#!/usr/bin/env python3
"""
Prepare CYD splash/background assets from source images.

Outputs:
  - splash.rgb565
  - background.rgb565
  - manifest.json
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Prepare CYD RGB565 assets")
    p.add_argument("--splash", required=True, help="Path to splash image")
    p.add_argument("--background", required=True, help="Path to background image")
    p.add_argument("--out-dir", required=True, help="Output directory")
    p.add_argument("--width", type=int, default=320, help="Target width in pixels")
    p.add_argument("--height", type=int, default=240, help="Target height in pixels")
    return p.parse_args()


def center_crop_to_ratio(img, width: int, height: int):
    src_w, src_h = img.size
    src_ratio = src_w / src_h
    dst_ratio = width / height

    if src_ratio > dst_ratio:
        new_w = int(src_h * dst_ratio)
        x0 = (src_w - new_w) // 2
        box = (x0, 0, x0 + new_w, src_h)
    else:
        new_h = int(src_w / dst_ratio)
        y0 = (src_h - new_h) // 2
        box = (0, y0, src_w, y0 + new_h)
    return img.crop(box)


def rgb888_to_rgb565(r: int, g: int, b: int) -> int:
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)


def convert_to_rgb565_bytes(img) -> bytes:
    pix = img.load()
    w, h = img.size
    out = bytearray(w * h * 2)
    k = 0
    for y in range(h):
        for x in range(w):
            r, g, b = pix[x, y]
            v = rgb888_to_rgb565(r, g, b)
            out[k] = (v >> 8) & 0xFF
            out[k + 1] = v & 0xFF
            k += 2
    return bytes(out)


def convert_one(*, name: str, src_path: Path, out_dir: Path, width: int, height: int) -> dict:
    try:
        from PIL import Image
    except ImportError as exc:
        raise SystemExit(
            "Pillow is required for image conversion. Install with: pip install pillow"
        ) from exc

    if not src_path.exists():
        raise SystemExit(f"Input image not found: {src_path}")

    with Image.open(src_path) as img:
        img = img.convert("RGB")
        img = center_crop_to_ratio(img, width, height)
        img = img.resize((width, height), Image.Resampling.LANCZOS)
        payload = convert_to_rgb565_bytes(img)

    out_path = out_dir / f"{name}.rgb565"
    out_path.write_bytes(payload)
    return {
        "name": name,
        "source": str(src_path),
        "output": str(out_path),
        "width": width,
        "height": height,
        "format": "RGB565_BE",
        "bytes": len(payload),
    }


def main() -> None:
    args = parse_args()
    if args.width <= 0 or args.height <= 0:
        raise SystemExit("width and height must be positive integers")

    out_dir = Path(args.out_dir).expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    splash = convert_one(
        name="splash",
        src_path=Path(args.splash).expanduser().resolve(),
        out_dir=out_dir,
        width=args.width,
        height=args.height,
    )
    background = convert_one(
        name="background",
        src_path=Path(args.background).expanduser().resolve(),
        out_dir=out_dir,
        width=args.width,
        height=args.height,
    )

    manifest = {
        "profile": "cyd-2432s028r-esp32-s3-nano-companion",
        "target_resolution": {"width": args.width, "height": args.height},
        "assets": [splash, background],
    }
    manifest_path = out_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(f"Generated assets in: {out_dir}")
    print(f"  - {splash['output']}")
    print(f"  - {background['output']}")
    print(f"  - {manifest_path}")


if __name__ == "__main__":
    main()
