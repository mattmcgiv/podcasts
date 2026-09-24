import io
import importlib.util
import json
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

import extract_article

HAS_TRAFILATURA = importlib.util.find_spec("trafilatura") is not None

FIXTURE = """<!DOCTYPE html><html><head><title>Test Story</title>
<meta name="author" content="Jane Doe">
<meta name="dcterms.date" content="2026-09-20">
<meta property="og:image" content="https://example.com/lead.jpg">
</head><body><nav>menu junk links</nav>
<article><h1>Test Story</h1>
<p>First paragraph with enough words to look like a real article body for the extractor cascade.</p>
<h2>Background</h2>
<p>Second paragraph continues the story with more detail and more words for the extractor.</p>
<p>Third paragraph wraps up this section of the test article fixture content.</p>
<h2>Ending</h2>
<p>Final paragraph concludes the miniature test article used for development.</p>
</article><footer>footer junk</footer></body></html>
"""


def run_fixture(html, *extra):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        source = root / "page.html"
        out = root / "article.json"
        source.write_text(html, encoding="utf-8")
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            code = extract_article.main(["--html", str(source), "--out", str(out),
                                         "--url", "https://example.com/story", *extra])
        payload = json.loads(out.read_text(encoding="utf-8")) if out.exists() else None
        return code, payload, stderr.getvalue()


@unittest.skipUnless(HAS_TRAFILATURA, "trafilatura not installed (run under uv)")
class ExtractArticleTest(unittest.TestCase):
    def test_extracts_sections_metadata_and_image(self):
        code, payload, _ = run_fixture(FIXTURE)
        self.assertEqual(code, 0)
        self.assertEqual(payload["title"], "Test Story")
        self.assertEqual(payload["author"], "Jane Doe")
        self.assertEqual(payload["image_url"], "https://example.com/lead.jpg")
        self.assertEqual(payload["url"], "https://example.com/story")
        self.assertEqual([s["heading"] for s in payload["sections"]], ["Test Story", "Background", "Ending"])
        self.assertEqual(len(payload["sections"][1]["paragraphs"]), 2)
        self.assertTrue(all(p["paragraphs"] for p in payload["sections"]))

    def test_empty_page_fails_without_output(self):
        code, payload, stderr = run_fixture("<!DOCTYPE html><html><head><title>Empty</title></head><body><script>var x = 1;</script></body></html>")
        self.assertEqual(code, 2)
        self.assertIsNone(payload)
        self.assertIn("no readable text", stderr)

    def test_overlong_article_fails_fast(self):
        code, _, stderr = run_fixture(FIXTURE, "--max-words", "10")
        self.assertEqual(code, 3)
        self.assertIn("exceeds 10 words", stderr)
        code, _, stderr = run_fixture(FIXTURE, "--max-sections", "1")
        self.assertEqual(code, 3)
        self.assertIn("exceeds 1 sections", stderr)

    def test_rejects_non_http_images(self):
        code, payload, _ = run_fixture(FIXTURE.replace("https://example.com/lead.jpg", "/lead.jpg"))
        self.assertEqual(code, 0)
        self.assertEqual(payload["image_url"], "")


if __name__ == "__main__":
    unittest.main()
