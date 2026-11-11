# CYD 2432S028R + ESP32-S3 Nano Companion Helper

This profile is for a **CYD 2432S028R** front-end paired with a piggyback
**ESP32-S3 Nano** companion node that runs WireClaw.

It standardizes flash commands and a practical TX/RX/SPI distribution for mixed
radio + GPS stacks (nRF56/84x, CC1101, SX1267, nRF24PA/LNA, L76K GPS).

## Flashing

Use the companion helper:

```bash
skill/wireclaw/scripts/wc-companion.sh flash --port /dev/ttyACM0
```

Default PlatformIO env:

```bash
esp32-s3-nano-companion
```

Direct PlatformIO (equivalent):

```bash
pio run -e esp32-s3-nano-companion -t uploadfs
pio run -e esp32-s3-nano-companion -t upload
```

## TX/RX + Bus Distribution

### Inter-board UART (CYD <-> S3 Nano)

- **S3 TX = GPIO16** -> CYD RX
- **S3 RX = GPIO15** <- CYD TX

Use this for control-plane traffic between display/UI (CYD) and the companion.

### Dedicated module UART (UART1)

- **RX = GPIO19**
- **TX = GPIO20**

Use UART1 for devices that benefit from a clean serial line (recommended:
**GPS L76K**).

### Shared SPI (radio plane)

- **SCK = GPIO12**
- **MISO = GPIO13**
- **MOSI = GPIO11**

All radios share SPI, each with a unique CS/control line:

| Module | Pins |
|---|---|
| CC1101 (sub-GHz 433 MHz) | `CS=5`, `GDO0=4` |
| SX1267 (LoRa) | `CS=6`, `DIO1=8`, `BUSY=10`, `RST=9` |
| nRF24PA/LNA (2.4 GHz) | `CSN=7`, `CE=3`, `IRQ=2` |

## Quick Pinmap Output

```bash
skill/wireclaw/scripts/wc-companion.sh pinmap
skill/wireclaw/scripts/wc-companion.sh pinmap-json
```

## Design Notes

- Keep **GPS on UART1** and **radios on SPI** to avoid UART contention.
- Keep inter-board UART separate from module UART.
- Share GND across CYD, ESP32-S3 Nano, and all peripherals.
- If using an nRF56/84x sidecar (for example nRF52840-class), connect it
  through the inter-board UART pair unless you intentionally move it onto SPI.
