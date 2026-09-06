"""Checkpointed local Whisper transcription. Never contacts an inference provider."""
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys

MODEL_REVISION = "49e6aa286ad60c14352c404340ded53710378a11"
CHUNK = 180
OVERLAP = 5


def atomic_json(path, value):
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    temp.replace(path)


def normalize_words(words):
    result = []
    prior = 0.0
    for word in words:
        start, end = float(word["start"]), float(word["end"])
        text = word["word"].strip()
        if not all(math.isfinite(v) for v in (start, end)) or end < start:
            raise ValueError("Invalid word timestamps")
        start = max(start, prior)
        if not text or end <= start:
            continue
        result.append({"start": start, "end": end, "text": text})
        prior = end
    return result


def group_words(words):
    segments = []
    for word in normalize_words(words):
        if (not segments or word["start"] - segments[-1]["end"] > 0.6
                or word["end"] - segments[-1]["start"] > 8
                or segments[-1]["text"].endswith((".", "?", "!"))):
            segments.append({"id": f"s{len(segments)}", **word})
        else:
            segments[-1]["end"] = word["end"]
            segments[-1]["text"] += " " + word["text"]
    if not segments:
        raise ValueError("No speech found")
    return segments


def transcribe(source, destination):
    model = Path(os.environ.get("PODS_WHISPER_MODEL", str(Path.home() / "models/whisper-large-v3-mlx")))
    if not (model / "config.json").is_file() or not (model / ".pods-revision").is_file():
        raise ValueError("Install the pinned local Whisper model before processing")
    if (model / ".pods-revision").read_text().strip() != MODEL_REVISION:
        raise ValueError("Unexpected Whisper revision")
    # Import only after checking the local checkpoint. A missing model cannot trigger a download.
    import mlx_whisper

    duration = float(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(source)
    ], timeout=60))
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError("Invalid audio duration")
    with source.open("rb") as audio:
        source_hash = hashlib.file_digest(audio, "sha256").hexdigest()
    checkpoint = destination.parent / f"words-{source_hash}-{MODEL_REVISION}"
    checkpoint.mkdir(exist_ok=True)
    words = []
    for core_start in range(0, math.ceil(duration), CHUNK):
        saved = checkpoint / f"{core_start}.json"
        if saved.exists():
            batch = json.loads(saved.read_text())
        else:
            start = max(0, core_start - OVERLAP)
            end = min(duration, core_start + CHUNK + OVERLAP)
            wav = checkpoint / f"{core_start}.wav"
            subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-ss", str(start),
                            "-i", str(source), "-t", str(end - start), "-ac", "1", "-ar", "16000", str(wav)],
                           check=True, timeout=300)
            output = mlx_whisper.transcribe(str(wav), path_or_hf_repo=str(model), word_timestamps=True,
                                            language=os.environ.get("PODS_LANGUAGE", "en"),
                                            temperature=0.0, condition_on_previous_text=False,
                                            verbose=False)
            batch = []
            for segment in output["segments"]:
                if segment.get("compression_ratio", 0) > 2.4 and segment.get("avg_logprob", 0) < -1:
                    raise ValueError("Repeated or unreliable speech requires review")
                for word in segment.get("words", []):
                    absolute = {"word": word["word"], "start": start + word["start"], "end": start + word["end"]}
                    midpoint = (absolute["start"] + absolute["end"]) / 2
                    if core_start <= midpoint < min(duration, core_start + CHUNK):
                        batch.append(absolute)
            atomic_json(saved, batch)
            wav.unlink(missing_ok=True)
        words.extend(batch)
    atomic_json(destination, group_words(words))


if __name__ == "__main__":
    try:
        transcribe(Path(sys.argv[1]), Path(sys.argv[2]))
    except Exception as error:
        # Do not write transcript text, credentials, or provider payloads to service logs.
        print(f"Local transcription failed: {type(error).__name__}", file=sys.stderr)
        sys.exit(1)
