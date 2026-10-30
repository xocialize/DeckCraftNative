# Helpers for Tools/legacy/make-fixtures.sh, run with the legacy-tools venv's Python (it has olefile):
#
#   fixtures.py describe FILE              the encryption a compound file declares, as JSON
#   fixtures.py olefile-list FILE          olefile's reading of a compound file: every entry's path, kind, size and
#                                          sha256, as JSON (DCCFB's tests compare their own reading with it)
#   fixtures.py mutate SEED OUT_DIR FILE…  hostile copies of each FILE (truncated, bit-flipped, cyclic chains)
#   fixtures.py manifest LEGACY_DIR        legacy/manifest.json from the files and their .meta.json sidecars
#
# Every mutation is deterministic for a seed, so the hostile set regenerates byte for byte.
import hashlib
import json
import os
import random
import re
import struct
import sys

import olefile


def describe(path):
    out = {"compound": olefile.isOleFile(path)}
    if not out["compound"]:
        return out
    with olefile.OleFileIO(path) as o:
        out["streams"] = ["/".join(p) for p in o.listdir(streams=True, storages=False)]
        if o.exists("EncryptionInfo"):
            b = o.openstream("EncryptionInfo").read()
            major, minor = struct.unpack_from("<HH", b, 0)
            out["version"] = "%d.%d" % (major, minor)
            if (major, minor) == (4, 4):
                x = b[8:].decode("utf-8", "replace")
                kd = re.search(r"<keyData([^>]*)>", x)
                pk = re.search(r"<p:encryptedKey([^>]*)>", x)
                attrs = lambda s: dict(re.findall(r'(\w+)="([^"]*)"', s or ""))
                k, p = attrs(kd.group(1) if kd else ""), attrs(pk.group(1) if pk else "")
                out.update(method="agile", cipher=k.get("cipherAlgorithm"), keyBits=int(k.get("keyBits", 0)),
                           hash=k.get("hashAlgorithm"), chaining=k.get("cipherChaining"),
                           spinCount=int(p.get("spinCount", 0)), integrity="<dataIntegrity" in x)
            elif minor == 2 and major in (2, 3, 4):
                flags, = struct.unpack_from("<I", b, 4)
                hsize, = struct.unpack_from("<I", b, 8)
                alg, alghash, keybits = struct.unpack_from("<III", b, 12 + 8)
                names = {0x660E: "AES128", 0x660F: "AES192", 0x6610: "AES256", 0x6801: "RC4"}
                out.update(method="standard", cipher=names.get(alg, hex(alg)), keyBits=keybits, hash="SHA1",
                           flags=flags)
            elif minor == 3:
                out.update(method="extensible")
        if o.exists("PowerPoint Document"):
            out["ppt"] = True
    return out


def olefile_list(path):
    with olefile.OleFileIO(path) as o:
        out = []
        for p in o.listdir(streams=True, storages=True):
            kind = o.get_type(p)
            e = {"path": "/".join(p), "kind": {olefile.STGTY_STORAGE: "storage", olefile.STGTY_STREAM: "stream"}.get(kind, str(kind))}
            if kind == olefile.STGTY_STREAM:
                data = o.openstream(p).read()
                e.update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
            out.append(e)
        out.sort(key=lambda e: e["path"].lower())
        return {"major": o.dll_version if hasattr(o, "dll_version") else None, "sectorSize": o.sectorsize, "entries": out}


def mutate(seed, out_dir, files):
    rng = random.Random(int(seed))
    os.makedirs(out_dir, exist_ok=True)
    made = []
    for f in files:
        data = open(f, "rb").read()
        stem = os.path.splitext(os.path.basename(f))[0]
        ext = os.path.splitext(f)[1]
        variants = {}
        for frac in (0.0, 0.01, 0.25, 0.5, 0.9):
            n = max(0, int(len(data) * frac)) if frac else 7
            variants["trunc-%d" % n] = data[:n]
        for i in range(6):
            b = bytearray(data)
            region = rng.choice([(0, 512), (512, min(len(b), 4096)), (0, len(b))])
            for _ in range(rng.randint(1, 16)):
                if region[1] > region[0]:
                    p = rng.randrange(region[0], region[1])
                    b[p] ^= 1 << rng.randrange(8)
            variants["flip-%d" % i] = bytes(b)
        if data[:8] == b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" and len(data) >= 512:
            b = bytearray(data)
            first_dir, = struct.unpack_from("<I", b, 48)
            first_fat, = struct.unpack_from("<I", b, 76)
            shift, = struct.unpack_from("<H", b, 30)
            size = 1 << shift if shift in (9, 12) else 512
            fat_at = 512 + first_fat * size
            if 0 <= fat_at and fat_at + 4 * (first_dir + 1) <= len(b):
                c = bytearray(b)
                struct.pack_into("<I", c, fat_at + 4 * first_dir, first_dir)
                variants["dir-chain-self-loop"] = bytes(c)
            c = bytearray(b)
            struct.pack_into("<I", c, 44, 0x7FFFFFFF)
            variants["fat-count-huge"] = bytes(c)
            c = bytearray(b)
            struct.pack_into("<I", c, 48, 0xFFFFFFF0)
            variants["dir-start-out-of-range"] = bytes(c)
            c = bytearray(b)
            struct.pack_into("<H", c, 30, 20)
            variants["sector-shift-bad"] = bytes(c)
        for name, v in variants.items():
            p = os.path.join(out_dir, "%s.%s%s" % (stem, name, ext))
            with open(p, "wb") as fh:
                fh.write(v)
            made.append(p)
    print(len(made))


def manifest(root):
    entries = []
    for dirpath, _, names in os.walk(root):
        for n in sorted(names):
            if n.endswith(".meta.json") or n == "manifest.json" or n.startswith("."):
                continue
            p = os.path.join(dirpath, n)
            rel = os.path.relpath(p, root)
            e = {"file": rel, "sha256": hashlib.sha256(open(p, "rb").read()).hexdigest()}
            meta = p + ".meta.json"
            if os.path.exists(meta):
                e.update(json.load(open(meta)))
            entries.append(e)
    entries.sort(key=lambda e: e["file"])
    with open(os.path.join(root, "manifest.json"), "w") as fh:
        json.dump({"files": entries}, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    print(len(entries))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "describe" and len(sys.argv) == 3:
        print(json.dumps(describe(sys.argv[2])))
    elif cmd == "olefile-list" and len(sys.argv) == 3:
        print(json.dumps(olefile_list(sys.argv[2]), ensure_ascii=False))
    elif cmd == "mutate" and len(sys.argv) >= 5:
        mutate(sys.argv[2], sys.argv[3], sys.argv[4:])
    elif cmd == "manifest" and len(sys.argv) == 3:
        manifest(sys.argv[2])
    else:
        sys.exit("usage: fixtures.py describe FILE | olefile-list FILE | mutate SEED OUT_DIR FILE… | manifest LEGACY_DIR")
