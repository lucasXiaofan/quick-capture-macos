#!/usr/bin/env python3
"""Read Aloud engine: Kokoro-82M on MLX, kept warm in one process, driven by JSON lines.

  stdin  {"cmd":"speak","id":"…","text":"…","voice":"af_heart","speed":1.0}   (a new speak cancels the old one)
         {"cmd":"stop"} | {"cmd":"stats"} | {"cmd":"quit"}
  stdout {"event":"ready",…} {"event":"start","id","chunks":[…]} {"event":"chunk","id","path","index","audio_s","gen_s"} {"event":"done",…}
         {"event":"stats",…} {"event":"error","message"}

Speed: chunks grow 80 -> 200 -> 360 chars (short first chunk = fast first audio; see SIZES). Kokoro has no batch dimension, so batching is along time: fewer, longer calls (each call has a
fixed cost). Generation runs ~10-15x faster than playback, so chunk 2 is ready long before chunk 1 ends.
Memory: MLX keeps freed buffers in a cache that grows with every new input shape (17 GB on Kokoro if
unlimited). We cap it (set_cache_limit), set a memory limit, clear the cache after each request, and exit if
the process footprint goes over --mem-limit-gb (the app restarts it on the next request).
Files: models in --models-dir (HF_HOME), audio in --audio-dir (pruned to --audio-limit-mb), all deletable.

  python kokoro_server.py serve --models-dir D --audio-dir D [--mem-limit-gb 3] [--idle-exit 600]
  python kokoro_server.py bench --models-dir D --text-file F          (chunking + cache settings, prints a table)
"""
import argparse
import ctypes
import hashlib
import json
import os
import queue
import re
import sys
import threading
import time
import wave
from pathlib import Path

SR = 24000
REPO = "mlx-community/Kokoro-82M-bf16"
# Chunk sizes grow: cost is ~linear in audio length (M4: ~0.07 s per audio second + ~0.05 s per call; 2x that
# in Low Power Mode), so time to first audio = size of chunk 1. Each next chunk must be ready before the
# previous one finishes playing: gen(k+1) < audio(k), true for growth up to ~6x even in Low Power Mode.
SIZES = (80, 200, 360)   # chars; 360 stays under Kokoro's 510-phoneme limit
GB = 1 << 30


# ---------- memory: the process's physical footprint (what Activity Monitor shows; includes Metal buffers)
class _RUsage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in (
        "user", "system", "idle_wk", "int_wk", "pageins", "wired", "resident", "phys_footprint", "start", "exit",
        "c_user", "c_system", "c_idle", "c_int", "c_pageins", "c_elapsed", "disk_r", "disk_w")]


def footprint_bytes():
    try:
        buf = _RUsage()
        ctypes.CDLL("libproc.dylib").proc_pid_rusage(os.getpid(), 2, ctypes.byref(buf))
        return int(buf.phys_footprint)
    except Exception:
        return -1


# ---------- text: OCR lines -> clean text -> chunks
def clean(text):
    text = re.sub(r"(\w)-\n(\w)", r"\1\2", text)          # re-join words hyphenated at line ends
    text = re.sub(r"\s*\n\s*", " ", text)                  # screenshot line wraps are not sentence ends
    text = re.sub(r"\bAl\b", "AI", text)                   # OCR reads "AI" as "Al" (seen on Apple Vision)
    return re.sub(r"\s+", " ", text).strip()


def chunks(text):
    """Split at sentence ends, pack sentences up to the growing SIZES; a too-long piece is cut at a comma, else a space."""
    sents = [s for s in re.split(r"(?<=[.!?;:])\s+(?=[\"'(\[]?[A-Z0-9])", text) if s.strip()]
    out, cur = [], ""

    def limit():
        return SIZES[min(len(out), len(SIZES) - 1)]

    for s in sents:
        if cur and len(cur) + 1 + len(s) > limit():
            out.append(cur)
            cur = ""
        cur = f"{cur} {s}".strip()
        while len(cur) > limit():
            n = limit()
            cut = cur.rfind(", ", n // 3, n)
            cut = cut + 1 if cut > 0 else cur.rfind(" ", n // 3, n)
            if cut <= 0:
                break
            out.append(cur[:cut].strip())
            cur = cur[cut:].strip()
    if cur:
        out.append(cur)
    return out


def write_wav(path, audio):
    import numpy as np
    pcm = (np.clip(audio, -1, 1) * 32767).astype("<i2")
    tmp = Path(str(path) + ".tmp")
    with wave.open(str(tmp), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    tmp.replace(path)


EVENTS = sys.stdout          # the protocol channel; libraries print to stdout too, so they get stderr (main())


def emit(**ev):
    EVENTS.write(json.dumps(ev) + "\n")
    EVENTS.flush()


class Engine:
    def __init__(self, models_dir, mem_limit_gb, cache_limit_gb):
        os.environ["HF_HOME"] = str(models_dir)               # model files live where the app can delete them
        os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
        t0 = time.perf_counter()
        import mlx.core as mx
        from mlx_audio.tts.utils import load_model
        self.mx = mx
        mx.set_memory_limit(int(mem_limit_gb * GB))         # MLX frees cache / waits when it would go over
        mx.set_cache_limit(int(cache_limit_gb * GB))        # keep at most this much of freed buffers
        self.model = load_model(REPO)
        self.load_s = time.perf_counter() - t0
        self.pipes = {}
        t0 = time.perf_counter()
        self.synth("Ready.", "af_heart", 1.0)               # first call compiles kernels; pay it now, not on chunk 1
        self.warm_s = time.perf_counter() - t0
        mx.clear_cache()

    def pipe(self, voice):
        lang = voice[0] if voice[:1] in "abefhijpz" else "a"   # Kokoro voice ids start with their language code
        if lang not in self.pipes:
            self.pipes[lang] = self.model._get_pipeline(lang)
        return self.pipes[lang]

    def synth(self, text, voice, speed):
        import numpy as np
        parts = [np.array(r.audio).reshape(-1) for r in self.pipe(voice)(text, voice=voice, speed=speed,
                                                                         split_pattern=None) if r.audio is not None]
        return np.concatenate(parts) if parts else np.zeros(0, dtype="float32")


def prune(audio_dir, limit_mb):
    files = sorted((p for p in audio_dir.glob("*.wav")), key=lambda p: p.stat().st_mtime)
    total = sum(p.stat().st_size for p in files)
    while files and total > limit_mb * (1 << 20):
        p = files.pop(0)
        total -= p.stat().st_size
        p.unlink(missing_ok=True)
        p.with_suffix(".txt").unlink(missing_ok=True)


def serve(a):
    audio_dir = Path(a.audio_dir)
    parts_dir = audio_dir / ".parts"
    audio_dir.mkdir(parents=True, exist_ok=True)
    try:
        eng = Engine(a.models_dir, a.mem_limit_gb, a.cache_limit_gb)
    except Exception as e:  # noqa: BLE001
        emit(event="error", message=f"could not load Kokoro: {e}")
        return 1
    emit(event="ready", load_s=round(eng.load_s, 2), warm_s=round(eng.warm_s, 2),
         footprint_mb=footprint_bytes() >> 20)

    jobs, cancel = queue.Queue(), threading.Event()
    last_used = [time.time()]

    def stats():
        mx = eng.mx
        return dict(footprint_mb=footprint_bytes() >> 20, active_mb=mx.get_active_memory() >> 20,
                    cache_mb=mx.get_cache_memory() >> 20, peak_mb=mx.get_peak_memory() >> 20)

    def run(job):
        jid, voice, speed = job["id"], job.get("voice") or a.voice, float(job.get("speed") or a.speed)
        text = clean(job.get("text", ""))
        if not text:
            emit(event="error", id=jid, message="no text")
            return
        key = hashlib.sha1(f"{REPO}|{voice}|{speed}|{text}".encode()).hexdigest()[:16]
        final = audio_dir / f"{key}.wav"
        if final.exists():                                  # same text before: no model call at all
            os.utime(final)
            emit(event="start", id=jid, chunks=[text])
            emit(event="chunk", id=jid, index=0, path=str(final), audio_s=None, gen_s=0, cached=True)
            emit(event="done", id=jid, path=str(final), cached=True, ttfa_s=0, **stats())
            return
        import numpy as np
        for old in parts_dir.glob("*.wav"):                 # parts of earlier requests have been played
            old.unlink(missing_ok=True)
        parts_dir.mkdir(exist_ok=True)
        t_start, audio, ttfa = time.perf_counter(), [], None
        eng.mx.reset_peak_memory()
        plan = chunks(text)
        emit(event="start", id=jid, chunks=plan)            # the panel shows the text as it will be spoken
        for i, c in enumerate(plan):
            if cancel.is_set():
                break
            t0 = time.perf_counter()
            wav = eng.synth(c, voice, speed)
            gen = time.perf_counter() - t0
            eng.mx.clear_cache()                              # shapes differ per chunk: a kept buffer is rarely reused
            p = parts_dir / f"{key}-{i:03d}.wav"
            write_wav(p, wav)
            ttfa = ttfa if ttfa is not None else time.perf_counter() - t_start
            audio.append(wav)
            emit(event="chunk", id=jid, index=i, path=str(p), audio_s=round(len(wav) / SR, 2), gen_s=round(gen, 3),
                 chars=len(c))
        if cancel.is_set():
            emit(event="done", id=jid, cancelled=True, **stats())
            return
        full = np.concatenate(audio) if audio else np.zeros(0)
        write_wav(final, full)
        final.with_suffix(".txt").write_text(text)
        prune(audio_dir, a.audio_limit_mb)
        emit(event="done", id=jid, path=str(final), audio_s=round(len(full) / SR, 2),
             gen_s=round(time.perf_counter() - t_start, 3), ttfa_s=round(ttfa or 0, 3), **stats())

    def worker():
        while True:
            job = jobs.get()
            if job is None:
                return
            cancel.clear()
            try:
                run(job)
            except Exception as e:  # noqa: BLE001
                emit(event="error", id=job.get("id"), message=str(e))
            eng.mx.clear_cache()
            last_used[0] = time.time()
            if footprint_bytes() > a.mem_limit_gb * GB:      # hard guard: give all memory back, app restarts us
                emit(event="exit", reason="memory", **stats())
                os._exit(0)

    def idle_watch():
        while True:
            time.sleep(15)
            if a.idle_exit and jobs.empty() and time.time() - last_used[0] > a.idle_exit:
                emit(event="exit", reason="idle")
                os._exit(0)

    threading.Thread(target=worker, daemon=True).start()
    threading.Thread(target=idle_watch, daemon=True).start()
    for line in sys.stdin:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        cmd = msg.get("cmd")
        last_used[0] = time.time()
        if cmd == "speak":
            cancel.set()                                    # newest request wins
            while not jobs.empty():
                jobs.get_nowait()
            jobs.put(msg)
        elif cmd == "stop":
            cancel.set()
        elif cmd == "stats":
            emit(event="stats", **stats())
        elif cmd == "quit":
            break
    cancel.set()
    jobs.put(None)
    return 0


def bench(a):
    """Same text, several chunking plans and cache settings; one process, so run each cache setting separately."""
    text = clean(Path(a.text_file).read_text())
    eng = Engine(a.models_dir, a.mem_limit_gb, a.cache_limit_gb)
    mx = eng.mx
    sents = [s for s in re.split(r"(?<=[.!?;:])\s+(?=[A-Z0-9])", text) if s.strip()]
    plans = {
        "per-sentence": sents,
        "growing 80/200/360": chunks(text),
        "one-call": [text],
    }
    print(f"load {eng.load_s:.2f}s warm {eng.warm_s:.2f}s  cache_limit={a.cache_limit_gb}GB "
          f"clear_each={a.clear_each}  footprint {footprint_bytes() >> 20} MB")
    rows = []
    for name, cs in plans.items():
        for rep in range(a.reps):
            mx.reset_peak_memory()
            t_start, ttfa, n_audio, peak_fp = time.perf_counter(), None, 0, 0
            for c in cs:
                wav = eng.synth(c, a.voice, 1.0)
                if a.clear_each:
                    mx.clear_cache()
                ttfa = ttfa or time.perf_counter() - t_start
                n_audio += len(wav)
                peak_fp = max(peak_fp, footprint_bytes())
            total = time.perf_counter() - t_start
            if rep == a.reps - 1:
                rows.append((name, len(cs), ttfa, total, n_audio / SR, peak_fp >> 20,
                             mx.get_peak_memory() >> 20, mx.get_cache_memory() >> 20))
    print(f"{'plan':22} {'calls':>5} {'ttfa_s':>7} {'total_s':>7} {'audio_s':>7} {'x_rt':>5} "
          f"{'foot_MB':>7} {'peak_MB':>7} {'cache_MB':>8}")
    for r in rows:
        print(f"{r[0]:22} {r[1]:5d} {r[2]:7.3f} {r[3]:7.3f} {r[4]:7.1f} {r[4] / r[3]:5.1f} {r[5]:7d} {r[6]:7d} {r[7]:8d}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["serve", "bench"])
    ap.add_argument("--models-dir", required=True)
    ap.add_argument("--audio-dir", default="")
    ap.add_argument("--voice", default="af_heart")
    ap.add_argument("--speed", type=float, default=1.0)
    ap.add_argument("--mem-limit-gb", type=float, default=3.0)
    ap.add_argument("--cache-limit-gb", type=float, default=0.5)
    ap.add_argument("--audio-limit-mb", type=float, default=500)
    ap.add_argument("--idle-exit", type=float, default=600, help="seconds idle before exiting (0 = never)")
    ap.add_argument("--text-file", default="")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--clear-each", type=int, default=1)
    a = ap.parse_args()
    if a.mode == "serve":
        sys.stdout = sys.stderr
    sys.exit(serve(a) if a.mode == "serve" else bench(a))


if __name__ == "__main__":
    main()
