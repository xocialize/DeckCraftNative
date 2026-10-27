# DCAutomation — port notes

Port of deckcraft `crates/mcp` (the MCP server), the JSON control channel of `crates/ui-egui/src/control.rs`, the
app's loopback control server (`apps/deckcraft/src/control_server.rs`), and `apps/deckcraft-cli` (as `Apps/dccli`,
see [dccli](#dccli)), at the pin in `Tools/oracle/pin.env`. **Status: done** (Wave 4, last step; the control server
at the start of Wave 5, and the pointer with DCEngine's `Session.pointer`; see [The pointer](#the-pointer)).

- **Code:** about 2,600 lines in `Sources/DCAutomation` and 1,200 in `Apps/dccli`; 2,600 lines of tests.
- **Tests:** DCAutomationTests 52, dccliTests 31, with 201 parameterised cases; all pass, with 1 known issue (one PDF page; see
  [Divergences](#divergences)); dccliTests' `PointerParityTests` adds 7 pointer sessions. `swift test --filter 'DCAutomationTests|dccliTests'` takes
  about 8 minutes in debug. Every
  `#[test]` of `crates/mcp` (25), `control.rs` (1 of 2), `control_server.rs` (14), `deckcraft-cli` (11) and
  `automation_args.rs` (3) is ported.

## File map

| Rust | Swift (`Sources/DCAutomation`) | Notes |
|---|---|---|
| `mcp/src/lib.rs` | `Backend.swift` | `Automation.defaultPort`, `controlAddr` |
| `mcp/src/backend.rs` | `Backend.swift` | `Backend` (protocol), `Remote` on BSD sockets, `IOFailure` (Rust's `io::Error` text), `Sockets`, `RustParse` |
| `mcp/src/headless.rs` | `Headless.swift` | `Headless`; `ControlInput` (pointer kinds, mods, tool names, serde's `ToolKind`), shared with the control channel |
| `mcp/src/tools.rs` | `MCPTools.swift` | `ToolResult`, `MCPTools.definitions` (deckcraft's JSON values), `MCPTools.call` |
| `mcp/src/server.rs` | `MCPServer.swift`, `MCPTransport.swift` | `MCPCore` (`request`, `notification`), `MCPServer` (framing on the SDK), `LineReader`, `serve` |
| `ui-egui/src/control.rs` | `Control.swift` | `ControlRequest` (`take`/`abandon`), `ControlReply`, `ControlOutcome`, `ControlHost`, `Control.handle`, `ControlChannel`, `HeadlessControlHost` |
| `apps/deckcraft/src/control_server.rs` | `ControlServer.swift` | `ControlServer` (`Limits`, `tryReceive`/`receive`, `stop`), `ControlChannel.serve`, `ControlQueue` (`sync_channel`), `ControlStream` (`read_line`, `close_politely`) |
| — | `EngineThread.swift` | the 32 MiB engine thread |
| — | `JSONText.swift` | `JSON.pretty`: serde_json's `to_string_pretty` |
| `mcp/src/tests.rs` | `Tests/DCAutomationTests/MCPServerTests.swift` | all 9 |
| `backend.rs` tests | `Tests/DCAutomationTests/RemoteTests.swift` | all 9, plus address errors |
| `control.rs` tests | `Tests/DCAutomationTests/ControlTests.swift` | `take_and_abandon_are_exclusive`; `screenshot_reply_is_path_only_or_explicitly_inline` is the window's (Wave 5) |
| `control_server.rs` tests | `Tests/DCAutomationTests/ControlServerTests.swift` | all 14, plus every reply byte for byte, `stop`, and `Remote` against a headless app |
| — | `Tests/DCAutomationTests/FramingTests.swift`, `LargeStackTests.swift` | framing replies byte for byte, lifecycle, resources, line reading; deep groups |

## The MCP server on swift-sdk

deckcraft's server is hand-written JSON-RPC; its replies are serde_json `Value`s with sorted keys. Here
`modelcontextprotocol/swift-sdk` (0.12.1, as PhotoCraftNative) carries the requests, following PhotoCraftNative's
`MCPTransport` pattern (a reader thread, an in-memory transport pair, a rewrite of what goes out):

- **`MCPServer.handleLine`** is deckcraft's `handle_line` / `handle`: DCCore parses the line with serde_json's rules
  and messages, and answers what isn't a request itself — parse errors, batches (each item handled, replies
  collected), non-objects, missing `method`, a bad `id`, responses (ignored) and notifications.
- **Requests go through the SDK's `Server`**, one at a time and in order (deckcraft's loop is single-threaded; the
  SDK would otherwise run pipelined requests concurrently). Its handlers (`initialize`, `ping`, `tools/list`,
  `tools/call`, `resources/list`, `resources/templates/list`, `resources/read`, registered after `start` so they
  replace the SDK's defaults) run `MCPCore.request` on the engine thread.
- **Exactness.** The SDK's `Value` loses serde_json's integer/float distinction (`600.0` comes back as `600`) and
  its `ID` takes only strings and `Int`s (deckcraft echoes `1.5` or `2^64−1`). So the request's exact parameters
  and the handler's exact outcome travel beside the SDK (`Exchange`), the SDK sees a sequence number as the id,
  and the reply line is written from the exact outcome with the client's own id, keys sorted, by DCCore's writer.
  Through the SDK alone the handlers still work on the SDK's decoded values.
- **The same bytes as deckcraft.** `FramingTests` holds deckcraft-cli's own replies to 14 lines; dccliTests runs a
  36-line agent session through both binaries and compares every reply byte for byte (`initialize`, `tools/list`,
  resources, 25 tool calls, errors), with saved files' sizes masked (DCZip's deflate).
- **Interop.** dccliTests connects the SDK's own `Client` to `dccli mcp` over stdio (`StdioTransport`): it
  initializes, lists the tools, calls them and reads a resource.

## Large stacks

Engine commands recurse once per group level (shape-tree walks, rendering, the file coders), and 32 nested
groups — the most `arrange.group` makes — overflow a Swift concurrency thread's 512 KiB in a debug build.
`EngineThread` is a serial thread with a 32 MiB stack (`PPTX.onLargeStack`'s size): the MCP server runs every
backend call there, `ControlChannel` every control request, and `dccli` its whole run (`EngineThread.onLargeStack`).
Non-Sendable state (`Session`, backends, hosts) is confined to it (`EngineConfined`). `LargeStackTests` builds 32
nested groups through `MCPServer` and through `ControlChannel` from Swift Testing's concurrency threads, then draws,
saves, reopens, copies and pastes them; dccliTests does the same through the `dccli mcp` process.

## The control channel

`Control.handle(host, method, params)` is `control.rs`' `handle` for every method that needs no window:
`engine.execute` / `ui.menu.invoke` / `command`, `engine.commands` (engine commands plus the host's UI commands),
`document.inspect`, `ui.inspect` (the host's), `ui.pointer`, `ui.key` (after `ControlHost.interceptKey`, the slide
show and animation preview's turn), `ui.text`, `ui.tool.select`, `ui.render` (`render_png`, written by the host),
`app.open`, `app.save`, `app.export`. Everything else goes to `ControlHost.handleUI` (`ui.ime`, `ui.move`/`click`/
`drag`, `ui.set`, `ui.dialog.*`, `ui.screenshot`, `ui.resize`, `ui.focus`, `show.*`, `app.quit`): the app plugs in
there in Wave 5. Replies are `{"ok": true, "result"}` / `{"ok": false, "error"}`; `ControlRequest.take` and
`abandon` keep a timed-out request from running late (#719). `ControlChannel` runs requests on its engine thread
and skips abandoned ones; `HeadlessControlHost` is a host without a window (tests, and the fake app in dccliTests
that `mcp --connect` and `app` drive).

Not ported: `save_screenshot` belongs with the window's capture budget (`capture.rs`).

## The control server

`ControlServer` is `control_server.rs`: 127.0.0.1 only, one request per line, one reply per line, under deckcraft's
`Limits` (16 clients, 256 MiB lines, 64 queued, idle 600 s, write 30 s, reply 60 s). Behaviour and reply texts are
deckcraft's, byte for byte (`repliesAreDeckcraftsBytes` holds every literal): a line that isn't a JSON object with a
string `method` (HTTP, binary, bad JSON) gets one error and the connection closes politely (FIN, then a drain of at
most 64 KiB until the write timeout); a connection past the limit reads `busy` and is drained on a thread of its own
(at most 16 at once, 250 ms each); an oversized line and an idle socket close the connection; a full queue answers
`busy`; a timed-out request still queued is abandoned (it never runs late, #719), one already taken reports an
unknown outcome.

- **BSD sockets**, as `Remote`: `SO_RCVTIMEO`/`SO_SNDTIMEO` are Rust's `set_read_timeout`/`set_write_timeout`
  exactly (per read and per write, a sub-microsecond timeout rounded up to 1 µs as Rust does), `shutdown(SHUT_WR)`
  is the polite close, and each connection is a blocking thread as in deckcraft. Network.framework has no
  per-read timeout or half-close-then-drain without rebuilding them on timers.
- **The app's side.** The server answers nothing: requests wait in a bounded queue (`sync_channel`) and `wake`
  (egui's `request_repaint`) runs after each is queued, on the connection's thread. The app's main thread drains
  `tryReceive()` and answers each with `take()`, `Control.handle(host, method, params)` and `reply.send` (a
  `.screenshot` outcome once the window has captured). Bind failure throws; deckcraft logs
  `control server failed to bind 127.0.0.1:{port}: {e}` and runs without the channel.
- **Headless.** `ControlChannel.serve(port:limits:)` is the server with one consumer that answers each request on
  the channel's engine thread before taking the next, as the app's main thread does. dccliTests' `FakeApp` is now
  exactly that (it was a hand-written socket loop): `dccli app` gave the same stdout, stderr and exit code against
  both for a 12-call session, and the oracle's `deckcraft-cli app` drives it too.
- **Stopping.** deckcraft's server lives as long as the app; `stop()` (and `deinit`) closes the listener through a
  self-pipe, shuts the connections being served and drops the queue.

## The pointer

`ui.pointer` and the MCP `pointer` tool validate their events as deckcraft does and feed each to DCEngine's
`Session.pointer` (tools.rs, ported at the start of Wave 5; DCEngine's PORT-NOTES, "Pointer") through `drivePointer`
in `Headless.swift`; an engine error is the request's error, as `e.to_string()` is in deckcraft. The divergence
this section used to record (`pointerNotPorted`) is gone: `agent_builds_a_deck` drags its shape with the pointer
and passes plainly, `connectedToAnApp` (dccliTests) presses the fake app's canvas, and seven pointer sessions
(`Tools/oracle/pointer-sessions/`, 992 lines: every pointer kind, tool and drag, snapping on and off, modifiers,
pressures) give deckcraft-cli's replies, every one, and its deck's `presentation` byte for byte
(`PointerParityTests`; DCEngine's PORT-NOTES has the table).

## Divergences

- **Pictures.** `render_slide` and `ui.render` PNGs are ImageIO's (DCEngine's `ImageEncoding`): same pixels' sizes,
  other bytes. Saved files' sizes in `save_presentation` answers are DCZip's deflate.
- **Bounded lines.** deckcraft reads MCP lines without limit; here a line is at most 256 MiB (an oversized line ends
  the session with an error).
- **Ordering.** As in deckcraft, requests run one at a time in arrival order; a `notifications/cancelled` can't stop
  a request already running.
- **PDF pictures.** `effects.pdf` page 3 scores 74.3: DCRender's vector PDF keeps an 8 px gradient picture at its
  size (`/Interpolate true`) and CoreGraphics, drawing the page (as Preview does), magnifies it in soft blocks,
  where deckcraft's page is a 200 dpi picture of the slide. DCRender's PORT-NOTES records the choice (its raster
  canvas enlarges such pictures first; PDF output keeps the original). The parity test marks that page
  `withKnownIssue`.
- **Control server.** A request the app drops without answering is noticed at once in Rust (its reply channel
  disconnects) and only at the reply timeout here (`ControlReply` has no drop signal); the reply text is the same.
  Requests queued when the server stops wait out their reply timeout in the same way. A client thread that can't be
  started isn't detected (Foundation's `Thread`), so there is no "could not start a client thread" log.
- **Versions.** `serverInfo.version` and `dccli --version` say 0.11.1, deckcraft-cli's version, since the
  answers are its answers.

## Lower-layer changes

- `DCEngine/Tools.swift`: `Session.setTool` (deckcraft's `set_tool`, 6 lines), for `ui.tool.select`. `tool.drag` is
  internal to DCEngine, so automation couldn't drop a drag itself.
- `DCEngine/ImageEncoding.swift`: a GIF ImageIO writes without a loop block is labelled `GIF87a` although each frame
  has a Graphic Control Extension (GIF89a only); the header now says `GIF89a`, as deckcraft's does. Proven by
  `export_tool_lists_gif_and_its_options` (MCP) and `exports_an_animated_gif` (CLI), which check the header.

## dccli

`Apps/dccli` is deckcraft-cli on swift-argument-parser: `info`, `render`, `render-transition`, `convert`, `run`,
`commands`, `describe`, `app`, `mcp`, `bench`, `links`, `help`, `--version`.

| Rust (`apps/deckcraft-cli/src`) | Swift (`Apps/dccli`) |
|---|---|
| `main.rs` `main` | `DCCLI.swift`: the `@main` `ParsableCommand`, its subcommand table and dispatch |
| `main.rs` (the subcommands) | `CLI.swift` |
| `help.rs` | `Help.swift` |
| `automation_args.rs` | `AutomationArgs.swift` |
| tests | `Apps/dccliTests/CLITests.swift` (in process), `ParityTests.swift`, `MCPProcessTests.swift` (the binaries) |

- **ArgumentParser** holds the subcommand table and routes; each subcommand takes its arguments as they come
  (`captureForPassthrough`, no help names) and reads them as deckcraft-cli does, so flags, messages and exit codes
  are deckcraft-cli's (exit 1 on failure, where ArgumentParser would use 64). `help`, `--help`, `--version` and an
  unknown subcommand are answered before parsing, in deckcraft-cli's order.
- **Text.** Help pages, messages and the `describe` text name `deckcraft-cli`, word for word: the parity is to the
  byte.
- **I/O.** Files the CLI writes itself use POSIX calls so errors read as Rust's `io::Error`
  (`No such file or directory (os error 2)`); a closed stdout exits 0, as deckcraft's `outln!` does. `bench`'s peak
  memory is Linux-only in deckcraft, so it prints none here either.

**Parity** (`ParityTests`, `MCPProcessTests`; they skip without the oracle binary or the corpus):

| What | Compared | Result |
|---|---|---|
| `commands` | the corpus's `commands.txt` | byte-identical (330 lines) |
| `describe ID` | the oracle, all 330 commands | identical |
| help pages, `--version`, `links`, unknown subcommands | the oracle, 27 invocations | identical stdout, stderr, exit code |
| bad input | the oracle, 72 invocations (every subcommand's missing, malformed and unknown arguments, unreadable and unwritable files, bad JSON, failing commands, unreachable apps, bad roots) | identical stderr, stdout and exit code |
| engine scripts (44) | `engine/<name>.results.txt`, `.errors.txt`, `.deckcraft` | answers, all 238 refusals and decks identical; the 6 `*-native-*` scripts compared as DCEngineTests compares them |
| corpus scripts (8), `run --sample` | the oracle's `--print` output; the corpus decks | identical |
| `info` | `<deck>.info.json`, 9 decks | byte-identical |
| `convert` → `.pptx` | `<deck>.pptx` | every part byte-identical |
| `convert` `.pptx` → `.deckcraft` | `<deck>.from-pptx.deckcraft` | presentation and media identical |
| `convert` → `.md` | `<deck>.md` | byte-identical |
| `convert` → `.png`; `render --all --scale 2` (43 slides); `render-transition` (15 transitions × 3 frames) | file names, sizes, printed lines; SSIMULACRA2 at 480 px wide, floor 85 | PNG ≥ 96.0, slides ≥ 94.6, frames ≥ 92.8 |
| `convert` → `.pdf` | the oracle's page count; each page drawn at 2 px/pt against the oracle's slide picture | same page counts; every page ≥ 95.1 but one (below) |
| `mcp` | the oracle's 35 replies to a 36-line session | identical but saved files' sizes |
| `mcp --connect`, `app` | the control server over a headless channel (`FakeApp`); the oracle's `app` against another | identical |

One test-harness lesson: Foundation's `Process` passes arguments in their file-system representation, which
decomposes `Ü` into `U` + U+0308; the harness spawns with `posix_spawn` so a script's `--cmd` reaches dccli byte
for byte.
