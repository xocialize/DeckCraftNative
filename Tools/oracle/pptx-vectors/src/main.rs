//! pptx-vectors FIXTURES: runs deckcraft-pptx's foundation modules, compiled in from the pinned
//! checkout, and writes what they return to `FIXTURES/pptx/`:
//!
//! - `xml.txt`: the parser over hand-written and generated inputs (mutations of XML, entity, DOCTYPE
//!   and attribute fragments), each line `input-hex TAB err TAB message` or
//!   `input-hex TAB ok TAB dump TAB to_xml-hex TAB queries`.
//! - `corpus.txt`: every part of every oracle-corpus `.pptx` through `opc::Package`: its bytes'
//!   length, content type, relationships, and for XML parts the parse result and `to_xml`.
//! - `escape.txt`: `esc` and `esc_attr`.
//! - `modules.txt`: opc path functions, package budgets, cfb, png, maps, custgeom, tables and dgm, one
//!   call per line with its inputs and its result.
//!
//! Inputs come from a fixed xorshift seed, so reruns are equal. Strings are written as hex of their
//! UTF-8, floats as hex of their bits.
#![allow(dead_code, unused_imports, clippy::all)]

#[path = "../../../../../deckcraft/crates/pptx/src/cfb.rs"]
mod cfb;
#[path = "../../../../../deckcraft/crates/pptx/src/custgeom.rs"]
mod custgeom;
#[path = "../../../../../deckcraft/crates/pptx/src/dgm.rs"]
mod dgm;
#[path = "../../../../../deckcraft/crates/pptx/src/maps.rs"]
mod maps;
/// opc.rs, with `Package::open_within` public (see build.rs).
mod opc {
    include!(concat!(env!("OUT_DIR"), "/opc.rs"));
}
#[path = "../../../../../deckcraft/crates/pptx/src/png.rs"]
mod png;
#[path = "../../../../../deckcraft/crates/pptx/src/tables.rs"]
mod tables;
#[path = "../../../../../deckcraft/crates/pptx/src/xml.rs"]
mod xml;

use std::fmt::Write as _;
use std::io::{Read, Write};

use deckcraft_geom::preset::FillMode;
use deckcraft_model::anim::{ANIMATIONS, AnimClass, TRANSITIONS};
use deckcraft_model::{CustomPath, Diagram, DiagramNode};

/// deckcraft-pptx's error type (lib.rs), which the modules return.
#[derive(Debug, thiserror::Error)]
pub enum PptxError {
    #[error("not a PPTX file: {0}")]
    NotPptx(String),
    #[error("unsupported: {0}")]
    Unsupported(String),
    #[error("write failed: {0}")]
    Write(String),
    #[error("malformed XML: {0}")]
    Xml(String),
}

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: usize) -> usize {
        if n == 0 { 0 } else { (self.next() % n as u64) as usize }
    }
    fn pick<'a, T>(&mut self, v: &'a [T]) -> &'a T {
        &v[self.below(v.len())]
    }
}

fn hex(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        let _ = write!(s, "{x:02x}");
    }
    s
}

fn hs(s: &str) -> String {
    hex(s.as_bytes())
}

fn opt_hs(s: Option<&str>) -> String {
    s.map(hs).unwrap_or_else(|| "-".into())
}

/// The element as a string both sides build the same way: `E<name>[,<key>=<value>]…{children}` with
/// texts as `T<text>;`, every string as hex.
fn dump(e: &xml::El, out: &mut String) {
    out.push('E');
    out.push_str(&hs(&e.name));
    for (k, v) in &e.attrs {
        let _ = write!(out, ",{}={}", hs(k), hs(v));
    }
    out.push('{');
    for c in &e.children {
        match c {
            xml::Node::El(c) => dump(c, out),
            xml::Node::Text(t) => {
                out.push('T');
                out.push_str(&hs(t));
                out.push(';');
            }
        }
    }
    out.push('}');
}

/// Lookups on a parsed root: attributes by several names, the numeric readers on `v`, `text()`, the
/// first `t`'s text, the local name and prefix, and the namespace declarations.
fn queries(d: &xml::Doc) -> String {
    let r = &d.root;
    let mut q = vec![];
    for n in ["id", "r:id", "x:id", "v", "a", "xmlns", "b", "val", "name", "a:b"] {
        q.push(opt_hs(r.attr(n)));
    }
    q.push(r.i64("v").map(|v| v.to_string()).unwrap_or("-".into()));
    q.push(r.i32("v").map(|v| v.to_string()).unwrap_or("-".into()));
    q.push(r.u32("v").map(|v| v.to_string()).unwrap_or("-".into()));
    q.push(r.f64("v").map(|v| format!("{:016x}", v.to_bits())).unwrap_or("-".into()));
    q.push(r.bool("v").map(|v| if v { "1" } else { "0" }.to_string()).unwrap_or("-".into()));
    q.push(hs(&r.text()));
    q.push(opt_hs(r.find("t").map(|t| t.text()).as_deref()));
    q.push(hs(r.local()));
    q.push(hs(r.prefix()));
    q.push(d.ns_decls().len().to_string());
    let mut all = vec![];
    r.find_all("t", &mut all);
    q.push(all.len().to_string());
    q.join(",")
}

fn xml_line(input: &[u8], out: &mut String) {
    let _ = write!(out, "{}\t", hex(input));
    match xml::parse(input) {
        Ok(d) => {
            let mut s = String::new();
            dump(&d.root, &mut s);
            let _ = writeln!(out, "ok\t{s}\t{}\t{}", hs(&d.root.to_xml()), queries(&d));
        }
        Err(PptxError::Xml(m)) => {
            let _ = writeln!(out, "err\t{m}");
        }
        Err(e) => {
            let _ = writeln!(out, "err\t{e}");
        }
    }
}

const FRAGMENTS: &[&str] = &[
    "<",
    ">",
    "/>",
    "</",
    "&",
    ";",
    "\"",
    "'",
    "=",
    " ",
    "\t",
    "\r",
    "\n",
    "\r\n",
    "!",
    "?",
    "-",
    "--",
    "[",
    "]",
    "]]>",
    "<![CDATA[",
    "<!--",
    "-->",
    "<!DOCTYPE",
    "<!doctype x",
    "<!ENTITY",
    "<!ELEMENT",
    "<?xml",
    "?>",
    "<?",
    "&amp;",
    "&lt;",
    "&gt;",
    "&quot;",
    "&apos;",
    "&#x41;",
    "&#65;",
    "&#0;",
    "&#xD800;",
    "&#x110000;",
    "&#+5;",
    "&#x;",
    "&#;",
    "&#X41;",
    "&nbsp;",
    "&#13;",
    "&#10;",
    "&#9;",
    "a",
    "p:sp",
    "r:id",
    "xmlns",
    "xmlns:a",
    "id",
    "v",
    "t",
    "a:t",
    ":",
    "x:",
    "\u{0}",
    "\u{1}",
    "\u{b}",
    "\u{FFFE}",
    "\u{FFFF}",
    "é",
    "🎉",
    "\u{2028}",
    "\u{85}",
    "\u{feff}",
    "1",
    "-2",
    "+3",
    "4.5",
    "1e30",
    "nan",
    "inf",
    " 7 ",
    "0x10",
    "true",
    "on",
    "off",
    "1.",
    ".5",
];

const SEEDS: &[&str] = &[
    "<a/>",
    "<a></a>",
    "<p:sp a=\"1\"><p:t>x &amp; y</p:t><e/></p:sp>",
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<a:p xmlns:a=\"x\" xmlns=\"y\"><a:r><a:t>A &amp; B &#x41; &lt;</a:t></a:r><a:x r:id=\"rId1\" id=\"5\"/></a:p>",
    "<a:p><a:t>one\r\ntwo\rthree&#13;four</a:t><a:t><![CDATA[x\r\ny]]></a:t></a:p>",
    "<!DOCTYPE a [<!ENTITY e 'v>'><!-- > --><?p > ?><!ELEMENT a ANY><!ATTLIST a b CDATA \"x>\">]><a>1</a>",
    "<!DOCTYPE a PUBLIC \"-//x//[>\" 'y'><a/>",
    "<a v=' 42 ' id=\"7\" r:id='rId3' x:id=\"9\"><t>t1</t><b><t>t2</t></b></a>",
    "<a v='a\tb\r\nc\rd&#10;e&lt;f&amp;g'/>",
    "<a x=1 y='2' z w = \"3\" v='q'/>",
    "<a / ><b/></a>",
    "<a><b>x</c></d>tail</a>more<z/>",
    "<a><!-- c --><?pi x?>text<![CDATA[<cdata>]]></a>",
    "<a v=\"1e5\" b='on'/>",
    "<root xmlns:a='1' xmlns:b='2' a:v='3' v='4'/>",
    "\u{feff}<a/>",
    "<a>&#x1F389;&#128512;</a>",
    "<a v='x&foo;y'/>",
    "<a v='&#0;'/>",
    "<a v='&#x41'/>",
    "<a>\u{0}\u{1}</a>",
    "<a v='+0.5' />",
    "<a v='-9223372036854775809'/>",
    "<a v='9223372036854775807'/>",
    "<a v='4294967296'/>",
    "<a v='1E3'/>",
    "<dgm:pt modelId=\"{0}\" type=\"pres\"><dgm:prSet presAssocID=\"x\"/></dgm:pt>",
];

fn gen_xml(rng: &mut Rng, base: &[u8]) -> Vec<u8> {
    let mut v = base.to_vec();
    let n = 1 + rng.below(4);
    for _ in 0..n {
        match rng.below(5) {
            0 | 1 => {
                let at = rng.below(v.len() + 1);
                let f = rng.pick(FRAGMENTS).as_bytes();
                v.splice(at..at, f.iter().copied());
            }
            2 => {
                if !v.is_empty() {
                    let a = rng.below(v.len());
                    let b = (a + 1 + rng.below(4)).min(v.len());
                    v.drain(a..b);
                }
            }
            3 => {
                if !v.is_empty() {
                    let at = rng.below(v.len());
                    v[at] = *rng.pick(&[0xFFu8, 0xC3, 0x80, 0x00, b'<', b'&', b'"', b'\'', b'>', b' ', 0x0D, 0xEF]);
                }
            }
            _ => {
                let cut = rng.below(v.len() + 1);
                v.truncate(cut);
            }
        }
    }
    v
}

fn write_xml(dir: &std::path::Path, rng: &mut Rng, corpus_xml: &[Vec<u8>]) -> usize {
    let mut out = String::new();
    let mut n = 0;
    let mut inputs: Vec<Vec<u8>> = vec![];
    for s in SEEDS {
        inputs.push(s.as_bytes().to_vec());
    }
    for f in FRAGMENTS {
        inputs.push(format!("<a v='{f}'>{f}</a>").into_bytes());
        inputs.push(format!("<a v=\"{f}\"/>").into_bytes());
    }
    // UTF-16 parts, both byte orders, with and without a declaration.
    for s in ["<?xml version=\"1.0\" encoding=\"UTF-16\"?><a>é🎉</a>", "<a b='1'>x</a>", "<?xml?><a/>"] {
        let mut le = vec![0xFF, 0xFE];
        let mut be = vec![0xFE, 0xFF];
        for u in s.encode_utf16() {
            le.extend(u.to_le_bytes());
            be.extend(u.to_be_bytes());
        }
        le.push(0x41); // an odd trailing byte
        inputs.push(le);
        inputs.push(be);
    }
    inputs.push(vec![0xFF, 0xFE, 0x00, 0xD8, 0x41, 0x00]); // a lone surrogate
    inputs.push(b"\xEF\xBB\xBF\xEF\xBB\xBF<a/>".to_vec());
    inputs.push("<a>".repeat(xml::MAX_DEPTH - 1).into_bytes());
    inputs.push("<a>".repeat(xml::MAX_DEPTH).into_bytes());
    inputs.push("<a>".repeat(xml::MAX_DEPTH + 1).into_bytes());
    let mut deep_empty = "<a>".repeat(xml::MAX_DEPTH);
    deep_empty.push_str("<b/>");
    inputs.push(deep_empty.into_bytes());
    for i in 0..30_000 {
        let base: Vec<u8> = if i % 3 == 0 && !corpus_xml.is_empty() {
            let c = rng.pick(corpus_xml);
            let len = c.len().min(400 + rng.below(1200));
            c[..len].to_vec()
        } else {
            rng.pick(SEEDS).as_bytes().to_vec()
        };
        inputs.push(gen_xml(rng, &base));
    }
    for input in &inputs {
        xml_line(input, &mut out);
        n += 1;
    }
    std::fs::write(dir.join("xml.txt"), out).expect("write xml.txt");
    n
}

fn write_escape(dir: &std::path::Path, rng: &mut Rng) -> usize {
    let mut strings: Vec<String> = (0u32..0x80).filter_map(char::from_u32).map(|c| c.to_string()).collect();
    strings.extend(["", "a\rb", "\u{FFFE}\u{FFFF}\u{FFFD}", "é 中文 🎉", "\u{85}\u{2028}\u{7f}", "\"'<>&\t\n\r"].map(String::from));
    let palette: Vec<char> = "ab<>&\"'\t\n\r\u{0}\u{1}\u{1f}\u{7f}\u{80}\u{FFFE}\u{FFFF}\u{EFFF}\u{F000}éø🎉 ".chars().collect();
    for _ in 0..3000 {
        let n = rng.below(20);
        strings.push((0..n).map(|_| *rng.pick(&palette)).collect());
    }
    let mut out = String::new();
    for s in &strings {
        let _ = writeln!(out, "{}\t{}\t{}", hs(s), hs(&xml::esc(s)), hs(&xml::esc_attr(s)));
    }
    std::fs::write(dir.join("escape.txt"), out).expect("write escape.txt");
    strings.len()
}

fn write_corpus(dir: &std::path::Path, decks: &std::path::Path) -> (usize, Vec<Vec<u8>>) {
    let mut out = String::new();
    let mut n = 0;
    let mut xmls = vec![];
    let mut entries: Vec<_> = std::fs::read_dir(decks).map(|d| d.flatten().map(|e| e.path()).collect()).unwrap_or_default();
    entries.sort();
    for path in entries {
        if path.extension().and_then(|e| e.to_str()) != Some("pptx") {
            continue;
        }
        let deck = path.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string();
        let bytes = std::fs::read(&path).expect("read deck");
        let pkg = match opc::Package::open(&bytes) {
            Ok(p) => p,
            Err(e) => {
                let _ = writeln!(out, "deck\t{deck}\terr\t{e}");
                continue;
            }
        };
        let _ = writeln!(out, "deck\t{deck}\tok");
        let z = zip::ZipArchive::new(std::io::Cursor::new(&bytes[..])).expect("zip");
        let names: Vec<String> = z.file_names().map(String::from).collect();
        for name in names {
            let data = pkg.get(&name);
            let ct = pkg.content_type(&name);
            let rels = pkg.rels(&name);
            let mut r = String::new();
            for it in &rels.items {
                let _ = write!(r, "{}:{}:{}:{}:{}:{}:{};", hs(&it.id), hs(&it.kind), hs(&it.ty), hs(&it.target_raw), hs(&it.target), it.external as u8, 0);
            }
            let _ = write!(
                out,
                "part\t{deck}\t{}\t{}\t{}\t{}\t{}",
                hs(&name),
                data.map(|d| d.len().to_string()).unwrap_or("-".into()),
                opt_hs(ct.as_deref()),
                if r.is_empty() { "-".into() } else { r },
                opt_hs(pkg.original_name(&name)),
            );
            let is_xml = name.ends_with(".xml") || name.ends_with(".rels");
            match (is_xml, data) {
                (true, Some(d)) => {
                    xmls.push(d.to_vec());
                    match xml::parse(d) {
                        Ok(doc) => {
                            let mut s = String::new();
                            dump(&doc.root, &mut s);
                            let _ = writeln!(out, "\tok\t{s}\t{}", hs(&doc.root.to_xml()));
                        }
                        Err(e) => {
                            let _ = writeln!(out, "\terr\t{e}");
                        }
                    }
                }
                _ => {
                    let _ = writeln!(out, "\t-");
                }
            }
            n += 1;
        }
    }
    std::fs::write(dir.join("corpus.txt"), out).expect("write corpus.txt");
    (n, xmls)
}

/// A zip of `entries`. The zip crate won't write a name twice, so repeats of `dup` are written as
/// `dvp`, `dwp`… and renamed afterwards, in the local headers and the central directory alike.
fn zip_with(entries: &[(&str, Vec<u8>, bool)]) -> Vec<u8> {
    let mut zw = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
    let mut dups = 0u8;
    let mut written: Vec<String> = vec![];
    for (name, data, deflate) in entries {
        let mut name = name.to_string();
        if name == "dup" && written.contains(&name) {
            dups += 1;
            name = format!("d{}p", (b'u' + dups) as char);
        } else if written.contains(&name) {
            continue;
        }
        written.push(name.clone());
        let o = zip::write::SimpleFileOptions::default()
            .compression_method(if *deflate { zip::CompressionMethod::Deflated } else { zip::CompressionMethod::Stored });
        zw.start_file(name.as_str(), o).expect("start");
        zw.write_all(data).expect("write");
    }
    let mut z = zw.finish().expect("finish").into_inner();
    for k in 1..=dups {
        let from = [b'd', b'u' + k, b'p'];
        let mut i = 0;
        while i + 3 <= z.len() {
            if z[i..i + 3] == from {
                z[i + 1] = b'u';
            }
            i += 1;
        }
    }
    z
}

/// Flip a byte inside one entry's stored data, so reading it fails its CRC (or inflating fails).
fn corrupt_one(z: &mut Vec<u8>, rng: &mut Rng) {
    let target = {
        let Ok(mut a) = zip::ZipArchive::new(std::io::Cursor::new(&z[..])) else { return };
        if a.len() == 0 {
            return;
        }
        let i = rng.below(a.len());
        let Ok(f) = a.by_index_raw(i) else { return };
        if f.compressed_size() == 0 {
            return;
        }
        f.data_start() as usize + rng.below(f.compressed_size() as usize)
    };
    if let Some(b) = z.get_mut(target) {
        *b ^= 0x55;
    }
}

fn modules(dir: &std::path::Path, rng: &mut Rng) -> usize {
    let mut out = String::new();
    let mut n = 0;
    let mut line = |out: &mut String, s: String| {
        out.push_str(&s);
        out.push('\n');
        n += 1;
    };

    // opc: path functions over generated paths.
    let segs = ["ppt", "slides", "..", ".", "", "media", "a%20b.png", "a%2", "%41", "x#frag", "\\", "_rels", "chart1.xml", "chart.xml", "chart1.xml.rels", "chartA.xml", "embeddings", "charts", "drawings", "PPT", "é", "/", "a%zz", "%e9", "%C3%A9"];
    let mut paths: Vec<String> = vec![String::new()];
    for _ in 0..3000 {
        let k = rng.below(6);
        let mut p = String::new();
        if rng.below(4) == 0 {
            p.push('/');
        }
        for i in 0..k {
            if i > 0 {
                p.push(if rng.below(8) == 0 { '\\' } else { '/' });
            }
            p.push_str(rng.pick(&segs));
        }
        paths.push(p);
    }
    for p in &paths {
        line(&mut out, format!("norm\t{}\t{}", hs(p), hs(&opc::norm(p))));
        line(&mut out, format!("dirof\t{}\t{}", hs(p), hs(&opc::dir_of(p))));
        line(&mut out, format!("fileof\t{}\t{}", hs(p), hs(opc::file_of(p))));
        line(&mut out, format!("relspath\t{}\t{}", hs(p), hs(&opc::rels_path(p))));
        line(&mut out, format!("sidecar\t{}\t{}", hs(p), opc::sidecar_part(p) as u8));
        let q = rng.pick(&paths);
        line(&mut out, format!("resolve\t{}\t{}\t{}", hs(p), hs(q), hs(&opc::resolve(p, q))));
        line(&mut out, format!("relative\t{}\t{}\t{}", hs(p), hs(q), hs(&opc::relative(p, q))));
    }

    // opc: rels parts.
    for _ in 0..300 {
        let mut x = String::from("<Relationships xmlns=\"r\">");
        for k in 0..rng.below(5) {
            let mode = *rng.pick(&["", " TargetMode=\"External\"", " TargetMode=\"EXTERNAL\"", " TargetMode=\"Internal\""]);
            let ty = *rng.pick(&["http://x/relationships/slide", "image", "http://x/a/", "plain"]);
            let target = rng.pick(&paths).replace('&', "&amp;").replace('"', "&quot;").replace('<', "&lt;");
            let id = if rng.below(10) == 0 { String::new() } else { format!(" Id=\"rId{k}\"") };
            let _ = write!(x, "<Relationship{id} Type=\"{ty}\" Target=\"{target}\"{mode}/>");
        }
        x.push_str("</Relationships>");
        let part = rng.pick(&paths).clone();
        let rels = opc::rels_from_bytes(x.as_bytes(), &part);
        let mut r = String::new();
        for it in &rels.items {
            let _ = write!(r, "{}:{}:{}:{}:{}:{};", hs(&it.id), hs(&it.kind), hs(&it.ty), hs(&it.target_raw), hs(&it.target), it.external as u8);
        }
        line(&mut out, format!("rels\t{}\t{}\t{}", hs(&x), hs(&part), if r.is_empty() { "-".into() } else { r }));
    }

    // opc: packages and their budgets.
    for _ in 0..200 {
        let count = 1 + rng.below(7);
        let mut entries: Vec<(String, Vec<u8>, bool)> = vec![];
        for _ in 0..count {
            let name = (*rng.pick(&["a.xml", "A.XML", "/b.bin", "dir/", "c/d.xml", "e", "dup", "dup", "x\\y.xml", "[Content_Types].xml"])).to_string();
            let len = *rng.pick(&[0usize, 1, 5, 40, 80, 81, 100, 200, 1000]);
            let data: Vec<u8> = (0..len).map(|i| if rng.below(3) == 0 { (rng.next() & 0xFF) as u8 } else { b'a' + (i % 3) as u8 }).collect();
            entries.push((name, data, rng.below(2) == 0));
        }
        let refs: Vec<(&str, Vec<u8>, bool)> = entries.iter().map(|(a, b, c)| (a.as_str(), b.clone(), *c)).collect();
        let mut z = zip_with(&refs);
        // Sometimes corrupt one entry's data (a CRC failure on read).
        if rng.below(3) == 0 {
            corrupt_one(&mut z, rng);
        }
        let max_part = *rng.pick(&[1u64, 50, 100, 1000]);
        let max_total = *rng.pick(&[50u64, 100, 300, 5000]);
        let max_work = *rng.pick(&[60u64, 130, 400, 10000]);
        let res = match opc::Package::open_within(&z, max_part, max_total, max_work) {
            Ok(p) => {
                let mut s = String::new();
                for name in ["a.xml", "A.XML", "b.bin", "/b.bin", "dir/", "c/d.xml", "e", "dup", "x/y.xml", "x\\y.xml", "[content_types].xml"] {
                    let _ = write!(s, "{}:{}:{};", hs(name), p.get(name).map(hex).unwrap_or("-".into()), opt_hs(p.original_name(name)));
                }
                s
            }
            Err(e) => format!("err {e}"),
        };
        line(&mut out, format!("package\t{}\t{max_part}\t{max_total}\t{max_work}\t{res}", hex(&z)));
    }

    // cfb: hostile compound files.
    {
        let base = cfb_build(&["EncryptionInfo", "EncryptedPackage"]);
        let plain = cfb_build(&["PowerPoint Document", "Current User"]);
        for i in 0..400 {
            let mut c = if i % 2 == 0 { base.clone() } else { plain.clone() };
            for _ in 0..1 + rng.below(3) {
                let at = *rng.pick(&[30usize, 44, 48, 60, 68, 76, 80, 512, 516, 520, 1024 + 64, 1024 + 128 + 64, 1100]);
                let v = *rng.pick(&[0u32, 1, 2, 3, 7, 12, 0xFFFF_FFFA, 0xFFFF_FFFE, 0xFFFF_FFFF, 0x7FFF_FFFF, 9]);
                c[at..at + 4].copy_from_slice(&v.to_le_bytes());
            }
            if rng.below(3) == 0 {
                let cut = rng.below(c.len());
                c.truncate(cut);
            }
            line(&mut out, format!("cfb\t{}\t{}", hex(&c), cfb::is_encrypted(&c) as u8));
        }
    }

    line(&mut out, format!("png\t{}", hex(&png::transparent_1x1())));

    // maps: transitions both ways.
    let mut options: Vec<&str> = vec!["", "zz", "hex", "hexx", "single", "particles", "black", "outBounce"];
    for t in TRANSITIONS {
        options.extend(t.4.iter().copied());
    }
    options.sort();
    options.dedup();
    let mut written = vec![];
    for t in TRANSITIONS {
        for o in &options {
            let mut w = xml::W::frag();
            let ns = maps::transition_to_xml(&mut w, t.0, o);
            line(&mut out, format!("trans\t{}\t{}\t{}\t{}", hs(t.0), hs(o), ns.unwrap_or("-"), hs(&w.s)));
            written.push(w.s);
        }
    }
    let mut reads: Vec<String> = written.into_iter().filter(|s| !s.is_empty()).collect();
    let locals = ["fade", "cut", "push", "wipe", "strips", "split", "randomBar", "circle", "diamond", "plus", "zoom", "warp", "newsflash", "pull", "cover", "checker", "blinds", "comb", "wheel", "wheelReverse", "wedge", "vortex", "switch", "flip", "ripple", "doors", "window", "ferris", "gallery", "conveyor", "pan", "glitter", "shred", "reveal", "flythrough", "prism", "prstTrans", "morph", "dissolve", "random", "honeycomb", "flash", "other"];
    let attrs = ["dir=\"l\"", "dir=\"in\"", "dir=\"out\"", "dir=\"r\"", "dir=\"Lu\"", "thruBlk=\"1\"", "thruBlk=\"true\"", "orient=\"vert\"", "pattern=\"hexagon\"", "pattern=\"crush\"", "pattern=\"rectangle\"", "hasBounce=\"on\"", "isContent=\"1\"", "isInverted=\"1\"", "prst=\"wind\"", "prst=\"pageCurlSingle\"", "prst=\"bogus\"", "prst=\"drape\"", "invX=\"1\"", "option=\"byWord\"", "option=\"byChar\""];
    for _ in 0..1500 {
        let mut s = format!("<p:{}", rng.pick(&locals));
        for _ in 0..rng.below(4) {
            s.push(' ');
            s.push_str(rng.pick(&attrs));
        }
        s.push_str("/>");
        reads.push(s);
    }
    for s in &reads {
        let r = xml::parse(s.as_bytes()).ok().and_then(|d| maps::transition_from_xml(&d.root));
        line(&mut out, format!("transread\t{}\t{}", hs(s), r.map(|(k, o)| format!("{}:{}", hs(&k), hs(&o))).unwrap_or("-".into())));
    }

    // maps: animations.
    let classes = [AnimClass::Entrance, AnimClass::Emphasis, AnimClass::Exit, AnimClass::Path, AnimClass::Media];
    let cname = |c: AnimClass| match c {
        AnimClass::Entrance => "entrance",
        AnimClass::Emphasis => "emphasis",
        AnimClass::Exit => "exit",
        AnimClass::Path => "path",
        AnimClass::Media => "media",
    };
    let mut effects: Vec<&str> = ANIMATIONS.iter().map(|a| a.0).collect();
    effects.extend(["bogus", "lines", "arcs", "turns", "strips", "shapeOut"]);
    effects.sort();
    effects.dedup();
    let anim_opts = ["", "b", "l", "d", "u", "horz", "in", "out", "1", "circleIn", "plusOut", "across", "rd", "left", "zz"];
    for e in &effects {
        for s in 0..70u32 {
            line(&mut out, format!("optsub\t{}\t{s}\t{}", hs(e), hs(&maps::option_from_subtype(e, s))));
        }
        for o in anim_opts {
            line(&mut out, format!("subopt\t{}\t{}\t{}", hs(e), hs(o), maps::subtype_from_option(e, o).map(|v| v.to_string()).unwrap_or("-".into())));
        }
    }
    for c in classes {
        for p in 0..80u32 {
            line(&mut out, format!("effpreset\t{}\t{p}\t{}", cname(c), opt_hs(maps::effect_for_preset(c, p))));
        }
        line(&mut out, format!("fallback\t{}\t{}", cname(c), hs(maps::fallback_effect(c))));
    }
    for _ in 0..3000 {
        let mut a = deckcraft_model::Animation::default();
        a.class = *rng.pick(&classes);
        a.effect = (*rng.pick(&effects)).to_string();
        a.option = (*rng.pick(&anim_opts)).to_string();
        a.preset_id = if rng.below(3) == 0 { None } else { Some(rng.below(60) as u32) };
        line(
            &mut out,
            format!(
                "presetfor\t{}\t{}\t{}\t{}\t{}",
                cname(a.class),
                hs(&a.effect),
                hs(&a.option),
                a.preset_id.map(|v| v.to_string()).unwrap_or("-".into()),
                maps::preset_for(&a)
            ),
        );
    }

    // custgeom: formulas.
    let ops = ["*/", "+-", "+/", "?:", "abs", "at2", "cat2", "sat2", "cos", "sin", "tan", "max", "min", "mod", "pin", "sqrt", "val", "bogus", ""];
    let operands = ["w", "h", "ss", "ls", "hc", "vc", "wd2", "hd3", "ssd8", "cd2", "cd4", "3cd4", "7cd8", "0", "1", "-1", "100000", "-5400000", "21600000", "1e300", "nan", "inf", "2.5", " 3 ", "x1", "adj"];
    let mut sizes = vec![(0.0f64, 0.0f64), (1000.0, 500.0), (914_400.0, 457_200.0), (1.0, 1e12), (f64::NAN, 5.0), (1e20, -3.0)];
    for _ in 0..20 {
        sizes.push(((rng.next() % 10_000_000) as f64, (rng.next() % 10_000_000) as f64 / 7.0));
    }
    let fmla = |rng: &mut Rng| {
        let mut f = (*rng.pick(&ops)).to_string();
        for _ in 0..rng.below(5) {
            f.push(*rng.pick(&[' ', ' ', ' ', '\t', '\u{3000}']));
            f.push_str(rng.pick(&operands));
        }
        f
    };
    for _ in 0..6000 {
        let (w, h) = *rng.pick(&sizes);
        let mut g = custgeom::Guides::new(w, h);
        g.set("x1", 1234.5);
        let f = fmla(rng);
        line(&mut out, format!("guide\t{:016x}\t{:016x}\t{}\t{:016x}", w.to_bits(), h.to_bits(), hs(&f), g.eval(&f).to_bits()));
    }
    // custgeom: whole geometries with guides, arcs and every command.
    let commands = ["moveTo", "lnTo", "cubicBezTo", "quadBezTo", "arcTo", "close", "other"];
    for _ in 0..1500 {
        let mut x = String::from("<a:custGeom><a:avLst>");
        for k in 0..rng.below(3) {
            let _ = write!(x, "<a:gd name=\"adj{k}\" fmla=\"val {}\"/>", rng.below(100_000));
        }
        x.push_str("</a:avLst><a:gdLst>");
        for k in 0..rng.below(5) {
            let _ = write!(x, "<a:gd name=\"g{k}\" fmla=\"{}\"/>", fmla(rng));
        }
        x.push_str("</a:gdLst><a:pathLst>");
        for _ in 0..1 + rng.below(3) {
            let pw = *rng.pick(&["", " w=\"0\"", " w=\"21600\"", " w=\"100\" h=\"50\"", " h=\"7\"", " w=\"-5\" h=\"-5\""]);
            let fill = *rng.pick(&["", " fill=\"none\"", " fill=\"lighten\"", " fill=\"lightenLess\"", " fill=\"darken\"", " fill=\"darkenLess\"", " fill=\"bogus\""]);
            let stroke = *rng.pick(&["", " stroke=\"0\"", " stroke=\"true\"", " stroke=\"x\""]);
            let _ = write!(x, "<a:path{pw}{fill}{stroke}>");
            for _ in 0..rng.below(8) {
                let c = *rng.pick(&commands);
                let pt = |rng: &mut Rng| format!("<a:pt x=\"{}\" y=\"{}\"/>", rng.pick(&operands), rng.pick(&["g0", "g1", "h", "0", "333", "-7"]));
                match c {
                    "moveTo" | "lnTo" => {
                        let p = pt(rng);
                        let _ = write!(x, "<a:{c}>{p}</a:{c}>");
                    }
                    "cubicBezTo" | "quadBezTo" => {
                        let k = if c == "cubicBezTo" { 3 } else { 2 };
                        let k = if rng.below(5) == 0 { k + 1 } else { k };
                        let _ = write!(x, "<a:{c}>");
                        for _ in 0..k {
                            let p = pt(rng);
                            x.push_str(&p);
                        }
                        let _ = write!(x, "</a:{c}>");
                    }
                    "arcTo" => {
                        let _ = write!(
                            x,
                            "<a:arcTo wR=\"{}\" hR=\"{}\" stAng=\"{}\" swAng=\"{}\"/>",
                            rng.pick(&["w", "50", "0", "hd2", "g0"]),
                            rng.pick(&["h", "50", "1e-12", "wd4"]),
                            rng.pick(&["0", "cd4", "-5400000", "g1", "16200000"]),
                            rng.pick(&["0", "cd2", "21600000", "-10800000", "5400000", "43200000", "g2", "1"])
                        );
                    }
                    "close" => x.push_str("<a:close/>"),
                    _ => x.push_str("<a:other/>"),
                }
            }
            x.push_str("</a:path>");
        }
        x.push_str("</a:pathLst></a:custGeom>");
        let (w, h) = *rng.pick(&sizes);
        let d = xml::parse(x.as_bytes()).expect("generated custGeom parses");
        let paths = custgeom::read_cust_geom(&d.root, w, h);
        line(&mut out, format!("cgread\t{}\t{:016x}\t{:016x}\t{}", hs(&x), w.to_bits(), h.to_bits(), paths_spec(&paths)));
        let mut wr = xml::W::frag();
        custgeom::write_cust_geom(&mut wr, &paths);
        line(&mut out, format!("cgwrite\t{}\t{}", paths_spec(&paths), hs(&wr.s)));
    }
    // custgeom: path syntax.
    let toks = ["M", "L", "C", "Q", "Z", "E", "m", "z", " ", ",", "-", "1", "2.5", "1e3", "1e-3", "e", "x", "\t", "\n", "--1", "7.", "nan", "inf", "1e999"];
    for _ in 0..3000 {
        let s: String = (0..rng.below(20)).map(|_| *rng.pick(&toks)).collect();
        let p = custgeom::parse_path(&s);
        let mut r = String::new();
        for (c, v) in &p {
            let _ = write!(r, "{c}");
            for x in v {
                let _ = write!(r, ":{:016x}", x.to_bits());
            }
            r.push(';');
        }
        line(&mut out, format!("parsepath\t{}\t{}", hs(&s), if r.is_empty() { "-".into() } else { r }));
        let cp = CustomPath { w: *rng.pick(&[0.0, 10.0, 100.0, 19_999.0, 20_000.0, 914_400.0, -50.0, f64::INFINITY]), h: *rng.pick(&[0.0, 5.0, 1e9, 33.3]), d: s.clone(), fill: FillMode::Norm, stroke: rng.below(2) == 0 };
        let mut wr = xml::W::frag();
        custgeom::write_cust_geom(&mut wr, std::slice::from_ref(&cp));
        line(&mut out, format!("cgwrite\t{}\t{}", paths_spec(std::slice::from_ref(&cp)), hs(&wr.s)));
    }

    // tables.
    let mut guid_inputs: Vec<String> = deckcraft_model::table::table_styles().into_iter().map(|(id, _)| id).collect();
    guid_inputs.extend(["", "{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}", "{5c22544a-7ee6-4342-b048-85bdc9fd1c3a}", "{ABCDEF00-0000-0000-0000-000000000000}", "medium2", "bogus", "é"].map(String::from));
    let own: Vec<String> = deckcraft_model::table::table_styles().into_iter().map(|(id, _)| tables::guid(&format!("deckcraft-table-style:{id}"))).collect();
    guid_inputs.extend(own.iter().cloned());
    guid_inputs.extend(own.iter().map(|g| g.to_ascii_lowercase()));
    for s in &guid_inputs {
        let (g, def) = tables::guid_for_style(s);
        line(&mut out, format!("guid\t{}\t{}", hs(s), hs(&tables::guid(s))));
        line(&mut out, format!("stylefromguid\t{}\t{}", hs(s), hs(&tables::style_from_guid(s))));
        line(&mut out, format!("guidforstyle\t{}\t{}\t{}", hs(s), hs(&g), def as u8));
        line(&mut out, format!("isownguid\t{}\t{}", hs(s), tables::is_own_guid(s) as u8));
    }
    let raws = [
        "<a:tblStyle styleId=\"{X}\" styleName=\"Mine\"><a:wholeTbl/></a:tblStyle>",
        "<a:other/>",
        "<a:tblStyle",
        "<a:tblStyle styleId='{Y}'/>",
    ];
    for _ in 0..300 {
        let used: Vec<String> = (0..rng.below(6)).map(|_| rng.pick(&guid_inputs).clone()).collect();
        let defs: Vec<deckcraft_model::table::TableStyleDef> = (0..rng.below(3))
            .map(|_| deckcraft_model::table::TableStyleDef {
                id: rng.pick(&guid_inputs).clone(),
                raw: (*rng.pick(&raws)).to_string(),
                ..Default::default()
            })
            .collect();
        let u: Vec<String> = used.iter().map(|s| hs(s)).collect();
        let d: Vec<String> = defs.iter().map(|d| format!("{}:{}", hs(&d.id), hs(&d.raw))).collect();
        line(&mut out, format!("tablestyles\t{}\t{}\t{}", u.join(","), d.join(","), hex(&tables::table_styles_xml(&used, &defs))));
    }

    // dgm: ids.
    let kinds = ["list", "blockList", "hBulletList", "process", "chevron", "verticalProcess", "stepUp", "cycle", "blockCycle", "radial", "hierarchy", "pyramid", "invertedPyramid", "matrix", "titledMatrix", "pictureList", "pictureCaption", "pictureProcess", "pictureHList", "timeline", "venn", "target", "textCycle", "continuousCycle", "horizontalHierarchy", "gridMatrix", "gear", "funnel", "segmentedCycle", "multidirectionalCycle", "orgChart", "halfCircleOrgChart", "nameTitleOrgChart", "verticalBoxList", "trapezoidList", "tableList", "accentProcess", "continuousBlockProcess", "bendingProcess", "linearVenn", "stackedVenn", "nestedTarget", "cycleMatrix", "segmentedPyramid", "pie", "bogus", ""];
    let styles = ["", "subtle", "intense", "outline", "polished", "inset", "cartoon", "powder", "brick", "flat", "bogus"];
    let colors = ["", "colorful", "range12", "range23", "range34", "range45", "range56", "range67", "range", "accent0", "accent1", "accent6", "accent7", "accent3Grad", "accent", "accentX", "rangeé", "accent1_2"];
    for k in kinds {
        line(&mut out, format!("layoutid\t{}\t{}", hs(k), hs(dgm::layout_id(k))));
        line(&mut out, format!("layoutxml\t{}\t{}", hs(k), hex(&dgm::layout_xml(k))));
    }
    for s in styles {
        line(&mut out, format!("qsid\t{}\t{}", hs(s), hs(&dgm::qs_id(s))));
        line(&mut out, format!("stylexml\t{}\t{}", hs(s), hex(&dgm::style_xml(s))));
    }
    for c in colors {
        line(&mut out, format!("csid\t{}\t{}", hs(c), hs(&dgm::cs_id(c))));
        line(&mut out, format!("colorsxml\t{}\t{}", hs(c), hex(&dgm::colors_xml(c))));
    }
    let lasts = ["simple1", "simple2", "simple3", "simple4", "simple5", "3d1", "3d2", "3d3", "3d4", "3d5", "", "x", "colorful1", "colorful2", "colorful5", "colorful6", "colorful+3", "colorful03", "accent1_2", "accent3_3", "accent6_5", "accent7_2", "accent2", "accent2_", "accent+4_4", "default", "hList2", "pList2", "orgChart1", "NameandTitleOrganizationalChart", "HalfCircleOrganizationChart", "gear1", "chevron2", "hProcess9", "arrow3", "venn9", "radial4", "cycle9", "pyramid9", "matrix9", "hierarchy9", "timeline1", "funnel1", "target9", "unknown"];
    let prefixes = ["", "urn:microsoft.com/office/officeart/2005/8/layout/", "urn:x/", "a/b/"];
    let cats = ["", "list", "process", "PROCESS", "cycle", "relationship", "hierarchy", "matrix", "pyramid", "picture", "other"];
    for p in prefixes {
        for l in lasts {
            let id = format!("{p}{l}");
            line(&mut out, format!("stylefor\t{}\t{}", hs(&id), hs(dgm::style_for(&id))));
            line(&mut out, format!("colorsfor\t{}\t{}", hs(&id), hs(&dgm::colors_for(&id))));
            for c in cats {
                line(&mut out, format!("kindfor\t{}\t{}\t{}", hs(&id), hs(c), hs(dgm::kind_for(&id, c))));
            }
        }
    }
    for k in kinds {
        let id = dgm::layout_id(k);
        for c in cats {
            line(&mut out, format!("kindfor\t{}\t{}\t{}", hs(id), hs(c), hs(dgm::kind_for(id, c))));
        }
    }
    // dgm: data models and outlines.
    let texts = ["", "CEO", "a & b <c>", "line\nbreak", "é🎉", " ", "x\ry"];
    for _ in 0..500 {
        let count = rng.below(8);
        let mut nodes = vec![];
        for _ in 0..count {
            nodes.push(DiagramNode {
                text: (*rng.pick(&texts)).to_string(),
                level: rng.below(4) as u8,
                picture: None,
                assistant: rng.below(5) == 0,
                title: if rng.below(4) == 0 { (*rng.pick(&texts)).to_string() } else { String::new() },
            });
        }
        let d = Diagram {
            kind: (*rng.pick(&kinds)).to_string(),
            nodes,
            style: (*rng.pick(&styles)).to_string(),
            colors: (*rng.pick(&colors)).to_string(),
            layout_id: if rng.below(4) == 0 { "urn:custom/layout".into() } else { String::new() },
            ..Default::default()
        };
        let seed = rng.next() as u32;
        let rel = format!("rId{}", rng.below(20));
        let pics: Vec<(usize, String)> = (0..rng.below(4)).map(|_| (rng.below(10), format!("rId{}", rng.below(9)))).collect();
        let x = dgm::data_xml(&d, seed, &rel, &pics);
        let ns: Vec<String> = d.nodes.iter().map(|n| format!("{}:{}:{}:{}", hs(&n.text), n.level, n.assistant as u8, hs(&n.title))).collect();
        let ps: Vec<String> = pics.iter().map(|(k, r)| format!("{k}:{}", hs(r))).collect();
        line(
            &mut out,
            format!("dataxml\t{}\t{}\t{}\t{}\t{seed}\t{}\t{}\t{}\t{}", hs(&d.kind), hs(&d.style), hs(&d.colors), hs(&d.layout_id), hs(&rel), ns.join(","), ps.join(","), hex(&x)),
        );
        // Read it back, sometimes damaged.
        let input = if rng.below(2) == 0 { x.clone() } else { gen_xml(rng, &x) };
        if let Ok(doc) = xml::parse(&input) {
            let o: Vec<String> = dgm::outline(&doc.root).iter().map(|n| format!("{}:{}:{}:{}", hs(&n.text), n.level, n.assistant as u8, hs(&n.title))).collect();
            let p: Vec<String> = dgm::node_pictures(&doc.root).iter().map(|(k, r)| format!("{k}:{}", hs(r))).collect();
            line(&mut out, format!("outline\t{}\t{}\t{}", hex(&input), o.join(","), p.join(",")));
        }
    }
    let hostile = br#"<dgm:dataModel xmlns:dgm="d"><dgm:ptLst><dgm:pt modelId="0" type="doc"/><dgm:pt modelId="1"><dgm:t><a:p xmlns:a="a"><a:r><a:t>A</a:t></a:r></a:p></dgm:t></dgm:pt><dgm:pt modelId="2"/><dgm:pt modelId="3" type="asst"/><dgm:pt modelId="9" type="pres"><dgm:prSet presName="titleText1" presAssocID="1"/><dgm:t><a:p><a:t>T</a:t></a:p><a:p><a:t> </a:t></a:p><a:p><a:r><a:t>U</a:t></a:r></a:p></dgm:t></dgm:pt></dgm:ptLst><dgm:cxnLst><dgm:cxn srcId="0" destId="1" srcOrd="2"/><dgm:cxn srcId="0" destId="3" srcOrd="2"/><dgm:cxn srcId="1" destId="2"/><dgm:cxn srcId="2" destId="1"/><dgm:cxn type="presOf" srcId="0" destId="2"/><dgm:cxn srcId="0" destId="9"/></dgm:cxnLst></dgm:dataModel>"#;
    {
        let doc = xml::parse(hostile).expect("hostile parses");
        let o: Vec<String> = dgm::outline(&doc.root).iter().map(|n| format!("{}:{}:{}:{}", hs(&n.text), n.level, n.assistant as u8, hs(&n.title))).collect();
        let p: Vec<String> = dgm::node_pictures(&doc.root).iter().map(|(k, r)| format!("{k}:{}", hs(r))).collect();
        line(&mut out, format!("outline\t{}\t{}\t{}", hex(hostile), o.join(","), p.join(",")));
    }

    std::fs::write(dir.join("modules.txt"), out).expect("write modules.txt");
    n
}

fn paths_spec(paths: &[CustomPath]) -> String {
    let v: Vec<String> = paths
        .iter()
        .map(|p| {
            let fill = match p.fill {
                FillMode::Norm => "norm",
                FillMode::None => "none",
                FillMode::Lighten => "lighten",
                FillMode::LightenLess => "lightenLess",
                FillMode::Darken => "darken",
                FillMode::DarkenLess => "darkenLess",
            };
            format!("{:016x}:{:016x}:{}:{fill}:{}", p.w.to_bits(), p.h.to_bits(), hs(&p.d), p.stroke as u8)
        })
        .collect();
    if v.is_empty() { "-".into() } else { v.join(",") }
}

/// cfb.rs's test `build`: a minimal compound file whose directory holds a root entry and `streams`.
fn cfb_build(streams: &[&str]) -> Vec<u8> {
    const SIGNATURE: [u8; 8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
    const END_OF_CHAIN: u32 = 0xFFFF_FFFE;
    let mut b = vec![0u8; 512 * 3];
    b[..8].copy_from_slice(&SIGNATURE);
    b[24..26].copy_from_slice(&0x3Eu16.to_le_bytes());
    b[26..28].copy_from_slice(&3u16.to_le_bytes());
    b[28..30].copy_from_slice(&0xFFFEu16.to_le_bytes());
    b[30..32].copy_from_slice(&9u16.to_le_bytes());
    b[32..34].copy_from_slice(&6u16.to_le_bytes());
    b[44..48].copy_from_slice(&1u32.to_le_bytes());
    b[48..52].copy_from_slice(&1u32.to_le_bytes());
    b[60..64].copy_from_slice(&END_OF_CHAIN.to_le_bytes());
    b[68..72].copy_from_slice(&END_OF_CHAIN.to_le_bytes());
    for i in 0..109 {
        b[76 + i * 4..80 + i * 4].copy_from_slice(&0xFFFF_FFFFu32.to_le_bytes());
    }
    b[76..80].copy_from_slice(&0u32.to_le_bytes());
    for i in 0..128 {
        b[512 + i * 4..516 + i * 4].copy_from_slice(&0xFFFF_FFFFu32.to_le_bytes());
    }
    b[512..516].copy_from_slice(&0xFFFF_FFFDu32.to_le_bytes());
    b[516..520].copy_from_slice(&END_OF_CHAIN.to_le_bytes());
    for (k, name) in std::iter::once("Root Entry").chain(streams.iter().copied()).take(4).enumerate() {
        let e = 1024 + k * 128;
        let units: Vec<u16> = name.encode_utf16().take(31).collect();
        for (i, u) in units.iter().enumerate() {
            b[e + i * 2..e + i * 2 + 2].copy_from_slice(&u.to_le_bytes());
        }
        b[e + 64..e + 66].copy_from_slice(&((units.len() as u16 + 1) * 2).to_le_bytes());
        b[e + 66] = if k == 0 { 5 } else { 2 };
    }
    b
}

fn main() {
    let root = std::path::PathBuf::from(std::env::args().nth(1).unwrap_or_else(|| "../../../../DeckCraftNative-Fixtures".into()));
    let pin = std::env::args().nth(2).unwrap_or_else(|| "27009cd9".into());
    let dir = root.join("pptx");
    std::fs::create_dir_all(&dir).expect("create pptx dir");
    let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
    let (parts, corpus_xml) = write_corpus(&dir, &root.join("oracle").join(&pin).join("decks"));
    let cases = write_xml(&dir, &mut rng, &corpus_xml);
    let escapes = write_escape(&dir, &mut rng);
    let calls = modules(&dir, &mut rng);
    println!("{parts} corpus parts, {cases} xml cases, {escapes} escapes, {calls} module calls");
}
