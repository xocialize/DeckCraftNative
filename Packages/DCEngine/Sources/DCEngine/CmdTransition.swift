// DCEngine — the `transition` command module: the Transitions tab.
// Port of deckcraft crates/engine/src/cmd/transition.rs (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft
// contributors).
import DCCore
import DCMedia
import DCModel

public enum TransitionCommands {
    public static func specs() -> [CommandSpec] {
        [
            .cmd(
                "transition.set",
                "Transition",
                ["Transitions", "Transition to This Slide"],
                nil,
                "{kind: none|morph|fade|push|wipe|split|reveal|cut|randomBar|shape|uncover|cover|flash|… (transition.list), option?, duration?: ms, index?}",
                Cmd.hasSlide,
                set
            ),
            .cmd("transition.options", "Effect Options", ["Transitions", "Transition to This Slide"], nil, "{option, index?}", Cmd.hasSlide, options),
            .cmd(
                "transition.timing",
                "Timing",
                ["Transitions", "Timing"],
                nil,
                "{duration?: ms, onClick?: bool, after?: ms | null, index?}",
                Cmd.hasSlide,
                timing
            ),
            .cmd(
                "transition.sound",
                "Sound",
                ["Transitions", "Timing"],
                nil,
                "{builtin?: chime|click|camera|whoosh|drumRoll|laser | path? | data: base64, name?, none?: true (No Sound), stopPrevious?: true, loop?: bool (Loop Until Next Sound), index?} — the sound plays as the slide comes in",
                Cmd.hasSlide,
                sound
            ),
            .cmd("transition.applyAll", "Apply To All", ["Transitions", "Timing"], nil, "{}", Cmd.hasSlide, applyAll),
            .query("transition.list", "Transition Gallery", [], nil, "{} → [{id, label, category, duration, options}]", Cmd.always, list),
        ]
    }

    static func slideIndices(_ s: Session, _ p: JSON) throws -> [Int] {
        let st = try s.doc()
        if let i = Cmd.usizeParam(p, "index") { return [i] }
        let v = st.selection.slides.compactMap { st.doc.slideIndex($0) }
        return v.isEmpty ? [st.selection.slide] : v
    }

    @Sendable static func set(_ s: Session, _ p: JSON) throws -> JSON {
        guard let kind = Cmd.strParam(p, "kind") else { throw Cmd.bad("transition.set", "missing `kind`") }
        guard let info = DCModel.transitions.first(where: { EngineFonts.eqIgnoreASCIICase($0.id, kind) }) else {
            throw Cmd.bad("transition.set", "unknown transition `\(kind)`")
        }
        let option = Cmd.strParam(p, "option") ?? info.options.first ?? ""
        let duration = p.get("duration")?.asU64.map { UInt32(min($0, 59_000)) }
        let list = try slideIndices(s, p)
        try s.edit { doc, _ in
            for i in list where doc.slides.indices.contains(i) {
                var t = doc.slides[i].transition ?? .default
                t.kind = info.id
                t.option = option
                t.durationMs = duration ?? info.defaultDurationMs
                t.raw = nil
                let plain = info.id == "none" && t.advanceAfterMs == nil && t.advanceOnClick && t.sound == nil && !t.stopSound
                doc.slides[i].transition = plain ? nil : t
            }
        }
        return ["kind": .string(info.id)]
    }

    @Sendable static func options(_ s: Session, _ p: JSON) throws -> JSON {
        guard let option = Cmd.strParam(p, "option") else { throw Cmd.bad("transition.options", "missing `option`") }
        let list = try slideIndices(s, p)
        try s.edit { doc, _ in
            for i in list where doc.slides.indices.contains(i) && doc.slides[i].transition != nil {
                doc.slides[i].transition?.option = option
            }
        }
        return Cmd.ok()
    }

    @Sendable static func timing(_ s: Session, _ p: JSON) throws -> JSON {
        let list = try slideIndices(s, p)
        try s.edit { doc, _ in
            for i in list where doc.slides.indices.contains(i) {
                var t = doc.slides[i].transition ?? .default
                if let d = p.get("duration")?.asU64 { t.durationMs = UInt32(min(d, 59_000)) }
                if let c = Cmd.boolParam(p, "onClick") { t.advanceOnClick = c }
                switch p.get("after") {
                case .some(.null): t.advanceAfterMs = nil
                case .some(let v):
                    if let x = v.asU64 { t.advanceAfterMs = UInt32(min(x, 86_400_000)) }
                case .none: break
                }
                doc.slides[i].transition = t
            }
        }
        return Cmd.ok()
    }

    /// Transitions › Sound: embed an audio file as the slides' transition sound, or `none` to remove it.
    @Sendable static func sound(_ s: Session, _ p: JSON) throws -> JSON {
        let list = try slideIndices(s, p)
        let looping = Cmd.boolParam(p, "loop")
        func editAll(_ f: (inout Transition) -> Void) throws {
            try s.edit { doc, _ in
                for i in list where doc.slides.indices.contains(i) {
                    var t = doc.slides[i].transition ?? .default
                    f(&t)
                    doc.slides[i].transition = t
                }
            }
        }
        if Cmd.boolParam(p, "none") == true {
            try editAll { t in
                t.sound = nil
                t.stopSound = false
                t.soundLoop = false
            }
            return ["sound": .null]
        }
        if Cmd.boolParam(p, "stopPrevious") == true {
            try editAll { t in
                t.sound = nil
                t.soundLoop = false
                t.stopSound = true
            }
            return ["sound": .null, "stopPrevious": true]
        }
        let wantsFile = p.get("path") != nil || p.get("data") != nil || p.get("builtin") != nil
        if !wantsFile {
            // Only Loop Until Next Sound changes.
            guard let l = looping else {
                throw Cmd.bad("transition.sound", "give `path`, `data`, `builtin`, `none`, `stopPrevious` or `loop`")
            }
            try editAll { t in t.soundLoop = l && t.sound != nil }
            return ["loop": .bool(l)]
        }
        let name: String
        let bytes: [UInt8]
        if let id = Cmd.strParam(p, "builtin") {
            guard let (bid, label) = Sounds.builtin.first(where: { EngineFonts.eqIgnoreASCIICase($0.0, id) }) else {
                let ids = Sounds.builtin.map(\.0)
                throw Cmd.bad("transition.sound", "unknown built-in sound `\(id)` (one of \(ids.joined(separator: ", ")))")
            }
            guard let b = Sounds.builtin(bid) else { throw Cmd.bad("transition.sound", "built-in sound failed") }
            (name, bytes) = ("\(label).wav", b)
        } else {
            (name, bytes) = try InsertCommands.mediaBytes(p, "transition.sound")
        }
        let ct = InsertCommands.contentType(name, bytes)
        let audible = (try? Media.probe(bytes))?.audio != nil
        if !audible && !ct.hasPrefix("audio/") {
            throw Cmd.bad("transition.sound", "\(name) is not a sound file (\(ct))")
        }
        let lp = looping ?? false
        let media: MediaId = try s.edit { doc, _ in
            // The same built-in sound is embedded once.
            let existing = doc.media.first { Array($0.name.utf8) == Array(name.utf8) && $0.data == bytes }?.id
            let m: MediaId
            if let e = existing {
                m = e
            } else {
                guard let added = doc.addMedia(name, ct, bytes) else { throw Cmd.bad("transition.sound", Cmd.noIdSpace) }
                m = added
            }
            for i in list where doc.slides.indices.contains(i) {
                var t = doc.slides[i].transition ?? .default
                t.sound = m
                t.stopSound = false
                t.soundLoop = lp
                doc.slides[i].transition = t
            }
            return m
        }
        return ["sound": .string(name), "media": .integer(media.rawValue), "playable": .bool(audible), "loop": .bool(lp)]
    }

    @Sendable static func applyAll(_ s: Session, _ p: JSON) throws -> JSON {
        try s.edit { doc, sel in
            let t = doc.slides.at(sel.slide)?.transition
            for i in doc.slides.indices { doc.slides[i].transition = t }
        }
        return Cmd.ok()
    }

    @Sendable static func list(_ s: Session, _ p: JSON) throws -> JSON {
        .array(DCModel.transitions.map { t in
            [
                "id": .string(t.id), "label": .string(t.label), "category": .string(t.category),
                "duration": .integer(t.defaultDurationMs), "options": .array(t.options.map { .string($0) }),
            ]
        })
    }
}
