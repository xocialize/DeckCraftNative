//! json-vectors OUT_DIR: writes `f64.txt`, `f32.txt` and `strings.txt`, each line an input and
//! serde_json's compact output for it. Inputs come from a fixed xorshift seed, so reruns are equal.
use std::fmt::Write as _;

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
}

fn main() {
    let out = std::path::PathBuf::from(std::env::args().nth(1).unwrap_or_else(|| ".".into()));
    std::fs::create_dir_all(&out).unwrap();
    let mut rng = Rng(0x9E37_79B9_7F4A_7C15);

    // f64: random bit patterns, decimal-looking values, and the edges of ryu's layout ranges.
    let mut f64s: Vec<f64> = Vec::new();
    for _ in 0..200_000 {
        let v = f64::from_bits(rng.next());
        if v.is_finite() {
            f64s.push(v);
        }
    }
    for i in -2000..2000 {
        f64s.push(i as f64);
        f64s.push(i as f64 / 100.0);
        f64s.push(i as f64 / 3.0);
        f64s.push(i as f64 * 12_700.0);
        f64s.push(i as f64 / 12_700.0);
    }
    for e in -330..310 {
        for m in [1.0, 1.5, 9.999_999_999_999_999, 123_456_789.0] {
            f64s.push(m * 10f64.powi(e));
        }
    }
    f64s.extend([0.0, -0.0, f64::MIN_POSITIVE, f64::MAX, f64::MIN, f64::EPSILON, 5e-324, 1e16, 1e17, 9_007_199_254_740_993.0, 0.1 + 0.2]);
    let mut s = String::new();
    for v in &f64s {
        let _ = writeln!(s, "{:016x} {}", v.to_bits(), serde_json::to_string(v).unwrap());
    }
    std::fs::write(out.join("f64.txt"), s).unwrap();

    // f32: the same mix at single precision.
    let mut f32s: Vec<f32> = Vec::new();
    for _ in 0..100_000 {
        let v = f32::from_bits(rng.next() as u32);
        if v.is_finite() {
            f32s.push(v);
        }
    }
    for i in -2000..2000 {
        f32s.push(i as f32 / 100.0);
        f32s.push(i as f32 / 3.0);
    }
    for e in -46..39 {
        f32s.push(1.5 * 10f32.powi(e));
    }
    f32s.extend([0.0, -0.0, f32::MIN_POSITIVE, f32::MAX, 1e13, 1e14, 0.000_001, 0.000_000_1]);
    let mut s = String::new();
    for v in &f32s {
        let _ = writeln!(s, "{:08x} {}", v.to_bits(), serde_json::to_string(v).unwrap());
    }
    std::fs::write(out.join("f32.txt"), s).unwrap();

    // Strings: every C0 control, quotes, backslashes, DEL, non-ASCII and astral characters, as JSON
    // input (hex of the UTF-8) and serde_json's output.
    let mut strings: Vec<String> = (0u8..0x80).map(|b| (b as char).to_string()).collect();
    strings.extend(["", "a\"b\\c/d", "tab\there\nnew\r\u{7f}", "é ü 中文 🎉 \u{2028}\u{2029}", "\u{0}\u{1f}\u{20}"].map(String::from));
    let mut s = String::new();
    for v in &strings {
        let hex: String = v.bytes().map(|b| format!("{b:02x}")).collect();
        let _ = writeln!(s, "{} {}", if hex.is_empty() { "-".into() } else { hex }, serde_json::to_string(v).unwrap());
    }
    std::fs::write(out.join("strings.txt"), s).unwrap();
    println!("{} f64, {} f32, {} strings", f64s.len(), f32s.len(), strings.len());
}
