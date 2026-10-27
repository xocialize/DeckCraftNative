// DCPPTX — transitions and the animation timing tree. Port of deckcraft crates/pptx/src/write/timing.rs
// (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors).
import DCColor
import DCCore
import DCModel

extension PPTXWrite {
    /// The `write::timing` module.
    enum Timing {
        static func transition(_ w: inout W, _ x: Exp, _ o: Out, _ t: Transition) {
            let advClick: String? = !t.advanceOnClick ? "0" : nil
            let advTm = t.advanceAfterMs.map { Swift.min($0, 86_400_000) }
            let spd = switch t.durationMs {
            case 0 ... 600: "fast"
            case 601 ... 900: "med"
            default: "slow"
            }
            var sound: (String, String)?
            if let m = t.sound, let r = x.mediaRel(o, m, "audio") {
                sound = (r, x.p.media(m)?.name ?? "")
            }
            func snd(_ w: inout W) {
                if let (r, name) = sound {
                    w.open0("p:sndAc")
                    w.open("p:stSnd", A.new().t("loop", t.soundLoop))
                    let name = name.isEmpty ? "sound.wav" : name
                    w.empty("p:snd", A.new().a("r:embed", r).a("name", name))
                    w.close("p:stSnd")
                    w.close("p:sndAc")
                } else if t.stopSound {
                    w.open0("p:sndAc")
                    w.empty0("p:endSnd")
                    w.close("p:sndAc")
                }
            }
            var effect = W.frag()
            let found: String? = bytesEqual(t.kind, "none") ? "p" : Maps.transitionToXML(&effect, t.kind, t.option)
            // Unknown kind: write the kept element if there is one, else a fade.
            let ns = found ?? unknownTransition(&effect, t.raw)
            let isNone = bytesEqual(t.kind, "none")
            let dur = Swift.min(t.durationMs, 60_000)
            w.open("mc:AlternateContent", A.new().a("xmlns:mc", OPC.nsMC))
            var ch = A.new().a("xmlns:p14", OPC.nsP14)
            let req: String
            switch ns {
            case "p15":
                ch = ch.a("xmlns:p15", OPC.nsP15)
                req = "p15"
            case "p159":
                ch = ch.a("xmlns:p159", OPC.nsP159)
                req = "p159"
            default:
                req = "p14"
            }
            w.open("mc:Choice", ch.a("Requires", req))
            w.open("p:transition", A.new().a("spd", spd).o("p14:dur", !isNone ? dur : nil).o("advClick", advClick).o("advTm", advTm))
            if !isNone {
                w.raw(effect.s)
            }
            snd(&w)
            w.close("p:transition")
            w.close("mc:Choice")
            w.open0("mc:Fallback")
            w.open("p:transition", A.new().a("spd", spd).o("advClick", advClick).o("advTm", advTm))
            if !isNone {
                if ns == "p" {
                    w.raw(effect.s)
                } else {
                    w.empty0("p:fade")
                }
            }
            snd(&w)
            w.close("p:transition")
            w.close("mc:Fallback")
            w.close("mc:AlternateContent")
        }

        /// An unknown kind: the kept element when there is one (and it references no relationship),
        /// else a fade. Returns the namespace prefix the effect is in.
        static func unknownTransition(_ effect: inout W, _ raw: String?) -> String {
            if let raw,
               let d = try? parseXML(raw),
               let e = d.root.elements.first(where: { !(bytesEqual($0.local, "sndAc") || bytesEqual($0.local, "extLst")) }),
               PPTXRead.relRefs(e).isEmpty
            {
                let prefix = String(e.prefix)
                var nsDecl = d.nsDecls()
                nsDecl.removeAll { !bytesEqual($0.key, "xmlns:" + prefix) }
                var e2 = e
                for (k, v) in nsDecl {
                    e2.attrs.append((k, v))
                }
                effect.raw(e2.toXML())
                switch prefix {
                case "p14": return "p14"
                case "p15": return "p15"
                case "p159": return "p159"
                case "p": return "p"
                default:
                    effect = W.frag()
                    effect.empty0("p:fade")
                    return "p"
                }
            }
            effect.empty0("p:fade")
            return "p"
        }

        /// One effect to write (an animation, or one paragraph of a by-paragraph build).
        struct Eff {
            var a: Animation
            var spid: UInt32
            var start: AnimStart
            var paragraph: UInt32?
            var grp: UInt32
        }

        struct Ids {
            var n: UInt32

            mutating func next() -> UInt32 {
                n = satAdd(n, 1)
                return n
            }
        }

        static func tgt(_ w: inout W, _ spid: UInt32, _ para: UInt32?) {
            w.open0("p:tgtEl")
            if let p = para {
                w.open("p:spTgt", A.new().a("spid", spid))
                w.open0("p:txEl")
                w.empty("p:pRg", A.new().a("st", p).a("end", p))
                w.close("p:txEl")
                w.close("p:spTgt")
            } else {
                w.empty("p:spTgt", A.new().a("spid", spid))
            }
            w.close("p:tgtEl")
        }

        static func cBhvr(_ w: inout W, _ ids: inout Ids, _ e: Eff, _ dur: UInt32, _ delay: UInt32?, _ attrs: [String], _ additive: String?) {
            w.open("p:cBhvr", A.new().o("additive", additive))
            let a = A.new().a("id", ids.next()).a("dur", Swift.max(dur, 1)).a("fill", "hold")
            if let d = delay {
                w.open("p:cTn", a)
                w.open0("p:stCondLst")
                w.empty("p:cond", A.new().a("delay", d))
                w.close("p:stCondLst")
                w.close("p:cTn")
            } else {
                w.empty("p:cTn", a)
            }
            tgt(&w, e.spid, e.paragraph)
            if !attrs.isEmpty {
                w.open0("p:attrNameLst")
                for n in attrs {
                    w.elt("p:attrName", n)
                }
                w.close("p:attrNameLst")
            }
            w.close("p:cBhvr")
        }

        static func setVis(_ w: inout W, _ ids: inout Ids, _ e: Eff, _ delay: UInt32, _ visible: Bool) {
            w.open0("p:set")
            cBhvr(&w, &ids, e, 1, delay, ["style.visibility"], nil)
            w.open0("p:to")
            w.val("p:strVal", visible ? "visible" : "hidden")
            w.close("p:to")
            w.close("p:set")
        }

        static func animEffect(_ w: inout W, _ ids: inout Ids, _ e: Eff, _ dur: UInt32, _ filter: String, _ out: Bool) {
            w.open("p:animEffect", A.new().a("transition", out ? "out" : "in").a("filter", filter))
            cBhvr(&w, &ids, e, dur, nil, [], nil)
            w.close("p:animEffect")
        }

        static func animProp(_ w: inout W, _ ids: inout Ids, _ e: Eff, _ dur: UInt32, _ attr: String, _ from: String, _ to: String) {
            w.open("p:anim", A.new().a("calcmode", "lin").a("valueType", "num"))
            cBhvr(&w, &ids, e, dur, nil, [attr], "base")
            w.open0("p:tavLst")
            for (tm, v) in [(0, from), (100_000, to)] {
                w.open("p:tav", A.new().a("tm", tm))
                w.open0("p:val")
                w.val("p:strVal", v)
                w.close("p:val")
                w.close("p:tav")
            }
            w.close("p:tavLst")
            w.close("p:anim")
        }

        static func filterFor(_ effect: String, _ option: String) -> String {
            switch effect {
            case "wipe", "wipeOut":
                switch option {
                case "t": "wipe(down)"
                case "l": "wipe(right)"
                case "r": "wipe(left)"
                default: "wipe(up)"
                }
            case "split", "splitOut":
                switch option {
                case "horzOut": "barn(outHorizontal)"
                case "vertIn": "barn(inVertical)"
                case "vertOut": "barn(outVertical)"
                default: "barn(inHorizontal)"
                }
            case "randomBars", "randomBarsOut":
                option == "vert" ? "randombar(vertical)" : "randombar(horizontal)"
            case "blinds", "blindsOut":
                option == "vert" ? "blinds(vertical)" : "blinds(horizontal)"
            case "box", "boxOut":
                option == "out" ? "box(out)" : "box(in)"
            case "circle":
                option == "out" ? "circle(out)" : "circle(in)"
            case "diamond", "diamondOut":
                option == "out" ? "diamond(out)" : "diamond(in)"
            case "shape", "shapeOut":
                switch option {
                case "circleOut": "circle(out)"
                case "boxIn": "box(in)"
                case "boxOut": "box(out)"
                case "diamondIn": "diamond(in)"
                case "diamondOut": "diamond(out)"
                case "plusIn": "plus(in)"
                case "plusOut": "plus(out)"
                default: "circle(in)"
                }
            case "checkerboard", "checkerboardOut":
                option == "down" ? "checkerboard(down)" : "checkerboard(across)"
            case "dissolve", "dissolveOut":
                "dissolve"
            case "wheel", "wheelOut":
                switch option {
                case "2": "wheel(2)"
                case "3": "wheel(3)"
                case "4": "wheel(4)"
                case "8": "wheel(8)"
                default: "wheel(1)"
                }
            case "strips", "stripsOut":
                switch option {
                case "ru": "strips(upRight)"
                case "ld": "strips(downLeft)"
                case "rd": "strips(downRight)"
                default: "strips(upLeft)"
                }
            case "peek", "peekOut":
                switch option {
                case "t": "slide(fromTop)"
                case "l": "slide(fromLeft)"
                case "r": "slide(fromRight)"
                default: "slide(fromBottom)"
                }
            default:
                "fade"
            }
        }

        static func flyFrom(_ option: String) -> (String, String) {
            let has = { (c: Unicode.Scalar) in option.unicodeScalars.contains(c) }
            let x = has("l") ? "0-#ppt_w/2" : has("r") ? "1+#ppt_w/2" : "#ppt_x"
            let y = has("t") ? "0-#ppt_h/2" : (has("b") || option.isEmpty) ? "1+#ppt_h/2" : "#ppt_y"
            return (x, y)
        }

        static func behaviors(_ w: inout W, _ x: Exp, _ ids: inout Ids, _ e: Eff) {
            let a = e.a
            let dur = Swift.min(Swift.max(a.durationMs, 1), 3_600_000)
            switch a.class {
            case .entrance:
                setVis(&w, &ids, e, 0, true)
                switch a.effect {
                case "appear":
                    break
                case "fly":
                    let (fx, fy) = flyFrom(a.option)
                    animProp(&w, &ids, e, dur, "ppt_x", fx, "#ppt_x")
                    animProp(&w, &ids, e, dur, "ppt_y", fy, "#ppt_y")
                case "zoom", "grow", "expand", "spinner":
                    animProp(&w, &ids, e, dur, "ppt_w", "0", "#ppt_w")
                    animProp(&w, &ids, e, dur, "ppt_h", "0", "#ppt_h")
                    animEffect(&w, &ids, e, dur, "fade", false)
                case "float", "rise":
                    animProp(&w, &ids, e, dur, "ppt_y", a.option == "d" ? "#ppt_y-.1" : "#ppt_y+.1", "#ppt_y")
                    animEffect(&w, &ids, e, dur, "fade", false)
                default:
                    animEffect(&w, &ids, e, dur, filterFor(a.effect, a.option), false)
                }
            case .exit:
                switch a.effect {
                case "disappear":
                    break
                case "flyOut":
                    let (fx, fy) = flyFrom(a.option)
                    animProp(&w, &ids, e, dur, "ppt_x", "#ppt_x", fx)
                    animProp(&w, &ids, e, dur, "ppt_y", "#ppt_y", fy)
                case "floatOut", "sinkDown":
                    let to = a.effect == "sinkDown" || a.option == "d" ? "#ppt_y+.1" : "#ppt_y-.1"
                    animProp(&w, &ids, e, dur, "ppt_y", "#ppt_y", to)
                    animEffect(&w, &ids, e, dur, "fade", true)
                case "zoomOut", "shrinkTurn", "spinnerOut", "contract":
                    animProp(&w, &ids, e, dur, "ppt_w", "#ppt_w", "0")
                    animProp(&w, &ids, e, dur, "ppt_h", "#ppt_h", "0")
                    animEffect(&w, &ids, e, dur, "fade", true)
                default:
                    animEffect(&w, &ids, e, dur, filterFor(a.effect, a.option), true)
                }
                setVis(&w, &ids, e, a.effect == "disappear" ? 0 : dur &- 1, false)
            case .emphasis:
                switch a.effect {
                case "spin", "teeter":
                    let deg0 = a.amount ?? (a.effect == "teeter" ? 4.0 : 360.0)
                    let deg = a.option == "counterClockwise" ? -Swift.abs(deg0) : deg0
                    let by = Int64(rustCast: (deg.clamped(-36_000.0, 36_000.0) * 60_000.0).rounded())
                    w.open("p:animRot", A.new().a("by", by))
                    cBhvr(&w, &ids, e, dur, nil, ["r"], nil)
                    w.close("p:animRot")
                case "transparency":
                    w.open0("p:set")
                    cBhvr(&w, &ids, e, dur, nil, ["style.opacity"], nil)
                    w.open0("p:to")
                    w.val("p:strVal", rustFixed((1.0 - (a.amount ?? 0.5)).clamped(0.0, 1.0), places: 2))
                    w.close("p:to")
                    w.close("p:set")
                case "colorPulse":
                    // As PowerPoint writes it: text and fill go to the colour and back (autoRev). The behaviour
                    // duration is the one import reads as the effect duration.
                    let c = a.color ?? .rgb(.rgb(0xC0, 0x00, 0x00))
                    for (attr, child) in [("style.color", true), ("fillcolor", false)] {
                        w.open("p:animClr", A.new().a("clrSpc", "rgb").a("dir", "cw"))
                        w.open("p:cBhvr", A.new().o("override", child ? "childStyle" : nil))
                        w.empty("p:cTn", A.new().a("id", ids.next()).a("dur", Swift.max(dur, 1)).a("autoRev", "1").a("fill", "remove"))
                        tgt(&w, e.spid, e.paragraph)
                        w.open0("p:attrNameLst")
                        w.elt("p:attrName", attr)
                        w.close("p:attrNameLst")
                        w.close("p:cBhvr")
                        w.open0("p:to")
                        DML.color(&w, c)
                        w.close("p:to")
                        w.close("p:animClr")
                    }
                case "fillColor", "objectColor", "fontColor", "lineColor", "complementaryColor", "darken", "lighten":
                    let attr = switch a.effect {
                    case "fontColor": "style.color"
                    case "lineColor": "stroke.color"
                    default: "fillcolor"
                    }
                    let c = a.color ?? .scheme(.accent2)
                    w.open("p:animClr", A.new().a("clrSpc", "rgb").a("dir", "cw"))
                    cBhvr(&w, &ids, e, dur, nil, [attr], nil)
                    w.open0("p:to")
                    DML.color(&w, c)
                    w.close("p:to")
                    w.close("p:animClr")
                default:
                    let s = a.amount.flatMap { $0.isFinite && $0 > 0.0 ? $0 : nil } ?? (a.effect == "growShrink" ? 1.5 : 1.1)
                    let (sx, sy): (Double, Double) = switch a.option {
                    case "horz": (s, 1.0)
                    case "vert": (1.0, s)
                    default: (s, s)
                    }
                    w.open0("p:animScale")
                    cBhvr(&w, &ids, e, dur, nil, [], nil)
                    w.empty(
                        "p:by",
                        A.new().a("x", Int64(rustCast: (sx.clamped(0.01, 100.0) * 100_000.0).rounded())).a("y", Int64(rustCast: (sy.clamped(0.01, 100.0) * 100_000.0).rounded()))
                    )
                    w.close("p:animScale")
                }
            case .path:
                let kept = a.path.flatMap { p in
                    !rustTrim(p).isEmpty && p.unicodeScalars.allSatisfy({ $0.isASCII && $0 != "\"" && $0 != "<" && $0 != "&" }) ? p : nil
                }
                let byOption = switch a.option {
                case "up": "M 0 0 L 0 -0.25 E"
                case "right": "M 0 0 L 0.25 0 E"
                case "left": "M 0 0 L -0.25 0 E"
                default: "M 0 0 L 0 0.25 E"
                }
                let path = kept ?? byOption
                w.open("p:animMotion", A.new().a("origin", "layout").a("path", path).a("pathEditMode", "relative").a("ptsTypes", ""))
                cBhvr(&w, &ids, e, dur, nil, ["ppt_x", "ppt_y"], nil)
                w.close("p:animMotion")
            case .media:
                let cmd = switch a.effect {
                case "pause": "togglePause"
                case "stop": "stop"
                default: "playFrom(0.0)"
                }
                w.open("p:cmd", A.new().a("type", "call").a("cmd", cmd))
                cBhvr(&w, &ids, e, 1, nil, [], nil)
                w.close("p:cmd")
            }
            _ = x
        }

        static func effectPar(_ w: inout W, _ x: Exp, _ ids: inout Ids, _ e: Eff, _ firstInClick: Bool) {
            let a = e.a
            let node = switch e.start {
            case .onClick: "clickEffect"
            case .withPrevious: "withEffect"
            case .afterPrevious: "afterEffect"
            }
            _ = firstInClick
            let preset = Maps.presetFor(a)
            let sub: UInt32 = preset == 47
                ? 0
                : (Maps.subtypeFromOption(a.effect, a.option) ?? (a.presetId == preset ? a.presetSubtype : nil) ?? 0)
            let repeatCount: String? = switch a.repeat {
            case UInt32.max: "indefinite"
            case 0, 1: nil
            default: String(Swift.min(a.repeat, 10_000) * 1000)
            }
            let accel = a.smoothStart > 0.0 ? Int64(rustCast: (a.smoothStart.clamped(0.0, 1.0) * 100_000.0).rounded()) : nil
            let decel = a.smoothEnd > 0.0 ? Int64(rustCast: (a.smoothEnd.clamped(0.0, 1.0) * 100_000.0).rounded()) : nil
            // `bounceEnd` is a positive percentage (100000 = 100%), same scale as accel/decel. The model stores 0–1.
            var bounce: Int64?
            if a.bounceEnd.isFinite && a.bounceEnd > 0.0 {
                let n = Int64(rustCast: (a.bounceEnd.clamped(0.0, 1.0) * 100_000.0).rounded())
                if n > 0 { bounce = n }
            }
            w.open0("p:par")
            w.open(
                "p:cTn",
                A.new()
                    .a("id", ids.next())
                    .a("presetID", preset)
                    .a("presetClass", a.class.xml)
                    .a("presetSubtype", sub)
                    .o("repeatCount", repeatCount)
                    .o("accel", accel)
                    .o("decel", decel)
                    .o("bounceEnd", bounce)
                    .t("autoRev", a.autoReverse)
                    .a("fill", a.rewind ? "remove" : "hold")
                    .a("grpId", e.grp)
                    .a("nodeType", node)
            )
            w.open0("p:stCondLst")
            w.empty("p:cond", A.new().a("delay", Swift.min(a.delayMs, 3_600_000)))
            w.close("p:stCondLst")
            w.open0("p:childTnLst")
            behaviors(&w, x, &ids, e)
            w.close("p:childTnLst")
            w.close("p:cTn")
            w.close("p:par")
        }

        static func endTime(_ e: Eff) -> UInt32 {
            let rep: UInt32 = switch e.a.repeat {
            case 0, 1: 1
            case UInt32.max: 1
            default: Swift.min(e.a.repeat, 100)
            }
            return Swift.min(satAdd(e.a.delayMs, satMul(e.a.durationMs, rep)), 3_600_000)
        }

        /// click groups → after-groups → effects
        typealias Groups = [(auto: Bool, afters: [[Eff]])]

        static func group(_ effects: [Eff]) -> Groups {
            var clicks: Groups = []
            for e in effects {
                switch e.start {
                case .onClick:
                    clicks.append((false, [[e]]))
                case .withPrevious:
                    if let ci = clicks.indices.last, let gi = clicks[ci].afters.indices.last {
                        clicks[ci].afters[gi].append(e)
                    } else {
                        clicks.append((true, [[e]]))
                    }
                case .afterPrevious:
                    if let ci = clicks.indices.last {
                        clicks[ci].afters.append([e])
                    } else {
                        clicks.append((true, [[e]]))
                    }
                }
            }
            return clicks
        }

        static func clickPars(_ w: inout W, _ x: Exp, _ ids: inout Ids, _ clicks: Groups, _ interactive: Bool) {
            for (ci, click) in clicks.enumerated() {
                w.open0("p:par")
                w.open("p:cTn", A.new().a("id", ids.next()).a("fill", "hold"))
                w.open0("p:stCondLst")
                if interactive && ci == 0 {
                    w.empty("p:cond", A.new().a("delay", 0))
                } else {
                    w.empty("p:cond", A.new().a("delay", "indefinite"))
                    if click.auto {
                        w.open("p:cond", A.new().a("evt", "onBegin").a("delay", 0))
                        w.val("p:tn", 2)
                        w.close("p:cond")
                    }
                }
                w.close("p:stCondLst")
                w.open0("p:childTnLst")
                var t: UInt32 = 0
                for g in click.afters {
                    w.open0("p:par")
                    w.open("p:cTn", A.new().a("id", ids.next()).a("fill", "hold"))
                    w.open0("p:stCondLst")
                    w.empty("p:cond", A.new().a("delay", t))
                    w.close("p:stCondLst")
                    w.open0("p:childTnLst")
                    for (i, e) in g.enumerated() {
                        effectPar(&w, x, &ids, e, i == 0)
                    }
                    w.close("p:childTnLst")
                    w.close("p:cTn")
                    w.close("p:par")
                    t = satAdd(t, g.map(endTime).max() ?? 0)
                }
                w.close("p:childTnLst")
                w.close("p:cTn")
                w.close("p:par")
            }
        }

        /// Write `p:timing` for a slide's animations.
        static func timing(_ w: inout W, _ x: Exp, _ anims: [Animation], _ shapes: [Shape], _ idmap: Shapes.IdMap) {
            var grpCount: [UInt32: UInt32] = [:]
            var main: [Eff] = []
            var triggered: [(UInt32, [Eff])] = []
            var bld: [(UInt32, UInt32, Bool)] = []
            // The last paragraph effect written: (shape, class, trigger, grpId).
            var prevPara: (ShapeId, AnimClass, ShapeId?, UInt32)?
            for a in anims.prefix(10_000) {
                guard let spid = idmap.get(a.shape) else {
                    PPTXLog.warn("pptx: animation on missing shape \(a.shape) skipped")
                    continue
                }
                guard let shape = findShape(shapes, a.shape) else { continue }
                let isShapeKind = if case .shape = shape.kind { true } else { false }
                let textSp = isShapeKind && shape.text != nil
                let isTextSp = isShapeKind && (shape.text.map { !$0.isEmpty } ?? false)
                let text = a.textBuild == .byParagraph && isTextSp ? shape.text : nil
                let roles = text.map(paragraphBuildRoles) ?? []
                let byPara = roles.contains(.top)
                // PowerPoint keeps a shape's consecutive paragraph effects in one build (`grpId`) marked
                // `build="p"`; the reader turns them back into a by-paragraph build only if that plays them
                // the same way.
                let paraEffect = !byPara && textSp && a.paragraph != nil
                let joins = paraEffect && (prevPara.map { $0.0 == a.shape && $0.1 == a.class && $0.2 == a.trigger } ?? false)
                let grp: UInt32
                if let p = prevPara, joins {
                    grp = p.3
                } else {
                    let c = grpCount[spid] ?? 0
                    grp = c
                    grpCount[spid] = c &+ 1
                }
                prevPara = paraEffect ? (a.shape, a.class, a.trigger, grp) : nil
                var effs: [Eff] = []
                if byPara {
                    // One effect per paragraph the build animates on its own, deeper ones with their
                    // parent; indices in the file count empty paragraphs too.
                    var tops = 0
                    for (i, role) in roles.enumerated() {
                        let start: AnimStart
                        switch role {
                        case .top:
                            tops += 1
                            if tops == 1 {
                                start = a.start
                            } else if a.start == .onClick {
                                start = .onClick
                            } else {
                                start = .afterPrevious
                            }
                        case .member where text.flatMap({ $0.paragraphs.at(i) }).map(buildFilled) ?? false:
                            start = .withPrevious
                        default:
                            continue
                        }
                        guard let pi = UInt32(exactly: i) else { break }
                        effs.append(Eff(a: a, spid: spid, start: start, paragraph: pi, grp: grp))
                    }
                } else {
                    effs.append(Eff(a: a, spid: spid, start: a.start, paragraph: a.paragraph, grp: grp))
                }
                if textSp && !joins {
                    bld.append((spid, grp, byPara || paraEffect))
                }
                if let t = a.trigger.flatMap({ idmap.get($0) }) {
                    if let i = triggered.firstIndex(where: { $0.0 == t }) {
                        triggered[i].1.append(contentsOf: effs)
                    } else {
                        triggered.append((t, effs))
                    }
                } else {
                    main.append(contentsOf: effs)
                }
            }
            if main.isEmpty && triggered.isEmpty {
                return
            }
            var ids = Ids(n: 0)
            w.open0("p:timing")
            w.open0("p:tnLst")
            w.open0("p:par")
            w.open("p:cTn", A.new().a("id", ids.next()).a("dur", "indefinite").a("restart", "never").a("nodeType", "tmRoot"))
            w.open0("p:childTnLst")
            if !main.isEmpty {
                let clicks = group(main)
                w.open("p:seq", A.new().a("concurrent", 1).a("nextAc", "seek"))
                w.open("p:cTn", A.new().a("id", ids.next()).a("dur", "indefinite").a("nodeType", "mainSeq"))
                w.open0("p:childTnLst")
                clickPars(&w, x, &ids, clicks, false)
                w.close("p:childTnLst")
                w.close("p:cTn")
                w.open0("p:prevCondLst")
                w.open("p:cond", A.new().a("evt", "onPrev").a("delay", 0))
                w.open0("p:tgtEl")
                w.empty0("p:sldTgt")
                w.close("p:tgtEl")
                w.close("p:cond")
                w.close("p:prevCondLst")
                w.open0("p:nextCondLst")
                w.open("p:cond", A.new().a("evt", "onNext").a("delay", 0))
                w.open0("p:tgtEl")
                w.empty0("p:sldTgt")
                w.close("p:tgtEl")
                w.close("p:cond")
                w.close("p:nextCondLst")
                w.close("p:seq")
            }
            for (trig, effs0) in triggered {
                // The first step starts with the button's click. Later On Click effects must remain
                // separate steps; With/After Previous effects still belong to their preceding step.
                let effs = effs0.enumerated().map { i, e in
                    var e = e
                    if i == 0 { e.start = .onClick }
                    return e
                }
                let clicks = group(effs)
                func trigCond(_ w: inout W) {
                    w.open("p:cond", A.new().a("evt", "onClick").a("delay", 0))
                    w.open0("p:tgtEl")
                    w.empty("p:spTgt", A.new().a("spid", trig))
                    w.close("p:tgtEl")
                    w.close("p:cond")
                }
                w.open("p:seq", A.new().a("concurrent", 1).a("nextAc", "seek"))
                w.open(
                    "p:cTn",
                    A.new()
                        .a("id", ids.next())
                        .a("restart", "whenNotActive")
                        .a("fill", "hold")
                        .a("evtFilter", "cancelBubble")
                        .a("nodeType", "interactiveSeq")
                )
                w.open0("p:stCondLst")
                trigCond(&w)
                w.close("p:stCondLst")
                w.open("p:endSync", A.new().a("evt", "end").a("delay", 0))
                w.empty("p:rtn", A.new().a("val", "all"))
                w.close("p:endSync")
                w.open0("p:childTnLst")
                clickPars(&w, x, &ids, clicks, true)
                w.close("p:childTnLst")
                w.close("p:cTn")
                w.open0("p:nextCondLst")
                trigCond(&w)
                w.close("p:nextCondLst")
                w.close("p:seq")
            }
            w.close("p:childTnLst")
            w.close("p:cTn")
            w.close("p:par")
            w.close("p:tnLst")
            if !bld.isEmpty {
                w.open0("p:bldLst")
                for (spid, grp, buildP) in bld {
                    w.empty("p:bldP", A.new().a("spid", spid).a("grpId", grp).o("build", buildP ? "p" : nil).t("animBg", !buildP))
                }
                w.close("p:bldLst")
            }
            w.close("p:timing")
        }
    }
}
