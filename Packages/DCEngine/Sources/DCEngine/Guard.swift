// DCEngine — the last-resort guard around every command.
// Port of deckcraft crates/engine/src/guard.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// deckcraft catches a panic that escapes a command, turns it into `EngineError::Internal`, rolls the
// document back and writes a recovery snapshot. Swift can't catch a trap, so there is nothing to catch
// here: commands must not trap (CLAUDE.md, "Never crash"), a failed command is rolled back by
// `Session.execute` itself, and the app saves recovery snapshots on a timer. `guarded` stays as the one
// place every command passes through.

extension Session {
    /// Run command `id` (`f`) inside the guard.
    func guarded<T>(_ id: String, _ f: (Session) throws -> T) throws -> T {
        try f(self)
    }
}
