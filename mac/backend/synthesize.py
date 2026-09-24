"""Per-section Kokoro TTS over an extracted article.

Reads article.json, writes one WAV per section plus manifest.json with
measured durations. Each section start becomes a chapter start downstream.
Existing section WAVs are kept and re-measured, so a preempted run resumes.

Exit 0 on success; exit 2 with a stderr reason on failure.
"""
import argparse
import json
import re
import sys
import wave
from pathlib import Path

DEFAULT_MODEL = "mlx-community/Kokoro-82M-bf16"
DEFAULT_REVISION = "a71e4d38b236d968966a2002c4c895dbd12b1c3c"
DEFAULT_VOICE = "af_heart"
CHUNK_LIMIT = 900


def load_tts():
    # Heavy MLX dependency, imported lazily so module import stays light
    # outside the uv environment.
    from mlx_audio.audio_io import write as audio_write
    from mlx_audio.tts.utils import load
    import numpy

    return load, audio_write, numpy


def split_sentences(text):
    parts = re.split(r"(?<=[.!?])\s+|\n+", text.strip())
    return [part.strip() for part in parts if part and part.strip()]


def chunk_text(text, limit=CHUNK_LIMIT):
    """Split speakable text into model-sized chunks at sentence boundaries."""
    chunks = []
    current = ""
    for sentence in split_sentences(text):
        while len(sentence) > limit:
            chunks.append(sentence[:limit])
            sentence = sentence[limit:]
        if len(current) + len(sentence) + 1 > limit and current:
            chunks.append(current)
            current = ""
        current = f"{current} {sentence}".strip() if current else sentence
    if current:
        chunks.append(current)
    return chunks


def section_text(article, index):
    section = article["sections"][index]
    pieces = []
    if index == 0:
        intro = article.get("title", "").strip()
        author = article.get("author", "").strip()
        if intro:
            pieces.append(intro + ".")
        if author:
            pieces.append(f"By {author}.")
    heading = section.get("heading", "").strip()
    if heading and (index > 0 or heading != article.get("title", "").strip()):
        pieces.append(heading + ".")
    pieces.extend(p for p in section.get("paragraphs", []) if p.strip())
    return " ".join(pieces)


def wav_samples(path):
    with wave.open(str(path), "rb") as handle:
        return handle.getnframes(), handle.getframerate()


def synthesize(load, audio_write, numpy, model, voice, texts, out_path):
    arrays = []
    for text in chunks_for(texts):
        results = list(model.generate(text, voice=voice, speed=1.0, lang_code="a"))
        if not results:
            raise ValueError("model generated no audio")
        for result in results:
            arrays.append(numpy.asarray(result.audio).reshape(-1))
    combined = numpy.concatenate(arrays) if arrays else numpy.zeros(0)
    audio_write(str(out_path), combined, 24000, format="wav")
    return len(combined)


def chunks_for(texts):
    for text in texts:
        yield from chunk_text(text)


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--article", required=True)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--voice", default=DEFAULT_VOICE)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--revision", default=DEFAULT_REVISION)
    args = parser.parse_args(argv)
    article = json.loads(Path(args.article).read_text(encoding="utf-8"))
    sections = article.get("sections") or []
    if not sections:
        sys.stderr.write("article had no readable text\n")
        return 2
    if not args.voice.strip():
        sys.stderr.write("voice is required\n")
        return 2
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    load, audio_write, numpy = load_tts()
    try:
        model = load(args.model, revision=args.revision or None)
    except Exception as exc:
        sys.stderr.write(f"TTS model failed to load: {exc}\n")
        return 2
    manifest = {"voice": args.voice, "model": args.model, "sample_rate": 24000, "sections": []}
    for index, section in enumerate(sections):
        filename = f"section-{index:03d}.wav"
        path = out_dir / filename
        try:
            if path.is_file():
                samples, rate = wav_samples(path)
                if rate != 24000 or samples == 0:
                    raise ValueError(f"{filename} is not usable audio")
            else:
                texts = [section_text(article, index)]
                samples = synthesize(load, audio_write, numpy, model, args.voice, texts, path)
        except Exception as exc:
            sys.stderr.write(f"section {index} failed: {exc}\n")
            return 2
        manifest["sections"].append({
            "heading": section.get("heading", ""),
            "file": filename,
            "samples": samples,
            "duration": samples / 24000,
        })
    temp = out_dir / "manifest.tmp"
    temp.write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    temp.replace(out_dir / "manifest.json")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
