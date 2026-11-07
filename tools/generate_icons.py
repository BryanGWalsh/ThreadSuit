#!/usr/bin/env python3
"""Generate Thread Suit's app icons for macOS, Windows and Linux from one PNG.

Usage: python3 tools/generate_icons.py [source.png]
Default source: docs/Icon.png.
Needs Pillow (pip install pillow). Safe to run again: it overwrites only the
generated files listed below.

  macOS    macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{16..1024}.png
  Windows  windows/runner/resources/app_icon.ico (16, 24, 32, 48, 64, 128, 256)
  Linux    linux/runner/resources/app_icon.png (256; the window icon, installed
           into the app bundle) and linux/packaging/icons/hicolor/<n>x<n>/apps/
           io.github.bryangwalsh.thread_suit.png (16 to 512, for the desktop entry)

The artwork is cropped to its visible pixels and centred. macOS icons follow
Apple's grid (the artwork is 824 of 1024 pixels, with a transparent margin);
Windows and Linux icons fill 92% of the square.
"""
import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_ID = "io.github.bryangwalsh.thread_suit"
MAC_SIZES = [16, 32, 64, 128, 256, 512, 1024]
WIN_SIZES = [16, 24, 32, 48, 64, 128, 256]
LINUX_SIZES = [16, 24, 32, 48, 64, 128, 256, 512]


def load(path):
    im = Image.open(path).convert("RGBA")
    box = im.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()
    if box is None:
        sys.exit(f"{path} is fully transparent")
    art = im.crop(box)
    if max(art.size) < 512:
        print(f"warning: the artwork is only {art.size[0]}x{art.size[1]}; large icons will be blurry")
    return art


def square(art, size, fill):
    """[art] scaled to [fill] of a [size] square, centred, on transparency."""
    target = max(1, round(size * fill))
    w, h = art.size
    scale = target / max(w, h)
    scaled = art.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(scaled, ((size - scaled.width) // 2, (size - scaled.height) // 2), scaled)
    return canvas


def save(im, *parts):
    path = os.path.join(ROOT, *parts)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    im.save(path, optimize=True)
    return os.path.relpath(path, ROOT)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "docs", "Icon.png")
    art = load(src)
    written = []

    mac_fill = 824 / 1024
    for n in MAC_SIZES:
        written.append(save(square(art, n, mac_fill), "macos/Runner/Assets.xcassets/AppIcon.appiconset", f"app_icon_{n}.png"))

    # Each size of the .ico is drawn from the full artwork, not scaled down from 256.
    ico = os.path.join(ROOT, "windows/runner/resources/app_icon.ico")
    big = square(art, 256, 0.92)
    big.save(ico, format="ICO", sizes=[(n, n) for n in WIN_SIZES],
             append_images=[square(art, n, 0.92) for n in WIN_SIZES[:-1]])
    written.append(os.path.relpath(ico, ROOT))

    written.append(save(square(art, 256, 0.92), "linux/runner/resources/app_icon.png"))
    for n in LINUX_SIZES:
        written.append(save(square(art, n, 0.92), "linux/packaging/icons/hicolor", f"{n}x{n}", "apps", f"{APP_ID}.png"))

    print("\n".join(written))


if __name__ == "__main__":
    main()
