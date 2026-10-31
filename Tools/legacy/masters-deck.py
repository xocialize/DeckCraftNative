#!/usr/bin/env python3
# The dccli commands for a deck whose template has graphics of its own, the masters test of the legacy import
# (Docs/plans/Legacy-PPT-and-Encryption.md, P6):
# - the slide master: a banner bar, a logo picture, a rule and a text box;
# - the Title Slide layout: a shape and a background of its own;
# - title and content slides, one of each hiding the background graphics.
# Saved as .ppt by LibreOffice and by PowerPoint, the master becomes a main master and (PowerPoint) the Title Slide
# layout a title master.
#
#   Tools/legacy/masters-deck.py  →  one `--cmd …` argument per line, for `dccli run`
import base64
import json
import struct
import zlib


def png(w, h, pixel):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = b"".join(b"\0" + b"".join(bytes(pixel(x, y)) for x in range(w)) for y in range(h))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def logo(x, y):
    # A two-colour square with a diagonal.
    return (31, 78, 121) if x > y else (244, 177, 131)


def cmd(name, params):
    return f"{name}=" + json.dumps(params)


logo_png = base64.b64encode(png(48, 48, logo)).decode()
cmds = []

# 1. The slide master's own graphics.
cmds.append(cmd("view.slideMaster", {"master": 0}))
cmds.append(cmd("shape.insert", {"preset": "rect", "rect": [0, 0, 960, 36]}))
cmds.append(cmd("shape.fill", {"color": "#1F4E79"}))
cmds.append(cmd("shape.line", {"none": True}))
cmds.append(cmd("insert.picture", {"data": logo_png, "name": "logo.png", "rect": [880, 470, 48, 48]}))
cmds.append(cmd("shape.insert", {"preset": "line", "rect": [40, 460, 820, 0]}))
cmds.append(cmd("shape.line", {"color": "#C55A11", "width": 2}))
cmds.append(cmd("insert.textBox", {"rect": [40, 490, 400, 30], "text": "Company Confidential"}))

# 2. The Title Slide layout's own shape and background.
cmds.append(cmd("view.slideMaster", {"master": 0, "layout": 0}))
cmds.append(cmd("shape.insert", {"preset": "ellipse", "rect": [700, 60, 200, 200]}))
cmds.append(cmd("shape.fill", {"color": "#F4B183"}))
cmds.append(cmd("design.background", {"color": "#E2F0D9"}))
cmds.append(cmd("view.closeMaster", {}))

# 3. Slides: a title slide, content slides, and one of each hiding the background graphics.
cmds.append(cmd("slide.new", {"layout": "title", "title": "Title slide"}))
cmds.append(cmd("slide.new", {"layout": "titleOnly", "title": "Content slide"}))
cmds.append(cmd("slide.new", {"layout": "titleOnly", "title": "Content, no background graphics"}))
cmds.append(cmd("design.hideBackgroundGraphics", {"hide": True}))
cmds.append(cmd("slide.new", {"layout": "title", "title": "Title, no background graphics"}))
cmds.append(cmd("design.hideBackgroundGraphics", {"hide": True}))

for c in cmds:
    print("--cmd")
    print(c)
