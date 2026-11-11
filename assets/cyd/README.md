# CYD Screen Assets

Place your source splash/background images here (or anywhere on disk), then run:

```bash
pip install pillow

skill/wireclaw/scripts/wc-companion.sh prepare-assets \
  --splash ./image-4.jpg \
  --background ./image-2.jpg \
  --out-dir ./assets/cyd/generated
```

Generated output:
- `splash.rgb565`
- `background.rgb565`
- `manifest.json`

Default target resolution is `320x240` (CYD 2432 class).
