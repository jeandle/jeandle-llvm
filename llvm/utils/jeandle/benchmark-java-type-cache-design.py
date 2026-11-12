#!/usr/bin/env python3
"""Compare JavaType cache designs on correctness-independent workloads.

This harness deliberately separates diagnostics from timed runs. Diagnostic
runs enable statistics and collect structural counters; timed runs disable
statistics, verification, and other observers. Every mode must produce the
same optimized IR on complete, acyclic workloads before timing starts.
"""

import argparse
import hashlib
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


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git_output(root, *args):
    result = subprocess.run(
        ["git", *args], cwd=root, capture_output=True, text=True, check=True
    )
    return result.stdout


def untracked_source(root):
    names = [
        name
        for name in git_output(
            root, "ls-files", "--others", "--exclude-standard"
        ).splitlines()
        if name
    ]
    files = []
    patch_parts = []
    for name in names:
        path = root / name
        if not path.is_file():
            continue
        content = path.read_bytes()
        files.append(
            {
                "path": name,
                "sha256": hashlib.sha256(content).hexdigest(),
                "size": len(content),
            }
        )
        result = subprocess.run(
            [
                "git",
                "diff",
                "--binary",
                "--no-ext-diff",
                "--no-index",
                "--",
                os.devnull,
                name,
            ],
            cwd=root,
            capture_output=True,
            check=False,
        )
        if result.returncode not in (0, 1):
            raise RuntimeError(
                f"cannot record untracked file {name}: {result.stderr!r}"
            )
        patch_parts.append(result.stdout)
    if patch_parts and not patch_parts[-1].endswith(b"\n"):
        patch_parts[-1] += b"\n"
    return files, b"".join(patch_parts)


def source_identity(root):
    repo = Path(git_output(root, "rev-parse", "--show-toplevel").strip()).resolve()
    untracked_files, untracked_patch = untracked_source(repo)
    tracked_patch = git_output(
        repo, "diff", "--binary", "--no-ext-diff", "HEAD", "--"
    ).encode()
    return {
        "root": str(repo),
        "head": git_output(repo, "rev-parse", "HEAD").strip(),
        "status": git_output(repo, "status", "--porcelain=v1"),
        "patch": tracked_patch + untracked_patch,
        "untracked": untracked_files,
    }


def counters(stderr):
    return {
        key: int(value)
        for key, value in re.findall(r"^  ([^:\n]+): (\d+)$", stderr, re.M)
    }


def reduction_percent(before, after):
    if before == 0:
        return None
    return 100 * (1 - after / before)


def run(command, prefix, capture_stdout=True):
    prefix.with_suffix(".command").write_text(shlex.join(command) + "\n")
    start = time.perf_counter_ns()
    result = subprocess.run(command, capture_output=True, text=True)
    elapsed = time.perf_counter_ns() - start
    prefix.with_suffix(".stderr").write_text(result.stderr)
    if capture_stdout:
        prefix.with_suffix(".stdout").write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(
            f"Command failed ({result.returncode}); see {prefix}.stderr"
        )
    return elapsed, result


def parse_mode(value):
    try:
        name, rest = value.split("=", 1)
        binary, _, flags = rest.partition("::")
    except ValueError as error:
        raise argparse.ArgumentTypeError(
            "mode must be NAME=OPT[::FLAGS]"
        ) from error
    if not name or not binary:
        raise argparse.ArgumentTypeError("mode name and binary must be non-empty")
    return name, Path(binary).resolve(), shlex.split(flags)


def generate(out, name, kind, functions, sites, depth):
    is_virtual = kind == "virtual"
    is_tce_cha = kind == "tce-cha"
    lines = [
        "@jeandle.personality = global ptr null",
        "@oop_handle_member_5 = external global ptr addrspace(1)",
        "declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)",
        'declare hotspotcc ptr addrspace(1) @link(ptr addrspace(1), ptr addrspace(1)) #1 gc "hotspotgc"',
        'declare hotspotcc ptr addrspace(1) @virtual(ptr addrspace(1)) #1 gc "hotspotgc"',
    ]
    for function in range(functions):
        lines += [
            f'define hotspotcc ptr addrspace(1) @caller{function}(ptr addrspace(1) "java-klass"="22" %a, ptr addrspace(1) "java-klass"="22" %b, i1 %c) #0 gc "hotspotgc" personality ptr @jeandle.personality {{',
            "entry:",
            "  %member = load ptr addrspace(1), ptr @oop_handle_member_5",
        ]
        value = "%a"
        for index in range(depth):
            lines.append(
                f"  %s{index} = select i1 %c, ptr addrspace(1) {value}, ptr addrspace(1) %b"
            )
            value = f"%s{index}"
        if is_tce_cha:
            lines.append(
                f"  %check = call hotspotcc i1 @jeandle.check_instanceof(ptr inttoptr (i64 22 to ptr), ptr addrspace(1) nonnull {value})"
            )
        for index in range(sites):
            if is_virtual:
                target = f"@virtual(ptr addrspace(1) {value})"
            else:
                target = (
                    f"@link(ptr addrspace(1) {value}, "
                    "ptr addrspace(1) %member)"
                )
            lines += [
                f'  %r{index} = invoke hotspotcc ptr addrspace(1) {target} #{index + 2} [ "deopt"(i64 0, i32 7, i32 7) ] to label %next{index} unwind label %unwind',
                f"next{index}:",
            ]
        lines += [
            f"  ret ptr addrspace(1) %r{sites - 1}",
            "unwind:",
            "  %lp = landingpad i64 cleanup",
            "  ret ptr addrspace(1) null",
            "}",
        ]
    lines += [
        'attributes #0 = { "java-method"="100" }',
        'attributes #1 = { "java-method"="200" }',
    ]
    for index in range(sites):
        attrs = (
            '"bytecode"="invokevirtual"'
            if is_virtual
            else '"bytecode"="invokehandle" "monomorphic-target" '
            '"mh-intrinsic-name"="_linkToStatic"'
        )
        lines.append(
            f'attributes #{index + 2} = {{ {attrs} "declared-holder"="300" '
            f'"statepoint-id"="{42 + index}" '
            '"statepoint-num-patch-bytes"="5" }'
        )
    lines += [
        "!java-method-compilation = !{}",
        "!static-call-patch-size = !{!0}",
        "!0 = !{i32 5}",
    ]
    ir = out / f"{name}.ll"
    ir.write_text("\n".join(lines) + "\n")

    callbacks = [
        'GetCHAOptInfo 100 200 300 0 false 5 5 = (601, 700, 13, "Optimized_target")',
        'GetCHAOptInfo 100 200 300 22 false 0 -1 = (22, 700, 48, "Optimized_target")',
        'GetCHAOptInfo 100 200 300 22 true 0 -1 = (22, 700, 48, "Optimized_target")',
        "GetSignatureArgType 700 -1 = 12",
        "GetSignatureArgType 700 0 = 12",
        "GetSignatureArgTypeKlass 700 0 = 22",
        "IsSubtype 22 22 = true",
        "IsInterface 22 = false",
        "IsObjectKlass 22 = false",
        "IsEffectivelyFinal 22 = false",
        "GetSecondarySupers 22 = []",
        "GetCommonSuperKlass 22 22 = 22",
    ]
    for index in range(sites):
        callbacks += [
            f"UpdateCallSite {42 + index} 0 true 700 = true",
            f"UpdateCallSite {42 + index} 2 false 700 = true",
        ]
    cblog = out / f"{name}.cblog"
    cblog.write_text("\n".join(callbacks) + "\n")
    passes = (
        "type-check-elimination,cha-devirtualization"
        if is_tce_cha
        else "cha-devirtualization"
    )
    return ir, cblog, passes


def bootstrap_ratio(rows, candidate, reference, rounds):
    pairs = []
    for round_index in range(rounds):
        group = {
            row["mode"]: row["wall_ns"]
            for row in rows
            if row["round"] == round_index
        }
        pairs.append((group[candidate], group[reference]))
    rng = random.Random(20261023)
    estimates = []
    for _ in range(4000):
        sample = rng.choices(pairs, k=len(pairs))
        candidate_median = statistics.median(pair[0] for pair in sample)
        reference_median = statistics.median(pair[1] for pair in sample)
        estimates.append(100 * (1 - candidate_median / reference_median))
    estimates.sort()
    return [estimates[100], estimates[3899]]


def case_specs(profile, functions, sites, depth):
    if profile == "smoke":
        return [
            ("deep-static", "static", functions, sites, depth),
            ("wide-static", "static", functions, sites * 4, max(8, depth // 4)),
            ("leaf-static", "static", functions, sites * 2, 0),
            ("tce-cha", "tce-cha", functions, sites, depth),
            ("virtual-cfg", "virtual", functions, sites * 2, 0),
        ]
    return [
        ("deep-static", "static", functions, sites, depth),
        ("wide-static", "static", functions, sites * 4, max(8, depth // 4)),
        ("leaf-static", "static", functions, sites * 2, 0),
        ("tce-cha", "tce-cha", functions, sites, depth),
        ("virtual-cfg", "virtual", functions, sites * 2, 0),
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--opt", type=Path, required=True)
    parser.add_argument(
        "--source-root",
        type=Path,
        default=Path.cwd(),
        help="Git checkout whose source and patch identity should be recorded.",
    )
    parser.add_argument(
        "--mode",
        action="append",
        type=parse_mode,
        help="NAME=OPT[::OPTIONS]; may be repeated. Defaults compare selective, full, and original.",
    )
    parser.add_argument("--reference", default="full")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=11)
    parser.add_argument("--warmups", type=int, default=2)
    parser.add_argument("--functions", type=int, default=8)
    parser.add_argument("--sites", type=int, default=16)
    parser.add_argument("--depth", type=int, default=64)
    parser.add_argument("--profile", choices=["smoke", "full"], default="smoke")
    args = parser.parse_args()
    if min(args.repeats, args.warmups, args.functions, args.sites) < 1:
        parser.error("repeat, warmup, function, and site counts must be positive")
    if args.depth < 0:
        parser.error("depth must be nonnegative")
    if not args.opt.exists():
        parser.error(f"missing opt binary: {args.opt}")

    opt = args.opt.resolve()
    modes = args.mode or [
        ("s0", opt, ["-jeandle-java-type-force-base-scan-invalidation"]),
        ("s1", opt, []),
        ("full", opt, ["-jeandle-java-type-force-full-invalidation"]),
        ("original", opt, ["-jeandle-disable-java-type-cache"]),
    ]
    mode_map = {name: (binary, flags) for name, binary, flags in modes}
    if args.reference not in mode_map:
        parser.error(f"reference mode {args.reference!r} is not defined")
    if len(mode_map) != len(modes):
        parser.error("mode names must be unique")

    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    source = source_identity(args.source_root)
    (out / "source.patch").write_bytes(source["patch"])
    manifest = {
        "platform": platform.platform(),
        "cpu": platform.processor(),
        "cpu_affinity": (
            sorted(os.sched_getaffinity(0))
            if hasattr(os, "sched_getaffinity")
            else None
        ),
        "profile": args.profile,
        "repeats": args.repeats,
        "warmups": args.warmups,
        "modes": {
            name: {"binary": str(binary), "flags": flags}
            for name, binary, flags in modes
        },
        "binary_sha256": {
            str(binary): digest(binary) for _, binary, _ in modes
        },
        "source": {
            "root": source["root"],
            "head": source["head"],
            "status": source["status"].splitlines(),
            "patch_sha256": hashlib.sha256(source["patch"]).hexdigest(),
            "untracked": source["untracked"],
        },
        "timing": (
            "Warmups and measured runs disable statistics, verification, and "
            "logging. Each round shuffles mode order. Wall time includes process "
            "startup, parsing, optimization, and analysis destruction."
        ),
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (out / "reproduce.py").write_bytes(Path(__file__).read_bytes())

    rng = random.Random(20261023)
    summaries = {}
    for name, kind, functions, sites, depth in case_specs(
        args.profile, args.functions, args.sites, args.depth
    ):
        dest = out / name
        dest.mkdir()
        ir, cblog, passes = generate(
            dest, name, kind, functions, sites, depth
        )
        pass_pipeline = f"-passes=function({passes})"
        common = [pass_pipeline, f"-jeandle-vm-callback-log={cblog}", str(ir)]

        diagnostics = {}
        outputs = {}
        for mode_name, (binary, flags) in mode_map.items():
            _, result = run(
                [
                    str(binary),
                    "-S",
                    "-verify-each",
                    "-jeandle-java-type-stats",
                    "-passes=function("
                    + passes
                    + "),print<java-type-analysis-summary>",
                    f"-jeandle-vm-callback-log={cblog}",
                    str(ir),
                    *flags,
                ],
                dest / f"diagnose-{mode_name}",
            )
            outputs[mode_name] = result.stdout
            diagnostics[mode_name] = counters(result.stderr)
            transformed = len(
                re.findall(r"invoke hotspotcc .* @Optimized_target\(", result.stdout)
            )
            if transformed != functions * sites:
                raise RuntimeError(
                    f"{name}/{mode_name}: transformed {transformed}, "
                    f"expected {functions * sites}"
                )
        if len(set(outputs.values())) != 1:
            raise RuntimeError(
                f"{name}: diagnostic modes produced different optimized IR"
            )

        rows = []
        for round_index in range(-args.warmups, args.repeats):
            order = list(mode_map)
            rng.shuffle(order)
            for mode_name in order:
                binary, flags = mode_map[mode_name]
                elapsed, _ = run(
                    [
                        str(binary),
                        "-disable-output",
                        *common,
                        *flags,
                    ],
                    dest / f"time-{round_index}-{mode_name}",
                    capture_stdout=False,
                )
                rows.append(
                    {
                        "round": round_index,
                        "mode": mode_name,
                        "wall_ns": elapsed,
                    }
                )
        (dest / "samples.json").write_text(json.dumps(rows, indent=2) + "\n")
        (dest / "diagnostics.json").write_text(
            json.dumps(diagnostics, indent=2) + "\n"
        )

        summary = {
            "km": {
                "functions": functions,
                "sites_per_function": sites,
                "select_depth": depth,
            },
            "ir_equal": True,
            "diagnostics": diagnostics,
            "design_comparisons": {},
            "modes": {},
        }
        if {"s0", "s1"} <= diagnostics.keys():
            s0 = diagnostics["s0"]
            s1 = diagnostics["s1"]
            s0_slots = s0.get("invalidation base slots scanned")
            s1_slots = s1.get("invalidation base slots scanned")
            s0_time = s0.get("total invalidation time (ns)")
            s1_time = s1.get("total invalidation time (ns)")
            summary["design_comparisons"]["s1_vs_s0"] = {
                "scope": (
                    "Diagnostic counters include timing instrumentation and "
                    "are not the formal performance ranking."
                ),
                "base_slots_scanned_s0": s0_slots,
                "base_slots_scanned_s1": s1_slots,
                "base_slots_scan_reduction_pct": (
                    reduction_percent(s0_slots, s1_slots)
                    if s0_slots is not None and s1_slots is not None
                    else None
                ),
                "invalidation_time_s0_ns": s0_time,
                "invalidation_time_s1_ns": s1_time,
                "invalidation_time_reduction_pct": (
                    reduction_percent(s0_time, s1_time)
                    if s0_time is not None and s1_time is not None
                    else None
                ),
            }
        measured = [row for row in rows if row["round"] >= 0]
        for mode_name in mode_map:
            samples = [
                row["wall_ns"]
                for row in measured
                if row["mode"] == mode_name
            ]
            summary["modes"][mode_name] = {
                "median_ns": statistics.median(samples),
                "min_ns": min(samples),
                "max_ns": max(samples),
            }
        reference = summary["modes"][args.reference]["median_ns"]
        for mode_name in mode_map:
            if mode_name == args.reference:
                continue
            summary["modes"][mode_name]["reduction_vs_reference_pct"] = (
                100
                * (
                    1
                    - summary["modes"][mode_name]["median_ns"] / reference
                )
            )
            summary["modes"][mode_name][
                "reduction_vs_reference_bootstrap_95pct"
            ] = bootstrap_ratio(
                measured, mode_name, args.reference, args.repeats
            )
        summaries[name] = summary
        (out / "summary.json").write_text(json.dumps(summaries, indent=2) + "\n")
        print(
            f"{name}: {functions * sites} sites; "
            f"{args.reference} median {reference / 1e6:.3f} ms",
            flush=True,
        )

    if digest(Path(__file__)) != digest(out / "reproduce.py"):
        raise RuntimeError("benchmark script changed during the run")
    for binary, expected in manifest["binary_sha256"].items():
        if digest(Path(binary)) != expected:
            raise RuntimeError(f"binary changed during run: {binary}")
    final_source = source_identity(args.source_root)
    if any(
        final_source[key] != source[key] for key in ("root", "head", "status", "patch")
    ):
        raise RuntimeError("source checkout changed during the run")
    (out / "SUCCESS").write_text(
        "Correctness, diagnostics, and isolated timing completed.\n"
    )
    print(f"Evidence: {out}")


if __name__ == "__main__":
    main()
