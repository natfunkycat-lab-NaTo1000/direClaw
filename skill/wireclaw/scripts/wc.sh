#!/usr/bin/env bash
# WireClaw — OpenClaw tool execution helper
#
# Usage:
#   wc.sh exec <device> <tool> [json_params]  — Execute a tool on a device
#   wc.sh caps <device>                        — Query device capabilities
#   wc.sh discover                             — Find all WireClaw devices
#   wc.sh sub <device>                         — Subscribe to event stream
#   wc.sh orchestrate <plan|@file>             — Multi-level governance orchestration
#   wc.sh plan-template                         — Print orchestration plan template
#
# Examples:
#   wc.sh exec wireclaw-01 led_set '{"r":255,"g":0,"b":0}'
#   wc.sh exec wireclaw-01 sensor_read '{"name":"chip_temp"}'
#   wc.sh exec wireclaw-01 device_info
#   wc.sh caps wireclaw-01
#   wc.sh discover
#   wc.sh sub wireclaw-01
#   wc.sh plan-template
#   wc.sh orchestrate @examples/plan.json
#   wc.sh orchestrate '{"orchestration_name":"demo","levels":[{"name":"level-1","mode":"parallel","tasks":[{"device":"wireclaw-01","tool":"device_info"}]}]}'
#
# Environment:
#   WIRECLAW_NATS_URL  — NATS server URL (default: nats://localhost:4222)

set -euo pipefail

NATS_URL="${WIRECLAW_NATS_URL:-nats://localhost:4222}"

usage() {
    echo "Usage:"
    echo "  wc.sh exec <device> <tool> [json_params]  — Execute a tool"
    echo "  wc.sh caps <device>                        — Query capabilities"
    echo "  wc.sh discover                             — Find all devices"
    echo "  wc.sh sub <device>                         — Subscribe to events"
    echo "  wc.sh orchestrate <plan|@file> [options]  — Run multi-level governance orchestration"
    echo "  wc.sh plan-template                        — Print a JSON template for orchestration plans"
    echo ""
    echo "orchestrate options:"
    echo "  --timeout <duration>   NATS request timeout per task (default: 10s)"
    echo "  --max-parallel <n>     Global max workers for parallel levels (default: 4)"
    echo "  --dry-run              Expand and validate plan, but do not execute tool calls"
    echo "  --json                 Emit machine-readable JSON summary instead of conversational output"
    echo "  --log-file <path>      Write detailed execution report to the given path"
    exit 1
}

cmd_exec() {
    local device="${1:?exec requires <device> <tool> [json_params]}"
    local tool="${2:?exec requires <device> <tool> [json_params]}"
    local params="${3:-}"

    # Merge "tool" key into params JSON
    local payload
    if [ -n "$params" ]; then
        # Strip leading { from params, prepend {"tool":"...","
        payload="{\"tool\":\"${tool}\",${params#\{}"
    else
        payload="{\"tool\":\"${tool}\"}"
    fi

    exec nats req "${device}.tool_exec" "$payload" \
        --server="${NATS_URL}" \
        --timeout=10s
}

cmd_caps() {
    local device="${1:?caps requires <device>}"

    exec nats req "${device}.capabilities" "" \
        --server="${NATS_URL}" \
        --timeout=5s
}

cmd_discover() {
    exec nats req "_ion.discover" "" \
        --server="${NATS_URL}" \
        --replies=0 \
        --timeout=3s
}

cmd_sub() {
    local device="${1:?sub requires <device>}"

    exec nats sub "${device}.events" \
        --server="${NATS_URL}"
}

print_plan_template() {
    cat <<'JSON'
{
  "orchestration_name": "facility-governance",
  "levels": [
    {
      "name": "level-1-observe",
      "mode": "parallel",
      "max_parallel": 4,
      "ordinance": {
        "on_error": "continue",
        "min_success_ratio": 0.5
      },
      "tasks": [
        {
          "id": "probe-info",
          "duty": "Collect device health info",
          "device": ["wireclaw-01", "wireclaw-02"],
          "tool": "device_info"
        }
      ]
    },
    {
      "name": "level-2-actuate",
      "mode": "series",
      "ordinance": {
        "on_error": "halt",
        "min_success_ratio": 1.0
      },
      "tasks": [
        {
          "id": "vector-led",
          "duty": "Apply multiplexed LED state by vector",
          "device": "wireclaw-01",
          "tool": "led_set",
          "params": {
            "r": 0,
            "g": 255,
            "b": 0
          },
          "vectors": [
            {
              "suffix": "alpha",
              "params": {
                "g": 64
              }
            },
            {
              "suffix": "beta",
              "params": {
                "g": 255
              }
            }
          ]
        }
      ]
    }
  ]
}
JSON
}

cmd_orchestrate() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "Error: python3 is required for orchestration mode." >&2
        exit 1
    fi

    local timeout="10s"
    local max_parallel="4"
    local dry_run="0"
    local json_output="0"
    local log_file=""
    local plan_input=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --timeout)
                shift
                timeout="${1:?--timeout requires a value}"
                ;;
            --max-parallel)
                shift
                max_parallel="${1:?--max-parallel requires a value}"
                ;;
            --dry-run)
                dry_run="1"
                ;;
            --json)
                json_output="1"
                ;;
            --log-file)
                shift
                log_file="${1:?--log-file requires a value}"
                ;;
            -*)
                echo "Unknown orchestrate option: $1" >&2
                usage
                ;;
            *)
                if [ -n "${plan_input}" ]; then
                    echo "orchestrate accepts exactly one plan input (<plan-json> or @<file>)" >&2
                    exit 1
                fi
                plan_input="$1"
                ;;
        esac
        shift
    done

    if [ -z "${plan_input}" ]; then
        echo "orchestrate requires a plan input (<plan-json> or @<file>)" >&2
        exit 1
    fi

    python3 - "$NATS_URL" "$timeout" "$max_parallel" "$dry_run" "$json_output" "$log_file" "$plan_input" <<'PY'
import concurrent.futures
import datetime as dt
import json
import os
import shlex
import subprocess
import sys
import time
from typing import Any, Dict, List


def fail(msg: str, code: int = 2) -> None:
    print(f"Error: {msg}", file=sys.stderr)
    raise SystemExit(code)


def load_plan(plan_input: str) -> Dict[str, Any]:
    if plan_input.startswith("@"):
        path = plan_input[1:]
        if not path:
            fail("Plan file reference '@<file>' must include a path")
        with open(path, "r", encoding="utf-8") as f:
            raw = f.read()
    else:
        raw = plan_input
    try:
        plan = json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(f"Invalid plan JSON: {exc}")
    if not isinstance(plan, dict):
        fail("Plan must be a JSON object")
    return plan


def ensure_str(x: Any, name: str) -> str:
    if not isinstance(x, str) or not x.strip():
        fail(f"{name} must be a non-empty string")
    return x.strip()


def ensure_mode(mode: Any) -> str:
    if mode in ("series", "parallel"):
        return mode
    fail("Level mode must be either 'series' or 'parallel'")


def expand_task(task: Dict[str, Any], level_idx: int, level_name: str, task_idx: int) -> List[Dict[str, Any]]:
    tool = ensure_str(task.get("tool"), f"levels[{level_idx}].tasks[{task_idx}].tool")
    device_raw = task.get("device")
    if isinstance(device_raw, str):
        devices = [device_raw]
    elif isinstance(device_raw, list) and device_raw and all(isinstance(d, str) and d.strip() for d in device_raw):
        devices = [d.strip() for d in device_raw]
    else:
        fail(f"levels[{level_idx}].tasks[{task_idx}].device must be a string or non-empty string array")

    base_params = task.get("params", {})
    if base_params is None:
        base_params = {}
    if not isinstance(base_params, dict):
        fail(f"levels[{level_idx}].tasks[{task_idx}].params must be an object")

    vectors_raw = task.get("vectors")
    vectors: List[Dict[str, Any]]
    if vectors_raw is None:
        vectors = [{}]
    elif isinstance(vectors_raw, list) and vectors_raw:
        vectors = []
        for v_idx, vector in enumerate(vectors_raw):
            if not isinstance(vector, dict):
                fail(f"levels[{level_idx}].tasks[{task_idx}].vectors[{v_idx}] must be an object")
            vector_params = vector.get("params", {})
            if vector_params is None:
                vector_params = {}
            if not isinstance(vector_params, dict):
                fail(f"levels[{level_idx}].tasks[{task_idx}].vectors[{v_idx}].params must be an object")
            vectors.append({
                "suffix": str(vector.get("suffix", f"vector-{v_idx + 1}")),
                "params": vector_params,
                "duty_suffix": str(vector.get("duty_suffix", "")).strip(),
            })
    else:
        fail(f"levels[{level_idx}].tasks[{task_idx}].vectors must be a non-empty array when provided")

    base_id = str(task.get("id", f"level-{level_idx + 1}-task-{task_idx + 1}")).strip()
    base_duty = str(task.get("duty", "")).strip()
    expanded: List[Dict[str, Any]] = []
    for device in devices:
        for vector in vectors:
            params = dict(base_params)
            params.update(vector.get("params", {}))
            vector_suffix = vector.get("suffix", "").strip()
            duty_suffix = vector.get("duty_suffix", "").strip()
            duty = base_duty
            if duty_suffix:
                duty = f"{base_duty} [{duty_suffix}]".strip()
            task_id = base_id
            if len(devices) > 1:
                task_id = f"{task_id}@{device}"
            if len(vectors) > 1 and vector_suffix:
                task_id = f"{task_id}#{vector_suffix}"
            expanded.append({
                "id": task_id,
                "duty": duty,
                "level_idx": level_idx,
                "level_name": level_name,
                "device": device,
                "tool": tool,
                "params": params,
            })
    return expanded


def normalize_levels(plan: Dict[str, Any]) -> List[Dict[str, Any]]:
    levels_raw = plan.get("levels")
    if not isinstance(levels_raw, list) or not levels_raw:
        fail("Plan must include a non-empty levels array")

    normalized: List[Dict[str, Any]] = []
    for i, level in enumerate(levels_raw):
        if not isinstance(level, dict):
            fail(f"levels[{i}] must be an object")
        level_name = ensure_str(level.get("name", f"level-{i + 1}"), f"levels[{i}].name")
        mode = ensure_mode(level.get("mode", "series"))
        tasks_raw = level.get("tasks")
        if not isinstance(tasks_raw, list) or not tasks_raw:
            fail(f"levels[{i}].tasks must be a non-empty array")
        ordinance = level.get("ordinance", {})
        if ordinance is None:
            ordinance = {}
        if not isinstance(ordinance, dict):
            fail(f"levels[{i}].ordinance must be an object")
        on_error = ordinance.get("on_error", "halt")
        if on_error not in ("halt", "continue"):
            fail(f"levels[{i}].ordinance.on_error must be 'halt' or 'continue'")
        min_success_ratio = ordinance.get("min_success_ratio", 1.0)
        if not isinstance(min_success_ratio, (int, float)) or not (0 <= float(min_success_ratio) <= 1):
            fail(f"levels[{i}].ordinance.min_success_ratio must be a number between 0 and 1")
        level_max_parallel = level.get("max_parallel")
        if level_max_parallel is not None:
            if not isinstance(level_max_parallel, int) or level_max_parallel < 1:
                fail(f"levels[{i}].max_parallel must be an integer >= 1")

        expanded_tasks: List[Dict[str, Any]] = []
        for t_idx, task in enumerate(tasks_raw):
            if not isinstance(task, dict):
                fail(f"levels[{i}].tasks[{t_idx}] must be an object")
            expanded_tasks.extend(expand_task(task, i, level_name, t_idx))

        normalized.append({
            "name": level_name,
            "mode": mode,
            "tasks": expanded_tasks,
            "ordinance": {
                "on_error": on_error,
                "min_success_ratio": float(min_success_ratio),
            },
            "max_parallel": level_max_parallel,
        })
    return normalized


def run_nats_req(
    nats_url: str,
    timeout: str,
    task: Dict[str, Any],
    dry_run: bool,
) -> Dict[str, Any]:
    payload_obj = {"tool": task["tool"]}
    payload_obj.update(task["params"])
    payload = json.dumps(payload_obj, separators=(",", ":"), ensure_ascii=False)
    subject = f"{task['device']}.tool_exec"
    cmd = [
        "nats",
        "req",
        subject,
        payload,
        f"--server={nats_url}",
        f"--timeout={timeout}",
    ]

    started = time.perf_counter()
    if dry_run:
        output = f"DRY-RUN {shlex.join(cmd)}"
        ok = True
        exit_code = 0
    else:
        proc = subprocess.run(cmd, capture_output=True, text=True)
        output = (proc.stdout or proc.stderr).strip()
        ok = proc.returncode == 0
        exit_code = proc.returncode
    duration_ms = int((time.perf_counter() - started) * 1000)

    return {
        "task_id": task["id"],
        "level_name": task["level_name"],
        "level_idx": task["level_idx"],
        "device": task["device"],
        "tool": task["tool"],
        "duty": task["duty"],
        "ok": ok,
        "exit_code": exit_code,
        "duration_ms": duration_ms,
        "subject": subject,
        "payload": payload_obj,
        "output": output,
    }


def execute_level(
    *,
    level: Dict[str, Any],
    nats_url: str,
    timeout: str,
    dry_run: bool,
    max_parallel_global: int,
) -> Dict[str, Any]:
    tasks = level["tasks"]
    results: List[Dict[str, Any]] = []
    on_error = level["ordinance"]["on_error"]

    if level["mode"] == "series":
        for task in tasks:
            result = run_nats_req(nats_url, timeout, task, dry_run)
            results.append(result)
            if on_error == "halt" and not result["ok"]:
                break
    else:
        workers = level.get("max_parallel") or max_parallel_global
        workers = max(1, min(workers, len(tasks)))
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            pending = [pool.submit(run_nats_req, nats_url, timeout, task, dry_run) for task in tasks]
            for future in concurrent.futures.as_completed(pending):
                result = future.result()
                results.append(result)
                if on_error == "halt" and not result["ok"]:
                    for other in pending:
                        other.cancel()
                    break
        seen = {r["task_id"] for r in results}
        if len(seen) < len(tasks):
            for task in tasks:
                if task["id"] not in seen:
                    results.append({
                        "task_id": task["id"],
                        "level_name": task["level_name"],
                        "level_idx": task["level_idx"],
                        "device": task["device"],
                        "tool": task["tool"],
                        "duty": task["duty"],
                        "ok": False,
                        "exit_code": None,
                        "duration_ms": 0,
                        "subject": f"{task['device']}.tool_exec",
                        "payload": {"tool": task["tool"], **task["params"]},
                        "output": "skipped because ordinance.on_error=halt triggered in parallel execution",
                        "skipped": True,
                    })

    total = len(results)
    successes = sum(1 for r in results if r["ok"])
    min_success_ratio = level["ordinance"]["min_success_ratio"]
    success_ratio = (successes / total) if total else 0.0
    level_ok = success_ratio >= min_success_ratio

    return {
        "name": level["name"],
        "mode": level["mode"],
        "ordinance": level["ordinance"],
        "task_count": total,
        "successes": successes,
        "failures": total - successes,
        "success_ratio": success_ratio,
        "level_ok": level_ok,
        "results": sorted(results, key=lambda r: r["task_id"]),
    }


def conversational_report(report: Dict[str, Any]) -> None:
    icon = "✅" if report["ok"] else "❌"
    print(
        f"{icon} Governance orchestration '{report['orchestration_name']}' "
        f"completed: {report['successes']}/{report['task_count']} duties succeeded "
        f"across {report['level_count']} levels."
    )
    print("")
    print("Execution flow:")
    for level in report["levels"]:
        li = "✅" if level["level_ok"] else "❌"
        print(
            f"  {li} {level['name']} [{level['mode']}] "
            f"{level['successes']}/{level['task_count']} "
            f"(ordinance: on_error={level['ordinance']['on_error']}, "
            f"min_success_ratio={level['ordinance']['min_success_ratio']})"
        )
        for result in level["results"]:
            ri = "✅" if result["ok"] else "❌"
            duty_suffix = f" duty='{result['duty']}'" if result["duty"] else ""
            print(
                f"    {ri} {result['task_id']} -> {result['device']}.{result['tool']}"
                f"{duty_suffix} ({result['duration_ms']}ms)"
            )
            output = (result.get("output") or "").strip()
            if output:
                one_line = output.replace("\n", " | ")
                print(f"      ↳ {one_line[:220]}")
    if report.get("log_file"):
        print("")
        print(f"Detailed log: {report['log_file']}")


def main() -> None:
    nats_url, timeout, max_parallel_s, dry_run_s, json_output_s, log_file, plan_input = sys.argv[1:]
    dry_run = dry_run_s == "1"
    json_output = json_output_s == "1"
    try:
        max_parallel = int(max_parallel_s)
    except ValueError:
        fail("--max-parallel must be an integer")
    if max_parallel < 1:
        fail("--max-parallel must be >= 1")

    plan = load_plan(plan_input)
    orchestration_name = str(plan.get("orchestration_name", "wireclaw-governance")).strip() or "wireclaw-governance"
    levels = normalize_levels(plan)

    level_reports = []
    halted = False
    for level in levels:
        if halted:
            level_reports.append({
                "name": level["name"],
                "mode": level["mode"],
                "ordinance": level["ordinance"],
                "task_count": 0,
                "successes": 0,
                "failures": 0,
                "success_ratio": 0.0,
                "level_ok": False,
                "results": [],
                "skipped": True,
            })
            continue
        rep = execute_level(
            level=level,
            nats_url=nats_url,
            timeout=timeout,
            dry_run=dry_run,
            max_parallel_global=max_parallel,
        )
        level_reports.append(rep)
        if not rep["level_ok"] and level["ordinance"]["on_error"] == "halt":
            halted = True

    task_count = sum(l["task_count"] for l in level_reports)
    successes = sum(l["successes"] for l in level_reports)
    ok = all(l.get("level_ok", False) for l in level_reports if not l.get("skipped"))
    report = {
        "timestamp_utc": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "orchestration_name": orchestration_name,
        "level_count": len(level_reports),
        "task_count": task_count,
        "successes": successes,
        "failures": task_count - successes,
        "ok": ok,
        "dry_run": dry_run,
        "nats_url": nats_url,
        "timeout": timeout,
        "max_parallel": max_parallel,
        "levels": level_reports,
        "log_file": log_file or None,
    }

    if log_file:
        log_dir = os.path.dirname(log_file)
        if log_dir:
            os.makedirs(log_dir, exist_ok=True)
        with open(log_file, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2, ensure_ascii=False)
            f.write("\n")

    if json_output:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        conversational_report(report)

    if report["ok"]:
        raise SystemExit(0)
    raise SystemExit(3)


if __name__ == "__main__":
    main()
PY
}

# --- Main ---

if [ $# -lt 1 ]; then
    usage
fi

case "$1" in
    exec)     shift; cmd_exec "$@" ;;
    caps)     shift; cmd_caps "$@" ;;
    discover) shift; cmd_discover "$@" ;;
    sub)      shift; cmd_sub "$@" ;;
    orchestrate) shift; cmd_orchestrate "$@" ;;
    plan-template) print_plan_template ;;
    -h|--help) usage ;;
    *)        echo "Unknown command: $1"; usage ;;
esac
