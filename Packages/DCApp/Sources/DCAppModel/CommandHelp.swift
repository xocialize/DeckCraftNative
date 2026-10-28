// DCAppModel — one-line descriptions of what commands do, for tooltips, the command palette and VoiceOver hints
// (Docs/plans/Ribbon-and-StartScreen.md §6, decision 3). They are written in our own words, from what our command
// does, never from another product's tooltips. The engine's `CommandSpec` stays as deckcraft has it (its English is
// compared byte for byte), so the descriptions live here, keyed by command id, and are translated from the
// Commands catalog as `help.<id>`. The table starts empty in R0; R1 fills it for every command the ribbon and the
// toolbar show, and R4 for the rest.
import Foundation

public enum CommandHelp {
    /// English descriptions by command id.
    static let english: [String: String] = [:]

    /// The description to show for command `id`, translated, or nil when it has none yet.
    public static func description(_ id: String) -> String? {
        guard let e = english[id] else { return nil }
        return Bundle.module.localizedString(forKey: "help.\(id)", value: e, table: "Commands")
    }
}
