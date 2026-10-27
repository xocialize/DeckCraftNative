//! display-vectors DIR: reads `DIR/f64.txt` and `DIR/f32.txt` (json-vectors' inputs: the hex bits
//! first on each line) and writes `DIR/display-f64.txt` and `DIR/display-f32.txt`, each line the
//! hex bits and `format!("{}", v)`. deckcraft-pptx's XML builder formats numbers this way.
use std::fmt::Write as _;

fn main() {
    let dir = std::path::PathBuf::from(std::env::args().nth(1).unwrap_or_else(|| ".".into()));
    let read = |name: &str| std::fs::read_to_string(dir.join(name)).expect("json-vectors inputs (oracle.sh json-vectors)");

    let mut out = String::new();
    let mut n64 = 0;
    for line in read("f64.txt").lines() {
        let Some(hex) = line.split(' ').next() else { continue };
        let Ok(bits) = u64::from_str_radix(hex, 16) else { continue };
        let _ = writeln!(out, "{hex} {}", f64::from_bits(bits));
        n64 += 1;
    }
    // Values the generator can't reach: NaN, the infinities, and the integers either side of 2^53.
    for v in [f64::NAN, -f64::NAN, f64::INFINITY, f64::NEG_INFINITY, 9_007_199_254_740_992.0, 1e21, 1e22, 1e-7, 123_456_789_012_345_680.0] {
        let _ = writeln!(out, "{:016x} {v}", v.to_bits());
        n64 += 1;
    }
    std::fs::write(dir.join("display-f64.txt"), out).expect("write display-f64.txt");

    let mut out = String::new();
    let mut n32 = 0;
    for line in read("f32.txt").lines() {
        let Some(hex) = line.split(' ').next() else { continue };
        let Ok(bits) = u32::from_str_radix(hex, 16) else { continue };
        let _ = writeln!(out, "{hex} {}", f32::from_bits(bits));
        n32 += 1;
    }
    for v in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY, f32::MAX, f32::MIN, 1e-45, 16_777_217.0] {
        let _ = writeln!(out, "{:08x} {v}", v.to_bits());
        n32 += 1;
    }
    std::fs::write(dir.join("display-f32.txt"), out).expect("write display-f32.txt");
    println!("{n64} f64, {n32} f32");
}
