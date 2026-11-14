#!/usr/bin/env python3
"""Runs a badge game on a computer with a stand-in badge API and saves screenshots.

    pip install lupa pillow
    python3 tools/sim.py pong out_dir

This is a rough preview for development only. The real test is "Try in
emulator" on the badge site, then "Run on badge".
"""
import os
import sys

from lupa import lua54
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
THEME = {
    "text": 0xFFFFFF, "dim": 0x8A8AA0, "bg": 0x0B0B14, "panel": 0x1C1C2B,
    "border": 0x3A3A55, "purple": 0x9945FF, "green": 0x14F195, "pink": 0xEB54BC,
    "lpurple": 0xC4A4FF, "blue": 0x2F80ED, "aqua": 0x00C2FF, "lime": 0xB4F000,
    "yellow": 0xFFD84D, "orange": 0xFF754A,
}
ART = {"#": 0xFFFFFF, "k": 0, "w": 0xFFFFFF, "p": 0x9945FF, "g": 0x14F195, "m": 0xEB54BC,
       "v": 0xC4A4FF, "b": 0x2F80ED, "a": 0x00C2FF, "l": 0xB4F000, "y": 0xFFD84D, "o": 0xFF754A}
STATUS_H = 22  # status bar above the app area (screen is 320 x 240)


def rgb(c):
    if isinstance(c, str):
        c = THEME[c]
    c = int(c)
    return ((c >> 16) & 255, (c >> 8) & 255, c & 255)


def font(size):
    for name in ("DejaVuSans-Bold.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            pass
    return ImageFont.load_default()


class Sim:
    def __init__(self, app):
        self.lua = lua54.LuaRuntime(unpack_returned_tuples=True)
        self.M = self.lua.eval(f'dofile("{os.path.join(HERE, "badge_mock.lua")}")')
        self.M.run(os.path.join(HERE, "..", app))
        self.g = self.lua.globals()

    def press(self, key, rep=False):
        self.M.press(key, rep)

    def hold(self, keys):
        self.M.keys = self.lua.table_from({k: True for k in keys})

    def tick(self, ms=30, n=1):
        for _ in range(n):
            self.M.tick(ms)

    def render(self, path, scale=2):
        img = Image.new("RGB", (320, 240), rgb(THEME["bg"]))
        d = ImageDraw.Draw(img)
        # status bar
        d.rectangle([0, 0, 319, STATUS_H - 1], fill=(20, 20, 30))
        d.text((6, 4), "SOLANA OS", fill=rgb("dim"), font=font(11))
        leds = self.M.leds
        for i in range(1, 7):
            c = leds[i]
            col = (c[1], c[2], c[3]) if c else (40, 40, 55)
            d.ellipse([200 + i * 16, 7, 208 + i * 16, 15], fill=col)
        oy = STATUS_H
        bg = self.M.bg
        d.rectangle([0, oy, 319, 239], fill=rgb(bg if bg is not None else "bg"))
        for o in self.M.objects.values():
            if o.removed or not o.visible:
                continue
            x, y = int(o.x), int(o.y) + oy
            k = o.kind
            if k == "rect":
                r = o.opts.radius or 0
                d.rounded_rectangle([x, y, x + o.w - 1, y + o.h - 1], radius=r, fill=rgb(o.col),
                                    outline=rgb(o.opts.border) if o.opts.border else None)
            elif k == "gradient":
                for i in range(o.w):
                    t = i / max(1, o.w - 1)
                    c = tuple(int(a + (b - a) * t) for a, b in zip(rgb(0x9945FF), rgb(0x14F195)))
                    d.line([x + i, y, x + i, y + o.h - 1], fill=c)
            elif k == "image":
                pal = o.palette
                for ry, row in enumerate(o.rows.values()):
                    for rx, ch in enumerate(row):
                        if ch in ". ":
                            continue
                        c = pal[ch] if pal and pal[ch] is not None else ART[ch]
                        img.putpixel((x + rx, y + ry), rgb(c)) if 0 <= x + rx < 320 and 0 <= y + ry < 240 else None
            elif k == "label":
                size = o.opts.size or 14
                f = font(int(size * 0.85))
                txt = str(o.txt)
                w = o.opts.w
                tw = d.textlength(txt, font=f)
                tx = x
                if w and o.opts.align == "center":
                    tx = x + (w - tw) / 2
                elif w and o.opts.align == "right":
                    tx = x + w - tw
                d.text((tx, y), txt, fill=rgb(o.col), font=f)
            elif k == "list":
                d.rectangle([x, y, x + o.w - 1, y + o.h - 1], fill=rgb("panel"))
                for i, it in enumerate(o._items.values()):
                    ry = y + i * 36
                    if ry + 36 > y + o.h:
                        break
                    if i + 1 == o.sel:
                        d.rectangle([x, ry, x + o.w - 1, ry + 35], fill=rgb("border"))
                    title = it if isinstance(it, str) else it.title
                    d.text((x + 10, ry + 10), str(title), fill=rgb("text"), font=font(13))
                    if not isinstance(it, str) and it.right:
                        rt = str(it.right)
                        d.text((x + o.w - 10 - d.textlength(rt, font=font(11)), ry + 12), rt,
                               fill=rgb("dim"), font=font(11))
        hint = self.M.hint
        if hint:
            d.rectangle([0, 224, 319, 239], fill=(20, 20, 30))
            d.text((6, 226), str(hint), fill=rgb("dim"), font=font(10))
        img = img.resize((320 * scale, 240 * scale), Image.NEAREST)
        img.save(path)


def main():
    app = sys.argv[1] if len(sys.argv) > 1 else "pong"
    out = sys.argv[2] if len(sys.argv) > 2 else "."
    os.makedirs(out, exist_ok=True)
    s = Sim(app)
    s.render(os.path.join(out, "1-menu.png"))
    s.press("select")                 # Normal
    s.tick(30, 10)
    s.render(os.path.join(out, "2-serve.png"))
    s.tick(30, 40)
    s.render(os.path.join(out, "3-play.png"))


if __name__ == "__main__":
    main()
