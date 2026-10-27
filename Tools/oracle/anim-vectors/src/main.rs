//! anim-vectors DECKS OUT: runs deckcraft-anim and deckcraft-render's transition compositor, from the
//! pinned checkout, over the oracle corpus decks (DECKS) and generated cases, and writes what they return to
//! OUT (`DeckCraftNative-Fixtures/anim/`). DCAnimTests' `AnimVectorTests` and DCRenderTests'
//! `CompositeVectorTests` replay every line and compare bit for bit.
//!
//! - `easing.txt`: `ease(p, a, d, b)`.
//! - `paths.txt`: `default_path` for every motion-path preset, and `MotionPath::parse` of those and of
//!   generated strings (points, length, positions).
//! - `transitions.txt`: `transition_frame` of every transition and option at a grid of times and aspects,
//!   hashed, with `layer_mesh` of every layer; `uses_slide_parts`.
//! - `composite.txt`: `composite_transition` of generated images, hashed.
//! - `timelines.txt` (+ `timelines-cases.jsonl`): `Timeline` of every corpus slide and of generated slides:
//!   steps, effect timings, paragraph targets, play-all clock, media cues, and states at a grid of times,
//!   with triggered sequences and stamps.
//! - `show.txt` (+ `show-cases.jsonl`): `ShowState` driven through generated sequences of navigation,
//!   links, ticks and clicks over the corpus decks and generated decks: each call, its answer and the state.
//! - `morph.txt` (+ `morph-cases.jsonl`): `morph_frame` and `morph_pairs` of consecutive corpus slides and of
//!   generated slide pairs; `xfrm.txt`: `morph_xfrm` and `morph_crop`.
//!
//! Floats are written as the hex of their bits, strings as the hex of their UTF-8 (`-` when empty). Hashes
//! are FNV-1a 64 over the little-endian bits. Inputs come from a fixed xorshift seed, so reruns are equal.
#![allow(clippy::all)]

use std::fmt::Write as _;
use std::sync::Arc;

use deckcraft_anim::{
    Click, HitShape, Layer, LinkJump, MotionPath, ShowAction, ShowState, Source, StepStamp, Timeline, TriggerPlay, default_path, ease,
    layer_mesh, morph_crop, morph_frame, morph_pairs, morph_xfrm, transition_frame, uses_slide_parts,
};
use deckcraft_model::anim::{ANIMATIONS, AnimClass, AnimStart, TRANSITIONS, TextBuild};
use deckcraft_model::text::{Action, Hyperlink, TextBody};
use deckcraft_model::{
    Animation, ColorRef, CustomShow, Fill, Geom, Presentation, Rgba, Shape, ShapeId, ShapeKind, Slide, SlideId, Transition, Xfrm,
};
use deckcraft_render::{Image, SlideParts, composite_transition};

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
    fn chance(&mut self, pct: u64) -> bool {
        self.next() % 100 < pct
    }
    fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }
    fn range(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * self.unit()
    }
    fn pick<'a, T>(&mut self, v: &'a [T]) -> &'a T {
        &v[self.below(v.len())]
    }
}

struct Fnv(u64);
impl Fnv {
    fn new() -> Fnv {
        Fnv(0xcbf2_9ce4_8422_2325)
    }
    fn bytes(&mut self, b: &[u8]) {
        for x in b {
            self.0 ^= *x as u64;
            self.0 = self.0.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }
    fn f(&mut self, v: f64) {
        self.bytes(&v.to_bits().to_le_bytes());
    }
    fn u(&mut self, v: u64) {
        self.bytes(&v.to_le_bytes());
    }
    fn s(&mut self, s: &str) {
        self.u(s.len() as u64);
        self.bytes(s.as_bytes());
    }
    fn hex(&self) -> String {
        format!("{:016x}", self.0)
    }
}

fn fb(v: f64) -> String {
    format!("{:016x}", v.to_bits())
}

fn hs(s: &str) -> String {
    if s.is_empty() {
        return "-".into();
    }
    let mut o = String::with_capacity(s.len() * 2);
    for b in s.bytes() {
        let _ = write!(o, "{b:02x}");
    }
    o
}

fn json<T: serde::Serialize>(v: &T) -> String {
    serde_json::to_string(v).unwrap_or_default()
}

fn source_index(s: Source) -> u64 {
    match s {
        Source::Old => 0,
        Source::New => 1,
        Source::Black => 2,
        Source::White => 3,
        Source::OldBack => 4,
        Source::NewBack => 5,
        Source::OldContent => 6,
        Source::NewContent => 7,
    }
}

fn hash_layer(h: &mut Fnv, l: &Layer) {
    h.u(source_index(l.source));
    for v in l.src {
        h.f(v);
    }
    for p in l.quad.iter().chain(l.uv.iter()) {
        h.f(p[0]);
        h.f(p[1]);
    }
    h.f(l.alpha);
    for v in l.fade {
        h.f(v);
    }
}

fn hash_mesh(h: &mut Fnv, l: &Layer) {
    let (v, t) = layer_mesh(l);
    h.u(v.len() as u64);
    for x in &v {
        h.f(x.pos[0]);
        h.f(x.pos[1]);
        h.f(x.uv[0]);
        h.f(x.uv[1]);
        h.f(x.a);
    }
    h.u(t.len() as u64);
    for tri in &t {
        h.u(tri[0] as u64);
        h.u(tri[1] as u64);
        h.u(tri[2] as u64);
    }
}

// ---------- easing ----------

fn easing(out: &mut String) {
    let ps = [f64::NAN, -1.0, 0.0, 1e-9, 0.01, 0.1, 0.2, 0.25, 0.3, 0.33, 0.5, 0.6, 0.67, 0.75, 0.8, 0.9, 0.99, 0.999_999, 1.0, 2.0];
    let ks = [f64::NAN, -0.5, 0.0, 0.1, 0.3, 0.5, 0.7, 0.9, 1.0, 1.5];
    let bs = [f64::NAN, 0.0, 0.1, 0.3, 0.5, 1.0, f64::INFINITY];
    for p in ps {
        for a in ks {
            for d in ks {
                for b in bs {
                    let _ = writeln!(out, "{}\t{}\t{}\t{}\t{}", fb(p), fb(a), fb(d), fb(b), fb(ease(p, a, d, b)));
                }
            }
        }
    }
}

// ---------- paths ----------

const PATH_GRID: [f64; 12] = [f64::NAN, -0.5, 0.0, 0.01, 0.1, 0.25, 0.5, 0.6, 0.75, 0.9, 1.0, 1.5];

fn path_line(out: &mut String, s: &str) {
    let p = MotionPath::parse(s);
    let mut h = Fnv::new();
    for q in &p.points {
        h.f(q.0);
        h.f(q.1);
    }
    let at: Vec<String> = PATH_GRID
        .iter()
        .map(|t| {
            let (x, y) = p.at(*t);
            format!("{},{}", fb(x), fb(y))
        })
        .collect();
    let _ = writeln!(out, "P\t{}\t{}\t{}\t{}\t{}", hs(s), p.points.len(), fb(p.length()), h.hex(), at.join(";"));
}

fn fuzz_path(r: &mut Rng) -> String {
    let toks = [
        "M", "m", "L", "l", "C", "c", "Q", "q", "H", "h", "V", "v", "Z", "z", "E", "e", "X", " ", ",", " ", "  ", "-", "+", ".", "0", "1", "2", "5",
        "9", "0.5", "-0.25", "1e-1", "2E3", "1e400", "3e", "nan", "inf", "😀", "\u{a0}", "\u{2003}", "\t", "\n", "-.5", "+.5e+2",
    ];
    let n = 1 + r.below(40);
    let mut s = String::new();
    for _ in 0..n {
        s.push_str(r.pick(&toks));
        if r.chance(60) {
            s.push(' ');
        }
    }
    s
}

fn paths(out: &mut String) {
    let mut inputs: Vec<String> = Vec::new();
    for (id, _, class, _, _, opts) in ANIMATIONS {
        if *class != AnimClass::Path {
            continue;
        }
        let mut options: Vec<&str> = opts.to_vec();
        options.extend(["", "up", "left", "right", "bogus"]);
        for o in options {
            let d = default_path(id, o);
            let _ = writeln!(out, "D\t{}\t{}\t{}", hs(id), hs(o), hs(&d));
            inputs.push(d);
        }
    }
    for e in ["lines", "arcs", "turns", "shapes", "loops", "customPath", "nope"] {
        for o in ["", "up", "right", "left", "diamond", "hexagon", "triangle", "square", "octagon", "pentagon", "trapezoid", "parallelogram", "circle"] {
            let d = default_path(e, o);
            let _ = writeln!(out, "D\t{}\t{}\t{}", hs(e), hs(o), hs(&d));
            inputs.push(d);
        }
    }
    let mut r = Rng(0x5eed_0001);
    for _ in 0..3000 {
        inputs.push(fuzz_path(&mut r));
    }
    inputs.push("L 1 1 ".repeat(25_000));
    for s in &inputs {
        path_line(out, s);
    }
}

// ---------- transitions ----------

fn transitions(out: &mut String) {
    let ts = [f64::NAN, -1.0, 0.0, 0.01, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.99, 1.0, 2.0];
    let aspects = [16.0 / 9.0, 4.0 / 3.0];
    let extra = ["", "bogus", "hexhexL", "singleR", "lu", "l\u{301}", "horzIn\u{301}", "outBounce"];
    let mut kinds: Vec<(&str, Vec<&str>)> = TRANSITIONS.iter().map(|t| (t.0, t.4.to_vec())).collect();
    kinds.push(("no-such-kind", vec![]));
    for (kind, opts) in &kinds {
        let mut options: Vec<&str> = opts.clone();
        options.push("");
        for o in &options {
            for t in ts {
                for a in aspects {
                    frame_line(out, kind, o, t, a);
                }
            }
        }
        for o in extra {
            frame_line(out, kind, o, 0.5, 16.0 / 9.0);
            frame_line(out, kind, o, 0.37, 16.0 / 9.0);
        }
        for a in [f64::NAN, 0.0, 0.01, 0.5, 1.0, 2.35, 100.0, 1e9] {
            for o in &options {
                frame_line(out, kind, o, 0.45, a);
            }
        }
        for o in options.iter().chain(extra.iter()) {
            let _ = writeln!(out, "U\t{}\t{}\t{}", hs(kind), hs(o), uses_slide_parts(kind, o) as u8);
        }
    }
}

fn frame_line(out: &mut String, kind: &str, o: &str, t: f64, a: f64) {
    let ls = transition_frame(kind, o, t, a);
    let mut h1 = Fnv::new();
    let mut h2 = Fnv::new();
    for l in &ls {
        hash_layer(&mut h1, l);
        hash_mesh(&mut h2, l);
    }
    let _ = writeln!(out, "F\t{}\t{}\t{}\t{}\t{}\t{}\t{}", hs(kind), hs(o), fb(t), fb(a), ls.len(), h1.hex(), h2.hex());
}

// ---------- composite ----------

/// Generated test images: opaque patterns for slides and backgrounds, premultiplied see-through ones for
/// contents. The Swift side makes the same ones.
fn image(w: u32, h: u32, seed: u32, content: bool) -> Image {
    let mut px = Vec::with_capacity((w * h * 4) as usize);
    for y in 0..h {
        for x in 0..w {
            let v = x.wrapping_mul(7).wrapping_add(y.wrapping_mul(13)).wrapping_add(seed.wrapping_mul(31));
            let r = (v.wrapping_mul(5) % 256) as u8;
            let g = ((x * 255) / w.max(1)) as u8;
            let b = ((y * 255) / h.max(1)) as u8 ^ (seed as u8);
            if content {
                let a = if (x / 8 + y / 6 + seed) % 3 == 0 { 0u8 } else { ((x * 11 + y * 3 + seed) % 256) as u8 };
                let m = |c: u8| ((c as u32 * a as u32 + 127) / 255) as u8;
                px.extend([m(r), m(g), m(b), a]);
            } else {
                px.extend([r, g, b, 255]);
            }
        }
    }
    Image { width: w, height: h, pixels: px }
}

fn composite(out: &mut String) {
    let (w, h) = (64u32, 36u32);
    let old = image(w, h, 1, false);
    let new = image(w, h, 2, false);
    let parts = SlideParts { old_back: Some(image(w, h, 3, false)), old_content: Some(image(w, h, 4, true)), new_back: image(w, h, 5, false), new_content: image(w, h, 6, true) };
    let first = SlideParts { old_back: None, old_content: None, ..parts.clone() };
    for (kind, _, _, _, opts) in TRANSITIONS {
        let mut options: Vec<&str> = opts.to_vec();
        options.push("");
        for o in options {
            for t in [0.1, 0.35, 0.5, 0.65, 0.9] {
                let ls = transition_frame(kind, o, t, 16.0 / 9.0);
                for variant in 0..4u8 {
                    let img = match variant {
                        0 => composite_transition(Some(&old), &new, None, &ls),
                        1 => composite_transition(None, &new, None, &ls),
                        2 => composite_transition(Some(&old), &new, Some(&parts), &ls),
                        _ => composite_transition(None, &new, Some(&first), &ls),
                    };
                    let mut hh = Fnv::new();
                    hh.u(img.width as u64);
                    hh.u(img.height as u64);
                    hh.bytes(&img.pixels);
                    let _ = writeln!(out, "{}\t{}\t{}\t{}\t{}", hs(kind), hs(o), fb(t), variant, hh.hex());
                }
            }
        }
    }
}

// ---------- timelines ----------

fn states_grid() -> Vec<(usize, f64)> {
    let mut v = Vec::new();
    for step in [0usize, 1, 2, 3, 5, usize::MAX] {
        for t in [f64::NAN, -1.0, 0.0, 0.001, 0.1, 0.25, 0.5, 0.75, 0.999, 1.0, 1.25, 1.5, 2.0, 3.5, 7.0, 1e9] {
            v.push((step, t));
        }
    }
    v
}

fn hash_state(h: &mut Fnv, s: &deckcraft_anim::AnimState) {
    h.u(s.visible as u64);
    h.f(s.opacity);
    h.f(s.offset_x);
    h.f(s.offset_y);
    h.f(s.scale_x);
    h.f(s.scale_y);
    h.f(s.rotate);
    match s.clip {
        Some(c) => {
            h.u(1);
            for v in c {
                h.f(v);
            }
        }
        None => h.u(0),
    }
    match s.tint {
        Some(c) => {
            h.u(1);
            h.bytes(&[c.r, c.g, c.b, c.a]);
        }
        None => h.u(0),
    }
}

fn timeline_line(out: &mut String, id: &str, slide: &Slide, w: f64, hgt: f64) {
    let tl = Timeline::new(slide, w, hgt);
    let n = tl.steps();
    let mut h_steps = Fnv::new();
    h_steps.u(n as u64);
    for i in 0..=n + 1 {
        h_steps.u(tl.step_is_auto(i) as u64);
        h_steps.f(tl.step_duration(i));
    }
    h_steps.f(tl.total_duration());
    h_steps.u(tl.is_empty() as u64);
    for tr in tl.trigger_shapes() {
        h_steps.u(tr.0 as u64);
        let k = tl.trigger_steps(tr);
        h_steps.u(k as u64);
        for i in 0..=k {
            h_steps.f(tl.trigger_step_duration(tr, i));
        }
    }
    let mut h_eff = Fnv::new();
    for e in tl.effects() {
        h_eff.u(e.anim as u64);
        h_eff.u(e.shape.0 as u64);
        h_eff.u(e.paragraph.map_or(u64::MAX, |p| p as u64));
        h_eff.u(match e.sequence {
            deckcraft_anim::Sequence::Main => u64::MAX,
            deckcraft_anim::Sequence::Trigger(s) => s.0 as u64,
        });
        h_eff.u(e.step as u64);
        h_eff.f(e.start);
        h_eff.f(e.duration);
        h_eff.f(e.iterations);
        h_eff.u(e.until_next_click as u64);
        h_eff.u(e.auto_reverse as u64);
        h_eff.u(e.rewind as u64);
        h_eff.f(e.span);
        h_eff.u(e.class as u64);
    }
    let animated = tl.animated_shapes();
    let mut h_paras = Fnv::new();
    for s in &animated {
        h_paras.u(s.0 as u64);
        for p in tl.paragraph_targets(*s) {
            h_paras.u(p as u64);
        }
        h_paras.u(u64::MAX);
    }
    let mut h_start = Fnv::new();
    for a in 0..=slide.animations.len() {
        match tl.start_of(a) {
            Some(v) => h_start.f(v),
            None => h_start.u(u64::MAX),
        }
    }
    let mut h_locate = Fnv::new();
    for time in [f64::NAN, f64::NEG_INFINITY, -1.0, 0.0, 0.25, 0.5, 1.0, 1.5, 2.0, 2.75, 3.0, 4.5, 10.0, 1e12] {
        let (s, t) = tl.locate(time);
        h_locate.u(s as u64);
        h_locate.f(t);
    }
    let mut h_cues = Fnv::new();
    for step in 0..=n {
        for (from, to) in [(f64::NEG_INFINITY, 0.0), (0.0, 1.0), (-1.0, f64::INFINITY), (0.5, 2.0)] {
            for c in tl.media_cues(step, from, to) {
                h_cues.u(c.anim as u64);
                h_cues.u(c.shape.0 as u64);
                h_cues.f(c.start);
            }
            h_cues.u(u64::MAX);
        }
    }
    let grid = states_grid();
    let mut targets: Vec<(ShapeId, Option<usize>)> = Vec::new();
    for s in animated.iter().copied().chain([ShapeId(424_242)]) {
        targets.push((s, None));
        for p in tl.paragraph_targets(s) {
            targets.push((s, Some(p)));
        }
        targets.push((s, Some(97)));
    }
    let mut h_states = Fnv::new();
    for (s, p) in &targets {
        for (step, t) in &grid {
            hash_state(&mut h_states, &tl.state(*s, *p, *step, *t));
        }
        for time in [f64::NAN, -1.0, 0.0, 0.3, 0.9, 1.7, 2.5, 4.0, 1e9] {
            hash_state(&mut h_states, &tl.state_at(*s, *p, time));
        }
    }
    // Triggered sequences: every trigger at a few playheads, then with stamps in both orders.
    let trig = tl.trigger_shapes();
    let mut h_with = Fnv::new();
    let mut h_ord = Fnv::new();
    if !trig.is_empty() {
        let plays_at = |step: usize, t: f64| -> Vec<TriggerPlay> { trig.iter().map(|tr| TriggerPlay { trigger: *tr, step, t }).collect() };
        for (s, p) in &targets {
            for (step, t) in [(0usize, 0.0), (0, 0.5), (1, 0.0), (1, 0.4), (2, 1.0), (9, 0.0)] {
                let plays = plays_at(step, t);
                hash_state(&mut h_with, &tl.state_with(*s, *p, 1, 0.3, &plays));
                hash_state(&mut h_with, &tl.state_with(*s, *p, usize::MAX, 0.0, &plays));
                let fwd: Vec<StepStamp> =
                    trig.iter().enumerate().flat_map(|(i, tr)| (0..3).map(move |k| StepStamp { trigger: *tr, step: k, at: (i * 3 + k) as u64 })).collect();
                let rev: Vec<StepStamp> = fwd.iter().map(|x| StepStamp { at: 1000 - x.at, ..*x }).collect();
                let max: Vec<StepStamp> = fwd.iter().map(|x| StepStamp { at: u64::MAX, ..*x }).collect();
                for stamps in [&fwd, &rev, &max] {
                    hash_state(&mut h_ord, &tl.state_ordered(*s, *p, 1, 0.3, &plays, stamps));
                }
            }
        }
    }
    let _ = writeln!(
        out,
        "{id}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
        fb(w),
        fb(hgt),
        h_steps.hex(),
        h_eff.hex(),
        h_paras.hex(),
        h_start.hex(),
        h_locate.hex(),
        h_cues.hex(),
        h_states.hex(),
        h_with.hex(),
        h_ord.hex()
    );
}

fn text_body(r: &mut Rng) -> TextBody {
    let words = ["alpha", "beta", "gamma", "", "  ", "delta epsilon", "ζήτα", "η"];
    let n = 1 + r.below(6);
    let lines: Vec<&str> = (0..n).map(|_| *r.pick(&words)).collect();
    let mut t = TextBody::from_text(&lines.join("\n"));
    for p in &mut t.paragraphs {
        p.level = *r.pick(&[0u8, 0, 1, 2, 1, 3]);
    }
    t
}

fn gen_shape(r: &mut Rng, id: u32) -> Shape {
    let mut s = Shape { id: ShapeId(id), name: format!("S{id}"), ..Default::default() };
    if !r.chance(15) {
        s.xfrm = Some(Xfrm::new(r.range(-100.0, 900.0).round(), r.range(-50.0, 500.0).round(), r.range(0.0, 400.0).round(), r.range(0.0, 300.0).round()));
    }
    if r.chance(50) {
        s.text = Some(text_body(r));
    }
    if r.chance(40) {
        s.fill = Some(Fill::solid(ColorRef::rgb(Rgba::rgb(r.next() as u8, r.next() as u8, r.next() as u8))));
    }
    s
}

fn gen_animation(r: &mut Rng, shapes: u32) -> Animation {
    let (id, _, class, _, _, opts) = *r.pick(ANIMATIONS);
    let mut a = Animation { shape: ShapeId(1 + r.below(shapes as usize + 1) as u32), class, effect: id.into(), ..Default::default() };
    a.option = match r.below(4) {
        0 => String::new(),
        1 => "bogus".into(),
        _ => opts.first().map(|o| o.to_string()).unwrap_or_default(),
    };
    if !opts.is_empty() && r.chance(50) {
        a.option = r.pick(opts).to_string();
    }
    a.start = *r.pick(&[AnimStart::OnClick, AnimStart::WithPrevious, AnimStart::AfterPrevious]);
    a.duration_ms = *r.pick(&[0u32, 1, 250, 500, 1000, 1750, 3000]);
    a.delay_ms = *r.pick(&[0u32, 0, 100, 250, 1000]);
    a.repeat = *r.pick(&[0u32, 1, 1, 2, 3, u32::MAX, u32::MAX - 1]);
    a.auto_reverse = r.chance(20);
    a.rewind = r.chance(15);
    a.text_build = *r.pick(&[TextBuild::AsOne, TextBuild::AsOne, TextBuild::ByParagraph]);
    if r.chance(10) {
        a.paragraph = Some(r.below(5) as u32);
    }
    if r.chance(25) {
        a.trigger = Some(ShapeId(1 + r.below(shapes as usize) as u32));
    }
    a.after = match r.below(8) {
        0 => Some("hide".into()),
        1 => Some("hideOnNextClick".into()),
        2 => Some("#336699".into()),
        3 => Some("bogus".into()),
        _ => None,
    };
    if r.chance(30) {
        a.smooth_start = *r.pick(&[0.0, 0.2, 0.5, 0.9, 1.5]);
        a.smooth_end = *r.pick(&[0.0, 0.3, 0.5, 0.8]);
    }
    if r.chance(15) {
        a.bounce_end = *r.pick(&[0.1, 0.25, 0.5, 1.0]);
    }
    if r.chance(30) {
        a.amount = Some(*r.pick(&[0.0, 0.5, 1.5, 90.0, -720.0, 1e6]));
    }
    if r.chance(30) {
        a.color = Some(ColorRef::rgb(Rgba::rgb(r.next() as u8, r.next() as u8, r.next() as u8)));
    }
    if r.chance(15) {
        a.path = Some(fuzz_path(r));
    }
    a
}

fn gen_slide(r: &mut Rng) -> Slide {
    let n = 1 + r.below(5) as u32;
    let mut s = Slide { id: SlideId(r.below(10_000) as u32 + 1), ..Default::default() };
    s.shapes = (1..=n).map(|i| gen_shape(r, i)).collect();
    if r.chance(15) {
        // A group, its children animated too.
        let kids: Vec<Shape> = (0..2).map(|k| gen_shape(r, 50 + k)).collect();
        s.shapes.push(Shape { id: ShapeId(40), kind: ShapeKind::Group { children: kids, child: Xfrm::new(0.0, 0.0, 100.0, 100.0) }, ..Default::default() });
    }
    let k = r.below(9);
    s.animations = (0..k).map(|_| gen_animation(r, n)).collect();
    if r.chance(10) {
        for a in &mut s.animations {
            a.shape = *r.pick(&[ShapeId(40), ShapeId(50), ShapeId(51), ShapeId(1)]);
        }
    }
    s
}

fn timelines(out: &mut String, cases: &mut String, decks: &[(String, Presentation)]) {
    for (name, p) in decks {
        for (i, s) in p.slides.iter().enumerate() {
            timeline_line(out, &format!("corpus:{name}:{i}"), s, p.slide_size.width, p.slide_size.height);
        }
    }
    let mut r = Rng(0x5eed_0002);
    let sizes = [(960.0, 540.0), (720.0, 540.0), (f64::NAN, -1.0), (1e9, 1.0), (0.0, 0.0)];
    for k in 0..600 {
        let s = gen_slide(&mut r);
        let (w, h) = if k % 10 == 9 { *r.pick(&sizes) } else { (960.0, 540.0) };
        let _ = writeln!(cases, "{}", json(&s));
        timeline_line(out, &format!("gen:{k}"), &s, w, h);
    }
}

// ---------- show ----------

fn fmt_action(a: ShowAction) -> String {
    match a {
        ShowAction::None => "None".into(),
        ShowAction::PlayStep(n) => format!("PlayStep({n})"),
        ShowAction::FinishStep(n) => format!("FinishStep({n})"),
        ShowAction::StepBack(n) => format!("StepBack({n})"),
        ShowAction::Slide(n) => format!("Slide({n})"),
        ShowAction::End => "End".into(),
        ShowAction::Exit => "Exit".into(),
    }
}

fn fmt_jump(j: &LinkJump) -> String {
    match j {
        LinkJump::Show(a) => format!("Show({})", fmt_action(*a)),
        LinkJump::Open(u) => format!("Open({})", hs(u)),
        LinkJump::Exit => "Exit".into(),
        LinkJump::None => "None".into(),
    }
}

fn fmt_click(c: &Click) -> String {
    match c {
        Click::None => "None".into(),
        Click::Animated => "Animated".into(),
        Click::Show(a) => format!("Show({})", fmt_action(*a)),
        Click::Open(u) => format!("Open({})", hs(u)),
        Click::Exit => "Exit".into(),
    }
}

fn fmt_state(s: &ShowState, p: &Presentation) -> String {
    let plays: Vec<String> = s.trigger_plays().iter().map(|t| format!("{}:{}:{}", t.trigger.0, t.step, fb(t.t))).collect();
    let stamps: Vec<String> = s.trigger_stamps().iter().map(|t| format!("{}:{}:{}", t.trigger.0, t.step, t.at)).collect();
    let opt = |v: Option<usize>| v.map_or("-".to_string(), |x| x.to_string());
    format!(
        "{},{},{},{},{},{},{},{},{},{},{}|{}|{}",
        s.slide,
        s.step,
        s.playing as u8,
        s.ended as u8,
        s.zoom.map_or("-".into(), |(a, b)| format!("{a}/{b}")),
        opt(s.peek_next(p)),
        opt(s.first_index(p)),
        opt(s.last_index(p)),
        s.custom_name().map_or("-".into(), hs),
        s.trigger_playing() as u8,
        s.advance_after(p).map_or("-".into(), fb),
        plays.join(" "),
        stamps.join(" ")
    )
}

fn gen_action(r: &mut Rng, p: &Presentation) -> Action {
    let urls = ["https://example.org", " MAILTO:a@example.org", "javascript:alert(1)", "file:///etc/passwd", "", "http://x"];
    match r.below(11) {
        0 => Action::Url { url: r.pick(&urls).to_string() },
        1 | 2 => {
            let id = if !p.slides.is_empty() && r.chance(85) { p.slides[r.below(p.slides.len())].id } else { SlideId(9_999_999) };
            Action::Slide { slide: id }
        }
        3 => Action::NextSlide,
        4 => Action::PreviousSlide,
        5 => Action::FirstSlide,
        6 => Action::LastSlide,
        7 => Action::EndShow,
        8 => Action::LastViewed,
        9 => {
            let name = if !p.custom_shows.is_empty() && r.chance(80) { p.custom_shows[r.below(p.custom_shows.len())].name.clone() } else { "Missing".into() };
            Action::CustomShow { name, returns: r.chance(50) }
        }
        _ => {
            if r.chance(50) {
                Action::Program { path: "/bin/sh".into() }
            } else {
                Action::PlayMedia
            }
        }
    }
}

/// The hit shapes of slide `i` (top-level shapes and group children, back to front), `under` deciding which
/// are under the pointer.
fn hits_of(r: &mut Rng, p: &Presentation, i: usize) -> Vec<HitShape> {
    let mut v = Vec::new();
    let Some(s) = p.slides.get(i) else { return v };
    fn walk(r: &mut Rng, p: &Presentation, shapes: &[Shape], parent: Option<usize>, v: &mut Vec<HitShape>, depth: usize) {
        if depth > 3 {
            return;
        }
        for s in shapes {
            let link = match (&s.click, r.below(6)) {
                (Some(h), _) => Some(h.action.clone()),
                (None, 0) => Some(gen_action(r, p)),
                _ => None,
            };
            let idx = v.len();
            let is_group = matches!(s.kind, ShapeKind::Group { .. });
            v.push(HitShape { id: s.id, parent, is_group, link, under_pointer: r.chance(55) });
            walk(r, p, s.children(), Some(idx), v, depth + 1);
        }
    }
    walk(r, p, &s.shapes, None, &mut v, 0);
    if r.chance(5) {
        v.push(HitShape { id: ShapeId(777), parent: Some(v.len() + 3), is_group: false, link: None, under_pointer: true });
    }
    v
}

fn fmt_hits(h: &[HitShape]) -> String {
    let v: Vec<String> = h
        .iter()
        .map(|x| {
            format!(
                "{},{},{},{},{}",
                x.id.0,
                x.parent.map_or("-".into(), |p| p.to_string()),
                x.is_group as u8,
                x.link.as_ref().map_or("-".into(), |l| hs(&json(l))),
                x.under_pointer as u8
            )
        })
        .collect();
    if v.is_empty() { "-".into() } else { v.join(";") }
}

fn show_run(out: &mut String, id: &str, p: &Presentation, r: &mut Rng) {
    let (mut s, start) = match r.below(6) {
        0 if !p.slides.is_empty() => {
            let i = r.below(p.slides.len() + 1);
            (ShowState::start_at(p, i), format!("at:{i}"))
        }
        1 => {
            let name = p.custom_shows.first().map(|c| c.name.clone()).unwrap_or_else(|| "Missing".into());
            match ShowState::play_custom(p, &name) {
                Some(s) => (s, format!("custom:{}", hs(&name))),
                None => (ShowState::new(p), "new".into()),
            }
        }
        _ => (ShowState::new(p), "new".into()),
    };
    let _ = writeln!(out, "C\t{id}\t{start}\t{}", fmt_state(&s, p));
    let mut now = 0.0f64;
    let mut last: Option<usize> = None;
    for k in 0..120 {
        let before = s.slide;
        let tl = ShowState::timeline(p, s.slide);
        let (op, result) = match r.below(16) {
            0..=3 => ("next".to_string(), fmt_action(s.next(p))),
            4 => ("prev".into(), fmt_action(s.prev(p))),
            5 => ("done".into(), fmt_action(s.step_done(p))),
            6 => {
                let i = r.below(p.slides.len() + 2);
                (format!("goto:{i}"), fmt_action(s.goto(p, i)))
            }
            7 => {
                let a = gen_action(r, p);
                let lv = if r.chance(70) { last } else { Some(r.below(p.slides.len() + 2)) };
                (format!("follow:{}:{}", hs(&json(&a)), lv.map_or("-".into(), |x| x.to_string())), fmt_jump(&s.follow(p, &a, lv)))
            }
            8 => {
                let a = gen_action(r, p);
                let zr = if !p.slides.is_empty() && r.chance(60) { Some(p.slides[r.below(p.slides.len())].id) } else { None };
                let link = Hyperlink { action: a, tooltip: String::new(), highlight_click: false, zoom_return: zr, sound: None, stop_sound: false };
                (format!("link:{}:{}", hs(&json(&link)), last.map_or("-".into(), |x| x.to_string())), fmt_jump(&s.follow_link(p, &link, last)))
            }
            9 | 10 => {
                let dt = *r.pick(&[0.0, 0.05, 0.25, 0.5, 1.0, 3.0, 7.5]);
                now = if r.chance(3) { f64::NAN } else { now + dt };
                (format!("tick:{}", fb(now)), fmt_click(&s.tick(&tl, now)))
            }
            11..=13 => {
                let hits = hits_of(r, p, s.slide);
                let vis: Vec<(ShapeId, bool)> = hits
                    .iter()
                    .map(|h| {
                        let st = s.anim_state(&tl, h.id, 0.0);
                        (h.id, st.visible && st.opacity > 0.0)
                    })
                    .collect();
                let visible = move |id: ShapeId| vis.iter().find(|v| v.0 == id).is_none_or(|v| v.1);
                now += *r.pick(&[0.0, 0.1, 0.6, 2.0]);
                let c = s.click(p, &tl, &hits, &visible, now, last);
                (format!("click:{}:{}:{}", fb(now), last.map_or("-".into(), |x| x.to_string()), fmt_hits(&hits)), fmt_click(&c))
            }
            14 => {
                let hits = hits_of(r, p, s.slide);
                let t = s.target(p, &tl, &hits, &|_| true);
                let tt = s.top(p, &tl, &hits, &|_| true);
                (
                    format!("target:{}", fmt_hits(&hits)),
                    format!(
                        "{}|{}",
                        t.map_or("-".into(), |t| format!("{}:{}", t.shape.0, t.link.as_ref().map_or("-".into(), |l| hs(&json(l))))),
                        tt.map_or("-".into(), |x| x.to_string())
                    ),
                )
            }
            _ => {
                let e = *r.pick(&[f64::NAN, -1.0, 0.0, 1.0, 2.0, 2.5, 10.0]);
                (format!("due:{}", fb(e)), (s.auto_advance_due(p, e) as u8).to_string())
            }
        };
        if s.slide != before {
            last = Some(before);
        }
        // What the slide shows now: every top-level shape at a few main-step clocks.
        let tl = ShowState::timeline(p, s.slide);
        let mut h = Fnv::new();
        if let Some(sl) = p.slides.get(s.slide) {
            for sh in &sl.shapes {
                for t in [0.0, 0.3, 1.2] {
                    hash_state(&mut h, &s.anim_state(&tl, sh.id, t));
                }
            }
        }
        let _ = writeln!(out, "O\t{k}\t{op}\t{result}\t{}\t{}", fmt_state(&s, p), h.hex());
    }
}

fn gen_show_pres(r: &mut Rng) -> Presentation {
    let mut p = deckcraft_model::defaults::new_presentation(None);
    let n = r.below(7);
    p.slides = (0..n)
        .map(|i| {
            let mut s = gen_slide(r);
            s.id = SlideId(1000 + i as u32);
            s.hidden = r.chance(20);
            if r.chance(40) {
                s.transition = Some(Transition {
                    kind: "fade".into(),
                    advance_on_click: !r.chance(40),
                    advance_after_ms: if r.chance(50) { Some(*r.pick(&[0u32, 500, 2000])) } else { None },
                    ..Default::default()
                });
            }
            for sh in &mut s.shapes {
                if r.chance(20) {
                    sh.click = Some(Hyperlink {
                        action: Action::Slide { slide: SlideId(1000 + r.below(n + 1) as u32) },
                        tooltip: String::new(),
                        highlight_click: false,
                        zoom_return: if r.chance(30) { Some(SlideId(1000 + r.below(n + 1) as u32)) } else { None },
                        sound: None,
                        stop_sound: false,
                    });
                }
            }
            Arc::new(s)
        })
        .collect();
    if r.chance(40) && n > 0 {
        let k = 1 + r.below(n);
        let slides: Vec<SlideId> = (0..k).map(|_| SlideId(1000 + r.below(n + 1) as u32)).collect();
        p.custom_shows = vec![CustomShow { name: "Short".into(), slides }];
        if r.chance(50) {
            p.show.custom_show = Some(if r.chance(80) { "Short".into() } else { "Missing".into() });
        }
    }
    if r.chance(25) {
        p.show.range = Some((r.below(n + 2) as u32, r.below(n + 2) as u32));
    }
    p.show.loop_until_esc = r.chance(20);
    if r.chance(10) {
        p.show.show_type = "kiosk".into();
    }
    p.show.without_animation = r.chance(15);
    p.show.use_timings = !r.chance(20);
    p
}

fn show(out: &mut String, cases: &mut String, decks: &[(String, Presentation)]) {
    let mut r = Rng(0x5eed_0003);
    for (name, p) in decks {
        for k in 0..2 {
            show_run(out, &format!("corpus:{name}:{k}"), p, &mut r);
        }
    }
    for k in 0..120 {
        let p = gen_show_pres(&mut r);
        let _ = writeln!(cases, "{}", compact(&p));
        show_run(out, &format!("gen:{k}"), &p, &mut r);
    }
}

// ---------- morph ----------

fn morph_line(out: &mut String, id: &str, p: &Presentation, a: usize, b: usize) {
    let (Some(sa), Some(sb)) = (p.slides.get(a), p.slides.get(b)) else { return };
    let pairs: Vec<String> = morph_pairs(sa, sb).iter().map(|(x, y)| format!("{}:{}", x.0, y.0)).collect();
    for t in [f64::NAN, 0.0, 0.2, 0.5, 0.8, 1.0] {
        for hidden in 0..2u8 {
            let hb = |s: ShapeId| hidden == 1 && s.0 % 3 == 0;
            let f = morph_frame(p, sa, sb, t, &hb);
            let mut h = Fnv::new();
            for (s, _) in &f.shapes {
                h.s(&json(s));
            }
            let old: String = f.shapes.iter().map(|(_, o)| if *o { '1' } else { '0' }).collect();
            let ids: Vec<String> = f.shapes.iter().map(|(s, _)| s.id.0.to_string()).collect();
            let op: Vec<String> = f.opacity.iter().map(|(i, o)| format!("{}:{}", i.0, fb(*o))).collect();
            let xf = |x: &Xfrm| format!("{},{},{},{},{},{},{}", fb(x.x), fb(x.y), fb(x.w), fb(x.h), fb(x.rot), x.flip_h as u8, x.flip_v as u8);
            let text: Vec<String> = f.text.iter().map(|m| format!("{}:{}:{}:{}:{}", m.old.0, m.new.0, xf(&m.from), xf(&m.to), m.chars as u8)).collect();
            let paths: Vec<String> =
                f.paths.iter().map(|m| format!("{}:{}:{}:{}", m.id.0, hs(&json(&m.from)), xf(&m.from_box), xf(&m.to_box))).collect();
            let d = |v: Vec<String>| if v.is_empty() { "-".to_string() } else { v.join(";") };
            let _ = writeln!(
                out,
                "{id}\t{a}\t{b}\t{}\t{hidden}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                fb(t),
                d(pairs.clone()),
                fb(f.mix),
                h.hex(),
                d(ids),
                if old.is_empty() { "-".into() } else { old },
                d(op),
                d(text),
                d(paths)
            );
        }
    }
}

fn gen_morph_pres(r: &mut Rng) -> Presentation {
    let mut p = deckcraft_model::defaults::new_presentation(None);
    let names = ["", "Title 1", "!!Logo", "Box", "TextBox 2", "Picture 1"];
    let geoms = ["rect", "ellipse", "star5", "roundRect", "line", "triangle"];
    let texts = ["", "Hello", "Hello world", "The Science", "Science rocks", "  "];
    let n = 1 + r.below(5) as u32;
    let mut a = Slide { id: SlideId(1), ..Default::default() };
    for i in 1..=n {
        let mut s = Shape {
            id: ShapeId(i),
            name: r.pick(&names).to_string(),
            xfrm: Some(Xfrm::new(r.range(0.0, 800.0).round(), r.range(0.0, 400.0).round(), r.range(10.0, 300.0).round(), r.range(10.0, 200.0).round())),
            geom: Geom::preset(r.pick(&geoms)),
            ..Default::default()
        };
        let t = r.pick(&texts);
        if !t.is_empty() {
            s.text = Some(TextBody::from_text(t));
        }
        match r.below(6) {
            0 => s.fill = Some(Fill::solid(ColorRef::rgb(Rgba::rgb(r.next() as u8, r.next() as u8, r.next() as u8)))),
            1 => {
                s.kind = ShapeKind::Picture {
                    fill: deckcraft_model::style::PictureFill { crop: [r.range(0.0, 0.4), 0.0, r.range(0.0, 0.4), r.range(-0.1, 0.3)], ..Default::default() },
                }
            }
            2 => s.kind = ShapeKind::Table(Default::default()),
            _ => {}
        }
        if r.chance(20) {
            s.xfrm = s.xfrm.map(|x| Xfrm { rot: r.range(-400.0, 400.0).round(), flip_h: r.chance(50), ..x });
        }
        if r.chance(5) {
            s.xfrm = None;
        }
        a.shapes.push(s);
    }
    let mut b = Slide { id: SlideId(2), ..Default::default() };
    for s in &a.shapes {
        if r.chance(15) {
            continue;
        }
        let mut c = s.clone();
        c.id = ShapeId(100 + s.id.0);
        match r.below(8) {
            0 => {
                c.xfrm = c.xfrm.map(|x| Xfrm { x: x.x + 100.0, w: x.w * 1.5, rot: x.rot + 170.0, flip_v: !x.flip_v, ..x });
            }
            1 => c.geom = Geom::preset(r.pick(&geoms)),
            2 => c.fill = Some(Fill::solid(ColorRef::rgb(Rgba::rgb(r.next() as u8, 0, 0)))),
            3 => {
                if let ShapeKind::Picture { fill } = &mut c.kind {
                    fill.crop = [0.1, 0.2, 0.0, 0.05];
                }
            }
            4 => c.text = Some(TextBody::from_text(r.pick(&texts))),
            5 => c.name = r.pick(&names).to_string(),
            _ => {}
        }
        b.shapes.push(c);
    }
    if r.chance(30) {
        b.shapes.push(gen_shape(r, 300));
    }
    // Reorder some of the new slide's shapes.
    if b.shapes.len() > 1 && r.chance(40) {
        b.shapes.reverse();
    }
    if r.chance(60) {
        b.transition = Some(Transition { kind: "morph".into(), option: r.pick(&["objects", "words", "characters", ""]).to_string(), ..Default::default() });
    }
    p.slides = vec![Arc::new(a), Arc::new(b)];
    p
}

fn morph(out: &mut String, cases: &mut String, decks: &[(String, Presentation)]) {
    for (name, p) in decks {
        for i in 1..p.slides.len() {
            morph_line(out, &format!("corpus:{name}"), p, i - 1, i);
        }
    }
    let mut r = Rng(0x5eed_0004);
    for k in 0..400 {
        let p = gen_morph_pres(&mut r);
        let _ = writeln!(cases, "{}", compact(&p));
        morph_line(out, &format!("gen:{k}"), &p, 0, 1);
    }
}

fn xfrms(out: &mut String) {
    let mut r = Rng(0x5eed_0005);
    let specials = [f64::NAN, f64::INFINITY, -f64::INFINITY, -0.0, 0.0, 1e308, -1e-308];
    let val = |r: &mut Rng| if r.chance(6) { *r.pick(&specials) } else { r.range(-500.0, 900.0) };
    let xf = |x: &Xfrm| format!("{},{},{},{},{},{},{}", fb(x.x), fb(x.y), fb(x.w), fb(x.h), fb(x.rot), x.flip_h as u8, x.flip_v as u8);
    for _ in 0..4000 {
        let a = Xfrm { x: val(&mut r), y: val(&mut r), w: val(&mut r), h: val(&mut r), rot: val(&mut r), flip_h: r.chance(50), flip_v: r.chance(50) };
        let b = Xfrm { x: val(&mut r), y: val(&mut r), w: val(&mut r), h: val(&mut r), rot: val(&mut r), flip_h: r.chance(50), flip_v: r.chance(50) };
        let t = *r.pick(&[f64::NAN, -0.5, 0.0, 0.1, 0.4999, 0.5, 0.75, 0.999, 1.0, 3.0]);
        let _ = writeln!(out, "X\t{}\t{}\t{}\t{}", xf(&a), xf(&b), fb(t), xf(&morph_xfrm(a, b, t)));
    }
    let crop = |r: &mut Rng| -> [f64; 4] {
        let mut c = [0.0; 4];
        for v in &mut c {
            *v = if r.chance(5) { *r.pick(&specials) } else { r.range(-0.2, 0.7) };
        }
        c
    };
    for _ in 0..4000 {
        let (ca, cb) = (crop(&mut r), crop(&mut r));
        let bx = |r: &mut Rng| Xfrm::new(r.range(-100.0, 500.0), r.range(-100.0, 500.0), r.range(-10.0, 400.0), r.range(-10.0, 300.0));
        let (xa, xb, x) = (bx(&mut r), bx(&mut r), bx(&mut r));
        let t = r.unit();
        let c = morph_crop(ca, xa, cb, xb, x, t);
        let f4 = |c: [f64; 4]| c.iter().map(|v| fb(*v)).collect::<Vec<_>>().join(",");
        let _ = writeln!(out, "K\t{}\t{}\t{}\t{}\t{}\t{}\t{}", f4(ca), xf(&xa), f4(cb), xf(&xb), xf(&x), fb(t), f4(c));
    }
}

/// A generated deck as the Swift side reads it: what it sets on `new_presentation(None)` (written once, to
/// `default-presentation.json`), which keeps the case files small.
fn compact(p: &Presentation) -> String {
    let v = serde_json::json!({
        "slides": serde_json::to_value(&p.slides).unwrap_or_default(),
        "show": serde_json::to_value(&p.show).unwrap_or_default(),
        "customShows": serde_json::to_value(&p.custom_shows).unwrap_or_default(),
    });
    v.to_string()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (Some(decks_dir), Some(out_dir)) = (args.get(1), args.get(2)) else {
        eprintln!("usage: anim-vectors DECKS OUT");
        std::process::exit(64);
    };
    let out = std::path::Path::new(out_dir);
    std::fs::create_dir_all(out).expect("out dir");
    let mut names: Vec<String> = std::fs::read_dir(decks_dir)
        .expect("decks")
        .filter_map(|e| e.ok().map(|e| e.file_name().to_string_lossy().into_owned()))
        .filter(|n| n.ends_with(".deckcraft"))
        .collect();
    names.sort();
    let decks: Vec<(String, Presentation)> = names
        .iter()
        .map(|n| {
            let bytes = std::fs::read(std::path::Path::new(decks_dir).join(n)).expect("deck");
            (n.trim_end_matches(".deckcraft").to_string(), deckcraft_format::load(&bytes).expect("load"))
        })
        .collect();
    let write = |name: &str, s: &str| std::fs::write(out.join(name), s).expect("write");
    write("default-presentation.json", &json(&deckcraft_model::defaults::new_presentation(None)));
    let mut s = String::new();
    easing(&mut s);
    write("easing.txt", &s);
    let mut s = String::new();
    paths(&mut s);
    write("paths.txt", &s);
    let mut s = String::new();
    transitions(&mut s);
    write("transitions.txt", &s);
    let mut s = String::new();
    composite(&mut s);
    write("composite.txt", &s);
    let (mut s, mut c) = (String::new(), String::new());
    timelines(&mut s, &mut c, &decks);
    write("timelines.txt", &s);
    write("timelines-cases.jsonl", &c);
    let (mut s, mut c) = (String::new(), String::new());
    show(&mut s, &mut c, &decks);
    write("show.txt", &s);
    write("show-cases.jsonl", &c);
    let (mut s, mut c) = (String::new(), String::new());
    morph(&mut s, &mut c, &decks);
    write("morph.txt", &s);
    write("morph-cases.jsonl", &c);
    let mut s = String::new();
    xfrms(&mut s);
    write("xfrm.txt", &s);
}
