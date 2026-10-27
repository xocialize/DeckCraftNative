# DCAnim — port notes

Port of deckcraft `crates/anim` (about 6,000 lines with tests) at the pin in `Tools/oracle/pin.env`. Status:
**Wave 4, done.** Pure logic, as in the Rust: no rendering and no UI toolkit. Every function takes hostile numbers
(NaN, infinities, huge or negative times) and never traps.

## File map

| Rust | Swift |
|---|---|
| `lib.rs` (`AnimState`, `clampf`) | `AnimState.swift` (plus the Rust semantics the crate uses: `rem_euclid`, `total_cmp`, byte-wise `starts_with`/`ends_with`/`contains`, a stable sort) |
| `easing.rs` | `Easing.swift` |
| `effects.rs` | `Effects.swift` |
| `path.rs` | `MotionPath.swift` |
| `timeline.rs` | `Timeline.swift` |
| `show.rs` | `Show.swift` |
| `interact.rs` | `Interact.swift` |
| `transition.rs` | `Transition.swift` |
| `transition_fx.rs` | `TransitionFX.swift` |
| `transition_geom.rs` | `TransitionGeom.swift` |
| `mesh.rs` | `Mesh.swift` |
| `morph.rs` | `MorphFrame.swift` |
| `tests.rs` | `Tests/DCAnimTests/AnimTests.swift` (64 tests) |
| `tests_interact.rs` | `Tests/DCAnimTests/InteractTests.swift` (14) |
| `transition_tests.rs`, the tests in `mesh.rs` and `path.rs` | `Tests/DCAnimTests/TransitionTests.swift` (12 + 3 + 1) |
| — | `Tests/DCAnimTests/AnimVectorTests.swift`: bit-exact parity with deckcraft-anim (8 tests) |

All 94 Rust tests are ported, with the Rust tolerances.

## API

What the engine, the renderer and the app call. Names follow the Rust in Swift's casing.

- **Timeline.** `Timeline(slide, w, h)` or `Timeline(slide, w, h, scheme:, xfrmOf:)`. Then:
  - steps: `steps`, `stepIsAuto(i)`, `stepDuration(i)`, `totalDuration`;
  - effects: `effects` (`EffectTiming`s), `animatedShapes`, `paragraphTargets(shape)`;
  - the play-all clock: `locate(time)`, `startOf(anim)`, `stateAt(shape, para, time)`;
  - media: `mediaCues(step, from, to)`;
  - triggers: `triggerShapes`, `triggerSteps(shape)`, `triggerStepDuration(shape, i)`;
  - state: `state(shape, para, step, t)`, `stateWith(…, triggers)` and `stateOrdered(…, triggers, stamps)`. Each
    returns an `AnimState` (visible, opacity, offsets, scales, rotation, `clip: SIMD4<Double>?`, `tint`), with
    `compose` and `sanitized`.
- **Show state machine.** `ShowState(pres)`, `ShowState.startAt(pres, i)` and `ShowState.playCustom(pres, name)`
  start a show. The state is `slide`, `step`, `playing`, `ended` and `zoom`.
  - Navigation (`mutating`, each returning a `ShowAction`): `next`, `prev`, `stepDone`, `goto(i)`.
  - Links: `follow(pres, action, lastViewed)` and `followLink(pres, hyperlink, lastViewed)` return a
    `LinkJump`.
  - Clicks: `click(pres, timeline, hits, visible, now, lastViewed)` returns a `Click`. It uses `tick(timeline,
    now)`, `target(…)` and `top(…)`.
  - Drawing: `animState(timeline, shape, tMain)`, `triggerPlays`, `triggerStamps`, `triggerPlaying`.
  - Timings: `advanceAfter(pres)`, `autoAdvanceDue(pres, elapsed)`.
  - Lookahead: `peekNext`, `firstIndex`, `lastIndex`, `customName`.
  - Static helpers: `ShowState.timeline(pres, i)`, `ShowState.steps(pres, i)`, `showOrder(pres)`; `safeURL` is
    re-exported from DCModel, as deckcraft re-exports it.
- **Transitions.**
  - `transitionFrame(kind, option, t, aspect)` and `transitionLayers(kind, option, t)` (16:9) return `[Layer]`.
    A `Layer` is a `source: Source`, a `src` rect, a `quad` and `uv` (a `Quad` of `UnitPoint`s), `alpha` and per-corner
    `fade`.
  - `usesSlideParts(kind, option)` tells whether a frame needs the slides rendered in parts.
  - `layerMesh(layer)` returns the vertices and triangles to draw: projective subdivision for cards in
    perspective. The Metal compositor and DCRender's CPU compositor both draw these meshes.
- **Morph.**
  - `morphFrame(pres, a, b, t, hiddenB)` returns a `MorphFrame`: `shapes` with old/new flags, `opacity` and
    `opacityOf(id)`, `mix`, `text` (`MorphText`) and `paths` (`MorphPath`).
  - `morphPairs(a, b)`, `morphXfrm(a, b, t)` and `morphCrop(…)`.
  - DCRender's `renderTransition` and `renderBlend` draw a frame.
- **Also:** `ease(p, accel, decel, bounce)`, `MotionPath.parse(s)` (`points`, `length`, `at(p)`), and
  `defaultPath(effect, option)`.

## Divergences

- **Names.**
  - Rust's `Sequence` is `AnimSequence`, so it doesn't shadow Swift's `Sequence` protocol.
  - The `None` variants of `ShowAction`, `LinkJump` and `Click` are `none_`, as elsewhere in the port.
  - Zero-argument getters are properties: `steps`, `effects`, `triggerShapes`, `totalDuration`, `isEmpty`,
    `animatedShapes`, `triggerPlays`, `triggerStamps`, `triggerPlaying` and `customName`.
- **Fixed-size arrays.** Rust's `[f64; 4]` and `[[f64; 2]; 4]` are `SIMD4<Double>` and `Quad`, whose subscript
  can't trap. A picture's crop stays `[Double]`, as the model has it; `morphCrop` reads a short one as zeros.
- **No serde.** `AnimState`, `Layer` and `Source` derive `Serialize` in Rust. Nothing serialises them, so they
  have no JSON coding here.
- **Sharing.** `Timeline` shares each animation's effect spec between its paragraph effects through a class,
  where Rust uses an `Arc`. The default colour scheme is built once, not per timeline.
- **Strings compare as bytes.** Rust compares strings as bytes; Swift's `==` and `hasPrefix` use canonical
  equivalence. So the code uses `rustEqual` and byte-wise `starts_with`/`ends_with`/`contains` wherever the input
  can be anything:
  - shape names and texts in `morphPairs`;
  - effect and transition options;
  - custom show names.

  Literal ASCII ids are matched with `switch`, which is the same either way.
- **Two numeric details matter for bit-exactness:**
  - **Fused sine and cosine.** Wherever deckcraft takes both the sine and the cosine of one value (`sin_cos`,
    or `sin` and `cos` side by side), its release build calls `__sincos_stret` once. Those results differ from
    separate `sin` and `cos` in the last bit for about 1 value in 700. `sinCos` calls `__sincos_stret` in
    exactly those places:
    - rotations: `rot`, and `V3.yaw`, `pitch` and `roll`;
    - `boundary`, Vortex's swirl and Honeycomb's hexagons;
    - the polygon motion paths.

    A lone `sin` or `cos` stays a separate call.
  - **Empty sums.** Rust's `Iterator::sum` of `f64` starts at −0.0, so `totalDuration` (and the play-all
    offset in `startOf`) start their sums at −0.0 too.

## Parity

`AnimVectorTests` replays every line of `DeckCraftNative-Fixtures/anim/` and compares bit for bit. Those
lines were written by `Tools/oracle/anim-vectors`, a Rust tool built on the pinned deckcraft-anim and
deckcraft-render (`Tools/oracle/oracle.sh anim-vectors`). Floats are compared by their bits, and large outputs
by FNV-1a hashes of their bits. Everything matches, measured 2026-10-26:

| What | Cases |
|---|---|
| `ease` | 14,000 (a grid with NaN, ±∞ and out-of-range values) |
| `defaultPath` | 312 preset and option pairs, strings byte-identical |
| `MotionPath.parse` and `at` | 3,313 paths (presets and fuzzed strings), 12 positions each |
| `transitionFrame` and `layerMesh` | 8,280 frames: every transition × option × 16 times × 2 aspects, plus odd options and hostile aspects. Every layer and mesh vertex is compared. Also 587 `usesSlideParts` |
| `Timeline` | 686 slides (all 86 corpus slides, 600 generated): steps, effect timings, paragraph targets, the play-all clock, media cues, and 105 states per shape and paragraph, with triggers and stamps |
| `ShowState` | 156 runs, 18,720 calls (`next`, `prev`, `stepDone`, `goto`, `follow`, `followLink`, `tick`, `click`, `target`, `autoAdvanceDue`) over the 18 corpus decks and 120 generated decks. Each answer and the full state after it are compared, with every shape's `animState` |
| `morphFrame` and `morphPairs` | 5,616 frames: 68 pairs of consecutive corpus slides and 400 generated pairs, at 6 times, with and without hidden shapes. The frame shapes are compared as serde JSON |
| `morphXfrm`, `morphCrop` | 4,000 each |

The tests pass in debug and in release. DCRender's `CompositeVectorTests` checks its CPU compositor the same
way (DCRender/PORT-NOTES.md).

Regenerate:

```bash
Tools/oracle/oracle.sh engine-vectors transitions   # the transitions deck, for DCRender's frames
Tools/oracle/oracle.sh anim-vectors                 # anim/, deterministic: a rerun is byte-identical
```

The whole of DCAnimTests (102 tests) takes about 35 s in a debug test run, most of it the vectors, and about
10 s in release.
