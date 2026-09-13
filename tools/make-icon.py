#!/usr/bin/env python3
"""Generate the Kioku app icon (monochrome: ink background, paper card, 記).

Usage: python tools/make-icon.py [out.png]
Writes a 1024x1024 PNG (no alpha, as iOS requires for app icons).
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

S = 1024
INK = (26, 26, 26)
PAPER = (255, 255, 255)
SHADOW = (74, 74, 74)

FONT_CANDIDATES = [
    (r"C:\Windows\Fonts\YuGothB.ttc", 0),
    (r"C:\Windows\Fonts\BIZ-UDGothicB.ttc", 0),
    (r"C:\Windows\Fonts\meiryob.ttc", 0),
    (r"C:\Windows\Fonts\msgothic.ttc", 0),
    ("/System/Library/Fonts/ヒラギノ角ゴシック W7.ttc", 0),
    ("/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc", 0),
]


def load_font(size):
    for path, index in FONT_CANDIDATES:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size, index=index)
            except Exception:
                continue
    return None


def main(out_path):
    img = Image.new("RGB", (S, S), INK)
    d = ImageDraw.Draw(img)

    # Card geometry: a portrait card, centred, with a second card peeking behind.
    cw, ch = 512, 660
    cx, cy = S // 2, S // 2 + 8
    front = (cx - cw // 2, cy - ch // 2, cx + cw // 2, cy + ch // 2)
    off = 44
    back = (front[0] + off, front[1] - off, front[2] + off, front[3] - off)

    d.rounded_rectangle(back, radius=56, fill=SHADOW)
    d.rounded_rectangle(front, radius=56, fill=PAPER)

    # 記 on the front card.
    glyph = "記"
    font = load_font(340)
    if font is not None:
        box = d.textbbox((0, 0), glyph, font=font)
        gw, gh = box[2] - box[0], box[3] - box[1]
        d.text((cx - gw / 2 - box[0], cy - gh / 2 - box[1] - 18), glyph, font=font, fill=INK)
    else:  # geometric fallback: three ruled lines
        for i, w in enumerate((300, 300, 190)):
            y = cy - 60 + i * 78
            d.rounded_rectangle((cx - w // 2, y, cx + w // 2, y + 26), radius=13, fill=INK)

    # A short rule under the glyph, echoing the reviewer's answer divider.
    rw = 168
    ry = front[3] - 104
    d.rounded_rectangle((cx - rw // 2, ry, cx + rw // 2, ry + 12), radius=6, fill=(184, 184, 184))

    img.save(out_path, "PNG")
    print(f"wrote {out_path} ({img.size[0]}x{img.size[1]}, mode={img.mode})")


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "app/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    main(out)
