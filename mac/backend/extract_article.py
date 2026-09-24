"""Extract article text, structure, and metadata from fetched HTML. No network.

Reads one HTML file, writes one JSON document:
{"title", "author", "published", "site", "image_url", "url",
 "sections": [{"heading", "paragraphs": [...]}]}

Exit 0 on success. Exit 2 when the page has no readable text, exit 3 when
it exceeds --max-words or --max-sections. Human-readable reason on stderr.
"""
import argparse
import json
import sys
import urllib.parse
from pathlib import Path
from xml.etree import ElementTree


def load_trafilatura():
    # Heavy dependency, imported lazily like transcribe.py's mlx_whisper so
    # module import stays light outside the uv environment.
    import trafilatura

    return trafilatura


def atomic_json(path, value):
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    temp.replace(path)


def sections_from_xml(xml_text):
    try:
        root = ElementTree.fromstring(xml_text)
    except ElementTree.ParseError:
        return []
    sections = []
    current = {"heading": "", "paragraphs": []}

    def flush():
        if current["paragraphs"]:
            sections.append(current)

    for element in root.iter():
        if element.tag == "head":
            text = "".join(element.itertext()).strip()
            if not text:
                continue
            flush()
            current = {"heading": text, "paragraphs": []}
        elif element.tag in ("p", "item", "code"):
            text = "".join(element.itertext()).strip()
            if text:
                current["paragraphs"].append(text)
    flush()
    return [dict(section) for section in sections]


def word_count(sections):
    return sum(len(paragraph.split()) for section in sections for paragraph in section["paragraphs"])


def absolute_http_url(value):
    if not value:
        return ""
    try:
        parsed = urllib.parse.urlparse(value)
    except ValueError:
        return ""
    if parsed.scheme in ("http", "https") and parsed.netloc:
        return value
    return ""


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--html", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--max-words", type=int, default=12000)
    parser.add_argument("--max-sections", type=int, default=40)
    args = parser.parse_args(argv)
    trafilatura = load_trafilatura()
    html = Path(args.html).read_text(encoding="utf-8")
    document = trafilatura.bare_extraction(html, with_metadata=True, include_images=True)
    xml_text = trafilatura.extract(html, output_format="xml", include_images=True)
    sections = sections_from_xml(xml_text or "")
    if document is None or not sections or word_count(sections) == 0:
        sys.stderr.write("article had no readable text\n")
        return 2
    if len(sections) > args.max_sections:
        sys.stderr.write(f"article exceeds {args.max_sections} sections\n")
        return 3
    if word_count(sections) > args.max_words:
        sys.stderr.write(f"article exceeds {args.max_words} words\n")
        return 3
    atomic_json(Path(args.out), {
        "title": (document.title or "").strip(),
        "author": (document.author or "").strip(),
        "published": (document.date or "").strip(),
        "site": (document.sitename or "").strip(),
        "image_url": absolute_http_url(getattr(document, "image", "") or ""),
        "url": args.url,
        "sections": sections,
    })
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
