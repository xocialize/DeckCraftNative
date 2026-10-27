// DeckCraftNative's Quick Look thumbnail extension (com.apple.quicklook.thumbnail): the first slide of a
// .deckcraft, .pptx, .potx or .ppsx file at the size asked (or the picture the package carries of it, for a file too
// large to read whole). The work is DCQuickLook's, run on a large-stack thread (DCExtensionKit.LargeStack); the
// drawing block only draws the finished picture.
import DCExtensionKit
import DCQuickLook
import Foundation
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let (url, size, scale) = (request.fileURL, request.maximumSize, request.scale)
        let reply = Reply(handler)
        LargeStack.async({ QuickLookThumbnail.make(fileAt: url, maximumSize: size, scale: scale) }, then: { thumbnail in
            guard let thumbnail else {
                reply.handler(nil, QLThumbnailError(.generationFailed))
                return
            }
            reply.handler(QLThumbnailReply(contextSize: thumbnail.contextSize) { ctx in thumbnail.draw(in: ctx) }, nil)
        })
    }

    /// Quick Look's completion handler, called once from the thread that made the thumbnail.
    private struct Reply: @unchecked Sendable {
        let handler: (QLThumbnailReply?, Error?) -> Void
        init(_ handler: @escaping (QLThumbnailReply?, Error?) -> Void) { self.handler = handler }
    }
}
