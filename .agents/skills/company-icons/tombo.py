#!/usr/bin/env python3
"""Crop-mark / トンボ helper for company-icon low-visibility.

Aspect-fit the icon into a square (same as the iOS list), find the mark bounding
box against the background color (corner pixel, threshold 30), and print the
long side as a fraction of the square.

  python3 tombo.py ICON.png [ICON.png ...]
  python3 tombo.py ICON.png --overlay /tmp/icon-tombo.png

Below 70% = 低視認. After images should land at 80–88% (target 85%).
Overlay (optional) is a review PNG: red dashed 70%, green dashed 85%, blue bbox.
Do not commit overlay PNGs or icon binaries.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont

SQUARE = 400
MARGIN = 40
THRESHOLD = 30
LOW_VIS = 0.70
AFTER_TARGET = 0.85
FONTS = (
    "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
    "/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
)


def fit_square(img: Image.Image, size: int = SQUARE) -> Image.Image:
    img = img.convert("RGBA")
    bg = Image.new("RGBA", img.size, "white")
    bg.alpha_composite(img)
    img = bg.convert("RGB")
    w, h = img.size
    side = max(w, h)
    canvas = Image.new("RGB", (side, side), "white")
    canvas.paste(img, ((side - w) // 2, (side - h) // 2))
    return canvas.resize((size, size), Image.LANCZOS)


def mark_bbox(img: Image.Image, threshold: int = THRESHOLD):
    corner = img.getpixel((1, 1))
    bg = Image.new("RGB", img.size, corner)
    mask = ImageChops.difference(img, bg).convert("L").point(
        lambda p: 255 if p > threshold else 0
    )
    return mask.getbbox()


def dashed(draw: ImageDraw.ImageDraw, box, col, width: int = 2, dash: int = 8) -> None:
    x0, y0, x1, y1 = box
    for x in range(x0, x1, dash * 2):
        draw.line((x, y0, min(x + dash, x1), y0), fill=col, width=width)
        draw.line((x, y1, min(x + dash, x1), y1), fill=col, width=width)
    for y in range(y0, y1, dash * 2):
        draw.line((x0, y, x0, min(y + dash, y1)), fill=col, width=width)
        draw.line((x1, y, x1, min(y + dash, y1)), fill=col, width=width)


def _font(size: int) -> ImageFont.ImageFont:
    for path in FONTS:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def measure(img: Image.Image, size: int = SQUARE) -> dict:
    square = fit_square(img, size)
    bbox = mark_bbox(square)
    if bbox is None:
        return {
            "long": 0.0,
            "width": 0.0,
            "height": 0.0,
            "bbox": None,
            "square": square,
        }
    x0, y0, x1, y1 = bbox
    width = (x1 - x0) / size
    height = (y1 - y0) / size
    return {
        "long": max(width, height),
        "width": width,
        "height": height,
        "bbox": bbox,
        "square": square,
    }


def overlay(img: Image.Image, label: str, size: int = SQUARE, margin: int = MARGIN) -> Image.Image:
    stats = measure(img, size)
    square = stats["square"]
    bbox = stats["bbox"] or (0, 0, size, size)
    long = stats["long"]
    canvas_w = size + 2 * margin
    canvas = Image.new("RGB", (canvas_w, canvas_w + 60), (235, 235, 235))
    canvas.paste(square, (margin, margin))
    draw = ImageDraw.Draw(canvas)
    for cx, cy in (
        (margin, margin),
        (margin + size, margin),
        (margin, margin + size),
        (margin + size, margin + size),
    ):
        sx = -1 if cx == margin else 1
        sy = -1 if cy == margin else 1
        draw.line((cx + sx * 6, cy, cx + sx * 30, cy), fill="black", width=1)
        draw.line((cx, cy + sy * 6, cx, cy + sy * 30), fill="black", width=1)
    draw.line((margin + size // 2, margin - 30, margin + size // 2, margin - 8), fill="black")
    draw.line((margin + size // 2, margin + size + 8, margin + size // 2, margin + size + 30), fill="black")
    draw.line((margin - 30, margin + size // 2, margin - 8, margin + size // 2), fill="black")
    draw.line((margin + size + 8, margin + size // 2, margin + size + 30, margin + size // 2), fill="black")
    for ratio, col in ((LOW_VIS, (220, 40, 40)), (AFTER_TARGET, (30, 150, 60))):
        inset = int(size * (1 - ratio) / 2)
        dashed(draw, (margin + inset, margin + inset, margin + size - inset, margin + size - inset), col)
    x0, y0, x1, y1 = bbox
    draw.rectangle((margin + x0, margin + y0, margin + x1, margin + y1), outline=(0, 120, 255), width=2)
    ok = long >= LOW_VIS
    draw.text(
        (margin, margin + size + 18),
        f"{label}  long {long:.0%}  {'OK' if ok else 'low-vis'}",
        fill=(30, 130, 50) if ok else (200, 30, 30),
        font=_font(22),
    )
    return canvas


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Measure company-icon mark long-side % after aspect-fit (tombo / crop marks)."
    )
    parser.add_argument("images", nargs="+", type=Path, help="Icon image paths")
    parser.add_argument(
        "--overlay",
        type=Path,
        help="Write overlay PNG. One input: this file. Several: this directory.",
    )
    args = parser.parse_args(argv)

    overlay_dir = None
    overlay_file = None
    if args.overlay is not None:
        if len(args.images) == 1:
            overlay_file = args.overlay
            overlay_file.parent.mkdir(parents=True, exist_ok=True)
        else:
            overlay_dir = args.overlay
            overlay_dir.mkdir(parents=True, exist_ok=True)

    any_missing = False
    for path in args.images:
        if not path.is_file():
            print(f"{path}\tMISSING", file=sys.stderr)
            any_missing = True
            continue
        img = Image.open(path)
        stats = measure(img)
        long = stats["long"]
        verdict = "OK" if long >= LOW_VIS else "low-vis"
        print(
            f"{path}\tlong={long:.1%}\tw={stats['width']:.1%}\th={stats['height']:.1%}\t{verdict}"
        )
        if overlay_file is not None:
            overlay(img, path.stem).save(overlay_file)
            print(f"overlay\t{overlay_file}", file=sys.stderr)
        elif overlay_dir is not None:
            out = overlay_dir / f"{path.stem}-tombo.png"
            overlay(img, path.stem).save(out)
            print(f"overlay\t{out}", file=sys.stderr)
    return 1 if any_missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
