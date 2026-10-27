// DCPPTX — PPTX import and export: Office Open XML PresentationML / DrawingML, written from the public
// ECMA-376 standard. Port of deckcraft crates/pptx/src/lib.rs (MIT OR Apache-2.0, © ArtCraft Team and
// the DeckCraft contributors).
//
// `PPTX.import` reads a package leniently (unknown parts are skipped, malformed parts are logged and
// ignored, every size and depth is bounded) into the DeckCraft model; `PPTX.export` writes a valid
// package that PowerPoint opens without repair. Both live in the `read/` and `write/` ports, as
// extensions of `PPTX`; this file holds the crate root's error type, sniffing and content types.
import DCCore
import DCZip
import Foundation
import os

/// The crate root (`deckcraft_pptx::*`): `sniff`, `isEncrypted`, and the import / export entry points
/// the reader and writer add (`import`, `importChecked`, `importTheme`, `export`, `exportAs`).
public enum PPTX {
    /// Extension URI of the PowerPoint 2010 section list in `presentation.xml`.
    static let sectionExtURI = "{521415D9-36F7-43E2-AB2F-B90AF26B5E84}"

    /// Extension URI of the modern-comments anchor in a slide (names the threaded comment part).
    static let commentsExtURI = "{6950BFC3-D8DA-4A85-94F7-54DA5524770B}"

    /// Does this look like an OOXML package (zip with `[Content_Types].xml`)?
    ///
    /// The part is looked up in the zip's central directory, not in the leading bytes: writers may
    /// store it anywhere in the archive (recent PowerPoint builds put it last, megabytes in).
    public static func sniff(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2, bytes[0] == UInt8(ascii: "P"), bytes[1] == UInt8(ascii: "K") else { return false }
        guard let z = try? ZipReader(bytes) else { return false }
        return z.entries.contains { $0.name.utf8.elementsEqual("[Content_Types].xml".utf8) }
    }

    /// Is this a password-protected presentation (an encrypted package inside a compound file)?
    public static func isEncrypted(_ bytes: [UInt8]) -> Bool {
        CFB.isEncrypted(bytes)
    }

    /// The stack `import` and `export` run on. The reader and writer recurse once per nesting level of a
    /// part (`resolveMCRels` to `XML.maxDepth`, groups in groups to 33 levels), as deckcraft does on Rust's
    /// 2 MiB-and-up thread stacks. A Swift group level takes about 46 KiB of stack in a debug build, and
    /// a Swift concurrency thread has 512 KiB, so a file with groups 11 deep overflowed it.
    static let stackSize = 32 << 20

    /// Runs `body` on a thread with a `stackSize` stack and waits for its result.
    static func onLargeStack<T: Sendable>(_ body: @escaping @Sendable () throws(PPTXError) -> T) throws(PPTXError) -> T {
        let box = LargeStackResult<T>()
        let thread = Thread {
            box.result = Result { () throws(PPTXError) -> T in try body() }
            box.done.signal()
        }
        thread.stackSize = stackSize
        thread.start()
        box.done.wait()
        guard let result = box.result else { throw .notPptx("the PPTX thread didn't finish") }
        return try result.get()
    }
}

/// The result `PPTX.onLargeStack` hands back from its thread (written before `done` is signalled, read
/// after it is waited for).
private final class LargeStackResult<T>: @unchecked Sendable {
    var result: Result<T, PPTXError>?
    let done = DispatchSemaphore(value: 0)
}

/// `PptxError`.
public enum PPTXError: Error, Sendable, Equatable, CustomStringConvertible {
    case notPptx(String)
    case unsupported(String)
    case write(String)
    case xml(String)

    /// The `thiserror` messages.
    public var description: String {
        switch self {
        case .notPptx(let s): "not a PPTX file: \(s)"
        case .unsupported(let s): "unsupported: \(s)"
        case .write(let s): "write failed: \(s)"
        case .xml(let s): "malformed XML: \(s)"
        }
    }
}

/// Content type for a file name's extension.
func mimeFor(_ name: String) -> String {
    let ext: String
    if let dot = name.utf8.lastIndex(of: UInt8(ascii: ".")) {
        ext = rustASCIILowercase(String(name[name.utf8.index(after: dot)...]))
    } else {
        ext = ""
    }
    switch ext {
    case "png": return "image/png"
    case "jpg", "jpeg", "jpe": return "image/jpeg"
    case "gif": return "image/gif"
    case "bmp": return "image/bmp"
    case "tif", "tiff": return "image/tiff"
    case "svg": return "image/svg+xml"
    case "emf": return "image/x-emf"
    case "wmf": return "image/x-wmf"
    case "webp": return "image/webp"
    case "mp4", "m4v": return "video/mp4"
    case "mov": return "video/quicktime"
    case "wmv": return "video/x-ms-wmv"
    case "avi": return "video/x-msvideo"
    case "webm": return "video/webm"
    case "mp3": return "audio/mpeg"
    case "wav": return "audio/wav"
    case "m4a": return "audio/mp4"
    case "wma": return "audio/x-ms-wma"
    case "ogg": return "audio/ogg"
    case "flac": return "audio/flac"
    case "glb": return "model/gltf-binary"
    case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    case "fntdata": return "application/x-fontdata"
    default: return "application/octet-stream"
    }
}

/// deckcraft's `log::warn!`: the unified log, subsystem `DeckCraftNative`, category `pptx`.
enum PPTXLog {
    static let logger = Logger(subsystem: "DeckCraftNative", category: "pptx")

    static func warn(_ message: @autoclosure () -> String) {
        let m = message()
        logger.warning("\(m, privacy: .public)")
    }
}
