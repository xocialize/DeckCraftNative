// DCPPTX — slide transitions (`p:transition`) and animations (`p:timing`). Port of deckcraft
// crates/pptx/src/read/timing.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCCore
import DCModel

extension PPTXRead {
    static func msAttr(_ e: XMLEl, _ name: String) -> UInt32? {
        guard let raw = e.attr(name) else { return nil }
        let v = rustTrim(raw)
        if bytesEqual(v, "indefinite") { return nil }
        guard let f = rustParseF64(v), f.isFinite else { return nil }
        return UInt32(rustCast: f.clamped(0.0, 86_400_000.0))
    }

    static func transition(_ imp: Imp, _ part: Part, _ t: XMLEl) -> Transition? {
        let effect = t.elements.first { !bytesEqual($0.local, "sndAc") && !bytesEqual($0.local, "extLst") }
        var tr = Transition.default
        tr.advanceOnClick = t.bool("advClick") ?? true
        tr.advanceAfterMs = msAttr(t, "advTm")
        if let (k, o) = effect.flatMap(Maps.transitionFromXML) {
            tr.kind = k
            tr.option = o
        } else if let e = effect {
            tr.kind = String(e.local)
            tr.raw = part.keep(t)
        } else {
            tr.kind = "none"
        }
        let defaultDur = transitions.first { bytesEqual($0.id, tr.kind) }?.defaultDurationMs ?? 1000
        // `spd` defaults to "fast" in the schema; PowerPoint omits both attributes for 0.5 s.
        tr.durationMs = msAttr(t, "dur") ?? {
            switch t.attr("spd") {
            case "med"?: 750
            case "slow"?: Swift.max(defaultDur, 1000)
            default: 500
            }
        }()
        if let snd = t.path(["sndAc", "stSnd", "snd"]) {
            tr.sound = mediaRef(imp, part, snd)
            tr.soundLoop = t.path(["sndAc", "stSnd"])?.attr("loop").map { bytesEqual($0, "1") || bytesEqual($0, "true") } ?? false
        }
        tr.stopSound = t.path(["sndAc", "endSnd"]) != nil
        if bytesEqual(tr.kind, "none") && tr.advanceOnClick && tr.advanceAfterMs == nil && tr.sound == nil && !tr.stopSound {
            return nil
        }
        return tr
    }

    struct Found {
        var ctn: XMLEl
        var trigger: UInt32?
    }

    static func collect(_ e: XMLEl, _ trigger: UInt32?, _ out: inout [Found], _ depth: Int) {
        if depth > 64 || out.count > 10_000 { return }
        for c in e.elements {
            if c.is("cTn") && c.hasAttr("presetClass") {
                out.append(Found(ctn: c, trigger: trigger))
                continue
            }
            var trig = trigger
            if c.is("seq"), let ctn = c.child("cTn"), attrIs(ctn.attr("nodeType"), "interactiveSeq") {
                trig = ctn.path(["stCondLst", "cond", "tgtEl", "spTgt"])?.u32("spid")
            }
            collect(c, trig, &out, depth + 1)
        }
    }

    static func maxDur(_ e: XMLEl, _ depth: Int) -> UInt32? {
        if depth > 64 { return nil }
        var best: UInt32?
        for c in e.elements {
            if c.is("cTn"), let d = msAttr(c, "dur"), d > 1 {
                best = best.map { Swift.max($0, d) } ?? d
            }
            if let d = maxDur(c, depth + 1) {
                best = best.map { Swift.max($0, d) } ?? d
            }
        }
        return best
    }

    /// One effect read from the file: the animation, its file shape id, its group id, and whether it
    /// is part of a paragraph build.
    private typealias Effect = (anim: Animation, fileId: UInt32, grp: String, build: Bool)

    /// Flatten the timing tree into the Animation Pane list.
    static func animations(_ imp: Imp, _ part: Part, _ ctx: IdCtx, _ timing: XMLEl, _ shapes: [Shape]) -> [Animation] {
        guard let tn = timing.child("tnLst") else { return [] }
        var found: [Found] = []
        collect(tn, nil, &found, 0)
        // Paragraph builds (`bldP build="p"`) by (spid, grpId).
        let byPara: [(UInt32, String)] = timing.child("bldLst").map { b in
            b.childrenNamed("bldP").filter { attrIs($0.attr("build"), "p") }.compactMap { p in
                p.u32("spid").map { ($0, p.attr("grpId") ?? "0") }
            }
        } ?? []
        var out: [Effect] = []
        for f in found {
            let c = f.ctn
            let cls = AnimClass.fromXML(c.attr("presetClass") ?? "entr")
            let preset = c.u32("presetID") ?? 0
            let sub = c.u32("presetSubtype") ?? 0
            guard let tgt = c.find("spTgt"), let fileId = tgt.u32("spid"), let shape = ctx.lookup(fileId) else { continue }
            let paragraph = tgt.path(["txEl", "pRg"])?.u32("st")
            let base = Maps.effectForPreset(cls, preset) ?? Maps.fallbackEffect(cls)
            // PowerPoint writes Float Down as its own preset (47), not as Float with a direction.
            let effect: String, option: String
            switch (cls, preset) {
            case (.entrance, 47): (effect, option) = ("float", "d")
            case (.exit, 47): (effect, option) = ("floatOut", "d")
            default: (effect, option) = (base, Maps.optionFromSubtype(base, sub))
            }
            let start: AnimStart
            switch c.attr("nodeType") {
            case "clickEffect"?: start = .onClick
            case "afterEffect"?: start = .afterPrevious
            default: start = .withPrevious
            }
            var a = Animation.default
            a.shape = shape
            a.class = cls
            a.effect = effect
            a.option = option
            a.start = start
            a.durationMs = maxDur(c, 0) ?? 0
            a.delayMs = c.path(["stCondLst", "cond"]).flatMap { msAttr($0, "delay") } ?? 0
            a.paragraph = paragraph
            a.trigger = f.trigger.flatMap { ctx.lookup($0) }
            a.presetId = preset
            a.presetSubtype = sub
            a.autoReverse = c.bool("autoRev") ?? false
            // PowerPoint's "Rewind when done playing" is `fill="remove"` on the effect node.
            a.rewind = attrIs(c.attr("fill"), "remove")
            a.smoothStart = c.f64("accel").map { $0 / 100_000.0 } ?? 0.0
            a.smoothEnd = c.f64("decel").map { $0 / 100_000.0 } ?? 0.0
            a.bounceEnd = c.f64("bounceEnd").map { ($0 / 100_000.0).clamped(0.0, 1.0) } ?? 0.0
            switch c.attr("repeatCount") {
            case "indefinite"?:
                a.repeat = .max
            case let v?:
                a.repeat = rustParseF64(v).flatMap { $0.isFinite ? $0 : nil }
                    .map { UInt32(rustCast: ($0 / 1000.0).rounded().clamped(1.0, 10_000.0)) } ?? 1
            case nil:
                a.repeat = 1
            }
            if let m = c.find("animMotion") {
                a.path = m.attr("path")
            }
            if let r = c.find("animRot") {
                a.amount = r.f64("by").map { $0 / 60_000.0 }
                if a.effect == "spin" && (a.amount.map { $0 < 0.0 } ?? false) {
                    a.option = "counterClockwise"
                }
            } else if let s = c.find("animScale")?.child("by") {
                a.amount = s.f64("x").map { $0 / 100_000.0 }
            }
            if let clr = c.find("animClr")?.child("to") {
                a.color = color(clr)
            }
            let grp = c.attr("grpId") ?? "0"
            let build = paragraph != nil && byPara.contains { $0.0 == fileId && bytesEqual($0.1, grp) }
            out.append((a, fileId, grp, build))
        }
        // A paragraph build's effects, one per paragraph, become one by-paragraph animation only when
        // the timeline plays that back exactly: PowerPoint lets each paragraph keep its own start and
        // effect, and other shapes' effects can sit between them (#844).
        func sameBuild(_ x: Effect, _ y: Effect) -> Bool {
            x.build && y.build && x.fileId == y.fileId && bytesEqual(x.grp, y.grp) && x.anim.trigger == y.anim.trigger
        }
        var anims: [Animation] = []
        anims.reserveCapacity(out.count)
        var i = 0
        while i < out.count {
            // `chunk_by`: a run of consecutive effects each `sameBuild` as the one before.
            var j = i + 1
            while j < out.count && sameBuild(out[j - 1], out[j]) { j += 1 }
            let run = out[i ..< j]
            let effects = run.map(\.anim)
            let build = run.first?.build ?? false
            if let first = effects.first, let text = findShape(shapes, first.shape)?.text, build, playsAsBuild(effects, text) {
                var a = first
                a.textBuild = .byParagraph
                a.paragraph = nil
                anims.append(a)
            } else {
                anims.append(contentsOf: effects)
            }
            i = j
        }
        return anims
    }

    /// Are `effects` (paragraph effects of one shape, in file order) what a by-paragraph build of the
    /// first one plays: one effect per paragraph the build animates, in paragraph order, later top
    /// paragraphs on click (after previous when the build doesn't start on click), deeper ones with
    /// their parent, all with the same settings?
    static func playsAsBuild(_ effects: [Animation], _ text: TextBody) -> Bool {
        let roles = paragraphBuildRoles(text)
        let expected = roles.enumerated().filter { i, r in
            switch r {
            case .top: true
            case .member: text.paragraphs.at(i).map(buildFilled) ?? false
            case .unowned: false
            }
        }
        guard let first = effects.first else { return false }
        func settings(_ a: Animation) -> Animation {
            var a = a
            a.start = .onClick
            a.paragraph = nil
            return a
        }
        let base = settings(first)
        var matched = 0
        for (k, (i, role)) in expected.enumerated() {
            guard let a = effects.at(k) else { return false }
            let startOK: Bool
            switch role {
            case .top where k == 0: startOK = true
            case .top where first.start == .onClick: startOK = a.start == .onClick
            case .top: startOK = a.start == .afterPrevious
            default: startOK = a.start == .withPrevious
            }
            if a.paragraph != UInt32(exactly: i) || !startOK || settings(a) != base { return false }
            matched = k + 1
        }
        return matched == effects.count
    }
}
