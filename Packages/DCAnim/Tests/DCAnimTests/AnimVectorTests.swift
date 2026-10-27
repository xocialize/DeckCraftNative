// DCAnimTests — DCAnim against deckcraft-anim, bit for bit: every line `Tools/oracle/anim-vectors` wrote to
// `DeckCraftNative-Fixtures/anim/` (easing, motion paths, transition layers and meshes, timelines, the show
// state machine, Morph frames, morphXfrm and morphCrop) is replayed here and compared. The tests skip when
// the fixtures aren't there (`Tools/oracle/anim-vectors/run.sh` writes them).
import DCCore
import DCFormat
import DCGeometry
import DCModel
import DCTestSupport
import Foundation
import Testing
@testable import DCAnim

// MARK: Shared with the Rust tool

struct FNV {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    mutating func bytes(_ b: some Sequence<UInt8>) {
        for x in b {
            h ^= UInt64(x)
            h = h &* 0x0000_0100_0000_01B3
        }
    }

    mutating func f(_ v: Double) { u(v.bitPattern) }

    mutating func u(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes($0) } }

    mutating func s(_ s: String) {
        u(UInt64(s.utf8.count))
        bytes(s.utf8)
    }

    var hex: String { hex16(h) }
}

func hex16(_ v: UInt64) -> String {
    let s = String(v, radix: 16)
    return String(repeating: "0", count: Swift.max(0, 16 - s.count)) + s
}

func fb(_ v: Double) -> String { hex16(v.bitPattern) }

/// A float from the hex of its bits.
func bits(_ s: Substring) -> Double { Double(bitPattern: UInt64(s, radix: 16) ?? 0) }

/// A string from the hex of its UTF-8 (`-` for empty).
func unhex(_ s: Substring) -> String {
    if s == "-" { return "" }
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex, let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex) {
        out.append(UInt8(s[i ..< j], radix: 16) ?? 0)
        i = j
    }
    return String(decoding: out, as: UTF8.self)
}

func hs(_ s: String) -> String { s.isEmpty ? "-" : s.utf8.map { b in (b < 16 ? "0" : "") + String(b, radix: 16) }.joined() }

func fields(_ line: Substring) -> [Substring] { line.split(separator: "\t", omittingEmptySubsequences: false) }

/// The fixtures written by anim-vectors, or nil when they aren't there.
func animFixtures() -> URL? {
    let dir = Fixtures.root.appending(path: "anim", directoryHint: .isDirectory)
    return FileManager.default.fileExists(atPath: dir.appending(path: "pin.txt").path) ? dir : nil
}

func lines(_ name: String) -> [Substring] {
    guard let dir = animFixtures(), let data = FileManager.default.contents(atPath: dir.appending(path: name).path) else { return [] }
    return String(decoding: data, as: UTF8.self).split(separator: "\n")
}

/// Mismatch notes, the first few kept.
struct Misses {
    var count = 0
    var notes: [String] = []
    var checked = 0

    mutating func check(_ ok: Bool, _ note: @autoclosure () -> String) {
        checked += 1
        if ok { return }
        count += 1
        if notes.count < 12 { notes.append(note()) }
    }

    var summary: String { "\(count) of \(checked) differ:\n" + notes.joined(separator: "\n") }
}

func sourceIndex(_ s: Source) -> UInt64 {
    switch s {
    case .old: 0
    case .new: 1
    case .black: 2
    case .white: 3
    case .oldBack: 4
    case .newBack: 5
    case .oldContent: 6
    case .newContent: 7
    }
}

func hashState(_ h: inout FNV, _ s: AnimState) {
    h.u(s.visible ? 1 : 0)
    h.f(s.opacity)
    h.f(s.offsetX)
    h.f(s.offsetY)
    h.f(s.scaleX)
    h.f(s.scaleY)
    h.f(s.rotate)
    if let c = s.clip {
        h.u(1)
        for i in 0 ..< 4 { h.f(c[i]) }
    } else {
        h.u(0)
    }
    if let c = s.tint {
        h.u(1)
        h.bytes([c.r, c.g, c.b, c.a])
    } else {
        h.u(0)
    }
}

/// The corpus decks by name, loaded with DCFormat.
let corpusDecks: [String: Presentation] = {
    guard let corpus = Fixtures.oracleCorpus else { return [:] }
    let dir = corpus.appending(path: "decks", directoryHint: .isDirectory)
    var out: [String: Presentation] = [:]
    for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".deckcraft") {
        guard let data = FileManager.default.contents(atPath: dir.appending(path: f).path), let p = try? DeckFormat.load([UInt8](data)) else {
            continue
        }
        out[String(f.dropLast(".deckcraft".count))] = p
    }
    return out
}()

/// `new_presentation(None)` as deckcraft wrote it, which generated decks are built on.
let defaultPresentation: Presentation? = {
    guard let dir = animFixtures(), let data = FileManager.default.contents(atPath: dir.appending(path: "default-presentation.json").path),
          let json = try? JSONParser.parse([UInt8](data)) else { return nil }
    return try? Presentation(fromJSON: json)
}()

/// A generated deck: the default presentation with the case's slides, show settings and custom shows.
func generatedDeck(_ line: Substring) -> Presentation? {
    guard var p = defaultPresentation, let json = try? JSONParser.parse(String(line)),
          let slides = json["slides"].flatMap({ try? [Slide](fromJSON: $0) }),
          let show = json["show"].flatMap({ try? ShowSettings(fromJSON: $0) }),
          let custom = json["customShows"].flatMap({ try? [CustomShow](fromJSON: $0) }) else { return nil }
    p.slides = slides
    p.show = show
    p.customShows = custom
    return p
}

// MARK: The tests

@Suite(.serialized) struct AnimVectorTests {
    @Test func fixturesArePresent() {
        #expect(animFixtures() != nil, "no anim vectors: run Tools/oracle/anim-vectors/run.sh")
        #expect(defaultPresentation != nil || animFixtures() == nil, "default-presentation.json doesn't decode")
    }

    @Test func easing() {
        var m = Misses()
        for line in lines("easing.txt") {
            let f = fields(line)
            guard f.count == 5 else { continue }
            let y = ease(bits(f[0]), bits(f[1]), bits(f[2]), bits(f[3]))
            m.check(y.bitPattern == bits(f[4]).bitPattern, "\(line): got \(fb(y))")
        }
        #expect(m.count == 0, "\(m.summary)")
    }

    @Test func motionPaths() {
        let grid: [Double] = [.nan, -0.5, 0.0, 0.01, 0.1, 0.25, 0.5, 0.6, 0.75, 0.9, 1.0, 1.5]
        var m = Misses()
        for line in lines("paths.txt") {
            let f = fields(line)
            if f.first == "D", f.count == 4 {
                let got = defaultPath(unhex(f[1]), unhex(f[2]))
                m.check(hs(got) == f[3], "default \(unhex(f[1])) \(unhex(f[2])): got \(got), want \(unhex(f[3]))")
            } else if f.first == "P", f.count == 6 {
                let p = MotionPath.parse(unhex(f[1]))
                var h = FNV()
                for q in p.points {
                    h.f(q.x)
                    h.f(q.y)
                }
                let at = grid.map { t in
                    let (x, y) = p.at(t)
                    return "\(fb(x)),\(fb(y))"
                }.joined(separator: ";")
                let got = "\(p.points.count)\t\(fb(p.length))\t\(h.hex)\t\(at)"
                m.check(got == f[2...].joined(separator: "\t"), "parse \(unhex(f[1]).prefix(80)): got \(got.prefix(120))")
            }
        }
        #expect(m.count == 0, "\(m.summary)")
    }

    @Test func transitionLayersAndMeshes() {
        var m = Misses()
        for line in lines("transitions.txt") {
            let f = fields(line)
            if f.first == "F", f.count == 8 {
                let (kind, o, t, a) = (unhex(f[1]), unhex(f[2]), bits(f[3]), bits(f[4]))
                let ls = transitionFrame(kind, o, t, a)
                var h1 = FNV(), h2 = FNV()
                for l in ls {
                    h1.u(sourceIndex(l.source))
                    for i in 0 ..< 4 { h1.f(l.src[i]) }
                    for q in l.quad.corners + l.uv.corners {
                        h1.f(q[0])
                        h1.f(q[1])
                    }
                    h1.f(l.alpha)
                    for i in 0 ..< 4 { h1.f(l.fade[i]) }
                    let (v, tris) = layerMesh(l)
                    h2.u(UInt64(v.count))
                    for x in v {
                        h2.f(x.pos[0])
                        h2.f(x.pos[1])
                        h2.f(x.uv[0])
                        h2.f(x.uv[1])
                        h2.f(x.a)
                    }
                    h2.u(UInt64(tris.count))
                    for tr in tris {
                        h2.u(UInt64(tr[0]))
                        h2.u(UInt64(tr[1]))
                        h2.u(UInt64(tr[2]))
                    }
                }
                let got = "\(ls.count)\t\(h1.hex)\t\(h2.hex)"
                m.check(got == f[5...].joined(separator: "\t"), "\(kind)/\(o) t=\(t) a=\(a): got \(got), want \(f[5...].joined(separator: " "))")
            } else if f.first == "U", f.count == 4 {
                let got = usesSlideParts(unhex(f[1]), unhex(f[2]))
                m.check((got ? "1" : "0") == f[3], "usesSlideParts \(unhex(f[1])) \(unhex(f[2]))")
            }
        }
        #expect(m.count == 0, "\(m.summary)")
    }

    @Test func timelines() {
        let cases = lines("timelines-cases.jsonl")
        var m = Misses()
        for line in lines("timelines.txt") {
            let f = fields(line)
            guard f.count == 12 else { continue }
            let id = f[0].split(separator: ":")
            let slide: Slide?
            if id.first == "corpus", id.count == 3, let p = corpusDecks[String(id[1])], let i = Int(id[2]) {
                slide = p.slides.at(i)
            } else if id.first == "gen", id.count == 2, let k = Int(id[1]), let c = cases.at(k), let json = try? JSONParser.parse(String(c)) {
                slide = try? Slide(fromJSON: json)
            } else {
                slide = nil
            }
            guard let slide else {
                m.check(false, "\(f[0]): no slide")
                continue
            }
            let got = timelineLine(slide, bits(f[1]), bits(f[2]))
            m.check(got == f[3...].joined(separator: "\t"), "\(f[0]): got \(got)\n  want \(f[3...].joined(separator: " "))")
        }
        #expect(m.count == 0, "\(m.summary)")
    }

    @Test func showStateMachine() {
        let cases = lines("show-cases.jsonl")
        var m = Misses()
        var pres: Presentation?
        var show = ShowState()
        var caseId = ""
        var now = 0.0
        for line in lines("show.txt") {
            let f = fields(line)
            if f.first == "C", f.count == 4 {
                caseId = String(f[1])
                let id = f[1].split(separator: ":")
                if id.first == "corpus", id.count == 3 {
                    pres = corpusDecks[String(id[1])]
                } else if id.first == "gen", id.count == 2, let k = Int(id[1]), let c = cases.at(k) {
                    pres = generatedDeck(c)
                } else {
                    pres = nil
                }
                guard let p = pres else {
                    m.check(false, "\(caseId): no deck")
                    continue
                }
                let start = f[2]
                if start.hasPrefix("at:"), let i = Int(start.dropFirst(3)) {
                    show = ShowState.startAt(p, i)
                } else if start.hasPrefix("custom:"), let s = ShowState.playCustom(p, unhex(start.dropFirst(7))) {
                    show = s
                } else {
                    show = ShowState(p)
                }
                now = 0
                m.check(showSummary(show, p) == f[3], "\(caseId) start: got \(showSummary(show, p)), want \(f[3])")
                continue
            }
            guard f.first == "O", f.count == 6, let p = pres else { continue }
            let tl = ShowState.timeline(p, show.slide)
            let op = f[2].split(separator: ":", omittingEmptySubsequences: false)
            let result: String
            switch op.first {
            case "next": result = fmtAction(show.next(p))
            case "prev": result = fmtAction(show.prev(p))
            case "done": result = fmtAction(show.stepDone(p))
            case "goto": result = fmtAction(show.goto(p, Int(op[1]) ?? 0))
            case "follow":
                let a = (try? JSONParser.parse(unhex(op[1]))).flatMap { try? Action(fromJSON: $0) } ?? .playMedia
                result = fmtJump(show.follow(p, a, op[2] == "-" ? nil : Int(op[2])))
            case "link":
                guard let json = try? JSONParser.parse(unhex(op[1])), let link = try? Hyperlink(fromJSON: json) else {
                    m.check(false, "\(caseId) op \(f[1]): bad link")
                    continue
                }
                result = fmtJump(show.followLink(p, link, op[2] == "-" ? nil : Int(op[2])))
            case "tick":
                now = bits(op[1])
                result = fmtClick(show.tick(tl, now))
            case "click":
                now = bits(op[1])
                let hits = parseHits(op[3])
                let st = show
                let vis = hits.map { h in
                    let s = st.animState(tl, h.id, 0.0)
                    return (h.id, s.visible && s.opacity > 0.0)
                }
                result = fmtClick(show.click(p, tl, hits, { id in vis.first { $0.0 == id }.map(\.1) ?? true }, now, op[2] == "-" ? nil : Int(op[2])))
            case "target":
                let hits = parseHits(op[1])
                let t = show.target(p, tl, hits) { _ in true }
                let top = show.top(p, tl, hits) { _ in true }
                let ts = t.map { "\($0.shape.rawValue):\($0.link.map { hs(JSONWriter().string($0.toJSON())) } ?? "-")" } ?? "-"
                result = "\(ts)|\(top.map(String.init) ?? "-")"
            case "due":
                result = show.autoAdvanceDue(p, bits(op[1])) ? "1" : "0"
            default:
                result = "?"
            }
            let tl2 = ShowState.timeline(p, show.slide)
            var h = FNV()
            for sh in p.slides.at(show.slide)?.shapes ?? [] {
                for t in [0.0, 0.3, 1.2] { hashState(&h, show.animState(tl2, sh.id, t)) }
            }
            let got = "\(result)\t\(showSummary(show, p))\t\(h.hex)"
            m.check(got == f[3...].joined(separator: "\t"), "\(caseId) op \(f[1]) \(f[2].prefix(60)): got \(got)\n  want \(f[3...].joined(separator: " "))")
        }
        #expect(m.count == 0, "\(m.summary)")
    }

    @Test func morphFrames() {
        let cases = lines("morph-cases.jsonl")
        var generated: [Int: Presentation] = [:]
        var m = Misses()
        for line in lines("morph.txt") {
            let f = fields(line)
            guard f.count == 13 else { continue }
            let id = f[0].split(separator: ":")
            var p: Presentation?
            if id.first == "corpus", id.count == 2 {
                p = corpusDecks[String(id[1])]
            } else if id.first == "gen", id.count == 2, let k = Int(id[1]) {
                if generated[k] == nil, let c = cases.at(k) { generated[k] = generatedDeck(c) }
                p = generated[k]
            }
            guard let p, let ia = Int(f[1]), let ib = Int(f[2]), let a = p.slides.at(ia), let b = p.slides.at(ib) else {
                m.check(false, "\(f[0]): no slides")
                continue
            }
            let got = morphLine(p, a, b, bits(f[3]), f[4] == "1")
            m.check(got == f[5...].joined(separator: "\t"), "\(f[0]) \(ia)→\(ib) t=\(bits(f[3])) hidden=\(f[4]): got \(got)\n  want \(f[5...].joined(separator: " "))")
        }
        #expect(m.count == 0, "\(m.summary)")
    }

    @Test func morphXfrmAndCrop() {
        func xf(_ s: Substring) -> Xfrm {
            let v = s.split(separator: ",")
            guard v.count == 7 else { return Xfrm() }
            return Xfrm(x: bits(v[0]), y: bits(v[1]), w: bits(v[2]), h: bits(v[3]), rot: bits(v[4]), flipH: v[5] == "1", flipV: v[6] == "1")
        }
        func fx(_ x: Xfrm) -> String { "\(fb(x.x)),\(fb(x.y)),\(fb(x.w)),\(fb(x.h)),\(fb(x.rot)),\(x.flipH ? 1 : 0),\(x.flipV ? 1 : 0)" }
        func four(_ s: Substring) -> [Double] { s.split(separator: ",").map(bits) }
        var m = Misses()
        for line in lines("xfrm.txt") {
            let f = fields(line)
            if f.first == "X", f.count == 5 {
                let got = fx(morphXfrm(xf(f[1]), xf(f[2]), bits(f[3])))
                m.check(got == f[4], "\(line): got \(got)")
            } else if f.first == "K", f.count == 8 {
                let c = morphCrop(four(f[1]), xf(f[2]), four(f[3]), xf(f[4]), xf(f[5]), bits(f[6]))
                let got = c.map(fb).joined(separator: ",")
                m.check(got == f[7], "\(line): got \(got)")
            }
        }
        #expect(m.count == 0, "\(m.summary)")
    }
}

// MARK: Replays

private func timelineLine(_ slide: Slide, _ w: Double, _ hgt: Double) -> String {
    let tl = Timeline(slide, w, hgt)
    let n = tl.steps
    var hSteps = FNV()
    hSteps.u(UInt64(n))
    for i in 0 ... n + 1 {
        hSteps.u(tl.stepIsAuto(i) ? 1 : 0)
        hSteps.f(tl.stepDuration(i))
    }
    hSteps.f(tl.totalDuration)
    hSteps.u(tl.isEmpty ? 1 : 0)
    for tr in tl.triggerShapes {
        hSteps.u(UInt64(tr.rawValue))
        let k = tl.triggerSteps(tr)
        hSteps.u(UInt64(k))
        for i in 0 ... k { hSteps.f(tl.triggerStepDuration(tr, i)) }
    }
    var hEff = FNV()
    for e in tl.effects {
        hEff.u(UInt64(e.anim))
        hEff.u(UInt64(e.shape.rawValue))
        hEff.u(e.paragraph.map { UInt64($0) } ?? UInt64.max)
        switch e.sequence {
        case .main: hEff.u(UInt64.max)
        case .trigger(let s): hEff.u(UInt64(s.rawValue))
        }
        hEff.u(UInt64(e.step))
        hEff.f(e.start)
        hEff.f(e.duration)
        hEff.f(e.iterations)
        hEff.u(e.untilNextClick ? 1 : 0)
        hEff.u(e.autoReverse ? 1 : 0)
        hEff.u(e.rewind ? 1 : 0)
        hEff.f(e.span)
        hEff.u(classIndex(e.animClass))
    }
    let animated = tl.animatedShapes
    var hParas = FNV()
    for s in animated {
        hParas.u(UInt64(s.rawValue))
        for p in tl.paragraphTargets(s) { hParas.u(UInt64(p)) }
        hParas.u(UInt64.max)
    }
    var hStart = FNV()
    for a in 0 ... slide.animations.count {
        if let v = tl.startOf(a) { hStart.f(v) } else { hStart.u(UInt64.max) }
    }
    var hLocate = FNV()
    for time in [Double.nan, -.infinity, -1.0, 0.0, 0.25, 0.5, 1.0, 1.5, 2.0, 2.75, 3.0, 4.5, 10.0, 1e12] {
        let (s, t) = tl.locate(time)
        hLocate.u(UInt64(s))
        hLocate.f(t)
    }
    var hCues = FNV()
    for step in 0 ... n {
        for (from, to) in [(-Double.infinity, 0.0), (0.0, 1.0), (-1.0, Double.infinity), (0.5, 2.0)] {
            for c in tl.mediaCues(step, from, to) {
                hCues.u(UInt64(c.anim))
                hCues.u(UInt64(c.shape.rawValue))
                hCues.f(c.start)
            }
            hCues.u(UInt64.max)
        }
    }
    var grid: [(Int, Double)] = []
    for step in [0, 1, 2, 3, 5, Int.max] {
        for t in [Double.nan, -1.0, 0.0, 0.001, 0.1, 0.25, 0.5, 0.75, 0.999, 1.0, 1.25, 1.5, 2.0, 3.5, 7.0, 1e9] { grid.append((step, t)) }
    }
    var targets: [(ShapeId, Int?)] = []
    for s in animated + [ShapeId(424_242)] {
        targets.append((s, nil))
        for p in tl.paragraphTargets(s) { targets.append((s, p)) }
        targets.append((s, 97))
    }
    var hStates = FNV()
    for (s, p) in targets {
        for (step, t) in grid { hashState(&hStates, tl.state(s, p, step, t)) }
        for time in [Double.nan, -1.0, 0.0, 0.3, 0.9, 1.7, 2.5, 4.0, 1e9] { hashState(&hStates, tl.stateAt(s, p, time)) }
    }
    let trig = tl.triggerShapes
    var hWith = FNV(), hOrd = FNV()
    if !trig.isEmpty {
        for (s, p) in targets {
            for (step, t) in [(0, 0.0), (0, 0.5), (1, 0.0), (1, 0.4), (2, 1.0), (9, 0.0)] {
                let plays = trig.map { TriggerPlay(trigger: $0, step: step, t: t) }
                hashState(&hWith, tl.stateWith(s, p, 1, 0.3, plays))
                hashState(&hWith, tl.stateWith(s, p, Int.max, 0.0, plays))
                let fwd = trig.enumerated().flatMap { i, tr in (0 ..< 3).map { k in StepStamp(trigger: tr, step: k, at: UInt64(i * 3 + k)) } }
                let rev = fwd.map { StepStamp(trigger: $0.trigger, step: $0.step, at: 1000 - $0.at) }
                let max = fwd.map { StepStamp(trigger: $0.trigger, step: $0.step, at: UInt64.max) }
                for stamps in [fwd, rev, max] { hashState(&hOrd, tl.stateOrdered(s, p, 1, 0.3, plays, stamps)) }
            }
        }
    }
    return [hSteps, hEff, hParas, hStart, hLocate, hCues, hStates, hWith, hOrd].map(\.hex).joined(separator: "\t")
}

/// `AnimClass as u64` (declaration order).
private func classIndex(_ c: AnimClass) -> UInt64 {
    switch c {
    case .entrance: 0
    case .emphasis: 1
    case .exit: 2
    case .path: 3
    case .media: 4
    }
}

private func fmtAction(_ a: ShowAction) -> String {
    switch a {
    case .none_: "None"
    case .playStep(let n): "PlayStep(\(n))"
    case .finishStep(let n): "FinishStep(\(n))"
    case .stepBack(let n): "StepBack(\(n))"
    case .slide(let n): "Slide(\(n))"
    case .end: "End"
    case .exit: "Exit"
    }
}

private func fmtJump(_ j: LinkJump) -> String {
    switch j {
    case .show(let a): "Show(\(fmtAction(a)))"
    case .open(let u): "Open(\(hs(u)))"
    case .exit: "Exit"
    case .none_: "None"
    }
}

private func fmtClick(_ c: Click) -> String {
    switch c {
    case .none_: "None"
    case .animated: "Animated"
    case .show(let a): "Show(\(fmtAction(a)))"
    case .open(let u): "Open(\(hs(u)))"
    case .exit: "Exit"
    }
}

private func showSummary(_ s: ShowState, _ p: Presentation) -> String {
    func opt(_ v: Int?) -> String { v.map(String.init) ?? "-" }
    let plays = s.triggerPlays.map { "\($0.trigger.rawValue):\($0.step):\(fb($0.t))" }.joined(separator: " ")
    let stamps = s.triggerStamps.map { "\($0.trigger.rawValue):\($0.step):\($0.at)" }.joined(separator: " ")
    let zoom = s.zoom.map { "\($0.back)/\($0.until)" } ?? "-"
    let head = [
        String(s.slide), String(s.step), s.playing ? "1" : "0", s.ended ? "1" : "0", zoom, opt(s.peekNext(p)), opt(s.firstIndex(p)),
        opt(s.lastIndex(p)), s.customName.map(hs) ?? "-", s.triggerPlaying ? "1" : "0", s.advanceAfter(p).map(fb) ?? "-",
    ].joined(separator: ",")
    return "\(head)|\(plays)|\(stamps)"
}

private func parseHits(_ s: Substring) -> [HitShape] {
    if s == "-" { return [] }
    return s.split(separator: ";").map { h in
        let v = h.split(separator: ",", omittingEmptySubsequences: false)
        guard v.count == 5 else { return HitShape(id: ShapeId(0)) }
        let link = v[3] == "-" ? nil : (try? JSONParser.parse(unhex(v[3]))).flatMap { try? Action(fromJSON: $0) }
        return HitShape(id: ShapeId(UInt32(v[0]) ?? 0), parent: v[1] == "-" ? nil : Int(v[1]), isGroup: v[2] == "1", link: link, underPointer: v[4] == "1")
    }
}

private func morphLine(_ p: Presentation, _ a: Slide, _ b: Slide, _ t: Double, _ hidden: Bool) -> String {
    let pairs = morphPairs(a, b).map { "\($0.0.rawValue):\($0.1.rawValue)" }
    let f = morphFrame(p, a, b, t) { hidden && $0.rawValue % 3 == 0 }
    var h = FNV()
    for (s, _) in f.shapes { h.s(JSONWriter().string(s.toJSON())) }
    let old = f.shapes.map { $0.1 ? "1" : "0" }.joined()
    let ids = f.shapes.map { String($0.0.id.rawValue) }
    let op = f.opacity.map { "\($0.0.rawValue):\(fb($0.1))" }
    func xf(_ x: Xfrm) -> String { "\(fb(x.x)),\(fb(x.y)),\(fb(x.w)),\(fb(x.h)),\(fb(x.rot)),\(x.flipH ? 1 : 0),\(x.flipV ? 1 : 0)" }
    let text = f.text.map { "\($0.old.rawValue):\($0.new.rawValue):\(xf($0.from)):\(xf($0.to)):\($0.chars ? 1 : 0)" }
    let paths = f.paths.map { "\($0.id.rawValue):\(hs(JSONWriter().string($0.from.toJSON()))):\(xf($0.fromBox)):\(xf($0.toBox))" }
    func d(_ v: [String]) -> String { v.isEmpty ? "-" : v.joined(separator: ";") }
    return [d(pairs), fb(f.mix), h.hex, d(ids), old.isEmpty ? "-" : old, d(op), d(text), d(paths)].joined(separator: "\t")
}
