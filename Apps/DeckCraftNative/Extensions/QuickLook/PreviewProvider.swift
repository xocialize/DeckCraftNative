// DeckCraftNative's Quick Look preview extension (com.apple.quicklook.preview, data-based): every slide of a
// .deckcraft, .pptx, .potx or .ppsx file as a vector PDF, titled with the deck's title; a file that can't be read
// gets a page that says why. The work is DCQuickLook's, run on a large-stack thread (DCExtensionKit.LargeStack).
import DCExtensionKit
import DCQuickLook
import Foundation
import QuickLookUI
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let preview = await withCheckedContinuation { (done: CheckedContinuation<DeckPreview, Never>) in
            LargeStack.async({ QuickLookPreview.make(fileAt: url) }, then: { done.resume(returning: $0) })
        }
        let reply: QLPreviewReply
        switch preview.body {
        case .pdf(let data, let pageSize):
            reply = QLPreviewReply(dataOfContentType: .pdf, contentSize: pageSize) { _ in data }
        case .html(let data):
            reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 640, height: 360)) { _ in data }
        }
        reply.title = preview.title
        return reply
    }
}
