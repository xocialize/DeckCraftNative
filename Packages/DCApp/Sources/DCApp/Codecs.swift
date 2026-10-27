// DCApp — the video decoders the app adds to DCMedia. VP9 and VP8 have no decoder in Apple's frameworks;
// vpx-swift's `VpxVideoDecoder` (libvpx, BSD-3) plugs into DCMedia's external-decoder seam, so WebM and
// Matroska videos with those codecs play in the editor and the show, and get poster frames on insert.
// deckcraft decodes VP9 itself and reports VP8 as unsupported; here both play.
import DCMedia
import VpxSwift

public enum Codecs {
    /// Register the external decoders, once per process (later calls do nothing).
    public static func registerExternalDecoders() { _ = registered }

    private static let registered: Void = { Media.register(externalDecoder: VpxVideoDecoder()) }()
}
