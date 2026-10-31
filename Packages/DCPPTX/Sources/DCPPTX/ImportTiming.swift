// DCPPTX — the timing reader for other importers. A legacy `.ppt` (DCPPT, P5 of
// Docs/plans/Legacy-PPT-and-Encryption.md) holds its animations as PowerPoint 2002's binary timing tree, the same
// model as PresentationML's `p:timing`, or as a `p:timing` PowerPoint 2007 embedded; DCPPT turns either into a
// `p:timing` element and reads it here, so a `.ppt` and a `.pptx` map their effects the same way.
import DCModel

public enum PPTXTiming {
    /// The Animation Pane list of a `p:timing` element. `ids` maps the file's shape ids (`spTgt spid`) to the
    /// slide's; `shapes` are the slide's shapes, for its paragraph builds.
    public static func animations(_ timing: XMLEl, shapes: [Shape], ids: [UInt32: ShapeId]) -> [Animation] {
        let ctx = PPTXRead.IdCtx()
        ctx.map = ids
        return PPTXRead.animations(ctx, timing, shapes)
    }

    /// Our effect and option for a PowerPoint preset: its class, id and subtype.
    public static func effect(_ animClass: AnimClass, preset: UInt32, subtype: UInt32) -> (effect: String, option: String) {
        let base = Maps.effectForPreset(animClass, preset) ?? Maps.fallbackEffect(animClass)
        return (base, Maps.optionFromSubtype(base, subtype))
    }

    /// The first `timing` element in an XML document, wherever it sits; nil when there is none or the XML can't be
    /// read.
    public static func timing(in xml: [UInt8]) -> XMLEl? {
        guard let doc = try? parseXML(xml) else { return nil }
        return doc.root.is("timing") ? doc.root : doc.root.find("timing")
    }
}
