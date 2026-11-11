#!/usr/bin/env bash
# WireClaw link-up helper
#
# PC/mobile helper for:
# - connectivity + visibility validation (WiFi/NATS/BLE/Tailscale/SSH)
# - secure posture checks for remote operation
# - side-task dispatch to WireClaw chat and local file capture

set -euo pipefail

NATS_URL="${WIRECLAW_NATS_URL:-nats://localhost:4222}"
DEFAULT_OUT_DIR="${WIRECLAW_SIDE_TASK_DIR:-files/side-tasks}"

usage() {
    cat <<'EOF'
Usage:
  wc-linkup.sh validate --device <device> [options]
  wc-linkup.sh security-check [options]
  wc-linkup.sh side-task --device <device> --prompt "<text>" [options]

Commands:
  validate       Check device visibility + link health across local/remote paths
  security-check Check auth posture for NATS/Tailscale/SSH
  side-task      Send a side-question to {device}.chat and save result to files folder

validate options:
  --device <name>              WireClaw device name (required)
  --timeout <duration>         NATS timeout (default: 10s)
  --expect-device <name>       Require a registered device (repeatable)
  --ble-name <name>            Check nearby BLE scan output for this device name
  --ble-mac <mac>              Check nearby BLE scan output for this MAC (AA:BB:...)
  --tailscale-host <host>      Validate Tailscale reachability to host
  --ssh-target <user@host>     Validate SSH command path to target
  --require-auth               Fail if NATS auth material is not configured

security-check options:
  --require-auth               Require NATS auth in URL or NATS_CREDS env
  --require-tailscale          Require tailscale status to be healthy
  --require-ssh                Require SSH key material to exist

side-task options:
  --device <name>              WireClaw device name (required)
  --prompt "<text>"            Prompt to send over NATS chat (required)
  --timeout <duration>         NATS timeout (default: 30s)
  --out-dir <path>             Output folder (default: files/side-tasks)
  --tag <name>                 Optional filename tag

Examples:
  skill/wireclaw/scripts/wc-linkup.sh validate --device wireclaw-01 --tailscale-host wireclaw-node
  skill/wireclaw/scripts/wc-linkup.sh security-check --require-auth --require-tailscale --require-ssh
  skill/wireclaw/scripts/wc-linkup.sh side-task --device wireclaw-01 --prompt "Summarize sensor drift today"
EOF
    exit 1
}

log() {
    printf '%s\n' "$*"
}

require_cmd() {
    local cmd="${1:?missing cmd}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: required command not found: $cmd" >&2
        exit 1
    fi
}

extract_nats_payload() {
    # nats req output usually prints transport lines + payload as final line.
    # Return the final non-empty line.
    awk 'NF{line=$0} END{print line}'
}

nats_request() {
    local subject="${1:?missing subject}"
    local payload="${2:-}"
    local timeout="${3:-10s}"

    nats req "$subject" "$payload" --server="$NATS_URL" --timeout="$timeout"
}

nats_has_auth() {
    if [[ "$NATS_URL" == *"@"* ]]; then
        return 0
    fi
    if [[ -n "${NATS_CREDS:-}" || -n "${NATS_NKEY:-}" || -n "${NATS_USER:-}" ]]; then
        return 0
    fi
    return 1
}

validate_ble_presence() {
    local ble_name="${1:-}"
    local ble_mac="${2:-}"

    if [[ -z "$ble_name" && -z "$ble_mac" ]]; then
        return 0
    fi

    if ! command -v bluetoothctl >/dev/null 2>&1; then
        echo "BLE check requested but bluetoothctl is not installed" >&2
        return 1
    fi

    local scan_out
    scan_out="$(timeout 12s bluetoothctl --timeout 10 scan on 2>/dev/null || true)"

    if [[ -n "$ble_name" ]]; then
        if ! printf '%s\n' "$scan_out" | grep -Fqi "$ble_name"; then
            echo "BLE name not detected in scan: $ble_name" >&2
            return 1
        fi
    fi
    if [[ -n "$ble_mac" ]]; then
        if ! printf '%s\n' "$scan_out" | grep -Fqi "$ble_mac"; then
            echo "BLE MAC not detected in scan: $ble_mac" >&2
            return 1
        fi
    fi

    return 0
}

cmd_validate() {
    local device=""
    local timeout="10s"
    local require_auth="0"
    local ble_name=""
    local ble_mac=""
    local tailscale_host=""
    local ssh_target=""
    local -a expected_devices=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device)
                shift
                device="${1:?--device requires a value}"
                ;;
            --timeout)
                shift
                timeout="${1:?--timeout requires a value}"
                ;;
            --expect-device)
                shift
                expected_devices+=("${1:?--expect-device requires a value}")
                ;;
            --ble-name)
                shift
                ble_name="${1:?--ble-name requires a value}"
                ;;
            --ble-mac)
                shift
                ble_mac="${1:?--ble-mac requires a value}"
                ;;
            --tailscale-host)
                shift
                tailscale_host="${1:?--tailscale-host requires a value}"
                ;;
            --ssh-target)
                shift
                ssh_target="${1:?--ssh-target requires a value}"
                ;;
            --require-auth)
                require_auth="1"
                ;;
            -*)
                echo "Unknown validate option: $1" >&2
                usage
                ;;
            *)
                echo "Unexpected validate argument: $1" >&2
                usage
                ;;
        esac
        shift
    done

    if [[ -z "$device" ]]; then
        echo "validate requires --device <name>" >&2
        exit 1
    fi

    require_cmd nats
    require_cmd python3

    local ok=1

    if [[ "$require_auth" == "1" ]]; then
        if nats_has_auth; then
            log "✅ NATS auth material detected"
        else
            log "❌ NATS auth missing (set creds in URL or NATS_* env vars)"
            ok=0
        fi
    fi

    local caps_raw caps_json
    if ! caps_raw="$(nats_request "${device}.capabilities" "" "$timeout" 2>/dev/null)"; then
        log "❌ capabilities request failed for ${device}"
        exit 2
    fi
    caps_json="$(printf '%s\n' "$caps_raw" | extract_nats_payload)"

    if ! printf '%s' "$caps_json" | python3 - <<'PY' >/tmp/wc-linkup-caps.txt 2>/tmp/wc-linkup-caps.err
import json,sys
text=sys.stdin.read().strip()
obj=json.loads(text)
dev=obj.get("device","?")
tools=len(obj.get("tools",[]))
devices=obj.get("devices",[])
rules=len(obj.get("rules",[]))
print(f"device={dev}")
print(f"tools={tools}")
print(f"rules={rules}")
for d in devices:
    name=d.get("name","")
    kind=d.get("kind","")
    print(f"dev:{name}:{kind}")
PY
    then
        log "❌ capabilities payload is not valid JSON"
        sed -n '1,20p' /tmp/wc-linkup-caps.err >&2 || true
        rm -f /tmp/wc-linkup-caps.err /tmp/wc-linkup-caps.txt
        exit 3
    fi

    local tools_count rules_count
    tools_count="$(grep '^tools=' /tmp/wc-linkup-caps.txt | head -n1 | cut -d= -f2 || echo 0)"
    rules_count="$(grep '^rules=' /tmp/wc-linkup-caps.txt | head -n1 | cut -d= -f2 || echo 0)"
    log "✅ NATS capabilities visible: tools=${tools_count}, rules=${rules_count}"

    local info_raw info_json
    if info_raw="$(nats_request "${device}.tool_exec" '{"tool":"device_info"}' "$timeout" 2>/dev/null)"; then
        info_json="$(printf '%s\n' "$info_raw" | extract_nats_payload)"
        if printf '%s' "$info_json" | grep -q '"ok":true'; then
            if printf '%s' "$info_json" | grep -qi 'WiFi: connected'; then
                log "✅ WiFi reported connected in device_info"
            else
                log "⚠️  device_info returned, but WiFi connected string not found"
            fi
        else
            log "⚠️  device_info call returned an error payload"
            ok=0
        fi
    else
        log "⚠️  device_info request failed"
        ok=0
    fi

    if [[ "${#expected_devices[@]}" -gt 0 ]]; then
        local missing=0
        for expected in "${expected_devices[@]}"; do
            if grep -q "^dev:${expected}:" /tmp/wc-linkup-caps.txt; then
                log "✅ expected device present: ${expected}"
            else
                log "❌ expected device missing: ${expected}"
                missing=1
            fi
        done
        if [[ "$missing" -eq 1 ]]; then
            ok=0
        fi
    fi

    if [[ -n "$ble_name" || -n "$ble_mac" ]]; then
        if validate_ble_presence "$ble_name" "$ble_mac"; then
            log "✅ BLE visibility check passed"
        else
            log "❌ BLE visibility check failed"
            ok=0
        fi
    fi

    if [[ -n "$tailscale_host" ]]; then
        if ! command -v tailscale >/dev/null 2>&1; then
            log "❌ tailscale command not found"
            ok=0
        elif tailscale ping -c 1 "$tailscale_host" >/tmp/wc-linkup-ts.txt 2>&1; then
            log "✅ Tailscale host reachable: ${tailscale_host}"
            rm -f /tmp/wc-linkup-ts.txt
        else
            log "❌ Tailscale host unreachable: ${tailscale_host}"
            ok=0
            rm -f /tmp/wc-linkup-ts.txt
        fi
    fi

    if [[ -n "$ssh_target" ]]; then
        if ! command -v ssh >/dev/null 2>&1; then
            log "❌ ssh command not found"
            ok=0
        elif ssh -o BatchMode=yes -o ConnectTimeout=8 "$ssh_target" "echo linkup-ok" >/tmp/wc-linkup-ssh.txt 2>&1; then
            log "✅ SSH reachable: ${ssh_target}"
            rm -f /tmp/wc-linkup-ssh.txt
        else
            log "❌ SSH connect failed: ${ssh_target}"
            ok=0
            rm -f /tmp/wc-linkup-ssh.txt
        fi
    fi

    rm -f /tmp/wc-linkup-caps.err /tmp/wc-linkup-caps.txt

    if [[ "$ok" -eq 1 ]]; then
        log "✅ Link-up validation passed"
        return 0
    fi
    log "❌ Link-up validation failed"
    return 4
}

cmd_security_check() {
    local require_auth="0"
    local require_tailscale="0"
    local require_ssh="0"
    local ok=1

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --require-auth) require_auth="1" ;;
            --require-tailscale) require_tailscale="1" ;;
            --require-ssh) require_ssh="1" ;;
            -*)
                echo "Unknown security-check option: $1" >&2
                usage
                ;;
            *)
                echo "Unexpected security-check argument: $1" >&2
                usage
                ;;
        esac
        shift
    done

    if nats_has_auth; then
        log "✅ NATS auth material configured"
    else
        log "⚠️  NATS auth material not detected"
        [[ "$require_auth" == "1" ]] && ok=0
    fi

    if command -v tailscale >/dev/null 2>&1 && tailscale status >/tmp/wc-linkup-status.txt 2>&1; then
        log "✅ Tailscale status healthy"
    else
        log "⚠️  Tailscale not healthy or not installed"
        [[ "$require_tailscale" == "1" ]] && ok=0
    fi
    rm -f /tmp/wc-linkup-status.txt

    if command -v ssh >/dev/null 2>&1; then
        if [[ -n "${SSH_AUTH_SOCK:-}" || -f "${HOME}/.ssh/id_ed25519" || -f "${HOME}/.ssh/id_rsa" ]]; then
            log "✅ SSH key material detected"
        else
            log "⚠️  SSH key material not detected"
            [[ "$require_ssh" == "1" ]] && ok=0
        fi
    else
        log "⚠️  ssh command not found"
        [[ "$require_ssh" == "1" ]] && ok=0
    fi

    if [[ "$ok" -eq 1 ]]; then
        log "✅ Security posture check passed"
        return 0
    fi
    log "❌ Security posture check failed"
    return 5
}

cmd_side_task() {
    local device=""
    local prompt=""
    local timeout="30s"
    local out_dir="$DEFAULT_OUT_DIR"
    local tag=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device)
                shift
                device="${1:?--device requires a value}"
                ;;
            --prompt)
                shift
                prompt="${1:?--prompt requires a value}"
                ;;
            --timeout)
                shift
                timeout="${1:?--timeout requires a value}"
                ;;
            --out-dir)
                shift
                out_dir="${1:?--out-dir requires a value}"
                ;;
            --tag)
                shift
                tag="${1:?--tag requires a value}"
                ;;
            -*)
                echo "Unknown side-task option: $1" >&2
                usage
                ;;
            *)
                echo "Unexpected side-task argument: $1" >&2
                usage
                ;;
        esac
        shift
    done

    if [[ -z "$device" || -z "$prompt" ]]; then
        echo "side-task requires --device and --prompt" >&2
        exit 1
    fi

    require_cmd nats
    require_cmd python3

    mkdir -p "$out_dir"

    local ts slug base raw_file payload_file meta_file raw_out payload
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    slug="$(printf '%s' "${tag:-$prompt}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//' | cut -c1-40)"
    [[ -z "$slug" ]] && slug="side-task"
    base="${out_dir}/${ts}_${slug}"
    raw_file="${base}.raw.txt"
    payload_file="${base}.reply.txt"
    meta_file="${base}.json"

    local req_status=0
    if raw_out="$(nats_request "${device}.chat" "$prompt" "$timeout" 2>&1)"; then
        req_status=0
    else
        req_status=$?
    fi
    printf '%s\n' "$raw_out" > "$raw_file"
    payload="$(printf '%s\n' "$raw_out" | extract_nats_payload)"
    printf '%s\n' "$payload" > "$payload_file"

    python3 - "$meta_file" "$device" "$prompt" "$NATS_URL" "$timeout" "$raw_file" "$payload_file" "$req_status" <<'PY'
import json
import sys
from datetime import datetime, timezone

meta_path, device, prompt, nats_url, timeout, raw_file, payload_file, req_status = sys.argv[1:]
meta = {
    "timestamp_utc": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "device": device,
    "prompt": prompt,
    "nats_url": nats_url,
    "timeout": timeout,
    "request_exit_code": int(req_status),
    "request_ok": int(req_status) == 0,
    "raw_file": raw_file,
    "reply_file": payload_file,
}
with open(meta_path, "w", encoding="utf-8") as f:
    json.dump(meta, f, indent=2)
    f.write("\n")
PY

    if [[ "$req_status" -eq 0 ]]; then
        log "✅ Side-task dispatched and captured:"
    else
        log "❌ Side-task request failed (exit=${req_status}), raw output captured:"
    fi
    log "   raw:   $raw_file"
    log "   reply: $payload_file"
    log "   meta:  $meta_file"
    return "$req_status"
}

if [[ $# -lt 1 ]]; then
    usage
fi

case "$1" in
    validate) shift; cmd_validate "$@" ;;
    security-check) shift; cmd_security_check "$@" ;;
    side-task) shift; cmd_side_task "$@" ;;
    -h|--help) usage ;;
    *) echo "Unknown command: $1" >&2; usage ;;
esac
