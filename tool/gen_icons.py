"""Generates flDoc icons: assets/icons/app.png, tray.png and windows app_icon.ico.

Run: python tool/gen_icons.py
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent


def draw_icon(size: int) -> Image.Image:
    s = 4  # supersample
    n = size * s
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Background: rounded square with vertical gradient (Fluent blue).
    top, bottom = (0x2B, 0x88, 0xD8), (0x00, 0x5A, 0x9E)
    grad = Image.new("RGBA", (n, n))
    gd = ImageDraw.Draw(grad)
    for y in range(n):
        t = y / (n - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        gd.line([(0, y), (n, y)], fill=c)
    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, n - 1, n - 1], radius=int(n * 0.22), fill=255)
    img.paste(grad, (0, 0), mask)
    # Document sheet.
    m = n * 0.24
    x0, y0, x1, y1 = m, n * 0.18, n - m, n * 0.82
    fold = n * 0.14
    sheet = [(x0, y0), (x1 - fold, y0), (x1, y0 + fold), (x1, y1), (x0, y1)]
    d.polygon(sheet, fill=(255, 255, 255, 245))
    d.polygon([(x1 - fold, y0), (x1 - fold, y0 + fold), (x1, y0 + fold)], fill=(0xC7, 0xE0, 0xF4, 255))
    # Text lines.
    lw = max(1, int(n * 0.045))
    lx0 = x0 + n * 0.08
    for i, frac in enumerate([0.62, 0.78, 0.70, 0.52]):
        y = y0 + n * 0.22 + i * n * 0.11
        d.rounded_rectangle([lx0, y, lx0 + (x1 - x0 - n * 0.16) * frac, y + lw], radius=lw // 2,
                            fill=(0x00, 0x67, 0xC0, 255) if i == 0 else (0x7A, 0x95, 0xAD, 255))
    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    icons = ROOT / "assets" / "icons"
    icons.mkdir(parents=True, exist_ok=True)
    draw_icon(256).save(icons / "app.png")
    draw_icon(32).save(icons / "tray.png")
    ico = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
    big = draw_icon(256)
    big.save(ico, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("icons written")


if __name__ == "__main__":
    main()
