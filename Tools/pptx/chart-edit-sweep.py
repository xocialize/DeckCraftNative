#!/usr/bin/env python3 -I
"""Tools/pptx/chart-edit-sweep.py: does an edited chart keep what the edit doesn't touch? (AB-T-0433)

For each .pptx given, saves it twice with dccli: untouched (`convert`), and with one command run on
every chart of the first slide that has one (default `chart.options {"title":"Edited"}`). It then
compares each chart part, element by element, and the parts the chart points at (workbook, style,
colours). A FAIL line names what the edit lost; the exit status is the number of failures.

  Tools/pptx/chart-edit-sweep.py [--cmd 'chart.options={"legend":"t"}'] [--keep DIR] FILE.pptx…

The inputs are never changed. PowerPoint-saved fixtures stay outside git (DeckCraftNative's rule), so
this takes paths rather than shipping files. Open the kept results with Tools/pptx/powerpoint-check.sh.
"""
import collections
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import zipfile
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DCCLI = os.environ.get("DCCLI", os.path.join(ROOT, ".build-gate/debug/dccli"))


def dccli(*args):
    r = subprocess.run([DCCLI, *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"dccli {' '.join(args[:3])}…: {r.stderr.strip() or r.stdout.strip()}")
    return r.stdout


def first_chart_slide(path):
    """(slide index, [chart shape ids]) of the first slide with a chart."""
    info = json.loads(dccli("info", path))
    for i in range(len(info["slides"])):
        out = dccli("run", "--in", path, "--cmd", f'slide.go={{"index":{i}}}', "--cmd", "slide.inspect", "--print")
        line = next(l for l in out.splitlines() if l.startswith("slide.inspect"))
        slide = json.loads(line.split("→", 1)[1])
        ids = [s["id"] for s in walk(slide.get("shapes", [])) if s.get("kind") == "chart" or "chart" in str(s.get("kind", ""))]
        if ids:
            return i, ids
    return None, []


def walk(shapes):
    for s in shapes:
        yield s
        yield from walk(s.get("children", []) or [])


C = "http://schemas.openxmlformats.org/drawingml/2006/chart"


def charts(path, removes=()):
    """Each chart part's element counts (by prefix:name) and the types of its relationships. `removes`
    names what the command takes away ("title", "legend", "gridlines"): that element is left out of the
    counts, in both files, so only collateral losses show."""
    out = []
    with zipfile.ZipFile(path) as z:
        names = set(z.namelist())
        for n in sorted(x for x in names if re.fullmatch(r"ppt/charts/chart\d+\.xml", x)):
            data = z.read(n)
            prefixes = {}
            for _, (pfx, uri) in ET.iterparse(io.BytesIO(data), events=["start-ns"]):
                prefixes.setdefault(uri, pfx)
            root = ET.fromstring(data)
            chart = root.find(f"{{{C}}}chart")
            plot = chart.find(f"{{{C}}}plotArea") if chart is not None else None
            if chart is not None:
                for k in ("title", "legend"):
                    if k in removes:
                        for e in chart.findall(f"{{{C}}}{k}"):
                            chart.remove(e)
            if plot is not None and "gridlines" in removes:
                for ax in plot.findall(f"{{{C}}}valAx"):
                    for e in ax.findall(f"{{{C}}}majorGridlines"):
                        ax.remove(e)
            counts = collections.Counter()
            for e in root.iter():
                uri, _, local = e.tag[1:].partition("}") if e.tag.startswith("{") else ("", "", e.tag)
                counts[f"{prefixes.get(uri, '?')}:{local}"] += 1
            rels = n.replace("charts/", "charts/_rels/") + ".rels"
            targets = []
            if rels in names:
                for m in re.finditer(r"<Relationship\b[^>]*>", z.read(rels).decode()):
                    typ = re.search(r'Type="([^"]+)"', m.group(0))
                    targets.append(typ.group(1).rsplit("/", 1)[-1] if typ else "?")
            out.append((n, counts, sorted(targets)))
    return out


def main(argv):
    cmd = 'chart.options={"title":"Edited"}'
    keep = None
    files = []
    it = iter(argv)
    for a in it:
        if a == "--cmd":
            cmd = next(it)
        elif a == "--keep":
            keep = next(it)
        else:
            files.append(a)
    if not files:
        print(__doc__)
        return 2
    name, _, params = cmd.partition("=")
    base = json.loads(params) if params else {}
    work = keep or tempfile.mkdtemp(prefix="chart-sweep-")
    os.makedirs(work, exist_ok=True)
    fails = 0
    for f in files:
        stem = os.path.splitext(os.path.basename(f))[0]
        plain, edited = os.path.join(work, f"{stem}-plain.pptx"), os.path.join(work, f"{stem}-edit.pptx")
        try:
            dccli("convert", f, plain)
            slide, ids = first_chart_slide(f)
            if not ids:
                print(f"SKIP  {stem}: no chart")
                continue
            cmds = ["--cmd", f'slide.go={{"index":{slide}}}']
            for i in ids:
                cmds += ["--cmd", f"{name}={json.dumps({**base, 'id': i})}"]
            dccli("run", "--in", f, *cmds, "--save", edited)
        except (RuntimeError, StopIteration) as e:
            print(f"ERROR {stem}: {e}")
            fails += 1
            continue
        removes = [k for k in ("title", "legend") if k in base and base[k] is None]
        if base.get("gridlines") is False:
            removes.append("gridlines")
        a, b = charts(plain, removes), charts(edited, removes)
        lost = []
        for (n, ca, ra), (_, cb, rb) in zip(a, b):
            for k in sorted(set(ca) | set(cb)):
                if cb[k] < ca[k]:
                    lost.append(f"{n.rsplit('/', 1)[-1]} {k} {ca[k]}→{cb[k]}")
            for t in sorted(set(ra) - set(rb)):
                lost.append(f"{n.rsplit('/', 1)[-1]} part {t}")
        if len(a) != len(b):
            lost.append(f"{len(a)} chart parts → {len(b)}")
        if lost:
            fails += 1
            print(f"FAIL  {stem}: " + "; ".join(lost[:12]) + (" …" if len(lost) > 12 else ""))
        else:
            print(f"PASS  {stem}: {len(a)} chart(s), {sum(sum(c.values()) for _, c, _ in a)} elements and every part kept")
    print(f"{len(files)} files, {fails} failures; results in {work}")
    return min(fails, 250)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
