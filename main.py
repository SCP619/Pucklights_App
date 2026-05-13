"""
Hockey Highlight Engine — yhdistetty versio
FastAPI-backend + batch-GPU-pipeline (TensorRT tai .pt)
"""

import cv2
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
import uuid
from collections import deque
from pathlib import Path

import aiofiles
import uvicorn
from contextlib import asynccontextmanager
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from ultralytics import YOLO

# ─────────────────────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────────────────────
APP_DIR        = Path(__file__).resolve().parent

# Mallipolut — engine on prioriteetti, .pt varavaihtoehto
ENGINE_PATH    = str(APP_DIR / "HockeyAI_model_weight.engine")
PT_MODEL_PATH  = str(APP_DIR / "HockeyAI_model_weight.pt")
MODEL_PATH     = ENGINE_PATH if Path(ENGINE_PATH).exists() else PT_MODEL_PATH

UPLOAD_DIR     = APP_DIR / "uploads"
HIGHLIGHTS_DIR = APP_DIR / "highlights"
UPLOAD_DIR.mkdir(exist_ok=True)
HIGHLIGHTS_DIR.mkdir(exist_ok=True)

# Batch-koko: TensorRT-engine vaatii kiinteän koon buildaushetkeltä.
# Jos käytät .pt-mallia, voi olla pienempi.
BATCH_SIZE        = 16
PRE_GOAL_SECONDS  = 12
POST_GOAL_SECONDS = 3
FPS               = 60
GLOBAL_COOLDOWN   = 15   # sekuntia maalien välillä

# TensorRT engine uudelleenrakentaminen (aja kerran, sitten aseta False)
REBUILD_ENGINE = False
ENGINE_IMGSZ   = 1280

# ─────────────────────────────────────────────────────────────
# GLOBAALI TILA
# ─────────────────────────────────────────────────────────────
model: YOLO | None = None
DEVICE = "cpu"
jobs: dict = {}

# GPU-lukko: vain yksi job kerrallaan GPU:lla
gpu_lock = threading.Lock()


# ─────────────────────────────────────────────────────────────
# ENGINE EXPORT (aja kerran jos REBUILD_ENGINE=True)
# ─────────────────────────────────────────────────────────────
def maybe_rebuild_engine():
    if not REBUILD_ENGINE:
        return
    print(f"Buildataan TensorRT-engine: batch={BATCH_SIZE}, imgsz={ENGINE_IMGSZ}, half=True …")
    m = YOLO(PT_MODEL_PATH)
    m.export(
        format="engine",
        batch=BATCH_SIZE,
        half=True,
        imgsz=ENGINE_IMGSZ,
        workspace=4,
        device=0,
    )
    print("Engine valmis. Aseta REBUILD_ENGINE=False.")


# ─────────────────────────────────────────────────────────────
# FFMPEG
# ─────────────────────────────────────────────────────────────
def get_ffmpeg_path() -> str:
    venv_bin = os.path.dirname(sys.executable)
    for candidate in ("ffmpeg.exe", "ffmpeg"):
        p = os.path.join(venv_bin, candidate)
        if os.path.isfile(p):
            return p
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
        capture_output=True, check=False,
    )
    import imageio_ffmpeg
    return imageio_ffmpeg.get_ffmpeg_exe()

FFMPEG = get_ffmpeg_path()
print(f"FFmpeg: {FFMPEG}")


# ─────────────────────────────────────────────────────────────
# MAALIDETEKTIO
# ─────────────────────────────────────────────────────────────
def check_for_goal(r) -> bool:
    """Tarkistaa onko kiekko laajennetussa maalialueessa (yksittäinen tulos)."""
    puck_box = None
    goal_box = None

    for box in r.boxes:
        cls_id = int(box.cls[0])
        conf   = float(box.conf[0])

        if cls_id == 5 and conf > 0.50:
            puck_box = box.xyxy[0].tolist()
        elif cls_id == 2 and conf > 0.50:
            goal_box = box.xyxy[0].tolist()

    if puck_box and goal_box:
        px = (puck_box[0] + puck_box[2]) / 2
        py = (puck_box[1] + puck_box[3]) / 2

        gx_c = (goal_box[0] + goal_box[2]) / 2
        gy_c = (goal_box[1] + goal_box[3]) / 2
        gw   = (goal_box[2] - goal_box[0]) * 2
        gh   = (goal_box[3] - goal_box[1]) * 3

        exp = [
            gx_c - gw / 2,
            gy_c - gh / 2,
            gx_c + gw / 2,
            gy_c + gh / 2,
        ]

        if exp[0] < px < exp[2] and exp[1] < py < exp[3]:
            return True

    return False


# ─────────────────────────────────────────────────────────────
# ANNOTAATIO
# ─────────────────────────────────────────────────────────────
def annotate_frame(frame, r):
    for box in r.boxes:
        cls_id = int(box.cls[0])
        conf   = float(box.conf[0])
        x1, y1, x2, y2 = map(int, box.xyxy[0].tolist())

        if cls_id == 2 and conf > 0.50:
            cv2.rectangle(frame, (x1, y1), (x2, y2), (255, 0, 0), 2)
            cv2.putText(frame, f"Goal {conf:.2f}", (x1, y1 - 10),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 0, 0), 2)

            gx_c = (x1 + x2) / 2
            gy_c = (y1 + y2) / 2
            gw   = (x2 - x1) * 2
            gh   = (y2 - y1) * 3
            exp  = [int(gx_c - gw/2), int(gy_c - gh / 2), int(gx_c + gw/2), int(gy_c + gh/2)]
            cv2.rectangle(frame, (exp[0], exp[1]), (exp[2], exp[3]), (0, 255, 0), 2)
            cv2.putText(frame, "Goal Zone 3x", (exp[0], exp[1] - 10),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)

        elif cls_id == 5 and conf > 0.50:
            cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 0, 255), 2)
            cv2.putText(frame, f"Puck {conf:.2f}", (x1, y1 - 10),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 255), 2)

    return frame


# ─────────────────────────────────────────────────────────────
# KLIPPIEN TALLENNUS FFMPEG:LLÄ (audio mukaan)
# ─────────────────────────────────────────────────────────────
def save_highlight_with_audio(
    frames: list,
    out_path: str,
    source_video: str,
    buffer_start_frame: int,
    fps: float,
) -> None:
    if not frames:
        print("⚠️  Tyhjä framelista — ohitetaan.")
        return

    h, w, _ = frames[0].shape
    duration   = len(frames) / fps
    start_time = buffer_start_frame / fps

    tmp_path = out_path.replace(".mp4", "_noaudio.mp4")
    out = cv2.VideoWriter(tmp_path, cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))
    for f in frames:
        out.write(f)
    out.release()

    cmd = [
        FFMPEG, "-y",
        "-i", tmp_path,
        "-ss", str(start_time), "-t", str(duration),
        "-i", source_video,
        "-c:v", "libx264",
        "-pix_fmt", "yuv420p",
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
    else:
        print(f"FFmpeg virhe: {result.stderr[:300]}")
        os.rename(tmp_path, out_path)


# ─────────────────────────────────────────────────────────────
# BATCH GPU -PIPELINE
# Kolme threadia: reader → gpu_worker → processor
# gpu_lock estää useiden jobien samanaikaisen GPU-käytön
# ─────────────────────────────────────────────────────────────

def _reader_thread(video_path: str, fq: queue.Queue, fps_out: list):
    cap = cv2.VideoCapture(video_path)
    fps = cap.get(cv2.CAP_PROP_FPS)
    if fps <= 1:
        fps = FPS
    fps_out.append(fps)

    frame_id = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        ts = frame_id / fps
        fq.put((frame, ts))
        frame_id += 1

    cap.release()
    fq.put(None)  # sentinel


def _gpu_worker_thread(fq: queue.Queue, rq: queue.Queue):
    """Batch predict GPU-threadissa. gpu_lock on jo hankittu ulkopuolella."""
    batch_frames = []
    batch_times  = []

    def flush():
        if not batch_frames:
            return
        frames = list(batch_frames)
        times  = list(batch_times)
        pad    = BATCH_SIZE - len(frames)
        padded = frames + [frames[-1]] * pad
        results = model.predict(padded, verbose=False, device=DEVICE)
        for r, t in zip(results[:len(frames)], times):
            rq.put((r, r.orig_img.copy(), t))

    while True:
        item = fq.get()
        if item is None:
            flush()
            break
        frame, ts = item
        batch_frames.append(frame)
        batch_times.append(ts)
        if len(batch_frames) >= BATCH_SIZE:
            flush()
            batch_frames = []
            batch_times  = []

    rq.put(None)  # sentinel


def _processor_thread(
    rq: queue.Queue,
    job_id: str,
    job_dir: Path,
    video_path: str,
    fps: float,
):
    """Annotaatio + maalidetektio + klippien kirjoitus CPU-threadissa."""
    buffer         = deque(maxlen=int(PRE_GOAL_SECONDS * fps))
    last_goal_time = -999.0
    seen_events    = set()
    saving         = False
    post_frames    = 0
    goal_frames    = []
    goal_start_idx = 0
    frame_idx      = 0
    highlight_count = 0

    while True:
        item = rq.get()
        if item is None:
            break

        r, raw_frame, ts = item
        frame_idx += 1

        annotated = annotate_frame(raw_frame, r)
        buffer.append(annotated)

        is_goal    = check_for_goal(r)
        event_id   = int(ts * 2)
        cooldown_ok = (ts - last_goal_time) > GLOBAL_COOLDOWN

        if is_goal and cooldown_ok and event_id not in seen_events:
            print(f"\n[{job_id[:8]}] MAALI {ts:.2f}s!")
            seen_events.add(event_id)
            last_goal_time = ts

            goal_frames    = list(buffer)
            goal_start_idx = max(0, frame_idx - len(goal_frames))
            saving      = True
            post_frames = int(POST_GOAL_SECONDS * fps)

        if saving:
            goal_frames.append(annotated)

        if post_frames > 0:
            post_frames -= 1
            if post_frames == 0:
                saving = False
                highlight_count += 1
                out_name = f"highlight_{highlight_count}_{int(time.time())}.mp4"
                out_path = str(job_dir / out_name)

                save_highlight_with_audio(
                    frames=goal_frames,
                    out_path=out_path,
                    source_video=video_path,
                    buffer_start_frame=goal_start_idx,
                    fps=fps,
                )

                jobs[job_id]["highlights"].append({
                    "filename":    out_name,
                    "url":         f"/highlights/{job_id}/{out_name}",
                    "timestamp":   round(ts, 1),
                    "goal_number": highlight_count,
                })
                goal_frames = []
                print(f"\n[{job_id[:8]}] Klippi tallennettu: {out_name}")

        jobs[job_id]["processed_frames"] = frame_idx


def run_extraction(job_id: str, video_path: str) -> None:
    """Käynnistää kolme threadia ja odottaa niiden valmistumista."""
    cap          = cv2.VideoCapture(video_path)
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    raw_fps      = cap.get(cv2.CAP_PROP_FPS)
    cap.release()
    fps = raw_fps if raw_fps > 0 else FPS

    job_dir = HIGHLIGHTS_DIR / job_id
    job_dir.mkdir(exist_ok=True)

    jobs[job_id].update({
        "status":           "processing",
        "total_frames":     max(total_frames, 1),
        "processed_frames": 0,
    })

    fq = queue.Queue(maxsize=512)
    rq = queue.Queue()
    fps_out = []

    t_reader = threading.Thread(
        target=_reader_thread, args=(video_path, fq, fps_out), daemon=True
    )

    def gpu_wrapper():
        with gpu_lock:   # ← yksi job kerrallaan GPU:lla
            _gpu_worker_thread(fq, rq)

    t_gpu = threading.Thread(target=gpu_wrapper, daemon=True)

    t_proc = threading.Thread(
        target=_processor_thread,
        args=(rq, job_id, job_dir, video_path, fps),
        daemon=True,
    )

    try:
        t_reader.start()
        t_gpu.start()
        t_proc.start()

        t_reader.join()
        t_gpu.join()
        t_proc.join()

        jobs[job_id]["status"] = "completed"

    except Exception as e:
        jobs[job_id].update({"status": "failed", "error": str(e)})
        print(f"[{job_id[:8]}] Virhe: {e}")

    finally:
        try:
            os.remove(video_path)
        except OSError:
            pass


# ─────────────────────────────────────────────────────────────
# FASTAPI
# ─────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    global model, DEVICE
    import torch

    maybe_rebuild_engine()

    DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"🚀 Ladataan YOLO-malli ({MODEL_PATH}) laitteella {DEVICE} …")
    model = YOLO(MODEL_PATH)
    print("✅ Malli valmis.")
    yield


app = FastAPI(title="Hockey Highlight Engine", lifespan=lifespan)
app.mount("/highlights", StaticFiles(directory=str(HIGHLIGHTS_DIR)), name="highlights")


@app.post("/upload")
async def upload_video(file: UploadFile = File(...)):
    job_id = str(uuid.uuid4())
    suffix = Path(file.filename or "video.mp4").suffix or ".mp4"
    save_path = UPLOAD_DIR / f"{job_id}{suffix}"

    async with aiofiles.open(str(save_path), "wb") as f:
        while chunk := await file.read(1024 * 1024):
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
    job = jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Job not found")

    total     = job["total_frames"]
    processed = job["processed_frames"]
    progress  = round(processed / total * 100, 1) if total > 0 else 0.0

    return {
        "job_id":     job_id,
        "status":     job["status"],
        "progress":   progress,
        "highlights": job["highlights"],
        "error":      job["error"],
    }


@app.get("/highlights/{job_id}/{filename}")
async def stream_highlight(job_id: str, filename: str):
    safe = Path(filename).name
    path = HIGHLIGHTS_DIR / job_id / safe
    if not path.exists():
        raise HTTPException(status_code=404, detail="Highlight not found")
    return FileResponse(str(path), media_type="video/mp4", filename=safe)


@app.delete("/highlights/{job_id}/{filename}")
async def delete_highlight(job_id: str, filename: str):
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