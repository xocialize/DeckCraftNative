// DCPPT — the slide show (P5): the motion deck (Tools/legacy/motion-deck.py), saved as .ppt by LibreOffice and by
// PowerPoint (local only), comes back with its original's transitions by kind, option and speed, its hidden slide and
// timings, and its animations in order with their effects, options, starts and timings; the hash that tells a
// PowerPoint 97 edit from a current timing tree is PowerPoint's; and hostile timing records never trap.
import DCModel
import DCPPTX
import DCZip
import Foundation
import Testing
@testable import DCPPT

@Suite struct SlideShowTests {
    /// A transition's speed as a `.ppt` holds it: fast, medium or slow.
    static func speed(_ ms: UInt32) -> Int { ms <= 500 ? 2 : ms <= 750 ? 1 : 0 }

    /// The differences between a `.ppt`'s slide show and its original's, one line each.
    static func differences(_ ours: Presentation, _ want: Presentation, producer: String) -> [String] {
        var out: [String] = []
        guard ours.slides.count == want.slides.count else { return ["\(ours.slides.count) slides, original \(want.slides.count)"] }
        for (i, (s, o)) in zip(ours.slides, want.slides).enumerated() {
            let at = "slide \(i + 1)"
            if s.hidden != o.hidden { out.append("\(at): hidden \(s.hidden)") }
            switch (s.transition, o.transition) {
            case (nil, nil): break
            case (let t?, let u?):
                // What a .ppt can't hold, PowerPoint saves as Fade.
                let kept = SlideShowTests.pptKinds.contains("\(u.kind) \(u.option)")
                if kept {
                    if t.kind != u.kind || t.option != u.option { out.append("\(at): \(t.kind) \(t.option), original \(u.kind) \(u.option)") }
                    if speed(t.durationMs) != speed(u.durationMs) { out.append("\(at): \(t.durationMs) ms, original \(u.durationMs) ms") }
                } else if producer == "PowerPoint", t.kind != "fade" {
                    out.append("\(at): \(t.kind) for \(u.kind)")
                }
                if t.advanceOnClick != u.advanceOnClick || t.advanceAfterMs != u.advanceAfterMs {
                    out.append("\(at): advance \(t.advanceOnClick) \(String(describing: t.advanceAfterMs)), original \(u.advanceOnClick) \(String(describing: u.advanceAfterMs))")
                }
            case (let t, let u):
                out.append("\(at): transition \(t?.kind ?? "none"), original \(u?.kind ?? "none")")
            }
            func index(_ shapes: [Shape], _ id: ShapeId) -> Int? { shapes.firstIndex { $0.id == id } }
            if s.animations.count != o.animations.count {
                out.append("\(at): \(s.animations.count) animations, original \(o.animations.count)")
                continue
            }
            for (k, (a, b)) in zip(s.animations, o.animations).enumerated() {
                let what = "\(at) animation \(k + 1) (\(b.effect) \(b.option))"
                if index(s.shapes, a.shape) != index(o.shapes, b.shape) { out.append("\(what): shape") }
                if a.class != b.class || a.effect != b.effect || a.option != b.option {
                    out.append("\(what): \(a.class) \(a.effect) \(a.option)")
                }
                if a.start != b.start { out.append("\(what): start \(a.start)") }
                if a.delayMs != b.delayMs { out.append("\(what): delay \(a.delayMs)") }
                if a.durationMs != b.durationMs { out.append("\(what): duration \(a.durationMs), original \(b.durationMs)") }
                if a.repeat != b.repeat { out.append("\(what): repeat \(a.repeat)") }
                if a.rewind != b.rewind { out.append("\(what): rewind \(a.rewind)") }
                if a.textBuild != b.textBuild { out.append("\(what): text build \(a.textBuild)") }
                if a.paragraph != b.paragraph { out.append("\(what): paragraph \(String(describing: a.paragraph))") }
                if a.amount != b.amount { out.append("\(what): amount \(String(describing: a.amount)), original \(String(describing: b.amount))") }
                // LibreOffice leaves out a path's closing `E`, which is implied.
                func path(_ p: String?) -> String? { p.map { $0.hasSuffix(" E") ? String($0.dropLast(2)) : $0 } }
                if path(a.path) != path(b.path) { out.append("\(what): path \(a.path ?? "-")") }
            }
        }
        return out
    }

    /// The transitions a `.ppt` holds, by kind and option.
    static let pptKinds: Set<String> = Set((0 ... 27).flatMap { t in (0 ... 8).compactMap { d in
        SlideShow.kind(UInt8(t), UInt8(d)).map { "\($0.0) \($0.1)" }
    } })

    /// LibreOffice's and PowerPoint's saves of the motion deck come back as the original.
    @Test(arguments: ["LibreOffice", "PowerPoint"]) func theMotionDeckComesBackAsTheOriginal(producer: String) throws {
        let original = PPTFileTests.legacy.appending(path: "pptx/motion.pptx")
        let file = producer == "PowerPoint" ? ShapeTests.local.appending(path: "motion.open.ppt") : PPTFileTests.legacy.appending(path: "ppt/motion.ppt")
        guard FileManager.default.fileExists(atPath: file.path), FileManager.default.fileExists(atPath: original.path) else { return }
        let (ours, _) = try PPT.importChecked(Array(try Data(contentsOf: file)), password: producer == "PowerPoint" ? "Password1" : nil)
        let (want, _) = try PPTX.importChecked(Array(try Data(contentsOf: original)))
        var diffs = Self.differences(ours, want, producer: producer)
        if producer == "LibreOffice" {
            // How LibreOffice writes these (each checked in its records; PowerPoint's save of the deck has none of
            // them): Cut through black as plain Cut, Push Right as Left, Uncover Left as Right, a diagonal Wipe as
            // Cover, Shape In and Out as Cut, an advance time in 1024ths of a second with "on click" kept, a Pulse's
            // and a Grow/Shrink's size as the change from 100%, and no paragraph builds (each paragraph's effect is
            // its own); and Vortex and Ripple as Cut, where PowerPoint keeps Fade.
            let known = ["slide 4:", "slide 30:", "slide 31:", "slide 6:", "slide 9:", "slide 16:", "slide 20:", "slide 21:", "slide 32:",
                         "slide 36 animation 1 (pulse ): amount", "slide 36 animation 3 (growShrink ): amount", "slide 38: 9 animations"]
            diffs.removeAll { d in known.contains { d.hasPrefix($0) } }
        }
        #expect(diffs.isEmpty, "\(producer):\n\(diffs.joined(separator: "\n"))")
        #expect(ours.slides.reduce(0) { $0 + $1.animations.count } >= 50)
        #expect(ours.slides.filter { $0.transition != nil }.count >= (producer == "PowerPoint" ? 31 : 25))
    }

    /// PowerPoint's saves of the corpus's and engine's decks (local only) come back with their originals' slide shows.
    @Test func powerPointsDecksComeBackWithTheirSlideShows() throws {
        var animations = 0, decks = 0
        for n in ["corpus-motion", "corpus-sample", "engine-design-animations", "engine-design-transitions", "engine-transitions"] {
            let file = ShapeTests.local.appending(path: "\(n).open.ppt"), original = PPTFileTests.legacy.appending(path: "pptx/\(n).pptx")
            guard FileManager.default.fileExists(atPath: file.path), FileManager.default.fileExists(atPath: original.path) else { continue }
            let (ours, _) = try PPT.importChecked(Array(try Data(contentsOf: file)), password: "Password1")
            let (want, _) = try PPTX.importChecked(Array(try Data(contentsOf: original)))
            let diffs = Self.differences(ours, want, producer: "PowerPoint")
            #expect(diffs.isEmpty, "\(n):\n\(diffs.joined(separator: "\n"))")
            animations += ours.slides.reduce(0) { $0 + $1.animations.count }
            decks += 1
        }
        if decks > 0 { #expect(animations >= 10) }
    }

    // MARK: Hand-built records

    static func record(_ type: UInt16, instance: UInt16 = 0, version: UInt8 = 0, _ body: [UInt8]) -> [UInt8] {
        let vi = instance << 4 | UInt16(version)
        return [UInt8(vi & 0xFF), UInt8(vi >> 8), UInt8(type & 0xFF), UInt8(type >> 8)] + le(UInt32(body.count)) + body
    }

    static func le(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }

    /// An AnimationInfoAtom's 28 bytes.
    static func atom97(effect: UInt8, direction: UInt8, order: Int16, automatic: Bool = false, delay: UInt32 = 0,
                       build: UInt8 = 1, text: UInt8 = 0) -> [UInt8]
    {
        var a = [UInt8](repeating: 0, count: 28)
        if automatic { a[4] = 0x4 }
        a.replaceSubrange(12 ..< 16, with: le(delay))
        a[16] = UInt8(UInt16(bitPattern: order) & 0xFF)
        a[17] = UInt8(UInt16(bitPattern: order) >> 8)
        a[20] = build
        a[21] = effect
        a[22] = direction
        a[24] = text
        return a
    }

    /// A timing tree with one Fade entrance on shape `spid`.
    static func fadeTree(_ spid: UInt32) -> [UInt8] {
        func variant(_ id: UInt16, _ v: UInt32) -> [UInt8] { record(RT.timeVariant, instance: id, [1] + le(v)) }
        func node(type: UInt32, duration: UInt32 = 0, flags: UInt32 = 0) -> [UInt8] {
            record(RT.timeNode, [0, 0, 0, 0] + le(0) + le(type) + le(0) + le(0) + [0, 0, 0, 0] + le(duration) + le(flags))
        }
        let target = record(RT.timeClientVisualElement, version: 0xF, record(RT.visualShapeAtom, le(0) + le(1) + le(spid) + le(.max) + le(.max)))
        let set = record(RT.timeSetBehavior, version: 0xF, record(0xF13A, [UInt8](repeating: 0, count: 8))
            + record(RT.timeBehaviorContainer, version: 0xF, record(0xF133, [UInt8](repeating: 0, count: 16)) + target))
        let behavior = record(RT.timeExtTimeNode, instance: 1, version: 0xF, node(type: 3, duration: 500, flags: 0x10) + set)
        let props = record(RT.timePropertyList, version: 0xF, variant(0x0B, 1) + variant(0x09, 10) + variant(0x14, 1))
        return record(RT.timeExtTimeNode, instance: 1, version: 0xF, node(type: 0) + props + behavior)
    }

    /// A slide holding `inside`, then the drawn shapes' client data with their AnimationInfoAtoms.
    static func slide(_ inside: [UInt8], atoms: [(UInt32, [UInt8])]) -> (b: [UInt8], slide: Record, drawn: [DrawnShape]) {
        let s = record(RT.slide, version: 0xF, inside)
        var b = s
        var drawn: [DrawnShape] = []
        for (id, a) in atoms {
            let at = b.count
            b += record(RT.animationInfo, version: 0xF, record(RT.animationInfoAtom, a))
            drawn.append(DrawnShape(id: id, type: 1, flags: 0, clientData: [Record(b, at: at)].compactMap { $0 }))
        }
        return (b, Record(b, at: 0) ?? Record([0, 0, 0, 0, 0, 0, 0, 0], at: 0)!, drawn)
    }

    static func pp10(_ body: [UInt8]) -> [UInt8] {
        let name = Array("___PPT10".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        return record(RT.progTags, version: 0xF, record(RT.progBinaryTag, version: 0xF,
                      record(RT.cString, name) + record(RT.binaryTagDataBlob, body)))
    }

    /// PowerPoint 97's effects map to the nearest preset and play in their order; the timing tree wins while its hash
    /// is the atoms', and they win once it isn't; the hash is the one PowerPoint wrote in its own file.
    @Test func powerPoint97EffectsAndTheTreeTheHashChooses() throws {
        let atoms: [(UInt32, [UInt8])] = [
            (5, Self.atom97(effect: 12, direction: 0, order: 2)),  // Fly from the left
            (6, Self.atom97(effect: 10, direction: 3, order: 1, automatic: true, delay: 500)),  // Wipe from the top
            (7, Self.atom97(effect: 13, direction: 2, order: 3)),  // Split, vertically out
            (8, Self.atom97(effect: 6, direction: 0, order: 4, build: 0)),  // No build: not animated
        ]
        let ids: [UInt32: ShapeId] = [5: ShapeId(105), 6: ShapeId(106), 7: ShapeId(107), 8: ShapeId(108)]
        let plain = Self.slide([], atoms: atoms)
        let legacy = SlideShow.animations(plain.b, plain.slide, drawn: plain.drawn, shapes: [], ids: ids, scheme: [])
        #expect(legacy.map { "\($0.shape.rawValue) \($0.effect) \($0.option) \($0.start)" }
            == ["106 wipe t afterPrevious", "105 fly l onClick", "107 split vertOut onClick"])
        #expect(legacy.first?.delayMs == 500)

        let hash = SlideShow.hash(plain.b, SlideShow.animationAtoms(plain.b, plain.drawn))
        for (stored, effects) in [(hash, ["106 fade"]), (hash ^ 1, ["106 wipe", "105 fly", "107 split"])] {
            let s = Self.slide(Self.pp10(Self.record(RT.hashCodeAtom, Self.le(stored)) + Self.fadeTree(6)), atoms: atoms)
            let got = SlideShow.animations(s.b, s.slide, drawn: s.drawn, shapes: [], ids: ids, scheme: [])
            #expect(got.map { "\($0.shape.rawValue) \($0.effect)" } == effects, "hash \(stored)")
        }

        // PowerPoint's own file: a slide with one atom, whose tree carries the atom's hash.
        let file = ShapeTests.local.appending(path: "corpus-motion.open.ppt")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let ppt = try PPTFile(Array(try Data(contentsOf: file)), password: "Password1")
        var checked = 0
        for ref in ppt.directory.keys.sorted() {
            guard let o = ppt.object(ref), let r = Record(o, at: 0), r.type == RT.slide else { continue }
            let (drawn, _) = Drawing.tree(o, r)
            let found = SlideShow.animationAtoms(o, drawn)
            guard !found.isEmpty, let tag = SlideShow.binaryTag(o, r, "___PPT10"),
                  let stored = tag.children(o).first(where: { $0.type == RT.hashCodeAtom }) else { continue }
            #expect(SlideShow.hash(o, found) == le32(o, stored.body.lowerBound))
            checked += 1
        }
        #expect(checked == 1)
    }

    /// The `p:timing` PowerPoint 2007 embedded is read when a slide has no timing tree.
    @Test func anEmbeddedTimingIsRead() throws {
        let xml = """
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:timing><p:tnLst><p:par>\
        <p:cTn id="1" dur="indefinite" nodeType="tmRoot"><p:childTnLst><p:seq><p:cTn id="2" nodeType="mainSeq"><p:childTnLst>\
        <p:par><p:cTn id="3" fill="hold"><p:stCondLst><p:cond delay="indefinite"/></p:stCondLst><p:childTnLst>\
        <p:par><p:cTn id="4" presetID="2" presetClass="entr" presetSubtype="8" fill="hold" nodeType="clickEffect">\
        <p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst><p:set><p:cBhvr><p:cTn id="5" dur="1"/><p:tgtEl>\
        <p:spTgt spid="7"/></p:tgtEl></p:cBhvr></p:set></p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn></p:par>\
        </p:childTnLst></p:cTn></p:seq></p:childTnLst></p:cTn></p:par></p:tnLst></p:timing></p:sld>
        """
        var zip = ZipWriter()
        try zip.add("[Content_Types].xml", Array("<Types/>".utf8))
        try zip.add("ppt/slides/slide1.xml", Array(xml.utf8))
        let s = Self.slide(Self.record(RT.roundTripAnimation, try zip.finish()), atoms: [])
        let got = SlideShow.animations(s.b, s.slide, drawn: [], shapes: [], ids: [7: ShapeId(70)], scheme: [])
        #expect(got.map { "\($0.shape.rawValue) \($0.effect) \($0.option)" } == ["70 fly l"])
    }

    /// Damaged and hostile slide show records never trap or run away: every byte of a real slide's records changed in
    /// turn, a tree nested past the limit, and a transition of every type and direction.
    @Test func hostileSlideShowsAreBounded() throws {
        let file = PPTFileTests.legacy.appending(path: "ppt/motion.ppt")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let ppt = try PPTFile(Array(try Data(contentsOf: file)))
        var seed: UInt64 = 20261030
        func next() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: seed >> 33)
        }
        var mutated = 0
        let slides = ppt.directory.keys.sorted().compactMap { ppt.object($0) }.filter { Record($0, at: 0)?.type == RT.slide }
        for o in slides.suffix(3) {
            for _ in 0 ..< 300 {
                var b = o
                for _ in 0 ..< 4 { let i = next() % b.count; b[i] = UInt8(truncatingIfNeeded: next()) }
                guard let r = Record(b, at: 0) else { continue }
                let (drawn, _) = Drawing.tree(b, r)
                _ = SlideShow.transition(b, r) { _ in nil }
                _ = SlideShow.animations(b, r, drawn: drawn, shapes: [], ids: [:], scheme: [])
                mutated += 1
            }
        }
        #expect(mutated > 0)

        var deep = Self.fadeTree(6)
        for _ in 0 ..< 200 { deep = Self.record(RT.timeExtTimeNode, instance: 1, version: 0xF, Self.record(RT.timeNode, [UInt8](repeating: 0, count: 32)) + deep) }
        let s = Self.slide(Self.pp10(deep), atoms: [])
        _ = SlideShow.animations(s.b, s.slide, drawn: [], shapes: [], ids: [6: ShapeId(60)], scheme: [])

        for t in 0 ... 255 {
            for d in [0, 1, 4, 9, 255] {
                let info = [UInt8](repeating: 0xFF, count: 8) + [UInt8(d), UInt8(t), 0xFF, 0xFF, 0xFF, 0, 0, 0]
                let s = Self.slide(Self.record(RT.slideShowSlideInfoAtom, info), atoms: [])
                _ = SlideShow.transition(s.b, s.slide) { _ in nil }
            }
        }
    }
}
