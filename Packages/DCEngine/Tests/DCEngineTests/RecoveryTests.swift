// DCEngineTests — AutoRecover and the automation roots.
// Ports the tests of deckcraft crates/engine/src/recovery.rs and file_access.rs (MIT OR Apache-2.0,
// © ArtCraft Team and the DeckCraft contributors).
import Darwin
import DCCore
@testable import DCEngine
import DCFormat
import Foundation
import Testing

@Suite("AutoRecover", .serialized)
struct RecoveryTests {
    @Test func recoversUnsavedPresentations() throws {
        let dir = scratchDir("recovery")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = Session()
        s.run("file.new")
        s.run("file.new")
        // Only the edited presentation is written.
        s.run("slide.new", #"{"layout": "blank"}"#)
        #expect(try Recovery.save(s, dir) == 1)
        #expect(Recovery.list(dir).count == 1)
        // "Crash": a new session reopens it, unsaved, with its slides.
        let s2 = Session()
        #expect(try Recovery.open(s2, dir).count == 1)
        #expect(s2.st.isDirty)
        #expect(s2.st.doc.slides.count == 2)
        #expect(s2.st.displayTitle.hasSuffix("(Recovered)"))
        #expect(Recovery.list(dir).count == 1, "the snapshot stays until it is replaced or saved")
        // A second "crash" before any checkpoint: the presentation is recovered again.
        let s3 = Session()
        #expect(try Recovery.open(s3, dir).count == 1)
        #expect(s3.st.doc.slides.count == 2)
        // Opening again in the same session doesn't duplicate it.
        #expect(try Recovery.open(s3, dir).isEmpty)
        // Saving the recovered presentation drops the entry.
        s3.recoveryDir = dir
        s3.run("file.saveAs", JSON.object(JSONObject(["path": .string(dir.appending(path: "saved.deckcraft").path)])).display)
        #expect(Recovery.list(dir).isEmpty)
    }

    @Test func anotherRunningInstanceKeepsItsEntries() throws {
        let dir = scratchDir("recovery-shared")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Another instance (its own owner id and uid, its lock held) has an unsaved presentation.
        let other = Recovery.instanceId() ^ (1 << 40)
        let fd = open(Recovery.lockPath(dir, other).path, O_WRONLY | O_CREAT, 0o666)
        try #require(fd >= 0)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let o = Session()
        o.run("file.new")
        o.run("slide.new", #"{"layout": "blank"}"#)
        let bytes = try DeckFormat.save(o.st.doc)
        let uid = other + 5
        let (d, m) = Recovery.files(dir, uid)
        try Data(bytes).write(to: d)
        try Data((["title": "Theirs", "owner": .integer(other)] as JSON).display.utf8).write(to: m)
        // This instance saving its clean and dirty presentations leaves that entry alone...
        let s = Session()
        s.run("file.new")
        s.run("file.new")
        s.run("slide.new", #"{"layout": "blank"}"#)
        #expect(try Recovery.save(s, dir) == 1)
        #expect(Recovery.list(dir).contains { $0.0 == uid })
        // ...and a recovery open here skips it while its owner runs.
        let s2 = Session()
        try Recovery.open(s2, dir)
        #expect(s2.documents.allSatisfy { $0.uid != uid })
        #expect(FileManager.default.fileExists(atPath: Recovery.lockPath(dir, other).path), "a live owner's lock stays")
        // Once the owner is gone, its entry is recovered and its lock file cleaned up.
        flock(fd, LOCK_UN)
        close(fd)
        let s3 = Session()
        try Recovery.open(s3, dir)
        #expect(s3.documents.contains { $0.uid == uid && $0.displayTitle.hasPrefix("Theirs") })
        #expect(!FileManager.default.fileExists(atPath: Recovery.lockPath(dir, other).path))
    }

    @Test func corruptEntriesAreSkipped() throws {
        let dir = scratchDir("recovery-corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not a presentation".utf8).write(to: dir.appending(path: "7.deckcraft"))
        try Data("[1, 2]".utf8).write(to: dir.appending(path: "7.json"))
        let s = Session()
        #expect(try Recovery.open(s, dir).isEmpty)
        s.recoveryDir = dir
        let v = s.run("file.recovery.list")
        #expect(v.asArray?.count == 1)
        #expect(v.at(0)?.get("uid") == 7)
    }

    /// A FIFO where an entry or its metadata belongs is skipped rather than read (that blocked start-up
    /// forever), and a folder full of entries reopens only `maxReopen` per start.
    @Test func hostileRecoveryFoldersDontStallStartUp() throws {
        let dir = scratchDir("recovery-hostile")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = Session()
        s.run("file.new")
        s.run("slide.new", #"{"layout": "blank"}"#)
        try Recovery.save(s, dir)
        let (good, _) = Recovery.files(dir, s.st.uid)
        for i in 1 ... UInt64(Recovery.maxReopen + 3) {
            try FileManager.default.copyItem(at: good, to: dir.appending(path: "\(100_000 + i).deckcraft"))
        }
        for name in ["5.deckcraft", "6.json"] { mkfifo(dir.appending(path: name).path, 0o644) }
        try FileManager.default.copyItem(at: good, to: dir.appending(path: "6.deckcraft"))
        let s2 = Session()
        #expect(try Recovery.open(s2, dir).count == Recovery.maxReopen)
        // Every entry stays on disk: the opened ones plus the rest that wait for the next start.
        #expect(Recovery.list(dir).count == Recovery.maxReopen + 5, "the rest wait for the next start")
    }

    @Test func theRecoveryCommandsNeedAFolder() throws {
        let s = session()
        #expect(s.fails("file.recovery.save"))
        #expect(s.fails("file.recovery.list"))
        let dir = scratchDir("recovery-commands")
        defer { try? FileManager.default.removeItem(at: dir) }
        s.recoveryDir = dir
        s.run("slide.new")
        #expect(s.run("file.recovery.save") == ["written": 1])
        #expect(s.run("file.recovery.list").asArray?.count == 1)
        let meta = try #require(s.run("file.recovery.list").at(0))
        #expect(meta.get("title") == "Presentation1" && meta.get("path") == .null && meta.get("owner")?.asU64 == Recovery.instanceId())
        s.run("file.recovery.discard")
        #expect(s.run("file.recovery.list") == [])
        // Closing a presentation removes its entry.
        s.run("file.recovery.save")
        s.run("file.close")
        #expect(Recovery.list(dir).isEmpty)
    }
}

/// A fresh folder holding `in` (read root), `out` (write root) and `outside`.
private func folders(_ name: String) throws -> (URL, AutomationRoots) {
    let base = scratchDir("file-access-\(name)")
    for d in ["in/sub", "out", "outside", "in2"] {
        try FileManager.default.createDirectory(at: base.appending(path: d), withIntermediateDirectories: true)
    }
    try Data("x".utf8).write(to: base.appending(path: "in/a.deckcraft"))
    try Data("x".utf8).write(to: base.appending(path: "outside/secret.deckcraft"))
    let roots = try #require(try AutomationRoots.make(read: base.appending(path: "in").path, write: base.appending(path: "out").path))
    return (base, roots)
}

private func ok(_ roots: AutomationRoots, _ path: String, _ access: Access) -> Bool { (try? roots.check(path, access)) != nil }

private func err(_ roots: AutomationRoots, _ path: String, _ access: Access) -> String {
    do {
        try roots.check(path, access)
        return ""
    } catch {
        return error.message
    }
}

@Suite("Automation roots")
struct FileAccessTests {
    @Test func pathsInsideTheRootsPassAndOthersDont() throws {
        let (base, roots) = try folders("inside")
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(ok(roots, base.appending(path: "in/a.deckcraft").path, .read))
        #expect(ok(roots, base.appending(path: "in").path, .read), "the root itself")
        #expect(ok(roots, base.appending(path: "in/sub/new.deckcraft").path, .read), "missing files are checked by their folder")
        #expect(ok(roots, base.appending(path: "out/new/deeper/x.png").path, .write), "and by their nearest folder")
        #expect(err(roots, base.appending(path: "outside/secret.deckcraft").path, .read).hasPrefix("automation path rejected: outside the read root"))
        // Read and write access are separate.
        #expect(err(roots, base.appending(path: "in/a.deckcraft").path, .write).contains("outside the write root"))
        #expect(err(roots, base.appending(path: "out/x.png").path, .read).contains("outside the read root"))
    }

    @Test func aSiblingWithTheSamePrefixIsOutside() throws {
        let (base, roots) = try folders("prefix")
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("x".utf8).write(to: base.appending(path: "in2/b.deckcraft"))
        #expect(!ok(roots, base.appending(path: "in2/b.deckcraft").path, .read), "in2 is not inside in")
        #expect(!ok(roots, base.appending(path: "in").path + "2/c.deckcraft", .read))
    }

    @Test func parentTraversalIsResolvedOrRefused() throws {
        let (base, roots) = try folders("dotdot")
        defer { try? FileManager.default.removeItem(at: base) }
        let inDir = base.appending(path: "in").path
        #expect(err(roots, "\(inDir)/../outside/secret.deckcraft", .read).contains("outside the read root"), "`..` out of the root")
        #expect(ok(roots, "\(base.appending(path: "in/sub").path)/../a.deckcraft", .read), "`..` that stays inside")
        let e = err(roots, "\(base.appending(path: "out").path)/nope/../../outside/x.deckcraft", .write)
        #expect(e.contains("parent traversal below a folder that doesn't exist") || e.contains("outside the write root"), "\(e)")
    }

    @Test func relativePathsResolveAgainstTheWorkingDirectory() throws {
        let (base, roots) = try folders("relative")
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(err(roots, "a.deckcraft", .read).contains("outside the read root"))
        #expect(err(roots, "", .read).contains("path is empty"))
    }

    @Test func aMissingRootIsAnErrorAndNoneIsNoConfinement() throws {
        let (base, _) = try folders("missing")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            _ = try AutomationRoots.make(read: base.appending(path: "nope").path, write: nil)
            Issue.record("a missing root opened")
        } catch { #expect(error.message.hasPrefix("cannot open the automation read root"), "\(error)") }
        do {
            _ = try AutomationRoots.make(read: nil, write: base.appending(path: "in/a.deckcraft").path)
            Issue.record("a file root opened")
        } catch { #expect(error.message.hasPrefix("cannot open the automation write root") && error.message.hasSuffix("not a directory"), "\(error)") }
        do {
            _ = try AutomationRoots.make(read: "", write: nil)
            Issue.record("an empty root opened")
        } catch { #expect(error.message.hasPrefix("cannot open the automation read root ``"), "\(error)") }
        #expect(try AutomationRoots.make(read: nil, write: nil) == nil)
        // One root alone grants only its own access.
        let readOnly = try #require(try AutomationRoots.make(read: base.appending(path: "in").path, write: nil))
        #expect(err(readOnly, base.appending(path: "in/x.deckcraft").path, .write).contains("write authority is absent"))
    }

    @Test func linksAreFollowedBeforeComparing() throws {
        let (base, roots) = try folders("links")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        try fm.createSymbolicLink(at: base.appending(path: "in/leak.deckcraft"), withDestinationURL: base.appending(path: "outside/secret.deckcraft"))
        #expect(err(roots, base.appending(path: "in/leak.deckcraft").path, .read).contains("outside the read root"), "a file link out")
        try fm.createSymbolicLink(at: base.appending(path: "out/away"), withDestinationURL: base.appending(path: "outside"))
        #expect(err(roots, base.appending(path: "out/away/new.png").path, .write).contains("outside the write root"), "a folder link out")
        try fm.createSymbolicLink(at: base.appending(path: "out/dangling.png"), withDestinationURL: base.appending(path: "outside/gone.deckcraft"))
        #expect(err(roots, base.appending(path: "out/dangling.png").path, .write).contains("a link that leads nowhere"))
        // A link to a folder inside the root stays inside.
        try fm.createSymbolicLink(at: base.appending(path: "in/alias"), withDestinationURL: base.appending(path: "in/sub"))
        #expect(ok(roots, base.appending(path: "in/alias/x.deckcraft").path, .read))
        // A root given through a link is the folder it leads to.
        try fm.createSymbolicLink(at: base.appending(path: "in-link"), withDestinationURL: base.appending(path: "in"))
        let linked = try #require(try AutomationRoots.make(read: base.appending(path: "in-link").path, write: nil))
        #expect(ok(linked, base.appending(path: "in/a.deckcraft").path, .read))
    }

    @Test func scopesNestAndStayOnTheirTask() async throws {
        let (base, roots) = try folders("scopes")
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appending(path: "outside/secret.deckcraft").path
        @Sendable func readable() -> Bool { (try? FileAccess.checkRead(outside)) != nil }
        #expect(readable(), "nothing is confined by default")
        FileAccess.confine(roots) {
            #expect(!readable())
            #expect(FileAccess.unconfined { readable() })
            #expect(!readable(), "restored after unconfined")
            let there = Thread.detachNewThreadAndWait { readable() }
            #expect(there, "another thread is not confined by this one's scope")
        }
        #expect(readable(), "restored after confine")
        #expect(FileAccess.confine(nil) { readable() })
        // Commands read and write through the checks.
        let s = session()
        try FileAccess.confine(roots) {
            #expect(s.fails("file.open", JSON.object(JSONObject(["path": .string(outside)])).display))
            #expect(s.fails("file.saveAs", JSON.object(JSONObject(["path": .string(base.appending(path: "in/x.deckcraft").path)])).display))
            _ = try s.execute("file.saveAs", ["path": .string(base.appending(path: "out/x.deckcraft").path)])
            #expect(s.run("file.info").get("bytes") == .null, "File › Info doesn't reveal a file outside the read root")
        }
    }

    @Test func deviceNames() {
        for d in ["CON", "nul", "Com1", "LPT9.txt", "aux.deckcraft", "NUL "] { #expect(FileAccess.isDeviceName(d), "\(d)") }
        for f in ["console", "com10", "COM0", "lpt", "a.deckcraft", "nul-x"] { #expect(!FileAccess.isDeviceName(f), "\(f)") }
    }

    /// Every file a command reads or writes by path goes through `IO` (`readFile`, `writeFile`), which
    /// check the roots. Engine code that reaches for the file system itself would bypass them, so none
    /// may: every source file except `IO.swift`, `FileAccess.swift` and `Recovery.swift` (the recovery
    /// folder is set by the host application, never by a command's path).
    @Test func commandsDoNotTouchTheFileSystemThemselves() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/DCEngine")
        let files = try FileManager.default.contentsOfDirectory(atPath: src.path).filter { $0.hasSuffix(".swift") }
        #expect(files.contains("Engine.swift") && files.contains("CmdFile.swift"), "\(files)")
        var offenders: [String] = []
        for name in files where !["IO.swift", "FileAccess.swift", "Recovery.swift"].contains(name) {
            let text = try String(contentsOf: src.appending(path: name), encoding: .utf8)
            for (n, raw) in text.components(separatedBy: "\n").enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                let touches = ["FileManager", "Data(contentsOf", ".write(to", "fopen(", "Darwin.open(", "FileHandle"].contains { line.contains($0) }
                if touches { offenders.append("\(name):\(n + 1): \(line)") }
            }
        }
        #expect(offenders.isEmpty, "use IO.readFile / IO.writeFile: \(offenders)")
    }
}

/// The answer of `body` run on a new thread.
private final class ThreadAnswer: @unchecked Sendable {
    var value = false
    let done = DispatchSemaphore(value: 0)
}

private extension Thread {
    static func detachNewThreadAndWait(_ body: @escaping @Sendable () -> Bool) -> Bool {
        let box = ThreadAnswer()
        Thread.detachNewThread {
            box.value = body()
            box.done.signal()
        }
        box.done.wait()
        return box.value
    }
}
