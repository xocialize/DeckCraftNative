// DCText — the font database: the bundled craft-fonts faces (read from their manifests, as deckcraft's
// fonts/build.rs embeds them), then the installed system fonts through CoreText, loaded family by family
// on first use. Port of deckcraft crates/fonts/src/fontdb.rs and fallback.rs (MIT OR Apache-2.0, ©
// ArtCraft Team and the DeckCraft contributors). Fonts are never registered system-wide: faces come from
// descriptors made from the files' bytes, visible to this process only.
import CoreText
import DCCore
import Foundation
import Synchronization

/// The family used when a requested family is unknown and has no substitute.
public let fallbackFamily = "Inter"
/// The family PowerPoint draws a document's Latin text in when the font it names isn't installed.
public let missingFontFamily = "Calibri"

public final class FontDB: Sendable {
    private struct State {
        var faces: [FontFace] = []
        /// Families (lower case) whose installed faces have been looked for.
        var loadedFamilies: Set<String> = []
        /// Characters no system font covers.
        var misses: Set<UInt32> = []
    }

    private let state = Mutex(State())
    /// Held while installed faces load.
    private let loading = Mutex(())
    /// Office's font files by family (lower case, typographic and Windows names), indexed on first use.
    private let officeIndex = Mutex<[String: [URL]]?>(nil)
    /// The installed families CoreText knows (lower case), read once.
    private let systemFamilies: Set<String>
    /// The craft-fonts families and the scripts each serves, in manifest order.
    public let bundledScripts: [(family: String, scripts: [String])]
    private let systemFallback: Bool

    /// The process-wide database: craft-fonts from `CRAFT_FONTS_DIR` (else `../craft-fonts` beside the
    /// repository), then the installed system fonts.
    public static let shared = FontDB(craftFontsDir: FontDB.defaultCraftFontsDir(), systemFonts: true)

    /// Where craft-fonts is: `CRAFT_FONTS_DIR`, else a `craft-fonts` checkout beside this repository.
    public static func defaultCraftFontsDir() -> URL? {
        if let env = ProcessInfo.processInfo.environment["CRAFT_FONTS_DIR"], !env.isEmpty {
            return URL(filePath: env, directoryHint: .isDirectory)
        }
        // …/Packages/DCText/Sources/DCText/FontDB.swift → the research folder.
        var url = URL(filePath: #filePath)
        for _ in 0 ..< 6 { url = url.deletingLastPathComponent() }
        let dir = url.appending(path: "craft-fonts", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: dir.appending(path: "fonts/manifest.txt").path) ? dir : nil
    }

    /// A database of the craft-fonts faces in `craftFontsDir` (none when nil), with the installed
    /// fonts behind them when `systemFonts`.
    public init(craftFontsDir: URL?, systemFonts: Bool) {
        var faces: [FontFace] = []
        var scripts: [(String, [String])] = []
        if let dir = craftFontsDir {
            for manifest in ["fonts/latin-manifest.txt", "fonts/manifest.txt", "fonts/simplified-chinese-manifest.txt"] {
                guard let text = try? String(contentsOf: dir.appending(path: manifest), encoding: .utf8) else { continue }
                for line in rustLines(text) {
                    let l = String(rustTrim(line))
                    if l.isEmpty || l.hasPrefix("#") { continue }
                    let f = l.components(separatedBy: " | ").map { String(rustTrim($0)) }
                    guard f.count >= 4 else { continue }
                    let family = f[0]
                    if FontDB.isExcludedFamily(family) { continue }
                    let fileScripts = f[3].split(separator: ",").map { String(rustTrim(String($0))) }
                    if !scripts.contains(where: { $0.0 == family }) { scripts.append((family, fileScripts)) }
                    guard let data = try? Data(contentsOf: dir.appending(path: f[2])) else { continue }
                    faces += FontDB.facesOf(data: data, bundled: true)
                }
            }
        }
        state.withLock { $0.faces = faces }
        bundledScripts = scripts
        systemFallback = systemFonts
        if systemFonts, let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] {
            systemFamilies = Set(names.map(rustASCIILowercase))
        } else {
            systemFamilies = []
        }
    }

    /// The asset policy: no Adobe-authored typefaces and no Noto CJK (Source Han rebranded).
    static func isExcludedFamily(_ family: String) -> Bool {
        ["Source Sans 3", "Source Serif 4", "Source Han Sans", "Source Han Serif"].contains(family)
            || family.hasPrefix("Source Han Sans") || family.hasPrefix("Source Han Serif") || family.hasPrefix("Noto Sans CJK")
            || family.hasPrefix("Noto Serif CJK") || family.hasPrefix("Noto Sans Mono CJK")
    }

    /// Every face in a font file or collection; a variable font gives one face per named instance.
    static func facesOf(data: Data, bundled: Bool) -> [FontFace] {
        guard let descs = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor] else { return [] }
        return descs.flatMap { facesOf(descriptor: $0, bundled: bundled) }
    }

    static func facesOf(descriptor: CTFontDescriptor, bundled: Bool) -> [FontFace] {
        let font = CTFontCreateWithFontDescriptor(descriptor, 0, nil)
        guard SFNT.hasOutlines(font) else { return [] }
        let info = SFNT.info(font)
        let instances = namedInstances(font)
        if instances.isEmpty { return [FontFace(font: font, info: info, bundled: bundled)] }
        var seen: Set<String> = []
        return instances.compactMap { style, coords in
            guard seen.insert(rustASCIILowercase(style)).inserted else { return nil }
            let variation = Dictionary(uniqueKeysWithValues: coords.map { (NSNumber(value: SFNT.tag($0.0)), NSNumber(value: $0.1)) })
            let d = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: variation] as CFDictionary)
            let f = CTFontCreateCopyWithAttributes(font, 0, nil, d)
            return FontFace(font: f, info: info, style: style, coords: coords, bundled: bundled)
        }
    }

    /// A variable font's named instances (`fvar`): (style name, axis settings).
    static func namedInstances(_ font: CTFont) -> [(String, [(String, Double)])] {
        let t = SFNT.table(font, "fvar")
        guard let axesOff = t.u16(4), let axisCount = t.u16(8), let axisSize = t.u16(10), let instCount = t.u16(12),
              let instSize = t.u16(14), axisCount > 0 else { return [] }
        var tags: [String] = []
        for a in 0 ..< Int(axisCount) {
            guard let tag = t.u32(Int(axesOff) + a * Int(axisSize)) else { return [] }
            tags.append(String(decoding: [UInt8(tag >> 24), UInt8(tag >> 16 & 0xFF), UInt8(tag >> 8 & 0xFF), UInt8(tag & 0xFF)], as: UTF8.self))
        }
        let recs = SFNT.names(font)
        let base = Int(axesOff) + Int(axisCount) * Int(axisSize)
        var out: [(String, [(String, Double)])] = []
        for i in 0 ..< Int(instCount) {
            let r = base + i * Int(instSize)
            guard let nameID = t.u16(r) else { break }
            var coords: [(String, Double)] = []
            for (a, tag) in tags.enumerated() {
                guard let v = t.u32(r + 4 + a * 4) else { break }
                coords.append((tag, Double(Int32(bitPattern: v)) / 65536.0))
            }
            guard let style = SFNT.name(recs, [nameID]) else { continue }
            out.append((style, coords))
        }
        return out
    }

    // MARK: - Lookup

    private var faces: [FontFace] { state.withLock { $0.faces } }

    /// Every family available (loaded faces and installed families), sorted, without duplicates.
    public func families() -> [String] {
        var v = faces.map(\.family)
        if systemFallback, let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] { v += names }
        v.sort { rustASCIILowercase($0) < rustASCIILowercase($1) }
        var out: [String] = []
        for f in v where !out.contains(where: { rustASCIILowercase($0) == rustASCIILowercase(f) }) { out.append(f) }
        return out
    }

    /// Style names of `family` (Regular first, then by weight).
    public func styles(_ family: String) -> [String] {
        loadInstalled(family)
        let key = rustASCIILowercase(family)
        var v = faces.filter { rustASCIILowercase($0.family) == key && !$0.style.contains("{") }.map { ($0.italic, $0.weight, $0.style) }
        v.sort { a, b in a.0 != b.0 ? !a.0 : (a.1 != b.1 ? a.1 < b.1 : a.2 < b.2) }
        var out: [String] = []
        for s in v where out.last != s.2 { out.append(s.2) }
        return out
    }

    /// Add font files' faces (embedded fonts): the number added; faces already present are skipped.
    @discardableResult
    public func addFont(_ bytes: [UInt8]) -> Int {
        add(FontDB.facesOf(data: Data(bytes), bundled: false))
    }

    private func add(_ new: [FontFace]) -> Int {
        state.withLock { s in
            var added = 0
            for f in new where !s.faces.contains(where: {
                rustASCIILowercase($0.family) == rustASCIILowercase(f.family) && rustASCIILowercase($0.style) == rustASCIILowercase(f.style)
            }) {
                s.faces.append(f)
                added += 1
            }
            return added
        }
    }

    /// Load the installed faces of `family` (once).
    private func loadInstalled(_ family: String) {
        guard systemFallback else { return }
        let key = rustASCIILowercase(family)
        if state.withLock({ $0.loadedFamilies.contains(key) }) { return }
        // One load at a time, and a family is marked loaded only once its faces are in: a thread that
        // asked while another was loading it waits, then finds the faces (deckcraft's
        // `concurrent_lookups_all_find_an_installed_family`).
        loading.withLock { _ in
            if state.withLock({ $0.loadedFamilies.contains(key) }) { return }
            _ = add(installedFaces(family, key))
            state.withLock { _ = $0.loadedFamilies.insert(key) }
        }
    }

    /// Folders deckcraft's font scan reads on macOS that CoreText doesn't catalog: the fonts Office installs
    /// inside its apps and the ones it downloads on demand (Aptos…).
    static func officeFontDirs() -> [URL] {
        var dirs = ["Microsoft PowerPoint", "Microsoft Word", "Microsoft Excel"].map {
            URL(filePath: "/Applications/\($0).app/Contents/Resources/DFonts", directoryHint: .isDirectory)
        }
        dirs.append(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Group Containers/UBF8T346G9.Office/FontCache/4/CloudFonts"))
        return dirs
    }

    /// Office's font files for family `key` (lower case). The folders are read once, a face per file.
    private func officeFiles(_ key: String) -> [URL] {
        officeIndex.withLock { index in
            if index == nil {
                var map: [String: [URL]] = [:]
                var seen: Set<String> = []
                for dir in FontDB.officeFontDirs() {
                    guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
                    for case let url as URL in files where ["ttf", "otf", "ttc", "otc"].contains(url.pathExtension.lowercased()) {
                        // The same file ships in each Office app: index one copy.
                        guard seen.insert(url.lastPathComponent.lowercased()).inserted else { continue }
                        let descs = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? []
                        for d in descs {
                            let info = SFNT.info(CTFontCreateWithFontDescriptor(d, 0, nil))
                            for name in [info.family, info.legacy?.0].compactMap({ $0 }) {
                                let k = rustASCIILowercase(name)
                                if !(map[k]?.contains(url) ?? false) { map[k, default: []].append(url) }
                            }
                        }
                    }
                }
                index = map
            }
            return index?[key] ?? []
        }
    }

    private func installedFaces(_ family: String, _ key: String) -> [FontFace] {
        var new: [FontFace] = []
        let byFamily = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let matches = (CTFontDescriptorCreateMatchingFontDescriptors(byFamily, Set([kCTFontFamilyNameAttribute as String]) as CFSet) as? [CTFontDescriptor]) ?? []
        for d in matches { new += FontDB.facesOf(descriptor: d, bundled: false) }
        if new.isEmpty {
            // A Windows family name ("Segoe UI Semibold", "Arial Black"): CoreText finds it by name.
            let byName = CTFontDescriptorCreateWithNameAndSize(family as CFString, 0)
            let f = CTFontCreateWithFontDescriptor(byName, 0, nil)
            let info = SFNT.info(f)
            if rustASCIILowercase(info.family) == key || info.legacy.map({ rustASCIILowercase($0.0) == key }) == true {
                new += FontDB.facesOf(descriptor: CTFontCopyFontDescriptor(f), bundled: false)
            }
        }
        if new.isEmpty {
            // Office's own fonts (Calibri, Cambria… where Office is installed), read from their files.
            for url in officeFiles(key) {
                guard let data = try? Data(contentsOf: url) else { continue }
                new += FontDB.facesOf(data: data, bundled: false).filter { f in
                    rustASCIILowercase(f.family) == key || f.legacy.map { rustASCIILowercase($0.family) == key } == true
                }
            }
        }
        return new
    }

    func isLoaded(_ family: String) -> Bool {
        let key = rustASCIILowercase(family)
        return faces.contains { rustASCIILowercase($0.family) == key || $0.legacy.map { rustASCIILowercase($0.family) == key } == true }
    }

    /// Is `family` available (loaded, bundled or installed)?
    public func hasFamily(_ family: String) -> Bool {
        if isLoaded(family) { return true }
        if systemFamilies.contains(rustASCIILowercase(family)) { return true }
        loadInstalled(family)
        return isLoaded(family)
    }

    private func find(_ family: String, _ style: String) -> FontFace? {
        let all = faces
        let key = rustASCIILowercase(family)
        var cands = all.filter { rustASCIILowercase($0.family) == key }
        let ns = normStyle(style)
        if cands.isEmpty {
            cands = all.filter { $0.legacy.map { rustASCIILowercase($0.family) == key } == true }
            if let f = cands.first(where: { $0.legacy.map { normStyle($0.style) == ns } == true }) { return f }
            let plain = normStyle(styleItalic(style) ? "Italic" : "Regular")
            if let f = cands.first(where: { $0.legacy.map { normStyle($0.style) == plain } == true }) { return f }
        }
        if cands.isEmpty { return nil }
        if let f = cands.first(where: { normStyle($0.style) == ns }) { return f }
        let (tw, ti) = (styleWeight(style), styleItalic(style))
        return cands.min { a, b in
            (Swift.abs(a.weight - tw) + (a.italic != ti ? 1000 : 0)) < (Swift.abs(b.weight - tw) + (b.italic != ti ? 1000 : 0))
        }
    }

    private func tryFamily(_ family: String, _ style: String) -> FontFace? {
        loadInstalled(family)
        return find(family, style)
    }

    /// Resolve a family + style to a face: the closest style of the family, then an open substitute,
    /// then Inter and the usual sans families.
    public func face(_ family: String, _ style: String) -> FontFace {
        if let f = tryFamily(family, style) { return f }
        for sub in FontDB.substitutes(family) {
            if let f = tryFamily(sub, style) { return f }
        }
        for sub in [fallbackFamily, "Helvetica Neue", "Arial", "Liberation Sans", "DejaVu Sans", "Segoe UI"] {
            if let f = tryFamily(sub, style) { return f }
        }
        return find(fallbackFamily, "Regular") ?? faces.first ?? lastResort()
    }

    /// The face a document's text in `family` is drawn with, as PowerPoint draws it: the family when it
    /// is installed or bundled, a metric-compatible stand-in, the family PowerPoint maps it to, else
    /// Calibri (Carlito).
    public func documentFace(_ family: String, _ style: String) -> FontFace {
        if rustASCIILowercase(family) == rustASCIILowercase(fallbackFamily) || FontDB.hasMetricTwin(family)
            || FontDB.isOfficeCloudFont(family) || hasFamily(family) {
            return face(family, style)
        }
        if let twin = FontDB.officeTwin(family) { return face(twin, style) }
        return face(missingFontFamily, style)
    }

    private func lastResort() -> FontFace {
        let f = CTFontCreateWithName("Helvetica" as CFString, 0, nil)
        let face = FontFace(font: f, info: SFNT.info(f), bundled: false)
        _ = add([face])
        return face
    }

    // MARK: - Fallback

    /// Families tried (when installed) for characters the loaded fonts lack: CJK, symbols, emoji.
    static let systemFallbacks = [
        "Helvetica Neue", "Arial", "Segoe UI", "Noto Sans", "DejaVu Sans", "PingFang SC", "Hiragino Sans", "Hiragino Kaku Gothic ProN",
        "Apple SD Gothic Neo", "Heiti SC", "STHeiti", "Microsoft YaHei", "Yu Gothic", "Malgun Gothic", "Noto Sans CJK SC",
        "Noto Sans CJK JP", "Arial Unicode MS", "Apple Symbols", "Segoe UI Symbol", "Noto Sans Symbols", "Noto Sans Symbols2", "Noto Emoji",
        "Segoe UI Emoji", "Apple Color Emoji", "Noto Color Emoji",
    ]

    /// First loaded face (Inter first, then upright regular weights) that covers `c`, else an installed
    /// one loaded for it.
    public func fallback(for c: Unicode.Scalar, excluding exclude: UInt32 = .max) -> FontFace? {
        if let f = loadedFallback(c, exclude, { _ in true }) { return f }
        if systemFallbackLoad(c, { _ in true }) { return loadedFallback(c, exclude, { _ in true }) }
        return nil
    }

    private func loadedFallback(_ c: Unicode.Scalar, _ exclude: UInt32, _ accept: (FontFace) -> Bool) -> FontFace? {
        let order = faces.filter { $0.id != exclude }.enumerated().sorted { x, y in
            let a = (rustASCIILowercase(x.element.family) != "inter", x.element.italic, Int(Swift.abs(x.element.weight - 400)))
            let b = (rustASCIILowercase(y.element.family) != "inter", y.element.italic, Int(Swift.abs(y.element.weight - 400)))
            return a != b ? lexLess(a, b) : x.offset < y.offset
        }
        return order.first { $0.element.covers(c) && accept($0.element) }?.element
    }

    private func lexLess(_ a: (Bool, Bool, Int), _ b: (Bool, Bool, Int)) -> Bool {
        if a.0 != b.0 { return !a.0 }
        if a.1 != b.1 { return !a.1 }
        return a.2 < b.2
    }

    /// Load an installed font covering `c`: the preferred fallback families, then CoreText's own cascade.
    private func systemFallbackLoad(_ c: Unicode.Scalar, _ accept: (FontFace) -> Bool) -> Bool {
        guard systemFallback, !c.properties.isWhitespace, c.properties.generalCategory != .control else { return false }
        if state.withLock({ $0.misses.contains(c.value) }) { return false }
        for fam in FontDB.systemFallbacks where systemFamilies.contains(rustASCIILowercase(fam)) && !isLoaded(fam) {
            loadInstalled(fam)
            if faces.contains(where: { $0.covers(c) && accept($0) }) { return true }
        }
        // CoreText's cascade for the character.
        let base = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let s = String(c) as CFString
        let f = CTFontCreateForString(base, s, CFRange(location: 0, length: CFStringGetLength(s)))
        let new = FontDB.facesOf(descriptor: CTFontCopyFontDescriptor(f), bundled: false).filter { $0.covers(c) && accept($0) }
        if !new.isEmpty, add(new) > 0 || faces.contains(where: { $0.covers(c) && accept($0) }) { return true }
        state.withLock { _ = $0.misses.insert(c.value) }
        return false
    }

    /// A loaded colour face drawing all of `cluster`, loading an installed one if needed.
    func colorFace(_ key: Unicode.Scalar, _ cluster: [Unicode.Scalar]) -> FontFace? {
        func pick() -> FontFace? {
            faces.filter { Fallback.coversCluster($0, cluster) && $0.isColor }
                .min { ($0.italic ? 1 : 0, Int(Swift.abs($0.weight - 400))) < ($1.italic ? 1 : 0, Int(Swift.abs($1.weight - 400))) }
        }
        if let f = pick() { return f }
        if systemFamilies.contains("apple color emoji") { loadInstalled("Apple Color Emoji") }
        if let f = pick() { return f }
        return systemFallbackLoad(key, { $0.isColor }) ? pick() : nil
    }

    /// A loaded plain (not colour) face drawing all of `cluster`: symbol fonts first, then the usual
    /// fallback families in order, then any other.
    func plainFace(_ key: Unicode.Scalar, _ cluster: [Unicode.Scalar]) -> FontFace? {
        func rank(_ f: FontFace) -> Int {
            if f.family.contains("Symbol") { return 0 }
            if let i = FontDB.systemFallbacks.firstIndex(where: { rustASCIILowercase($0) == rustASCIILowercase(f.family) }) { return i + 1 }
            return 1000
        }
        func pick() -> FontFace? {
            faces.enumerated().filter { !$0.element.isColor && Fallback.coversCluster($0.element, cluster) }
                .min { a, b in
                    let x = (rank(a.element), a.element.italic ? 1 : 0, Int(Swift.abs(a.element.weight - 400)), a.offset)
                    let y = (rank(b.element), b.element.italic ? 1 : 0, Int(Swift.abs(b.element.weight - 400)), b.offset)
                    return x < y
                }?.element
        }
        for fam in FontDB.systemFallbacks where fam.contains("Symbol") && systemFamilies.contains(rustASCIILowercase(fam)) {
            loadInstalled(fam)
        }
        if let f = pick() { return f }
        return systemFallbackLoad(key, { !$0.isColor }) ? pick() : nil
    }

    /// Installed faces (not craft-fonts, not `bundledFamilies`) covering `cluster`.
    func systemFace(_ key: Unicode.Scalar, _ cluster: [Unicode.Scalar], _ bundledFamilies: [String]) -> FontFace? {
        func pick() -> FontFace? {
            faces.filter { f in
                !f.bundled && !bundledFamilies.contains { rustASCIILowercase($0) == rustASCIILowercase(f.family) } && Fallback.coversCluster(f, cluster)
            }.min { ($0.italic ? 1 : 0, Int(Swift.abs($0.weight - 400))) < ($1.italic ? 1 : 0, Int(Swift.abs($1.weight - 400))) }
        }
        if let f = pick() { return f }
        return systemFallbackLoad(key, { _ in true }) ? pick() : nil
    }

    /// Every loaded face, in load order (for fallback searches).
    var loadedFaces: [FontFace] { faces }

    // MARK: - Family tables

    /// Open substitutes for families documents often ask for but can't be shipped (metric-compatible
    /// where one exists), tried in order after the family itself.
    public static func substitutes(_ family: String) -> [String] {
        switch rustASCIILowercase(family) {
        case "calibri", "calibri light": ["Carlito", "Liberation Sans", "Arial", "Inter"]
        case "cambria", "cambria math": ["Caladea", "Liberation Serif", "Times New Roman", "Merriweather"]
        case "arial", "helvetica", "helvetica neue", "arial nova": ["Liberation Sans", "Arial", "Helvetica Neue", "Helvetica", "Inter"]
        case "times new roman", "times": ["Liberation Serif", "Times New Roman", "Times", "Merriweather"]
        case "courier new", "courier", "consolas", "menlo": ["Liberation Mono", "Courier New", "Menlo", "Courier"]
        case "aptos", "aptos display", "aptos narrow", "segoe ui", "segoe ui light", "segoe ui semibold", "tahoma", "verdana":
            ["Inter", "Helvetica Neue", "Arial", "Liberation Sans"]
        case "georgia", "garamond", "book antiqua", "palatino", "palatino linotype", "constantia": ["Merriweather", "Liberation Serif", "Georgia"]
        case "century gothic", "avenir", "avenir next", "futura", "gill sans", "gill sans mt", "trebuchet ms", "corbel", "candara":
            ["Montserrat", "Poppins", "Avenir Next", "Inter"]
        case "franklin gothic", "franklin gothic book", "franklin gothic medium", "univers": ["Open Sans", "Inter"]
        case "open sans", "lato", "roboto", "montserrat", "poppins", "nunito sans": ["Inter"]
        case "playfair display", "merriweather", "source serif 4", "source serif pro": ["Merriweather", "Liberation Serif", "Georgia"]
        case "source sans 3", "source sans pro": ["Open Sans", "Inter"]
        case "impact", "arial black": ["Montserrat", "Inter"]
        default: []
        }
    }

    /// Families whose open substitutes keep their metrics, so text breaks into the same lines.
    static func hasMetricTwin(_ family: String) -> Bool {
        ["calibri", "calibri light", "cambria", "cambria math", "arial", "helvetica", "times new roman", "times", "courier new", "courier"]
            .contains(rustASCIILowercase(family))
    }

    /// The installed family PowerPoint draws a missing `family` with instead of Calibri.
    static func officeTwin(_ family: String) -> String? {
        let f = rustASCIILowercase(family)
        switch f {
        case "liberation sans", "helvetica", "helv": return "Arial"
        case "liberation serif", "times", "tms rmn": return "Times New Roman"
        default: break
        }
        for suffix in [" baltic", " ce", " cyr", " greek", " tur"] where f.hasSuffix(suffix) {
            switch String(f.dropLast(suffix.count)) {
            case "arial": return "Arial"
            case "courier new": return "Courier New"
            case "times new roman": return "Times New Roman"
            default: return nil
            }
        }
        return nil
    }

    /// Office's downloadable (cloud) families, which PowerPoint fetches and draws as themselves.
    static func isOfficeCloudFont(_ family: String) -> Bool {
        let f = rustASCIILowercase(family)
        return f.hasPrefix("aptos") || ["bierstadt", "grandview", "seaford", "skeena", "tenorite"].contains { f.hasPrefix($0) }
    }

    /// The craft-fonts families for a script (ISO 15924 tag), in manifest order.
    public func bundledFamilies(_ script: ScriptTag) -> [String] {
        bundledScripts.filter { $0.scripts.contains(script) }.map(\.family)
    }
}
