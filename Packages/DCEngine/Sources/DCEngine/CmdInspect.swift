// DCEngine — inspection for agents: the deck, slides and shapes as JSON (verify work without screenshots).
// Port of deckcraft crates/engine/src/cmd/inspect.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCGeometry
import DCModel
import Foundation

public enum InspectCommands {
    public static func specs() -> [CommandSpec] {
        [
            .query("document.inspect", "Inspect Presentation", [], nil, "{} → slides with titles, layouts, shape counts; selection; size; theme", Cmd.hasDoc, document),
            .query("slide.inspect", "Inspect Slide", [], nil, "{index?} → the slide's shapes with ids, kinds, boxes, text, fills, animations, transition, notes (text, and notesBody with its formatting)", Cmd.hasDoc, slide),
            .query("shape.inspect", "Inspect Shape", [], nil, "{id} → full shape JSON plus its effective box", Cmd.hasDoc, shape),
            .query("commands.list", "List Commands", [], nil, "{filter?: substring} → [{id, label, params, enabled}]", Cmd.always, commands),
        ]
    }

    /// serde's `kind` tag of a value (`serde_json::to_value(&x).get("kind")`), or null.
    private static func kindTag(_ v: JSON) -> JSON { v.get("kind") ?? .null }

    @Sendable static func document(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        let d = st.doc
        let slides: [JSON] = d.slides.enumerated().map { i, sl in
            let layout = d.layout(sl.layout)?.layout.name ?? ""
            return [
                "index": .integer(i), "id": sl.id.toJSON(), "title": .string(sl.title), "layout": .string(layout), "shapes": .integer(sl.shapes.count),
                "hidden": .bool(sl.hidden), "transition": .opt(sl.transition?.kind), "animations": .integer(sl.animations.count), "notes": .string(sl.notesText),
            ]
        }
        let m = d.masters.first
        return [
            "title": .string(st.displayTitle),
            "path": .opt(st.path),
            "dirty": .bool(st.isDirty),
            "slideSize": [.num(d.slideSize.width), .num(d.slideSize.height)],
            "slides": .array(slides),
            "sections": .array(d.sections.map { ["name": .string($0.name), "slides": .integer($0.slides.count)] }),
            "theme": .opt(m?.theme.name),
            "fonts": m.map { ["major": .string($0.theme.fonts.major.latin), "minor": .string($0.theme.fonts.minor.latin)] } ?? .null,
            "layouts": m.map { .array($0.layouts.map { ["id": $0.id.toJSON(), "name": .string($0.name)] }) } ?? .null,
            "selection": st.selection.toJSON(),
            "media": .array(d.media.map { ["id": $0.id.toJSON(), "name": .string($0.name), "type": .string($0.contentType), "bytes": .integer($0.data.count)] }),
            "undo": .opt(st.history.undo.last?.label),
            "redo": .opt(st.history.redo.last?.label),
        ]
    }

    /// One shape as `slide.inspect` lists it (`shape_summary`).
    public static func shapeSummary(_ ctx: Resolve.Ctx?, _ sh: Shape, _ depth: Int) -> JSON {
        let x = ctx.map { Resolve.xfrm($0, sh) } ?? sh.xfrm ?? Xfrm()
        let fill: JSON? = ctx.map { c in
            let (f, ph) = Resolve.fill(c, sh)
            switch f {
            case .solid(let color)?: return .string("#\(c.color(color, ph).hex)")
            case .none_?, nil: return "none"
            case let other?: return kindTag(other.toJSON())
            }
        }
        var o = JSONObject()
        o.set("id", sh.id.toJSON())
        o.set("name", .string(sh.name))
        o.set("kind", .string(sh.kindName))
        o.set("box", [.num(round(x.x)), .num(round(x.y)), .num(round(x.w)), .num(round(x.h))])
        o.set("rotation", .num(x.rot))
        if let ph = sh.ph { o.set("placeholder", .string(ph.kind.xml)) }
        if let n = sh.geom.presetName {
            switch sh.kind {
            case .shape, .connector: o.set("preset", .string(n))
            default: break
            }
        }
        if let t = sh.text, !t.isEmpty { o.set("text", .string(t.text)) }
        if let f = fill { o.set("fill", f) }
        if sh.hidden { o.set("hidden", true) }
        if !sh.descr.isEmpty { o.set("altText", .string(sh.descr)) }
        switch sh.kind {
        case .table(let t):
            o.set("table", [
                "rows": .integer(t.nRows), "cols": .integer(t.nCols), "style": .string(t.style),
                "cells": .array(t.rows.map { r in .array(r.cells.map { .string($0.text.text) }) }),
            ])
        case .chart(let c):
            o.set("chart", [
                "type": .string(c.kind.label), "title": .opt(c.title), "categories": c.categories.toJSON(),
                "series": .array(c.series.map { ["name": .string($0.name), "values": $0.values.toJSON()] }),
            ])
        case .group(let children, _) where depth < 8:
            o.set("children", .array(children.map { shapeSummary(nil, $0, depth + 1) }))
        case .media(let m):
            o.set("media", ["id": m.media.toJSON(), "video": .bool(m.video), "autoplay": .bool(m.autoplay), "loop": .bool(m.loopPlay)])
        default:
            break
        }
        return .object(o)
    }

    private static func round(_ v: Double) -> Double { (v * 100).rounded(.toNearestOrAwayFromZero) / 100 }

    @Sendable static func slide(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        let doc = st.doc
        let i = Cmd.usizeParam(p, "index") ?? st.selection.slide
        guard let sl = doc.slides.at(i) else { throw Cmd.bad("slide.inspect", "no slide \(i)") }
        let ctx = Resolve.Ctx.forSlide(doc, sl)
        let shapes = sl.shapes.map { shapeSummary(ctx, $0, 0) }
        let bg: JSON = ctx.map { c in
            switch Resolve.background(c, sl) {
            case (.solid(let color), let ph): return .string("#\(c.color(color, ph).hex)")
            case (let f, _): return kindTag(f.toJSON())
            }
        } ?? .null
        return [
            "index": .integer(i),
            "id": sl.id.toJSON(),
            "layout": .opt(doc.layout(sl.layout)?.layout.name),
            "title": .string(sl.title),
            "background": bg,
            "shapes": .array(shapes),
            "transition": sl.transition?.toJSON() ?? .null,
            "animations": sl.animations.toJSON(),
            "notes": .string(sl.notesText),
            "notesBody": sl.notes.toJSON(),
            "comments": .integer(sl.comments.count),
            "hidden": .bool(sl.hidden),
        ]
    }

    @Sendable static func shape(_ s: Session, _ p: JSON) throws -> JSON {
        let st = try s.doc()
        guard let id = try Cmd.idParam(p, "id", "shape.inspect") ?? st.selection.shapes.first else {
            throw Cmd.bad("shape.inspect", "missing `id`")
        }
        guard let sh = st.shape(id) else { throw Cmd.bad("shape.inspect", "no shape \(id)") }
        let x = Cmd.xfrmOf(st.doc, st.selection, sh)
        return ["shape": sh.toJSON(), "box": x.toJSON()]
    }

    @Sendable static func commands(_ s: Session, _ p: JSON) throws -> JSON {
        let f = rustASCIILowercase(Cmd.strParam(p, "filter") ?? "")
        func has(_ text: String) -> Bool { f.isEmpty || rustASCIILowercase(text).range(of: f, options: .literal) != nil }
        return .array(s.commands().filter { has($0.id) || has($0.label) }.map { $0.toJSON() })
    }
}
