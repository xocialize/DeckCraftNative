//! geom-vectors OUT_DIR — writes deckcraft-geom's results as text, every float as its f64 bit pattern
//! in hex, into OUT_DIR:
//!
//! - `presets.txt`: full dumps of every catalog preset at its default adjusts on 100×100 and 216×108;
//! - `preset-hashes.txt`: one FNV-1a 64 hash per (preset, size, adjust set) of the same dump format,
//!   for every combination; `geom-vectors --dump NAME W H SET` prints one full dump to debug a mismatch;
//! - `warps.txt`, `morphs.txt`, `misc.txt`: warp guides, handles and mappings; morph frames; squircle
//!   paths, units and transforms.
//!
//! The Swift tests rebuild every line with the same formatting and compare.
use deckcraft_geom::morph::{GeometryMorph, align, contours};
use deckcraft_geom::preset::{CATALOG, Geometry, build};
use deckcraft_geom::warp::{self, Band, WarpLine};
use deckcraft_geom::{Rect, Unit, Xfrm, near_path, pt_to_emu, squircle};
use kurbo::{PathEl, Point, Shape, Vec2};
use std::fmt::Write as _;

fn h(v: f64) -> String {
    format!("{:016x}", v.to_bits())
}
fn p(q: Point) -> String {
    format!("{} {}", h(q.x), h(q.y))
}
fn r(q: Rect) -> String {
    format!("{} {} {} {}", h(q.x0), h(q.y0), h(q.x1), h(q.y1))
}

fn el(out: &mut String, e: &PathEl) {
    let _ = match e {
        PathEl::MoveTo(a) => writeln!(out, "M {}", p(*a)),
        PathEl::LineTo(a) => writeln!(out, "L {}", p(*a)),
        PathEl::QuadTo(a, b) => writeln!(out, "Q {} {}", p(*a), p(*b)),
        PathEl::CurveTo(a, b, c) => writeln!(out, "C {} {} {}", p(*a), p(*b), p(*c)),
        PathEl::ClosePath => writeln!(out, "Z"),
    };
}

fn fill_name(f: deckcraft_geom::preset::FillMode) -> &'static str {
    use deckcraft_geom::preset::FillMode::*;
    match f {
        Norm => "norm",
        None => "none",
        Lighten => "lighten",
        LightenLess => "lightenLess",
        Darken => "darken",
        DarkenLess => "darkenLess",
    }
}

/// The dump of one built geometry: sub-paths with their elements, the text rect, handles (with the
/// value each maps its own position back to), sites, and the outline's bounding box and area.
fn geometry(out: &mut String, g: &Geometry) {
    for s in &g.paths {
        let _ = writeln!(out, "path {} {} {}", fill_name(s.fill), s.stroke as u8, s.even_odd as u8);
        for e in s.path.elements() {
            el(out, e);
        }
    }
    let _ = writeln!(out, "text {}", r(g.text_rect));
    for hd in &g.handles {
        let _ = writeln!(
            out,
            "handle {} {} {} {} {} {} {} {}",
            hd.index,
            p(hd.pos),
            p(hd.origin),
            format!("{} {}", h(hd.dir.x), h(hd.dir.y)),
            h(hd.min),
            h(hd.max),
            hd.angle as u8,
            h(hd.value_at(hd.pos))
        );
    }
    for s in &g.sites {
        let _ = writeln!(out, "site {}", p(*s));
    }
    let o = g.outline();
    let _ = writeln!(out, "bbox {} area {}", r(o.bounding_box()), h(o.area()));
}

const SIZES: [(f64, f64); 5] = [(100.0, 100.0), (300.0, 80.0), (40.0, 200.0), (0.0, 0.0), (216.0, 108.0)];

fn adjust_sets() -> Vec<Vec<f64>> {
    vec![
        vec![],
        vec![0.0; 8],
        vec![100000.0; 8],
        vec![30000.0, 60000.0, 20000.0, 9000000.0, 20000.0, 40000.0, 120000.0, -30000.0],
        vec![1e12, -1e12, 1e12, -1e12, 1e12, -1e12, 1e12, -1e12],
        vec![f64::NAN, f64::INFINITY, f64::NEG_INFINITY, f64::NAN, 5.0, 6.0, 7.0, 8.0],
    ]
}

fn dump_case(name: &str, w: f64, hh: f64, adj: &[f64]) -> String {
    let mut s = String::new();
    match build(name, w, hh, adj) {
        Some(g) => geometry(&mut s, &g),
        None => s.push_str("none\n"),
    }
    s
}

fn fnv(s: &str) -> u64 {
    let mut x: u64 = 0xcbf29ce484222325;
    for b in s.bytes() {
        x ^= b as u64;
        x = x.wrapping_mul(0x100000001b3);
    }
    x
}

fn presets(dir: &std::path::Path) {
    let mut full = String::new();
    let mut hashes = String::new();
    for info in CATALOG {
        for (w, hh) in [(100.0, 100.0), (216.0, 108.0)] {
            let _ = writeln!(full, "case {} {} {}", info.name, h(w), h(hh));
            full.push_str(&dump_case(info.name, w, hh, &[]));
            // The flattened outline at the hit-test tolerance.
            if let Some(g) = build(info.name, w, hh, &[]) {
                let mut n = 0;
                deckcraft_geom::preset_flatten(&g.outline(), &mut |e| {
                    n += 1;
                    el(&mut full, &e);
                });
                let _ = writeln!(full, "flat {n}");
                let _ = writeln!(full, "near {} {}", near_path(&g.outline(), Point::new(w / 2.0, 0.0), 0.5) as u8, near_path(&g.outline(), Point::new(w / 2.0, hh / 2.0), 0.5) as u8);
            }
        }
        for (si, (w, hh)) in SIZES.iter().enumerate() {
            for (ai, adj) in adjust_sets().iter().enumerate() {
                let _ = writeln!(hashes, "{} {} {} {:016x}", info.name, si, ai, fnv(&dump_case(info.name, *w, *hh, adj)));
            }
        }
    }
    std::fs::write(dir.join("presets.txt"), full).unwrap();
    std::fs::write(dir.join("preset-hashes.txt"), hashes).unwrap();
}

fn guide_line(out: &mut String, tag: &str, g: &warp::Guide, full: bool) {
    let _ = writeln!(out, "{tag} len {} closed {}", h(g.length()), g.is_closed() as u8);
    let samples: Vec<f64> = if full { (0..=200).map(|i| i as f64 / 200.0).collect() } else { vec![0.0, 0.25, 0.5, 0.75, 1.0] };
    for t in samples {
        let (q, tan) = g.at(t * g.length());
        let _ = writeln!(out, "at {} {} {}", h(t), p(q), format!("{} {}", h(tan.x), h(tan.y)));
    }
    let o = g.offset(7.5);
    let _ = writeln!(out, "offset len {}", h(o.length()));
    let (q, _) = o.at(o.length() * 0.3);
    let _ = writeln!(out, "offset at {}", p(q));
}

fn warps(dir: &std::path::Path) {
    let mut out = String::new();
    let rects = [Rect::new(0.0, 0.0, 420.0, 200.0), Rect::new(110.0, 60.0, 10.0, 20.0)];
    let adjs: [&[f64]; 3] = [&[], &[f64::NAN, f64::INFINITY], &[21_599_999.0, 100_000.0]];
    let lines = [
        WarpLine { ink: Some(Rect::new(100.0, 50.0, 300.0, 90.0)), extent: (100.0, 300.0), ref_y: 88.0 },
        WarpLine { ink: Some(Rect::new(150.0, 95.0, 250.0, 130.0)), extent: (150.0, 250.0), ref_y: 128.0 },
        WarpLine { ink: None, extent: (5.0, 5.0), ref_y: 3.0 },
    ];
    for info in warp::CATALOG {
        for (ri, rect) in rects.iter().enumerate() {
            for (ai, adj) in adjs.iter().enumerate() {
                let _ = writeln!(out, "warp {} {} {}", info.id, ri, ai);
                let full = ri == 0 && ai == 0;
                let Some(w) = warp::warp(info.id, adj, *rect) else {
                    out.push_str("none\n");
                    continue;
                };
                for b in &w.bands {
                    match b {
                        Band::Fill { top, bottom } => {
                            guide_line(&mut out, "top", top, full);
                            guide_line(&mut out, "bottom", bottom, full);
                        }
                        Band::Follow { path, anchor } => {
                            let _ = writeln!(out, "follow {anchor:?}");
                            guide_line(&mut out, "path", path, full);
                        }
                    }
                }
                for hd in warp::handles(info.id, adj, *rect) {
                    let _ = writeln!(out, "handle {} {} {}", hd.index, p(hd.pos), h(hd.value_at(Point::new(rect.x0 + 37.0, rect.y1 - 11.0))));
                }
                let inner = rect.inset(-5.0);
                let m = w.mapper(&lines, inner);
                let _ = writeln!(out, "zoom {}", h(m.zoom()));
                for (i, q) in [(0, Point::new(100.0, 50.0)), (0, Point::new(300.0, 90.0)), (0, Point::new(200.0, 70.0)), (1, Point::new(150.0, 95.0)), (1, Point::new(250.0, 130.0)), (2, Point::new(5.0, 3.0)), (7, Point::new(1.0, 1.0))] {
                    let _ = writeln!(out, "map {} {}", i, p(m.map(i, q)));
                }
            }
        }
    }
    for (l, n, b) in [(0, 2, 2), (2, 3, 2), (4, 5, 3), (3, 4, 3), (0, 0, 3), (7, 9, 1)] {
        let _ = writeln!(out, "bandOfLine {l} {n} {b} {}", warp::band_of_line(l, n, b));
    }
    std::fs::write(dir.join("warps.txt"), out).unwrap();
}

fn morphs(dir: &std::path::Path) {
    let mut out = String::new();
    let pairs = [
        ("ellipse", 100.0, 100.0, "star5", 200.0, 100.0),
        ("triangle", 100.0, 100.0, "ellipse", 100.0, 100.0),
        ("rect", 100.0, 100.0, "cube", 100.0, 100.0),
        ("donut", 100.0, 100.0, "ellipse", 100.0, 100.0),
        ("cloud", 300.0, 200.0, "wave", 240.0, 120.0),
        ("rect", 10.0, 10.0, "line", 10.0, 0.0),
        ("gear9", 150.0, 150.0, "heart", 150.0, 150.0),
    ];
    for (a, aw, ah, b, bw, bh) in pairs {
        let (Some(ga), Some(gb)) = (build(a, aw, ah, &[]), build(b, bw, bh, &[])) else { continue };
        let m = GeometryMorph::new(&ga, &gb);
        for t in [0.0, 0.37, 1.0] {
            let (g, fades) = m.at(t, Vec2::new(1.0, 1.0), Vec2::new(0.5, 2.0));
            let _ = writeln!(out, "morph {a} {b} {}", h(t));
            for (s, f) in g.paths.iter().zip(&fades) {
                let _ = writeln!(out, "path {} {} {} fade {} {}", fill_name(s.fill), s.stroke as u8, s.even_odd as u8, h(f.fill), h(f.stroke));
                for e in s.path.elements() {
                    el(&mut out, e);
                }
            }
            let _ = writeln!(out, "text {}", r(g.text_rect));
        }
        // The raw alignment of the first sub-paths.
        let (ca, cb) = (contours(&ga.paths[0].path), contours(&gb.paths[0].path));
        let (x, y) = align(&ca, &cb, None, None);
        let _ = writeln!(out, "align {a} {b} {} {}", x.len(), y.len());
        for c in x.iter().chain(&y) {
            let _ = writeln!(out, "contour {} {}", c.closed as u8, c.pts.len());
            for q in &c.pts {
                let _ = writeln!(out, "pt {}", p(*q));
            }
        }
    }
    std::fs::write(dir.join("morphs.txt"), out).unwrap();
}

fn misc(dir: &std::path::Path) {
    let mut out = String::new();
    for (w, hh, rad, s) in [(100.0, 50.0, 0.0, 0.6), (200.0, 100.0, 20.0, 0.0), (200.0, 100.0, 20.0, 0.6), (120.0, 80.0, 16.0, 0.6), (40.0, 40.0, 50.0, 0.8), (10.0, 300.0, 4.0, 0.6), (f64::NAN, 10.0, f64::INFINITY, f64::NAN), (1e21, 3.0, 1.0, 0.5), (0.1234567, 0.2, 0.05, 1.0)] {
        let _ = writeln!(out, "squircle {}", squircle::path_d(w, hh, rad, s));
    }
    for t in ["2", "2\"", "2.54 cm", "36pt", "abc", "", "  5mm ", "-3.5in", "40px", "+1.25", "1e3", ".5", "1.2.3"] {
        let _ = writeln!(out, "parse {:?} {}", t, Unit::Inches.parse(t).map(h).unwrap_or_else(|| "none".into()));
    }
    for v in [150.0, 0.0, -1.005, 1e9, 2.675] {
        for u in [Unit::Inches, Unit::Centimeters, Unit::Points, Unit::Pixels] {
            let _ = writeln!(out, "format {} {:?} {}", h(v), u, u.format(v));
        }
    }
    for v in [0.0, 1.0, 12_699.0 / 12_700.0, -5.5, 1e300, f64::NAN, 0.5 / 12_700.0, 2.5 / 12_700.0] {
        let _ = writeln!(out, "emu {} {}", h(v), pt_to_emu(v));
    }
    for x in [
        Xfrm { x: 10.0, y: 20.0, w: 100.0, h: 50.0, rot: 90.0, ..Default::default() },
        Xfrm { x: -3.0, y: 7.0, w: 33.3, h: 12.1, rot: 33.0, flip_h: true, flip_v: false },
        Xfrm { x: 0.0, y: 0.0, w: 100.0, h: 50.0, rot: -725.0, flip_h: true, flip_v: true },
    ] {
        let a = x.affine();
        let _ = writeln!(out, "xfrm {} bounds {} rotnorm {} map {}", a.as_coeffs().map(h).join(" "), r(x.bounds()), h(x.rot_norm()), p(a * Point::new(3.0, 4.0)));
        let g = deckcraft_geom::group_child_affine(&x, Rect::new(5.0, 5.0, 55.0, 30.0));
        let _ = writeln!(out, "group {}", g.as_coeffs().map(h).join(" "));
    }
    std::fs::write(dir.join("misc.txt"), out).unwrap();
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--dump") {
        let name = &args[2];
        let w: f64 = args[3].parse().unwrap();
        let hh: f64 = args[4].parse().unwrap();
        let set: usize = args[5].parse().unwrap();
        print!("{}", dump_case(name, w, hh, &adjust_sets()[set]));
        return;
    }
    let dir = std::path::PathBuf::from(args.get(1).cloned().unwrap_or_else(|| ".".into()));
    std::fs::create_dir_all(&dir).unwrap();
    presets(&dir);
    warps(&dir);
    morphs(&dir);
    misc(&dir);
    println!("wrote {}", dir.display());
}
