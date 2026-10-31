// DCPPT — a slide's slide show (P5, Docs/plans/Legacy-PPT-and-Encryption.md): its transition, whether it's hidden,
// and its animations.
//
// - **Transitions** are the SlideShowSlideInfoAtom's ([MS-PPT] 2.6.6): PowerPoint 97's effects with their direction
//   and one of three speeds. PowerPoint 2010's transitions have no place in a `.ppt`: PowerPoint saves them as Fade.
// - **Animations** come from one of three places, the newest that is current:
//   1. PowerPoint 2002's timing tree (the ExtTimeNodeContainer and BuildListContainer in the slide's `___PPT10`
//      binary tag, 2.8.15). It is PresentationML's `p:timing` in records, node for node, so it is turned into that
//      element and read by DCPPTX's timing reader, as a `.pptx` is.
//   2. The `p:timing` PowerPoint 2007 embedded in a RoundTripAnimationAtom (2.11.7), read the same way. PowerPoint 16
//      writes none, and a later PowerPoint 2002 or 2003 save keeps an old one, so it is used only without a tree.
//   3. PowerPoint 97's AnimationInfoAtoms, one per shape (2.8.2), mapped to the nearest effect. The tree carries a
//      hash of these atoms (HashCode10Atom, 2.8.3); when PowerPoint 97 or 2000 changed them after a newer version
//      saved the tree, the hash no longer matches and the atoms win, as in PowerPoint.
import DCColor
import DCCore
import DCModel
import DCPPTX
import DCZip

enum SlideShow {
    /// Most time nodes read from one slide, and how deep they nest.
    static let maxNodes = 20_000
    static let maxDepth = 64
    /// Largest embedded package and timing part read.
    static let maxRoundTrip = 16 << 20

    // MARK: Transitions

    /// A slide's transition and whether it's hidden. `sound` gives the media of a sound in the SoundCollection.
    static func transition(_ b: [UInt8], _ slide: Record, sound: (UInt32) -> MediaId?) -> (transition: Transition?, hidden: Bool) {
        guard let atom = slide.children(b).first(where: { $0.type == RT.slideShowSlideInfoAtom }), atom.body.count >= 16 else {
            return (nil, false)
        }
        let p = atom.body.lowerBound
        let time = i32(b, p), soundRef = le32(b, p + 4)
        let direction = b[p + 8], type = b[p + 9], flags = le16(b, p + 10), speed = b[p + 12]
        let hidden = flags & 0x4 != 0
        guard let (kind, option) = Self.kind(type, direction) else { return (nil, hidden) }
        // Cut not through black "is the same as no transition at all" (2.6.6): PowerPoint writes it for a slide with
        // none that needs the atom for another reason, such as being hidden.
        let sounds = flags & 0x10 != 0 && soundRef != 0
        if type == 0, direction != 1, flags & 0x1 != 0, flags & (0x400 | 0x100) == 0, !sounds { return (nil, hidden) }
        var t = Transition.default
        t.kind = kind
        let hasOptions = transitions.first { $0.id == kind }.map { !$0.options.isEmpty } ?? false
        t.option = hasOptions ? option : ""
        // The three speeds, as a `.pptx` that gives only `spd` reads.
        let defaultDuration = transitions.first { $0.id == kind }?.defaultDurationMs ?? 1000
        t.durationMs = switch speed {
        case 0: max(defaultDuration, 1000)
        case 1: 750
        default: 500
        }
        t.advanceOnClick = flags & 0x1 != 0
        if flags & 0x400 != 0 { t.advanceAfterMs = UInt32(clamping: min(max(time, 0), 86_399_000)) }
        if sounds {
            t.sound = sound(soundRef)
            t.soundLoop = t.sound != nil && flags & 0x40 != 0
        }
        t.stopSound = flags & 0x100 != 0
        return (t, hidden)
    }

    /// Our transition and option for an effectType and effectDirection; nil for one that isn't defined.
    static func kind(_ type: UInt8, _ direction: UInt8) -> (String, String)? {
        let eight = ["l", "u", "r", "d", "lu", "ru", "ld", "rd"]
        let four = ["l", "u", "r", "d"]
        func pick(_ list: [String], _ fallback: String) -> String { Int(direction) < list.count ? list[Int(direction)] : fallback }
        switch type {
        case 0: return ("cut", direction == 1 ? "throughBlack" : "")
        case 1: return ("random", "")
        case 2: return ("blinds", direction == 1 ? "horz" : "vert")
        case 3: return ("checker", direction == 1 ? "vert" : "horz")
        case 4: return ("cover", pick(eight, "l"))
        case 5: return ("dissolve", "")
        case 6: return ("fade", "throughBlack")
        case 7: return ("uncover", pick(eight, "l"))
        case 8: return ("randomBar", direction == 1 ? "vert" : "horz")
        case 9: return ("wipe", (4 ... 7).contains(direction) ? eight[Int(direction)] : "lu")
        case 10: return ("wipe", pick(four, "l"))
        case 11: return ("shape", direction == 1 ? "in" : "out")
        case 13: return ("split", pick(["horzOut", "horzIn", "vertOut", "vertIn"], "horzOut"))
        case 17: return ("shape", "diamond")
        case 18: return ("shape", "plus")
        case 19: return ("clock", "wedge")
        case 20: return ("push", pick(four, "l"))
        case 21: return ("comb", direction == 1 ? "vert" : "horz")
        case 22: return ("zoom", "rotate")
        case 23: return ("fade", "smoothly")
        case 26: return ("clock", "clockwise")
        case 27: return ("shape", "circle")
        default: return nil
        }
    }

    // MARK: Animations

    /// A slide's animations. `drawn` are its drawn shapes and `shapes` the slide's, `ids` maps the one's ids to the
    /// other's; `scheme` resolves scheme colours in colour effects.
    static func animations(_ b: [UInt8], _ slide: Record, drawn: [DrawnShape], shapes: [Shape], ids: [UInt32: ShapeId],
                           scheme: [Rgba]) -> [Animation]
    {
        let atoms = animationAtoms(b, drawn)
        let pp10 = binaryTag(b, slide, "___PPT10").map { $0.children(b) } ?? []
        let tree = pp10.first { $0.type == RT.timeExtTimeNode }
        let stored = pp10.first { $0.type == RT.hashCodeAtom && $0.body.count >= 4 }.map { le32(b, $0.body.lowerBound) }
        // A tree whose hash doesn't match the atoms is older than they are.
        let current = atoms.isEmpty || stored.map { $0 == hash(b, atoms) } ?? false
        let texts = TimingTree.texts(shapes, ids)
        if current, let tree {
            var t = TimingTree(b: b, texts: texts, scheme: scheme)
            if let timing = t.timing(tree, builds: pp10.first { $0.type == RT.buildList }) {
                return PPTXTiming.animations(timing, shapes: shapes, ids: ids)
            }
        }
        if current, let timing = roundTrip(b, slide) {
            return PPTXTiming.animations(timing, shapes: shapes, ids: ids)
        }
        return legacy(b, atoms, shapes: shapes, ids: ids)
    }

    /// The data of the slide's programmable binary tag named `name` (`___PPT10`).
    static func binaryTag(_ b: [UInt8], _ slide: Record, _ name: String) -> Record? {
        guard let tags = slide.children(b).first(where: { $0.type == RT.progTags }) else { return nil }
        for tag in tags.children(b) where tag.type == RT.progBinaryTag {
            let kids = tag.children(b)
            guard let n = kids.first(where: { $0.type == RT.cString }), Document.unicode(b, n.body) == name else { continue }
            return kids.first { $0.type == RT.binaryTagDataBlob }
        }
        return nil
    }

    /// The `p:timing` in the slide's RoundTripAnimationAtom: a package holding a timing part.
    static func roundTrip(_ b: [UInt8], _ slide: Record) -> XMLEl? {
        guard let atom = slide.children(b).first(where: { $0.type == RT.roundTripAnimation }), atom.body.count <= maxRoundTrip,
              let zip = try? ZipReader(Array(b[atom.body]))
        else { return nil }
        for e in zip.entries.prefix(256) where e.name.hasSuffix(".xml") {
            if let xml = try? zip.read(e, max: maxRoundTrip), let t = PPTXTiming.timing(in: xml) { return t }
        }
        return nil
    }

    /// Each drawn shape's AnimationInfoAtom (in its client data's AnimationInfoContainer), with the shape's id, in
    /// z-order, groups' members included.
    static func animationAtoms(_ b: [UInt8], _ drawn: [DrawnShape], depth: Int = 0) -> [(id: UInt32, atom: Range<Int>)] {
        guard depth < Drawing.maxDepth else { return [] }
        return drawn.flatMap { d -> [(id: UInt32, atom: Range<Int>)] in
            let own = d.clientData.first { $0.type == RT.animationInfo }
                .flatMap { $0.children(b).first { $0.type == RT.animationInfoAtom && $0.body.count >= 28 } }
                .map { [(d.id, $0.body.lowerBound ..< $0.body.lowerBound + 28)] } ?? []
            return own + animationAtoms(b, d.children, depth: depth + 1)
        }
    }

    /// The HashCode10Atom's hash of a slide's AnimationInfoAtoms (2.8.3): each byte of each atom picks a word of a
    /// fixed pseudo-random table, by its value and by the shape's id times its position, and the words are XORed.
    /// PowerPoint hashes the shapes that have an atom (measured on its own files).
    static func hash(_ b: [UInt8], _ atoms: [(id: UInt32, atom: Range<Int>)]) -> UInt32 {
        var h: UInt32 = 0
        for (id, atom) in atoms {
            for (k, at) in atom.enumerated() where at < b.count {
                let row = Int((UInt64(id) &* UInt64(k + 1)) % 256)
                h ^= hashTable[row * 256 + Int(b[at])]
            }
        }
        return h
    }

    /// The 256×256 table of 2.8.3, built from its linear congruential generator.
    static let hashTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 65536)
        var seed: UInt32 = 1
        func next(_ r: UInt32) -> UInt32 { ((r &* 0x343FD &+ 0x269EC3) >> 16) & 0x7FFF }
        for i in 0 ..< 65536 {
            let r1 = next(seed), r2 = next(r1), r3 = next(r2), r4 = next(r3)
            seed = r4
            table[i] = (r4 % 256) << 24 | (r3 % 256) << 16 | (r2 % 256) << 8 | (r1 % 256)
        }
        return table
    }()

    // MARK: PowerPoint 97

    /// PowerPoint 97's per-shape effects as animations, in their order: each atom's effect mapped to the nearest
    /// preset, on click or after the previous one with its delay, and its text build.
    static func legacy(_ b: [UInt8], _ atoms: [(id: UInt32, atom: Range<Int>)], shapes: [Shape], ids: [UInt32: ShapeId]) -> [Animation] {
        var out: [(order: Int, index: Int, anim: Animation)] = []
        for (i, (id, atom)) in atoms.enumerated() {
            let p = atom.lowerBound
            let flags = le32(b, p + 4), delay = i32(b, p + 12), order = Int16(bitPattern: le16(b, p + 16))
            let buildType = b[p + 20], effect = b[p + 21], direction = b[p + 22], textBuild = b[p + 24]
            // No build (0), or following the master (0xFE), animates nothing on the slide itself; past 0x06 a chart
            // builds by series or category, which plays here as one object.
            guard buildType != 0, buildType != 0xFE, let shape = ids[id], let (preset, subtype) = preset97(effect, direction) else { continue }
            let (name, option) = PPTXTiming.effect(.entrance, preset: preset, subtype: subtype)
            var a = Animation.default
            a.shape = shape
            a.class = .entrance
            a.effect = name
            a.option = option
            a.presetId = preset
            a.presetSubtype = subtype
            a.durationMs = preset == 1 ? 0 : 500
            if flags & 0x4 != 0 {
                a.start = .afterPrevious
                a.delayMs = UInt32(clamping: max(delay, 0))
            }
            let text = findShape(shapes, shape)?.text.map { !$0.paragraphs.isEmpty } ?? false
            if text {
                switch textBuild {
                case 1: a.textBuild = .byWord
                case 2: a.textBuild = .byLetter
                default: if (2 ... 6).contains(buildType) { a.textBuild = .byParagraph }
                }
            }
            out.append((Int(order), i, a))
        }
        return out.sorted { ($0.order, $0.index) < ($1.order, $1.index) }.map(\.anim)
    }

    /// The entrance preset and subtype nearest a PowerPoint 97 animEffect and animEffectDirection; nil for one that
    /// isn't defined.
    static func preset97(_ effect: UInt8, _ direction: UInt8) -> (UInt32, UInt32)? {
        // Direction bits of a preset subtype: 1 top, 2 right, 4 bottom, 8 left.
        let from: [UInt32] = [8, 1, 2, 4, 9, 3, 12, 6]
        let towards: [UInt32] = [2, 4, 8, 1, 6, 12, 3, 9]
        func at(_ list: [UInt32], _ d: UInt8, _ fallback: UInt32) -> UInt32 { Int(d) < list.count ? list[Int(d)] : fallback }
        switch effect {
        case 0: return (1, 0)  // Cut: Appear
        case 1: return (24, 0)  // Random Effects
        case 2: return (3, direction == 1 ? 10 : 5)  // Blinds
        case 3: return (5, direction == 1 ? 5 : 10)  // Checkerboard
        case 4: return (2, at(towards, direction, 2))  // Cover: flies in from where it covers from
        case 5: return (9, 0)  // Dissolve In
        case 6: return (10, 0)  // Fade
        case 7: return (direction < 4 ? 22 : 18, direction < 4 ? at(towards, direction, 2) : at(towards, direction, 6))  // Uncover: Wipe or Strips
        case 8: return (14, direction == 1 ? 5 : 10)  // Random Bars
        case 9: return (18, at(towards, direction, 6))  // Strips
        case 10: return (22, at(towards, direction, 2))  // Wipe
        case 11: return (4, direction == 1 ? 16 : 32)  // Box
        case 12:
            switch direction {
            case 0 ... 7: return (2, at(from, direction, 8))  // Fly In
            case 8 ... 11: return (12, [8, 4, 2, 1][Int(direction) - 8])  // Peek In, from the shape's own edge
            case 12 ... 15: return (2, [8, 1, 2, 4][Int(direction) - 12])  // Crawl: a slow Fly In
            case 16, 17, 20: return (53, 16)  // Zoom in
            case 18, 19, 21: return (53, 32)  // Zoom out
            case 22 ... 26: return (55, 0)  // Stretch: Expand
            case 27: return (45, 10)  // Swivel
            default: return (10, 0)  // Spiral: Fade
            }
        case 13: return (16, [42, 21, 37, 26][Int(min(direction, 3))])  // Split
        case 14: return (10, 0)  // Flash: Fade
        case 17: return (8, 32)  // Diamond
        case 18: return (6, 32)  // Plus: Shape
        case 19: return (21, 1)  // Wedge: Wheel
        case 26: return (21, [1, 2, 3, 4, 8].contains(UInt32(direction)) ? UInt32(direction) : 1)  // Wheel
        case 27: return (6, 32)  // Circle: Shape
        default: return nil
        }
    }
}

/// PowerPoint 2002's binary timing tree as the `p:timing` it encodes ([MS-PPT] 2.8.15–2.8.82): each
/// ExtTimeNodeContainer a `p:par`, `p:seq`, behaviour or media node with its `p:cTn`, properties, conditions and
/// modifiers; each behaviour's target a `p:spTgt`; the BuildListContainer's paragraph builds `p:bldP`.
struct TimingTree {
    let b: [UInt8]
    /// Each shape's paragraphs' lengths, by its id in the file, to turn a character range into a paragraph.
    let texts: [UInt32: [Int]]
    let scheme: [Rgba]
    var nextId = 1
    var count = 0

    /// Each shape's paragraphs' lengths in UTF-16 units, the paragraph mark included, by file id.
    static func texts(_ shapes: [Shape], _ ids: [UInt32: ShapeId]) -> [UInt32: [Int]] {
        var lengths: [ShapeId: [Int]] = [:]
        func walk(_ list: [Shape], _ depth: Int) {
            guard depth <= SlideShow.maxDepth else { return }
            for s in list {
                if let text = s.text { lengths[s.id] = text.paragraphs.map { p in p.runs.reduce(0) { $0 + $1.text.utf16.count } + 1 } }
                walk(s.children, depth + 1)
            }
        }
        walk(shapes, 0)
        return ids.compactMapValues { lengths[$0] }
    }

    mutating func timing(_ root: Record, builds: Record?) -> XMLEl? {
        guard let node = node(root, 0) else { return nil }
        var children: [XMLNode] = [.el(el("p:tnLst", [], [.el(node)]))]
        if let builds {
            let list = builds.children(b).compactMap(paraBuild)
            if !list.isEmpty { children.append(.el(el("p:bldLst", [], list.map { .el($0) }))) }
        }
        return el("p:timing", [], children)
    }

    /// A ParaBuildContainer as `p:bldP`.
    func paraBuild(_ r: Record) -> XMLEl? {
        guard r.type == RT.paraBuild else { return nil }
        let kids = r.children(b)
        guard let build = kids.first(where: { $0.type == RT.buildAtom && $0.body.count >= 12 }),
              let para = kids.first(where: { $0.type == RT.paraBuildAtom && $0.body.count >= 8 })
        else { return nil }
        let kind = switch le32(b, para.body.lowerBound) {
        case 0: "allAtOnce"
        case 1: "p"
        case 2: "cust"
        default: "whole"
        }
        return el("p:bldP", [("spid", String(le32(b, build.body.lowerBound + 8))), ("grpId", String(le32(b, build.body.lowerBound + 4))),
                             ("build", kind), ("bldLvl", String(le32(b, para.body.lowerBound + 4)))], [])
    }

    /// One ExtTimeNodeContainer.
    mutating func node(_ r: Record, _ depth: Int) -> XMLEl? {
        guard depth < SlideShow.maxDepth, count < SlideShow.maxNodes else { return nil }
        count += 1
        let kids = r.children(b)
        guard let atom = kids.first(where: { $0.type == RT.timeNode && $0.body.count >= 32 }) else { return nil }
        let p = atom.body.lowerBound
        let type = le32(b, p + 8)
        var ctn = cTn(atom, kids.first { $0.type == RT.timePropertyList }, kids.filter { $0.type == RT.timeModifier })
        var ctnKids: [XMLNode] = []
        for (instance, name) in [(UInt16(1), "p:stCondLst"), (2, "p:endCondLst")] {
            let conds = kids.filter { $0.type == RT.timeConditionContainer && $0.instance == instance }.compactMap(condition)
            if !conds.isEmpty { ctnKids.append(.el(el(name, [], conds.map { .el($0) }))) }
        }
        let children = kids.filter { $0.type == RT.timeExtTimeNode }.compactMap { node($0, depth + 1) }
        if !children.isEmpty { ctnKids.append(.el(el("p:childTnLst", [], children.map { .el($0) }))) }
        ctn.children = ctnKids
        switch type {
        case 1:
            var seq: [(String, String)] = []
            if let s = kids.first(where: { $0.type == RT.timeSequenceData && $0.body.count >= 20 }) {
                let flags = le32(b, s.body.lowerBound + 16)
                if flags & 1 != 0 { seq.append(("concurrent", le32(b, s.body.lowerBound) == 1 ? "1" : "0")) }
                if flags & 2 != 0 { seq.append(("nextAc", le32(b, s.body.lowerBound + 4) == 1 ? "seek" : "none")) }
                if flags & 4 != 0 { seq.append(("prevAc", le32(b, s.body.lowerBound + 8) == 1 ? "skipTimed" : "none")) }
            }
            var out: [XMLNode] = [.el(ctn)]
            for (instance, name) in [(UInt16(4), "p:prevCondLst"), (3, "p:nextCondLst")] {
                let conds = kids.filter { $0.type == RT.timeConditionContainer && $0.instance == instance }.compactMap(condition)
                if !conds.isEmpty { out.append(.el(el(name, [], conds.map { .el($0) }))) }
            }
            return el("p:seq", seq, out)
        case 3:
            return behavior(kids, ctn)
        case 4:
            let target = kids.first { $0.type == RT.timeClientVisualElement }.flatMap(target)
            var media: [XMLNode] = [.el(ctn)]
            if let target { media.append(.el(target)) }
            return el("p:video", [], [.el(el("p:cMediaNode", [], media))])
        default:
            return el("p:par", [], [.el(ctn)])
        }
    }

    /// A node's `p:cTn`: its TimeNodeAtom, properties and modifiers.
    mutating func cTn(_ atom: Record, _ props: Record?, _ modifiers: [Record]) -> XMLEl {
        let p = atom.body.lowerBound
        let restart = le32(b, p + 4), fill = le32(b, p + 12), duration = i32(b, p + 24), flags = le32(b, p + 28)
        var a: [(String, String)] = [("id", String(nextId))]
        nextId += 1
        for v in props?.children(b) ?? [] where v.type == RT.timeVariant && v.body.count >= 5 && b[v.body.lowerBound] == 1 {
            let value = i32(b, v.body.lowerBound + 1)
            switch v.instance {
            case 0x09: a.append(("presetID", String(value)))
            case 0x0A: a.append(("presetSubtype", String(value)))
            case 0x0B:
                let c = ["entr", "exit", "emph", "path", "verb", "mediacall"]
                if (1 ... 6).contains(value) { a.append(("presetClass", c[Int(value) - 1])) }
            case 0x13: a.append(("grpId", String(value)))
            case 0x14:
                let n = ["clickEffect", "withEffect", "afterEffect", "mainSeq", "interactiveSeq", "clickPar", "withGroup", "afterGroup", "tmRoot"]
                if (1 ... 9).contains(value) { a.append(("nodeType", n[Int(value) - 1])) }
            default: break
            }
        }
        if flags & 0x2 != 0 { a.append(("restart", ["never", "always", "whenNotActive", "never"][Int(min(restart, 3))])) }
        if flags & 0x1 != 0 { a.append(("fill", ["freeze", "remove", "transition", "hold", "remove"][Int(min(fill, 4))])) }
        if flags & 0x10 != 0 { a.append(("dur", duration < 0 ? "indefinite" : String(duration))) }
        for m in modifiers where m.body.count >= 8 {
            let value = Double(Float(bitPattern: le32(b, m.body.lowerBound + 4)))
            guard value.isFinite else {
                if le32(b, m.body.lowerBound) == 0 { a.append(("repeatCount", "indefinite")) }
                continue
            }
            switch le32(b, m.body.lowerBound) {
            case 0: a.append(("repeatCount", String(Int((value * 1000).clamped(0, 1e9)))))
            case 1: a.append(("repeatDur", String(Int((value).clamped(0, 1e9)))))
            case 2: a.append(("spd", String(Int((value * 100_000).clamped(-1e9, 1e9)))))
            case 3: a.append(("accel", String(Int((value * 100_000).clamped(0, 100_000)))))
            case 4: a.append(("decel", String(Int((value * 100_000).clamped(0, 100_000)))))
            case 5: a.append(("autoRev", value != 0 ? "1" : "0"))
            default: break
            }
        }
        return el("p:cTn", a, [])
    }

    /// A TimeConditionContainer as `p:cond`.
    func condition(_ r: Record) -> XMLEl? {
        let kids = r.children(b)
        guard let atom = kids.first(where: { $0.type == RT.timeCondition && $0.body.count >= 16 }) else { return nil }
        let p = atom.body.lowerBound
        let object = le32(b, p), event = le32(b, p + 4), id = le32(b, p + 8), delay = i32(b, p + 12)
        var a: [(String, String)] = []
        let events: [UInt32: String] = [1: "onBegin", 3: "begin", 4: "end", 5: "onClick", 7: "onMouseOver", 9: "onNext", 10: "onPrev", 11: "onStopAudio"]
        if let e = events[event] { a.append(("evt", e)) }
        a.append(("delay", delay < 0 ? "indefinite" : String(delay)))
        var c: [XMLNode] = []
        switch object {
        case 1:
            if let t = kids.first(where: { $0.type == RT.timeClientVisualElement }).flatMap(target) { c.append(.el(t)) }
        case 2: c.append(.el(el("p:tn", [("val", String(id))], [])))
        case 3: c.append(.el(el("p:rtn", [("val", "all")], [])))
        default: break
        }
        return el("p:cond", a, c)
    }

    /// A ClientVisualElementContainer as `p:tgtEl`: the slide, a shape, a shape's background or one of its paragraphs.
    func target(_ r: Record) -> XMLEl? {
        let kids = r.children(b)
        if kids.contains(where: { $0.type == RT.visualPageAtom }) { return el("p:tgtEl", [], [.el(el("p:sldTgt", [], []))]) }
        guard let v = kids.first(where: { $0.type == RT.visualShapeAtom && $0.body.count >= 20 }) else { return nil }
        let p = v.body.lowerBound
        let type = le32(b, p), refType = le32(b, p + 4), spid = le32(b, p + 8), start = i32(b, p + 12)
        guard refType == 1 else { return nil }
        var sp: [XMLNode] = []
        switch type {
        case 2:
            if let paragraph = paragraph(spid, start) {
                sp.append(.el(el("p:txEl", [], [.el(el("p:pRg", [("st", String(paragraph)), ("end", String(paragraph))], []))])))
            }
        case 6: sp.append(.el(el("p:bg", [], [])))
        default: break
        }
        return el("p:tgtEl", [], [.el(el("p:spTgt", [("spid", String(spid))], sp))])
    }

    /// The paragraph of shape `spid` holding character `at`.
    func paragraph(_ spid: UInt32, _ at: Int32) -> Int? {
        guard let lengths = texts[spid], at >= 0 else { return nil }
        var end = 0
        for (i, n) in lengths.enumerated() {
            end += n
            if Int(at) < end { return i }
        }
        return nil
    }

    /// A behaviour node: its element (`p:animScale`, `p:animRot`…), holding `p:cBhvr` with the node's `p:cTn` and
    /// target, and the behaviour's values.
    func behavior(_ kids: [Record], _ ctn: XMLEl) -> XMLEl {
        let kinds: [UInt16: String] = [
            RT.timeAnimateBehavior: "p:anim", RT.timeColorBehavior: "p:animClr", RT.timeEffectBehavior: "p:animEffect",
            RT.timeMotionBehavior: "p:animMotion", RT.timeRotationBehavior: "p:animRot", RT.timeScaleBehavior: "p:animScale",
            RT.timeSetBehavior: "p:set", RT.timeCommandBehavior: "p:cmd",
        ]
        guard let container = kids.first(where: { kinds[$0.type] != nil }), let name = kinds[container.type] else {
            return el("p:par", [], [.el(ctn)])
        }
        let parts = container.children(b)
        let common = parts.first { $0.type == RT.timeBehaviorContainer }?.children(b) ?? []
        var bhvr: [XMLNode] = [.el(ctn)]
        if let t = common.first(where: { $0.type == RT.timeClientVisualElement }).flatMap(target) { bhvr.append(.el(t)) }
        let names = common.first { $0.type == RT.timeVariantList }?.children(b).compactMap(string) ?? []
        if !names.isEmpty {
            bhvr.append(.el(el("p:attrNameLst", [], names.map { .el(el("p:attrName", [], [.text($0)])) })))
        }
        var attrs: [(String, String)] = []
        var values: [XMLNode] = []
        let atom = parts.first { $0.type != RT.timeBehaviorContainer && !$0.isContainer && $0.type != RT.timeVariant }
        let p = atom?.body.lowerBound ?? 0, n = atom?.body.count ?? 0
        func f(_ at: Int) -> Double? {
            let v = Double(Float(bitPattern: le32(b, p + at)))
            return v.isFinite ? v : nil
        }
        func pair(_ tag: String, _ x: Double?, _ y: Double?, _ k: Double) -> XMLNode? {
            guard let x, let y else { return nil }
            return .el(el(tag, [("x", String(Int((x * k).clamped(-1e9, 1e9)))), ("y", String(Int((y * k).clamped(-1e9, 1e9))))], []))
        }
        switch container.type {
        case RT.timeScaleBehavior where n >= 28:
            let flags = le32(b, p)
            if flags & 0x1 != 0, let v = pair("p:by", f(4), f(8), 1000) { values.append(v) }
            if flags & 0x2 != 0, let v = pair("p:from", f(12), f(16), 1000) { values.append(v) }
            if flags & 0x4 != 0, let v = pair("p:to", f(20), f(24), 1000) { values.append(v) }
        case RT.timeRotationBehavior where n >= 20:
            let flags = le32(b, p)
            for (bit, at, key) in [(UInt32(1), 4, "by"), (2, 8, "from"), (4, 12, "to")] where flags & bit != 0 {
                if let v = f(at) { attrs.append((key, String(Int((v * 60000).clamped(-1e12, 1e12))))) }
            }
        case RT.timeMotionBehavior where n >= 32:
            let flags = le32(b, p)
            if flags & 0x10 != 0, let path = parts.first(where: { $0.type == RT.timeVariant && $0.instance == 1 }).flatMap(string) {
                attrs.append(("path", path))
            }
            if flags & 0x8 != 0 { attrs.append(("origin", le32(b, p + 28) == 2 ? "layout" : "parent")) }
        case RT.timeColorBehavior where n >= 52:
            if le32(b, p) & 0x4 != 0, let c = color(p + 36) { values.append(.el(el("p:to", [], [.el(c)]))) }
        default:
            break
        }
        return el(name, attrs, [.el(el("p:cBhvr", [], bhvr))] + values)
    }

    /// A TimeAnimateColor (2.8.58) at `at` as `a:srgbClr`; a scheme colour is resolved.
    func color(_ at: Int) -> XMLEl? {
        let rgba: Rgba
        switch le32(b, at) {
        case 0:
            rgba = .rgb(UInt8(clamping: le32(b, at + 4)), UInt8(clamping: le32(b, at + 8)), UInt8(clamping: le32(b, at + 12)))
        case 2:
            let i = Int(le32(b, at + 4))
            guard i < scheme.count else { return nil }
            rgba = scheme[i]
        default:
            return nil
        }
        let hex = [rgba.r, rgba.g, rgba.b].map { String($0, radix: 16, uppercase: true).leftPad(2) }.joined()
        return el("a:srgbClr", [("val", hex)], [])
    }

    /// A TimeVariantString's text.
    func string(_ r: Record) -> String? {
        guard r.type == RT.timeVariant, r.body.count >= 1, b[r.body.lowerBound] == 3 else { return nil }
        var s = Document.unicode(b, r.body.lowerBound + 1 ..< r.body.upperBound)
        while s.last == "\0" { s.removeLast() }
        return s
    }

    func el(_ name: String, _ attrs: [(String, String)], _ children: [XMLNode]) -> XMLEl {
        XMLEl(name: name, attrs: attrs.map { (key: $0.0, value: $0.1) }, children: children)
    }
}
