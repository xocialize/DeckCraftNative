// DCEngine — original starter presentations for File › New.
// Port of deckcraft crates/engine/src/templates.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
//
// Each deck is a few slides of our own text on one of our themes. Nothing here is copied from another
// product's templates.
import DCCore
import DCGeometry
import DCModel
import Foundation

/// One slide of a starter: a layout, a title, text for each non-title placeholder in order, and optional
/// speaker notes.
public struct SlideSeed: Sendable {
    public var layout: String
    public var title: String
    public var bodies: [String]
    public var notes: String
}

/// A starter deck shown in the template gallery.
public struct Starter: Sendable {
    public var name: String
    public var summary: String
    public var theme: String
    public var slides: [SlideSeed]
}

private func seed(_ layout: String, _ title: String, _ bodies: [String], _ notes: String) -> SlideSeed {
    SlideSeed(layout: layout, title: title, bodies: bodies, notes: notes)
}

public enum Templates {
    static let starterList: [Starter] = [
    Starter(
        name: "Briefing",
        summary: "A weekly check-in: what changed, what's stuck, and who does the next thing",
        theme: "Harbor",
        slides: [
            seed("title", "Weekly briefing", ["What changed, what's stuck, and what we do next"], "Open with what changed since last week."),
            seed(
                "titleAndContent",
                "This week's agenda",
                ["Shipped since last time\n\tOne concrete change\nStill open\n\tThe decision we need\nNext\n\tWho does it, and by when"],
                "",
            ),
            seed("sectionHeader", "Where we are", ["A short picture before the details"], ""),
            seed(
                "twoContent",
                "Done and next",
                [
                    "Done\n\tThe change is in people's hands\n\tWe wrote down what we learned",
                    "Next\n\tPick the one risk to retire\n\tSay who owns it",
                ],
                "",
            ),
            seed("title", "See you next week", ["Bring one number and one question"], ""),
        ],
    ),
    Starter(
        name: "Lesson",
        summary: "A short class that ends with the learner explaining the idea",
        theme: "Meadow",
        slides: [
            seed("title", "How a lock works", ["A short lesson for people new to the idea"], ""),
            seed(
                "titleAndContent",
                "By the end",
                ["You can say what a lock protects\n\tAnd what it does not\nYou can sketch one in three steps"],
                "",
            ),
            seed("sectionHeader", "The idea", ["One metaphor, then the real thing"], ""),
            seed(
                "titleAndContent",
                "Three steps",
                ["Name the thing being shared\nDecide who may change it\nLeave it so the next person can tell"],
                "",
            ),
            seed("title", "Try it", ["Explain a lock to someone who has never seen one"], ""),
        ],
    ),
    Starter(
        name: "Pitch",
        summary: "A ten-minute conversation about one promise, not a tour of features",
        theme: "Ember",
        slides: [
            seed("title", "A quieter inbox", ["Ten minutes. One promise."], ""),
            seed(
                "titleAndContent",
                "The mess",
                [
                    "People miss the one message that mattered\n\tIt arrived between newsletters\nThey spend the morning sorting\n\tAnd still feel behind",
                ],
                "",
            ),
            seed("sectionHeader", "A smaller promise", ["Show the one message. Hide the rest until asked."], ""),
            seed(
                "comparison",
                "Today and after",
                [
                    "Today",
                    "The important note is buried\nFinding it takes a search",
                    "After",
                    "It sits at the top until you deal with it\nEverything else waits",
                ],
                "",
            ),
            seed("title", "The ask", ["Twenty people, two weeks, one question: did the right note surface?"], ""),
        ],
    ),
    Starter(
        name: "Field Notes",
        summary: "What an outing set out to see, and what it actually found",
        theme: "Coral Reef",
        slides: [
            seed("title", "Saturday on the ridge", ["What we went to see, and what we found"], ""),
            seed("titleAndContent", "Plan", ["Leave at dawn\n\tCold, clear, little wind\nWalk the west path\nBe back before dusk"], ""),
            seed("sectionHeader", "What we saw", ["Notes taken on the spot"], ""),
            seed(
                "twoContent",
                "Expected and found",
                [
                    "Expected\n\tA clear view from the ridge\n\tThe creek on the map",
                    "Found\n\tLow cloud on the ridge\n\tThe creek, and a better pencil",
                ],
                "",
            ),
            seed("title", "Pack list for next time", ["Warmer gloves. A second pencil. The map that shows the creek."], ""),
        ],
    ),
    Starter(
        name: "Quarterly",
        summary: "A report meant to be read aloud in half an hour",
        theme: "Paper",
        slides: [
            seed("title", "Spring report", ["Read aloud in thirty minutes"], ""),
            seed(
                "titleAndContent",
                "Headlines",
                ["The waiting list got shorter\n\tBy the amount we promised\nTwo things slipped\n\tBoth have a new date"],
                "",
            ),
            seed("sectionHeader", "The numbers", ["Only the ones that change a decision"], ""),
            seed("titleAndContent", "What we will stop", ["The report nobody reads\nThe meeting that repeats the report"], ""),
            seed("title", "Questions we want", ["Where should the next quarter refuse work?"], ""),
        ],
    ),
    Starter(
        name: "Evening Talk",
        summary: "A public talk the audience can check on the way home",
        theme: "Nocturne",
        slides: [
            seed("title", "Lights out", ["A talk about how cities sleep"], ""),
            seed("titleAndContent", "Road map", ["Why the sky looks orange\nWhat a dark street is for\nOne change a block can make"], ""),
            seed("sectionHeader", "Look up", ["The part you can check on the way home"], ""),
            seed(
                "titleAndContent",
                "One change",
                ["Shield the lamp so light goes down\n\tNot into bedroom windows\nLeave a path you can still walk"],
                "",
            ),
            seed("title", "Walk home", ["Count the lamps you can see from your pillow"], ""),
        ],
    ),
]

    /// The starter gallery, in the order File › New shows it.
    public static func starters() -> [Starter] { starterList }

    /// Starters whose name, summary, theme or a slide title contains `query` (empty matches all).
    public static func matching(_ query: String) -> [Starter] {
        let q = rustLowercase(String(rustTrim(query)))
        func hit(_ text: String) -> Bool { q.isEmpty || rustLowercase(text).range(of: q, options: .literal) != nil }
        return starters().filter { t in q.isEmpty || hit(t.name) || hit(t.summary) || hit(t.theme) || t.slides.contains { hit($0.title) } }
    }

    public static func find(_ name: String) -> Starter? {
        let n = rustASCIILowercase(String(rustTrim(name)))
        return starters().first { Array(rustASCIILowercase($0.name).utf8) == Array(n.utf8) }
    }

    static func textWithLevels(_ text: String) -> TextBody {
        var body = TextBody.fromText(text)
        for i in body.paragraphs.indices {
            let tabs = body.paragraphs[i].runs.first.map { $0.text.unicodeScalars.prefix { $0 == "\t" }.count } ?? 0
            if tabs > 0 {
                body.paragraphs[i].runs[0].text = String(String.UnicodeScalarView(body.paragraphs[i].runs[0].text.unicodeScalars.drop { $0 == "\t" }))
                body.paragraphs[i].level = UInt8(min(tabs, 8))
            }
        }
        return body
    }

    /// A new presentation filled with `name`'s slides. `size` is the slide size in points.
    public static func build(_ name: String, _ size: Size) throws(EngineError) -> Presentation {
        guard let starter = find(name) else {
            let names = starters().map(\.name).joined(separator: ", ")
            throw Cmd.bad("file.new", "no template `\(name)`; use \(names)")
        }
        guard let theme = builtinThemes().first(where: { Array(rustASCIILowercase($0.name).utf8) == Array(rustASCIILowercase(starter.theme).utf8) }) else {
            throw Cmd.bad("file.new", "template `\(starter.name)` names a missing theme `\(starter.theme)`")
        }
        var doc = blankPresentation(size, theme, false)
        for seed in starter.slides {
            guard let layout = SlideCommands.findLayout(doc, .string(seed.layout), 0) else {
                throw Cmd.bad("file.new", "template `\(starter.name)` uses an unknown layout `\(seed.layout)`")
            }
            guard var slide = newSlide(&doc, layout) else { throw Cmd.bad("file.new", Cmd.noIdSpace) }
            if !seed.title.isEmpty, let i = slide.shapes.firstIndex(where: { $0.phType?.isTitle == true }) {
                slide.shapes[i].text = textWithLevels(seed.title)
            }
            var bodies = seed.bodies.makeIterator()
            for i in slide.shapes.indices where slide.shapes[i].phType.map({ !$0.isTitle }) == true {
                guard let text = bodies.next() else { break }
                if !text.isEmpty { slide.shapes[i].text = textWithLevels(text) }
            }
            if bodies.next() != nil {
                throw Cmd.bad("file.new", "template `\(starter.name)` has more text than the `\(seed.layout)` layout holds")
            }
            if !seed.notes.isEmpty { slide.notes = textWithLevels(seed.notes) }
            doc.slides.append(slide)
        }
        return doc
    }
}
