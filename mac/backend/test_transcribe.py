import unittest
from transcribe import group_words, normalize_words


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


if __name__ == "__main__":
    unittest.main()
