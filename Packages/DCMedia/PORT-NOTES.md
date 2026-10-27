# DCMedia — port notes

Ports deckcraft `crates/media` (MIT OR Apache-2.0, © ArtCraft Team and the DeckCraft contributors) at the commit
in `Tools/oracle/pin.env`, with the parsers of the crates it reads from: craft-media's `isobmff` and `matroska`
(craft-libs at the rev deckcraft's `Cargo.toml` pins, MIT OR Apache-2.0), deckcraft-ogg and the `OpusHead` parser
of deckcraft-opus. Every decoder is replaced by Apple's frameworks, and by media-bridge's external-decoder seam for
the codecs Apple doesn't decode. Nothing here imports AppKit or SwiftUI.

## Public API

| Swift | deckcraft-media |
|---|---|
| `Media.probe(_ bytes: [UInt8]) throws(MediaError) -> MediaInfo` | `probe` |
| `Media.probeHeaders(_:) throws(MediaError) -> MediaInfo` | `probe_headers` |
| `Media.posterPNG(_ bytes:, _ t: Double) throws(MediaError) -> [UInt8]` | `video::poster_png` |
| `Media.posterFrame(_:_:) throws(MediaError) -> Frame` | `video::poster_frame` |
| `Media.decodeAudio(_:) throws(MediaError) -> Pcm`, `Media.resample(_:_:)` | `audio::decode`, `audio::resample` |
| `MediaInfo { container, durationMs, audio: AudioInfo?, video: VideoInfo? }`, `.duration`, `.playable` | `MediaInfo` |
| `AudioInfo { codec, sampleRate, channels, decodable }` | `AudioInfo` |
| `VideoInfo { codec, width, height, fps, frames, decodable }` | `VideoInfo` |
| `MediaError.unsupported/.corrupt/.missing(String)`, `description` = deckcraft's message | `MediaError` |
| `Container.sniff(_:)`, `.name` | `Container` |
| `ClipParams` (`fromMs`, `range`, `gain`) | `clip::ClipParams` |
| `Player(_ out: AudioOut?)`: `play(_:mediaKey:bytes:spec:from:)`, `pause`, `stop`, `stopAll`, `seek`, `status`, `keys`, `anyPlaying`, `tick`, `waitLoaded(_:timeout:)`, `render(_:channels:rate:)`, `hasOutput` | `player::Player` |
| `AudioOut` (`start(fill) throws(AudioOutError)`, `stop`, `failure`), `AudioFill`, `PlayState`, `VoiceSpec`, `VoiceStatus` | `AudioOut`, `PlayState`, `VoiceSpec`, `VoiceStatus` |
| `AudioEngineOutput` | (cpal output in ui-egui) |
| `VideoFeed`: `size`, `seek`, `frameAt`, `ended`, `frameAtBlocking(_:timeout:)` | `feed::VideoFeed` |
| `VideoDecoder`: `size`, `codec`, `frameCount`, `nextFrame()`, `seek(_:)`; `Frame { time, width, height, rgba }` | `video::VideoDecoder`, `Frame` |
| `MediaInfo.audioSupport` / `.videoSupport` → `MediaSupport` | — (new) |
| `Media.register(externalDecoder:)`, `Media.unregisterAllExternalDecoders()`; `MediaExternalVideoDecoder`, `MediaExternalVideoPacket`, `MediaDecodedVideoFrame` (typealiases of media-bridge's `ExternalVideoDecoder`, `ExternalVideoPacket`, `DecodedVideoFrame`) | — (new; mirrors `MediaBridge.register(externalDecoder:)`) |

`decodable` keeps deckcraft's meaning (deckcraft's decoders), so probe results stored in documents are the same in
both apps. What *this* app can decode on *this* Mac is `audioSupport`/`videoSupport`: `.supported`,
`.unsupported(reason)` (the "can't play" state) or `.absent`. It counts runtime availability (AV1, MPEG-1/2,
ProRes, JPEG, Vorbis) and registered external decoders.

`mediaKey` identifies a clip's bytes for the audio cache, as in deckcraft; the cache reuses an entry only when the
key *and* the bytes match (Swift arrays have no allocation identity to compare).

## File map

| Swift | Source |
|---|---|
| `MediaTypes.swift` | `lib.rs` (`MediaError`, `Container::sniff`), `probe.rs` types |
| `Probe.swift` | `probe.rs` (`probe`, `probe_headers`, MP4, Matroska, Ogg Opus and ASF probes) |
| `BoxReader.swift` | craft-media `isobmff/{boxes,bytes,error}.rs` |
| `ISOBMFF.swift` | craft-media `isobmff/{demux,codec}.rs`: `open`, `trak`/`stbl`/`moof` sample tables, sample entries and their error paths. Metadata (`udta`/`meta`), `tref`, `sdtp`, sample-group contents and the colour/HDR fields are left out: nothing reads them and they can't fail |
| `Matroska.swift` | craft-media `matroska/{ebml,demux,track,codec,meta,ids}.rs`: EBML header, Segment walk with resync, SeekHead, Info, Tracks, cluster scan and lacing. Cues/Chapters/Tags/Attachments are walked and budgeted but not parsed; the packet-streaming `Demuxer` is not ported (the decoder reads indexed samples) |
| `Ogg.swift` | deckcraft `crates/ogg/src/lib.rs` (pages, CRC, packets, `OpusTiming`), `crates/opus/src/header.rs` (`OpusHead` checks) |
| `MP4Guard.swift` | `mp4guard.rs` |
| `PlainAudio.swift` | new: replaces `audio.rs`'s `probe_symphonia` (see below) |
| `AudioDecode.swift` | `audio.rs` (`Pcm`, `decode`, `resample`) on AudioToolbox |
| `VideoDecode.swift` | `video.rs` (`VideoDecoder`, `poster_frame`, `poster_png`) on VideoToolbox, the external-decoder seam and ImageIO; the support matrix |
| `ExternalDecoders.swift` | new: the external-decoder registry and the bridge to its async protocol |
| `Clip.swift`, `Player.swift`, `Feed.swift` | `clip.rs`, `player.rs`, `feed.rs` |
| `AudioEngineOutput.swift` | new: the `AudioOut` on AVAudioEngine |
| `Media.swift` | the free functions |

`yuv.rs` is not ported: VideoToolbox returns BGRA.

## What replaces what

- **Video decoding** (deckcraft-h264, -hevc, -vp9, -av1, `yuv.rs`): VideoToolbox, fed by the ported demuxers
  (`avcC`/`hvcC`/`av1C` as sample-description extension atoms; MPEG-1/2 from media-bridge's factory; ProRes and JPEG
  from the codec type and size), and registered external decoders for VP9, VP8 and any other CodecID they claim. Demuxing, frame timing, seeking (to the preceding
  sync sample, skipping to the frame shown) and presentation order are deckcraft's; VideoToolbox decodes in decode
  order, so frames are released once no sample still to be fed has an earlier pts. Pixels differ from deckcraft's
  decoders (VideoToolbox's matrix and rounding); the gradient tests hold them within 24/255 of the source.
- **Audio decoding** (symphonia, deckcraft-opus): AudioToolbox. Plain files (WAV, AIFF, CAF, FLAC, MP3, ADTS) go
  through `AudioFile` reading from memory plus `ExtAudioFile`; the audio of MP4/MOV, Matroska/WebM and Ogg Opus comes
  packet by packet from the ported demuxers through an `AudioConverter` (cookie: the `esds` ES_Descriptor, the ALAC
  config, an ES_Descriptor built from Matroska's AudioSpecificConfig, the Xiph-laced headers for Vorbis). MPEG audio in
  MP4 or Matroska takes its layer from the first frame header. MP3 gets deckcraft's gapless trim (LAME or
  ffmpeg tag delay and padding); Opus gets its pre-skip and RFC 7845 end trim. Samples differ by codec rounding.
- **Plain-audio probing** (symphonia's probe, MPL-2.0, so neither ported nor read): `PlainAudio.swift`, written
  from the formats' specifications, and fitted to symphonia's *observed* answers with black-box inputs run through
  the oracle. What that established:
  - WAV: chunks may not run past the RIFF length (the file may be shorter); `fmt ` before `data`; PCM 8/16/24/32-bit,
    float 32/64, A-law/µ-law with an 18-byte `fmt `, IMA/MS ADPCM with 4-bit samples and a 20-byte `fmt `,
    WAVE_FORMAT_EXTENSIBLE with a 40-byte `fmt `; INFO lists must be well formed; frames = data length / block align.
  - AIFF/AIFC: chunks within FORM; `COMM` then `SSND` required. CAF: version 1, chunks within the file; a packet
    table that reads cleanly and adds up to the data; a `chan` chunk that holds its descriptions; Opus is "unknown".
  - FLAC: every metadata block inside the file. Ogg Vorbis/FLAC: only an undamaged file (every page, CRC, to the end).
  - MP3: the Xing/Info tag counts only in a frame whose side information is all zero; a LAME tag trims delay + padding
    only when its CRC-16 checks, an ffmpeg (`Lavf`/`Lavc`) tag always; with no tag, a constant-rate estimate from the
    first 17 frames (none if any of them is missing); ID3 headers with a 0xFF version byte or a high size bit are
    rejected; an unrecognised file is searched for a layer III frame followed by another.
  - ADTS: only MPEG-4 headers without CRC (`FF F1`; AudioToolbox writes `FF F9`, which deckcraft can't probe); the
    duration is estimated from the mean frame length from the middle of the file (fits upstream's fixture and its
    mutations, not every file: see parity).
  - An MP4 whose audio track has a damaged handler: the first track with an audio sample entry, at its timescale,
    with no channel count.
  - `probe` measures a raw MP3/ADTS stream by walking its frames (resynchronising over damage) where deckcraft
    decodes it; for clean streams the counts are the same.
- **The audio output** (cpal, injected by the Rust UI): `AudioEngineOutput`, an `AVAudioSourceNode` pulling the
  mixer; a configuration change is reported through `failure()`, so the player falls back to the wall clock exactly
  as with deckcraft's stall and failure rules. The mixer, clocks, stall detection and cache are deckcraft's.
- **Video for the slide show**: `VideoFeed` (decode-ahead worker, generations, seek-on-jump) on the VideoToolbox
  decoder, clocked by the player's voice position as in deckcraft. AVPlayer is not used: it keeps its own clock,
  which would break the voice clock that video frames follow.
## What comes from media-bridge

DCMedia depends on media-bridge's **MediaImport** product (`Package.swift`: `.product(name: "MediaImport", package:
"media-bridge")`, the v0.40.0 already resolved). It uses:

- **`SupportGate`**: the native codec matrix. `audioSupport`/`videoSupport` map deckcraft's codec names to Matroska
  CodecIDs and ask the gate, then add the runtime checks the gate leaves to its caller (AV1 hardware, MPEG-1/2,
  ProRes and JPEG session creation) and one correction: the gate defers `A_VORBIS`, but AudioToolbox on this macOS
  lists a Vorbis decoder and decodes it (checked at run time through `kAudioFormatProperty_DecodeFormatIDs`).
- **`FormatDescriptionFactory`**: the MPEG-1/2 video format descriptions.
- **`ExternalVideoDecoder`, `ExternalVideoPacket`, `DecodedVideoFrame`**: the seam. vpx-swift's `VpxVideoDecoder`
  conforms already, so `Media.register(externalDecoder: VpxVideoDecoder())` in the app makes VP9 and VP8 play
  (the app and `dccli` register it since 2026-10-27: `DCApp/Codecs.swift`, `DCAppTests/CodecsTests.swift`; vpx-swift
  converts untagged streams as BT.709 where deckcraft takes SD as BT.601, asked as AB-A-0205);
  DCMedia doesn't depend on vpx-swift (Wave 5's decision). The registry is DCMedia's own, because media-bridge's
  lookup is internal to its MediaBridge product. The protocol decodes a batch of packets asynchronously; DCMedia's
  decoder is synchronous like deckcraft's, so each keyframe-to-keyframe run goes to the decoder on a detached task
  and the calling thread waits. Frame order, timing and seeking are the same as for VideoToolbox.

Not used, and why:

- `AudioDecodeSession`: decodes a whole packet array to Int16, throws on the first converter error and has no FLAC;
  DCMedia's `AudioConverter` path already decodes to float, skips bad packets and covers every format the session
  does (AC-3, E-AC-3 and MPEG layers I–III were added to it with the same format IDs and frame counts).
- `VideoDecodeSession`: whole-batch async decode for transcoding; playback needs one picture at a time, resettable
  for seeks. DCMedia's H.264/HEVC/AV1 format descriptions use the configuration record as an extension atom, as the
  factory does for AV1.
- `MediaBridge.probe` and MatroskaDemux: URL-based and async, a different codec vocabulary; parity needs
  craft-media's exact parsing, which is ported.

## What decodes, and what doesn't

On this Mac (Apple M5 Max, macOS 27), checked by the tests:

- **Video, VideoToolbox:** H.264, HEVC, AV1, MPEG-1, MPEG-2 (Matroska `V_MPEG1`/`V_MPEG2`), Apple ProRes (422 and
  4444 families, MP4/MOV and Matroska) and baseline Motion JPEG (`jpeg` in MOV, `V_MJPEG`). AV1, MPEG-1/2, ProRes and
  JPEG are runtime-gated: where the decoder is missing they are "unsupported".
- **Video, external decoder:** VP9 and VP8 (WebM/Matroska, VP9 also in MP4) once the app registers one; any other
  Matroska CodecID a registered decoder claims.
- **Audio, AudioToolbox:** AAC, ALAC, MP3, MP2, MP1, AC-3, E-AC-3, FLAC, Opus (Ogg, WebM/Matroska, CAF), Vorbis (Ogg,
  WebM/Matroska), PCM, A-law/µ-law, IMA/MS ADPCM.

Still unsupported (a typed "can't play", never a crash):

| Format | Probe | Decode |
|---|---|---|
| VP9 / VP8 with no decoder registered | as deckcraft | `unsupported("VP9 video")` / `("VP8 video")` |
| AV1 without a VideoToolbox decoder (M1/M2) | as deckcraft | `unsupported("AV1 video")` |
| Motion-JPEG A/B (`mjpa`, `mjpb`), DNxHD/HR, DV, MPEG-4 Part 2 (`mp4v`), APV | as deckcraft | `unsupported("<codec> video")` (no VideoToolbox decoder; `mp4v` would need its `esds`) |
| WMA / WMV (ASF) | header fields, as deckcraft | `unsupported(...)` (deckcraft too) |
| FLAC in Ogg, Speex, Theora (without a registered decoder) | as deckcraft | unsupported |

`videoSupport` names "Motion JPEG" supported from the codec name alone; an `mjpa`/`mjpb` track says so when it opens.
AC-3 and E-AC-3 are checked by creating their decoders: no Apple encoder exists to make test media in code.

Where Swift decodes more than deckcraft (not a parity concern; nothing stores decode results): every codec above
deckcraft's own set, AudioToolbox's own ADTS (`FF F9`), Opus in CAF, WAVs whose `fmt `/LIST/RIFF lengths symphonia
rejects, and one damaged MP4.

## Parity (oracle: `Tools/oracle/media-vectors`)

The tool runs deckcraft-media's `probe_headers`, `probe`, `audio::decode` and `VideoDecoder` over 64 inputs — 44
generated by `TestMedia.swift` (WAV/AIFF/MP3/ASF/Ogg/Matroska written byte by byte, AAC/ALAC/FLAC/Opus/PCM from
AudioToolbox, H.264/HEVC movies from AVAssetWriter) and upstream's 20 CC0 fixtures — and 1,276 mutations of them
(truncations, inverted bytes): 1,340 cases. `OracleParityTests` compares:

- **Probe** (`probe_headers` and `probe`, every field, fps as bits): **2,634 / 2,680 identical (98.3%)**. Every
  MP4/MOV, Matroska/WebM, Ogg Opus and ASF case is identical, and all but these plain-audio ones:
  - `at-aac-long-mpeg4.aac` and its mutations (44): symphonia's ADTS duration estimate on a 3 s file (2,995 ms against
    2,972 ms); the middle-of-file model matches upstream's `tone.aac` and all its mutations but not this file.
  - `wav-extensible.wav~x4` (2): a RIFF length 129 bytes short of the data chunk, which symphonia accepts for
    WAVE_FORMAT_EXTENSIBLE only.
  These are listed in `knownDifferences`; anything else fails the test.
- **Video** (the track opened, frame count, every frame's presentation time as bits): **1,317 / 1,340**. The rest:
  the VP9 file and its mutations (20: no decoder registered in the comparison; with one, `ExternalDecoderTests`
  shows deckcraft's frame times for VP9 and VP8), and 3 mutations whose damaged codec configuration VideoToolbox
  rejects when the session opens while deckcraft fails at the first frame (or vice versa).
- **Audio decode** (unmutated inputs; rate and channels exact, frames within one codec frame): **55 / 64**, Vorbis
  included (22,528 frames, as deckcraft). The rest: Swift decoding files deckcraft rejects (6, listed above), and
  error wording on three damaged files.

Regenerate (inputs, then the oracle, then the tests):

```sh
DCMEDIA_WRITE_INPUTS=1 swift test --filter FixtureWriterTests --scratch-path .build-media   # writes media/inputs
Tools/oracle/media-vectors/run.sh                                                           # writes media/cases, probe.txt
swift test --filter DCMediaTests --scratch-path .build-media
```

AVAssetWriter stamps creation times, so regenerating the inputs changes their bytes; rerun the oracle after.

## Tests

`DCMediaTests`: 62 tests in 12 suites. Of deckcraft-media's 43:

- **Ported (38)**: lib (1), probe (1), audio (2), clip (4), player (10; the source-replacement test checks the
  key-and-bytes cache rule instead of allocation identity), feed (2), and from `tests/it/decode.rs`: WAV, AIFF, MP3,
  AAC (M4A + ADTS), ALAC, FLAC, Ogg Opus, WMA, garbage/truncation (split in two), H.264 MP4 with B-frames and AAC,
  H.264 MOV, HEVC MP4, AV1 MKV (VideoToolbox), both feed tests, the player test, damaged media (a time check in
  place of the watchdog thread), and the overrunning sample tables.
- **Ported (1 more)**: `ogg_vorbis` decodes again (AudioToolbox's Vorbis decoder), falling back to the unsupported
  state where macOS lacks one.
- **Replaced (1)**: `vp9_webm_with_opus_audio` checks the probe and the unsupported state without a registered
  decoder (and the WebM's Opus track decodes); `ExternalDecoderTests` covers VP9 with one.
- **Skipped (3)**: `yuv.rs`'s conversion tests (VideoToolbox converts; the decode tests' colour checks stand in).

`CodecTests.swift`: MPEG-1 and MPEG-2 pictures written bit by bit (intra, DC-only macroblocks) in Matroska; ProRes 422,
ProRes 4444 and JPEG movies from AVAssetWriter; silent MPEG audio layer I/II frames as files and in Matroska; the AC-3
and E-AC-3 decoders; the support matrix; Vorbis in Ogg and WebM; and the seam, with a fake decoder (gated by a task
local so concurrent tests never see it) playing upstream's VP9 and VP8 clips and a made-up `V_THEORA` track.

New: container sniffing, error messages, ASF fields, MP3 measurement, `Pcm` bounds, an undecodable voice, the
AVAudioEngine output, AudioToolbox and AVAssetWriter media through the decoders, and the three oracle comparisons.
The upstream fixtures are read from `../deckcraft/crates/media/tests/fixtures`; those tests skip without it.
