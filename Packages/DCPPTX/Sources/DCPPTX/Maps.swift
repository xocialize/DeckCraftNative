// DCPPTX — mappings between our transition / animation ids and PresentationML elements and preset
// numbers, shared by the reader and the writer. Port of deckcraft crates/pptx/src/maps.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
import DCModel

/// The `maps` module.
enum Maps {
    /// (our kind, namespace prefix, element) for transitions that map one-to-one.
    static let simple: [(kind: String, prefix: String, element: String)] = [
        ("dissolve", "p", "dissolve"), ("random", "p", "random"), ("honeycomb", "p14", "honeycomb"), ("flash", "p14", "flash"),
    ]

    /// Read a transition effect element → (kind, option). nil for effects we don't model.
    static func transitionFromXML(_ e: XMLEl) -> (kind: String, option: String)? {
        guard let (k, o) = transitionFromXMLRaw(e) else { return nil }
        // Kinds without options keep none.
        let hasOpts = transitions.first { $0.id == k }.map { !$0.options.isEmpty } ?? true
        return (k, hasOpts ? o : "")
    }

    /// Preset transitions (`p15:prstTrans`) whose "Left" option PowerPoint writes with `invX="1"` (the
    /// others write it for "Right"), as observed on PowerPoint's own files.
    static let invxLeft = ["wind", "airplane", "origami"]

    private static func asciiUppercase(_ s: String) -> String {
        String(decoding: s.utf8.map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 32 : $0 }, as: UTF8.self)
    }

    private static func transitionFromXMLRaw(_ e: XMLEl) -> (String, String)? {
        // Defaults are what PowerPoint leaves out: e.g. it writes Push Left as `<p:push/>`.
        func dir(_ d: String) -> String { e.attr("dir") ?? d }
        switch e.local {
        case "fade": return ("fade", e.bool("thruBlk") == true ? "throughBlack" : "smoothly")
        case "cut": return ("cut", e.bool("thruBlk") == true ? "throughBlack" : "")
        case "push": return ("push", dir("l"))
        case "wipe": return ("wipe", dir("l"))
        // Diagonal wipes.
        case "strips": return ("wipe", dir("lu"))
        case "split":
            let o = e.attr("orient") ?? "horz"
            let d = e.attr("dir") ?? "out"
            return ("split", o + (d == "in" ? "In" : "Out"))
        case "randomBar": return ("randomBar", dir("horz"))
        case "circle": return ("shape", "circle")
        case "diamond": return ("shape", "diamond")
        case "plus": return ("shape", "plus")
        // Shape In / Out (the slide zooming in a box).
        case "zoom": return ("shape", e.attr("dir") == "in" ? "in" : "out")
        // The Zoom transition, and its Zoom and Rotate option.
        case "warp": return ("zoom", e.attr("dir") == "in" ? "in" : "out")
        case "newsflash": return ("zoom", "rotate")
        case "pull": return ("uncover", dir("l"))
        case "cover": return ("cover", dir("l"))
        case "checker": return ("checker", dir("horz"))
        case "blinds": return ("blinds", dir("horz"))
        case "comb": return ("comb", dir("horz"))
        case "wheel": return ("clock", "clockwise")
        case "wheelReverse": return ("clock", "counterClockwise")
        case "wedge": return ("clock", "wedge")
        case "vortex": return ("vortex", dir("l"))
        case "switch": return ("switch", dir("r"))
        case "flip": return ("flip", dir("r"))
        case "ripple": return ("ripple", dir("center"))
        case "doors": return ("doors", dir("horz"))
        case "window": return ("window", dir("horz"))
        case "ferris": return ("ferris", dir("l"))
        case "gallery": return ("gallery", dir("l"))
        case "conveyor": return ("conveyor", dir("l"))
        case "pan": return ("pan", dir("l"))
        case "glitter":
            let d = dir("l")
            return e.attr("pattern") == "hexagon" ? ("glitter", "hex" + asciiUppercase(d)) : ("glitter", d)
        case "shred":
            // `crush` is what DeckCraft wrote before it knew PowerPoint's `rectangle`.
            let particles = e.attr("pattern") == "rectangle" || e.attr("pattern") == "crush"
            let out = e.attr("dir") == "out"
            return ("shred", (particles ? "particles" : "strips") + (out ? "Out" : "In"))
        case "reveal":
            let black = e.bool("thruBlk") == true
            let right = e.attr("dir") == "r"
            return ("reveal", (black ? "black" : "smoothly") + (right ? "Right" : "Left"))
        case "flythrough":
            let out = e.attr("dir") == "out"
            let b = e.bool("hasBounce") == true
            return ("flythrough", (out ? "out" : "in") + (b ? "Bounce" : ""))
        case "prism":
            let content = e.bool("isContent") == true
            let inv = e.bool("isInverted") == true
            let kind = switch (content, inv) {
            case (false, false): "cube"
            case (false, true): "box"
            case (true, false): "rotate"
            case (true, true): "orbit"
            }
            return (kind, dir("l"))
        case "prstTrans":
            let prst = e.attr("prst") ?? "fallOver"
            let inv = e.bool("invX") == true
            if prst == "pageCurlSingle" {
                return ("pageCurlDouble", inv ? "singleR" : "singleL")
            }
            guard transitions.contains(where: { $0.id == prst }) else { return nil }
            let left = invxLeft.contains(prst) ? inv : !inv
            return (prst, left ? "l" : "r")
        case "morph":
            let option = switch e.attr("option") {
            case "byWord": "words"
            case "byChar": "characters"
            default: "objects"
            }
            return ("morph", option)
        case let other:
            guard let s = simple.first(where: { bytesEqual($0.element, other) }) else { return nil }
            return (s.kind, "")
        }
    }

    /// Write the effect element for a transition. Returns the namespace prefix it needs (`p`, `p14`,
    /// `p15`, `p159`), or nil when the kind is unknown.
    static func transitionToXML(_ w: inout W, _ kind: String, _ option: String) -> String? {
        func lr(_ d: String) -> String { ["l", "r"].contains(option) ? option : d }
        func lrud(_ d: String) -> String { ["l", "r", "u", "d"].contains(option) ? option : d }
        func hv(_ d: String) -> String { ["horz", "vert"].contains(option) ? option : d }
        func eight(_ d: String) -> String { ["l", "r", "u", "d", "lu", "ru", "ld", "rd"].contains(option) ? option : d }
        switch kind {
        case "fade": w.empty("p:fade", A().t("thruBlk", option == "throughBlack"))
        case "cut": w.empty("p:cut", A().t("thruBlk", option == "throughBlack"))
        case "push": w.empty("p:push", A().a("dir", lrud("u")))
        case "wipe":
            switch option {
            case "lu", "ru", "ld", "rd": w.empty("p:strips", A().a("dir", option))
            default: w.empty("p:wipe", A().a("dir", lrud("r")))
            }
        case "split":
            let (o, d) = switch option {
            case "vertIn": ("vert", "in")
            case "vertOut": ("vert", "out")
            case "horzIn": ("horz", "in")
            default: ("horz", "out")
            }
            w.empty("p:split", A().a("orient", o).a("dir", d))
        case "randomBar": w.empty("p:randomBar", A().a("dir", hv("vert")))
        case "shape":
            switch option {
            case "diamond": w.empty0("p:diamond")
            case "plus": w.empty0("p:plus")
            case "in", "out": w.empty("p:zoom", A().a("dir", option))
            default: w.empty0("p:circle")
            }
        case "zoom":
            if option == "rotate" {
                w.empty0("p:newsflash")
            } else {
                w.empty("p14:warp", A().a("dir", option == "out" ? "out" : "in"))
                return "p14"
            }
        case "uncover": w.empty("p:pull", A().a("dir", eight("l")))
        case "cover": w.empty("p:cover", A().a("dir", eight("l")))
        case "checker": w.empty("p:checker", A().a("dir", hv("horz")))
        case "blinds": w.empty("p:blinds", A().a("dir", hv("horz")))
        case "comb": w.empty("p:comb", A().a("dir", hv("horz")))
        case "clock":
            switch option {
            case "counterClockwise":
                w.empty("p14:wheelReverse", A().a("spokes", 1))
                return "p14"
            case "wedge": w.empty0("p:wedge")
            default: w.empty("p:wheel", A().a("spokes", 1))
            }
        case "dissolve": w.empty0("p:dissolve")
        case "random": w.empty0("p:random")
        case "honeycomb":
            w.empty0("p14:honeycomb")
            return "p14"
        case "flash":
            w.empty0("p14:flash")
            return "p14"
        case "vortex":
            w.empty("p14:vortex", A().a("dir", lrud("l")))
            return "p14"
        case "glitter":
            let hex = hasBytePrefix(option, "hex")
            var rest = Substring(option)
            while hasBytePrefix(rest, "hex") { rest = rest.dropFirst(3) } // trim_start_matches("hex")
            var d = rustASCIILowercase(String(rest))
            if !["l", "r", "u", "d"].contains(d) { d = "l" }
            w.empty("p14:glitter", A().a("dir", d).o("pattern", hex ? "hexagon" : nil))
            return "p14"
        case "switch", "flip", "gallery", "conveyor", "ferris":
            let name = switch kind {
            case "switch": "p14:switch"
            case "flip": "p14:flip"
            case "gallery": "p14:gallery"
            case "conveyor": "p14:conveyor"
            default: "p14:ferris"
            }
            w.empty(name, A().a("dir", lr("l")))
            return "p14"
        case "ripple":
            let d = ["lu", "ru", "ld", "rd"].contains(option) ? option : "center"
            w.empty("p14:ripple", A().a("dir", d))
            return "p14"
        case "doors", "window":
            w.empty(kind == "doors" ? "p14:doors" : "p14:window", A().a("dir", hv("vert")))
            return "p14"
        case "pan":
            w.empty("p14:pan", A().a("dir", lrud("d")))
            return "p14"
        case "shred":
            let particles = hasBytePrefix(option, "particles")
            w.empty("p14:shred", A().a("pattern", particles ? "rectangle" : "strip").a("dir", hasByteSuffix(option, "Out") ? "out" : "in"))
            return "p14"
        case "reveal":
            w.empty("p14:reveal", A().t("thruBlk", hasBytePrefix(option, "black")).a("dir", hasByteSuffix(option, "Right") ? "r" : "l"))
            return "p14"
        case "flythrough":
            w.empty("p14:flythrough", A().a("dir", hasBytePrefix(option, "out") ? "out" : "in").t("hasBounce", hasByteSuffix(option, "Bounce")))
            return "p14"
        case "cube", "box", "rotate", "orbit":
            w.empty(
                "p14:prism",
                A().a("dir", lrud("l")).t("isContent", kind == "rotate" || kind == "orbit").t("isInverted", kind == "box" || kind == "orbit")
            )
            return "p14"
        case "pageCurlDouble" where hasBytePrefix(option, "single"):
            w.empty("p15:prstTrans", A().a("prst", "pageCurlSingle").t("invX", option == "singleR"))
            return "p15"
        case "fallOver", "drape", "curtains", "wind", "prestige", "fracture", "crush", "peelOff", "pageCurlDouble", "airplane", "origami":
            let inv = invxLeft.contains(kind) ? option == "l" : option == "r"
            w.empty("p15:prstTrans", A().a("prst", kind).t("invX", inv))
            return "p15"
        case "morph":
            let o = switch option {
            case "words": "byWord"
            case "characters": "byChar"
            default: "byObject"
            }
            w.empty("p159:morph", A().a("option", o))
            return "p159"
        default:
            return nil
        }
        return "p"
    }

    // MARK: Animations

    private static let dir8: [(String, UInt32)] = [("b", 4), ("lb", 12), ("l", 8), ("lt", 9), ("t", 1), ("rt", 3), ("r", 2), ("rb", 6)]
    private static let dir4: [(String, UInt32)] = [("b", 4), ("l", 8), ("t", 1), ("r", 2)]
    private static let split: [(String, UInt32)] = [("horzIn", 21), ("horzOut", 42), ("vertIn", 26), ("vertOut", 37)]
    private static let inout_: [(String, UInt32)] = [("in", 16), ("out", 32)]
    private static let inoutShape: [(String, UInt32)] = [("circleIn", 16), ("circleOut", 32)]
    private static let hv: [(String, UInt32)] = [("horz", 10), ("vert", 5)]
    private static let wheel: [(String, UInt32)] = [("1", 1), ("2", 2), ("3", 3), ("4", 4), ("8", 8)]
    private static let diagonal: [(String, UInt32)] = [("lu", 9), ("ru", 3), ("ld", 12), ("rd", 6)]
    private static let checker: [(String, UInt32)] = [("across", 10), ("down", 5)]
    private static let float: [(String, UInt32)] = [("u", 0), ("d", 4)]
    private static let lines: [(String, UInt32)] = [("down", 4), ("up", 1), ("right", 2), ("left", 8)]

    /// Effect options ↔ preset subtypes.
    static let subtypes: [(effect: String, map: [(String, UInt32)])] = [
        ("fly", dir8),
        ("flyOut", dir8),
        ("peek", dir4),
        ("wipe", dir4),
        ("wipeOut", dir4),
        ("strips", diagonal),
        ("split", split),
        ("splitOut", split),
        ("zoom", inout_),
        ("zoomOut", inout_),
        ("box", inout_),
        ("circle", inout_),
        ("diamond", inout_),
        ("randomBars", hv),
        ("randomBarsOut", hv),
        ("blinds", hv),
        ("swivel", hv),
        ("swivelOut", hv),
        ("blindsOut", hv),
        ("boxOut", inout_),
        ("checkerboardOut", checker),
        ("diamondOut", inout_),
        ("peekOut", dir4),
        ("stripsOut", diagonal),
        ("checkerboard", checker),
        ("wheel", wheel),
        ("wheelOut", wheel),
        ("float", float),
        ("floatOut", float),
        (
            "shape",
            [("circleIn", 16), ("circleOut", 32), ("boxIn", 16), ("boxOut", 32), ("diamondIn", 16), ("diamondOut", 32), ("plusIn", 16), ("plusOut", 32)]
        ),
        ("shapeOut", inoutShape),
        ("lines", lines),
        ("arcs", lines),
        ("turns", lines),
    ]

    static func optionFromSubtype(_ effect: String, _ sub: UInt32) -> String {
        subtypes.first { $0.effect == effect }?.map.first { $0.1 == sub }?.0 ?? ""
    }

    static func subtypeFromOption(_ effect: String, _ option: String) -> UInt32? {
        subtypes.first { $0.effect == effect }?.map.first { $0.0 == option }?.1
    }

    /// Our effect id for a preset (first match in `animations`).
    static func effectForPreset(_ animClass: AnimClass, _ preset: UInt32) -> String? {
        animations.first { $0.animClass == animClass && $0.presetId == preset && $0.id != "customPath" }?.id
    }

    /// Effect used for presets we don't know.
    static func fallbackEffect(_ animClass: AnimClass) -> String {
        switch animClass {
        case .entrance: "fade"
        case .exit: "fadeOut"
        case .emphasis: "pulse"
        case .path: "customPath"
        case .media: "play"
        }
    }

    /// The preset id to write for an animation.
    static func presetFor(_ a: Animation) -> UInt32 {
        // Float Down is PowerPoint's preset 47 (Float Up is 42).
        if (a.effect == "float" || a.effect == "floatOut") && a.option == "d" {
            return 47
        }
        if let p = a.presetId {
            let consistent = if let e = effectForPreset(a.`class`, p) {
                e == a.effect
            } else {
                a.effect == fallbackEffect(a.`class`)
            }
            if consistent { return p }
        }
        if let info = animationInfo(a.effect, a.`class`), info.animClass == a.`class` {
            return info.presetId
        }
        switch a.`class` {
        case .entrance, .exit: return 10
        case .emphasis: return 26
        case .path: return 0
        case .media: return 1
        }
    }
}
