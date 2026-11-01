#!/usr/bin/env python3
"""Tools/l10n/translations.py — move translations in and out of the String Catalogs.

    translations.py export LANG OUTDIR [--all]   one JSON file per catalog: the entries LANG still lacks (--all: every
                                                 entry), each with its English text and the catalog's comment
    translations.py import LANG FILE…            write translations into the catalogs as "needs_review", after
                                                 checking that each keeps the English text's format arguments
    translations.py review-export LANG FILE.csv  the review sheet: one row per string (per plural form), English,
                                                 the translation, its state and the catalog's comment
    translations.py review-import LANG FILE.csv  a reviewed sheet back: changed text and the "reviewed" column
                                                 (marked x) land in the catalogs; a reviewed row becomes "translated"
    translations.py check LANG                   every entry of LANG checked again; counts by state
    translations.py validate FILE…               check translation files against the catalogs without writing

Entries are named `<catalog>|<key>`, the catalog by its short name below. A translation is a string, a plural
{"one": …, "other": …}, a substitution {"value": …, "one": …, "other": …} (the value keeps its %#@name@ and the forms
their %arg) or, for an App Shortcuts phrase, a list of phrases (each keeps ${applicationName}).
"""
import csv
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CATALOGS = {
    "DCAppModel": "Packages/DCApp/Sources/DCAppModel/Resources/Localizable.xcstrings",
    "Commands": "Packages/DCApp/Sources/DCAppModel/Resources/Commands.xcstrings",
    "Ribbon": "Packages/DCApp/Sources/DCAppModel/Resources/Ribbon.xcstrings",
    "DCApp": "Packages/DCApp/Sources/DCApp/Resources/Localizable.xcstrings",
    "DCIntentsKit": "Packages/DCExtensions/Sources/DCIntentsKit/Resources/Localizable.xcstrings",
    "DCQuickLook": "Packages/DCExtensions/Sources/DCQuickLook/Resources/Localizable.xcstrings",
    "App": "Apps/DeckCraftNative/App/Localizable.xcstrings",
    "AppShortcuts": "Apps/DeckCraftNative/App/AppShortcuts.xcstrings",
    "InfoPlist": "Apps/DeckCraftNative/App/InfoPlist.xcstrings",
    "IntentsExtension": "Apps/DeckCraftNative/Extensions/Intents/Localizable.xcstrings",
}
# The app's own name stays as it is in every language.
KEEP = {("InfoPlist", "CFBundleDisplayName"), ("InfoPlist", "CFBundleName")}

SPEC = re.compile(r"%#@[A-Za-z0-9_]+@|%arg|%%|%(?:\d+\$)?[-+#0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaA]|\$\{[A-Za-z]+\}")


def load(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as f:
        return json.load(f)


def save(path, catalog):
    # As l10n.py writes them: Xcode's layout (two-space indent, " : " separators) and a final newline. The keys keep
    # the order they were read in (Xcode's, which sorts ignoring case); new localizations are put in place by `write`.
    text = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "))
    with open(os.path.join(ROOT, path), "w", encoding="utf-8") as f:
        f.write(text + "\n")


def english(key, entry):
    """The English text of an entry in the shape a translation takes, or None when it has nothing to translate."""
    if entry.get("shouldTranslate") is False:
        return None
    en = entry.get("localizations", {}).get("en", {})
    if "stringSet" in en:
        return list(en["stringSet"]["values"])
    if "variations" in en:
        p = en["variations"]["plural"]
        return {"one": p["one"]["stringUnit"]["value"], "other": p["other"]["stringUnit"]["value"]}
    if "substitutions" in en:
        (name, sub), = en["substitutions"].items()
        p = sub["variations"]["plural"]
        return {"value": en["stringUnit"]["value"], "one": p["one"]["stringUnit"]["value"], "other": p["other"]["stringUnit"]["value"]}
    if "stringUnit" in en:
        return en["stringUnit"]["value"]
    return key


def specs(text):
    return [m.group(0) for m in SPEC.finditer(text)]


def kinds(text):
    """The format arguments without their positions, in order: %1$@ and %@ are the same kind."""
    return [re.sub(r"^%\d+\$", "%", s) for s in specs(text)]


def check_text(en, tr):
    if not isinstance(tr, str) or not tr.strip():
        return "empty"
    a, b = kinds(en), kinds(tr)
    if sorted(a) != sorted(b):
        return f"format arguments differ: {specs(en)} vs {specs(tr)}"
    positional = any(re.match(r"%\d+\$", s) for s in specs(tr))
    if a != b and not positional:
        return f"arguments reordered without positions (%1$@): {specs(tr)}"
    if en.count("\n") != tr.count("\n"):
        return "line breaks differ"
    return None


def check(en, tr):
    if isinstance(en, list):
        if not isinstance(tr, list) or not tr:
            return "phrases must be a list"
        bad = [p for p in tr if "${applicationName}" not in p]
        return f"phrases without ${{applicationName}}: {bad}" if bad else None
    if isinstance(en, dict):
        if not isinstance(tr, dict) or set(tr) != set(en):
            return f"forms must be {sorted(en)}"
        for form in en:
            if (problem := check_text(en[form], tr[form])):
                return f"{form}: {problem}"
        return None
    return check_text(en, tr)


def localization(en_entry, tr, state):
    unit = lambda v: {"stringUnit": {"state": state, "value": v}}
    if isinstance(tr, list):
        return {"stringSet": {"state": state, "values": tr}}
    if isinstance(tr, dict) and "value" in tr:
        (name, sub), = en_entry["localizations"]["en"]["substitutions"].items()
        return {"stringUnit": {"state": state, "value": tr["value"]}, "substitutions": {name: {
            "argNum": sub["argNum"], "formatSpecifier": sub["formatSpecifier"],
            "variations": {"plural": {"one": unit(tr["one"]), "other": unit(tr["other"])}}}}}
    if isinstance(tr, dict):
        return {"variations": {"plural": {"one": unit(tr["one"]), "other": unit(tr["other"])}}}
    return unit(tr)


def current(entry, lang):
    """A language's text and state in the same shape as `english`, or (None, None)."""
    loc = entry.get("localizations", {}).get(lang)
    if not loc:
        return None, None
    if "stringSet" in loc:
        return loc["stringSet"]["values"], loc["stringSet"]["state"]
    if "variations" in loc:
        p = loc["variations"]["plural"]
        return {f: p[f]["stringUnit"]["value"] for f in ("one", "other")}, p["other"]["stringUnit"]["state"]
    if "substitutions" in loc:
        (_, sub), = loc["substitutions"].items()
        p = sub["variations"]["plural"]
        return {"value": loc["stringUnit"]["value"], "one": p["one"]["stringUnit"]["value"],
                "other": p["other"]["stringUnit"]["value"]}, loc["stringUnit"]["state"]
    return loc["stringUnit"]["value"], loc["stringUnit"]["state"]


def entries():
    for short, path in CATALOGS.items():
        catalog = load(path)
        for key, entry in catalog.get("strings", {}).items():
            if (short, key) in KEEP or entry.get("extractionState") == "stale":
                continue
            en = english(key, entry)
            if en is not None:
                yield short, path, catalog, key, entry, en


def export(lang, outdir, everything=False):
    os.makedirs(outdir, exist_ok=True)
    out = {}
    for short, _, _, key, entry, en in entries():
        if not everything and current(entry, lang)[0] is not None:
            continue
        out.setdefault(short, []).append({"id": f"{short}|{key}", "en": en, "comment": entry.get("comment", "")})
    for short, items in out.items():
        with open(os.path.join(outdir, f"{short}.json"), "w", encoding="utf-8") as f:
            json.dump(items, f, ensure_ascii=False, indent=1)
        print(f"{short}: {len(items)}")


def write(lang, translations, state):
    """translations: {(short, key): text}. Returns the problems found; good translations are written."""
    problems, by_catalog = [], {}
    for (short, key), tr in translations.items():
        by_catalog.setdefault(short, {})[key] = tr
    for short, items in by_catalog.items():
        path = CATALOGS[short]
        catalog = load(path)
        strings = catalog["strings"]
        for key, tr in items.items():
            entry = strings.get(key)
            if entry is None:
                problems.append(f"{short}|{key}: no such entry")
                continue
            en = english(key, entry)
            if (problem := check(en, tr)):
                problems.append(f"{short}|{key}: {problem}")
                continue
            locs = entry.setdefault("localizations", {})
            locs[lang] = localization(entry, tr, state)
            entry["localizations"] = dict(sorted(locs.items()))
        save(path, catalog)
    return problems


def do_import(lang, files):
    translations = {}
    for path in files:
        with open(path, encoding="utf-8") as f:
            for item in json.load(f):
                short, key = item["id"].split("|", 1)
                translations[(short, key)] = item["t"]
    problems = write(lang, translations, "needs_review")
    print(f"{len(translations) - len(problems)} written as needs_review, {len(problems)} refused")
    for p in problems:
        print("  " + p)
    return 1 if problems else 0


FORMS = ("value", "one", "other")


def review_export(lang, path):
    rows = []
    for short, _, _, key, entry, en in entries():
        tr, state = current(entry, lang)
        base = {"id": f"{short}|{key}", "comment": entry.get("comment", ""), "state": state or "missing"}
        if isinstance(en, list):
            rows.append(base | {"form": "phrases", "english": "\n".join(en), "translation": "\n".join(tr or [])})
        elif isinstance(en, dict):
            for form in FORMS:
                if form in en:
                    rows.append(base | {"form": form, "english": en[form], "translation": (tr or {}).get(form, "")})
        else:
            rows.append(base | {"form": "", "english": en, "translation": tr or ""})
    with open(path, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["id", "form", "english", "translation", "state", "reviewed", "note", "comment"])
        w.writeheader()
        for r in rows:
            w.writerow(r | {"reviewed": "", "note": ""})
    print(f"{path}: {len(rows)} rows")


def review_import(lang, path):
    """A row marked reviewed (any text in "reviewed") becomes "translated", with its text as the sheet has it.
    Other rows whose text changed are written as needs_review."""
    grouped = {}
    with open(path, encoding="utf-8", newline="") as f:
        for r in csv.DictReader(f):
            grouped.setdefault(r["id"], []).append(r)
    current_entries = {f"{short}|{key}": (entry, en) for short, _, _, key, entry, en in entries()}
    reviewed, changed = {}, {}
    for rid, rows in grouped.items():
        if rid not in current_entries:
            continue
        entry, en = current_entries[rid]
        old, _ = current(entry, lang)
        if isinstance(en, list):
            tr = [p for p in rows[0]["translation"].split("\n") if p.strip()]
        elif isinstance(en, dict):
            tr = {r["form"]: r["translation"] for r in rows if r["form"] in en}
        else:
            tr = rows[0]["translation"]
        short, key = rid.split("|", 1)
        if all(r["reviewed"].strip() for r in rows):
            reviewed[(short, key)] = tr
        elif tr != old and tr:
            changed[(short, key)] = tr
    problems = write(lang, reviewed, "translated") + write(lang, changed, "needs_review")
    print(f"{len(reviewed)} reviewed, {len(changed)} changed for review, {len(problems)} refused")
    for p in problems:
        print("  " + p)
    return 1 if problems else 0


def do_check(lang):
    counts, problems = {}, []
    for short, _, _, key, entry, en in entries():
        tr, state = current(entry, lang)
        counts[state or "missing"] = counts.get(state or "missing", 0) + 1
        if tr is not None and (problem := check(en, tr)):
            problems.append(f"{short}|{key}: {problem}")
    print(f"{lang}: " + ", ".join(f"{n} {s}" for s, n in sorted(counts.items())))
    for p in problems:
        print("  " + p)
    return 1 if problems else 0


def validate(files):
    """Each item of each file: is its entry there, is the shape right, are the format arguments kept."""
    known = {f"{short}|{key}": en for short, _, _, key, _, en in entries()}
    problems, n = [], 0
    for path in files:
        with open(path, encoding="utf-8") as f:
            items = json.load(f)
        for item in items:
            n += 1
            rid, tr = item.get("id"), item.get("t")
            if rid not in known:
                problems.append(f"{path}: {rid}: no such entry")
            elif (problem := check(known[rid], tr)):
                problems.append(f"{path}: {rid}: {problem}")
    print(f"{n} checked, {len(problems)} problems")
    for p in problems:
        print("  " + p)
    return 1 if problems else 0


def main(argv):
    if len(argv) >= 3 and argv[1] == "validate":
        return validate(argv[2:])
    if len(argv) < 3:
        print(__doc__)
        return 2
    cmd, lang, rest = argv[1], argv[2], argv[3:]
    if cmd == "export":
        export(lang, rest[0], everything="--all" in rest)
    elif cmd == "import":
        return do_import(lang, rest)
    elif cmd == "review-export":
        review_export(lang, rest[0])
    elif cmd == "review-import":
        return review_import(lang, rest[0])
    elif cmd == "check":
        return do_check(lang)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
