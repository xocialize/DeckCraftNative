# Legacy .ppt and password-protected presentations

**Status:** plan, draft 2, 2026-10-30. The operator's decisions are recorded (§9). **E0–E3 are done** (§5, the milestone notes): encryption is ready for a release; P1 is next. · **Pin:**
deckcraft `88c2ceff` · **Reads with:** [PLAN.md](../../PLAN.md) §11, [EVALUATION.md](../../EVALUATION.md) §1,
[PORT-STATUS.md](../../PORT-STATUS.md), DCPPTX's and DCEngine's PORT-NOTES.

Two kinds of file don't open in DeckCraftNative today, and deckcraft can't open them either:

- **Password-protected presentations.** A `.pptx` saved with a password is not a zip but a compound file that wraps
  the encrypted zip. DCPPTX recognises one (`CFB.isEncrypted`) and the engine refuses it with "DeckCraft can't open
  password-protected presentations yet". Quick Look says the same.
- **Legacy `.ppt`** (PowerPoint 97 to 2003, and anything later saved in that format). The app doesn't declare the
  type at all: File › Open greys it out and the engine answers "not a presentation DeckCraft can read".

This plan adds both, as **a new wave in two parts**: encryption first (smaller, and useful on its own), then a
`.ppt` reader. Every release since 0.1.0 has listed both as "Not supported".

> **Guiding principle (the operator, 2026-10-27):** *familiarity, not a 100% match.* Someone who knows PowerPoint
> should be comfortable: a protected file asks for its password the way PowerPoint does, File › Passwords is where
> they expect it, and an old `.ppt` opens and can be saved as a modern file. Exact parity that adds work and no
> comfort is left out.

## 1. Sources and the clean-room line

| Source | Used for | Rule |
|---|---|---|
| [MS-OFFCRYPTO] (119 pp), [MS-PPT] (647 pp), [MS-ODRAW] (611 pp), [MS-OSHARED] (199 pp) in `../OfficeFileFormatsProtocols`; [MS-CFB] and [MS-OLEPS], to be downloaded there (approved 2026-10-30) | **The formats.** Open Specifications under Microsoft's Open Specification Promise | Implement from the documents; never copy their text into code or docs (PLAN.md §11). Their examples sections (MS-PPT has 134 pages) become hand-built test inputs, typed from the structure, not pasted |
| deckcraft `crates/pptx/src/cfb.rs` → `DCPPTX/CFB.swift` (MIT OR Apache-2.0) | The start of the compound-file reader | Already ported. It moves and grows (§4) |
| rust-cfb (MIT), SheetJS js-cfb (Apache-2.0), OLEKit (Apache-2.0, dormant) | Reference for the compound-file reader and writer | Permissive: may be consulted and ported with attribution in the file header. The spec stays the authority |
| msoffcrypto-tool (MIT), Apache POI (Apache-2.0), LibreOffice (MPL-2.0) | **Run, never copied**: they make test files and act as independent readers (§6) | LibreOffice's code is MPL: run only. Their own sample files are excluded (provenance unknown, mostly saved by Office) |
| [ppt2pptx](https://github.com/HuiTurn/ppt2pptx) (MIT, pure Python, 0.4.2; suggested by the operator 2026-10-30) | **An independent `.ppt` reader** (its reports are in the fixtures' `reference/`), and **a porting reference**: it already handles incremental saves, master selection, RC4 CryptoAPI, PICT, MS Graph charts and tables rebuilt from cell grids | MIT: may be consulted and ported with attribution in the file header; the spec stays the authority. Its own test `.ppt` files were made with PowerPoint (COM) and are excluded |
| Microsoft PowerPoint for Mac (installed; black-box) | **Behaviour**: the password prompt, File › Passwords, what a `.ppt` looks like once open, slide and shape counts in sweeps. **And password-protected test files** (§6.1, approved 2026-10-30): PowerPoint saves DeckCraft's own decks with a password, as `.pptx` and as `.ppt` | Behaviour described in our own words. The protected files are the one thing PowerPoint saves that is used, and they stay **local-only**, in `~/Library/Caches/DeckCraftNative/powerpoint-protected/`: never in the repo or `../DeckCraftNative-Fixtures`. Nothing else PowerPoint saves, renders or shows is kept |
| Govdocs1 (US-government files from `.gov` servers) | A **local-only crash corpus** of real `.ppt` files (§6.4, approved 2026-10-30) | Never committed, never in the fixtures repo, never compared for content: only "opens or fails cleanly, in bounded time" |

Two traps to keep out:

- **POI's blank template.** `new HSLFSlideShow()` starts from a bundled `empty.ppt` that PowerPoint almost certainly
  saved, so every `.ppt` POI makes from scratch carries PowerPoint's bytes. POI is used only to *encrypt* `.ppt`
  files LibreOffice made, and to *read* files for comparison.
- **Working text of the specs.** The spec survey extracted their text into the session scratchpad; it stays there.

## 2. What PowerPoint does (observed 2026-10-30)

PowerPoint for Mac 16 on macOS 27, black box, described in our own words. No password was typed into PowerPoint:
each prompt was opened and cancelled (or answered with Read Only).

- **Opening a file with a password to open**: before any document window, a small window titled *Password to
  Open* says the presentation needs a password, names the file, and has one password field with Cancel and Open
  (Open is disabled while the field is empty). Cancel leaves an empty document window with "can't read" and the
  file's path, and an OK button.
- **Opening a file with a password to modify**: *Password to Modify* names the file, has a "Reserved by" line (the
  author, blank in our files), a password field, and three buttons: **Read Only** on the left, Cancel and Modify
  (disabled while empty) on the right. Read Only opens the document with "Read-Only" after its name in the title
  bar and the formatting controls disabled. Not observed: what follows a wrong password, and the order of the two
  prompts when a file has both.
- **Setting passwords**: File › Passwords… (between *Always Open Read-Only* and *Restrict Permissions*, disabled in
  a read-only document) opens a sheet with two sections. *Password to open*: a checkbox "Encrypt this presentation
  and require a password to open". *Password to modify*: a checkbox "Require a password to modify the
  presentation". Each has a Change Password… button, enabled once its box is ticked; Cancel and OK close the sheet.
  The ribbon's Review tab wasn't checked for a Protect command.
- **What PowerPoint writes** (from the files `powerpoint-protect.sh` made): a password to open gives Agile
  encryption, AES-256 with SHA-512 and 100,000 rounds, in `.pptx`, and RC4 CryptoAPI in `.ppt` (the summary
  streams left in the clear). A password to modify alone leaves the `.pptx` unencrypted, with a `modifyVerifier`
  (SHA-512, 100,000 rounds) in `presentation.xml`; with both passwords the verifier is inside the encrypted package.
- **Opening a `.ppt`**: the title bar reads "*name* - Compatibility Mode". The File menu has no Convert command;
  Save keeps the `.ppt`, and Save As… offers other formats. Move… and Rename… are disabled.

## 3. Adopt, adapt or skip

| PowerPoint behaviour | Here | Why |
|---|---|---|
| Password sheet on open; retry on a wrong password | **Adopt** | The familiar path |
| File › Passwords… (open and modify), Review › Protect Presentation | **Adopt** | Same place, same two fields |
| Password to modify → Read Only | **Adopt** for `.pptx` (`modifyVerifier` in `presentation.xml`, ECMA-376) | Not encryption; it's a hash. A read-only window is the comfort |
| Saving a `.ppt` back as `.ppt` | **Skip** (§9.1) | A `.ppt` opens as an untitled converted copy; Save offers `.pptx` or `.deckcraft` |
| "[Compatibility Mode]" and File › Convert | **Adapt** | The window says the file was converted from `.ppt` (a one-line banner with the import report), and Save is Save As |
| Encryption types | Read Agile, Standard and `.ppt` RC4 CryptoAPI; write Agile only (AES-256, SHA-512, 100,000 rounds, Office 2013's default) | What Office has written since 2007. Extensible encryption and IRM (rights-managed) files are recognised and refused by name |
| PowerPoint 2003–2007's default password for `.ppt` (a fixed string the spec gives) | **Adopt silently** | Files PowerPoint encrypted with no password the user knows open without a prompt |

## 4. Architecture

### 4.1 New targets

| Target | Layer | Depends on | Holds |
|---|---|---|---|
| **DCCFB** | L0 | nothing | The compound file: header (v3 512-byte and v4 4096-byte sectors), DIFAT, FAT, mini FAT and mini stream, the directory tree (walked by child/sibling links, names compared case-insensitively). **Reader and writer**: the writer is needed to save encrypted `.pptx` (E3). Every sector id bounds-checked, every chain cycle-checked, sizes capped. `DCPPTX/CFB.swift` stays: it is deckcraft's sniffer and 400 parity vectors pin its behaviour; the engine moves to DCCFB in E2 |
| **DCOffCrypto** | L1 | DCCore, DCCFB, CommonCrypto | [MS-OFFCRYPTO]: the `EncryptionInfo` parsers (Agile XML, Standard binary, RC4 CryptoAPI), key derivation, password verification, segment decryption, the Agile HMAC integrity check, the Agile writer, and RC4 CryptoAPI block decryption for `.ppt`. Pure functions over bytes; cancellable; no logging of passwords or keys |
| **DCPPT** | L4 | DCModel, DCGeometry, DCColor, DCCore, DCZip, DCCFB, DCOffCrypto, DCPPTX | [MS-PPT] + [MS-ODRAW] → `Presentation`, plus an import report. DCPPTX only for its readers of the round-trip OOXML parts a `.ppt` may embed (theme, layouts, timing, §5 P2/P5) |

DCZip already inflates; zlib-wrapped streams (compressed metafile pictures, embedded OLE objects) need its two-byte
header and Adler-32 handled, a small addition there. DCEngine and DCExtensionKit add DCCFB, DCOffCrypto and DCPPT.

### 4.2 Opening

`FileCommands.openChecked` sniffs in this order: `.deckcraft`, zip `.pptx`, then **compound file**:

1. `EncryptionInfo` + `EncryptedPackage` → protected OOXML. With no password: the error **`passwordRequired`**.
   With one: decrypt, verify (Agile's HMAC; a mismatch is `damaged`, not "wrong password"), then hand the zip to
   DCPPTX as today. Extensible or `\x09DRMContent` → a named refusal.
2. `PowerPoint Document` + `Current User` → `.ppt`. An encrypted one (a CryptSession reference in the UserEditAtom;
   not the header token, which PowerPoint 2002 writes unencrypted) tries the default password, then asks.
3. Anything else → today's "not a presentation DeckCraft can read".

The engine never prompts (programmatic calls never open UI): `file.open` and `file.openBytes` gain an optional
`password` param, and `passwordRequired` / `wrongPassword` come back as errors. **The app** catches them in
`PresentationDocument.read`, shows the password sheet over the document's window (or as an app-modal alert when
there is none), and retries. MCP and `dccli` pass `password`.

A `.ppt` opens **untitled**, like txt/md/rtf today, named after the file, with the import report available
(§4.4). Its type is declared with the Viewer role: `com.microsoft.powerpoint.ppt`, `.pot` and `.pps`. Quick Look,
thumbnails and Spotlight for `.ppt` stay with macOS's own Office importers, which already handle them.

### 4.3 Saving with a password

- The password lives **with the open document in memory** (an engine-side `DocProtection` beside the document
  state, never in DCModel), so it never reaches `.deckcraft`, the clipboard, MCP replies or logs.
- **Save as `.pptx`** with protection → DCPPTX writes the zip, DCOffCrypto encrypts it, DCCFB writes the compound
  file with `EncryptionInfo`, `EncryptedPackage` and the `\x06DataSpaces` storage.
- **Save as `.deckcraft`**: the format has no encryption. Saving a protected presentation as `.deckcraft` warns that
  the password won't be kept (a `.deckcraft` with encryption is a later decision, §8).
- **AutoRecover** must not write a protected presentation in the clear. Until E3, a protected document has
  AutoRecover off; from E3 its recovery file is encrypted with the same password.
- **App-side Spotlight indexing** (SpotlightFeature) indexes `.deckcraft` only, so a protected `.pptx`'s text is
  never indexed. Keep it that way.
- New command: **`file.passwords {open?, modify?}`** (our id; deckcraft has none), behind File › Passwords… and
  Review › Protect Presentation.

### 4.4 The import report

`PPTX.importChecked` returns the slides it couldn't read; a `.ppt` import loses more, so DCPPT returns a structured
report: what was read, what became a picture (charts, OLE objects, PICT), what was dropped (VBA, ActiveX,
broadcast data). The app shows it from the converted banner; `dccli`/MCP return it with `file.open`.

## 5. Milestones

Sizes are relative (S, M, L, XL). Each milestone ends with its tests green, both alpha gates, PORT-NOTES, and
PORT-STATUS, as before.

| # | Milestone | Size | Done when |
|---|---|---|---|
| **E0** | **Setup.** Install LibreOffice, a JDK with Apache POI, and msoffcrypto-tool in a venv (all outside the repo); download [MS-CFB] and [MS-OLEPS]. `Tools/legacy/` scripts that make every test file (§6.1), writing into `../DeckCraftNative-Fixtures/legacy/`, and the PowerPoint-protected set into its local cache. The PowerPoint observations of §2 | S | `Tools/legacy/make-fixtures.sh` regenerates the encrypted and `.ppt` sets from DeckCraft's own decks |
| **E1** | **DCCFB.** Reader and writer, v3 and v4, mini stream, DIFAT beyond 109 entries, cycle and range guards, fuzzing. (DCPPTX's deckcraft-ported `CFB.swift` stays for parity; the engine and DeckReader move to DCCFB in E2) | S | Streams read back byte-for-byte against olefile on every fixture; files we write open in olefile and POI; fuzzed input never crashes or hangs |
| **E2** | **Open protected `.pptx`.** Agile and Standard decryption, password verification, HMAC, the named refusals; `passwordRequired` through the engine, the app's password sheet, MCP/`dccli` `password`; AutoRecover off for protected documents; Quick Look's message unchanged | M | Every encrypted fixture (each producer and cipher, §6.1) opens with its password and matches the plaintext zip byte-for-byte; wrong passwords and tampered files fail cleanly |
| **E3** | **Save protected `.pptx`.** The Agile writer, File › Passwords… and Review › Protect Presentation, keeping a file's password on Save, password to modify (`modifyVerifier`) with a Read Only choice on open. (Encrypted AutoRecover was decided against: protected presentations stay out of AutoRecover, E3 notes) | M | msoffcrypto-tool and POI decrypt what we write to our own zip byte-for-byte; PowerPoint opens it with the password (`powerpoint-check.sh` learns to answer the prompt) |
| — | **Release**: E1–E3 ship on their own | | |
| **P1** | **`.ppt` container.** Current User, the UserEditAtom chain and persist directory (newest wins; unreached records ignored), the record tree, RC4 CryptoAPI with the default password then the prompt; the document types, the converted banner and the import report. Slides open blank but counted, with slide size and notes size | M | Every `.ppt` fixture opens with the right slide count; the Govdocs1 crash run is clean |
| **P2** | **Text, masters and slides.** Text in shapes and in the slide list, the paragraph and character runs, master text styles by text type and level, the font collection, colour schemes, placeholders and their inheritance, title/notes/handout masters, headers and footers with date fields ([MS-OSHARED] formats), notes pages, hyperlinks, backgrounds. The OOXML theme and layouts PowerPoint 2007+ embeds are used when present | L | Text per slide matches POI's dump and macOS's Office importer (`mdimport`) on every fixture |
| **P3** | **Shapes.** OfficeArt property tables, anchors, groups, the 203 shape types mapped to DCModel presets (a generated table with each adjust value rescaled from 21,600 units, checked shape by shape), freeforms, connectors, fill, line and shadow, WordArt, tables (a group flagged as a table) | L | Shape count, type and position per slide match POI's dump; the alpha gate's render check passes on converted decks |
| **P4** | **Pictures and objects.** The BLIP store and the Pictures stream, zlib-compressed metafiles through DCMetafile, picture fills and bullets, PICT (§8), sounds and linked movies, OLE objects as `opaque` shapes with their preview, charts as their preview picture, comments | M | Every picture in the fixtures lands with the right bytes; the import report lists each object that became a picture |
| **P5** | **Slide show.** Transitions; animations from the OOXML timing PowerPoint 2007+ embeds where present (DCPPTX's timing reader), then the PowerPoint 2002+ timing tree, then 97/2000 per-shape effects mapped to the nearest | L–XL | Transitions match by type and speed; a file's animations play in order with the right effects for the common entrance, emphasis and exit effects |
| **P6** | **Hardening and release.** The crash corpus at full size, fuzzing of every record reader, bounded work on hostile files, the docs and release notes | S | No crash or hang across the corpus; EVALUATION and the release notes drop "Not supported" for both |

[MS-PPT]'s animation chapter alone is 125 pages, and its text chapter 66; most of [MS-ODRAW]'s 373 pages of
properties are Word and Excel borders, positioning and toolbars that a PowerPoint reader skips.

### E3 notes (2026-10-30)

- **Writing** (`OfficeCrypto.encrypt`): Agile as PowerPoint 16 writes it, AES-256, SHA-512, 100,000 rounds, the
  HMAC, a version 4 compound file. The `\x06DataSpaces` streams match POI's byte for byte.
  - `Tools/legacy/check-encrypt.sh` has msoffcrypto-tool and POI decrypt every corpus deck we encrypt, with every
    kind of password. Both get the exact zip back.
  - Not checked: PowerPoint opening a file we wrote. That needs a person to type the password, because rules keep me
    from typing passwords into PowerPoint.
- **The password to modify** (`ModifyVerifier`): a SHA-512 verifier, 100,000 rounds, in `presentation.xml`. Its
  hash order (counter appended) was settled against PowerPoint's own files.
  - The engine writes it on save and reads it on open. Without the password, a file opens as an untitled
    "(Read-Only)" copy; `file.open {modifyPassword}` opens it for editing.
  - The app asks like PowerPoint's *Password to Modify*: Modify, Read Only, Cancel.
- **Saving:**
  - As `.pptx`, `.potx` or `.ppsx`, a protected presentation keeps both passwords.
  - As `.deckcraft` or an outline it can't, so the document has none afterwards and the status line says so.
  - Exports are unprotected copies.
- **Setting passwords:** File › Passwords… and Review › Protect Presentation (a new group) open the Passwords sheet,
  with PowerPoint's two checkboxes and each password typed twice.
  - Empty fields keep a password that's already set. A mismatch, an empty new password or more than 255 characters
    asks again.
  - `file.passwords {password?, modifyPassword?}` sets them from scripts and the control channel.
  - A change makes the document need saving (`DocState.protectionEdited`).
  - `file.passwords` is an app command, because the engine's command list is pinned to deckcraft's.
- **Decided against: encrypted AutoRecover.** A protected presentation stays out of AutoRecover. Encrypted recovery
  files would need a password prompt during crash recovery. The property that matters holds either way: a protected
  presentation is never written in the clear.
- **Checked live:**
  - **Over the control channel:** set both passwords; save (the file is encrypted); reopen with no password (it asks),
    with the open password only (it opens read-only), and with both (it opens for editing).
  - **In the test build's windows:** the Passwords sheet, unticking a password, the Password to Modify prompt, and
    Read Only giving a "(Read-Only)" window.
  - **Not automated:** typing into the secure fields, which computer use can't do.

### E2 notes (2026-10-30)

- **DCOffCrypto** (`Packages/DCOffCrypto`, its PORT-NOTES): Agile and Standard decryption with CommonCrypto, the
  HMAC integrity check, and refusals by name for Extensible and IRM files. It has 8 tests, which decrypt:
  - all 36 encrypted `.pptx` fixtures, to their exact plaintext;
  - PowerPoint's 9 protected copies, to msoffcrypto-tool's bytes.

  Wrong passwords, tampering, cancelling and seeded damage fail cleanly.
- **The engine:**
  - `FileCommands.openProtected` reads a protected file, and `file.open` and `file.openBytes` take `password`.
  - The new errors are `EngineError.passwordRequired` and `wrongPassword`.
  - The password lives in `DocState.protection` only. A `password` parameter is dropped from the journal, and a
    reply says `"protected": true` only for a protected file, so every other reply stays deckcraft's byte for
    byte.
  - The commands' parameter text stays deckcraft's, because a registry parity test pins it.
- **Until E3:**
  - Save, Save As and `file.saveBytes` refuse a protected presentation, with a reason, rather than drop its password.
  - AutoRecover leaves it out.
  - Exports still work.
- **The app:**
  - **The prompt:** `PasswordPrompt` asks before the document's window, naming the file, with a secure field,
    Cancel and Open. It asks again after a wrong password, and Cancel opens nothing, with no error.
  - **The control channel:** `app.open {path, password}` never prompts, and `ui.inspect`'s documents carry
    `protected`.
  - **dccli:** reads `DCCLI_PASSWORD`.
- **Checked live:**
  - In the development build, over the control channel: no password, a wrong one, the right one (it opens, marked
    protected), and Save refused.
  - In a signed test build: the prompt appears and Cancel works. Typing into the prompt couldn't be automated,
    because computer use is blocked while secure input is active. Entering the password by hand is the one step
    left for the operator.
- **Fixed on the way:** `Tools/l10n/sync.sh` had stopped since `b4b79c3`: the Spotlight entity's display title was
  a string literal that `l10n.py` takes for a main-bundle lookup. It's now built from the file name.

### E1 notes (2026-10-30)

- **DCCFB** (`Packages/DCCFB`, its PORT-NOTES): `CompoundFile` reads, `CompoundFileWriter` writes, version 3 or 4.
  It has no dependencies. 12 tests: round trips at every size boundary in both versions, a DIFAT, names ordered
  as [MS-CFB] 2.6.4 says, and damaged input from three sources (the hostile fixtures, deckcraft's 400 CFB parity
  inputs, and 6,000 seeded mutations). None traps or hangs.
- **Against olefile:** all 105 compound files in the fixtures, and PowerPoint's 15 protected copies, read with the
  same entries and the same bytes. The references come from `fixtures.py olefile-list`, now part of
  `make-fixtures.sh`.
- **What we write:** `Tools/legacy/check-cfb-writer.sh` has olefile and POI (`PoiTool list-cfb`) read five written
  files. Both see every entry with its bytes.
- **Found:** PowerPoint 16 writes its protected `.pptx` as **version 4** (4096-byte sectors), where POI and
  msoffcrypto-tool write version 3. E3 picks the version our encrypted files use.
- **A change from the plan:** DCPPTX's `CFB.swift` stays. It is deckcraft's sniffer, pinned by parity vectors,
  including its fallback scan for stream names in a file it can't walk. The engine's sniffing moves to DCCFB in E2.

### E0 notes (2026-10-30)

- **Tools**, all in `~/Library/Caches/DeckCraftNative/legacy-tools/` or installed by Homebrew, none in the repo:
  LibreOffice 26.8.2 (cask), OpenJDK 27 (the `openjdk` formula; the Temurin cask needs an administrator password),
  Apache POI 6.0.0's jars from Maven Central (each checked against its SHA-1; POI no longer ships a binary bundle),
  and a venv with msoffcrypto-tool 6.0.0, olefile 0.47 and ppt2pptx 0.4.2.
- **Specs**: [MS-CFB] v20210625 (46 pp) and [MS-OLEPS] v20210625 (67 pp) are in `../OfficeFileFormatsProtocols`.
  [MS-CFB]'s 2024 edition on Microsoft's site is a rights-protected PDF that ordinary readers can't open.
- **Fixtures**: `Tools/legacy/make-fixtures.sh` (`--quick` for the corpus decks only) makes 363 files in
  `../DeckCraftNative-Fixtures/legacy/`: 60 `.pptx`, their 60 `.ppt`, 45 encrypted files, 60 hostile copies and
  138 reference readings. Every encrypted `.pptx` decrypts to its plaintext byte for byte with both
  msoffcrypto-tool and POI, and both POI and ppt2pptx read every `.ppt`, the RC4 CryptoAPI ones included.
  `PoiTool.java` (encrypt, decrypt, dump) and `fixtures.py` (describe, mutate, manifest) are its helpers.
- **Dropped producers**: LibreOffice can't encrypt here, because macOS 27 kills its bundled Python when run outside
  the app ("Launch Constraint Violation"), so a UNO script can't run. Keynote Creator Studio 15.3 crashed on an
  AppleScript `open` of a `.pptx` (an uncaught exception converting the file argument). Neither is needed: POI,
  msoffcrypto-tool and PowerPoint cover every method.
- **PowerPoint steps** (finished 2026-10-30 with the operator watching): `Tools/legacy/powerpoint-protect.sh` made 18
  protected files from the corpus sample, content and charts decks in `~/Library/Caches/DeckCraftNative/
  powerpoint-protected/`. PowerPoint is sandboxed: it asks "Grant File Access" for each new folder it saves into,
  so the script works through one fixed `work/` folder, granted once (a fresh temporary folder per file brought a
  prompt per file). Every `.pptx` with a password to open decrypts to identical bytes with POI and
  msoffcrypto-tool; POI and ppt2pptx read every `.ppt` with the same slide count. msoffcrypto-tool 6.0.0 fails on
  PowerPoint's `.ppt` ("write_stream: data must be the same size"; its `.ppt` support is marked experimental), so
  POI and ppt2pptx are the `.ppt` references. The observations are in §2.

## 6. Testing and oracles

### 6.1 Test files (all made, none PowerPoint-saved)

- **`.ppt`**: DeckCraftNative's own corpus and engine decks, exported to `.pptx` by `dccli`, converted by LibreOffice
  (`soffice --headless --convert-to ppt`). Text, shapes, pictures, tables, notes and masters are covered; the
  incremental-save chain isn't (LibreOffice writes one save), so P1 also builds record streams by hand from the
  spec's structures.
- **Encrypted `.pptx`**: the corpus decks encrypted by POI (Agile with AES-128/SHA-1 and AES-256/SHA-512, both at
  100,000 rounds; Standard AES-128) and msoffcrypto-tool (Agile AES-256/SHA-512), with passwords in plain ASCII,
  with accents, with a character outside the BMP (a UTF-16 surrogate pair) and at Office's 255-character maximum.
  LibreOffice and Keynote were tried and dropped (E0 notes).
- **Encrypted `.ppt`**: LibreOffice's `.ppt` files encrypted by POI with RC4 CryptoAPI (LibreOffice can't).
- **Encrypted by PowerPoint** (local-only, §1): a handful of DeckCraft's decks saved by PowerPoint with a password to
  open, a password to modify, and both, as `.pptx` (Agile, PowerPoint's current default) and as `.ppt` (RC4
  CryptoAPI). They are the real-world target: E2 and P1 aren't done until each opens. A script
  (`Tools/legacy/powerpoint-protect.sh`) makes them from the committed decks, so they can be regenerated rather than
  kept.
- **Hostile files**: truncated, cyclic, oversized, wrong-length and nonsense versions of all of the above, made by a
  mutation script, plus the spin count at the spec's 10,000,000 maximum (must stay cancellable).

They live in `../DeckCraftNative-Fixtures/legacy/` (local, never pushed), with a manifest of how each was made.

### 6.2 Independent readers

- **Compound files**: olefile lists streams and their bytes.
- **Decryption**: msoffcrypto-tool and POI decrypt the same file; all three plaintext zips must be identical.
- **`.ppt` content**: a small POI program dumps slides, shapes (type, anchor) and text runs as JSON, compared with
  `dccli info`. macOS's `Office.mdimporter` gives text per file as a second opinion.
- **PowerPoint**: the sweep's AppleScript counts slides and shapes in each `.ppt` fixture, as it does for `.pptx`
  today (black box: counts only, nothing saved).

### 6.3 The never-crash rule

Every length, count, offset and index in these formats comes from the file. Each reader bounds them, caps
allocations, limits recursion (OLE objects nest compound files) and checks every chain for cycles. A crash found by
the corpus or the fuzzer lands with its regression test (CLAUDE.md).

### 6.4 The crash corpus

Govdocs1 `.ppt` files, downloaded outside the repo and the fixtures (in `~/Library/Caches/DeckCraftNative/govdocs`),
picked by signature and a `PowerPoint Document` stream. A `Tools/legacy/crash-run.sh` opens each through `dccli` with
a time limit and records only: opened, failed cleanly (with the reason), crashed, or timed out. Nothing from these
files is compared, committed or shown.

## 7. Risks

| Risk | Mitigation |
|---|---|
| **PICT pictures**: modern macOS has no PICT renderer; DCMetafile handles EMF and WMF only | P4 decides between a QuickDraw subset (bitmaps and simple vectors) and the shape's grey placeholder with a report entry (§8) |
| **Incremental saves** aren't in any generated file | Hand-built record streams in P1, and the crash corpus exercises them in the wild |
| LibreOffice's `.ppt` files are simpler than PowerPoint's (fewer PP9/PP10 tags) | Hand-built streams for the tag extensions; the crash corpus; PowerPoint's counts in the sweep |
| [MS-OFFCRYPTO]'s wording on decrypting the `.ppt` Pictures stream is unusual | Cross-check with POI and msoffcrypto-tool on E0's RC4 CryptoAPI files, and with PowerPoint's own encrypted `.ppt`, before trusting it |
| Animation is big and in two generations | P5 starts with the embedded OOXML timing, which DCPPTX already reads; the rest maps to the nearest effect |
| Password handling | Passwords never logged, never in DCModel, `.deckcraft`, MCP replies or the clipboard; key buffers cleared after use where Swift allows; AutoRecover off or encrypted |
| A spin count near the maximum takes seconds | Derivation off the main thread, cancellable, with the sheet showing progress |
| A converted `.ppt` loses things PowerPoint keeps | The import report says what, per slide |

## 8. Later decisions

- **PICT**: QuickDraw subset or placeholder (decide in P4, with counts from the crash corpus).
- **Encrypted `.deckcraft`**: possible later; for now saving a protected presentation as `.deckcraft` warns.
- **Charts from MS Graph** as real charts ([MS-OGRAPH] over [MS-XLS]) rather than their preview: only if the import
  report shows they're common.
- **`.ppt` writing**: not planned (§9.1).

## 9. Decisions (the operator, 2026-10-30)

1. **`.ppt` is converted, not edited in place.** It opens as an untitled copy; Save offers `.pptx` or `.deckcraft`.
   No `.ppt` writer.
2. **Protected `.pptx` opens and saves**: File › Passwords, and a file opened with a password keeps it on Save.
3. **Test tools approved**: LibreOffice, a JDK with Apache POI, msoffcrypto-tool in a venv, and the [MS-CFB] and
   [MS-OLEPS] downloads; further research into other tools is approved where needed.
4. **A local-only crash corpus of real `.ppt` files** (Govdocs1) is approved, for crash and hang checks only, never
   committed and never compared for content.
5. **PowerPoint may make password-protected test files** for testing, as needed. Kept local-only (§1, §6.1).
6. Order (recommended in this plan): encryption first (E1–E3, its own release), then `.ppt` (P1–P6).
