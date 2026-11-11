# WireClaw - OpenClaw Skill

Control physical hardware from OpenClaw. WireClaw runs on ESP32 microcontrollers
and executes tool calls directly on LEDs, GPIO pins, relays, and sensors via NATS.

## Requirements

- [NATS CLI](https://github.com/nats-io/natscli) (`nats` binary in PATH)
- NATS server accessible from both OpenClaw and WireClaw (default port 4222)
- One or more WireClaw devices on the same network

## Installation

```bash
openclaw install wireclaw
```

Or manually copy the `skill/wireclaw/` folder to `~/.openclaw/workspace/skills/wireclaw/`.

## Configuration

Set `WIRECLAW_NATS_URL` if your NATS server is not at `localhost:4222`:

```bash
export WIRECLAW_NATS_URL="nats://192.168.1.100:4222"
```

## Quick Start

```bash
# Discover devices on the network
scripts/wc.sh discover

# Set LED green on a device
scripts/wc.sh exec wireclaw-01 led_set '{"r":0,"g":255,"b":0}'

# Read chip temperature
scripts/wc.sh exec wireclaw-01 sensor_read '{"name":"chip_temp"}'

# Query device capabilities
scripts/wc.sh caps wireclaw-01

# Create a persistent automation rule
scripts/wc.sh exec wireclaw-01 rule_create '{"rule_name":"heat alert","sensor_name":"chip_temp","condition":"gt","threshold":35,"on_action":"led_set","on_r":255,"on_g":0,"on_b":0,"off_action":"led_set","off_r":0,"off_g":255,"off_b":0}'
```

## Governance Orchestration CLI

`wc.sh` also includes a multi-agent governance orchestration command for
full-stack level orchestration with serial/parallel execution and vectorized
task expansion:

```bash
# Print a starter plan
scripts/wc.sh plan-template

# Validate and expand without executing
scripts/wc.sh orchestrate @plan.json --dry-run

# Execute with conversational output and write full log
scripts/wc.sh orchestrate @plan.json --max-parallel 8 --timeout 12s --log-file ./run-log.json

# Machine-readable summary output
scripts/wc.sh orchestrate @plan.json --json

# CYD 2432S028R + ESP32-S3 Nano companion helper
scripts/wc-companion.sh pinmap
scripts/wc-companion.sh flash --port /dev/ttyACM0
scripts/wc-companion.sh prepare-assets --splash ./image-4.jpg --background ./image-2.jpg
```

Plan highlights:
- **Multi-level governance:** levels execute top-down
- **Per-level ordinance controls:** `on_error` (`halt`/`continue`), `min_success_ratio`
- **Series or parallel per level:** `mode`
- **Vectorized multiplex duties:** one task can fan out across devices and vectors

See `SKILL.md` for the full tool reference and automation patterns.

## Links

- [WireClaw](https://wireclaw.io) - Project homepage
- [WireClaw GitHub](https://github.com/M64GitHub/WireClaw) - Source code
