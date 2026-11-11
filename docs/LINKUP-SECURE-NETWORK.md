# Secure Link-Up, Validation, and Side-Task Flow

This guide covers PC/mobile visibility checks and secure remote link-up for
DireClaw/WireClaw nodes on:
- Home LAN (WiFi + NATS)
- Remote mesh (Tailscale + SSH)

It also includes side-task dispatch so a prompt can be sent to a device and the
response saved into a local files folder.

## Helper Script

Use:

```bash
skill/wireclaw/scripts/wc-linkup.sh --help
```

Main commands:
- `validate` — connectivity + visibility validation
- `security-check` — auth posture checks
- `side-task` — send prompt and capture response to files

## 1) Validate WiFi/NATS/BLE/Radio Visibility

```bash
skill/wireclaw/scripts/wc-linkup.sh validate \
  --device wireclaw-01 \
  --require-auth \
  --expect-device chip_temp \
  --expect-device clock_hhmm \
  --tailscale-host wireclaw-node \
  --ssh-target user@wireclaw-node
```

Optional BLE visibility:

```bash
skill/wireclaw/scripts/wc-linkup.sh validate \
  --device wireclaw-01 \
  --ble-name "DireClaw" \
  --ble-mac "AA:BB:CC:DD:EE:FF"
```

For sub-GHz/nRF visibility, register each module path as named devices/sensors
and validate with repeated `--expect-device` flags.

## 2) Security Posture Check

```bash
skill/wireclaw/scripts/wc-linkup.sh security-check \
  --require-auth \
  --require-tailscale \
  --require-ssh
```

What this checks:
- NATS auth material present (URL creds or `NATS_*` env vars)
- Tailscale daemon reachable
- SSH key material available

## 3) Side-Question / Overlay Prompt Transfer

Send a side question to the device AI and save output to local files:

```bash
skill/wireclaw/scripts/wc-linkup.sh side-task \
  --device wireclaw-01 \
  --prompt "Investigate BLE packet loss and suggest mitigation steps." \
  --out-dir ./files/side-tasks \
  --tag ble-loss
```

Generated files:
- `*.raw.txt` — raw NATS CLI output
- `*.reply.txt` — extracted reply payload
- `*.json` — metadata (timestamp, device, request status)

## Secure Handshake Guidance

For practical secure operation:
- Use WPA2/WPA3 on WiFi.
- Require NATS auth (credentials/token) and avoid open brokers.
- Use Tailscale for remote reachability and ACL restrictions.
- Use SSH key auth for remote shell access (avoid plaintext password workflows).

This gives a secure, reachable network array across phone/PC/tablet when on the
same LAN or connected through Tailscale.
