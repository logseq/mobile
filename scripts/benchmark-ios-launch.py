#!/usr/bin/env python3
"""Repeat process-cold launches and report measured startup stages in milliseconds."""
import argparse
import json
import os
from pathlib import Path
import re
import statistics
import subprocess


def parse_run(log):
    process = {key: float(value) for key, value in re.findall(
        r"LOGSEQ_PROCESS_LAUNCH_METRIC (\w+)_ms=([0-9.]+)", log)}
    app = {key: float(value) for key, value in re.findall(
        r"LOGSEQ_LAUNCH_METRIC (\w+)_ms=([0-9.]+)", log)}
    result = {
        "process_to_app_init": process["local_load_started"] - app["local_load_started"],
        "catalog_open": app["catalog_opened"] - app["local_load_started"],
        "graph_open": app["open_graph_returned"] - app["open_graph_started"],
        "snapshot_apply": app["store_opened"] - app["open_graph_returned"],
        "launch_finish_to_root_appear": process["root_appeared"] - process["did_finish_launching"],
        "root_appear_to_callback": process["first_ui_rendered"] - process["root_appeared"],
        "process_to_graph_ready": process["graph_loaded"],
        "process_to_root_appear": process["root_appeared"],
        "process_to_ui_callback": process["first_ui_rendered"],
    }
    for name, value in re.findall(r"LOGSEQ_LAUNCH_STEP name=(\w+) elapsed_ms=([0-9.]+)", log):
        result[name] = result.get(name, 0) + float(value)
    if any(value < 0 for value in result.values()):
        raise ValueError("startup stages are out of order")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    if options.runs < 1:
        parser.error("--runs must be positive")
    root = Path(__file__).resolve().parent.parent
    options.output.parent.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    # Gather distributions without hiding slow samples behind a per-run limit.
    environment.setdefault("LOGSEQ_JOURNALS_READY_BUDGET_MS", "10000")
    runs = []
    for index in range(options.runs):
        run = subprocess.run([str(root / "scripts/test-ios-journals-launch-performance.sh")],
                             cwd=root, env=environment, text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45)
        options.output.with_name(f"{options.output.stem}-{index + 1}.log").write_text(run.stdout)
        if run.returncode:
            raise SystemExit(run.stdout)
        runs.append(parse_run(run.stdout))
        print(f"Run {index + 1}: {runs[-1]['process_to_ui_callback']:.3f}ms", flush=True)
    summary = {name: {
        "median_ms": round(statistics.median(run[name] for run in runs), 3),
        "min_ms": round(min(run[name] for run in runs), 3),
        "max_ms": round(max(run[name] for run in runs), 3),
    } for name in runs[0]}
    options.output.write_text(json.dumps({
        "measurement": "process creation to first UI callback; not GPU presentation",
        "cache": "graph and authentication preserved; process restarted for each run",
        "note": "Nested intervals overlap and must not be added together.",
        "summary": summary, "runs": runs,
    }, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
