// DCAppModel — downloading a release's DMG: URLSession's download task, then the checks craft-update makes before
// it trusts a file (`crates/update/src/http.rs` download, `verify_sha256`; storytold/craft-libs @495e5971,
// MIT OR Apache-2.0, © ArtCraft Team and the Craft contributors): the HTTP status, a size cap, the release's
// size and SHA-256 when GitHub gave them. The file lands in Downloads under its own name (never over an existing
// file) and is quarantined like a browser download, so Gatekeeper checks the app inside before it first runs.
import CryptoKit
import Foundation

public enum UpdateDownloader {
    /// No DeckCraftNative DMG comes near this.
    public static let maxBytes: Int64 = 2 << 30

    /// Where downloads go: the user's Downloads folder.
    public static var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
    }

    /// Start downloading `asset` into `directory`. `completion` runs once, on URLSession's queue, with the saved
    /// file. The task's `progress` reports the bytes; `cancel()` stops it (`.cancelled`).
    @discardableResult
    public static func start(
        _ asset: UpdateAsset, into directory: URL, session: URLSession = .shared,
        completion: @escaping @Sendable (Result<URL, UpdateError>) -> Void
    ) -> URLSessionDownloadTask {
        var request = URLRequest(url: asset.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("DeckCraftNative/\(DCAppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let task = session.downloadTask(with: request) { location, response, error in
            // `location` is deleted when this returns: everything happens here.
            completion(finish(asset, location, response, error, into: directory))
        }
        task.resume()
        return task
    }

    /// Check what arrived and move it into place.
    static func finish(_ asset: UpdateAsset, _ location: URL?, _ response: URLResponse?, _ error: (any Error)?, into directory: URL) -> Result<URL, UpdateError> {
        if let error {
            if (error as? URLError)?.code == .cancelled { return .failure(.cancelled) }
            return .failure(.network(error.localizedDescription))
        }
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) { return .failure(.http(http.statusCode)) }
        guard let location else { return .failure(.network(String(localized: "nothing was received", bundle: .module))) }
        return verify(asset, at: location).flatMap { _ in place(location, named: asset.name, in: directory) }
    }

    /// The size cap, the release's size, and its SHA-256.
    static func verify(_ asset: UpdateAsset, at file: URL) -> Result<Void, UpdateError> {
        let size: Int64
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            return .failure(.file(error.localizedDescription))
        }
        if size > maxBytes { return .failure(.tooLarge) }
        if asset.size > 0, size != asset.size { return .failure(.corrupt) }
        if let expected = asset.sha256 {
            switch sha256(of: file) {
            case .success(let got) where got == expected.lowercased(): break
            case .success: return .failure(.corrupt)
            case .failure(let e): return .failure(e)
            }
        }
        return .success(())
    }

    /// Lowercase hex SHA-256 of `file`, read in chunks.
    public static func sha256(of file: URL) -> Result<String, UpdateError> {
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return .success(hasher.finalize().map { String(format: "%02x", $0) }.joined())
        } catch {
            return .failure(.file(error.localizedDescription))
        }
    }

    /// Move `file` into `directory` as `name` (`name (2).dmg` when taken), quarantined.
    static func place(_ file: URL, named name: String, in directory: URL) -> Result<URL, UpdateError> {
        let fm = FileManager.default
        let safe = UpdateFeed.validFileName(name) ? name : "DeckCraftNative-update.dmg"
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let dest = uniqueURL(for: safe, in: directory)
            try fm.moveItem(at: file, to: dest)
            quarantine(dest)
            return .success(dest)
        } catch {
            return .failure(.file(error.localizedDescription))
        }
    }

    /// `name` in `directory`, or `stem (n).ext` for the first n from 2 that isn't taken.
    static func uniqueURL(for name: String, in directory: URL) -> URL {
        let first = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for n in 2 ... 9_999 {
            let candidate = directory.appending(path: ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appending(path: "\(UUID().uuidString)-\(name)")
    }

    /// Mark `file` as downloaded from the web, as Safari would (LaunchServices' quarantine properties).
    static func quarantine(_ file: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [
            "LSQuarantineAgentName": "DeckCraftNative",
            "LSQuarantineType": "LSQuarantineTypeWebDownload",
        ]
        var url = file
        try? url.setResourceValues(values)
    }
}
