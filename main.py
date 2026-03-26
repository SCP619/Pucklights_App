"""
Hockey Highlight Extraction Backend
Ports the logic from Extraction_Engine.ipynb into a FastAPI server.

Run from /home/scp619/LDB/App/ :
    uvicorn main:app --host 0.0.0.0 --port 8000
"""

import cv2
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from collections import deque
from pathlib import Path

import aiofiles
import uvicorn
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from ultralytics import YOLO

# ── Paths ─────────────────────────────────────────────────────────────────────
APP_DIR       = Path(__file__).resolve().parent          # .../App/
MODEL_PATH    = str(APP_DIR / "HockeyAI_model_weight.pt")
UPLOAD_DIR    = APP_DIR / "uploads"
HIGHLIGHTS_DIR = APP_DIR / "highlights"

UPLOAD_DIR.mkdir(exist_ok=True)
HIGHLIGHTS_DIR.mkdir(exist_ok=True)

# ── Notebook constants ────────────────────────────────────────────────────────
PRE_GOAL_SECONDS  = 12
POST_GOAL_SECONDS = 3
TOTAL_SECONDS     = PRE_GOAL_SECONDS + POST_GOAL_SECONDS
FPS               = 60   # default; overridden per-video at runtime

# ── Global model (loaded once at startup) ────────────────────────────────────
model: YOLO | None = None

# ── Job registry ──────────────────────────────────────────────────────────────
jobs: dict = {}

# ── FFmpeg helper (ported from notebook) ─────────────────────────────────────

def get_ffmpeg_path() -> str:
    """Return ffmpeg executable path — mirrors get_ffmpeg_path() in the notebook."""
    venv_bin = os.path.dirname(sys.executable)
    for candidate in ("ffmpeg.exe", "ffmpeg"):
        venv_ffmpeg = os.path.join(venv_bin, candidate)
        if os.path.isfile(venv_ffmpeg):
            return venv_ffmpeg

    which = shutil.which("ffmpeg")
    if which:
        return which

    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except ImportError:
        pass

    subprocess.run(
        [sys.executable, "-m", "pip", "install", "imageio[ffmpeg]", "-q"],
        capture_output=True, check=False
    )
    import imageio_ffmpeg
    return imageio_ffmpeg.get_ffmpeg_exe()


FFMPEG = get_ffmpeg_path()
print(f"FFmpeg: {FFMPEG}")

# ── Core detection logic (ported from notebook) ───────────────────────────────

def check_for_goal(r) -> tuple[bool, tuple | None]:
    """
    Ported directly from check_for_goal() in Extraction_Engine.ipynb.
    Checks a single YOLO result frame for a puck inside a 3× expanded goal box.
    Returns (is_goal, puck_coords_or_None).
    """
    puck_box = None
    goal_box = None

    for box in r.boxes:
        cls_id = int(box.cls[0])
        conf   = float(box.conf[0])

        if cls_id == 5 and conf > 0.30:   # Puck
            puck_box = box.xyxy[0].tolist()
        elif cls_id == 2 and conf > 0.50:  # Goal Net
            goal_box = box.xyxy[0].tolist()

    if puck_box and goal_box:
        px = (puck_box[0] + puck_box[2]) / 2
        py = (puck_box[1] + puck_box[3]) / 2

        gx_center = (goal_box[0] + goal_box[2]) / 2
        gy_center = (goal_box[1] + goal_box[3]) / 2
        gw = (goal_box[2] - goal_box[0]) * 3
        gh = (goal_box[3] - goal_box[1]) * 3
        expanded_goal = [
            gx_center - gw / 2,
            gy_center - gh / 2,
            gx_center + gw / 2,
            gy_center + gh / 2,
        ]

        if (expanded_goal[0] < px < expanded_goal[2]) and (expanded_goal[1] < py < expanded_goal[3]):
            return True, (px, py)

    return False, None


def save_highlight_with_audio(
    frames: list,
    out_path: str,
    source_video: str,
    buffer_start_frame: int,
    fps: float,
) -> None:
    """
    Ported directly from save_highlight_with_audio() in Extraction_Engine.ipynb.
    Writes frames to a silent MP4 then merges the original audio with FFmpeg.
    """
    if not frames:
        print("⚠️  Empty frame list — skipping save.")
        return

    h, w, _ = frames[0].shape
    duration    = len(frames) / fps
    start_time  = buffer_start_frame / fps

    tmp_path = out_path.replace(".mp4", "_noaudio.mp4")
    out = cv2.VideoWriter(tmp_path, cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))
    for frame in frames:
        out.write(frame)
    out.release()

    cmd = [
        FFMPEG, "-y",
        "-i", tmp_path,
        "-ss", str(start_time),
        "-t",  str(duration),
        "-i", source_video,
        "-c:v", "copy",
        "-c:a", "aac",
        "-b:a", "192k",
        "-map", "0:v:0",
        "-map", "1:a:0",
        "-shortest",
        out_path,
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode == 0:
        os.remove(tmp_path)
        print(f"✅ Highlight saved with audio: {out_path}")
    else:
        os.rename(tmp_path, out_path)
        print(f"⚠️  FFmpeg failed (code {result.returncode}), saved without audio.")


# ── Job processing thread ─────────────────────────────────────────────────────

def run_extraction(job_id: str, video_path: str) -> None:
    """
    Main extraction loop — ported from the main loop in Extraction_Engine.ipynb.
    Uses model.track with BotSort, rolling frame buffer, goal detection, and
    save_highlight_with_audio for each goal clip.
    """
    global model

    if model is None:
        jobs[job_id].update({"status": "failed", "error": "Model not loaded"})
        return

    # Probe total frames for progress reporting
    probe = cv2.VideoCapture(video_path)
    total_frames = int(probe.get(cv2.CAP_PROP_FRAME_COUNT))
    raw_fps      = probe.get(cv2.CAP_PROP_FPS)
    probe.release()
    fps = raw_fps if raw_fps > 0 else FPS

    job_dir = HIGHLIGHTS_DIR / job_id
    job_dir.mkdir(exist_ok=True)

    jobs[job_id].update({
        "status":           "processing",
        "total_frames":     max(total_frames, 1),
        "processed_frames": 0,
    })

    frame_buffer         = deque(maxlen=TOTAL_SECONDS * int(fps))
    goal_detected_cooldown = 0
    post_goal_frames     = 0
    goal_start_frame     = 0
    highlight_count      = 0

    # model.track with stream=True — mirrors the notebook loop exactly
    results = model.track(
        source=video_path,
        stream=True,
        persist=True,
        conf=0.25,
        iou=0.5,
        tracker="botsort.yaml",
        device=0,
        show=False,
    )

    for i, r in enumerate(results):
        frame = r.orig_img.copy()
        frame_buffer.append(frame)

        is_goal, _ = check_for_goal(r)

        buffer_start_frame = max(0, i - len(frame_buffer) + 1)

        if is_goal and goal_detected_cooldown == 0:
            print(f"🚨 Goal at frame {i} ({i/fps:.1f}s)")
            post_goal_frames       = int(POST_GOAL_SECONDS * fps)
            goal_detected_cooldown = int(fps * 30)
            goal_start_frame       = buffer_start_frame

        if post_goal_frames > 0:
            post_goal_frames -= 1
            if post_goal_frames == 0:
                highlight_count += 1
                out_name = f"goal_{highlight_count}_{int(time.time())}.mp4"
                out_path = str(job_dir / out_name)
                save_highlight_with_audio(
                    frames=list(frame_buffer),
                    out_path=out_path,
                    source_video=video_path,
                    buffer_start_frame=goal_start_frame,
                    fps=fps,
                )
                jobs[job_id]["highlights"].append({
                    "filename":    out_name,
                    "url":         f"/highlights/{job_id}/{out_name}",
                    "timestamp":   round(i / fps, 1),
                    "goal_number": highlight_count,
                })

        if goal_detected_cooldown > 0:
            goal_detected_cooldown -= 1

        jobs[job_id]["processed_frames"] = i + 1

    jobs[job_id]["status"] = "completed"
    print(f"✅ Job {job_id} done — {highlight_count} goal(s) found.")

    try:
        os.remove(video_path)
    except OSError:
        pass


# ── FastAPI app ───────────────────────────────────────────────────────────────

app = FastAPI(title="Hockey Highlight Engine")
app.mount("/highlights", StaticFiles(directory=str(HIGHLIGHTS_DIR)), name="highlights")


@app.on_event("startup")
def load_model() -> None:
    global model
    print(f"🚀 Loading YOLO model from {MODEL_PATH} …")
    model = YOLO(MODEL_PATH)
    print("✅ Model ready.")


@app.post("/upload")
async def upload_video(file: UploadFile = File(...)):
    """Receive a hockey video, save it, and start extraction in a background thread."""
    job_id = str(uuid.uuid4())
    suffix = Path(file.filename or "video.mp4").suffix or ".mp4"
    save_path = UPLOAD_DIR / f"{job_id}{suffix}"

    async with aiofiles.open(str(save_path), "wb") as f:
        while chunk := await file.read(1024 * 1024):   # 1 MB chunks
            await f.write(chunk)

    jobs[job_id] = {
        "status":           "queued",
        "total_frames":     1,
        "processed_frames": 0,
        "highlights":       [],
        "error":            None,
    }

    threading.Thread(
        target=run_extraction,
        args=(job_id, str(save_path)),
        daemon=True,
    ).start()

    return {"job_id": job_id}


@app.get("/status/{job_id}")
async def get_status(job_id: str):
    """Poll extraction progress."""
    job = jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Job not found")

    total     = job["total_frames"]
    processed = job["processed_frames"]
    progress  = round(processed / total * 100, 1) if total > 0 else 0.0

    return {
        "job_id":     job_id,
        "status":     job["status"],      # queued | processing | completed | failed
        "progress":   progress,
        "highlights": job["highlights"],
        "error":      job["error"],
    }


@app.get("/highlights/{job_id}/{filename}")
async def stream_highlight(job_id: str, filename: str):
    """Stream a highlight clip to the app."""
    safe = Path(filename).name
    path = HIGHLIGHTS_DIR / job_id / safe
    if not path.exists():
        raise HTTPException(status_code=404, detail="Highlight not found")
    return FileResponse(str(path), media_type="video/mp4", filename=safe)


@app.delete("/highlights/{job_id}/{filename}")
async def delete_highlight(job_id: str, filename: str):
    """Discard a highlight (delete from disk + job registry)."""
    safe = Path(filename).name
    path = HIGHLIGHTS_DIR / job_id / safe
    if path.exists():
        path.unlink()
    if job_id in jobs:
        jobs[job_id]["highlights"] = [
            h for h in jobs[job_id]["highlights"] if h["filename"] != safe
        ]
    return {"deleted": safe}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
