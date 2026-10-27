// DCAppModel — the canvas's smaller pieces without a window: the Eyedropper's state and pick, what a file
// dropped on the canvas becomes, and the keys the canvas hands the engine. Ports deckcraft
// `crates/ui-egui/src/eyedropper.rs`, `infer_command` / `is_presentation_name` and `key_name` in
// `crates/ui-egui/src/lib.rs` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
import DCEngine
import DCGeometry
import DCModel
import DCRender

// MARK: - Eyedropper

/// The Eyedropper waiting for a click: the slide as it is drawn and what the click is for (`State`).
public struct CanvasEyedropper {
    /// What a click with the pointer does (`Pick`).
    public enum Pick {
        /// Hands the colour (`RRGGBB`) to whoever asked: a colour menu applies it its own way.
        case color(@MainActor (String) -> Void)
        /// Picture Format › Color › Set Transparent Color: the colour of the selected picture under the
        /// pointer turns transparent.
        case transparentColor
    }

    /// Pixels per slide point of the picture the Eyedropper looks at (`SCALE`).
    public static let scale = 2.0

    public var pick: Pick
    public var slide: Int
    public var image: RenderImage

    /// Start on the active presentation's current slide; nil (with the reason) when it isn't showing a
    /// slide (`begin`).
    public static func begin(_ s: Session, _ pick: Pick) -> Result<CanvasEyedropper, CommandError> {
        guard let d = s.activeDoc else { return .failure("no presentation is open") }
        guard d.selection.target == .slides else { return .failure("The Eyedropper takes colours from a slide") }
        let slide = d.selection.slide
        let image = renderSlide(d.doc, slide, RenderOpts(scale: scale))
        return .success(CanvasEyedropper(pick: pick, slide: slide, image: image))
    }

    /// The status line while it waits.
    public var prompt: String {
        switch pick {
        case .color: "Eyedropper: click the slide (Esc cancels)"
        case .transparentColor: "Set Transparent Color: click the colour in the picture (Esc cancels)"
        }
    }

    /// The colour drawn at slide point `p` (straight RGBA), for the loupe.
    public func color(at p: Point) -> [UInt8]? {
        guard p.x.isFinite, p.y.isFinite else { return nil }
        let x = Int(rustCast: (p.x * Self.scale).rustMax(0)), y = Int(rustCast: (p.y * Self.scale).rustMax(0))
        return image.straight(x, y)
    }

    /// `RRGGBB` of a colour.
    public static func hex(_ c: [UInt8]) -> String {
        c.prefix(3).map { b in
            let s = String(b, radix: 16, uppercase: true)
            return s.count == 1 ? "0" + s : s
        }.joined()
    }

    /// A click at slide point `p`: the colour goes to whoever asked (`slide.colorAt`), or the picture's
    /// colour there turns transparent. Failures come back as the status message.
    @MainActor
    public func click(_ app: AppModel, _ p: Point) {
        switch pick {
        case .color(let deliver):
            do {
                let v = try app.session.execute("slide.colorAt", ["slide": .integer(slide), "x": .num(p.x), "y": .num(p.y), "scale": .num(Self.scale)])
                if let c = v["color"]?.asStr { deliver(c) }
            } catch {
                app.status = error.description
            }
        case .transparentColor:
            app.run("picture.transparentColor", ["at": [.num(p.x), .num(p.y)]])
        }
        app.changed()
    }
}

// MARK: - Drops

/// What a file dropped on the canvas becomes (`infer_command`): a presentation opens, a picture, sound or
/// video is inserted, an outline becomes slides.
public enum CanvasDrop: Sendable, Equatable {
    case open
    case insert(String)
    case outline

    public static func isPresentation(_ name: String) -> Bool {
        let lower = name.lowercased()
        return [".deckcraft", ".slidecraft", ".pptx", ".potx", ".ppsx"].contains { lower.hasSuffix($0) }
    }

    /// nil: DeckCraft can't open this kind of file.
    public static func infer(_ name: String, _ bytes: [UInt8]) -> CanvasDrop? {
        let lower = name.lowercased()
        if isPresentation(lower) { return .open }
        let ct = InsertCommands.contentType(name, bytes)
        if ct.hasPrefix("image/") { return .insert("insert.picture") }
        if ct.hasPrefix("audio/") { return .insert("insert.audio") }
        if ct.hasPrefix("video/") { return .insert("insert.video") }
        if lower.hasSuffix(".txt") || lower.hasSuffix(".md") || lower.hasSuffix(".rtf") { return .outline }
        return nil
    }

    /// The command's parameters for the file's bytes (base64, as the control channel sends them).
    public static func params(_ name: String, _ bytes: [UInt8]) -> JSON {
        ["name": .string(name), "data": .string(Cmd.base64Encode(bytes))]
    }
}

// MARK: - Keys

/// The keys the canvas hands `Session.key` (`key_name`), by the character AppKit gives a key event.
public enum CanvasKeys {
    /// The engine's name for a special key's character (`NSEvent.charactersIgnoringModifiers`'s first
    /// scalar), or nil for a character that is typed.
    public static func name(_ scalar: Unicode.Scalar) -> String? {
        switch scalar.value {
        case 0x0D, 0x03: "Enter"
        case 0x1B: "Escape"
        case 0x7F, 0x08: "Backspace"
        case 0xF728: "Delete"
        case 0x09, 0x19: "Tab"
        case 0xF702: "Left"
        case 0xF703: "Right"
        case 0xF700: "Up"
        case 0xF701: "Down"
        case 0xF729: "Home"
        case 0xF72B: "End"
        case 0xF72C: "PageUp"
        case 0xF72D: "PageDown"
        case 0xF705: "F2"
        case 0xF708: "F5"
        case 0xF70A: "F7"
        default: nil
        }
    }

    /// deckcraft's modifiers: Command or Control is `cmd` (`mods`).
    public static func mods(shift: Bool, option: Bool, command: Bool, control: Bool) -> Mods {
        Mods(shift: shift, alt: option, cmd: command || control)
    }
}
