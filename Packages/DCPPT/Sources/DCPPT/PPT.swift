// DCPPT — a `.ppt` as a DCModel presentation. P1 (Docs/plans/Legacy-PPT-and-Encryption.md) reads the document: the
// slide and notes size from the DocumentAtom ([MS-PPT] 2.4.2, in master units of 1/576 inch) and the slides from
// the slide list (the SlideListWithTextContainer of instance 0, 2.4.14.3: one SlidePersistAtom per slide, in order).
// Each slide becomes a blank slide of the default master; its content comes in P2–P5. What isn't brought over is
// listed in the import report.
import DCCFB
import DCGeometry
import DCModel

/// What a `.ppt` import read and what it left behind.
public struct PPTReport: Sendable, Equatable {
    /// Slides in the file's slide list.
    public var slides: Int
    /// 1-based numbers of the slides whose record couldn't be read (they're blank).
    public var unreadSlides: [Int]
    /// Saves in the file's edit chain (more than one: PowerPoint saved it incrementally).
    public var edits: Int
    public var encrypted: Bool
    /// What this version doesn't bring over yet.
    public var notImported: [String]
}

public enum PPT {
    /// Whether `bytes` is a `.ppt`.
    public static func sniff(_ bytes: [UInt8]) -> Bool { PPTFile.isPPT(bytes) }

    /// Points per master unit: 72 / 576.
    static let pointsPerMasterUnit = 1.0 / 8.0
    /// The DocumentAtom's sizes are clamped to what PowerPoint allows (1 to 56 inches).
    static let sizeRange = 72.0 ... 4032.0

    /// The presentation in a `.ppt`, and what the import couldn't bring over.
    public static func importChecked(_ bytes: [UInt8], password: String? = nil) throws(PPTError) -> (Presentation, PPTReport) {
        let file = try PPTFile(bytes, password: password)
        guard let doc = file.object(file.documentRef), let root = Record(doc, at: 0), root.type == RT.document, root.isContainer else {
            throw .damaged("the DocumentContainer can't be read")
        }
        let children = root.children(doc)

        var size = Size(720, 540), notes = Size(540, 720)
        if let atom = children.first(where: { $0.type == RT.documentAtom }), atom.body.count >= 16 {
            func points(_ v: Int32, _ fallback: Double) -> Double {
                let p = Double(v) * pointsPerMasterUnit
                return p.isFinite && sizeRange.contains(p) ? p : fallback
            }
            let b = atom.body.lowerBound
            size = Size(points(i32(doc, b), 720), points(i32(doc, b + 4), 540))
            notes = Size(points(i32(doc, b + 8), 540), points(i32(doc, b + 12), 720))
        }

        // The slide list: SlidePersistAtoms in the SlideListWithTextContainer of instance 0.
        var slideRefs: [UInt32] = []
        if let list = children.first(where: { $0.type == RT.slideListWithText && $0.instance == 0 }) {
            for r in list.children(doc) where r.type == RT.slidePersistAtom && r.body.count >= 4 {
                slideRefs.append(le32(doc, r.body.lowerBound))
            }
        }

        var p = blankPresentation(size, .default, false)
        p.notesSize = notes
        let layout = layoutOfKind(p, .blank) ?? p.masters.first?.layouts.first?.id ?? LayoutId(0)
        var unread: [Int] = []
        for (i, ref) in slideRefs.enumerated() {
            if let o = file.object(ref), let r = Record(o, at: 0), r.type == RT.slide, r.isContainer {} else { unread.append(i + 1) }
            // The deck can run out of ids only past millions of slides; a file can't make that many.
            guard let slide = newSlide(&p, layout) else { break }
            p.slides.append(slide)
        }
        let report = PPTReport(slides: slideRefs.count, unreadSlides: unread, edits: file.edits, encrypted: file.isEncrypted,
                               notImported: ["text", "shapes", "pictures", "masters and layouts", "notes", "transitions and animations"])
        return (p, report)
    }
}
