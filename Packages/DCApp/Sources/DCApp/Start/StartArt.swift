// DCApp — the start window's pictures: each tile's title slide, rendered by `StartTileArt` off the main thread
// and cached on disk, and each recent file's Quick Look thumbnail (our Quick Look extension serves `.deckcraft`
// and `.pptx`). A picture that isn't ready yet is nil, and the tile shows a placeholder meanwhile. Not a port.
import AppKit
import DCAppModel
import Observation
import QuickLookThumbnailing

@MainActor @Observable
final class StartArt {
    /// The pixel width tiles are rendered at (two pixels a point for a 192-point tile).
    static let tileWidth = 384

    private(set) var tiles: [String: NSImage] = [:]
    private(set) var thumbnails: [String: NSImage] = [:]
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var rendering = false

    /// Tile `id`'s picture, asking for it the first time.
    func tile(_ id: String) -> NSImage? {
        if let img = tiles[id] { return img }
        if asked.insert("tile:\(id)").inserted {
            queue.append(id)
            renderNext()
        }
        return nil
    }

    /// One tile at a time, off the main thread: each render is a scratch session of its own.
    private func renderNext() {
        guard !rendering, !queue.isEmpty else { return }
        rendering = true
        let id = queue.removeFirst()
        let width = Self.tileWidth
        Task.detached(priority: .utility) { [weak self] in
            let png = StartTileArt.png(id, width: width)
            await MainActor.run {
                guard let self else { return }
                if let png, let img = NSImage(data: Data(png)) { self.tiles[id] = img }
                self.rendering = false
                self.renderNext()
            }
        }
    }

    /// The Quick Look thumbnail of a recent file, asking for it the first time.
    func thumbnail(_ path: String) -> NSImage? {
        if let img = thumbnails[path] { return img }
        guard asked.insert("file:\(path)").inserted else { return nil }
        let req = QLThumbnailGenerator.Request(
            fileAt: URL(filePath: path), size: CGSize(width: 64, height: 48), scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let cg = rep?.cgImage else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.thumbnails[path] = NSImage(cgImage: cg, size: .zero) } }
        }
        return nil
    }
}
