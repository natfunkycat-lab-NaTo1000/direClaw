#!/usr/bin/env bash
# WireClaw CYD companion helper
#
# Companion target: CYD 2432S028R + piggyback ESP32-S3 Nano
# Radio stack: nRF52/nRF24 + CC1101 + SX1267 + GPS L76K
#
# This helper standardizes:
#  - flash workflow for the companion profile
#  - TX/RX + SPI pin distribution reference

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEFAULT_ENV="esp32-s3-nano-companion"

usage() {
    cat <<'EOF'
Usage:
  wc-companion.sh flash [--port <serial>] [--env <platformio-env>] [--skip-fs]
  wc-companion.sh pinmap
  wc-companion.sh pinmap-json
  wc-companion.sh env
  wc-companion.sh prepare-assets --splash <file> --background <file> [--out-dir <dir>] [--width <px>] [--height <px>]

Commands:
  flash        Build + upload filesystem + flash firmware for companion profile
  pinmap       Print recommended TX/RX/SPI distribution table
  pinmap-json  Print the same mapping as JSON
  env          Print default PlatformIO environment name
  prepare-assets  Convert splash/background images into CYD-ready RGB565 assets

Examples:
  skill/wireclaw/scripts/wc-companion.sh flash --port /dev/ttyACM0
  skill/wireclaw/scripts/wc-companion.sh pinmap
  skill/wireclaw/scripts/wc-companion.sh pinmap-json
  skill/wireclaw/scripts/wc-companion.sh prepare-assets --splash ./image-4.jpg --background ./image-2.jpg
EOF
    exit 1
}

print_pinmap_table() {
    cat <<'EOF'
Companion profile: CYD 2432S028R + ESP32-S3 Nano piggyback

Inter-board link (CYD <-> S3 Nano):
  CYD RX <= S3 TX: GPIO16
  CYD TX => S3 RX: GPIO15

UART1 (dedicated module UART):
  RX: GPIO19
  TX: GPIO20
  Recommended module: GPS L76K

Shared SPI bus (for radios):
  SCK : GPIO12
  MISO: GPIO13
  MOSI: GPIO11

Per-module control pins:
  CC1101 (433 MHz sub-GHz):
    CS   : GPIO5
    GDO0 : GPIO4

  SX1267 (LoRa):
    CS   : GPIO6
    DIO1 : GPIO8
    BUSY : GPIO10
    RST  : GPIO9

  nRF24PA/LNA (2.4 GHz):
    CSN  : GPIO7
    CE   : GPIO3
    IRQ  : GPIO2

Notes:
  - Keep all radio modules on SPI, each with its own CS line.
  - Keep GPS on UART1 (19/20) to avoid bus contention.
  - Use level-safe wiring and shared GND across CYD/S3/modules.
EOF
}

print_pinmap_json() {
    cat <<'JSON'
{
  "profile": "cyd-2432s028r-esp32-s3-nano-companion",
  "interboard_uart": {
    "tx": 16,
    "rx": 15
  },
  "uart1": {
    "tx": 20,
    "rx": 19,
    "recommended_module": "gps-l76k"
  },
  "spi": {
    "sck": 12,
    "miso": 13,
    "mosi": 11
  },
  "modules": {
    "cc1101": {
      "cs": 5,
      "gdo0": 4
    },
    "sx1267": {
      "cs": 6,
      "dio1": 8,
      "busy": 10,
      "rst": 9
    },
    "nrf24pa_lna": {
      "csn": 7,
      "ce": 3,
      "irq": 2
    }
  }
}
JSON
}

cmd_flash() {
    local env="${DEFAULT_ENV}"
    local port=""
    local skip_fs="0"

    while [ $# -gt 0 ]; do
        case "$1" in
            --env)
                shift
                env="${1:?--env requires a value}"
                ;;
            --port)
                shift
                port="${1:?--port requires a value}"
                ;;
            --skip-fs)
                skip_fs="1"
                ;;
            -*)
                echo "Unknown flash option: $1" >&2
                usage
                ;;
            *)
                echo "Unexpected flash argument: $1" >&2
                usage
                ;;
        esac
        shift
    done

    local -a upload_args=()
    if [ -n "$port" ]; then
        upload_args+=(--upload-port "$port")
    fi

    if ! command -v pio >/dev/null 2>&1; then
        echo "Error: PlatformIO CLI ('pio') not found in PATH." >&2
        exit 1
    fi

    cd "$REPO_ROOT"
    if [ "$skip_fs" != "1" ]; then
        pio run -e "$env" -t uploadfs "${upload_args[@]}"
    fi
    pio run -e "$env" -t upload "${upload_args[@]}"
}

cmd_prepare_assets() {
    local splash=""
    local background=""
    local out_dir="$REPO_ROOT/assets/cyd/generated"
    local width="320"
    local height="240"

    while [ $# -gt 0 ]; do
        case "$1" in
            --splash)
                shift
                splash="${1:?--splash requires a value}"
                ;;
            --background)
                shift
                background="${1:?--background requires a value}"
                ;;
            --out-dir)
                shift
                out_dir="${1:?--out-dir requires a value}"
                ;;
            --width)
                shift
                width="${1:?--width requires a value}"
                ;;
            --height)
                shift
                height="${1:?--height requires a value}"
                ;;
            -*)
                echo "Unknown prepare-assets option: $1" >&2
                usage
                ;;
            *)
                echo "Unexpected prepare-assets argument: $1" >&2
                usage
                ;;
        esac
        shift
    done

    if [ -z "$splash" ] || [ -z "$background" ]; then
        echo "prepare-assets requires --splash <file> and --background <file>" >&2
        exit 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo "Error: python3 is required for asset conversion." >&2
        exit 1
    fi

    python3 "$REPO_ROOT/skill/wireclaw/scripts/wc-cyd-assets.py" \
        --splash "$splash" \
        --background "$background" \
        --out-dir "$out_dir" \
        --width "$width" \
        --height "$height"
}

if [ $# -lt 1 ]; then
    usage
fi

case "$1" in
    flash) shift; cmd_flash "$@" ;;
    pinmap) print_pinmap_table ;;
    pinmap-json) print_pinmap_json ;;
    env) echo "$DEFAULT_ENV" ;;
    prepare-assets) shift; cmd_prepare_assets "$@" ;;
    -h|--help) usage ;;
    *) echo "Unknown command: $1" >&2; usage ;;
esac
