#!/usr/bin/env python3
# The dccli commands for a deck of every preset in DCGeometry's gallery (Preset.swift's catalog), the shapes test of
# the legacy import (Docs/plans/Legacy-PPT-and-Encryption.md, P3). Each preset appears three times, in a column: wide
# at its default adjusts, tall at its default adjusts, and wide with every adjust moved off its default. Saved as
# .ppt by LibreOffice and by PowerPoint, the deck shows how each writes a preset's type and adjusts, and the import
# is checked against the original shape by shape.
#
#   Tools/legacy/preset-deck.py PRESET.swift  →  one `--cmd …` argument per line, for `dccli run`
import json
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
catalog = src[src.index("public static let catalog"):]
catalog = catalog[:catalog.index("\n    ]\n")]
presets = []
for m in re.finditer(r'p\("(\w+)", "[^"]*", \.\w+(?:, \[([^\]]*)\])?\)', catalog):
    name, defaults = m.group(1), m.group(2)
    if name == "textBox":
        continue
    presets.append((name, [float(v) for v in defaults.split(",")] if defaults else []))


def moved(d):
    """An adjust value off its default: 0 becomes 10% of the reference, the rest move by a third toward 0."""
    return 10000 if d == 0 else round(d * 2 / 3)


cols, cell = 6, 160
cmds = []
for i in range(0, len(presets), cols):
    cmds.append('slide.new={"layout":"blank"}')
    for c, (name, defaults) in enumerate(presets[i:i + cols]):
        x = 10 + c * cell
        for row, (w, h, adj) in enumerate([(140, 84, None), (84, 140, None), (140, 84, [moved(d) for d in defaults])]):
            y = [20, 120, 280][row]
            cmds.append("shape.insert=" + json.dumps({"preset": name, "rect": [x, y, w, h]}))
            for k, v in enumerate(adj or []):
                cmds.append("shape.adjust=" + json.dumps({"index": k, "value": v}))
for c in cmds:
    print("--cmd")
    print(c)
