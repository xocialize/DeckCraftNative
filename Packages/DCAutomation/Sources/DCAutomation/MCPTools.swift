// DCAutomation — the MCP tools: names, descriptions and JSON Schemas, and what each one calls on a
// `Backend`. Port of deckcraft crates/mcp/src/tools.rs (MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors). The definitions are deckcraft's JSON values, so `tools/list` answers what
// deckcraft's server answers, byte for byte.
import DCCore
import DCEngine

/// The result of `tools/call`: MCP content blocks plus the `isError` flag.
public struct ToolResult: Sendable, Equatable {
    public var content: [JSON]
    public var isError: Bool

    public init(content: [JSON], isError: Bool) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ t: String) -> ToolResult {
        ToolResult(content: [["type": "text", "text": .string(t)]], isError: false)
    }

    /// The value as pretty JSON text.
    public static func json(_ v: JSON) -> ToolResult { text(v.pretty) }

    public static func error(_ t: String) -> ToolResult {
        ToolResult(content: [["type": "text", "text": .string(t)]], isError: true)
    }

    public static func image(_ pngBase64: String, _ info: JSON) -> ToolResult {
        ToolResult(content: [["type": "image", "data": .string(pngBase64), "mimeType": "image/png"], ["type": "text", "text": .string(info.display)]], isError: false)
    }

    public func toJSON() -> JSON { ["content": .array(content), "isError": .bool(isError)] }
}

public enum MCPTools {
    private static func num(_ desc: String) -> JSON { ["type": "number", "description": .string(desc)] }
    private static func int(_ desc: String) -> JSON { ["type": "integer", "minimum": 0, "description": .string(desc)] }
    private static func string(_ desc: String) -> JSON { ["type": "string", "description": .string(desc)] }
    private static func boolean(_ desc: String) -> JSON { ["type": "boolean", "description": .string(desc)] }

    private static func modsSchema() -> JSON {
        [
            "type": "object", "additionalProperties": false,
            "description": "Modifier keys (cmd = Command on macOS / Ctrl elsewhere; alt = Option)",
            "properties": ["shift": ["type": "boolean"], "alt": ["type": "boolean"], "cmd": ["type": "boolean"]],
        ]
    }

    private static func obj(_ props: JSON, _ required: [String] = []) -> JSON {
        var o: JSON = ["type": "object", "properties": props, "additionalProperties": false]
        if !required.isEmpty { o.set("required", .array(required.map { .string($0) })) }
        return o
    }

    private static func tool(_ name: String, _ title: String, _ desc: String, _ schema: JSON, _ readOnly: Bool) -> JSON {
        [
            "name": .string(name), "title": .string(title), "description": .string(desc), "inputSchema": schema,
            "annotations": ["title": .string(title), "readOnlyHint": .bool(readOnly), "openWorldHint": false],
        ]
    }

    private static let appOnly = " Desktop app only (`deckcraft-cli mcp --connect PORT`)."

    /// Every tool, in deckcraft's order.
    public static let definitions: [JSON] = [
        tool(
            "list_commands", "List commands",
            "Every command (id, label, ribbon/menu place, shortcut, parameter summary, whether it is enabled now). Filter by a substring of id or label.",
            obj(["filter": string("Substring of the id or label, e.g. `format.` or `slide`")]),
            true
        ),
        tool(
            "run_command", "Run a command",
            "Run any command by id with JSON parameters. This is how everything is done: slide.new, shape.insert, text.set, format.bold, shape.fill, design.theme, transition.set, animation.add, table.merge, edit.undo…",
            obj(["command": string("Command id from list_commands"), "params": ["type": "object", "description": "Parameters (see the command's params summary)"]], ["command"]),
            false
        ),
        tool(
            "batch", "Run several commands",
            "Run commands in order; stops at the first error unless keepGoing. Returns each result.",
            obj(
                ["commands": ["type": "array", "items": obj(["command": string("id"), "params": ["type": "object"]], ["command"])], "keepGoing": boolean("Continue after errors")],
                ["commands"]
            ),
            false
        ),
        tool(
            "new_presentation", "New presentation",
            "Start a new presentation (one title slide). Optional theme: DeckCraft, Harbor, Ember, Meadow, Nocturne, Paper, Coral Reef, Slate.",
            obj(["theme": string("Theme name"), "blank": boolean("No first slide")]),
            false
        ),
        tool("open_presentation", "Open presentation", "Open a .deckcraft or .pptx file by path.", obj(["path": string("File path")], ["path"]), false),
        tool(
            "save_presentation", "Save presentation", "Save the active presentation (.deckcraft or .pptx by extension).",
            obj(["path": string("File path (optional when it was opened from a file)")]), false
        ),
        tool(
            "export", "Export",
            "Export slides: png/jpeg (one slide, or all with all:true), pptx, deckcraft, outline text, pdf (slides, notes pages or handouts), or an animated gif of the deck (one frame per slide).",
            obj(
                [
                    "path": string("Output path"),
                    "format": ["type": "string", "enum": ["png", "jpeg", "pptx", "deckcraft", "outline", "rtf", "pdf", "gif"], "description": "Output format (default: from the path's extension)"],
                    "slide": int("Slide index for images"),
                    "all": boolean("All slides (images)"),
                    "scale": num("Pixels per point for images (default 2)"),
                    "layout": ["type": "string", "enum": ["slides", "notes", "handouts"], "description": "PDF page layout (default slides)"],
                    "perPage": ["type": "integer", "enum": [1, 2, 3, 4, 6, 9], "description": "PDF handouts: slides per page (default 6)"],
                    "dpi": num("PDF: raster resolution of slide artwork, 36-600 (default 200)"),
                    "slides": ["type": "array", "items": ["type": "integer", "minimum": 0], "description": "PDF and GIF: slide indices to export, in order (default all)"],
                    "includeHidden": boolean("PDF and GIF: include hidden slides (default false)"),
                    "textLayer": boolean("PDF: invisible text layer for search, select and copy (default true)"),
                    "frame": boolean("PDF notes/handouts: thin frame around each slide (default true)"),
                    "paper": ["type": "string", "enum": ["letter", "a4", "legal", "a3"], "description": "PDF notes/handouts: paper size (default letter)"],
                    "orientation": ["type": "string", "enum": ["portrait", "landscape"], "description": "PDF notes/handouts: page orientation (default portrait)"],
                    "width": [
                        "oneOf": [
                            ["type": "integer", "minimum": 16, "maximum": 3840],
                            ["type": "string", "enum": ["small", "medium", "large", "extraLarge"]],
                        ],
                        "description": "GIF: frame width in pixels, or a size: small 640, medium 960 (default), large 1280, extraLarge 1920; the height follows the slide's shape",
                    ],
                    "secondsPerSlide": ["type": "number", "minimum": 0.1, "maximum": 600, "description": "GIF: seconds each slide shows (default 5)"],
                    "loop": boolean("GIF: loop forever (true, default) or play once (false)"),
                ],
                ["path"]
            ),
            false
        ),
        tool(
            "inspect_document", "Inspect presentation",
            "Slides (index, id, title, layout, shape count, transition, animations, notes), sections, theme, layouts, media and the selection.",
            obj([:]), true
        ),
        tool(
            "inspect_slide", "Inspect slide",
            "One slide's shapes with ids, kinds, boxes [x,y,w,h], placeholder types, text, fills, tables, charts; plus background, transition, animations, notes.",
            obj(["index": int("Slide index (default: current)")]), true
        ),
        tool(
            "render_slide", "Render slide", "Render a slide to a PNG image and return it, to check your work visually.",
            obj(["slide": int("Slide index (default: current)"), "scale": num("Pixels per point (default 1 = 960×540 for 16:9)"), "edit": boolean("Show placeholder prompts like the editor")]),
            true
        ),
        tool(
            "add_slide", "Add slide",
            "Insert a slide after the current one with a layout (title, titleAndContent, sectionHeader, twoContent, comparison, titleOnly, blank, contentWithCaption, pictureWithCaption) and optional title/body text (body: one paragraph per line, leading tabs indent).",
            obj(["layout": string("Layout name or kind"), "title": string("Title text"), "body": string("Body text")]), false
        ),
        tool("go_to_slide", "Go to slide", "Make a slide current (shape commands act on the current slide).", obj(["index": int("Slide index")], ["index"]), false),
        tool(
            "add_shape", "Add shape",
            "Insert a preset shape (rect, roundRect, ellipse, triangle, diamond, rightArrow, chevron, star5, heart, cloud, wedgeRectCallout, line, straightConnector1… see shape.presets) at x,y with size w×h, with optional text and fill colour (#RRGGBB or accent1..6).",
            obj(
                ["preset": string("Preset name"), "x": num("Left (pt)"), "y": num("Top (pt)"), "w": num("Width (pt)"), "h": num("Height (pt)"), "text": string("Text inside"), "fill": string("Fill colour"), "line": string("Outline colour or `none`")],
                ["preset", "x", "y", "w", "h"]
            ),
            false
        ),
        tool(
            "add_text_box", "Add text box", "Insert a text box. Height grows to fit the text.",
            obj(
                ["x": num("Left (pt)"), "y": num("Top (pt)"), "w": num("Width (pt)"), "h": num("Height (pt)"), "text": string("Text (one paragraph per line)"), "size": num("Font size (pt)"), "color": string("Text colour"), "align": string("left|center|right|justify")],
                ["x", "y", "w", "text"]
            ),
            false
        ),
        tool(
            "set_text", "Set text", "Replace a shape's text (keeps its first run's formatting). Leading tabs set bullet levels.",
            obj(["id": int("Shape id (from inspect_slide)"), "text": string("New text")], ["id", "text"]), false
        ),
        tool(
            "insert_picture", "Insert picture", "Insert a picture from a file path or base64 data, optionally at a box.",
            obj(["path": string("Image file path"), "data": string("Base64 image data (instead of path)"), "name": string("File name for data"), "x": num("Left"), "y": num("Top"), "w": num("Width"), "h": num("Height")]),
            false
        ),
        tool(
            "insert_table", "Insert table", "Insert a table with rows×cols and optional cell text (data: rows of strings).",
            obj(
                ["rows": int("Rows"), "cols": int("Columns"), "data": ["type": "array", "items": ["type": "array", "items": ["type": "string"]]], "x": num("Left"), "y": num("Top"), "w": num("Width"), "h": num("Height")],
                ["rows", "cols"]
            ),
            false
        ),
        tool(
            "insert_chart", "Insert chart", "Insert a chart (column, bar, line, pie, doughnut, area, scatter, stackedColumn…) with categories and series.",
            obj([
                "type": string("Chart type"), "title": string("Chart title"), "categories": ["type": "array", "items": ["type": "string"]],
                "series": ["type": "array", "items": obj(["name": string("Series name"), "values": ["type": "array", "items": ["type": "number"]]], ["values"])],
            ]),
            false
        ),
        tool("select", "Select shapes", "Select shapes by id (formatting commands then act on them).", obj(["ids": ["type": "array", "items": ["type": "integer"]]], ["ids"]), false),
        tool(
            "pointer", "Pointer gesture",
            "Drive the active tool with pointer events in slide points: down/drag/up/move/doubleclick/contextclick, exactly like the mouse (draws, moves, resizes, rotates, places the caret; contextclick selects like a right click).",
            obj(
                [
                    "events": ["type": "array", "items": obj(["kind": string("down|drag|up|move|doubleclick|tripleclick|contextclick"), "x": num("x (pt)"), "y": num("y (pt)"), "mods": modsSchema()], ["kind", "x", "y"])],
                    "mods": modsSchema(),
                ],
                ["events"]
            ),
            false
        ),
        tool(
            "select_tool", "Select tool", "Pick the pointer tool: select, textBox, shape (with preset), pen, highlighter, eraser — or a preset name.",
            obj(["tool": string("Tool name"), "preset": string("Shape preset for the shape tool")], ["tool"]), false
        ),
        tool(
            "key", "Press key", "Press a key as on the keyboard: text editing keys (arrows, Backspace, Enter, Tab), nudges, and shortcuts (cmd+B…).",
            obj(["key": string("Key name or character"), "mods": modsSchema()], ["key"]), false
        ),
        tool("type_text", "Type text", "Type text into the text being edited (or into the selected shape).", obj(["text": string("Text")], ["text"]), false),
        tool("screenshot", "Screenshot", "Screenshot of the whole DeckCraft window (UI included).\(appOnly)", obj([:]), true),
        tool(
            "call_app", "Call app method", "Call any control-channel method (ui.click, ui.set, ui.dialog.*, ui.inspect…).\(appOnly)",
            obj(["method": string("Method"), "params": ["type": "object"]], ["method"]), false
        ),
    ]

    private static func exec(_ b: Backend, _ cmd: String, _ params: JSON) throws(AutomationError) -> JSON {
        try b.call("engine.execute", ["command": .string(cmd), "params": params])
    }

    /// `a.get(k).and_then(Value::as_f64)` as the JSON `json!` makes of it.
    private static func f(_ a: JSON, _ k: String) -> Double? { a.get(k)?.asF64 }
    private static func fj(_ v: Double?) -> JSON { v.map { JSON.num($0) } ?? .null }

    private static func wrap(_ body: () throws(AutomationError) -> JSON) -> ToolResult {
        do { return .json(try body()) } catch { return .error(error.message) }
    }

    /// Keys other than the tool's schema properties are refused, so a misspelled argument does not succeed
    /// with the tool's defaults. Keys inside a free object such as `run_command`'s `params` belong to the
    /// command and are left for the command to read.
    static func unknownArgumentError(_ name: String, _ args: JSON) -> String? {
        guard let def = definitions.first(where: { $0.get("name")?.asStr == name }) else { return nil }
        let allowed = (def.get("inputSchema")?.get("properties")?.asObject?.keys ?? []).sorted(by: byteOrder)
        guard let o = args.asObject else { return nil }
        // serde_json's map has each key once.
        let keys = JSON.object(o).canonical.asObject?.keys ?? []
        let unknown = keys.filter { k in !allowed.contains { rustEqual($0, k) } }.sorted(by: byteOrder)
        guard let first = unknown.first else { return nil }
        let expected = allowed.isEmpty ? "none" : allowed.joined(separator: ", ")
        let (what, list) = unknown.count == 1
            ? ("unknown argument", rustDebugString(first))
            : ("unknown arguments", unknown.map(rustDebugString).joined(separator: ", "))
        return "\(name): \(what) \(list) (expected: \(expected))"
    }

    /// Run tool `name` with arguments `a` on `b`.
    public static func call(_ b: Backend, _ name: String, _ args: JSON) -> ToolResult {
        let a = args.isObject ? args.canonical : .emptyObject
        if let msg = unknownArgumentError(name, a) { return .error(msg) }
        switch name {
        case "list_commands":
            return wrap { () throws(AutomationError) -> JSON in
                let v = try b.call("engine.commands", .emptyObject)
                let filter = rustLowercase(a.get("filter")?.asStr ?? "")
                func has(_ c: JSON, _ k: String) -> Bool { c.get(k)?.asStr.map { bytesContain(rustLowercase($0), filter) } ?? false }
                return .array((v.asArray ?? []).filter { c in filter.isEmpty || has(c, "id") || has(c, "label") })
            }
        case "run_command":
            guard let c = a.get("command")?.asStr else { return .error("missing `command`") }
            return wrap { () throws(AutomationError) -> JSON in try exec(b, c, a.get("params") ?? .emptyObject) }
        case "batch":
            let keep = a.get("keepGoing")?.asBool ?? false
            var out: [JSON] = []
            for c in a.get("commands")?.asArray ?? [] {
                let id = c.get("command")?.asStr ?? ""
                do {
                    let v = try exec(b, id, c.get("params") ?? .emptyObject)
                    out.append(["command": .string(id), "ok": true, "result": v])
                } catch {
                    out.append(["command": .string(id), "ok": false, "error": .string(error.message)])
                    if !keep { return ToolResult(content: [["type": "text", "text": .string(JSON.array(out).display)]], isError: true) }
                }
            }
            return .json(.array(out))
        case "new_presentation": return wrap { () throws(AutomationError) -> JSON in try exec(b, "file.new", a) }
        case "open_presentation": return wrap { () throws(AutomationError) -> JSON in try exec(b, "file.open", a) }
        case "save_presentation": return wrap { () throws(AutomationError) -> JSON in try exec(b, "file.save", a) }
        case "export": return wrap { () throws(AutomationError) -> JSON in try exec(b, "file.export", a) }
        case "inspect_document": return wrap { () throws(AutomationError) -> JSON in try b.call("document.inspect", .emptyObject) }
        case "inspect_slide": return wrap { () throws(AutomationError) -> JSON in try exec(b, "slide.inspect", a) }
        case "render_slide":
            do {
                let v = try b.call("ui.render", a)
                if let png = v.get("png")?.asStr {
                    return .image(png, ["width": v.get("width") ?? .null, "height": v.get("height") ?? .null, "slide": v.get("slide") ?? .null])
                }
                return .json(v)
            } catch {
                return .error(error.message)
            }
        case "add_slide": return wrap { () throws(AutomationError) -> JSON in try exec(b, "slide.new", a) }
        case "go_to_slide": return wrap { () throws(AutomationError) -> JSON in try exec(b, "slide.go", a) }
        case "add_shape":
            let v: JSON
            do {
                v = try exec(b, "shape.insert", [
                    "preset": a.get("preset") ?? .null,
                    "rect": [fj(f(a, "x")), fj(f(a, "y")), fj(f(a, "w")), fj(f(a, "h"))],
                    "text": a.get("text") ?? .null,
                ])
            } catch {
                return .error(error.message)
            }
            let id = v.get("id") ?? .null
            if let c = a.get("fill"), c.isString {
                do { _ = try exec(b, "shape.fill", ["id": id, "color": c]) } catch { return .error(error.message) }
            }
            if let c = a.get("line")?.asStr {
                let p: JSON = c == "none" ? ["id": id, "none": true] : ["id": id, "color": .string(c)]
                do { _ = try exec(b, "shape.line", p) } catch { return .error(error.message) }
            }
            return .json(v)
        case "add_text_box":
            let v: JSON
            do {
                v = try exec(b, "insert.textBox", [
                    "rect": [fj(f(a, "x")), fj(f(a, "y")), fj(f(a, "w")), .num(f(a, "h") ?? 30)],
                    "text": a.get("text") ?? .null,
                ])
            } catch {
                return .error(error.message)
            }
            let id = v.get("id") ?? .null
            _ = try? exec(b, "text.exit", .emptyObject)
            _ = try? exec(b, "edit.select", ["ids": [id]])
            if let s = f(a, "size") { _ = try? exec(b, "format.size", ["size": .num(s)]) }
            if let c = a.get("color"), c.isString { _ = try? exec(b, "format.color", ["color": c]) }
            if let al = a.get("align")?.asStr { _ = try? exec(b, "format.align", ["align": .string(al)]) }
            return .json(v)
        case "set_text": return wrap { () throws(AutomationError) -> JSON in try exec(b, "text.set", a) }
        case "insert_picture", "insert_table":
            var p = a
            if let x = f(a, "x"), let y = f(a, "y"), let w = f(a, "w"), let h = f(a, "h") {
                p.set("rect", [.num(x), .num(y), .num(w), .num(h)])
            }
            let cmd = name == "insert_picture" ? "insert.picture" : "insert.table"
            return wrap { () throws(AutomationError) -> JSON in try exec(b, cmd, p.canonical) }
        case "insert_chart": return wrap { () throws(AutomationError) -> JSON in try exec(b, "insert.chart", a) }
        case "select": return wrap { () throws(AutomationError) -> JSON in try exec(b, "edit.select", a) }
        case "pointer": return wrap { () throws(AutomationError) -> JSON in try b.call("ui.pointer", a) }
        case "select_tool": return wrap { () throws(AutomationError) -> JSON in try b.call("ui.tool.select", a) }
        case "key":
            var p = a.get("mods").flatMap { $0.isObject ? $0 : nil } ?? .emptyObject
            p.set("key", a.get("key") ?? .null)
            let params = p.canonical
            return wrap { () throws(AutomationError) -> JSON in try b.call("ui.key", params) }
        case "type_text": return wrap { () throws(AutomationError) -> JSON in try b.call("ui.text", a) }
        case "screenshot":
            if !b.hasUI { return .error("screenshot: \(needsApp). Use render_slide to see a slide headlessly.") }
            do {
                let v = try b.call("ui.screenshot", ["base64": true])
                if let png = v.get("png")?.asStr { return .image(png, ["width": v.get("width") ?? .null, "height": v.get("height") ?? .null]) }
                return .json(v)
            } catch {
                return .error(error.message)
            }
        case "call_app":
            guard let m = a.get("method")?.asStr else { return .error("missing `method`") }
            return wrap { () throws(AutomationError) -> JSON in try b.call(m, a.get("params") ?? .emptyObject) }
        default:
            return .error("unknown tool `\(name)`")
        }
    }
}

/// Rust's byte-wise string order (`sort_unstable` on `&str`).
func byteOrder(_ a: String, _ b: String) -> Bool { Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8)) }

/// `haystack.contains(needle)` on bytes, as Rust's `str::contains` matches.
func bytesContain(_ haystack: String, _ needle: String) -> Bool {
    let h = Array(haystack.utf8), n = Array(needle.utf8)
    if n.isEmpty { return true }
    if n.count > h.count { return false }
    for i in 0 ... (h.count - n.count) where h[i] == n[0] && Array(h[i ..< i + n.count]) == n { return true }
    return false
}

/// Rust's `{:?}` of a string: quoted, with `"`, `\` and control characters escaped as Rust escapes them.
func rustDebugString(_ s: String) -> String {
    var out = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\0": out += "\\0"
        default:
            if c.properties.generalCategory == .control {
                out += "\\u{\(String(c.value, radix: 16))}"
            } else {
                out.unicodeScalars.append(c)
            }
        }
    }
    return out + "\""
}
