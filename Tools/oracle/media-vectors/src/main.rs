//! media-vectors FIXTURES — runs deckcraft-media over the media inputs and writes what it returns, so
//! DCMedia (Swift) can be checked against it.
//!
//! Inputs:
//! - `FIXTURES/media/inputs/*`: files DCMediaTests generates in code (WAV, AIFF, CAF, MP3 and ADTS
//!   frames, ASF headers, Ogg and Matroska files written by hand, MP4/MOV/M4A from AVAssetWriter).
//! - `../deckcraft/crates/media/tests/fixtures/` (and `damaged/`): upstream's CC0 fixtures, made with
//!   ffmpeg from a synthesised sine and gradient (their `make.sh`).
//!
//! For every input it also makes deterministic mutations: truncations and bytes inverted at fixed
//! positions. Each case is written to `FIXTURES/media/cases/<case>.bin`, and `FIXTURES/media/probe.txt`
//! gets, per case:
//!
//! ```text
//! == <case>
//! sniff <container>
//! headers <result>          probe_headers
//! probe <result>            probe
//! decode ok <rate> <channels> <frames> | decode err <kind> <message>
//! video ok <w> <h> <codec> <frames> | video err <kind> <message>
//! times <t>,<t>,…           presentation times of the decoded frames (as f64 bit patterns), unmutated inputs only
//! ```
//!
//! A result is `ok <container> <duration_ms> audio=<codec>|<rate>|<channels>|<decodable>
//! video=<codec>|<w>|<h>|<fps bits>|<frames>|<decodable>` (`-` for none) or `err <kind> <message>`.
//! The Swift test (`DCMediaTests/OracleParityTests.swift`) reads the same `.bin` files and compares.
use deckcraft_media::{Bytes, Container, MediaError, MediaInfo, audio, probe, video};
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::sync::Arc;

fn err(e: &MediaError) -> String {
    match e {
        MediaError::Unsupported(s) => format!("err unsupported {s}"),
        MediaError::Corrupt(s) => format!("err corrupt {s}"),
        MediaError::Missing(s) => format!("err missing {s}"),
    }
}

fn info(r: &Result<MediaInfo, MediaError>) -> String {
    match r {
        Err(e) => err(e),
        Ok(i) => {
            let a = match &i.audio {
                None => "-".to_string(),
                Some(a) => format!("{}|{}|{}|{}", a.codec, a.sample_rate, a.channels, a.decodable),
            };
            let v = match &i.video {
                None => "-".to_string(),
                Some(v) => format!("{}|{}|{}|{:016x}|{}|{}", v.codec, v.width, v.height, v.fps.to_bits(), v.frames, v.decodable),
            };
            format!("ok {} {} audio={} video={}", i.container, i.duration_ms, a, v)
        }
    }
}

/// Truncations and inverted bytes at fixed positions: the header region densely, the rest sparsely.
fn mutations(b: &[u8]) -> Vec<(String, Vec<u8>)> {
    let n = b.len();
    let mut out = Vec::new();
    if n < 16 {
        return out;
    }
    for cut in [n / 4, n / 2, 3 * n / 4, n - 1] {
        out.push((format!("cut{cut}"), b[..cut].to_vec()));
    }
    let head = n.min(512);
    let mut at: Vec<usize> = (0..12).map(|k| (k * 37 + 4) % head).collect();
    at.extend((1..=6).map(|k| n * k / 7));
    at.sort_unstable();
    at.dedup();
    for p in at {
        let mut m = b.to_vec();
        m[p] ^= 0xFF;
        out.push((format!("x{p}"), m));
    }
    out
}

fn case(name: &str, bytes: &[u8], full: bool, out: &mut String, cases: &Path) {
    std::fs::write(cases.join(format!("{name}.bin")), bytes).expect("write case");
    let b: Bytes = Arc::new(bytes.to_vec());
    let _ = writeln!(out, "== {name}");
    let _ = writeln!(out, "sniff {}", Container::sniff(&b).name());
    let r = std::panic::catch_unwind(|| {
        let mut s = String::new();
        let _ = writeln!(s, "headers {}", info(&probe::probe_headers(&b)));
        let _ = writeln!(s, "probe {}", info(&probe::probe(&b)));
        match audio::decode(&b) {
            Ok(p) => {
                let _ = writeln!(s, "decode ok {} {} {}", p.rate, p.channels, p.frames());
            }
            Err(e) => {
                let _ = writeln!(s, "decode {}", err(&e));
            }
        }
        match video::VideoDecoder::open(b.clone()) {
            Err(e) => {
                let _ = writeln!(s, "video {}", err(&e));
            }
            Ok(mut d) => {
                let (w, h) = d.size();
                let _ = writeln!(s, "video ok {w} {h} {} {}", d.codec(), d.frame_count());
                if full {
                    let mut times = Vec::new();
                    for _ in 0..64 {
                        match d.next_frame() {
                            Ok(Some(f)) => times.push(format!("{:016x}", f.time.to_bits())),
                            _ => break,
                        }
                    }
                    let _ = writeln!(s, "times {}", times.join(","));
                }
            }
        }
        s
    });
    match r {
        Ok(s) => out.push_str(&s),
        Err(_) => {
            let _ = writeln!(out, "panic");
        }
    }
}

fn files(dir: &Path) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = std::fs::read_dir(dir).map(|r| r.filter_map(|e| e.ok().map(|e| e.path())).collect()).unwrap_or_default();
    v.retain(|p| p.is_file() && p.file_name().is_some_and(|n| !n.to_string_lossy().starts_with('.')) && p.extension().is_some_and(|e| e != "sh"));
    v.sort();
    v
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let Some(fixtures) = args.get(1).map(PathBuf::from) else {
        eprintln!("usage: media-vectors FIXTURES");
        std::process::exit(2);
    };
    let here = Path::new(env!("CARGO_MANIFEST_DIR"));
    let upstream = here.join("../../../../deckcraft/crates/media/tests/fixtures");
    let media = fixtures.join("media");
    let cases = media.join("cases");
    let _ = std::fs::remove_dir_all(&cases);
    std::fs::create_dir_all(&cases).expect("cases dir");
    let mut inputs: Vec<(String, Vec<u8>, bool)> = Vec::new();
    for p in files(&media.join("inputs")) {
        let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        inputs.push((name, std::fs::read(&p).expect("read input"), true));
    }
    for p in files(&upstream) {
        let name = format!("upstream-{}", p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default());
        inputs.push((name, std::fs::read(&p).expect("read upstream fixture"), true));
    }
    for p in files(&upstream.join("damaged")) {
        let name = format!("damaged-{}", p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default());
        inputs.push((name, std::fs::read(&p).expect("read damaged fixture"), false));
    }
    let mut out = String::new();
    let mut n = 0;
    for (name, bytes, mutate) in &inputs {
        case(name, bytes, true, &mut out, &cases);
        n += 1;
        if *mutate {
            for (m, b) in mutations(bytes) {
                case(&format!("{name}~{m}"), &b, false, &mut out, &cases);
                n += 1;
            }
        }
    }
    std::fs::write(media.join("probe.txt"), out).expect("write probe.txt");
    eprintln!("media-vectors: {} inputs, {n} cases", inputs.len());
}
