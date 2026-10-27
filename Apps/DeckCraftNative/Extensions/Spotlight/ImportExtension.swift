// DeckCraftNative's Spotlight importer: a Core Spotlight import extension (com.apple.spotlight.import,
// `CSImportExtension`, the current mechanism for third-party importers; `.mdimporter` plug-ins are legacy). For a
// .deckcraft, .pptx, .potx or .ppsx file it sets the title, subject, authors, keywords, dates, slide count and size,
// and the text of every slide, table and chart, the notes and the comments. The work is DCSpotlight's, run on a
// large-stack thread (DCExtensionKit.LargeStack); the file is read without its pictures and media.
import CoreSpotlight
import DCExtensionKit
import DCSpotlight
import Foundation

final class ImportExtension: CSImportExtension {
    override func update(_ attributes: CSSearchableItemAttributeSet, forFileAt contentURL: URL) throws {
        let result = LargeStack.sync { () -> Result<DeckIndex, DeckFileError> in
            do throws(DeckFileError) {
                return .success(try DeckIndex.make(fileAt: contentURL))
            } catch {
                return .failure(error)
            }
        }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        try result.get().apply(to: attributes)
    }
}
