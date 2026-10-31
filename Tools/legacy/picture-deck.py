#!/usr/bin/env python3
# The dccli commands for a deck of pictures, the pictures test of the legacy import (Docs/plans/
# Legacy-PPT-and-Encryption.md, P4): pictures cropped, corrected, recoloured and with a transparent colour; shapes filled
# with a picture, stretched and tiled, and with patterns; slide backgrounds of a picture, stretched and tiled, and of a
# pattern; and comments. Saved as .ppt by LibreOffice and by PowerPoint, it shows how each writes them.
#
#   Tools/legacy/picture-deck.py PHOTO.jpg  →  one `--cmd …` argument per line, for `dccli run`
# The PNGs are made here; PHOTO.jpg is any JPEG (make-fixtures.sh makes one with sips from `--png`'s output).
#   Tools/legacy/picture-deck.py --png OUT.png  writes the photo-like PNG the JPEG is made from
import base64
import json
import struct
import sys
import zlib


def png(w, h, pixel):
    """An 8-bit RGBA PNG whose pixel (x, y) is pixel(x, y) → (r, g, b, a)."""
    rows = b"".join(b"\0" + bytes(c for x in range(w) for c in pixel(x, y)) for y in range(h))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def photo(x, y):
    """A smooth colour field with a white disc: something crops, corrections and a transparent colour change visibly."""
    if (x - 120) ** 2 + (y - 80) ** 2 < 40 ** 2:
        return (255, 255, 255, 255)
    return (40 + x * 200 // 240, 60 + y * 180 // 160, 200 - (x + y) * 150 // 400, 255)


def tile(x, y):
    """A small two-colour tile with a transparent corner, for tiled fills and backgrounds."""
    if x < 8 and y < 8:
        return (0, 0, 0, 0)
    return (230, 120, 30, 255) if (x // 8 + y // 8) % 2 else (30, 90, 200, 255)


if sys.argv[1] == "--png":
    open(sys.argv[2], "wb").write(png(240, 160, photo))
    sys.exit(0)

photo_png = base64.b64encode(png(240, 160, photo)).decode()
tile_png = base64.b64encode(png(32, 32, tile)).decode()
jpeg = base64.b64encode(open(sys.argv[1], "rb").read()).decode()


def cmd(name, params):
    return f"{name}=" + json.dumps(params)


cmds = []
# 1. Pictures: as inserted, cropped, corrected, recoloured, with a transparent colour, and a JPEG.
cmds.append(cmd("slide.new", {"layout": "blank"}))
cells = [(20, 20), (250, 20), (480, 20), (710, 20), (20, 280), (250, 280), (480, 280), (710, 280)]
edits = [
    [],
    [("picture.crop", {"left": 0.1, "top": 0.2, "right": 0.25, "bottom": 0.05})],
    [("picture.adjust", {"brightness": 0.3, "contrast": -0.2})],
    [("picture.recolor", {"preset": "grayscale"})],
    [("picture.recolor", {"preset": "bw50"})],
    [("picture.recolor", {"preset": "washout"})],
    [("picture.transparentColor", {"color": "#FFFFFF"})],
]
for (x, y), e in zip(cells, edits):
    cmds.append(cmd("insert.picture", {"data": photo_png, "name": "photo.png", "rect": [x, y, 210, 140]}))
    cmds += [cmd(n, p) for n, p in e]
cmds.append(cmd("insert.picture", {"data": jpeg, "name": "photo.jpg", "rect": [710, 280, 210, 140]}))

# 2. Shapes filled with a picture, stretched and tiled, and with patterns.
cmds.append(cmd("slide.new", {"layout": "blank"}))
cmds.append(cmd("shape.insert", {"preset": "ellipse", "rect": [20, 20, 280, 180]}))
cmds.append(cmd("shape.fill", {"picture": photo_png}))
cmds.append(cmd("shape.insert", {"preset": "rect", "rect": [340, 20, 280, 180]}))
cmds.append(cmd("shape.fill", {"picture": tile_png, "pictureProps": {"tile": True}}))
cmds.append(cmd("shape.insert", {"preset": "roundRect", "rect": [660, 20, 280, 180]}))
cmds.append(cmd("shape.fill", {"picture": jpeg}))
for i, preset in enumerate(["pct50", "dkDnDiag", "smGrid", "horz", "lgCheck", "openDmnd"]):
    cmds.append(cmd("shape.insert", {"preset": "rect", "rect": [20 + i * 155, 260, 140, 140]}))
    cmds.append(cmd("shape.fill", {"pattern": {"preset": preset, "fg": "#1F4E79", "bg": "#F4B183"}}))

# 3–5. Backgrounds: a picture stretched, a picture tiled, a pattern.
cmds.append(cmd("slide.new", {"layout": "titleOnly", "title": "Picture background"}))
cmds.append(cmd("design.background", {"picture": photo_png}))
cmds.append(cmd("slide.new", {"layout": "titleOnly", "title": "Tiled background"}))
cmds.append(cmd("design.background", {"picture": tile_png, "pictureProps": {"tile": True}}))
cmds.append(cmd("slide.new", {"layout": "titleOnly", "title": "Pattern background"}))
cmds.append(cmd("design.background", {"pattern": {"preset": "dkUpDiag", "fg": "#385723", "bg": "#E2F0D9"}}))

# 6. Comments.
cmds.append(cmd("slide.new", {"layout": "titleOnly", "title": "Comments"}))
cmds.append(cmd("comment.add", {"text": "First comment", "x": 100, "y": 120}))
cmds.append(cmd("comment.add", {"text": "Second comment, with more words", "x": 500, "y": 300}))

for c in cmds:
    print("--cmd")
    print(c)
