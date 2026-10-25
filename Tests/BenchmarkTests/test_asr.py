import importlib.util
import unittest
from pathlib import Path
spec = importlib.util.spec_from_file_location("evaluate_asr", Path(__file__).parents[2]/"scripts/evaluate-asr.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class MetricsTests(unittest.TestCase):
    def test_edits(self):
        self.assertEqual(module.wer(["a", "b", "c"], ["a", "x", "c"])["substitutions"], 1)
        self.assertEqual(module.wer(["a", "b"], ["a"])["deletions"], 1)
        self.assertEqual(module.wer(["a"], ["a", "b"])["insertions"], 1)
        self.assertIsNone(module.wer([], ["a"])["wer"])
    def test_normalization(self):
        self.assertEqual(module.tokens("L’été, C’EST bien !"), ["l", "été", "c", "est", "bien"])
    def test_track_separation(self):
        reference = dict(benchmark_schema=1, consent_confirmed=True, words=[dict(text="bonjour", start=0, end=1, speaker="speaker-1", source="mic")])
        scores = module.evaluate(reference, {"segments":[dict(text="bonjour", start=0, source="system")]})["tracks"]
        self.assertEqual(scores["mic"]["deletions"], 1)
        self.assertEqual(scores["system"]["insertions"], 1)
        reference["consent_confirmed"] = False
        with self.assertRaises(ValueError): module.evaluate(reference, {"segments":[]})
