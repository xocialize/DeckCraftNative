#!/usr/bin/env python3
"""Tools/l10n/l10n.py — helpers for the String Catalogs of DCAppModel and DCApp (see sync.sh).

  split <stringsdata-dir> <Packages/DCApp/Sources>
      Sorts the compiler's .stringsdata files by module (<dir>/DCAppModel, <dir>/DCApp), keeping only those
      whose source file is in that module and still exists.
  plurals <catalog.xcstrings> <plurals.json>
      Gives the keys listed in plurals.json (under the catalog's module) their English plural variations:
      `{one, other}` makes a top-level `plural` variation (a key with one argument); `{value, arg, spec, one,
      other}` makes Xcode's substitution for a key with several (value "%1$@ (%#@slides@)", the plural one
      argument `arg` with format `spec`, one "%arg slide", other "%arg slides").
  fill <catalog.xcstrings>
      Writes out every entry's English value (see `fill`).
  infoplist <built Info.plist> <InfoPlist.xcstrings>
      Writes InfoPlist.xcstrings from the built app's Info.plist (its name, copyright, document type names).
  stats <catalog.xcstrings>
      Prints the number of entries, stale entries and plural entries.
  pseudo <catalog.xcstrings> <bundle's Resources dir>
      Build-only pseudo-localization: compiles an `en-XA` table from the catalog into a built bundle's
      `en-XA.lproj` (in a .build folder, never the catalog), every value bracketed and accented with its
      format specifiers kept, so a run with `-AppleLanguages '(en-XA)'` shows at a glance any text that
      isn't from a catalog. Tools/l10n/pseudo.sh does it for the app.
"""
import json
import os
import plistlib
import re
import shutil
import sys

SPEC = re.compile(r"%#@[A-Za-z0-9_]+@|%arg|%%|\$\{[A-Za-z0-9_]+\}|%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfFeEgGcCsSpaA]")


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save(path, catalog):
    # Xcode's own layout: two-space indent, " : " separators, sorted keys.
    text = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    with open(path, "w", encoding="utf-8") as f:
        f.write(text + "\n")


def literal_end(text, i):
    """The index just past the Swift string literal that starts at text[i] (a quote), interpolations included."""
    if text.startswith('"""', i):
        j = text.find('"""', i + 3)
        return len(text) if j < 0 else j + 3
    j = i + 1
    while j < len(text):
        c = text[j]
        if c == "\\":
            if text.startswith("(", j + 1):
                depth, j = 1, j + 2
                while j < len(text) and depth:
                    if text[j] == '"':
                        j = literal_end(text, j)
                        continue
                    depth += {"(": 1, ")": -1}.get(text[j], 0)
                    j += 1
                continue
            j += 2
            continue
        if c == '"':
            return j + 1
        if c == "\n":
            return j
        j += 1
    return j


def call_tail(text, i):
    """The rest of the call around the literal at text[i]: up to the `)` that closes it, or the end of the
    statement when the literal isn't an argument (`static let title: LocalizedStringResource = "…"`)."""
    j, depth = literal_end(text, i), 0
    start = j
    while j < len(text):
        c = text[j]
        if c == '"':
            j = literal_end(text, j)
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return text[start:j]
            depth -= 1
        elif c == "\n" and depth == 0 and not text[start:j].rstrip().endswith((",", "(")):
            return text[start:j]
        j += 1
    return text[start:j]


def main_bundle_entries(data):
    """Splits a .stringsdata's entries into the module's and the main bundle's: a literal whose call names no
    `bundle:` is looked up in the main bundle. App Intents metadata (`LocalizedStringResource` titles,
    descriptions, parameter and enum names) must be, so `DCApp/Intents` has some on purpose."""
    with open(data["source"], encoding="utf-8") as f:
        lines = f.read().split("\n")
    module, main = {}, {}
    for table, entries in data.get("tables", {}).items():
        for e in entries:
            loc = e.get("location", {})
            line = loc.get("startingLine", 1) - 1
            # Columns count UTF-8 bytes.
            prefix = lines[line].encode("utf-8")[: loc.get("startingColumn", 1) - 1].decode("utf-8", "ignore")
            text = "\n".join(lines[line:line + 12])
            tail = call_tail(text, len(prefix)) if text[len(prefix):len(prefix) + 1] == '"' else ""
            (module if "bundle:" in tail else main).setdefault(table, []).append(e)
    return module, main


def split(src_dir, sources):
    """Sorts the .stringsdata files by catalog: <dir>/DCAppModel, <dir>/DCApp, and <dir>/App for the literals
    in DCApp that the main bundle looks up (App Intents metadata). Prints any main-bundle literal outside
    DCApp/Intents: SwiftUI's `Text("…")` without `bundle:` is one, and a bug."""
    for module in ("DCAppModel", "DCApp", "App"):
        os.makedirs(os.path.join(src_dir, module), exist_ok=True)
    root = os.path.realpath(sources)
    stray = []
    for name in sorted(os.listdir(src_dir)):
        path = os.path.join(src_dir, name)
        if not name.endswith(".stringsdata"):
            continue
        data = load(path)
        source = os.path.realpath(data.get("source", ""))
        data["source"] = source
        os.remove(path)
        if not os.path.exists(source):
            continue
        if source.startswith(os.path.join(root, "DCAppModel") + os.sep):
            dump(os.path.join(src_dir, "DCAppModel", name), data)
        elif source.startswith(os.path.join(root, "DCApp") + os.sep):
            module, main = main_bundle_entries(data)
            dump(os.path.join(src_dir, "DCApp", name), dict(data, tables=module))
            if main:
                dump(os.path.join(src_dir, "App", name), dict(data, tables=main))
                if os.sep + "Intents" + os.sep not in source:
                    stray += [f"{source}:{e['location']['startingLine']}: {e['key']!r}" for es in main.values() for e in es]
    if stray:
        print("Literals the main bundle would look up (add `bundle: .module`):", *stray, sep="\n  ", file=sys.stderr)
        sys.exit(1)


def dump(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def plurals(catalog_path, plurals_path):
    module = os.path.basename(os.path.dirname(os.path.dirname(catalog_path)))
    wanted = load(plurals_path).get(module, {})
    catalog = load(catalog_path)
    strings = catalog.setdefault("strings", {})
    missing = []
    for key, forms in sorted(wanted.items()):
        if key.startswith("//"):
            continue
        entry = strings.get(key)
        if entry is None:
            missing.append(key)
            continue
        if "value" not in forms:
            # One argument: the plural variation is the whole string.
            en = {"variations": {"plural": {"one": unit(forms["one"]), "other": unit(forms["other"])}}}
        else:
            # Several arguments: Xcode's substitution, e.g. "%1$@ (%#@slides@)" with slides = argument 2,
            # {one: "%arg slide", other: "%arg slides"}. plurals.json spells the value out.
            var = re.search(r"%#@([A-Za-z0-9_]+)@", forms["value"]).group(1)
            en = {
                "stringUnit": {"state": "translated", "value": forms["value"]},
                "substitutions": {
                    var: {
                        "argNum": forms["arg"],
                        "formatSpecifier": forms["spec"],
                        "variations": {"plural": {"one": unit(forms["one"]), "other": unit(forms["other"])}},
                    }
                },
            }
        entry.setdefault("localizations", {})["en"] = en
    save(catalog_path, catalog)
    if missing:
        print(f"plurals.json keys not in {module}'s catalog: {missing}", file=sys.stderr)
        sys.exit(1)


def fill(catalog_path):
    """Writes each entry's English value out (Xcode leaves it implied when it equals the key) and marks it
    translated, so the compiled `en.lproj` holds every string: `Bundle.localizedString` finds each key the
    code uses (the tests check that). A stale entry (no code uses it) with no translation is dropped; one
    with translations stays, marked stale, for a translator to reuse."""
    catalog = load(catalog_path)
    strings = catalog.get("strings", {})
    # A stale entry with nothing but English has nothing to keep: drop it. One with translations stays, stale.
    for key in [k for k, e in strings.items() if e.get("extractionState") == "stale" and set(e.get("localizations", {})) <= {"en"}]:
        del strings[key]
    for key, entry in strings.items():
        if entry.get("shouldTranslate") is False:
            continue
        en = entry.setdefault("localizations", {}).setdefault("en", {})
        if "stringUnit" not in en and "variations" not in en and "stringSet" not in en:
            en["stringUnit"] = {"state": "translated", "value": key}
        elif "stringUnit" in en and en["stringUnit"].get("state") == "new":
            en["stringUnit"]["state"] = "translated"
        if "stringSet" in en and en["stringSet"].get("state") == "new":
            en["stringSet"]["state"] = "translated"
    save(catalog_path, catalog)


INFOPLIST = [
    ("CFBundleDisplayName", "The app's name, as Finder and the menu bar show it"),
    ("CFBundleName", "The app's short name"),
    ("NSHumanReadableCopyright", "The copyright line in About and Finder's Get Info"),
]


def infoplist(plist_path, catalog_path):
    """InfoPlist.xcstrings from the built app's Info.plist: its name, its copyright line and the names of its
    document types (CFBundleTypeName) and exported or imported types (UTTypeDescription), which Finder shows.
    A document type's name is its own key, as in InfoPlist.strings."""
    with open(plist_path, "rb") as f:
        info = plistlib.load(f)
    strings = {}
    for key, comment in INFOPLIST:
        if isinstance(info.get(key), str):
            strings[key] = (info[key], comment)
    for t in info.get("CFBundleDocumentTypes", []):
        if isinstance(t.get("CFBundleTypeName"), str):
            strings[t["CFBundleTypeName"]] = (t["CFBundleTypeName"], "A document type's name, in Finder (Kind) and Get Info")
    for group in ("UTExportedTypeDeclarations", "UTImportedTypeDeclarations"):
        for t in info.get(group, []):
            if isinstance(t.get("UTTypeDescription"), str):
                strings[t["UTTypeDescription"]] = (t["UTTypeDescription"], f"The description of the file type {t.get('UTTypeIdentifier', '')}")
    catalog = {"sourceLanguage": "en", "version": "1.0", "strings": {}}
    for key, (value, comment) in strings.items():
        catalog["strings"][key] = {
            "comment": comment,
            "extractionState": "manual",
            "localizations": {"en": {"stringUnit": {"state": "translated", "value": value}}},
        }
    save(catalog_path, catalog)


def stats(catalog_path):
    strings = load(catalog_path).get("strings", {})
    stale = sum(1 for e in strings.values() if e.get("extractionState") == "stale")
    plural = sum(1 for e in strings.values() if "variations" in json.dumps(e))
    print(f"  {'/'.join(os.path.abspath(catalog_path).split('/')[-3:])}: {len(strings)} entries ({stale} stale, {plural} with plural variations)")


ACCENTS = dict(zip(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
    "àƀçðéƒĝĥîĵķļɱñöþǫŕšţûṽŵẋýžÀßÇÐÉƑĜĤÎĴĶĻṀÑÖÞǪŔŠŢÛṼŴẊÝŽ",
))


def pseudo_text(text):
    out, pos = [], 0
    for m in SPEC.finditer(text):
        out.append("".join(ACCENTS.get(c, c) for c in text[pos:m.start()]))
        out.append(m.group(0))
        pos = m.end()
    out.append("".join(ACCENTS.get(c, c) for c in text[pos:]))
    return "[" + "".join(out) + "]"


def pseudo_localization(node):
    """The `en` localization of a catalog entry with every string unit pseudo-localized."""
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if k == "stringUnit":
                out[k] = {"state": "translated", "value": pseudo_text(v.get("value", ""))}
            elif k == "stringSet":
                out[k] = {"state": "translated", "values": [pseudo_text(x) for x in v.get("values", [])]}
            else:
                out[k] = pseudo_localization(v)
        return out
    return node


def pseudo(catalog_path, resources):
    """Build-only pseudo-localization: compiles an `en-XA` copy of the catalog (every English value bracketed
    and accented, format specifiers kept) into `<resources>/en-XA.lproj` of a built bundle, never into the
    catalog. Run the app with `-AppleLanguages '(en-XA)'`: text that isn't bracketed isn't from a catalog."""
    import subprocess
    import tempfile
    catalog = load(catalog_path)
    for key, entry in catalog.get("strings", {}).items():
        locs = entry.setdefault("localizations", {})
        en = locs.get("en") or {"stringUnit": {"state": "translated", "value": key}}
        locs["en-XA"] = pseudo_localization(en)
    with tempfile.TemporaryDirectory() as tmp:
        name = os.path.basename(catalog_path)
        src = os.path.join(tmp, name)
        save(src, catalog)
        out = os.path.join(tmp, "out")
        subprocess.run(["xcrun", "xcstringstool", "compile", src, "--output-directory", out, "--language", "en-XA",
                        "--serialization-format", "binary"], check=True)
        dst = os.path.join(resources, "en-XA.lproj")
        os.makedirs(dst, exist_ok=True)
        for f in os.listdir(os.path.join(out, "en-XA.lproj")):
            shutil.copy(os.path.join(out, "en-XA.lproj", f), os.path.join(dst, f))
    print(f"{dst}: {name} ({len(catalog.get('strings', {}))} strings)")


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd, args = argv[1], argv[2:]
    if cmd == "split":
        split(*args)
    elif cmd == "plurals":
        plurals(*args)
    elif cmd == "fill":
        fill(*args)
    elif cmd == "infoplist":
        infoplist(*args)
    elif cmd == "stats":
        stats(*args)
    elif cmd == "pseudo":
        pseudo(*args)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
