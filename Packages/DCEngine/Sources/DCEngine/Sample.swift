// DCEngine — a sample deck built entirely in code (our own text, shapes and data), for demos, screenshots
// and tests: `dccli run --sample`.
// Port of deckcraft crates/engine/src/sample.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors). Every command and parameter is deckcraft's, in order, so the deck is the corpus's
// `sample.deckcraft`.
import DCCore
import DCModel

public enum Sample {
    @discardableResult
    private static func run(_ s: Session, _ id: String, _ p: JSON) throws(EngineError) -> JSON {
        try s.execute(id, p)
    }

    private static func lastId(_ v: JSON) -> JSON { .integer(v.get("id")?.asU64 ?? 0) }

    /// The commands the sample deck runs.
    public static let commands = [
        "file.new", "text.set", "slide.notes", "shape.insert", "shape.fill", "shape.line", "shape.rename", "transition.set", "slide.new",
        "edit.select", "animation.set", "animation.options", "design.background", "format.color", "shape.effects", "format.size",
        "format.bold", "animation.add", "insert.textBox", "format.alignCenter", "format.italic", "insert.chart", "insert.table",
        "section.add", "slide.go", "edit.deselect",
    ]

    /// Open the sample presentation in a new document.
    public static func openSample(_ s: Session) throws(EngineError) {
        try run(s, "file.new", ["theme": "DeckCraft"])
        try openRest(s)
    }

    private static func openRest(_ s: Session) throws(EngineError) {
        var st = try s.doc()
        let title = JSON.integer(st.currentSlide?.shapes.first?.id.rawValue ?? 0)
        let sub = JSON.integer(st.currentSlide?.shapes.at(1)?.id.rawValue ?? 0)
        try run(s, "text.set", ["id": title, "text": "Northern Lights"])
        try run(s, "text.set", ["id": sub, "text": "A short tour of the aurora — where it comes from, when to look, and how to photograph it"])
        try run(s, "slide.notes", ["text": "Welcome everyone. This deck was made in DeckCraft."])
        // Decorative bands on the title slide.
        let b = try run(s, "shape.insert", ["preset": "rect", "rect": [0, 470, 960, 70]])
        try run(s, "shape.fill", ["id": lastId(b), "gradient": ["stops": [[0, "accent1"], [0.5, "accent4"], [1, "accent2"]], "angle": 0]])
        try run(s, "shape.line", ["id": lastId(b), "none": true])
        try run(s, "shape.rename", ["id": lastId(b), "name": "Aurora Band"])
        try run(s, "transition.set", ["kind": "fade"])

        // Agenda.
        try run(s, "slide.new", ["layout": "titleAndContent", "title": "What we'll cover"])
        let body = JSON.integer(try s.doc().currentSlide?.shapes.at(1)?.id.rawValue ?? 0)
        try run(s, "text.set", [
            "id": body,
            "text": "The science: solar wind meets the magnetosphere\nWhere and when to see it\n\tHigh latitudes, dark skies, long winter nights\n\tKp index and space-weather forecasts\nPhotographing the aurora\nSafety and etiquette in the field",
        ])
        try run(s, "transition.set", ["kind": "push", "option": "u"])
        try run(s, "edit.select", ["ids": [body]])
        try run(s, "animation.set", ["effect": "fade", "class": "entrance"])
        try run(s, "animation.options", ["textBuild": "byParagraph"])

        // Section header.
        try run(s, "slide.new", ["layout": "sectionHeader", "title": "The Science", "body": "Charged particles, magnetic fields and glowing gases"])
        try run(s, "design.background", ["color": "dk2"])
        st = try s.doc()
        let ids = JSON.array((st.currentSlide?.shapes ?? []).map { .integer($0.id.rawValue) })
        try run(s, "edit.select", ["ids": ids])
        try run(s, "format.color", ["color": "#FFFFFF"])
        try run(s, "transition.set", ["kind": "wipe", "option": "r"])

        // Process diagram from shapes.
        try run(s, "slide.new", ["layout": "titleOnly", "title": "From the Sun to your sky"])
        let steps = [("Solar wind", "accent2"), ("Magnetosphere", "accent1"), ("Particles collide", "accent4"), ("Light!", "accent3")]
        var prev: UInt64?
        for (i, (label, color)) in steps.enumerated() {
            let x = 60.0 + Double(i) * 220.0
            let v = try run(s, "shape.insert", ["preset": .string(i == 3 ? "star5" : "roundRect"), "rect": [.double(x), 210, 190, 120], "text": .string(label)])
            let id = lastId(v)
            try run(s, "shape.fill", ["id": id, "color": .string(color)])
            try run(s, "shape.line", ["id": id, "none": true])
            try run(s, "shape.effects", ["id": id, "shadow": "bottom"])
            try run(s, "edit.select", ["ids": [id]])
            try run(s, "format.size", ["size": 17])
            try run(s, "format.bold", ["on": true])
            try run(s, "animation.add", ["effect": "zoom", "class": "entrance", "start": .string(i == 0 ? "onClick" : "afterPrevious")])
            if prev != nil {
                let a = try run(s, "shape.insert", ["preset": "rightArrow", "rect": [.double(x - 36.0), 255, 32, 30]])
                try run(s, "shape.fill", ["id": lastId(a), "color": "tx2"])
                try run(s, "shape.line", ["id": lastId(a), "none": true])
            }
            prev = id.asU64
        }
        let cap = try run(s, "insert.textBox", ["rect": [60, 380, 840, 60], "text": "Oxygen glows green and red; nitrogen adds blue and purple fringes."])
        try run(s, "edit.select", ["ids": [lastId(cap)]])
        try run(s, "format.alignCenter", .emptyObject)
        try run(s, "format.size", ["size": 20])
        try run(s, "format.italic", ["on": true])
        try run(s, "transition.set", ["kind": "morph"])

        // Chart.
        try run(s, "slide.new", ["layout": "titleOnly", "title": "Best months to look (clear nights)"])
        try run(s, "insert.chart", [
            "type": "column", "rect": [80, 140, 800, 360], "title": "Average clear, dark nights per month",
            "categories": ["Sep", "Oct", "Nov", "Dec", "Jan", "Feb", "Mar"],
            "series": [
                ["name": "Tromsø", "values": [6, 8, 7, 6, 7, 9, 11]],
                ["name": "Fairbanks", "values": [9, 10, 8, 9, 11, 12, 13]],
                ["name": "Yellowknife", "values": [8, 11, 9, 10, 12, 13, 14]],
            ],
        ])
        try run(s, "transition.set", ["kind": "fade"])

        // Table.
        try run(s, "slide.new", ["layout": "titleOnly", "title": "Camera settings that work"])
        try run(s, "insert.table", [
            "rows": 5, "cols": 3, "rect": [100, 150, 760, 260],
            "data": [
                ["Setting", "Faint aurora", "Bright, active aurora"], ["Aperture", "f/1.4 – f/2.8", "f/2.8"], ["Shutter", "8 – 15 s", "1 – 4 s"],
                ["ISO", "1600 – 3200", "800 – 1600"], ["Focus", "Manual, on a bright star", "Manual, on a bright star"],
            ],
        ])
        try run(s, "transition.set", ["kind": "cover", "option": "l"])

        // Two content: comparison with shapes.
        try run(s, "slide.new", ["layout": "twoContent", "title": "Field checklist"])
        st = try s.doc()
        let l = JSON.integer(st.currentSlide?.shapes.at(1)?.id.rawValue ?? 0)
        let r = JSON.integer(st.currentSlide?.shapes.at(2)?.id.rawValue ?? 0)
        try run(s, "text.set", ["id": l, "text": "Bring\n\tTripod and spare batteries\n\tHeadlamp with a red mode\n\tWarm layers and a thermos"])
        try run(s, "text.set", ["id": r, "text": "Remember\n\tCheck the forecast and cloud cover\n\tLet your eyes adapt for 20 minutes\n\tLeave no trace"])
        try run(s, "transition.set", ["kind": "split"])

        // Closing.
        try run(s, "slide.new", ["layout": "title", "title": "Clear skies!", "body": "Made with DeckCraft — free and open source"])
        let moon = try run(s, "shape.insert", ["preset": "moon", "rect": [820, 40, 80, 120]])
        try run(s, "shape.fill", ["id": lastId(moon), "color": "accent6"])
        try run(s, "shape.line", ["id": lastId(moon), "none": true])
        try run(s, "shape.effects", ["id": lastId(moon), "glow": ["color": "accent6", "radius": 10]])
        try run(s, "transition.set", ["kind": "fade"])

        try run(s, "section.add", ["name": "Introduction", "at": 0])
        try run(s, "section.add", ["name": "Science", "at": 2])
        try run(s, "section.add", ["name": "In the Field", "at": 5])
        try run(s, "slide.go", ["index": 0])
        try run(s, "edit.deselect", .emptyObject)
        try run(s, "edit.deselect", .emptyObject)
        // The sample opens clean: no undo history, not dirty.
        if let st = s.activeDoc {
            st.history.undo.removeAll()
            st.history.redo.removeAll()
            st.savedDocRef = st.docRef
            st.title = "Northern Lights"
        }
    }
}
