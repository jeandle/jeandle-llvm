#!/usr/bin/env python3
"""Profile the JavaType cache without conflating correctness and timing.

This runner consumes the workloads and identity helpers from
benchmark-java-type-cache-design.py. It keeps four cache modes on one frozen
opt binary and separates unscoped process timing from perf stat and call-stack
sampling. Every external command is represented as an argument array.
"""

import argparse
import csv
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import random
import re
import shlex
import statistics
import subprocess
import time


HERE = Path(__file__).resolve().parent
BENCHMARK = HERE / "benchmark-java-type-cache-design.py"
PROFILER = Path(__file__)
MODES = {
    "origin": ["-jeandle-disable-java-type-cache"],
    "full": ["-jeandle-java-type-force-full-invalidation"],
    "s0": ["-jeandle-java-type-force-base-scan-invalidation"],
    "s1": [],
}
CASE_SPECS = {
    "deep-static": ("static", 16, 64),
    "wide-static": ("static", 64, 16),
    "leaf-static": ("static", 32, 0),
    "tce-cha": ("tce-cha", 16, 64),
    "virtual-cfg": ("virtual", 32, 0),
}
L2_SPECS = {
    "cff-cache-reuse": {
        "fixture": "llvm/test/Jeandle/constant-field-folding/cache-reuse.ll",
        "cblog": "llvm/test/Jeandle/constant-field-folding/Inputs/cache-reuse.cblog",
        "function": "reuse",
        "passes": "constant-field-folding",
    }
}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_benchmark():
    spec = importlib.util.spec_from_file_location("javatype_benchmark", BENCHMARK)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


B = load_benchmark()


def read_json(path, default=None):
    if not path.exists():
        return default
    return json.loads(path.read_text())


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def command_record(command):
    return {
        "argv": [str(item) for item in command],
        "shell": shlex.join(str(item) for item in command),
    }


def run(command, stderr_path, stdout_path=None):
    started = time.perf_counter_ns()
    completed = subprocess.run(
        [str(item) for item in command],
        stdout=subprocess.PIPE if stdout_path else subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        check=False,
    )
    elapsed_ns = time.perf_counter_ns() - started
    stderr_path.parent.mkdir(parents=True, exist_ok=True)
    stderr_path.write_bytes(completed.stderr)
    if stdout_path:
        stdout_path.parent.mkdir(parents=True, exist_ok=True)
        stdout_path.write_bytes(completed.stdout)
    if completed.returncode:
        raise RuntimeError(
            f"command failed with {completed.returncode}; see {stderr_path}: "
            + shlex.join(str(item) for item in command)
        )
    return completed, elapsed_ns


def measure(command, stderr_path):
    """Run one child and return process-local wall time plus wait4 resource use."""
    started = time.perf_counter_ns()
    stderr_path.parent.mkdir(parents=True, exist_ok=True)
    with stderr_path.open("wb") as stderr:
        process = subprocess.Popen(
            [str(item) for item in command],
            stdout=subprocess.DEVNULL,
            stderr=stderr,
        )
        _, status, usage = os.wait4(process.pid, 0)
        process.returncode = os.waitstatus_to_exitcode(status)
    elapsed_ns = time.perf_counter_ns() - started
    if process.returncode:
        raise RuntimeError(
            f"command failed with {process.returncode}; see {stderr_path}: "
            + shlex.join(str(item) for item in command)
        )
    return elapsed_ns, usage


def parse_semicolon_metrics(text):
    metrics = {}
    for line in text.splitlines():
        fields = line.split(";")
        if len(fields) < 3:
            continue
        value, event = fields[0].strip(), fields[2].strip()
        try:
            number = float(value)
        except ValueError:
            continue
        metrics[event] = {
            "value": number,
            "unit": fields[1].strip(),
            "enabled_pct": fields[3].strip() if len(fields) > 3 else "",
            "running_pct": fields[4].strip() if len(fields) > 4 else "",
        }
    return metrics


def source_identity(source, opt):
    source_record = B.source_identity(source)
    patch = source_record["patch"]
    return {
        "head": source_record["head"],
        "status": source_record["status"].splitlines(),
        "source_patch_sha256": hashlib.sha256(patch).hexdigest(),
        "benchmark_sha256": sha256(BENCHMARK),
        "profiler_sha256": sha256(PROFILER),
        "opt_sha256": sha256(opt),
    }, patch


def ensure_identity(manifest, phase):
    expected = manifest["identity"]
    current, _ = source_identity(
        Path(manifest["source"]["root"]), Path(manifest["opt"])
    )
    if current != expected:
        raise RuntimeError(
            f"source or binary identity changed during {phase}: "
            f"expected {expected}, found {current}"
        )


def load_manifest(out):
    manifest = read_json(out / "manifest.json")
    if not manifest:
        raise RuntimeError("run prepare first")
    return manifest


def item_command(manifest, item, mode, *, verify=False, stats=False, output=False):
    command = [manifest["opt"]]
    if output:
        command.extend(["-S", "-verify-each"])
    else:
        command.append("-disable-output")
    pipeline = (
        f"-passes=function({item['passes']}),print<java-type-analysis-summary>"
        if stats
        else f"-passes=function({item['passes']})"
    )
    command.extend(
        [
            pipeline,
            "-jeandle-java-type-stats=true"
            if stats
            else "-jeandle-java-type-stats=false",
            "-jeandle-verify-java-type-cache=true"
            if verify
            else "-jeandle-verify-java-type-cache=false",
            f"-jeandle-vm-callback-log={item['cblog']}",
            item["ir"],
            *MODES[mode],
        ]
    )
    return command


def case_command(manifest, case, mode, **kwargs):
    return item_command(manifest, manifest["cases"][case], mode, **kwargs)


def prepare(args):
    out = args.out.resolve()
    opt = args.opt.resolve()
    source = args.source_root.resolve()
    identity, patch = source_identity(source, opt)
    manifest = read_json(out / "manifest.json")
    if manifest:
        if manifest["identity"] != identity:
            raise RuntimeError("existing output belongs to a different source/binary")
    else:
        out.mkdir(parents=True, exist_ok=False)
        (out / "source.patch").write_bytes(patch)
        manifest = {
            "schema": 1,
            "created_unix": time.time(),
            "source": {
                "root": str(source),
                "head": identity["head"],
                "status": identity["status"],
            },
            "opt": str(opt),
            "identity": identity,
            "cpu": args.cpu,
            "seed": args.seed,
            "functions": args.functions,
            "cases": {},
            "modes": MODES,
            "environment": {
                "platform": platform.platform(),
                "python": platform.python_version(),
                "uname": platform.uname()._asdict(),
                "affinity": sorted(os.sched_getaffinity(0))
                if hasattr(os, "sched_getaffinity")
                else None,
            },
        }
    cases = args.case or list(CASE_SPECS)
    for name in cases:
        kind, sites, depth = CASE_SPECS[name]
        case_dir = out / "inputs" / name
        case_dir.mkdir(parents=True, exist_ok=True)
        ir, cblog, passes = B.generate(
            case_dir, name, kind, args.functions, sites, depth
        )
        input_identity = {
            "ir": str(ir),
            "ir_sha256": sha256(ir),
            "cblog": str(cblog),
            "cblog_sha256": sha256(cblog),
            "passes": passes,
            "kind": kind,
            "functions": args.functions,
            "sites_per_function": sites,
            "select_depth": depth,
        }
        old = manifest["cases"].get(name)
        if old and old != input_identity:
            raise RuntimeError(f"existing case identity differs for {name}")
        manifest["cases"][name] = input_identity
        write_json(out / "manifest.json", manifest)
    print(f"prepared {len(cases)} case(s) in {out}")


def correctness(args):
    out = args.out.resolve()
    manifest = load_manifest(out)
    ensure_identity(manifest, "correctness setup")
    report = read_json(out / "correctness.json", {})
    for case in args.case or list(manifest["cases"]):
        kind, sites, depth = CASE_SPECS[case]
        root = out / "correctness" / "inputs" / case
        root.mkdir(parents=True, exist_ok=True)
        ir, cblog, passes = B.generate(
            root, case, kind, args.correctness_functions, sites, depth
        )
        case_item = {
            "passes": passes,
            "cblog": str(cblog),
            "ir": str(ir),
            "functions": args.correctness_functions,
            "sites_per_function": sites,
        }
        hashes = {}
        counts = {}
        for mode in args.mode or list(MODES):
            stem = out / "correctness" / case / mode
            original_item = manifest["cases"][case]
            manifest["cases"][case] = case_item
            command = case_command(
                manifest, case, mode, verify=True, stats=True, output=True
            )
            manifest["cases"][case] = original_item
            result, _ = run(command, Path(f"{stem}.stderr"), Path(f"{stem}.ll"))
            body = Path(f"{stem}.ll").read_bytes()
            hashes[mode] = hashlib.sha256(body).hexdigest()
            counts[mode] = len(
                re.findall(rb"invoke hotspotcc .* @Optimized_target\(", body)
            )
            Path(f"{stem}.command.json").write_text(
                json.dumps(command_record(command), indent=2) + "\n"
            )
            if not (stem.with_suffix(".stderr")).stat().st_size:
                raise RuntimeError(f"{case}/{mode}: diagnostics emitted no statistics")
        expected = args.correctness_functions * sites
        if len(set(hashes.values())) != 1:
            raise RuntimeError(f"{case}: modes emitted different IR")
        if any(count != expected for count in counts.values()):
            raise RuntimeError(
                f"{case}: transformed target count {counts}, expected {expected}"
            )
        report[case] = {
            "status": "pass",
            "functions": args.correctness_functions,
            "ir_sha256": hashes,
            "transformed_call_sites": counts,
            "expected_call_sites": expected,
        }
        write_json(out / "correctness.json", report)
        print(f"correctness {case}: pass ({expected} transformed sites)")
    ensure_identity(manifest, "correctness")


def clone_l2(source_root, spec, functions, destination):
    source_path = source_root / spec["fixture"]
    original = source_path.read_text()
    name = spec["function"]
    match = re.search(rf"define\s+[^\n]*@{re.escape(name)}\(", original)
    if not match:
        raise RuntimeError(f"cannot find function @{name} in {source_path}")
    end = original.find("\n}\n", match.end())
    if end < 0:
        raise RuntimeError(f"cannot find end of function @{name} in {source_path}")
    end += len("\n}\n")
    body = original[match.start() : end]
    clones = []
    for index in range(functions):
        clones.append(body.replace(f"@{name}(", f"@{name}{index}(", 1))
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(original[: match.start()] + "\n".join(clones) + original[end:])
    return destination


def prepare_l2(args):
    out = args.out.resolve()
    manifest = load_manifest(out)
    ensure_identity(manifest, "L2 prepare setup")
    source_root = Path(manifest["source"]["root"])
    spec = L2_SPECS[args.l2_case]
    destination = out / "inputs" / "l2" / f"{args.l2_case}.ll"
    clone_l2(source_root, spec, args.l2_functions, destination)
    cblog = source_root / spec["cblog"]
    item = {
        "ir": str(destination),
        "ir_sha256": sha256(destination),
        "cblog": str(cblog),
        "cblog_sha256": sha256(cblog),
        "passes": spec["passes"],
        "functions": args.l2_functions,
        "fixture": str(source_root / spec["fixture"]),
        "fixture_sha256": sha256(source_root / spec["fixture"]),
    }
    manifest.setdefault("l2", {})[args.l2_case] = item
    write_json(out / "manifest.json", manifest)
    print(f"prepared {args.l2_case}: {args.l2_functions} cloned functions")


def correctness_l2(args):
    out = args.out.resolve()
    manifest = load_manifest(out)
    ensure_identity(manifest, "L2 correctness setup")
    spec = L2_SPECS[args.l2_case]
    source_root = Path(manifest["source"]["root"])
    root = out / "correctness" / "inputs" / "l2"
    ir = clone_l2(
        source_root,
        spec,
        args.l2_correctness_functions,
        root / f"{args.l2_case}.ll",
    )
    item = {
        "passes": spec["passes"],
        "cblog": str(source_root / spec["cblog"]),
        "ir": str(ir),
    }
    hashes = {}
    query_counts = {}
    for mode in args.mode or list(MODES):
        stem = out / "correctness" / "l2" / args.l2_case / mode
        command = item_command(
            manifest, item, mode, verify=True, stats=True, output=True
        )
        result, _ = run(command, Path(f"{stem}.stderr"), Path(f"{stem}.ll"))
        body = Path(f"{stem}.ll").read_bytes()
        hashes[mode] = hashlib.sha256(body).hexdigest()
        matches = re.findall(
            rb"^\s+queries: (\d+)$", result.stderr, flags=re.MULTILINE
        )
        query_counts[mode] = sum(int(value) for value in matches)
        if not matches or query_counts[mode] == 0:
            raise RuntimeError(f"{args.l2_case}/{mode}: no JavaType queries observed")
    if len(set(hashes.values())) != 1:
        raise RuntimeError(f"{args.l2_case}: modes emitted different IR")
    report = read_json(out / "correctness-l2.json", {})
    report[args.l2_case] = {
        "status": "pass",
        "functions": args.l2_correctness_functions,
        "ir_sha256": hashes,
        "java_type_queries": query_counts,
    }
    write_json(out / "correctness-l2.json", report)
    ensure_identity(manifest, "L2 correctness")
    print(
        f"correctness L2 {args.l2_case}: pass; queries={query_counts}",
        flush=True,
    )


def baseline(args):
    out = args.out.resolve()
    manifest = load_manifest(out)
    ensure_identity(manifest, "baseline setup")
    rows = []
    rng = random.Random(args.seed)
    for case in args.case or list(manifest["cases"]):
        for round_index in range(-args.warmups, args.repeats):
            order = args.mode or list(MODES)
            rng.shuffle(order)
            for mode in order:
                stem = out / "baseline" / case / f"{round_index:03d}-{mode}"
                if stem.with_suffix(".json").exists():
                    rows.append(read_json(stem.with_suffix(".json")))
                    continue
                command = ["taskset", "-c", str(args.cpu)] + case_command(
                    manifest, case, mode
                )
                elapsed_ns, usage = measure(command, Path(f"{stem}.stderr"))
                row = {
                    "case": case,
                    "round": round_index,
                    "mode": mode,
                    "wall_s": elapsed_ns / 1e9,
                    "user_s": usage.ru_utime,
                    "system_s": usage.ru_stime,
                    "max_rss_kb": usage.ru_maxrss,
                    "command": command_record(command),
                }
                write_json(stem.with_suffix(".json"), row)
                rows.append(row)
        measured = [row for row in rows if row["case"] == case and row["round"] >= 0]
        print(
            f"baseline {case}: "
            + ", ".join(
                f"{mode}={statistics.median(r['user_s'] for r in measured if r['mode'] == mode):.3f}s user"
                for mode in MODES
                if any(r["mode"] == mode for r in measured)
            ),
            flush=True,
        )
    with (out / "baseline" / "samples.csv").open("w", newline="") as handle:
        fields = ["case", "round", "mode", "wall_s", "user_s", "system_s", "max_rss_kb"]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row[key] for key in fields})
    ensure_identity(manifest, "baseline")


def stat(args):
    out = args.out.resolve()
    manifest = load_manifest(out)
    ensure_identity(manifest, "stat setup")
    groups = [
        ("software", "task-clock:u,context-switches:u,cpu-migrations:u,page-faults:u"),
        ("core", "cycles:u,instructions:u,branches:u,branch-misses:u"),
    ]
    for case in args.case or list(manifest["cases"]):
        for round_index in range(args.repeats):
            for group, events in groups:
                for mode in args.mode or list(MODES):
                    stem = out / "stat" / case / f"{round_index:03d}-{mode}-{group}"
                    if stem.with_suffix(".json").exists():
                        continue
                    command = [
                        "perf",
                        "stat",
                        "-x",
                        ";",
                        "-e",
                        events,
                        "--",
                        "taskset",
                        "-c",
                        str(args.cpu),
                        *case_command(manifest, case, mode),
                    ]
                    result, _ = run(command, Path(f"{stem}.stderr"))
                    row = {
                        "case": case,
                        "round": round_index,
                        "mode": mode,
                        "group": group,
                        "events": events,
                        "metrics": parse_semicolon_metrics(
                            result.stderr.decode(errors="replace")
                        ),
                        "command": command_record(command),
                    }
                    write_json(stem.with_suffix(".json"), row)
        print(f"stat {case}: completed {args.repeats} round(s)", flush=True)
    ensure_identity(manifest, "stat")


def record(args):
    out = args.out.resolve()
    manifest = load_manifest(out)
    ensure_identity(manifest, "record setup")
    for case in args.case or list(manifest["cases"]):
        for run_index in range(args.repeats):
            for mode in args.mode or list(MODES):
                dest = out / "profiles" / case / mode / f"run-{run_index:02d}"
                success = dest / "SUCCESS"
                if success.exists():
                    continue
                dest.mkdir(parents=True, exist_ok=True)
                perf_data = dest / "perf.data"
                command = [
                    "perf",
                    "record",
                    "-e",
                    args.event,
                    "-F",
                    str(args.frequency),
                    "--call-graph",
                    args.call_graph,
                    "-o",
                    perf_data,
                    "--",
                    "taskset",
                    "-c",
                    str(args.cpu),
                    *case_command(manifest, case, mode),
                ]
                result, elapsed_ns = run(command, dest / "record.stderr")
                (dest / "record.command.json").write_text(
                    json.dumps(command_record(command), indent=2) + "\n"
                )
                reports = [
                    (
                        "self.txt",
                        [
                            "perf",
                            "report",
                            "-i",
                            perf_data,
                            "--stdio",
                            "--no-children",
                            "--show-nr-samples",
                            "--sort",
                            "comm,dso,symbol",
                        ],
                    ),
                    (
                        "inclusive.txt",
                        [
                            "perf",
                            "report",
                            "-i",
                            perf_data,
                            "--stdio",
                            "--children",
                            "--show-nr-samples",
                            "--sort",
                            "comm,dso,symbol",
                        ],
                    ),
                    (
                        "header.txt",
                        ["perf", "report", "-i", perf_data, "--header-only"],
                    ),
                    ("stacks.txt", ["perf", "script", "-i", perf_data]),
                ]
                for filename, report_command in reports:
                    run(
                        report_command,
                        dest / f"{filename}.stderr",
                        dest / filename,
                    )
                write_json(
                    dest / "run.json",
                    {
                        "case": case,
                        "mode": mode,
                        "run": run_index,
                        "elapsed_ns": elapsed_ns,
                        "perf_data_bytes": perf_data.stat().st_size,
                        "perf_data_sha256": sha256(perf_data),
                        "command": command_record(command),
                        "record_stderr": result.stderr.decode(errors="replace"),
                    },
                )
                success.write_text("profile reports generated\n")
                print(f"record {case}/{mode}/run-{run_index:02d}", flush=True)
    ensure_identity(manifest, "record")


def report(args):
    out = args.out.resolve()
    load_manifest(out)
    rows = []
    for path in sorted((out / "profiles").glob("*/*/run-*/self.txt")):
        case, mode = path.parts[-4], path.parts[-3]
        number = 0
        for line in path.read_text(errors="replace").splitlines():
            match = re.match(r"\s*([\d,.]+)\s+(.+)", line)
            if match:
                number += int(match.group(1).replace(",", ""))
        rows.append(
            {"case": case, "mode": mode, "samples": number, "path": str(path)}
        )
    write_json(
        out / "summary.json",
        {
            "profiles": rows,
            "thresholds": {
                "minimum_related_samples_per_mode": 1000,
                "minimum_repeat_profiles": 3,
                "minimum_event_running_pct": 90,
            },
            "notes": [
                "Self-report rows are sample counts, not cycle weights.",
                "JavaType-related samples must be filtered from source stacks.",
                "Review unknown, lost, throttle, stack truncation, and sampling overhead.",
            ],
        },
    )
    print(f"wrote {out / 'summary.json'}")


def parser():
    root = argparse.ArgumentParser(description=__doc__)
    root.add_argument("--out", type=Path, required=True)
    root.add_argument("--opt", type=Path, required=True)
    root.add_argument("--source-root", type=Path, required=True)
    root.add_argument("--cpu", type=int, default=16)
    root.add_argument("--seed", type=int, default=20261023)
    root.add_argument("--case", action="append", choices=sorted(CASE_SPECS))
    root.add_argument("--mode", action="append", choices=sorted(MODES))
    root.add_argument("--functions", type=int, default=2048)
    root.add_argument("--l2-case", choices=sorted(L2_SPECS), default="cff-cache-reuse")
    root.add_argument("--l2-functions", type=int, default=4096)
    sub = root.add_subparsers(dest="phase", required=True)
    sub.add_parser("prepare")
    correctness_parser = sub.add_parser("correctness")
    correctness_parser.add_argument("--correctness-functions", type=int, default=8)
    sub.add_parser("prepare-l2")
    correctness_l2_parser = sub.add_parser("correctness-l2")
    correctness_l2_parser.add_argument("--l2-correctness-functions", type=int, default=8)
    baseline_parser = sub.add_parser("baseline")
    baseline_parser.add_argument("--repeats", type=int, default=10)
    baseline_parser.add_argument("--warmups", type=int, default=3)
    stat_parser = sub.add_parser("stat")
    stat_parser.add_argument("--repeats", type=int, default=3)
    record_parser = sub.add_parser("record")
    record_parser.add_argument("--repeats", type=int, default=3)
    record_parser.add_argument("--event", default="cycles:u")
    record_parser.add_argument("--frequency", type=int, default=199)
    record_parser.add_argument("--call-graph", default="dwarf,8192")
    sub.add_parser("report")
    return root


def main():
    args = parser().parse_args()
    if args.functions < 1 or args.l2_functions < 1:
        raise SystemExit("function counts must be positive")
    {
        "prepare": prepare,
        "prepare-l2": prepare_l2,
        "correctness": correctness,
        "correctness-l2": correctness_l2,
        "baseline": baseline,
        "stat": stat,
        "record": record,
        "report": report,
    }[args.phase](args)


if __name__ == "__main__":
    main()
