#!/usr/bin/env python3 -I
"""Tools/pptx/chart-edit-sweep.py: does an edited chart keep what the edit doesn't touch? (AB-T-0433)

For each .pptx given, saves it twice with dccli: untouched (`convert`), and with one command run on
every chart of the first slide that has one (default `chart.options {"title":"Edited"}`). It then
compares each chart part, element by element, and the parts the chart points at (workbook, style,
colours). A FAIL line names what the edit lost; the exit status is the number of failures.

  Tools/pptx/chart-edit-sweep.py [--cmd 'chart.options={"legend":"t"}'] [--keep DIR] FILE.pptx…
  Tools/pptx/chart-edit-sweep.py --data values|rename|add-series|drop-series|add-category|drop-category FILE.pptx…

`--all-slides` edits the charts of every slide, not only the first slide with one.

`--data` runs `chart.data` with each chart's own data changed that way (from `slide.inspect`), checks
that the saved file reads back with that data, and leaves the series' data elements (`c:tx`, `c:cat`,
`c:val`, …), the workbook and its `c:externalData` out of the comparison: an edit replaces those (the
workbook would contradict the chart). A dropped series is left out of the untouched file's counts.

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


def chart_slides(path, with_data=False, every=False):
    """[(slide index, ids)] of the first slide with a chart, or with `every` of each slide with one."""
    info = json.loads(dccli("info", path))
    out = []
    for i in range(len(info["slides"])):
        one, ids = first_chart_slide(path, with_data, start=i, only=True)
        if ids:
            out.append((one, ids))
            if not every:
                break
    return out


def first_chart_slide(path, with_data=False, start=0, only=False):
    """(slide index, [chart shape ids]) of the first slide with a chart; with `with_data`, the ids are
    (id, chart) pairs, the chart as `slide.inspect` gives it."""
    info = json.loads(dccli("info", path))
    for i in range(start, start + 1 if only else len(info["slides"])):
        out = dccli("run", "--in", path, "--cmd", f'slide.go={{"index":{i}}}', "--cmd", "slide.inspect", "--print")
        line = next(l for l in out.splitlines() if l.startswith("slide.inspect"))
        slide = json.loads(line.split("→", 1)[1])
        charts_ = [s for s in walk(slide.get("shapes", [])) if s.get("kind") == "chart" or "chart" in str(s.get("kind", ""))]
        ids = [(s["id"], s.get("chart", {})) for s in charts_] if with_data else [s["id"] for s in charts_]
        if ids:
            return i, ids
    return None, []


def walk(shapes):
    for s in shapes:
        yield s
        yield from walk(s.get("children", []) or [])


C = "http://schemas.openxmlformats.org/drawingml/2006/chart"
DATA = ("tx", "cat", "val", "xVal", "yVal", "bubbleSize")
GROUPS = ("barChart", "bar3DChart", "lineChart", "line3DChart", "areaChart", "area3DChart", "pieChart",
          "pie3DChart", "ofPieChart", "doughnutChart", "scatterChart", "bubbleChart", "radarChart",
          "stockChart", "surfaceChart", "surface3DChart")
BOOK = ("package", "oleObject")


def edited_data(chart, mode):
    """`chart.data` parameters: `chart` (from slide.inspect) changed by `mode`."""
    cats = list(chart.get("categories", []))
    series = [{"name": x.get("name", ""), "values": list(x.get("values", []))} for x in chart.get("series", [])]
    n = max([len(cats)] + [len(x["values"]) for x in series])
    if mode == "values":
        for x in series:
            x["values"] = [None if v is None else round(v * 2 + 1, 3) for v in x["values"]]
    elif mode == "rename":
        cats = [f"{c} (e)" for c in cats]
        for x in series:
            x["name"] = x["name"] + " (edited)"
    elif mode == "add-series":
        series.append({"name": "Added", "values": [float(i + 1) for i in range(n)]})
    elif mode == "drop-series":
        series = series[:-1] if len(series) > 1 else series
    elif mode == "add-category":
        cats.append("Added")
        for x in series:
            x["values"].append(1.0)
    elif mode == "drop-category":
        cats = cats[:-1]
        for x in series:
            x["values"] = x["values"][:len(cats)] if cats else x["values"][:-1]
    else:
        raise SystemExit(f"unknown --data mode {mode}")
    return {"categories": cats, "series": series}


def charts(path, removes=(), plain=False):
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
            if "data" in removes:
                for e in list(root.iter()):
                    for k in ("externalData",):
                        for x in e.findall(f"{{{C}}}{k}"):
                            e.remove(x)
                if plot is not None:
                    groups = [g for g in plot if g.tag in {f"{{{C}}}{x}" for x in GROUPS}]
                    if plain and "drop-series" in removes:
                        last = [g for g in groups if g.findall(f"{{{C}}}ser")]
                        if last:
                            g = last[-1]
                            g.remove(g.findall(f"{{{C}}}ser")[-1])
                    for g in groups:
                        for ser in g.findall(f"{{{C}}}ser"):
                            for k in DATA:
                                for x in ser.findall(f"{{{C}}}{k}"):
                                    ser.remove(x)
            counts = collections.Counter()
            for e in root.iter():
                uri, _, local = e.tag[1:].partition("}") if e.tag.startswith("{") else ("", "", e.tag)
                counts[f"{prefixes.get(uri, '?')}:{local}"] += 1
            rels = n.replace("charts/", "charts/_rels/") + ".rels"
            targets = []
            if rels in names:
                for m in re.finditer(r"<Relationship\b[^>]*>", z.read(rels).decode()):
                    typ = re.search(r'Type="([^"]+)"', m.group(0))
                    t = typ.group(1).rsplit("/", 1)[-1] if typ else "?"
                    if not ("data" in removes and t in BOOK):
                        targets.append(t)
            out.append((n, counts, sorted(targets)))
    return out


def main(argv):
    cmd = 'chart.options={"title":"Edited"}'
    keep = None
    mode = None
    every = False
    files = []
    it = iter(argv)
    for a in it:
        if a == "--cmd":
            cmd = next(it)
        elif a == "--keep":
            keep = next(it)
        elif a == "--data":
            mode = next(it)
        elif a == "--all-slides":
            every = True
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
        wanted = {}
        try:
            dccli("convert", f, plain)
            slides = chart_slides(f, with_data=mode is not None, every=every)
            if not slides:
                print(f"SKIP  {stem}: no chart")
                continue
            cmds = []
            for slide, ids in slides:
                cmds += ["--cmd", f'slide.go={{"index":{slide}}}']
                if mode:
                    for i, chart in ids:
                        wanted[(slide, i)] = (edited_data(chart, mode), chart.get("type", ""))
                        cmds += ["--cmd", f"chart.data={json.dumps({**wanted[(slide, i)][0], 'id': i})}"]
                else:
                    for i in ids:
                        cmds += ["--cmd", f"{name}={json.dumps({**base, 'id': i})}"]
            dccli("run", "--in", f, *cmds, "--save", edited)
        except (RuntimeError, StopIteration) as e:
            print(f"ERROR {stem}: {e}")
            fails += 1
            continue
        if mode:
            removes = ["data", mode]
        else:
            removes = [k for k in ("title", "legend") if k in base and base[k] is None]
            if base.get("gridlines") is False:
                removes.append("gridlines")
        a, b = charts(plain, removes, plain=True), charts(edited, removes)
        lost = []
        for (n, ca, ra), (_, cb, rb) in zip(a, b):
            for k in sorted(set(ca) | set(cb)):
                if cb[k] < ca[k]:
                    lost.append(f"{n.rsplit('/', 1)[-1]} {k} {ca[k]}→{cb[k]}")
            for t in sorted(set(ra) - set(rb)):
                lost.append(f"{n.rsplit('/', 1)[-1]} part {t}")
        if len(a) != len(b):
            lost.append(f"{len(a)} chart parts → {len(b)}")
        if mode:
            # The edit must read back: the saved file's charts hold the data asked for.
            back = [(sl, i, chart) for sl, ids in chart_slides(edited, with_data=True, every=every) for i, chart in ids]
            for sl, i, chart in back:
                want, kind = wanted.get((sl, i), (None, ""))
                if want is None:
                    continue
                got = {"categories": chart.get("categories", []),
                       "series": [{"name": x.get("name", ""), "values": x.get("values", [])} for x in chart.get("series", [])]}
                if "Scatter" in kind or "Bubble" in kind:
                    got["categories"] = want["categories"]
                if got != want:
                    lost.append(f"slide {sl} chart {i} reads back {json.dumps(got)[:160]}")
        if lost:
            fails += 1
            print(f"FAIL  {stem}: " + "; ".join(lost[:12]) + (" …" if len(lost) > 12 else ""))
        else:
            print(f"PASS  {stem}: {len(a)} chart(s), {sum(sum(c.values()) for _, c, _ in a)} elements and every part kept")
    print(f"{len(files)} files, {fails} failures; results in {work}")
    return min(fails, 250)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
