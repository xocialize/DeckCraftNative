// DCApp — Review: deckcraft's Comments task pane (`comments`, `comment_card` in `panes.rs`) with the Review
// ribbon tab's comment navigation (`comment_nav`, `review` in `ribbon.rs`), the Thesaurus pane
// (`thesaurus`), and Compare's Revisions pane (`revisions`). MIT OR Apache-2.0, © ArtCraft Team and the
// DeckCraft contributors.
import AppKit
import DCAppModel
import DCCore
import DCEngine
import DCGeometry
import DCModel
import DesignScaffold
import SwiftUI

struct ReviewView: View {
    let ctl: InspectorController

    var body: some View {
        let pane = ctl.model.ui.pane
        let part = pane == "thesaurus" || pane == "revisions" ? pane ?? "comments" : "comments"
        Section {
            Picker(String(localized: "Show", bundle: .module, comment: "Which part of the Review inspector to show"), selection: Binding(get: { part }, set: { ctl.run("view.pane", ["pane": .string($0)]) })) {
                Text("Comments", bundle: .module).tag("comments")
                Text("Thesaurus", bundle: .module).tag("thesaurus")
                Text("Revisions", bundle: .module).tag("revisions")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        switch part {
        case "thesaurus": ThesaurusView(ctl: ctl)
        case "revisions": RevisionsView(ctl: ctl)
        default: CommentsView(ctl: ctl)
        }
        Section(String(localized: "Proofing", bundle: .module)) {
            Button(String(localized: "Spelling…", bundle: .module)) { ctl.run("app.dialog", ["id": "spelling"]) }
            Button(String(localized: "Check Accessibility…", bundle: .module)) { ctl.run("app.dialog", ["id": "accessibility"]) }
            Button(String(localized: "Language…", bundle: .module)) { ctl.run("app.dialog", ["id": "language"]) }
        }
    }
}

struct CommentsView: View {
    let ctl: InspectorController

    var body: some View {
        Section(String(localized: "Comments", bundle: .module)) {
            HStack {
                Button { ctl.run("app.dialog", ["id": "comment"]) } label: { Label(String(localized: "New Comment", bundle: .module), systemImage: "plus.bubble") }
                Spacer()
                Button { ctl.commentNav(forward: false) } label: { Image(systemName: "chevron.up") }
                    .help(String(localized: "Previous Comment", bundle: .module)).accessibilityLabel(String(localized: "Previous", bundle: .module)).disabled(!ctl.enabled("comment.prev"))
                Button { ctl.commentNav(forward: true) } label: { Image(systemName: "chevron.down") }
                    .help(String(localized: "Next Comment", bundle: .module)).accessibilityLabel(String(localized: "Next", bundle: .module)).disabled(!ctl.enabled("comment.next"))
            }
            let threads = ctl.commentThreads()
            if threads.isEmpty { InspectorNote(text: String(localized: "No comments.", bundle: .module)) }
            ScrollViewReader { proxy in
                ForEach(threads, id: \.slide) { t in
                    SectionHeader(String(localized: "Slide \(t.slide + 1)", bundle: .module))
                    ForEach(Array(t.comments.enumerated()), id: \.offset) { i, c in
                        CommentCard(ctl: ctl, slide: t.slide, index: i, comment: c, focused: ctl.commentFocus.map { $0.slide == t.slide && $0.index == i } ?? false)
                            .id("\(t.slide):\(i)")
                    }
                }
                .onChange(of: ctl.commentFocus.map { "\($0.slide):\($0.index)" }) { _, key in
                    if let key { withAnimation { proxy.scrollTo(key, anchor: .center) } }
                }
            }
        }
    }
}

/// One comment: initials, author, date (and Resolved), text, replies, a reply field, Resolve/Reopen, Delete.
struct CommentCard: View {
    let ctl: InspectorController
    let slide: Int
    let index: Int
    let comment: Comment
    let focused: Bool
    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            HStack(spacing: Tokens.Space.s) {
                Text(comment.initials)
                    .font(Tokens.Font.caption.weight(.semibold))
                    .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
                    .frame(width: Tokens.Space.xl, height: Tokens.Space.xl)
                    .background(Tokens.Color.accent, in: Circle())
                VStack(alignment: .leading) {
                    Text(comment.author).font(Tokens.Font.sectionTitle)
                    Text(when).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.tertiaryLabel)
                }
            }
            Text(comment.text).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(comment.replies.enumerated()), id: \.offset) { _, r in
                Text(verbatim: "↳ \(r.author): \(r.text)").foregroundStyle(Tokens.Color.secondaryLabel).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                TextField(String(localized: "Reply…", bundle: .module), text: $reply)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        ctl.reply(slide, index, reply)
                        reply = ""
                    }
                Button(comment.resolved ? String(localized: "Reopen", bundle: .module) : String(localized: "Resolve", bundle: .module)) { ctl.resolve(slide, index, !comment.resolved) }
                Button { ctl.deleteComment(slide, index) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: "Delete", bundle: .module))
            }
        }
        .padding(Tokens.Space.s)
        .background(focused ? Tokens.Color.selectionWash : Tokens.Color.fillElevated, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control).strokeBorder(focused ? Tokens.Color.accent : Color.clear, lineWidth: Tokens.Layout.hairline * 2))
        .contentShape(Rectangle())
        .onTapGesture { ctl.focusComment(slide, index) }
    }

    private var when: String {
        var w = comment.date.replacingOccurrences(of: "T", with: " ")
        while w.hasSuffix("Z") { w.removeLast() }
        return comment.resolved ? String(localized: "\(w) · Resolved", bundle: .module, comment: "A comment's date, then that it is resolved") : w
    }
}

struct ThesaurusView: View {
    let ctl: InspectorController

    var body: some View {
        Section(String(localized: "Thesaurus", bundle: .module)) {
            TextField(String(localized: "Search for a word", bundle: .module), text: Binding(get: { ctl.model.thesaurusQuery }, set: { ctl.model.thesaurusQuery = $0 }))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            let q = ctl.model.thesaurusQuery
            if rustTrim(q).isEmpty {
                InspectorNote(text: String(localized: "Select a word on the slide, or type one above.", bundle: .module))
            } else if ctl.thesaurusSenses.isEmpty {
                InspectorNote(text: String(localized: "No synonyms for \"\(rustTrim(q))\".", bundle: .module))
            } else {
                ForEach(Array(ctl.thesaurusSenses.enumerated()), id: \.offset) { _, sense in
                    Text(sense.word).font(Tokens.Font.sectionTitle)
                    ForEach(sense.synonyms, id: \.self) { syn in
                        Button(syn) { ctl.pickSynonym(syn) }
                            .buttonStyle(.link)
                            .help(ctl.editingText ? String(localized: "Insert", bundle: .module, comment: "Thesaurus: insert the synonym") : String(localized: "Look up", bundle: .module))
                    }
                }
            }
        }
    }
}

struct RevisionsView: View {
    let ctl: InspectorController

    var body: some View {
        Section(String(localized: "Revisions", bundle: .module)) {
            if case .success(let v) = Result(catching: { try ctl.session.execute("review.revisions", .emptyObject) }) {
                let changes = v["changes"]?.asArray ?? []
                InspectorNote(text: String(localized: "Compared with \(v["name"]?.asStr ?? "?")", bundle: .module))
                if v["byPosition"]?.asBool == true { InspectorNote(text: String(localized: "Not a copy of this presentation: slides are matched by position.", bundle: .module)) }
                if changes.isEmpty {
                    InspectorNote(text: String(localized: "No differences left.", bundle: .module))
                    Button(String(localized: "End Review", bundle: .module)) {
                        ctl.run("review.endCompare")
                        ctl.model.ui.pane = nil
                    }
                } else {
                    HStack {
                        Button(String(localized: "Accept All (\(changes.count))", bundle: .module)) { ctl.run("review.accept", ["all": true]) }
                        Button(String(localized: "Reject All (\(changes.count))", bundle: .module)) { ctl.run("review.reject", ["all": true]) }
                        Button(String(localized: "End Review", bundle: .module)) { ctl.run("review.endCompare") }
                    }
                    ForEach(Array(changes.enumerated()), id: \.offset) { i, c in change(i, c) }
                }
            } else {
                InspectorNote(text: String(localized: "Compare this presentation with a revised copy from Review ▸ Compare.", bundle: .module))
                Button(String(localized: "Compare…", bundle: .module)) { ctl.run("app.compareDialog") }
            }
        }
    }

    private func change(_ i: Int, _ c: JSON) -> some View {
        let slide = c["slide"]?.asU64 ?? 0
        let (head, color): (String, Color) = switch c["kind"]?.asStr ?? "" {
        case "inserted": (String(localized: "Slide inserted after \(slide)", bundle: .module), Tokens.Color.ready)
        case "deleted": (String(localized: "Slide \(slide &+ 1) deleted", bundle: .module), Tokens.Color.failure)
        default: (String(localized: "Slide \(slide &+ 1) changed", bundle: .module), Tokens.Color.accent)
        }
        return VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            HStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.control / 3).fill(color).frame(width: Tokens.Space.xs, height: Tokens.Space.l)
                Button(head) {
                    let max = Swift.max((ctl.doc?.doc.slides.count ?? 1) - 1, 0)
                    ctl.run("slide.go", ["index": .integer(Swift.min(Int(clamping: slide), max))])
                }
                .buttonStyle(.link)
                Spacer()
                Button(String(localized: "Accept", bundle: .module)) { ctl.run("review.accept", ["index": .integer(i)]) }
                Button(String(localized: "Reject", bundle: .module)) { ctl.run("review.reject", ["index": .integer(i)]) }
            }
            ForEach(Array((c["details"]?.asArray ?? []).compactMap(\.asStr).prefix(8).enumerated()), id: \.offset) { _, d in
                Text(verbatim: "• \(d)").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
            }
        }
    }
}
