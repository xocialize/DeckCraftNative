# DCCore — port notes

DCCore holds what every package needs in order to behave like its Rust original. Upstream has no crate like
it: it stands in for serde, serde_json and Rust's numeric and string semantics. It has 14 tests.

## JSON (serde_json 1.0.154, zmij 1.0.23)

| File | Holds |
|---|---|
| `JSON.swift` | `JSON` (integers and floats kept apart, as serde_json does) and `JSONObject` (keys in insertion order) |
| `JSONWriter.swift` | `serde_json::to_vec`'s compact output. Floats in zmij's layout over Swift's shortest digits: fixed for decimal exponents −5…15 (f32: −6…12), otherwise `1.5e+16` / `1e-7` |
| `JSONParser.swift` | Strict, as `serde_json::from_slice` is: no trailing commas, no leading zeros, nesting limited to 128, lone surrogates refused, line and column in errors |
| `JSONCoding.swift` | serde-derive semantics: `JSONFields` (`required`, `get(default:)`, `requiredFixed`, `optionalFixed`, `tag`), `JSONStringEnum`, `externalVariant`, `Pair`/`Triple` for tuples, the `JSONDecoding.nullFloatsAsZero` mode |

**Measured:** 222,461 f64 values, 107,713 f32 values and 133 strings, all equal to serde_json's own output
(`DECKCRAFT_FIXTURES/json/`, written by `Tools/oracle/oracle.sh json-vectors`).

## Rust semantics

| File | Holds |
|---|---|
| `RustNumerics.swift` | `init(rustCast:)`, which saturates and maps NaN to 0, as `as` does; `clamped`, which keeps NaN; `rem` (Rust `%`); `rustMin`/`rustMax`, which ignore NaN; `toRadians`/`toDegrees`; `Collection.at` (Rust `get`) |
| `RustStrings.swift` | `rustTrim` (and the start/end variants), `rustLines`, `rustASCIILowercase`, `rustLowercase` (with final sigma), `rustUppercase`, `rustEqual` (scalar for scalar), `rustFixed` (`{:.N}`) |
