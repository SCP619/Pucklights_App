"""
Hockey Highlight Engine — muistioptimioitu versio
FastAPI-backend + batch-GPU-pipeline (TensorRT tai .pt)

Muistioptimoinnit vs. alkuperainen:
- Pre-goal-buffer kirjoitetaan levylle JPEG:na muistin sijaan (DiskFrameBuffer)
- Post-goal-framet kirjoitetaan suoraan levylle, ei listaan RAM:iin
- rq-queue saa maxsize-rajoituksen (backpressure, estaa ylivuodon)
- Valitiedostot siivotaan heti klippia tallentaessa

Bugikorjaukset:
- _post_counter alustetaan funktion tasolla (ei if-lohkossa -> ei NameError)
- Pre-goal-framet kopioidaan turvaan heti maalin havaitsemishetkella,
  ennen kuin pyoriva puskuri ehtii poistaa ne (oli paasyyongelma)
- _framebuf-hakemisto poistetaan shutil.rmtreella rmdir:n sijaan
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
from pathlib import Path

import aiofiles
import uvicorn
from contextlib import asynccontextmanager
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from ultralytics import YOLO
from pydantic import BaseModel

# -------------------------------------------------------------
# CONFIG
# -------------------------------------------------------------
APP_DIR        = Path(__file__).resolve().parent

ENGINE_PATH    = str(APP_DIR / "HockeyAI_model_weight.engine")
PT_MODEL_PATH  = str(APP_DIR / "HockeyAI_model_weight.pt")
MODEL_PATH     = ENGINE_PATH if Path(ENGINE_PATH).exists() else PT_MODEL_PATH

UPLOAD_DIR           = APP_DIR / "uploads"
HIGHLIGHTS_DIR       = APP_DIR / "highlights"
DOWNLOADED_GAMES_DIR = APP_DIR / "downloaded_games"
UPLOAD_DIR.mkdir(exist_ok=True)
HIGHLIGHTS_DIR.mkdir(exist_ok=True)
DOWNLOADED_GAMES_DIR.mkdir(exist_ok=True)

BATCH_SIZE        = 16
PRE_GOAL_SECONDS  = 12
POST_GOAL_SECONDS = 3
FPS               = 60
GLOBAL_COOLDOWN   = 15

# JPEG-laatu levypuskurille: 75-85 on hyva kompromissi laatu/tila
BUFFER_JPEG_QUALITY = 80

REBUILD_ENGINE = False
ENGINE_IMGSZ   = 1280

# -------------------------------------------------------------
# GLOBAALI TILA
# -------------------------------------------------------------
model: YOLO | None = None
DEVICE = "cpu"
jobs: dict = {}

gpu_lock = threading.Lock()


# -------------------------------------------------------------
# ENGINE EXPORT
# -------------------------------------------------------------
def maybe_rebuild_engine():
    if not REBUILD_ENGINE:
        return
    print(f"Buildataan TensorRT-engine: batch={BATCH_SIZE}, imgsz={ENGINE_IMGSZ}, half=True ...")
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


# -------------------------------------------------------------
# FFMPEG
# -------------------------------------------------------------
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


# -------------------------------------------------------------
# MAALIDETEKTIO
# -------------------------------------------------------------
def check_for_goal(r) -> bool:
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

        gw = (goal_box[2] - goal_box[0]) * 2
        gh = (goal_box[3] - goal_box[1]) * 1.5

        x_left  = gx_c - gw / 2
        x_right = gx_c + gw / 2

        # FIX: Y alkaa keskeltä ja laajenee vain alaspäin
        y_top    = gy_c
        y_bottom = gy_c + gh

        exp = [x_left, y_top, x_right, y_bottom]

        if exp[0] < px < exp[2] and exp[1] < py < exp[3]:
            return True

    return False


# -------------------------------------------------------------
# ANNOTAATIO
# -------------------------------------------------------------
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

            gw = (x2 - x1) * 2
            gh = (y2 - y1) * 1.5

            x_left  = gx_c - gw / 2
            x_right = gx_c + gw / 2

            # FIX: vain alaspäin
            y_top    = gy_c
            y_bottom = gy_c + gh

            exp = [
                int(x_left),
                int(y_top),
                int(x_right),
                int(y_bottom)
            ]
            cv2.rectangle(frame, (exp[0], exp[1]), (exp[2], exp[3]), (0, 255, 0), 2)
            cv2.putText(frame, "Goal Zone 3x", (exp[0], exp[1] - 10),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)

        elif cls_id == 5 and conf > 0.50:
            cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 0, 255), 2)
            cv2.putText(frame, f"Puck {conf:.2f}", (x1, y1 - 10),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 255), 2)

    return frame


# -------------------------------------------------------------
# LEVYPUSKURI
# Korvaa deque(annotated_frames): kirjoittaa jokaisen annotoidun
# framen JPEG:na levylle, pitaa vain tiedostonimet muistissa.
# -------------------------------------------------------------
class DiskFrameBuffer:
    """
    Rengaspuskuri joka tallentaa framet JPEG-tiedostoina levylle.
    Muistissa pidetaan vain tiedostonimet (merkkijonot).
    """

    def __init__(self, tmpdir: Path, maxlen: int, quality: int = BUFFER_JPEG_QUALITY):
        self.tmpdir   = tmpdir
        self.maxlen   = maxlen
        self.quality  = quality
        self._names: list[str] = []
        self._counter = 0

    def append(self, frame) -> None:
        name = f"buf_{self._counter:08d}.jpg"
        path = self.tmpdir / name
        cv2.imwrite(str(path), frame, [cv2.IMWRITE_JPEG_QUALITY, self.quality])
        self._counter += 1
        self._names.append(name)

        # Poista vanhin jos puskuri taynna
        if len(self._names) > self.maxlen:
            old = self._names.pop(0)
            try:
                (self.tmpdir / old).unlink()
            except OSError:
                pass

    def snapshot_paths(self) -> list[str]:
        """Palauttaa absoluuttiset polut jarjestyksessa (vanhin ensin)."""
        return [str(self.tmpdir / n) for n in self._names]

    def start_frame_index(self, current_frame_idx: int) -> int:
        return max(0, current_frame_idx - len(self._names) + 1)

    def cleanup(self) -> None:
        for name in self._names:
            try:
                (self.tmpdir / name).unlink()
            except OSError:
                pass
        self._names.clear()


# -------------------------------------------------------------
# KLIPPIEN TALLENNUS
# -------------------------------------------------------------
def save_highlight_with_audio(
    frame_paths: list[str],
    out_path: str,
    source_video: str,
    buffer_start_frame: int,
    fps: float,
) -> None:
    if not frame_paths:
        print("  Tyhja framelista -- ohitetaan.")
        return

    first = cv2.imread(frame_paths[0])
    if first is None:
        print(f"  Ensimmaista framea ei voitu lukea: {frame_paths[0]}")
        return

    h, w, _ = first.shape
    duration   = len(frame_paths) / fps
    start_time = buffer_start_frame / fps

    tmp_path = out_path.replace(".mp4", "_noaudio.mp4")
    out = cv2.VideoWriter(tmp_path, cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))

    missing = 0
    for p in frame_paths:
        f = cv2.imread(p)
        if f is not None:
            out.write(f)
        else:
            missing += 1
    out.release()

    if missing:
        print(f"  Varoitus: {missing}/{len(frame_paths)} framea puuttui levylta.")

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


# -------------------------------------------------------------
# BATCH GPU -PIPELINE
# -------------------------------------------------------------

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
    fq.put(None)


def _gpu_worker_thread(fq: queue.Queue, rq: queue.Queue):
    """Batch predict. gpu_lock on jo hankittu ulkopuolella."""
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

    rq.put(None)


def _processor_thread(
    rq: queue.Queue,
    job_id: str,
    job_dir: Path,
    video_path: str,
    fps: float,
):
    """Annotaatio + maalidetektio + klippien kirjoitus CPU-threadissa."""
    buf_maxlen = int(PRE_GOAL_SECONDS * fps)

    # Pyoriva levypuskuri pre-goal-frameille
    tmpdir = job_dir / "_framebuf"
    tmpdir.mkdir(exist_ok=True)
    disk_buf = DiskFrameBuffer(tmpdir, maxlen=buf_maxlen)

    last_goal_time  = -999.0
    seen_events: set = set()
    saving           = False
    post_frames_rem  = 0
    _post_counter    = 0   # alustetaan funktion tasolla, ei if-lohkossa
    post_tmpdir: Path | None  = None
    clip_tmpdir: Path | None  = None   # turvakopiot pre-goal-frameista

    clip_pre_paths:  list[str] = []
    clip_post_paths: list[str] = []
    clip_start_idx   = 0

    frame_idx        = 0
    highlight_count  = 0

    while True:
        item = rq.get()
        if item is None:
            break

        r, raw_frame, ts = item
        frame_idx += 1

        annotated = annotate_frame(raw_frame, r)

        # -- 1. Kirjoita frame pyorivaan levypuskuriin --
        disk_buf.append(annotated)

        is_goal     = check_for_goal(r)
        event_id    = int(ts * 2)
        cooldown_ok = (ts - last_goal_time) > GLOBAL_COOLDOWN

        if is_goal and cooldown_ok and event_id not in seen_events:
            print(f"\n[{job_id[:8]}] MAALI {ts:.2f}s!")
            seen_events.add(event_id)
            last_goal_time = ts

            # -- KORJAUS: kopioi pre-goal-framet turvaan HETI --
            # Puskuri jatkaa pyorimista post-goal-ajan ja poistaa vanhimpia
            # tiedostoja. Jos viitataan suoraan puskurin polkuihin, ne voivat
            # olla poistettuja kun klippi yritetaan koostaa.
            clip_tmpdir = tmpdir / f"clip_{int(time.time()*1000)}"
            clip_tmpdir.mkdir(exist_ok=True)

            clip_pre_paths = []
            clip_start_idx = disk_buf.start_frame_index(frame_idx)

            for src in disk_buf.snapshot_paths():
                dst = clip_tmpdir / Path(src).name
                try:
                    shutil.copy2(src, dst)
                    clip_pre_paths.append(str(dst))
                except OSError as e:
                    print(f"  Varoitus: pre-framen kopiointi epaonnistui: {e}")

            print(f"[{job_id[:8]}] Kopioitu {len(clip_pre_paths)} pre-goal-framea turvaan.")

            # Oma kansio post-goal-frameille
            post_tmpdir = clip_tmpdir / "post"
            post_tmpdir.mkdir(exist_ok=True)

            clip_post_paths = []
            saving          = True
            post_frames_rem = int(POST_GOAL_SECONDS * fps)
            _post_counter   = 0

        # -- 2. Post-goal: kirjoita suoraan levylle --
        if saving and post_frames_rem > 0:
            name = f"post_{_post_counter:06d}.jpg"
            p    = post_tmpdir / name
            cv2.imwrite(str(p), annotated, [cv2.IMWRITE_JPEG_QUALITY, BUFFER_JPEG_QUALITY])
            clip_post_paths.append(str(p))
            _post_counter  += 1
            post_frames_rem -= 1

            if post_frames_rem == 0:
                saving = False

                # -- 3. Kokoa ja tallenna klippi --
                highlight_count += 1
                out_name = f"highlight_{highlight_count}_{int(time.time())}.mp4"
                out_path = str(job_dir / out_name)

                all_paths = clip_pre_paths + clip_post_paths
                print(f"[{job_id[:8]}] Tallennetaan klippi: {len(all_paths)} framea -> {out_name}")
                save_highlight_with_audio(
                    frame_paths=all_paths,
                    out_path=out_path,
                    source_video=video_path,
                    buffer_start_frame=clip_start_idx,
                    fps=fps,
                )
                print(f"[{job_id[:8]}] Klippi levylla: {os.path.exists(out_path)}")

                # -- 4. Siivoa turvakopiot heti --
                try:
                    shutil.rmtree(clip_tmpdir)
                except OSError:
                    pass
                clip_tmpdir     = None
                post_tmpdir     = None
                clip_pre_paths  = []
                clip_post_paths = []

                jobs[job_id]["highlights"].append({
                    "filename":    out_name,
                    "url":         f"/highlights/{job_id}/{out_name}",
                    "timestamp":   round(ts, 1),
                    "goal_number": highlight_count,
                })
                print(f"[{job_id[:8]}] Klippi tallennettu: {out_name}")

        jobs[job_id]["processed_frames"] = frame_idx

    # -- Siivoa kaikki valitiedostot jobin paattyessa --
    disk_buf.cleanup()
    if clip_tmpdir and clip_tmpdir.exists():
        shutil.rmtree(clip_tmpdir, ignore_errors=True)
    shutil.rmtree(tmpdir, ignore_errors=True)


def run_extraction(job_id: str, video_path: str) -> None:
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

    fps_out = []
    fq = queue.Queue(maxsize=512)
    rq = queue.Queue(maxsize=128)   # backpressure: estaa rq:n paisumisen

    t_reader = threading.Thread(
        target=_reader_thread, args=(video_path, fq, fps_out), daemon=True
    )

    def gpu_wrapper():
        with gpu_lock:
            _gpu_worker_thread(fq, rq)

    t_gpu  = threading.Thread(target=gpu_wrapper, daemon=True)
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


# -------------------------------------------------------------
# FASTAPI
# -------------------------------------------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    global model, DEVICE
    import torch

    maybe_rebuild_engine()

    DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Ladataan YOLO-malli ({MODEL_PATH}) laitteella {DEVICE} ...")
    model = YOLO(MODEL_PATH)
    print("Malli valmis.")
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


class URLUpload(BaseModel):
    url: str


@app.post("/upload-url")
def upload_video_url(payload: URLUpload):
    job_id    = str(uuid.uuid4())
    save_path = DOWNLOADED_GAMES_DIR / f"{job_id}.mp4"

    cmd = [
        FFMPEG,
        "-protocol_whitelist", "file,http,https,tcp,tls,crypto,data",
        "-i", payload.url,
        "-c", "copy",
        str(save_path),
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        raise HTTPException(status_code=400, detail=result.stderr[-1000:])

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


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)