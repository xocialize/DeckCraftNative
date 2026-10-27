// DCAppModel — which display the slide show plays on and where presenter view goes. deckcraft's show opens on the
// window's own monitor with presenter view in a second window (its gap #9); here, as in PowerPoint: with two or
// more displays the audience sees the chosen one (Set Up Show's monitor; automatically the first that isn't the
// main display) and presenter view goes to the main display, or another one when the show is on the main; with
// one display there is the show alone. New for the Mac app.
public struct ShowScreen: Equatable, Sendable {
    /// The display's localized name (`NSScreen.localizedName`).
    public var name: String
    /// The display with the menu bar.
    public var main: Bool

    public init(name: String, main: Bool) {
        self.name = name
        self.main = main
    }
}

public enum ShowDisplays {
    /// The preference value for "choose automatically".
    public static let automatic = "automatic"
    /// The preference value for "the main display".
    public static let primary = "primary"

    /// The audience display and presenter view's display, as indices into `screens`; nil for no screen (none
    /// attached) and no presenter display. `preference` is a display name, `automatic` or `primary`.
    public static func choose(_ screens: [ShowScreen], preference: String?, presenterView: Bool) -> (audience: Int?, presenter: Int?) {
        guard !screens.isEmpty else { return (nil, nil) }
        let main = screens.firstIndex(where: \.main) ?? 0
        var audience: Int
        switch preference ?? automatic {
        case automatic: audience = screens.indices.first { $0 != main } ?? main
        case primary: audience = main
        case let name: audience = screens.firstIndex { $0.name == name } ?? (screens.indices.first { $0 != main } ?? main)
        }
        if !screens.indices.contains(audience) { audience = main }
        guard presenterView, screens.count > 1 else { return (audience, nil) }
        let presenter = audience != main ? main : (screens.indices.first { $0 != audience } ?? main)
        return (audience, presenter)
    }
}
