//! metafile-vectors OUT_DIR — builds a set of WMF, EMF and EMF+ files (the shapes deckcraft-metafile's own
//! tests write, more arcs, rotations, text, brushes, clips and bitmap formats, and deterministic mutations of
//! each), parses them with deckcraft-metafile, places each picture on a target, and writes into OUT_DIR:
//!
//! - `<case>.bin`: the input file;
//! - `dumps.txt`: per case, `== <case>` then the parsed model and the placed items, every float as its bit
//!   pattern in hex (or `err <Error>`).
//!
//! The Swift test (`DCMetafileTests/OracleTests.swift`) parses each `.bin`, writes the same dump and
//! compares line for line. The record builders follow crates/metafile/src/tests.rs (MIT OR Apache-2.0,
//! © ArtCraft Team and the DeckCraft contributors). Nothing here comes from a Microsoft product.
use deckcraft_metafile::{HAlign, Item, PlacedItem, Seg, Text, VAlign, is_metafile, parse};
use kurbo::{Affine, BezPath, PathEl, Rect};
use std::collections::HashMap;
use std::fmt::Write as _;

// ---- Record builders ----

fn h16(v: i32) -> Vec<u8> {
    (v as i16).to_le_bytes().to_vec()
}
fn h32(v: u32) -> Vec<u8> {
    v.to_le_bytes().to_vec()
}
fn e32(v: i32) -> Vec<u8> {
    v.to_le_bytes().to_vec()
}
fn f32s(v: &[f32]) -> Vec<u8> {
    v.iter().flat_map(|x| x.to_le_bytes()).collect()
}
fn cat(parts: Vec<Vec<u8>>) -> Vec<u8> {
    parts.concat()
}
fn u16s(s: &str) -> Vec<u8> {
    s.encode_utf16().flat_map(u16::to_le_bytes).collect()
}

fn wrec(func: u16, params: &[u8]) -> Vec<u8> {
    let mut p = params.to_vec();
    if p.len() % 2 != 0 {
        p.push(0);
    }
    let words = ((6 + p.len()) / 2) as u32;
    let mut v = words.to_le_bytes().to_vec();
    v.extend(func.to_le_bytes());
    v.extend(p);
    v
}

fn wmf(records: &[Vec<u8>], placeable: Option<[i32; 4]>) -> Vec<u8> {
    let body: Vec<u8> = records.concat();
    let eof = wrec(0, &[]);
    let mut f = Vec::new();
    if let Some(bb) = placeable {
        f.extend(0x9AC6_CDD7u32.to_le_bytes());
        f.extend(0u16.to_le_bytes());
        for v in bb {
            f.extend((v as i16).to_le_bytes());
        }
        f.extend(1440u16.to_le_bytes());
        f.extend(0u32.to_le_bytes());
        f.extend(0u16.to_le_bytes());
    }
    let total = (f.len() + 18 + body.len() + eof.len()) / 2;
    f.extend(1u16.to_le_bytes());
    f.extend(9u16.to_le_bytes());
    f.extend(0x300u16.to_le_bytes());
    f.extend((total as u32).to_le_bytes());
    f.extend(16u16.to_le_bytes());
    f.extend(0u32.to_le_bytes());
    f.extend(0u16.to_le_bytes());
    f.extend(body);
    f.extend(eof);
    f
}

fn erec(typ: u32, payload: &[u8]) -> Vec<u8> {
    let mut p = payload.to_vec();
    while p.len() % 4 != 0 {
        p.push(0);
    }
    let mut v = typ.to_le_bytes().to_vec();
    v.extend(((8 + p.len()) as u32).to_le_bytes());
    v.extend(p);
    v
}

fn emf(records: &[Vec<u8>], bounds: [i32; 4], frame: [i32; 4]) -> Vec<u8> {
    let body: Vec<u8> = records.concat();
    let eof = erec(14, &[0; 12]);
    let total = 88 + body.len() + eof.len();
    let mut h = vec![0u8; 88];
    h[0..4].copy_from_slice(&1u32.to_le_bytes());
    h[4..8].copy_from_slice(&88u32.to_le_bytes());
    h[8..24].copy_from_slice(&bounds.iter().flat_map(|v| v.to_le_bytes()).collect::<Vec<u8>>());
    h[24..40].copy_from_slice(&frame.iter().flat_map(|v| v.to_le_bytes()).collect::<Vec<u8>>());
    h[40..44].copy_from_slice(&0x464D_4520u32.to_le_bytes());
    h[44..48].copy_from_slice(&0x0001_0000u32.to_le_bytes());
    h[48..52].copy_from_slice(&(total as u32).to_le_bytes());
    h[52..56].copy_from_slice(&((records.len() + 1) as u32).to_le_bytes());
    h[56..58].copy_from_slice(&1u16.to_le_bytes());
    h[72..76].copy_from_slice(&1000i32.to_le_bytes());
    h[76..80].copy_from_slice(&500i32.to_le_bytes());
    h[80..84].copy_from_slice(&250i32.to_le_bytes());
    h[84..88].copy_from_slice(&125i32.to_le_bytes());
    let mut out = h;
    out.extend(body);
    out.extend(eof);
    out
}

fn erec_at(typ: u32, len: usize, fields: &[(usize, u32)], blobs: &[(usize, &[u8])]) -> Vec<u8> {
    let mut v = vec![0u8; len];
    v[0..4].copy_from_slice(&typ.to_le_bytes());
    v[4..8].copy_from_slice(&(len as u32).to_le_bytes());
    for (off, val) in fields {
        v[*off..*off + 4].copy_from_slice(&val.to_le_bytes());
    }
    for (off, b) in blobs {
        v[*off..*off + b.len()].copy_from_slice(b);
    }
    v
}

fn dib_rec(typ: u32, fields: &[(usize, u32)], blobs: &[(usize, &[u8])], info: &[u8], bits: &[u8]) -> Vec<u8> {
    let at = 112;
    let bits_at = at + info.len();
    let mut f = fields.to_vec();
    f.extend([(84, at as u32), (88, info.len() as u32), (92, bits_at as u32), (96, bits.len() as u32)]);
    let mut b: Vec<(usize, &[u8])> = blobs.to_vec();
    b.extend([(at, info), (bits_at, bits)]);
    erec_at(typ, bits_at + bits.len(), &f, &b)
}

fn info_header(w: i32, h: i32, bpp: u16, size_image: u32) -> Vec<u8> {
    cat(vec![h32(40), e32(w), e32(h), h16(1), h16(i32::from(bpp)), h32(0), h32(size_image), e32(0), e32(0), h32(0), h32(0)])
}

fn dib24_bottom_up() -> Vec<u8> {
    let mut v = info_header(2, 2, 24, 16);
    v.extend([255, 0, 0, 0, 255, 0, 0, 0]);
    v.extend([0, 0, 255, 255, 255, 255, 0, 0]);
    v
}

fn mono_dib(rows: [u8; 8]) -> Vec<u8> {
    let mut v = info_header(8, 8, 1, 32);
    v.extend([255, 255, 255, 0, 0, 0, 0, 0]);
    for r in rows.iter().rev() {
        v.extend([*r, 0, 0, 0]);
    }
    v
}

fn wfont(height: i32, weight: i32, flags: [u8; 3], charset: u8, esc: i32, face: &[u8]) -> Vec<u8> {
    let mut v = cat(vec![h16(height), h16(0), h16(esc), h16(esc), h16(weight)]);
    v.extend(flags);
    v.extend([charset, 0, 0, 0, 0]);
    v.extend(face);
    v.push(0);
    wrec(0x02FB, &v)
}

fn wtext(x: i32, y: i32, s: &[u8], opts: i32, rect: Option<[i32; 4]>, dx: &[i32]) -> Vec<u8> {
    let mut v = cat(vec![h16(y), h16(x), h16(s.len() as i32), h16(opts)]);
    for c in rect.into_iter().flatten() {
        v.extend(h16(c));
    }
    v.extend(s);
    if s.len() % 2 == 1 {
        v.push(0);
    }
    for d in dx {
        v.extend(h16(*d));
    }
    wrec(0x0A32, &v)
}

fn efont(height: i32, esc: i32, weight: i32, italic: u8, charset: u8, face: &str) -> Vec<u8> {
    let mut v = cat(vec![h32(1), e32(height), e32(0), e32(esc), e32(esc), e32(weight)]);
    v.extend([italic, 0, 0, charset, 0, 0, 0, 0]);
    let mut name: Vec<u8> = face.encode_utf16().flat_map(u16::to_le_bytes).collect();
    name.resize(64, 0);
    v.extend(name);
    erec(82, &v)
}

fn etext(wide: bool, x: i32, y: i32, units: &[u16], opts: u32, dx: &[i32]) -> Vec<u8> {
    let no_rect = opts & 0x100 != 0;
    let fixed = if no_rect { 60 } else { 76 };
    let s: Vec<u8> = if wide { units.iter().flat_map(|u| u.to_le_bytes()).collect() } else { units.iter().map(|u| *u as u8).collect() };
    let s_off = fixed;
    let dx_off = (s_off + s.len()).next_multiple_of(4);
    let len = dx_off + dx.len() * 4;
    let mut f = vec![(24, 1u32), (36, x as u32), (40, y as u32), (44, units.len() as u32), (48, s_off as u32), (52, opts)];
    f.push((if no_rect { 56 } else { 72 }, if dx.is_empty() { 0 } else { dx_off as u32 }));
    let dxb: Vec<u8> = dx.iter().flat_map(|d| d.to_le_bytes()).collect();
    erec_at(if wide { 84 } else { 83 }, len.next_multiple_of(4), &f, &[(s_off, &s), (dx_off, &dxb)])
}

fn prec(typ: u16, flags: u16, data: &[u8]) -> Vec<u8> {
    let mut d = data.to_vec();
    while d.len() % 4 != 0 {
        d.push(0);
    }
    let mut v = typ.to_le_bytes().to_vec();
    v.extend(flags.to_le_bytes());
    v.extend(((12 + d.len()) as u32).to_le_bytes());
    v.extend((d.len() as u32).to_le_bytes());
    v.extend(d);
    v
}

fn plus_comment(recs: &[Vec<u8>]) -> Vec<u8> {
    let body = recs.concat();
    let mut p = ((body.len() + 4) as u32).to_le_bytes().to_vec();
    p.extend(0x2B46_4D45u32.to_le_bytes());
    p.extend(body);
    erec(70, &p)
}

fn plus_header(dual: bool) -> Vec<u8> {
    prec(0x4001, u16::from(dual), &cat(vec![h32(0xDBC0_1002), h32(0), h32(96), h32(96)]))
}

fn plus_file(recs: Vec<Vec<u8>>, bounds: [i32; 4], frame: [i32; 4]) -> Vec<u8> {
    let mut all = vec![plus_header(false)];
    all.extend(recs);
    emf(&[plus_comment(&all)], bounds, frame)
}

fn solid_pen(argb: u32, width: f32) -> Vec<u8> {
    cat(vec![h32(0xDBC0_1002), h32(0), h32(0), h32(0), f32s(&[width]), h32(0xDBC0_1002), h32(0), h32(argb)])
}

fn font_obj(family: &str, em: f32, unit: u32, style: u32) -> Vec<u8> {
    cat(vec![h32(0xDBC0_1002), f32s(&[em]), h32(unit), h32(style), h32(0), h32(family.encode_utf16().count() as u32), u16s(family)])
}

fn bitmap_obj(w: u32, h: u32, stride: i32, format: u32, pal: &[u32], px: &[u8]) -> Vec<u8> {
    let mut v = cat(vec![h32(0xDBC0_1002), h32(1), h32(w), h32(h), e32(stride), h32(format), h32(0)]);
    if !pal.is_empty() {
        v.extend(cat(vec![h32(0), h32(pal.len() as u32)]));
        v.extend(pal.iter().flat_map(|c| c.to_le_bytes()));
    }
    v.extend(px);
    v
}

fn bitmap_2x2() -> Vec<u8> {
    let px = [0xFFFF_0000u32, 0xFF00_FF00, 0xFF00_00FF, 0xFFFF_FFFF];
    bitmap_obj(2, 2, 8, 0x0026_200A, &[], &px.iter().flat_map(|v| v.to_le_bytes()).collect::<Vec<u8>>())
}

fn draw_image(id: u16, dst: [f32; 4]) -> Vec<u8> {
    prec(0x401A, id, &cat(vec![h32(0), h32(2), f32s(&[0.0, 0.0, 2.0, 2.0]), f32s(&dst)]))
}

fn fill_argb(argb: u32, r: [f32; 4]) -> Vec<u8> {
    prec(0x400A, 0x8000, &cat(vec![h32(argb), h32(1), f32s(&r)]))
}

fn xform(v: [f32; 6]) -> Vec<u8> {
    f32s(&v)
}

// ---- The cases ----

fn cases() -> Vec<(String, Vec<u8>)> {
    let mut c: Vec<(String, Vec<u8>)> = Vec::new();
    let mut add = |name: &str, bytes: Vec<u8>| c.push((name.to_string(), bytes));

    // WMF.
    add(
        "wmf-rect-solid",
        wmf(
            &[
                wrec(0x02FC, &cat(vec![h16(0), h32(0x0000_00FF), h16(0)])),
                wrec(0x012D, &h16(0)),
                wrec(0x041B, &cat(vec![h16(70), h16(110), h16(20), h16(10)])),
            ],
            None,
        ),
    );
    add(
        "wmf-polyline-pen",
        wmf(
            &[
                wrec(0x02FA, &cat(vec![h16(0), h16(4), h16(0), h32(0x0000_FF00)])),
                wrec(0x012D, &h16(0)),
                wrec(0x0325, &cat(vec![h16(3), h16(0), h16(0), h16(50), h16(0), h16(50), h16(40)])),
            ],
            None,
        ),
    );
    let stretch = cat(vec![h32(0x00CC_0020), h16(0), h16(2), h16(2), h16(0), h16(-1), h16(10), h16(-20), h16(0), h16(0), dib24_bottom_up()]);
    add("wmf-stretchdib", wmf(&[wrec(0x0F43, &stretch)], Some([-20, 0, 0, 10])));
    add(
        "wmf-mapping",
        wmf(
            &[
                wrec(0x0103, &h16(8)),
                wrec(0x020B, &cat(vec![h16(100), h16(100)])),
                wrec(0x020C, &cat(vec![h16(50), h16(50)])),
                wrec(0x020E, &cat(vec![h16(100), h16(100)])),
                wrec(0x0214, &cat(vec![h16(100), h16(100)])),
                wrec(0x0213, &cat(vec![h16(150), h16(150)])),
            ],
            None,
        ),
    );
    // Arcs, chords, pies, round rectangles and ellipses at assorted angles under an anisotropic mapping.
    let mut arcs = vec![
        wrec(0x0103, &h16(8)),
        wrec(0x020C, &cat(vec![h16(700), h16(1300)])),
        wrec(0x020E, &cat(vec![h16(330), h16(510)])),
        wrec(0x02FA, &cat(vec![h16(0), h16(7), h16(0), h32(0x0012_3456)])),
        wrec(0x012D, &h16(0)),
    ];
    let mut s = 0x1234u32;
    for i in 0..24 {
        s = s.wrapping_mul(1_103_515_245).wrapping_add(12_345);
        let v = |k: u32| ((s >> k) % 600) as i32;
        let func = [0x0817, 0x081A, 0x0830][i % 3];
        arcs.push(wrec(
            func,
            &cat(vec![h16(v(1)), h16(v(3)), h16(v(5) + 3), h16(v(7)), h16(50 + v(9)), h16(1200 - v(2) / 2), h16(10 + v(4) / 3), h16(17 + v(6) / 7)]),
        ));
    }
    arcs.push(wrec(0x061C, &cat(vec![h16(37), h16(51), h16(400), h16(900), h16(100), h16(300)])));
    arcs.push(wrec(0x061C, &cat(vec![h16(900), h16(900), h16(100), h16(300), h16(400), h16(900)])));
    arcs.push(wrec(0x0418, &cat(vec![h16(611), h16(1231), h16(13), h16(17)])));
    add("wmf-arcs", wmf(&arcs, Some([0, 0, 1300, 700])));
    // Text: escapement, y-up mapping, update-CP, opaque/clipped, character sets.
    add(
        "wmf-text",
        wmf(
            &[
                wrec(0x020C, &cat(vec![h16(100), h16(200)])),
                wfont(-20, 700, [1, 1, 1], 0, 450, b"Arial"),
                wrec(0x012D, &h16(0)),
                wrec(0x0209, &h32(0x0000_00FF)),
                wrec(0x0102, &h16(1)),
                wrec(0x012E, &h16(24 | 6)),
                wtext(50, 60, b"Hi!", 0, None, &[10, 8, 6]),
                wfont(30, 400, [0, 0, 0], 238, 300, b"Times New Roman"),
                wrec(0x012D, &h16(1)),
                wrec(0x012E, &h16(1 | 2)),
                wrec(0x0214, &cat(vec![h16(20), h16(10)])),
                wtext(0, 0, &[0xB9, 0xE8, 0x9E], 0, None, &[5, 7, 9]),
                wtext(0, 0, b"cd", 0, None, &[]),
                wrec(0x0201, &h32(0x0000_FF00)),
                wrec(0x0102, &h16(2)),
                wtext(12, 30, b"ok", 2 | 4, Some([10, 10, 60, 40]), &[]),
                wfont(-10, 400, [0, 0, 0], 128, 1350, b"F"),
                wrec(0x012D, &h16(2)),
                wtext(70, 70, &[0x41, 0x82, 0xA0, 0x42], 0, None, &[1, 2, 3, 4]),
            ],
            None,
        ),
    );
    add(
        "wmf-text-yup",
        wmf(
            &[
                wrec(0x0103, &h16(8)),
                wrec(0x020C, &cat(vec![h16(-100), h16(200)])),
                wrec(0x020E, &cat(vec![h16(77), h16(310)])),
                wfont(-13, 400, [0, 0, 0], 2, 3150, b"Symbol"),
                wrec(0x012D, &h16(0)),
                wtext(40, -30, b"n\xA7A", 0, None, &[]),
            ],
            None,
        ),
    );
    // Brushes and mix modes.
    let square = wrec(0x0324, &cat(vec![h16(4), h16(0), h16(0), h16(40), h16(0), h16(40), h16(40), h16(0), h16(40)]));
    add(
        "wmf-brushes",
        wmf(
            &[
                wrec(0x020C, &cat(vec![h16(100), h16(200)])),
                wrec(0x02FC, &cat(vec![h16(2), h32(0x00FF_0000), h16(4)])),
                wrec(0x012D, &h16(0)),
                wrec(0x041B, &cat(vec![h16(50), h16(50), h16(0), h16(0)])),
                wrec(0x0104, &h16(7)),
                wrec(0x02FC, &cat(vec![h16(0), h32(0x0080_8080), h16(0)])),
                wrec(0x012D, &h16(1)),
                square.clone(),
                wrec(0x0104, &h16(9)),
                wrec(0x0142, &cat(vec![h16(5), h16(0), mono_dib([0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA])])),
                wrec(0x012D, &h16(2)),
                wrec(0x041B, &cat(vec![h16(40), h16(40), h16(0), h16(0)])),
                wrec(0x0104, &h16(7)),
                wrec(0x012D, &h16(1)),
                square,
                wrec(0x0104, &h16(13)),
                wrec(0x0142, &cat(vec![h16(5), h16(0), mono_dib([0xFF, 0x80, 0, 0, 0, 0, 0, 0x01])])),
                wrec(0x012D, &h16(3)),
                wrec(0x041B, &cat(vec![h16(90), h16(190), h16(60), h16(100)])),
                wrec(0x041B, &cat(vec![h16(95), h16(195), h16(62), h16(103)])),
                wrec(0x061D, &cat(vec![h32(0x00F0_0021), h16(30), h16(40), h16(10), h16(20)])),
            ],
            Some([0, 0, 200, 100]),
        ),
    );
    // Clips and polypolygons.
    add(
        "wmf-clips",
        wmf(
            &[
                wrec(0x0416, &cat(vec![h16(30), h16(40), h16(5), h16(10)])),
                wrec(0x0415, &cat(vec![h16(20), h16(30), h16(15), h16(12)])),
                wrec(0x0106, &h16(2)),
                wrec(0x0538, &cat(vec![h16(2), h16(3), h16(4), h16(0), h16(0), h16(30), h16(0), h16(0), h16(30), h16(5), h16(5), h16(50), h16(5), h16(50), h16(50), h16(5), h16(50)])),
                wrec(0x001E, &[]),
                wrec(0x0416, &cat(vec![h16(3), h16(3), h16(1), h16(1)])),
                wrec(0x041B, &cat(vec![h16(40), h16(80), h16(0), h16(0)])),
                wrec(0x0127, &h16(-1)),
                wrec(0x041B, &cat(vec![h16(40), h16(80), h16(0), h16(0)])),
            ],
            Some([0, 0, 80, 40]),
        ),
    );
    add(
        "wmf-isotropic-metric",
        wmf(
            &[
                wrec(0x0103, &h16(7)),
                wrec(0x020C, &cat(vec![h16(50), h16(100)])),
                wrec(0x020E, &cat(vec![h16(-100), h16(400)])),
                wrec(0x0214, &cat(vec![h16(0), h16(0)])),
                wrec(0x0213, &cat(vec![h16(25), h16(50)])),
                wrec(0x0103, &h16(4)),
                wrec(0x0214, &cat(vec![h16(-7), h16(3)])),
                wrec(0x0213, &cat(vec![h16(77), h16(91)])),
            ],
            None,
        ),
    );

    // EMF.
    let mut payload = vec![0u8; 16];
    payload.extend(cat(vec![e32(0), e32(0), e32(0), e32(0), e32(2), e32(2), e32(80), e32(40), e32(120), e32(16), e32(0), e32(0x00CC_0020), e32(100), e32(50)]));
    payload.extend(info_header(2, 2, 24, 16));
    payload.extend(dib24_bottom_up().get(40..).unwrap_or_default());
    add("emf-stretchdibits", emf(&[erec(81, &payload)], [0, 0, 100, 50], [0, 0, 2500, 1250]));
    // A rotated world: shapes, arcs, beziers, text with escapement.
    let (a, b) = (0.866_025_4f32, 0.5f32);
    let mut rot = vec![
        erec(35, &xform([a, b, -b, a, 13.5, -7.25])),
        erec(38, &cat(vec![h32(1), h32(0), e32(3), e32(0), h32(0x00A0_B0C0)])),
        erec(37, &h32(1)),
        erec(42, &cat(vec![e32(0), e32(0), e32(40), e32(20)])),
        erec(44, &cat(vec![e32(5), e32(5), e32(70), e32(33), e32(12), e32(9)])),
        erec(36, &cat(vec![xform([1.5, 0.0, 0.25, 0.75, 3.0, 4.0]), h32(2)])),
    ];
    for (i, typ) in [45u32, 46, 47, 45, 46, 47].iter().enumerate() {
        let k = i as i32;
        rot.push(erec(*typ, &cat(vec![e32(10 * k), e32(3 * k), e32(90 + 7 * k), e32(60 + 5 * k), e32(100 - 13 * k), e32(17 * k), e32(5 * k), e32(80 - 9 * k)])));
    }
    let mut bezier = vec![0u8; 16];
    bezier.extend(cat(vec![e32(4), e32(0), e32(0), e32(5), e32(5), e32(10), e32(5), e32(10), e32(0)]));
    rot.push(erec(2, &bezier));
    rot.push(efont(24, 600, 400, 1, 0, "Segoe UI"));
    rot.push(erec(37, &h32(1)));
    rot.push(erec(22, &h32(0x18 | 2)));
    rot.push(etext(true, 100, 50, &[0x41, 0xD83D, 0xDE00, 0x42], 0, &[10, 6, 0, 4]));
    rot.push(etext(true, 30, 20, &[0x61, 0x62], 0x2000 | 0x100 | 4, &[7, 1, 9, 2]));
    add("emf-rotated", emf(&rot, [0, 0, 200, 100], [0, 0, 5000, 2500]));
    // Bitmaps and blends.
    let dib = dib24_bottom_up();
    let blend = [0u8, 0, 128, 0];
    let alpha = dib_rec(114, &[(24, 3), (28, 4), (32, 7), (36, 5), (44, 0), (48, 0), (100, 2), (104, 2)], &[(40, &blend[..])], &dib[..40], &dib[40..]);
    let blend1 = [0u8, 0, 200, 1];
    let info32 = info_header(2, 1, 32, 8);
    let alpha32 = dib_rec(114, &[(24, 0), (28, 0), (32, 2), (36, 1), (44, 0), (48, 0), (100, 2), (104, 1)], &[(40, &blend1[..])], &info32, &[10, 20, 64, 128, 0, 0, 0, 0]);
    let srcand = dib_rec(76, &[(24, 20), (28, 20), (32, 2), (36, 2), (40, 0x0088_00C6)], &[], &dib[..40], &dib[40..]);
    add("emf-bitmaps", emf(&[alpha, alpha32, srcand], [0, 0, 40, 40], [0, 0, 0, 0]));
    // Clip regions.
    let mut data = cat(vec![h32(32), h32(1), h32(2), h32(32), e32(0), e32(0), e32(50), e32(20)]);
    data.extend(cat(vec![e32(0), e32(0), e32(10), e32(20), e32(30), e32(0), e32(50), e32(20)]));
    let rgn = cat(vec![h32(data.len() as u32), h32(5), data.clone()]);
    let rgn_xor = cat(vec![h32(data.len() as u32), h32(3), data]);
    let rect = cat(vec![e32(0), e32(0), e32(50), e32(20)]);
    add(
        "emf-clips",
        emf(
            &[
                erec(75, &rgn),
                erec(43, &rect),
                erec(30, &cat(vec![e32(5), e32(2), e32(45), e32(18)])),
                erec(43, &rect),
                erec(29, &cat(vec![e32(20), e32(0), e32(25), e32(40)])),
                erec(43, &rect),
                erec(75, &rgn_xor),
                erec(43, &rect),
            ],
            [0, 0, 50, 20],
            [0, 0, 0, 0],
        ),
    );

    // EMF+.
    let pen = prec(0x4008, 0x0200 | 1, &solid_pen(0xFF20_60C0, 3.0));
    let diamond = f32s(&[100.0, 10.0, 190.0, 100.0, 100.0, 190.0, 10.0, 100.0]);
    let region = cat(vec![h32(0xDBC0_1002), h32(0), h32(0x1000_0000), f32s(&[220.0, 160.0, 180.0, 30.0])]);
    add(
        "plus-curves",
        plus_file(
            vec![
                prec(0x4009, 0, &h32(0xFFF4_EED8)),
                pen.clone(),
                prec(0x4016, 0x8000, &cat(vec![h32(0xFFE0_8020), f32s(&[0.5]), h32(4), diamond.clone()])),
                prec(0x4017, 1, &cat(vec![f32s(&[0.7]), h32(4), diamond])),
                prec(0x4018, 1, &cat(vec![f32s(&[0.5]), h32(0), h32(4), h32(5), f32s(&[210.0, 150.0, 260.0, 60.0, 310.0, 120.0, 360.0, 30.0, 410.0, 90.0])])),
                prec(0x4008, 0x0400 | 2, &region),
                prec(0x4013, 0x8000 | 2, &h32(0xFF30_A040)),
            ],
            [0, 0, 420, 200],
            [0, 0, 0, 0],
        ),
    );
    // Transforms, arcs and pies at assorted angles.
    let mut tr = vec![
        prec(0x4008, 0x0200 | 1, &solid_pen(0xFF00_0000, 1.5)),
        prec(0x402F, 0, &f32s(&[30.0])),
        prec(0x402D, 0x2000, &f32s(&[12.0, -4.0])),
        prec(0x402E, 0, &f32s(&[1.25, 0.8])),
        prec(0x400F, 1, &f32s(&[10.0, 10.0, 60.0, 30.0])),
        prec(0x400E, 0x8000, &cat(vec![h32(0x8040_2010), f32s(&[5.0, 7.0, 33.0, 21.0])])),
    ];
    for (i, (start, sweep)) in [(0.0f32, 90.0f32), (45.0, 200.0), (-30.0, -120.0), (170.0, 360.0), (12.5, -400.0), (300.0, 59.0)].iter().enumerate() {
        let r = f32s(&[10.0 + i as f32 * 3.0, 20.0, 80.0 + i as f32, 50.0 - i as f32]);
        tr.push(prec(0x4010, 0x8000, &cat(vec![h32(0xFF10_2030 + i as u32), f32s(&[*start, *sweep]), r.clone()])));
        tr.push(prec(if i % 2 == 0 { 0x4011 } else { 0x4012 }, 1, &cat(vec![f32s(&[*start, *sweep]), r])));
    }
    tr.push(prec(0x402A, 0, &f32s(&[0.9, 0.1, -0.2, 1.1, 5.0, 6.0])));
    tr.push(prec(0x4030, 6, &f32s(&[0.5])));
    tr.push(prec(0x400B, 1, &cat(vec![h32(2), f32s(&[1.0, 2.0, 30.0, 40.0, 50.0, 60.0, 7.0, 8.0])])));
    tr.push(prec(0x4019, 1, &cat(vec![h32(4), f32s(&[0.0, 0.0, 10.0, 30.0, 40.0, -10.0, 50.0, 20.0])])));
    add("plus-transforms", plus_file(tr, [0, 0, 300, 200], [0, 0, 7500, 5000]));
    // Brushes: linear (blend factors, presets), path gradient, texture, hatch.
    let lin_blend = cat(vec![
        h32(0xDBC0_1002), h32(4), h32(0x8 | 0x2), h32(1), f32s(&[10.0, 0.0, 80.0, 10.0]), h32(0xFFFF_0000), h32(0xFF00_00FF), h32(0), h32(0),
        f32s(&[1.0, 0.2, 0.0, 1.0, 5.0, 0.0]), h32(3), f32s(&[0.0, 0.4, 1.0]), f32s(&[0.0, 0.8, 1.0]),
    ]);
    let lin_preset = cat(vec![
        h32(0xDBC0_1002), h32(4), h32(0x4), h32(3), f32s(&[0.0, 0.0, 50.0, 10.0]), h32(0xFFFF_0000), h32(0xFF00_00FF), h32(0), h32(0),
        h32(3), f32s(&[1.0, 0.0, 0.5]), h32(0xFF00_FF00), h32(0x8000_0000), h32(0xFFFF_FFFF),
    ]);
    let path_grad = cat(vec![
        h32(0xDBC0_1002), h32(3), h32(0x2), h32(0), h32(0xFFFF_FF00), f32s(&[50.0, 40.0]), h32(1), h32(0xFF00_00FF),
        h32(4), f32s(&[10.0, 10.0, 90.0, 10.0, 90.0, 70.0, 10.0, 70.0]), f32s(&[1.0, 0.0, 0.0, 1.0, 3.0, 2.0]),
    ]);
    let texture = cat(vec![h32(0xDBC0_1002), h32(2), h32(0x2), h32(1), f32s(&[2.0, 0.0, 0.0, 3.0, 1.0, 1.0]), bitmap_2x2()]);
    let texture_clamp = cat(vec![h32(0xDBC0_1002), h32(2), h32(0), h32(4), bitmap_2x2()]);
    let hatch = cat(vec![h32(0xDBC0_1002), h32(1), h32(11), h32(0xFF00_0000), h32(0xFFFF_FFFF)]);
    let hatch4 = cat(vec![h32(0xDBC0_1002), h32(1), h32(4), h32(0xFF00_0000), h32(0x80FF_FFFF)]);
    let mut br = Vec::new();
    for (i, b) in [lin_blend, lin_preset, path_grad, texture, texture_clamp, hatch, hatch4].into_iter().enumerate() {
        br.push(prec(0x4008, 0x0100 | i as u16, &b));
        let x = (i % 4) as f32 * 60.0;
        let y = (i / 4) as f32 * 60.0;
        br.push(prec(0x400A, i as u16, &cat(vec![h32(i as u32), h32(1), f32s(&[x, y, 55.0, 50.0])])));
    }
    br.push(prec(0x402F, 0, &f32s(&[15.0])));
    br.push(prec(0x400C, 0, &cat(vec![h32(2), h32(3), f32s(&[10.0, 130.0, 90.0, 140.0, 40.0, 190.0])])));
    add("plus-brushes", plus_file(br, [0, 0, 240, 200], [0, 0, 0, 0]));
    // Clips: rectangle, convex path, region combine, offset; images under a clip.
    let diamond_path = cat(vec![h32(0xDBC0_1002), h32(4), h32(0), f32s(&[0.0, 50.0, 50.0, 0.0, 100.0, 50.0, 50.0, 100.0]), vec![0, 1, 1, 0x81]]);
    let rrect = |r: [f32; 4]| cat(vec![h32(0x1000_0000), f32s(&r)]);
    let region2 = cat(vec![h32(0xDBC0_1002), h32(2), h32(2), rrect([0.0, 0.0, 30.0, 30.0]), rrect([10.0, 10.0, 90.0, 90.0])]);
    add(
        "plus-clips",
        plus_file(
            vec![
                prec(0x4008, 0x0300 | 9, &diamond_path),
                prec(0x4033, 9, &[]),
                fill_argb(0xFF00_0000, [0.0, 0.0, 100.0, 100.0]),
                prec(0x4008, 0x0200 | 1, &solid_pen(0xFF00_FF00, 1.0)),
                prec(0x400D, 0x2001, &cat(vec![h32(3), f32s(&[0.0, 10.0, 100.0, 30.0, 20.0, 95.0])])),
                prec(0x4008, 0x0500 | 2, &bitmap_2x2()),
                draw_image(2, [40.0, 0.0, 20.0, 20.0]),
                prec(0x4035, 0, &f32s(&[7.0, 3.0])),
                fill_argb(0xFF11_2233, [30.0, 30.0, 40.0, 40.0]),
                prec(0x4032, 0x0100, &f32s(&[20.0, 20.0, 60.0, 15.0])),
                fill_argb(0xFF44_5566, [0.0, 0.0, 100.0, 100.0]),
                prec(0x4008, 0x0400 | 6, &region2),
                prec(0x4034, 6, &[]),
                fill_argb(0xFF77_8899, [0.0, 0.0, 100.0, 100.0]),
                prec(0x4031, 0, &[]),
                draw_image(2, [0.0, 100.0, -20.0, 30.0]),
            ],
            [0, 0, 100, 130],
            [0, 0, 0, 0],
        ),
    );
    // Strings: DrawString with formats and wrapping, DrawDriverString with positions and a matrix.
    let text = "alpha beta gamma delta epsilon\nzeta";
    add(
        "plus-strings",
        plus_file(
            vec![
                fill_argb(0xFFFF_FFFF, [0.0, 0.0, 200.0, 120.0]),
                prec(0x4008, 0x0600 | 3, &font_obj("Calibri", 12.0, 2, 3)),
                prec(0x4008, 0x0700 | 4, &cat(vec![h32(0xDBC0_1002), h32(0), h32(0), h32(1), h32(1)])),
                prec(0x401C, 0x8000 | 3, &cat(vec![h32(0xFF11_2233), h32(4), h32(text.encode_utf16().count() as u32), f32s(&[5.0, 5.0, 90.0, 60.0]), u16s(text)])),
                prec(0x4008, 0x0700 | 5, &cat(vec![h32(0xDBC0_1002), h32(0x5000), h32(0), h32(2), h32(2)])),
                prec(0x401C, 0x8000 | 3, &cat(vec![h32(0xFF33_2211), h32(5), h32(2), f32s(&[100.0, 0.0, 90.0, 60.0]), u16s("Hi")])),
                prec(0x4008, 0x0600, &font_obj("Arial", 10.0, 0, 0)),
                prec(0x4036, 0x8000, &cat(vec![h32(0xFF00_0000), h32(1), h32(1), h32(3), u16s("Abc"), f32s(&[5.0, 90.0, 11.0, 91.0, 18.5, 92.0]), f32s(&[1.0, 0.1, -0.1, 1.0, 2.0, 3.0])])),
                prec(0x4036, 0x8000, &cat(vec![h32(0xFF00_0000), h32(0), h32(0), h32(2), h16(36), h16(69), f32s(&[50.0, 100.0, 56.0, 100.0])])),
            ],
            [0, 0, 200, 120],
            [0, 0, 0, 0],
        ),
    );
    // Images: raw formats, a nested metafile, DrawImagePoints, Clear.
    let inner = emf(&[erec(43, &cat(vec![e32(0), e32(0), e32(10), e32(10)])), erec(42, &cat(vec![e32(2), e32(3), e32(9), e32(7)]))], [0; 4], [0; 4]);
    let nested = cat(vec![h32(0xDBC0_1002), h32(2), h32(3), h32(inner.len() as u32), inner]);
    let rgb24 = bitmap_obj(2, 2, 8, 0x0002_1808, &[], &[1, 2, 3, 4, 5, 6, 0, 0, 7, 8, 9, 10, 11, 12, 0, 0]);
    let rgb565 = bitmap_obj(2, 1, 4, 0x0002_1006, &[], &[0x1F, 0xF8, 0xE0, 0x07]);
    let rgb555 = bitmap_obj(2, 1, -4, 0x0002_1005, &[], &[0x1F, 0x7C, 0xE0, 0x03]);
    let pargb = bitmap_obj(2, 1, 8, 0x000E_200B, &[], &[0, 0, 128, 128, 10, 20, 64, 128]);
    let idx1 = bitmap_obj(9, 2, 4, 0x0003_0101, &[0xFF00_0000, 0xFFFF_FFFF], &[0xA5, 0x80, 0, 0, 0x5A, 0x00, 0, 0]);
    let idx8 = bitmap_obj(2, 2, 4, 0x0003_0803, &[0xFF11_2233, 0xFF44_5566, 0xFF77_8899], &[0, 1, 0, 0, 2, 9, 0, 0]);
    let mut im = vec![prec(0x4009, 0, &h32(0xFFF0_F0F0))];
    for (i, o) in [nested, rgb24, rgb565, rgb555, pargb, idx1, idx8].into_iter().enumerate() {
        im.push(prec(0x4008, 0x0500 | i as u16, &o));
        let x = i as f32 * 30.0;
        im.push(prec(0x401A, i as u16, &cat(vec![h32(0), h32(2), f32s(&[0.0, 0.0, 2.0, 2.0]), f32s(&[x, 0.0, 25.0, 20.0])])));
    }
    im.push(prec(0x401B, 1, &cat(vec![h32(0), h32(2), f32s(&[0.0, 0.0, 2.0, 2.0]), h32(3), f32s(&[10.0, 40.0, 50.0, 45.0, 5.0, 70.0])])));
    im.push(prec(0x401B, 0, &cat(vec![h32(0), h32(2), f32s(&[0.0, 0.0, 2.0, 2.0]), h32(3), f32s(&[100.0, 40.0, 150.0, 40.0, 100.0, 80.0])])));
    add("plus-images", plus_file(im, [0, 0, 210, 80], [0, 0, 5250, 2000]));
    // Many escapements and rotations: text transforms keep f64, so the sine and cosine of each angle show
    // to the last bit (deckcraft's release build computes them in one `__sincos_stret` call).
    let mut esc = vec![wrec(0x020C, &cat(vec![h16(1000), h16(1000)]))];
    for k in 0..700 {
        let e = (k * 37) % 3600 - 1800;
        esc.push(wfont(-12, 400, [0, 0, 0], 0, e, b"Arial"));
        esc.push(wrec(0x012D, &h16(0)));
        esc.push(wrec(0x012E, &h16(if k % 3 == 0 { 1 } else { 24 })));
        esc.push(wtext(k % 997, (k * 7) % 991, b"ab", 0, None, &[k % 11 + 1, 3]));
        esc.push(wrec(0x01F0, &h16(0)));
    }
    add("wmf-escapements", wmf(&esc, None));
    let mut rs = vec![prec(0x4008, 0x0600, &font_obj("Arial", 10.0, 0, 0))];
    for k in 0..400 {
        rs.push(prec(0x402B, 0, &[]));
        rs.push(prec(0x402F, if k % 2 == 0 { 0 } else { 0x2000 }, &f32s(&[k as f32 * 0.913 - 180.0])));
        rs.push(prec(0x402D, 0x2000, &f32s(&[(k % 20) as f32 * 9.0, (k / 20) as f32 * 9.0])));
        rs.push(prec(0x4036, 0x8000, &cat(vec![h32(0xFF00_0000), h32(1), h32(0), h32(1), u16s("x"), f32s(&[1.0, 2.0])])));
        rs.push(prec(0x4010, 0x8000, &cat(vec![h32(0xFF10_2030), f32s(&[k as f32 * 1.37, 11.0 + k as f32 * 0.71]), f32s(&[0.0, 0.0, 7.0, 5.0])])));
    }
    add("plus-rotated-strings", plus_file(rs, [0, 0, 200, 200], [0, 0, 0, 0]));
    add("plus-dual", {
        let fill = prec(0x400A, 0x8000, &cat(vec![h32(0xFFFF_0000), h32(1), f32s(&[0.0, 0.0, 5.0, 5.0])]));
        let gdi = erec(43, &cat(vec![e32(0), e32(0), e32(9), e32(9)]));
        emf(&[plus_comment(&[plus_header(true), fill]), gdi], [0; 4], [0; 4])
    });
    c
}

// ---- The dump ----

fn h64(v: f64) -> String {
    format!("{:016x}", v.to_bits())
}
fn h32f(v: f32) -> String {
    format!("{:08x}", v.to_bits())
}
fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
fn rgba(c: [u8; 4]) -> String {
    hex(&c)
}
fn fnv(b: &[u8]) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for x in b {
        h ^= u64::from(*x);
        h = h.wrapping_mul(0x0000_0100_0000_01B3);
    }
    format!("{h:016x}")
}

fn segs(out: &mut String, s: &[Seg]) {
    for g in s {
        let _ = match *g {
            Seg::Move(x, y) => writeln!(out, " M {} {}", h32f(x), h32f(y)),
            Seg::Line(x, y) => writeln!(out, " L {} {}", h32f(x), h32f(y)),
            Seg::Cubic(a, b, c, d, e, f) => writeln!(out, " C {} {} {} {} {} {}", h32f(a), h32f(b), h32f(c), h32f(d), h32f(e), h32f(f)),
            Seg::Close => writeln!(out, " Z"),
        };
    }
}

fn region(r: &Option<Vec<[f32; 4]>>) -> String {
    match r {
        None => "-".to_string(),
        Some(v) => {
            let mut s = format!("{}", v.len());
            for q in v {
                for x in q {
                    s += " ";
                    s += &h32f(*x);
                }
            }
            s
        }
    }
}

fn text(out: &mut String, t: &Text) {
    let tr: Vec<String> = t.transform.iter().map(|v| h64(*v)).collect();
    let dx: Vec<String> = t.dx.iter().map(|v| h32f(*v)).collect();
    let h = match t.h_align {
        HAlign::Left => "l",
        HAlign::Center => "c",
        HAlign::Right => "r",
    };
    let v = match t.v_align {
        VAlign::Top => "t",
        VAlign::Baseline => "b",
        VAlign::Bottom => "m",
    };
    let f = &t.font;
    let _ = writeln!(
        out,
        "text {} [{}] dx [{}] font {} {} {} {} {}{}{} {} color {} bg {} align {}{} clip {} region {}",
        hex(t.text.as_bytes()),
        tr.join(" "),
        dx.join(" "),
        hex(f.family.as_bytes()),
        h32f(f.height),
        h32f(f.width),
        f.weight,
        f.italic as u8,
        f.underline as u8,
        f.strike as u8,
        f.charset,
        rgba(t.color),
        t.background.map_or("-".to_string(), rgba),
        h,
        v,
        t.clip.map_or("-".to_string(), |c| c.iter().map(|x| h32f(*x)).collect::<Vec<_>>().join(" ")),
        region(&t.region),
    );
}

fn affine(a: Affine) -> String {
    a.as_coeffs().iter().map(|v| h64(*v)).collect::<Vec<_>>().join(" ")
}
fn rect(r: Rect) -> String {
    format!("{} {} {} {}", h64(r.x0), h64(r.y0), h64(r.x1), h64(r.y1))
}
fn path(out: &mut String, p: &BezPath) {
    for e in p.elements() {
        let _ = match e {
            PathEl::MoveTo(a) => writeln!(out, " M {} {}", h64(a.x), h64(a.y)),
            PathEl::LineTo(a) => writeln!(out, " L {} {}", h64(a.x), h64(a.y)),
            PathEl::QuadTo(a, b) => writeln!(out, " Q {} {} {} {}", h64(a.x), h64(a.y), h64(b.x), h64(b.y)),
            PathEl::CurveTo(a, b, c) => writeln!(out, " C {} {} {} {} {} {}", h64(a.x), h64(a.y), h64(b.x), h64(b.y), h64(c.x), h64(c.y)),
            PathEl::ClosePath => writeln!(out, " Z"),
        };
    }
}
fn placed_region(out: &mut String, r: &Option<std::sync::Arc<BezPath>>) {
    match r {
        None => {
            let _ = writeln!(out, " region -");
        }
        Some(p) => {
            let _ = writeln!(out, " region {}", p.elements().len());
            path(out, p);
        }
    }
}

fn dump(bytes: &[u8]) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "is {}", is_metafile(bytes) as u8);
    let mut pic = match parse(bytes) {
        Ok(p) => p,
        Err(e) => {
            let _ = writeln!(out, "err {e:?}");
            return out;
        }
    };
    let _ = writeln!(out, "pic {} {} {}", h32f(pic.width), h32f(pic.height), pic.items.len());
    let mut tiles: HashMap<*const deckcraft_metafile::Tile, usize> = HashMap::new();
    for it in &pic.items {
        match it {
            Item::Path { segs: s, fill, stroke, even_odd, region: r } => {
                let _ = writeln!(
                    out,
                    "path {} fill {} stroke {} eo {} region {}",
                    s.len(),
                    fill.map_or("-".to_string(), rgba),
                    stroke.map_or("-".to_string(), |(c, w)| format!("{} {}", rgba(c), h32f(w))),
                    *even_odd as u8,
                    region(r)
                );
                segs(&mut out, s);
            }
            Item::Bitmap { rect, width, height, rgba: px, region: r } => {
                let rr: Vec<String> = rect.iter().map(|v| h32f(*v)).collect();
                let _ = writeln!(out, "bitmap [{}] {} {} {} {} region {}", rr.join(" "), width, height, px.len(), fnv(px), region(r));
            }
            Item::Pattern { segs: s, even_odd, tile, region: r } => {
                let n = tiles.len();
                let id = *tiles.entry(std::sync::Arc::as_ptr(tile)).or_insert(n);
                let _ = writeln!(
                    out,
                    "pattern {} eo {} tile {} {} {} {} cell {} {} origin {} {} region {}",
                    s.len(),
                    *even_odd as u8,
                    id,
                    tile.width,
                    tile.height,
                    fnv(&tile.rgba),
                    h32f(tile.cell[0]),
                    h32f(tile.cell[1]),
                    h32f(tile.origin[0]),
                    h32f(tile.origin[1]),
                    region(r)
                );
                segs(&mut out, s);
            }
            Item::Text(t) => text(&mut out, t),
        }
    }
    // Placed on a target with a crop, as a renderer places it.
    let placed = pic.place(Rect::new(10.0, 20.0, 410.0, 320.0), [0.05, 0.1, 0.0, 0.2]);
    let _ = writeln!(out, "placed {}", placed.len());
    for p in &placed {
        match p {
            PlacedItem::Path { path: bp, fill, stroke, even_odd, region: r } => {
                let _ = writeln!(
                    out,
                    "ppath fill {} stroke {} eo {}",
                    fill.map_or("-".to_string(), rgba),
                    stroke.map_or("-".to_string(), |(c, w)| format!("{} {}", rgba(c), h64(w))),
                    *even_odd as u8
                );
                path(&mut out, bp);
                placed_region(&mut out, r);
            }
            PlacedItem::Bitmap { index, rect: rr, region: r } => {
                let _ = writeln!(out, "pbitmap {} {}", index, rect(*rr));
                placed_region(&mut out, r);
            }
            PlacedItem::Pattern { index, path: bp, even_odd, tile, region: r } => {
                let _ = writeln!(out, "ppattern {} eo {} tile {}", index, *even_odd as u8, affine(*tile));
                path(&mut out, bp);
                placed_region(&mut out, r);
            }
            PlacedItem::Text { index, transform, clip, region: r } => {
                let _ = writeln!(out, "ptext {} {} clip {}", index, affine(*transform), clip.map_or("-".to_string(), rect));
                placed_region(&mut out, r);
            }
        }
    }
    let px: Vec<String> = pic.items.iter_mut().map(|it| it.take_pixels().map_or("-".to_string(), |(w, h, p)| format!("{w}x{h}:{}", fnv(&p)))).collect();
    let _ = writeln!(out, "take {}", px.join(" "));
    out
}

/// Fixed-seed LCG (Knuth's constants), as the crate's own fuzz tests use.
struct Lcg(u64);
impl Lcg {
    fn rnd(&mut self) -> u32 {
        self.0 = self.0.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        (self.0 >> 33) as u32
    }
}

fn main() {
    let Some(out_dir) = std::env::args().nth(1) else {
        eprintln!("usage: metafile-vectors OUT_DIR");
        std::process::exit(2);
    };
    let dir = std::path::Path::new(&out_dir);
    if let Err(e) = std::fs::create_dir_all(dir) {
        eprintln!("cannot create {out_dir}: {e}");
        std::process::exit(1);
    }
    let mut all = Vec::new();
    let mut rng = Lcg(0x5DEE_CE66_D1CE_4E5B);
    for (name, bytes) in cases() {
        // Mutations: a few bytes changed, a tail of 0xFF, a truncation.
        let mut variants = vec![(name.clone(), bytes.clone())];
        // Fewer for the long files, whose dumps are large.
        let n = if bytes.len() > 20_000 { 2 } else { 12 };
        for k in 0..n {
            let mut b = bytes.clone();
            for _ in 0..(1 + k % 4) {
                let at = rng.rnd() as usize % b.len();
                b[at] = rng.rnd() as u8;
            }
            variants.push((format!("{name}~m{k}"), b));
        }
        let at = 88 + rng.rnd() as usize % (bytes.len().saturating_sub(88).max(1));
        let mut ff = bytes.clone();
        ff[at.min(bytes.len() - 1)..].iter_mut().for_each(|b| *b = 0xFF);
        variants.push((format!("{name}~ff"), ff));
        variants.push((format!("{name}~cut"), bytes[..bytes.len() * 2 / 3].to_vec()));
        all.extend(variants);
    }
    let mut dumps = String::new();
    for (name, bytes) in &all {
        if let Err(e) = std::fs::write(dir.join(format!("{name}.bin")), bytes) {
            eprintln!("cannot write {name}: {e}");
            std::process::exit(1);
        }
        let _ = writeln!(dumps, "== {name}");
        dumps += &dump(bytes);
    }
    if let Err(e) = std::fs::write(dir.join("dumps.txt"), dumps) {
        eprintln!("cannot write dumps.txt: {e}");
        std::process::exit(1);
    }
    println!("{} cases", all.len());
}
