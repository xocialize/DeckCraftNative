//! Copies deckcraft-pptx's opc.rs with `Package::open_within` made public (it is private to the module,
//! and the budget vectors call it with small limits). Nothing else changes; the module docs are dropped
//! because `include!` can't take inner attributes.
fn main() {
    let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../../deckcraft/crates/pptx/src/opc.rs");
    println!("cargo:rerun-if-changed={}", src.display());
    let text = std::fs::read_to_string(&src).expect("read opc.rs");
    let patched: String = text
        .lines()
        .filter(|l| !l.starts_with("//!"))
        .map(|l| if l.trim_start().starts_with("fn open_within(") { l.replacen("fn open_within(", "pub fn open_within(", 1) } else { l.to_string() })
        .collect::<Vec<_>>()
        .join("\n");
    assert!(patched.contains("pub fn open_within("), "opc.rs changed: open_within not found");
    let out = std::path::PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR")).join("opc.rs");
    std::fs::write(out, patched).expect("write opc.rs");
}
