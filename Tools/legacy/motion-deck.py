#!/usr/bin/env python3
# The dccli commands for a deck of transitions and animations, the slide show test of the legacy import (Docs/plans/
# Legacy-PPT-and-Encryption.md, P5):
# - one slide per transition a .ppt can hold, at each speed, with directions and options, then two it can't (they
#   become Fade), a slide that advances on its own, and a hidden slide;
# - slides of the common entrance, emphasis, exit and motion path effects with their options;
# - a slide of timings: each start, a delay, a duration, a repeat, rewind, and text built by paragraph and by word.
# Saved as .ppt by LibreOffice and by PowerPoint, it shows how each writes them.
#
#   Tools/legacy/motion-deck.py  →  one `--cmd …` argument per line, for `dccli run`
import json


def cmd(name, params):
    return f"{name}=" + json.dumps(params)


cmds = []

# 1. Transitions: (kind, option, duration). The durations are PowerPoint's three .ppt speeds: fast, medium and slow.
transitions = [
    ("fade", "smoothly", 500), ("fade", "throughBlack", 750), ("cut", "throughBlack", 500), ("push", "u", 1000),
    ("push", "r", 500), ("wipe", "l", 750), ("wipe", "d", 1000), ("wipe", "ru", 500), ("split", "vertIn", 750),
    ("split", "horzOut", 1000), ("randomBar", "vert", 500), ("cover", "ld", 750), ("cover", "u", 1000),
    ("uncover", "rd", 500), ("uncover", "l", 750), ("shape", "circle", 1000), ("shape", "diamond", 500),
    ("shape", "plus", 750), ("shape", "in", 1000), ("shape", "out", 500), ("blinds", "vert", 750),
    ("checker", "vert", 1000), ("comb", "horz", 500), ("dissolve", "", 750), ("clock", "wedge", 1000),
    ("clock", "clockwise", 500), ("zoom", "rotate", 750), ("random", "", 1000),
    # No .ppt equivalent: PowerPoint keeps Fade.
    ("vortex", "l", 1000), ("ripple", "center", 500),
]
for kind, option, ms in transitions:
    cmds.append(cmd("slide.new", {"layout": "titleOnly", "title": f"{kind} {option} {ms}"}))
    params = {"kind": kind, "duration": ms}
    if option:
        params["option"] = option
    cmds.append(cmd("transition.set", params))
cmds.append(cmd("slide.new", {"layout": "titleOnly", "title": "Advances after 3 s"}))
cmds.append(cmd("transition.set", {"kind": "fade", "option": "smoothly", "duration": 500}))
cmds.append(cmd("transition.timing", {"onClick": False, "after": 3000}))
cmds.append(cmd("slide.new", {"layout": "titleOnly", "title": "Hidden"}))
cmds.append(cmd("slide.hide", {"hidden": True}))

# 2. Effects, one shape each: (class, effect, option).
effects = [
    [
        ("entrance", "appear", ""), ("entrance", "fade", ""), ("entrance", "fly", "b"), ("entrance", "fly", "lt"),
        ("entrance", "wipe", "l"), ("entrance", "split", "horzOut"), ("entrance", "zoom", "in"),
        ("entrance", "wheel", "4"), ("entrance", "randomBars", "vert"), ("entrance", "blinds", "horz"),
        ("entrance", "checkerboard", "down"), ("entrance", "box", "out"),
    ],
    [
        ("entrance", "circle", "in"), ("entrance", "diamond", "out"), ("entrance", "dissolve", ""),
        ("entrance", "peek", "r"), ("entrance", "strips", "rd"), ("entrance", "swivel", "vert"),
        ("entrance", "bounce", ""), ("entrance", "float", "d"), ("entrance", "grow", ""), ("entrance", "rise", ""),
        ("entrance", "expand", ""), ("entrance", "spinner", ""),
    ],
    [
        ("emphasis", "pulse", ""), ("emphasis", "spin", "counterClockwise"), ("emphasis", "growShrink", "both"),
        ("emphasis", "transparency", ""), ("emphasis", "colorPulse", ""), ("emphasis", "teeter", ""),
        ("exit", "disappear", ""), ("exit", "fadeOut", ""), ("exit", "flyOut", "r"), ("exit", "zoomOut", "out"),
        ("exit", "wipeOut", "t"), ("exit", "shrinkTurn", ""),
    ],
    [
        ("path", "lines", "down"), ("path", "lines", "left"), ("path", "arcs", "up"), ("path", "turns", "right"),
        ("path", "diagonalDownRight", ""), ("path", "zigzag", ""), ("path", "loops", ""), ("path", "star5", ""),
    ],
]
for page, group in enumerate(effects):
    cmds.append(cmd("slide.new", {"layout": "blank"}))
    for i, (cls, effect, option) in enumerate(group):
        x, y = 40 + (i % 4) * 220, 40 + (i // 4) * 160
        cmds.append(cmd("shape.insert", {"preset": "rect", "rect": [x, y, 180, 110]}))
        params = {"effect": effect, "class": cls}
        if option:
            params["option"] = option
        cmds.append(cmd("animation.add", params))

# 3. Timings: each start, a delay, durations, a repeat, rewind, and text builds.
cmds.append(cmd("slide.new", {"layout": "blank"}))
timings = [
    {"start": "onClick", "duration": 1500},
    {"start": "withPrevious", "delay": 500},
    {"start": "afterPrevious", "delay": 250, "duration": 750},
    {"start": "onClick", "repeat": 3},
    {"start": "onClick", "rewind": True, "duration": 2000},
]
for i, t in enumerate(timings):
    cmds.append(cmd("shape.insert", {"preset": "ellipse", "rect": [40 + i * 180, 40, 150, 100]}))
    cmds.append(cmd("animation.add", {"effect": "fly", "class": "entrance", "option": "l"}))
    cmds.append(cmd("animation.timing", t))
cmds.append(cmd("insert.textBox", {"rect": [40, 220, 400, 200], "text": "First point\nSecond point\nThird point"}))
cmds.append(cmd("animation.add", {"effect": "fade", "class": "entrance"}))
cmds.append(cmd("animation.options", {"textBuild": "byParagraph"}))
cmds.append(cmd("insert.textBox", {"rect": [500, 220, 400, 200], "text": "Built word by word"}))
cmds.append(cmd("animation.add", {"effect": "fly", "class": "entrance", "option": "b"}))
cmds.append(cmd("animation.options", {"textBuild": "byWord"}))

for c in cmds:
    print("--cmd")
    print(c)
