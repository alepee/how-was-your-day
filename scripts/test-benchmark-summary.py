#!/usr/bin/env python3
"""No server, model, microphone or real recording required."""
import importlib.util
from pathlib import Path
import unittest
import tempfile
import os
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("benchmark_summary", Path(__file__).with_name("benchmark-summary.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BenchmarkTests(unittest.TestCase):
    def test_descendants_not_unrelated_processes(self):
        table = {1: (0, 10, "LM Studio"), 2: (1, 20, "worker"), 3: (2, 30, "backend"), 4: (0, 40, "other")}
        self.assertEqual(module.descendants(table, {1}), {1, 2, 3})
        self.assertEqual(module.descendants(table, {99}), set())

    def test_auto_groups_and_physical_footprint(self):
        table = {1: (0, 10, "/Applications/LM Studio.app/LM Studio"), 2: (1, 20, "python"),
                 3: (0, 30, "swift"), 4: (3, 40, "xctest"), 5: (0, 50, "HWYD")}
        with patch.object(module, "physical_footprint", side_effect=lambda pid: pid * 100):
            sample = module.memory_sample(table, 3, app_pids={5})
        self.assertEqual(sample["server"]["rss_bytes"], 30)
        self.assertEqual(sample["server"]["physical_footprint_bytes"], 300)
        self.assertEqual(sample["benchmark"]["rss_bytes"], 70)
        self.assertEqual(sample["app"]["rss_bytes"], 50)

    def test_unavailable_footprint_not_reported_as_zero(self):
        with patch.object(module, "physical_footprint", return_value=None):
            sample = module.memory_sample({1: (0, 20, "worker")}, server_pids={1})
        self.assertIsNone(sample["server"]["physical_footprint_bytes"])

    def test_run_records_output_and_keeps_input_unchanged(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            fake_swift = directory / "swift"
            fake_swift.write_text("#!/usr/bin/env python3\nimport os,json,pathlib\np=pathlib.Path(os.environ['HWYD_SUMMARY_OUTPUT'])\n(p/'result.json').write_text('{}')\n(p/'timing.txt').write_text('Elapsed seconds: 0.01')\nprint('BENCHMARK test 1/1 cached=false')\n")
            fake_swift.chmod(0o755)
            args = SimpleNamespace(developer_dir="unused", model="fixture", endpoint="http://127.0.0.1:1234/v1",
                                   input_characters=24000, skip_build=True, server_pid=[], app_pid=[],
                                   quantization="test", context_tokens=16000, sample_interval=0.1, timeout=5)
            with patch.dict(os.environ, {"PATH": str(directory) + os.pathsep + os.environ["PATH"]}), \
                 patch.object(module, "model_metadata", return_value={"matched": False}):
                self.assertTrue(module.run_case(module.FIXTURES / "fr.json", directory / "result", args))
            report = module.json.loads((directory / "result/benchmark.json").read_text())
            self.assertEqual(report["status"], "passed")
            self.assertTrue(report["source_unchanged"])
            self.assertEqual(report["quality"]["status"], "not_reviewed")
            self.assertTrue(report["sampled_peak_rss_bytes"]["benchmark"] > 0)

    def test_public_fixtures_and_ground_truth_sources(self):
        for name in ("fr", "en", "mixed"):
            path = module.FIXTURES / (name + ".json")
            self.assertEqual(module.validate_recording(path)["segments"], 18)
            recording = module.json.loads(path.read_text())
            rubric = module.json.loads(path.with_name(name + ".expected.json").read_text())
            ids = {segment["id"] for segment in recording["segments"]}
            for claim in rubric["decisions"] + rubric["actions"]:
                self.assertTrue(set(claim["sources"]) <= ids)
            self.assertTrue(recording["isDemo"])
            self.assertFalse(recording["audioChunks"])


if __name__ == "__main__":
    unittest.main()
