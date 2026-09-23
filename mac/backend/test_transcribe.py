import subprocess
import tempfile
import unittest
from pathlib import Path

from transcribe import decode_for_dictation, group_words, normalize_words


class WordTests(unittest.TestCase):
    def test_overlap_and_sentence_boundaries(self):
        words = [{"word": "Hello.", "start": 0, "end": 1},
                 {"word": "Next", "start": .9, "end": 1.5},
                 {"word": "sentence", "start": 1.5, "end": 2}]
        result = group_words(words)
        self.assertEqual([s["text"] for s in result], ["Hello.", "Next sentence"])
        self.assertEqual(result[1]["start"], 1)

    def test_invalid_times_fail(self):
        with self.assertRaises(ValueError):
            normalize_words([{"word": "bad", "start": float("nan"), "end": 1}])

    def test_empty_transcript_fails(self):
        with self.assertRaises(ValueError):
            group_words([])

    def test_dictation_decodes_webm_when_the_container_has_no_duration(self):
        if shutil_which("ffmpeg") is None or shutil_which("ffprobe") is None:
            self.skipTest("ffmpeg is required")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "note.webm"
            subprocess.run(
                ["ffmpeg", "-hide_banner", "-y", "-f", "lavfi", "-i", "sine=frequency=220:duration=2",
                 "-c:a", "libopus", "-b:a", "32k", "-f", "webm", "-live", "1", str(source)],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            probed = subprocess.check_output(
                ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(source)],
            )
            with self.assertRaises(ValueError):
                float(probed)
            wav = root / "note.wav"
            decode_for_dictation(source, wav)
            duration = float(subprocess.check_output(
                ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(wav)],
            ))
            self.assertAlmostEqual(duration, 2.0, delta=0.1)


def shutil_which(name):
    from shutil import which
    return which(name)


if __name__ == "__main__":
    unittest.main()
