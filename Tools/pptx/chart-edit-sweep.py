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
`c:val`, …), the workbook and its `c:externalData` out of the comparison: an edit replaces those. Each
edited chart must then link a workbook whose Sheet1 cells agree with the chart's ranges and caches
(AB-T-0435); PASS counts them: the original updated, replaced by a new one, or new where there was none. A dropped series is left out
of the untouched file's counts.

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


S = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
P = "http://schemas.openxmlformats.org/package/2006/relationships"


def rels_of(z, part):
    """A part's relationships in a zip: id → (type's last segment, resolved target)."""
    d, f = os.path.split(part)
    rp = os.path.join(d, "_rels", f + ".rels")
    out = {}
    if rp not in z.namelist():
        return out
    for r in ET.fromstring(z.read(rp)).iter(f"{{{P}}}Relationship"):
        t = r.get("Target", "")
        out[r.get("Id")] = (r.get("Type", "").rsplit("/", 1)[-1],
                            t.lstrip("/") if t.startswith("/") else os.path.normpath(os.path.join(d, t)))
    return out


def fallbacks(z):
    """Chart parts an Office 2016 chart's fallback draws (they carry no workbook)."""
    out = set()
    for n in z.namelist():
        if not re.fullmatch(r"ppt/slides/slide\d+\.xml", n):
            continue
        rels = rels_of(z, n)
        for fb in re.findall(r"<mc:Fallback>.*?</mc:Fallback>", z.read(n).decode(), re.S):
            for rid in re.findall(r'<c:chart\b[^>]*r:id="([^"]+)"', fb):
                if rid in rels:
                    out.add(rels[rid][1])
    return out


def book_of(z, chart):
    """The chart's embedded workbook: (its part names, Sheet1's cells as A1 → text), or None."""
    root = ET.fromstring(z.read(chart))
    link = root.find(f"{{{C}}}externalData")
    rel = rels_of(z, chart).get(link.get(f"{{{R}}}id")) if link is not None else None
    if not rel or rel[0] != "package" or rel[1] not in z.namelist():
        return None
    b = zipfile.ZipFile(io.BytesIO(z.read(rel[1])))
    wb = "xl/workbook.xml"
    sheets = {s.get("name"): s.get(f"{{{R}}}id") for s in ET.fromstring(b.read(wb)).iter(f"{{{S}}}sheet")}
    sheet = rels_of(b, wb).get(sheets.get("Sheet1"), (None, None))[1]
    sst = []
    if "xl/sharedStrings.xml" in b.namelist():
        sst = ["".join(t.text or "" for t in si.iter(f"{{{S}}}t")) for si in ET.fromstring(b.read("xl/sharedStrings.xml")).iter(f"{{{S}}}si")]
    cells = {}
    for c in ET.fromstring(b.read(sheet)).iter(f"{{{S}}}c") if sheet else []:
        v = c.find(f"{{{S}}}v")
        t = c.get("t")
        if t == "inlineStr":
            cells[c.get("r")] = "".join(x.text or "" for x in c.iter(f"{{{S}}}t"))
        elif t == "s" and v is not None:
            cells[c.get("r")] = sst[int(v.text)]
        elif v is not None:
            cells[c.get("r")] = v.text
    return set(b.namelist()), cells


def book_problems(z, chart):
    """What the chart's workbook says differently from the chart's caches."""
    got = book_of(z, chart)
    if got is None:
        return ["no workbook"]
    _, cells = got
    bad = []
    root = ET.fromstring(z.read(chart))
    for ser in root.iter(f"{{{C}}}ser"):
        for k in DATA:
            for ref in ser.findall(f"{{{C}}}{k}/*"):
                f = ref.find(f"{{{C}}}f")
                m = re.fullmatch(r"Sheet1!\$([A-Z]+)\$(\d+)(?::\$\1\$(\d+))?", (f.text or "").strip()) if f is not None else None
                if m is None:
                    continue
                col, r1, r2 = m.group(1), int(m.group(2)), int(m.group(3) or m.group(2))
                pts = {int(p.get("idx")): p.findtext(f"{{{C}}}v") for p in ref.iter(f"{{{C}}}pt")}
                for r in range(r1, r2 + 1):
                    want, have = pts.get(r - r1), cells.get(f"{col}{r}")
                    same = want == have
                    if not same and want is not None and have is not None:
                        try:
                            same = abs(float(want) - float(have)) < 1e-9
                        except ValueError:
                            pass
                    if not same:
                        bad.append(f"{col}{r} {have!r}≠{want!r}")
    return bad


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
        books = []
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
        if mode:
            # Each edited chart links a workbook that agrees with it: the original updated, or a new one.
            with zipfile.ZipFile(plain) as zp, zipfile.ZipFile(edited) as ze:
                skip = fallbacks(ze)
                for n in sorted(x for x in ze.namelist() if re.fullmatch(r"ppt/charts/chart\d+\.xml", x) and x not in skip):
                    # An untouched chart is written back as it was, with or without a workbook.
                    if n in zp.namelist() and zp.read(n) == ze.read(n):
                        continue
                    bad = book_problems(ze, n)
                    if bad:
                        lost.append(f"{n.rsplit('/', 1)[-1]} workbook: " + ", ".join(bad[:4]))
                        continue
                    was, now = book_of(zp, n) if n in zp.namelist() else None, book_of(ze, n)
                    books.append("new" if not was else "updated" if was[0] - {"xl/calcChain.xml"} <= now[0] else "replaced")
        if lost:
            fails += 1
            print(f"FAIL  {stem}: " + "; ".join(lost[:12]) + (" …" if len(lost) > 12 else ""))
        else:
            note = f"; workbooks {', '.join(f'{v} {k}' for k, v in sorted(collections.Counter(books).items()))}" if books else ""
            print(f"PASS  {stem}: {len(a)} chart(s), {sum(sum(c.values()) for _, c, _ in a)} elements and every part kept{note}")
    print(f"{len(files)} files, {fails} failures; results in {work}")
    return min(fails, 250)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
