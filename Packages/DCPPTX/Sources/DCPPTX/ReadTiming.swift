// DCPPTX — slide transitions (`p:transition`) and animations (`p:timing`). Port of deckcraft
// crates/pptx/src/read/timing.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import CNCore
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

    /// Does every behaviour time node (`p:cBhvr/p:cTn`) under the effect node `c` carry `autoRev`?
    static func behaviourAutoReverses(_ c: XMLEl) -> Bool {
        let behaviours = c.findAll("cBhvr")
        return !behaviours.isEmpty && behaviours.allSatisfy { $0.child("cTn")?.bool("autoRev") ?? false }
    }

    /// Volume, mute, Loop until Stopped, Hide While Not Playing and Play Full Screen live in the timing tree
    /// (`p:video`/`p:audio` > `p:cMediaNode`), not on the picture: copy them onto the target's `MediaClip`.
    static func mediaSettings(_ timing: XMLEl, _ ctx: IdCtx, _ shapes: inout [Shape]) {
        var nodes: [XMLEl] = []
        for tag in ["video", "audio"] {
            timing.findAll(tag, into: &nodes)
        }
        for node in nodes.prefix(10_000) {
            guard let cm = node.child("cMediaNode"),
                  let id = cm.path(["tgtEl", "spTgt"])?.u32("spid").flatMap({ ctx.lookup($0) }) else { continue }
            mutateShape(&shapes, id) { s in
                guard case .media(var clip) = s.kind else { return }
                if let v = cm.attr("vol").flatMap({ rustParseF64(rustTrim($0)) }), v.isFinite {
                    clip.volume = (v / 100_000.0).clamped(0.0, 1.0)
                }
                if cm.bool("mute") == true {
                    clip.volume = 0.0
                }
                if cm.bool("showWhenStopped") == false {
                    clip.hideWhileNotPlaying = true
                }
                if attrIs(cm.child("cTn")?.attr("repeatCount"), "indefinite") {
                    clip.loopPlay = true
                }
                if node.bool("fullScrn") == true {
                    clip.fullScreen = true
                }
                s.kind = .media(clip)
            }
        }
    }

    /// One effect read from the file: the animation, its file shape id, its group id, whether it is part
    /// of a paragraph build, and the chart build (`bldGraphic`) its chart part belongs to.
    private typealias Effect = (anim: Animation, fileId: UInt32, grp: String, build: Bool, chart: (ChartBuild, Bool)?)

    /// Flatten the timing tree into the Animation Pane list.
    static func animations(_ ctx: IdCtx, _ timing: XMLEl, _ shapes: [Shape]) -> [Animation] {
        guard let tn = timing.child("tnLst") else { return [] }
        var found: [Found] = []
        collect(tn, nil, &found, 0)
        // Paragraph builds (`bldP build="p"`) by (spid, grpId).
        let byPara: [(UInt32, String)] = timing.child("bldLst").map { b in
            b.childrenNamed("bldP").filter { attrIs($0.attr("build"), "p") }.compactMap { p in
                p.u32("spid").map { ($0, p.attr("grpId") ?? "0") }
            }
        } ?? []
        // Chart builds (`bldGraphic` with `a:bldChart`) by (spid, grpId): the build and whether it has a
        // background step (`animBg`, on unless "0" or "false").
        let byChart: [(UInt32, String, ChartBuild, Bool)] = timing.child("bldLst").map { b in
            b.childrenNamed("bldGraphic").compactMap { g in
                guard let spid = g.u32("spid"), let bc = g.path(["bldSub", "bldChart"]),
                      let build = ChartBuild.fromFile(bc.attr("bld")) else { return nil }
                return (spid, g.attr("grpId") ?? "0", build, bc.bool("animBg") ?? true)
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
            let chartEl = tgt.path(["graphicEl", "chart"]).flatMap { e in
                ChartElement.fromFile(step: e.attr("bldStep"), series: e.i64("seriesIdx"), category: e.i64("categoryIdx"))
            }
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
            a.chartElement = paragraph == nil ? chartEl : nil
            a.trigger = f.trigger.flatMap { ctx.lookup($0) }
            a.presetId = preset
            a.presetSubtype = sub
            // PowerPoint's "Auto-reverse" is `autoRev` on the behaviour nodes (`p:cBhvr/p:cTn`); Color Pulse
            // always writes it there and plays back and forth on its own, so it isn't read as the option.
            a.autoReverse = (c.bool("autoRev") ?? false) || (!bytesEqual(effect, "colorPulse") && behaviourAutoReverses(c))
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
            let chart = a.chartElement == nil ? nil : byChart.first { $0.0 == fileId && bytesEqual($0.1, grp) }.map { ($0.2, $0.3) }
            out.append((a, fileId, grp, build, chart))
        }
        // A paragraph build's effects, one per paragraph, become one by-paragraph animation only when
        // the timeline plays that back exactly: PowerPoint lets each paragraph keep its own start and
        // effect, and other shapes' effects can sit between them (#844).
        func sameBuild(_ x: Effect, _ y: Effect) -> Bool {
            (x.build && y.build || x.chart != nil && y.chart != nil) && x.fileId == y.fileId && bytesEqual(x.grp, y.grp)
                && x.anim.trigger == y.anim.trigger
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
            } else if let first = effects.first, let (cb, bg) = run.first?.chart, case .chart(let ch)? = findShape(shapes, first.shape)?.kind,
                      playsAsChartBuild(effects, ch, cb, bg) {
                // A chart build's steps, one effect per series, category or point, become one animation the
                // same way (AB-T-0443).
                var a = first
                a.chartBuild = cb
                a.chartNoBackground = !bg
                a.chartElement = nil
                anims.append(a)
            } else {
                anims.append(contentsOf: effects)
            }
            i = j
        }
        return anims
    }

    /// Are `effects` (chart part effects of one shape, in file order) what `build` of the first one plays: one
    /// effect per step of `chartBuildSteps`, in order, later steps on click (after previous when the build
    /// doesn't start on click), all with the same settings?
    static func playsAsChartBuild(_ effects: [Animation], _ chart: Chart, _ build: ChartBuild, _ background: Bool) -> Bool {
        let steps = chartBuildSteps(chart, build, background: background)
        guard let first = effects.first, !steps.isEmpty, steps.count == effects.count else { return false }
        func settings(_ a: Animation) -> Animation {
            var a = a
            a.start = .onClick
            a.chartElement = nil
            return a
        }
        let base = settings(first)
        let later: AnimStart = first.start == .onClick ? .onClick : .afterPrevious
        for (k, (a, step)) in zip(effects, steps).enumerated() {
            if a.chartElement != step || (k > 0 && a.start != later) || settings(a) != base { return false }
        }
        return true
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
