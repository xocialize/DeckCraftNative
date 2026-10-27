# DeckCraftNative — working notes

deckcraft (Rust) converted to a native macOS 26+ Swift app. [PLAN.md](PLAN.md) is the plan, and
[PORT-STATUS.md](PORT-STATUS.md) is where it stands. Read both first.

## Rules carried over from deckcraft (its AGENTS.md wins where they disagree)

- **Assets.** Nothing from Microsoft, Adobe, Avid or Autodesk products, and no PowerPoint-saved files
  committed. Fonts come from `../craft-fonts`, which is OFL or Apache.
- **Clean room.** File formats come from ECMA-376 and ISO 32000. Never copy GPL, LGPL or MPL code.
  Permissive code may be ported, and every ported file names its source file and licence in its header.
- **Never crash.** Production targets have no `!`, `try!`, `fatalError`, `precondition`, `as!`, or
  unchecked subscripts on input-derived indices. Treat numbers that come from files or commands as
  hostile, and bound recursion and allocations. A crash fix lands with a regression test.
- **Everything is a command.** Command ids are deckcraft's, unchanged. Programmatic calls never open UI.
- **Layering.** It is enforced by the target dependencies in `Package.swift`. Nothing below the app
  imports AppKit or SwiftUI.

## Porting a crate

Rust semantics live in DCCore, so use them rather than the Swift look-alikes:

- **Casts.** `init(rustCast:)`, not `UInt8(x)`, which traps.
- **Floats.** `clamped`, `rem`, `rustMin`/`rustMax`.
- **Strings.** `rustTrim`, `rustLines`, `rustLowercase`, `rustEqual` (Swift's `==` equates canonically
  equivalent strings), `rustFixed` for `{:.N}`, and `String.charCount` for `chars().count()`.
- **JSON.** serde-derived types are *generated*. `Tools/port/generate.sh` runs `Tools/port/serde2swift.py`
  over the crate's sources. Never hand-write or hand-edit a `Types.generated.swift`. The behaviour goes in
  hand-written files beside it, and the compiler lists what the generated code expects you to provide.

1. Read the crate at the pin (`Tools/oracle/pin.env`; the checkout is `../deckcraft`).
2. Port its tests alongside the code, as Swift Testing tests.
3. Keep a file map in the package's `PORT-NOTES.md`.
4. Compare against the oracle corpus (`DCTestSupport.Fixtures.oracleCorpus`), not against memory of
   what deckcraft does.
5. Update `PORT-STATUS.md` when a crate lands.

## Moving the pin

When upstream moves:

1. Diff it: `git -C ../deckcraft diff <pin>..origin/main -- crates/<crate>`.
2. Port the diff.
3. Update `pin.env`.
4. Run `Tools/oracle/oracle.sh build && Tools/oracle/oracle.sh corpus`.

## Gotchas

- **Test macros.** Swift Testing's `#expect` and `#require` can't call a mutating method. Assign its result to
  a `let` first.
- **Shared tree.** Parallel sessions working in the same tree build with their own `--scratch-path`
  (`.build-<name>/`, gitignored). Each owns a disjoint set of files and keeps the shared build green.

- `/Volumes/Satechi` is nearly full, so cargo's output goes to `~/Library/Caches/DeckCraftNative/cargo-target`.
- Homebrew's `rustup` is keg-only. `oracle.sh` puts `/opt/homebrew/opt/rustup/bin` on `PATH` itself.
