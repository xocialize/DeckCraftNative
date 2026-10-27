//! Text layout vectors: every text body of the oracle corpus decks and of a synthetic deck (wrapping,
//! bullets, autofit overflow, right-to-left Arabic and Hebrew, CJK, tabs, mixed fonts, fields…) laid out
//! with the pinned deckcraft-text, written as JSON so DCText can be compared with it.
//!
//!     text-vectors DECKS_DIR OUT_DIR
//!
//! Writes OUT_DIR/decks/<name>.json (each deck's model, as `presentation.json` holds it, after loading
//! and repair) and OUT_DIR/vectors.json: per body its deck, slide, shape path, layout box, font scale,
//! line reduction, and per line (para, start, end, top, baseline, bottom, extent) and per glyph run
//! (family, style, size, first and last glyph x, glyph count, para, chars). Build with CRAFT_FONTS_DIR
//! and CRAFT_FONTS_REQUIRED=1 so the bundled faces are the pinned craft-fonts.
use std::path::{Path, PathBuf};
use std::sync::Arc;

use deckcraft_geom::Rect;
use deckcraft_model::resolve::{self, Ctx};
use deckcraft_model::text::{Align, AutoFit, Bullet, Caps, Paragraph, Run, RunKind, Spacing, Strike, TabStop, TextBody, TextDir};
use deckcraft_model::{LayoutType, Presentation, Shape, ShapeKind, Xfrm, defaults};
use deckcraft_text::{NoFields, Opts, layout};
use serde_json::{Value, json};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (Some(decks), Some(out)) = (args.get(1), args.get(2)) else {
        eprintln!("usage: text-vectors DECKS_DIR OUT_DIR");
        std::process::exit(2);
    };
    let out = PathBuf::from(out);
    std::fs::create_dir_all(out.join("decks")).expect("output folder");
    let mut sources: Vec<(String, Presentation)> = vec![];
    let mut names: Vec<PathBuf> = std::fs::read_dir(decks)
        .expect("decks folder")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "deckcraft"))
        .collect();
    names.sort();
    for path in names {
        let bytes = std::fs::read(&path).expect("deck");
        let p = deckcraft_format::load(&bytes).expect("loads");
        sources.push((stem(&path), p));
    }
    sources.push(("synthetic".into(), synthetic()));
    let mut bodies = vec![];
    for (name, p) in &sources {
        std::fs::write(out.join("decks").join(format!("{name}.json")), serde_json::to_vec(p).expect("model json")).expect("write deck");
        for (si, slide) in p.slides.iter().enumerate() {
            let Some(ctx) = Ctx::for_slide(p, slide) else { continue };
            walk(&ctx, &slide.shapes, &mut vec![], &mut |path, shape| {
                let Some(body) = shape.text.as_ref() else { return };
                let x = resolve::xfrm(&ctx, shape);
                let rect = Rect::new(0.0, 0.0, x.w.max(0.0), x.h.max(0.0));
                let l = layout(&ctx, shape, body, &Opts { rect, fields: &NoFields, prompt_color: None, no_shrink: false });
                let lines: Vec<Value> =
                    l.lines.iter().map(|li| json!([li.para, li.start, li.end, li.top, li.baseline, li.bottom, li.extent.0, li.extent.1])).collect();
                let runs: Vec<Value> = l
                    .runs
                    .iter()
                    .map(|r| {
                        json!({
                            "family": r.face.family, "style": r.face.style, "size": r.size,
                            "x0": r.glyphs.first().map(|g| g.1), "x1": r.glyphs.last().map(|g| g.1),
                            "n": r.glyphs.len(), "para": r.para, "chars": [r.chars.0, r.chars.1],
                            "glyphs": r.glyphs.iter().map(|g| json!([g.0, g.1, g.2])).collect::<Vec<_>>(),
                        })
                    })
                    .collect();
                bodies.push(json!({
                    "deck": name, "slide": si, "path": path, "rect": [rect.x0, rect.y0, rect.x1, rect.y1],
                    "text": body.paragraphs.iter().map(|p| p.text()).collect::<Vec<_>>().join("\n"),
                    "font_scale": l.font_scale, "line_reduction": l.line_reduction, "overflow": l.overflow,
                    "lines": lines, "runs": runs,
                }));
            });
        }
    }
    let doc = json!({ "generator": "text-vectors", "bodies": bodies, "shapes": shapes() });
    std::fs::write(out.join("vectors.json"), serde_json::to_vec_pretty(&doc).expect("json")).expect("write vectors");
    eprintln!("text-vectors: {} bodies from {} decks", doc["bodies"].as_array().map_or(0, |b| b.len()), sources.len());
}

/// Items shaped directly with deckcraft-fonts' `shape_range` (one face, one direction, the default
/// features but kerning off and Latin ligatures off, as the layout shapes them): glyph id, cluster
/// (character index), advance and offsets in font units.
fn shapes() -> Vec<Value> {
    let db = deckcraft_fonts::FontDb::global();
    let samples: &[(&str, &str, bool, Option<&str>, bool)] = &[
        ("Inter", "Hello, world! AVATAR office fifth", false, Some("Latn"), true),
        ("Carlito", "The quick brown fox jumps over the lazy dog", false, Some("Latn"), true),
        ("Montserrat", "Variable weights: Montserrat Bold", false, Some("Latn"), true),
        ("Noto Sans Arabic", "بسم الله الرحمن الرحيم", true, Some("Arab"), false),
        ("Noto Sans Arabic", "سنة فقط نستعين به ونستغفره", true, Some("Arab"), false),
        ("Noto Naskh Arabic", "بسم الله الرحمن الرحيم", true, Some("Arab"), false),
        ("Noto Sans Hebrew", "שלום עולם מה שלומך", true, Some("Hebr"), false),
        ("Noto Sans Thai", "ภาษาไทยเขียนติดกัน", false, Some("Thai"), false),
        ("Noto Sans Devanagari", "हिन्दी क्षत्रिय मात्राएँ", false, Some("Deva"), false),
        ("Noto Sans JP", "日本語の文章。", false, Some("Hani"), false),
    ];
    let mut out = vec![];
    for (family, text, rtl, script, latin) in samples {
        if !db.has_family(family) {
            continue;
        }
        let face = db.face(family, "Regular");
        let mut features: Vec<deckcraft_fonts::Feature> = deckcraft_fonts::feature("-kern").into_iter().collect();
        if *latin {
            features.extend(deckcraft_fonts::feature("-liga"));
            features.extend(deckcraft_fonts::feature("-clig"));
        }
        let tag = script.and_then(|s| <[u8; 4]>::try_from(s.as_bytes()).ok());
        let params = deckcraft_fonts::ShapeParams { features: &features, rtl: *rtl, script: tag, language: None };
        let byte_to_char: std::collections::HashMap<usize, usize> = text.char_indices().enumerate().map(|(i, (b, _))| (b, i)).collect();
        let g = deckcraft_fonts::shape_range(&face, text, 0..text.len(), &params, |c| c);
        let glyphs: Vec<Value> = g
            .iter()
            .map(|g| json!([g.gid, byte_to_char.get(&g.cluster).copied().unwrap_or(usize::MAX), g.x_advance, g.x_offset, g.y_offset]))
            .collect();
        out.push(json!({ "family": face.family, "style": face.style, "text": text, "rtl": rtl, "script": script, "latin": latin, "glyphs": glyphs }));
    }
    out
}

fn stem(p: &Path) -> String {
    p.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
}

/// Every shape with its index path through groups.
fn walk(ctx: &Ctx, shapes: &[Shape], path: &mut Vec<usize>, f: &mut dyn FnMut(&[usize], &Shape)) {
    for (i, s) in shapes.iter().enumerate() {
        path.push(i);
        f(path, s);
        if let ShapeKind::Group { children, .. } = &s.kind {
            walk(ctx, children, path, f);
        }
        path.pop();
    }
}

fn run(text: &str, f: impl FnOnce(&mut Run)) -> Run {
    let mut r = Run::new(text);
    f(&mut r);
    r
}

fn para(runs: Vec<Run>, f: impl FnOnce(&mut Paragraph)) -> Paragraph {
    let mut p = Paragraph { runs, ..Default::default() };
    f(&mut p);
    p
}

/// A deck of one body per slide, each exercising part of the layout.
fn synthetic() -> Presentation {
    let mut p = defaults::new_presentation(None);
    p.slides.clear();
    let lay = defaults::layout_of_kind(&p, LayoutType::TitleAndContent).expect("layout");
    let add = |p: &mut Presentation, w: f64, h: f64, body: TextBody| {
        let Some(mut s) = defaults::new_slide(p, lay) else { return };
        let mut shape = s.shapes.remove(1);
        shape.xfrm = Some(Xfrm::new(40.0, 40.0, w, h));
        shape.text = Some(body);
        s.shapes = vec![shape];
        p.slides.push(Arc::new(s));
    };
    let body = |paras: Vec<Paragraph>| TextBody { paragraphs: paras, ..Default::default() };
    let lorem = "The quick brown fox jumps over the lazy dog while the five boxing wizards jump quickly, and a wizard's job is to vex chumps quickly in fog.";
    // Wrapping Latin, several widths and sizes.
    for (w, size) in [(300.0, 18.0), (180.0, 24.0), (520.0, 14.0)] {
        add(&mut p, w, 400.0, body(vec![para(vec![run(lorem, |r| r.props.size = Some(size))], |p| p.props.bullet = Some(Bullet::None))]));
    }
    // Bullets and autonumbers at three levels.
    let mut items = vec![];
    for (i, t) in ["First point", "Second point that is long enough to wrap onto another line here", "Third"].iter().enumerate() {
        items.push(para(vec![Run::new(*t)], |p| p.level = i as u8));
    }
    for t in ["one", "two", "three"] {
        items.push(para(vec![Run::new(t)], |p| p.props.bullet = Some(Bullet::AutoNum { scheme: "arabicPeriod".into(), start_at: 1 })));
    }
    items.push(para(vec![Run::new("roman")], |p| p.props.bullet = Some(Bullet::AutoNum { scheme: "romanUcParenR".into(), start_at: 3 })));
    add(&mut p, 400.0, 400.0, body(items));
    // Autofit overflow: shrink with no saved scale left to draw.
    let many: Vec<Paragraph> = (0..24).map(|i| para(vec![Run::new(format!("Overflowing line number {i}"))], |_| {})).collect();
    let mut b = body(many);
    b.body.autofit = Some(AutoFit::Shrink { font_scale: Some(1.0), line_reduction: 0.0 });
    add(&mut p, 400.0, 200.0, b);
    // Right-to-left Arabic (with numbers, Latin and brackets) and Hebrew.
    let ar = "سنة 2024 (Retrait) فقط بسم الله الرحمن الرحيم نستعين به ونستغفره ونتوب إليه";
    for (text, lang, align) in [(ar, "ar-SA", Align::Right), (ar, "en-US", Align::Right), ("שלום עולם 123 ABC, מה שלומך היום? טוב מאוד", "he-IL", Align::Justify)] {
        add(
            &mut p,
            260.0,
            300.0,
            body(vec![para(vec![run(text, |r| r.props.lang = Some(lang.into()))], |p| {
                p.props.rtl = Some(true);
                p.props.align = Some(align);
                p.props.bullet = Some(Bullet::None);
            })]),
        );
    }
    // CJK: Japanese with kinsoku, Chinese, Korean.
    for (text, lang) in [
        ("日本語の文章は空白なしで続きます。句読点も含めて、行末の処理を確認します。っ小さい仮名ーも。", "ja-JP"),
        ("中文排版测试：标点符号，换行规则。这是一段比较长的中文文本，用来检查换行。", "zh-CN"),
        ("한국어 안녕하세요 반갑습니다 감사합니다 한국어 문장은 단어 사이에서 줄이 바뀝니다", "ko-KR"),
    ] {
        add(
            &mut p,
            220.0,
            300.0,
            body(vec![para(vec![run(text, |r| r.props.lang = Some(lang.into()))], |p| {
                p.props.bullet = Some(Bullet::None);
                p.props.hanging_punct = Some(true);
            })]),
        );
    }
    // Tabs: left, centre, right and decimal stops, then defaults.
    let tabs = vec![
        TabStop { pos: 80.0, align: "l".into() },
        TabStop { pos: 180.0, align: "ctr".into() },
        TabStop { pos: 280.0, align: "r".into() },
        TabStop { pos: 360.0, align: "dec".into() },
    ];
    let tabbed: Vec<Paragraph> = ["a\tleft\tmid\tright\t12.50", "item\tx\tcentred\tend\t1234.5", "\t\t\t\t\tdefault"]
        .iter()
        .map(|t| {
            para(vec![Run::new(*t)], |p| {
                p.props.tabs = Some(tabs.clone());
                p.props.bullet = Some(Bullet::None);
            })
        })
        .collect();
    add(&mut p, 520.0, 200.0, body(tabbed));
    // Mixed fonts, sizes, weights and styles in one paragraph.
    let fonts = ["Calibri", "Times New Roman", "Courier New", "Georgia", "Arial", "Cambria", "Verdana", "Montserrat", "Roboto"];
    let mixed: Vec<Run> = fonts
        .iter()
        .enumerate()
        .map(|(i, f)| {
            run(&format!("{f} text "), |r| {
                r.props.font = Some((*f).into());
                r.props.size = Some(12.0 + 3.0 * i as f64);
                r.props.bold = Some(i % 2 == 1);
                r.props.italic = Some(i % 3 == 2);
            })
        })
        .collect();
    add(&mut p, 400.0, 400.0, body(vec![para(mixed, |p| p.props.bullet = Some(Bullet::None))]));
    // Fields: slide number and a date (NoFields keeps the saved text), next to text.
    let fields = vec![
        Run::new("Slide "),
        Run { text: "7".into(), props: Default::default(), kind: RunKind::Field { field: "slidenum".into() } },
        Run::new(" of the deck, saved on "),
        Run { text: "1/2/2024".into(), props: Default::default(), kind: RunKind::Field { field: "datetime1".into() } },
    ];
    add(&mut p, 400.0, 100.0, body(vec![para(fields, |p| p.props.bullet = Some(Bullet::None))]));
    // Alignment, line and paragraph spacing.
    let mut spaced = vec![];
    for (i, align) in [Align::Center, Align::Right, Align::Justify, Align::Distributed, Align::Left].into_iter().enumerate() {
        spaced.push(para(vec![Run::new("Spacing and alignment change from one paragraph to the next in this box")], |p| {
            p.props.align = Some(align);
            p.props.bullet = Some(Bullet::None);
            p.props.line_spacing = Some(if i % 2 == 0 { Spacing::Pct(0.9 + 0.2 * i as f64) } else { Spacing::Pts(20.0 + i as f64) });
            p.props.space_before = Some(Spacing::Pts(6.0 * i as f64));
            p.props.space_after = Some(Spacing::Pct(0.5));
        }));
    }
    add(&mut p, 300.0, 500.0, body(spaced));
    // Caps, superscript, underline, strike.
    let styled = vec![
        run("Small caps ", |r| r.props.caps = Some(Caps::Small)),
        run("ALL caps ", |r| r.props.caps = Some(Caps::All)),
        run("E=mc", |_| {}),
        run("2", |r| r.props.baseline = Some(0.3)),
        run(" H", |_| {}),
        run("2", |r| r.props.baseline = Some(-0.25)),
        run("O underlined ", |r| r.props.underline = Some("sng".into())),
        run("struck", |r| r.props.strike = Some(Strike::Single)),
    ];
    add(&mut p, 400.0, 150.0, body(vec![para(styled, |p| p.props.bullet = Some(Bullet::None))]));
    // East Asian vertical text and two columns.
    let mut b = body(vec![para(vec![Run::new("縦書きの日本語 ABC 123 です。")], |p| p.props.bullet = Some(Bullet::None))]);
    b.body.vert = Some(TextDir::EaVertical);
    add(&mut p, 200.0, 300.0, b);
    let mut b = body(vec![para(vec![Run::new(&lorem.repeat(3))], |p| p.props.bullet = Some(Bullet::None))]);
    b.body.columns = Some(2);
    b.body.col_spacing = Some(18.0);
    add(&mut p, 420.0, 160.0, b);
    // Thai and Devanagari.
    for text in ["ภาษาไทยเขียนติดกันโดยไม่มีช่องว่างระหว่างคำ การตัดบรรทัดจึงต้องใช้พจนานุกรม", "हिन्दी पाठ का परीक्षण संयुक्ताक्षर क्षत्रिय और मात्राएँ"] {
        add(&mut p, 240.0, 200.0, body(vec![para(vec![Run::new(text)], |p| p.props.bullet = Some(Bullet::None))]));
    }
    p
}
