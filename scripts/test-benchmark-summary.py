#!/usr/bin/env python3
"""No server, model, microphone or real recording required."""
import contextlib
import importlib.util
import io
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
                                   quantization="test", context_tokens=16000, reasoning_effort="none", sample_interval=0.1, timeout=5,
                                   schema_order="alphabetical")
            with patch.dict(os.environ, {"PATH": str(directory) + os.pathsep + os.environ["PATH"]}), \
                 patch.object(module, "model_metadata", return_value={"matched": False}):
                self.assertTrue(module.run_case(module.FIXTURES / "fr.json", directory / "result", args))
            report = module.json.loads((directory / "result/benchmark.json").read_text())
            self.assertEqual(report["status"], "passed")
            self.assertTrue(report["source_unchanged"])
            self.assertEqual(report["quality"]["status"], "not_reviewed")
            self.assertTrue(report["sampled_peak_rss_bytes"]["benchmark"] > 0)
            self.assertEqual(report["run_type"], "fresh")
            self.assertEqual(report["schema_order"], "alphabetical")
            self.assertTrue(report["timing_comparable_with_fresh"])
            seed = directory / "seed"
            seed.mkdir()
            entry = seed / ("a" * 64 + ".json")
            entry.write_text('{"overview":"cached fixture"}')
            args.cache_seed = seed
            with patch.dict(os.environ, {"PATH": str(directory) + os.pathsep + os.environ["PATH"]}), \
                 patch.object(module, "model_metadata", return_value={"matched": False}):
                self.assertTrue(module.run_case(module.FIXTURES / "fr.json", directory / "resumed", args))
            resumed = module.json.loads((directory / "resumed/benchmark.json").read_text())
            self.assertEqual(resumed["run_type"], "resumed")
            self.assertFalse(resumed["timing_comparable_with_fresh"])
            self.assertEqual(resumed["cache_seed"], str(seed.resolve()))
            self.assertEqual(resumed["cache_seed_copy"]["copied_count"], 1)
            self.assertEqual((directory / "resumed/cache" / entry.name).read_bytes(), entry.read_bytes())
            self.assertTrue(any("not comparable" in value for value in resumed["limitations"]))

    def test_schema_order_is_passed_to_swift_and_recorded(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            fake_swift = directory / "swift"
            fake_swift.write_text("#!/usr/bin/env python3\nimport os,pathlib\np=pathlib.Path(os.environ['HWYD_SUMMARY_OUTPUT'])\n(p/'result.json').write_text('{}')\n(p/'order.txt').write_text(os.environ['HWYD_LIVE_LLM_SCHEMA_ORDER'])\n")
            fake_swift.chmod(0o755)
            base = dict(developer_dir="unused", model="fixture", endpoint="http://127.0.0.1:1234/v1", input_characters=24000,
                        skip_build=True, server_pid=[], app_pid=[], quantization=None, context_tokens=None,
                        reasoning_effort=None, sample_interval=0.1, timeout=5)
            for name, kwargs, expected in (("default", {}, "alphabetical"), ("narrative", {"schema_order": "narrative-first"}, "narrative-first")):
                with patch.dict(os.environ, {"PATH": str(directory) + os.pathsep + os.environ["PATH"], "HWYD_LIVE_LLM_SCHEMA_ORDER": "ambient"}), \
                     patch.object(module, "model_metadata", return_value={"matched": False}):
                    self.assertTrue(module.run_case(module.FIXTURES / "fr.json", directory / name, SimpleNamespace(**base, **kwargs)))
                report = module.json.loads((directory / name / "benchmark.json").read_text())
                self.assertEqual(report["schema_order"], expected)
                self.assertEqual((directory / name / "order.txt").read_text(), expected)

    def test_schema_order_option_defaults_to_alphabetical_and_rejects_unknown(self):
        def parse(*extra):
            with patch("sys.argv", ["benchmark-summary.py", "--suite", "--prepare-only", *extra]), \
                 patch.object(module, "validate_recording", return_value={}), contextlib.redirect_stdout(io.StringIO()):
                module.main()
        parse()
        parse("--schema-order", "narrative-first")
        with self.assertRaises(SystemExit):
            parse("--schema-order", "reverse")

    def test_cache_seed_rejects_suite_multi_case_and_symlink_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            seed = Path(temporary)
            with self.assertRaises(ValueError):
                module.validate_cache_seed(seed, True, [Path("one.json")])
            with self.assertRaises(ValueError):
                module.validate_cache_seed(seed, False, [Path("one.json"), Path("two.json")])
            with self.assertRaises(ValueError):
                module.validate_cache_seed(seed, False, [])
            link = seed / "linked"
            link.symlink_to(seed, target_is_directory=True)
            with self.assertRaises(ValueError):
                module.validate_cache_seed(link, False, [Path("one.json")])
            self.assertEqual(module.validate_cache_seed(seed, False, [Path("one.json")]), seed.resolve())

    def test_cache_seed_only_copies_regular_hash_named_json(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            seed = root / "seed"
            seed.mkdir()
            valid = seed / ("a" * 64 + ".json")
            valid.write_text('{"overview":"fixture"}')
            (seed / "notes.json").write_text("{}")
            (seed / ("b" * 64 + ".json")).symlink_to(valid)
            (seed / ("c" * 64 + ".json")).write_text("not JSON")
            (seed / ("d" * 64 + ".json")).mkdir()
            os.mkfifo(seed / ("e" * 64 + ".json"))
            result = module.copy_cache_seed(seed, root / "destination")
            self.assertEqual(result["copied_count"], 1)
            self.assertEqual(result["copied_entries"][0]["name"], valid.name)
            self.assertEqual(len(result["skipped_entries"]), 5)
            self.assertEqual([p.name for p in (root / "destination").iterdir()], [valid.name])
            self.assertEqual((root / "destination" / valid.name).stat().st_mode & 0o777, 0o600)
            self.assertFalse((root / "destination" / valid.name).is_symlink())
            (root / "destination" / valid.name).write_text("changed")
            self.assertEqual(valid.read_text(), '{"overview":"fixture"}')

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
