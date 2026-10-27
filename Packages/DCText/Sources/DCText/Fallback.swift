// DCText — per-cluster font fallback: emoji clusters, coverage, and the cascade from a run's faces through
// the bundled and installed fonts. Port of deckcraft crates/fonts/src/fallback.rs (MIT OR Apache-2.0, ©
// ArtCraft Team and the DeckCraft contributors).

public enum Fallback {
    static let textSelector: Unicode.Scalar = "\u{FE0E}"
    static let keycap: Unicode.Scalar = "\u{20E3}"

    /// Characters a face needn't have to draw a cluster (spaces, controls, joiners, selectors).
    static func ignorable(_ c: Unicode.Scalar) -> Bool {
        if c.properties.isWhitespace || c.properties.generalCategory == .control { return true }
        switch c.value {
        case 0x200B ... 0x200F, 0x202A ... 0x202E, 0x2060 ... 0x2069, 0xFE00 ... 0xFE0F, 0xFEFF, 0xE0100 ... 0xE01EF: return true
        default: return false
        }
    }

    /// Is the cluster an emoji, drawn in colour as PowerPoint draws it?
    public static func isEmojiCluster(_ cluster: [Unicode.Scalar]) -> Bool {
        if cluster.contains(textSelector) || cluster.contains(keycap) { return false }
        func pictographic(_ c: Unicode.Scalar) -> Bool {
            switch c.value {
            case 0x1F000 ... 0x1FAFF, 0x2600 ... 0x27BF, 0x2B00 ... 0x2BFF, 0x2190 ... 0x21FF, 0x2300 ... 0x23FF: true
            default: false
            }
        }
        func defaultEmoji(_ c: Unicode.Scalar) -> Bool {
            switch c.value {
            case 0x1F300 ... 0x1F64F, 0x1F680 ... 0x1F6FF, 0x1F900 ... 0x1F9FF, 0x1FA70 ... 0x1FAFF, 0x1F1E6 ... 0x1F1FF, 0x1F004, 0x1F0CF,
                 0x1F18E, 0x1F191 ... 0x1F19A, 0x1F201, 0x1F21A, 0x1F22F, 0x1F232 ... 0x1F236, 0x1F238 ... 0x1F23A, 0x1F250 ... 0x1F251,
                 0x231A ... 0x231B, 0x23E9 ... 0x23EC, 0x23F0, 0x23F3, 0x25FD ... 0x25FE, 0x2614 ... 0x2615, 0x2648 ... 0x2653, 0x267F,
                 0x2693, 0x26A1, 0x26AA ... 0x26AB, 0x26BD ... 0x26BE, 0x26C4 ... 0x26C5, 0x26CE, 0x26D4, 0x26EA, 0x26F2 ... 0x26F3,
                 0x26F5, 0x26FA, 0x26FD, 0x2705, 0x270A ... 0x270B, 0x2728, 0x274C, 0x274E, 0x2753 ... 0x2755, 0x2757,
                 0x2795 ... 0x2797, 0x27B0, 0x27BF, 0x2B1B ... 0x2B1C, 0x2B50, 0x2B55:
                true
            default:
                false
            }
        }
        return cluster.contains(where: defaultEmoji)
            || (cluster.contains("\u{FE0F}") && cluster.contains(where: pictographic))
            || (cluster.contains("\u{200D}") && cluster.contains(where: pictographic))
    }

    /// Does `face` draw every character of the cluster that needs drawing?
    public static func coversCluster(_ face: FontFace, _ cluster: [Unicode.Scalar]) -> Bool {
        cluster.allSatisfy { ignorable($0) || face.covers($0) }
    }

    /// System families for scripts the bundled fonts may lack.
    static func osFamilies(_ script: ScriptTag) -> [String] {
        switch script {
        case "Arab": ["Noto Naskh Arabic", "Noto Sans Arabic", "Geeza Pro", "SF Arabic", "DejaVu Sans"]
        case "Hebr": ["Noto Sans Hebrew", "Arial Hebrew", "SF Hebrew", "DejaVu Sans"]
        case "Thai": ["Noto Sans Thai", "Thonburi"]
        case "Deva": ["Noto Sans Devanagari", "Kohinoor Devanagari", "Devanagari Sangam MN"]
        default: []
        }
    }
}

extension FontDB {
    /// The face that draws `cluster` for a run whose faces are `chain` (slot face, theme script font, run
    /// face): emoji in a colour face, the first chain face that covers the cluster, then the bundled and
    /// installed faces for its script, then any face that covers it.
    public func cascade(_ cluster: [Unicode.Scalar], _ chain: [FontFace], _ style: String) -> FontFace {
        if Fallback.isEmojiCluster(cluster) {
            if let f = chain.first(where: { $0.isColor && Fallback.coversCluster($0, cluster) }) { return f }
            if let key = cluster.first(where: { !Fallback.ignorable($0) }), let f = colorFace(key, cluster) { return f }
        }
        if let f = chain.first(where: { Fallback.coversCluster($0, cluster) }) { return f }
        let textStyle = cluster.contains(Fallback.textSelector) || cluster.contains(Fallback.keycap)
        if textStyle, let key = cluster.first(where: { !Fallback.ignorable($0) }), let f = plainFace(key, cluster) { return f }
        func first() -> FontFace { chain.first ?? face(fallbackFamily, style) }
        guard let key = cluster.first(where: { !Fallback.ignorable($0) }) else { return first() }
        if let s = cluster.lazy.compactMap({ Script.of($0) }).first, !Fallback.osFamilies(s).isEmpty {
            let bundled = bundledFamilies(s)
            for fam in bundled {
                let f = face(fam, style)
                if rustASCIILowercaseKey(f.family) == rustASCIILowercaseKey(fam) && Fallback.coversCluster(f, cluster) { return f }
            }
            for fam in Fallback.osFamilies(s) where !bundled.contains(fam) {
                if isLoaded(fam) || hasFamily(fam) {
                    let f = face(fam, style)
                    if rustASCIILowercaseKey(f.family) == rustASCIILowercaseKey(fam) && Fallback.coversCluster(f, cluster) { return f }
                }
            }
            if let f = systemFace(key, cluster, bundled) { return f }
        }
        let exclude = chain.first?.id ?? .max
        var f: FontFace
        switch fallback(for: key, excluding: exclude) {
        case let found? where Fallback.coversCluster(found, cluster):
            f = found
        case let found? where chain.allSatisfy({ !$0.covers(key) }):
            f = found
        default:
            f = loadedFaces.first { !$0.isColor && Fallback.coversCluster($0, cluster) } ?? first()
        }
        if f.isColor && !Fallback.isEmojiCluster(cluster), let plain = plainFace(key, cluster) { f = plain }
        return f
    }
}
