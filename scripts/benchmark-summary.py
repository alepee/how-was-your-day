#!/usr/bin/env python3
"""Run the real Swift summary workflow without touching the app store or audio.

Uses an already loaded loopback model. Never loads/unloads models. All run
artifacts go to an ignored build directory. RSS is sampled, not GPU allocation.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import time
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "benchmarks/summary/synthetic"



class RUsageInfoV2(ctypes.Structure):
    # Darwin sys/resource.h rusage_info_v2, RUSAGE_INFO_V2 = 2.
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins",
        "wired_size", "resident_size", "phys_footprint", "proc_start_abstime",
        "proc_exit_abstime", "child_user_time", "child_system_time", "child_pkg_idle_wkups",
        "child_interrupt_wkups", "child_pageins", "child_elapsed_abstime",
        "diskio_bytesread", "diskio_byteswritten")]


def physical_footprint(pid):
    try:
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        call = library.proc_pid_rusage
        call.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        call.restype = ctypes.c_int
        info = RUsageInfoV2()
        if call(pid, 2, ctypes.byref(info)) == 0:
            return info.phys_footprint
    except OSError:
        pass
    return None

def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def process_table():
    result = subprocess.run(["ps", "-axo", "pid=,ppid=,rss=,comm="], text=True, capture_output=True, check=True)
    table = {}
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) == 4:
            pid, parent, rss, executable = fields
            table[int(pid)] = (int(parent), int(rss) * 1024, executable)
    return table


def descendants(table, roots):
    selected = set(roots) & table.keys()
    while True:
        more = {pid for pid, row in table.items() if row[0] in selected}
        if more <= selected:
            return selected
        selected |= more


def memory_sample(table, benchmark_pid=None, server_pids=None, app_pids=None):
    if server_pids:
        server = descendants(table, server_pids)
        mode = "explicit_process_trees"
    else:
        roots = {pid for pid, row in table.items()
                 if any(value in row[2].lower() for value in (".lmstudio/", "lm studio", "llmster"))}
        server = descendants(table, roots)
        mode = "auto_lmstudio_including_gui"
    benchmark = descendants(table, {benchmark_pid}) if benchmark_pid else set()
    apps = descendants(table, app_pids or set())
    def group(pids):
        processes = [{"pid": pid, "rss_bytes": table[pid][1], "physical_footprint_bytes": physical_footprint(pid),
                      "executable": table[pid][2]} for pid in sorted(pids)]
        measured = [row["physical_footprint_bytes"] for row in processes if row["physical_footprint_bytes"] is not None]
        return {"rss_bytes": sum(table[pid][1] for pid in pids),
                "physical_footprint_bytes": sum(measured) if len(measured) == len(processes) else None,
                "physical_footprint_measured_processes": len(measured), "processes": processes}
    return {"server": group(server), "benchmark": group(benchmark), "app": group(apps), "server_selection": mode}


def model_metadata(endpoint, model):
    parsed = urllib.parse.urlsplit(endpoint)
    url = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, "/api/v1/models", "", ""))
    try:
        # Disable environment proxies for this local read.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(url, timeout=5) as response:
            body = json.load(response)
        models = body.get("models", body.get("data", []))
        selected = [item for item in models if model in (item.get("key"), item.get("id"), item.get("model"))
                    or any(instance.get("id") == model for instance in item.get("loaded_instances", []))]
        return {"source": url, "matching_models": selected, "matched": bool(selected)}
    except Exception as error:
        return {"source": url, "error": str(error)}


def validate_recording(path):
    recording = json.loads(path.read_text())
    assert recording.get("segments"), "Recording has no segments"
    ids = [row["id"] for row in recording["segments"]]
    assert len(ids) == len(set(ids)), "Duplicate segment IDs"
    assert all(row["end"] >= row["start"] and row["source"] in ("mic", "system") for row in recording["segments"])
    return {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "segments": len(ids),
            "text_characters": sum(len(row["text"]) for row in recording["segments"]),
            "duration_seconds": recording["duration"]}



def validate_cache_seed(seed, suite, recordings):
    if seed is None:
        return None
    if suite or len(recordings) != 1:
        raise ValueError("--cache-seed requires exactly one --recording and cannot be used with --suite")
    if seed.is_symlink() or not seed.is_dir():
        raise ValueError("--cache-seed must be an existing non-symlink directory")
    return seed.resolve()


def copy_cache_seed(seed, destination):
    """Copy only direct, regular SHA-256-named JSON entries, never symlinks."""
    if seed.is_symlink() or not seed.is_dir():
        raise ValueError("Cache seed must be an existing non-symlink directory")
    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    copied, skipped = [], []
    for entry in sorted(seed.iterdir()):
        if not re.fullmatch(r"[0-9a-fA-F]{64}\.json", entry.name):
            skipped.append(entry.name)
            continue
        try:
            # O_NOFOLLOW and fstat also reject a file swapped for a symlink
            # between enumeration and opening. No nested directory is traversed.
            descriptor = os.open(entry, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(descriptor, "rb") as stream:
                if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                    skipped.append(entry.name)
                    continue
                data = stream.read()
            json.loads(data)
        except (OSError, ValueError, UnicodeError):
            skipped.append(entry.name)
            continue
        target = destination / entry.name
        descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
        copied.append({"name": entry.name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    return {"directory": str(seed.resolve()), "copied_entries": copied,
            "copied_count": len(copied), "skipped_entries": skipped}

def run_case(path, output, args):
    output.mkdir(parents=True, exist_ok=False)
    input_info = validate_recording(path)
    seed = getattr(args, "cache_seed", None)
    seed_info = copy_cache_seed(seed, output / "cache") if seed is not None else None
    if seed is not None:
        print("Resumed run: copied cache entries; elapsed time is not comparable with a fresh run.", flush=True)
    env = dict(os.environ, DEVELOPER_DIR=args.developer_dir,
               HWYD_SUMMARY_RECORDING=str(path), HWYD_SUMMARY_OUTPUT=str(output),
               HWYD_LIVE_LLM_MODEL=args.model, HWYD_LIVE_LLM_URL=args.endpoint,
               HWYD_SUMMARY_INPUT_CHARACTER_LIMIT=str(args.input_characters))
    if args.reasoning_effort is not None:
        env["HWYD_LIVE_LLM_REASONING_EFFORT"] = args.reasoning_effort
    else:
        env.pop("HWYD_LIVE_LLM_REASONING_EFFORT", None)
    command = ["swift", "test", "--package-path", str(ROOT / "Packages/HWYDCore"),
               "--filter", "SummaryWorkflowTests.testRealRecordingWhenExplicitlyRequested"]
    if args.skip_build:
        command.insert(2, "--skip-build")
    before = memory_sample(process_table(), server_pids=set(args.server_pid), app_pids=set(args.app_pid))
    report = {"run_type": "resumed" if seed is not None else "fresh",
              "cache_seed": str(seed.resolve()) if seed is not None else None,
              "cache_seed_copy": seed_info,
              "timing_comparable_with_fresh": seed is None,
              "model": args.model, "endpoint": args.endpoint, "input": input_info,
              "input_path": str(path), "input_character_limit": args.input_characters,
              "reasoning_effort": args.reasoning_effort,
              "quantization_label": args.quantization, "loaded_context_tokens_label": args.context_tokens,
              "model_metadata_before": model_metadata(args.endpoint, args.model), "baseline": before,
              "sample_interval_seconds": args.sample_interval, "command": command,
              "quality": {"status": "not_reviewed", "note": "Successful JSON is not a quality pass."},
              "limitations": ["Sampled RSS can miss peaks and double-count shared pages.",
                              "RSS does not equal Metal allocation or macOS physical footprint.",
                              "Physical footprint uses Darwin proc_pid_rusage; inaccessible process samples are null.",
                              "Process-group sums are comparative metrics, not exact system-wide unique memory.",
                              "Auto server discovery includes LM Studio GUI and all detected model workers.",
                              "Wall time includes Swift test startup and compilation unless --skip-build.",
                              "Memory and timing comparisons require one loaded model and no competing inference."]}
    if seed is not None:
        report["limitations"].append("Resumed run: cached steps skip inference; timing is not comparable with a fresh run.")
    # Persist provenance before execution, even if the runner is interrupted externally.
    write_json(output / "benchmark.json", dict(report, status="running"))
    start = time.monotonic()
    peaks = {name: before[name]["rss_bytes"] for name in ("server", "benchmark", "app")}
    physical_peaks = {name: before[name]["physical_footprint_bytes"] for name in peaks}
    status = "failed"
    with (output / "swift-test.log").open("w") as log, (output / "memory.jsonl").open("w") as samples:
        process = subprocess.Popen(command, env=env, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            while True:
                sample = memory_sample(process_table(), process.pid, set(args.server_pid), set(args.app_pid))
                sample["elapsed_seconds"] = time.monotonic() - start
                samples.write(json.dumps(sample) + "\n")
                samples.flush()
                for name in peaks:
                    peaks[name] = max(peaks[name], sample[name]["rss_bytes"])
                    physical = sample[name]["physical_footprint_bytes"]
                    if physical is not None:
                        physical_peaks[name] = max(physical_peaks[name] or 0, physical)
                code = process.poll()
                if code is not None:
                    status = "passed" if code == 0 and (output / "result.json").exists() else "failed"
                    break
                if sample["elapsed_seconds"] >= args.timeout:
                    status = "timeout"
                    break
                time.sleep(args.sample_interval)
        except KeyboardInterrupt:
            status = "interrupted"
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
    log_text = (output / "swift-test.log").read_text()
    report.update(status=status, exit_code=process.returncode, wall_seconds=time.monotonic() - start,
                  sampled_peak_rss_bytes=peaks, sampled_peak_physical_footprint_bytes=physical_peaks,
                  benchmark_progress=re.findall(r"BENCHMARK [^\n]+", log_text),
                  source_unchanged=input_info["sha256"] == hashlib.sha256(path.read_bytes()).hexdigest(),
                  model_metadata_after=model_metadata(args.endpoint, args.model))
    timing = output / "timing.txt"
    if timing.exists():
        report["workflow_timing"] = timing.read_text()
    report["quality"]["rubric"] = str(FIXTURES / (path.stem + ".expected.json")) if path.parent == FIXTURES else None
    write_json(output / "benchmark.json", report)
    print(f"{path.stem}: {status}; {report['wall_seconds']:.1f}s; server sampled RSS {peaks['server'] / 2**30:.2f} GiB", flush=True)
    return status == "passed"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model")
    parser.add_argument("--endpoint", default="http://127.0.0.1:1234/v1")
    parser.add_argument("--recording", type=Path, action="append", default=[], help="Private Recording JSON; may repeat")
    parser.add_argument("--suite", action="store_true", help="Run FR, EN and mixed synthetic fixtures sequentially")
    parser.add_argument("--output", type=Path, help="New run directory under build/")
    parser.add_argument("--cache-seed", type=Path, help="Resume one --recording from a prior cache directory; not a fresh timing run")
    parser.add_argument("--input-characters", type=int, default=24000)
    parser.add_argument("--server-pid", type=int, action="append", default=[], help="Model worker PID; includes descendants; may repeat")
    parser.add_argument("--app-pid", type=int, action="append", default=[], help="Optional HWYD PID; includes descendants")
    parser.add_argument("--reasoning-effort", help="Optional provider-specific reasoning_effort, e.g. none")
    parser.add_argument("--quantization", help="User-supplied label, not inferred")
    parser.add_argument("--context-tokens", type=int, help="Loaded server context, label only; does not configure it")
    parser.add_argument("--sample-interval", type=float, default=0.5)
    parser.add_argument("--timeout", type=float, default=3600)
    parser.add_argument("--developer-dir", default="/Applications/Xcode.app/Contents/Developer")
    parser.add_argument("--skip-build", action="store_true", help="Use previously built Swift tests")
    parser.add_argument("--prepare-only", action="store_true", help="Validate fixture JSON without network or inference")
    args = parser.parse_args()
    try:
        args.cache_seed = validate_cache_seed(args.cache_seed, args.suite, args.recording)
    except ValueError as error:
        parser.error(str(error))
    paths = ([FIXTURES / f"{name}.json" for name in ("fr", "en", "mixed")] if args.suite else []) + [p.resolve() for p in args.recording]
    if not paths:
        parser.error("Choose --suite and/or --recording")
    if args.prepare_only:
        for path in paths:
            print(path.name, json.dumps(validate_recording(path)))
        return
    if not args.model or not args.output:
        parser.error("--model and --output are required for inference")
    endpoint = urllib.parse.urlsplit(args.endpoint)
    if endpoint.scheme not in ("http", "https") or endpoint.hostname not in ("localhost", "127.0.0.1", "::1") or endpoint.username or endpoint.password:
        parser.error("Only loopback endpoints without embedded credentials are supported")
    if args.input_characters < 4000 or args.sample_interval < 0.1 or args.timeout <= 0:
        parser.error("Invalid input budget, sample interval or timeout")
    args.output = args.output.resolve()
    if not args.output.is_relative_to(ROOT / "build"):
        parser.error("Run artifacts must be under the ignored build/ directory")
    args.output.mkdir(parents=True, exist_ok=False)
    results = []
    for index, path in enumerate(paths):
        results.append(run_case(path, args.output / f"{index + 1:02d}-{path.stem}", args))
    raise SystemExit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
