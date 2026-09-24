import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

import synthesize

ARTICLE = {
    "title": "Test Story",
    "author": "Jane Doe",
    "sections": [
        {"heading": "Test Story", "paragraphs": ["First paragraph here."]},
        {"heading": "Background", "paragraphs": ["Second paragraph here.", "Third one here."]},
    ],
}

HAS_MLX_AUDIO = importlib.util.find_spec("mlx_audio") is not None
RUN_SMOKE = HAS_MLX_AUDIO and os.environ.get("PODS_TTS_SMOKE") == "1"


class SynthesizeTextTest(unittest.TestCase):
    def test_first_section_gets_spoken_intro_without_repeating_title(self):
        text = synthesize.section_text(ARTICLE, 0)
        self.assertTrue(text.startswith("Test Story. By Jane Doe. First paragraph here."))
        self.assertEqual(text.count("Test Story"), 1)

    def test_later_sections_speak_their_heading(self):
        text = synthesize.section_text(ARTICLE, 1)
        self.assertTrue(text.startswith("Background. Second paragraph here."))

    def test_chunks_split_at_sentence_boundaries(self):
        chunks = synthesize.chunk_text("One two. Three four. Five six.", limit=20)
        self.assertEqual(chunks, ["One two. Three four.", "Five six."])

    def test_chunks_hard_split_pathological_sentences(self):
        chunks = synthesize.chunk_text("abcdefghij", limit=4)
        self.assertEqual(chunks, ["abcd", "efgh", "ij"])

    def test_empty_text_yields_no_chunks(self):
        self.assertEqual(synthesize.chunk_text("   "), [])


@unittest.skipUnless(RUN_SMOKE, "set PODS_TTS_SMOKE=1 under uv to synthesize")
class SynthesizeSmokeTest(unittest.TestCase):
    def test_synthesizes_one_section(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            article_path = root / "article.json"
            article_path.write_text(json.dumps({
                "title": "Smoke", "author": "",
                "sections": [{"heading": "", "paragraphs": ["Hello world."]}],
            }), encoding="utf-8")
            out_dir = root / "audio"
            code = synthesize.main(["--article", str(article_path), "--out-dir", str(out_dir)])
            self.assertEqual(code, 0)
            manifest = json.loads((out_dir / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["voice"], "af_heart")
            self.assertEqual(len(manifest["sections"]), 1)
            self.assertGreater(manifest["sections"][0]["duration"], 0)
            self.assertTrue((out_dir / "section-000.wav").is_file())


if __name__ == "__main__":
    unittest.main()
