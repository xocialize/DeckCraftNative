// DCMedia — audio decoding to interleaved float PCM. Port of deckcraft crates/media/src/audio.rs (MIT OR
// Apache-2.0, © ArtCraft Team and the DeckCraft contributors), with its decoders (symphonia and deckcraft-opus)
// replaced by AudioToolbox:
//
// - Plain audio files (WAV, AIFF, CAF, FLAC, MP3, ADTS) go through `AudioFile` reading from memory and
//   `ExtAudioFile`.
// - The audio of MP4/MOV, Matroska/WebM and Ogg comes from this package's demuxers, packet by packet, through
//   an `AudioConverter` (AAC, ALAC, MPEG audio layers I–III, AC-3, E-AC-3, FLAC, Opus); PCM tracks are
//   converted here. The codec matrix is media-bridge's (MediaImport `SupportGate`).
//
// Vorbis decodes through AudioToolbox's own Vorbis decoder (cookie: the Xiph-laced headers) where macOS has it;
// WMA has no decoder: `MediaError.unsupported`, never a crash. Samples differ
// from deckcraft's decoders by codec rounding; frame counts follow the containers (no gapless trimming of
// AAC, as deckcraft's MP4 path does none either).
import AudioToolbox
import DCCore

/// Decoded audio: interleaved float samples in −1…1.
public struct Pcm: Sendable, Equatable {
    public var rate: UInt32
    public var channels: UInt16
    public var samples: [Float]

    public init(rate: UInt32, channels: UInt16, samples: [Float]) {
        self.rate = rate
        self.channels = channels
        self.samples = samples
    }

    /// Sample frames (samples per channel).
    public var frames: Int { samples.count / Int(max(channels, 1)) }
    public var duration: Double { Double(frames) / Double(max(rate, 1)) }

    /// Sample `frame` of channel `ch` (0 past the end).
    public func at(_ frame: Int, _ ch: Int) -> Float {
        let c = Int(max(channels, 1))
        let (i, o) = frame.multipliedReportingOverflow(by: c)
        guard !o, frame >= 0, ch >= 0 else { return 0 }
        let k = i + min(ch, c - 1)
        return k < samples.count ? samples[k] : 0
    }

    /// Root-mean-square level over all samples.
    public var rms: Float {
        if samples.isEmpty { return 0 }
        return (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }
}

/// AudioToolbox's Vorbis format ('vorb'), which the SDK names no constant for.
let kAudioFormatVorbis: AudioFormatID = 0x766F_7262

/// The converter input's "no more packets" status ('eof!').
private let endOfPackets: OSStatus = 0x656F_6621

/// Most samples a decode keeps (deckcraft's `MAX_PCM_SAMPLES`).
let maxPcmSamples = 64 * 1024 * 1024

extension Media {
    /// Decode the audio of `bytes` (an audio file, or the audio track of a video) to PCM (deckcraft's
    /// `audio::decode`).
    public static func decodeAudio(_ bytes: [UInt8]) throws(MediaError) -> Pcm {
        try AudioDecode.decode(bytes)
    }

    /// Interleaved PCM resampled (linear) to `rate` (deckcraft's `audio::resample`).
    public static func resample(_ pcm: Pcm, _ rate: UInt32) -> Pcm {
        if pcm.rate == rate || pcm.rate == 0 || rate == 0 { return pcm }
        let c = Int(max(pcm.channels, 1))
        let nIn = pcm.frames
        let nOut = Int(UInt64(nIn) * UInt64(rate) / UInt64(pcm.rate))
        let step = Double(pcm.rate) / Double(rate)
        var out: [Float] = []
        out.reserveCapacity(nOut * c)
        for i in 0..<nOut {
            let x = Double(i) * step
            let k = Int(x)
            let f = Float(x - Double(k))
            for ch in 0..<c {
                let a = pcm.at(k, ch)
                let b = k + 1 < nIn ? pcm.at(k + 1, ch) : a
                out.append(a + (b - a) * f)
            }
        }
        return Pcm(rate: rate, channels: pcm.channels, samples: out)
    }
}

enum AudioDecode {
    static func decode(_ bytes: [UInt8]) throws(MediaError) -> Pcm {
        switch Container.sniff(bytes) {
        case .asf:
            throw .unsupported("Windows Media Audio (WMA)")
        case .ogg:
            return try decodeOgg(bytes)
        case .matroska:
            return try decodeMatroska(bytes)
        case .mp4:
            if !MP4Guard.tablesFit(bytes) { throw .corrupt("the MP4's sample tables do not fit the file") }
            return try decodeMP4(bytes)
        case .mp3:
            return try decodeMP3(bytes, from: nil)
        case .unknown:
            // Like deckcraft's reader, look for MPEG audio frames in a file nothing else recognises.
            guard let p = PlainAudio.MPEG.searchLayer3(bytes) else { throw .unsupported("this audio format") }
            return try decodeMP3(bytes, from: p)
        case let c:
            return try decodeFile(bytes, c)
        }
    }

    /// MP3 through AudioFile, then the gapless trim of its LAME (or ffmpeg) tag: the encoder delay from
    /// the start and the padding from the end, as deckcraft's reader applies them.
    static func decodeMP3(_ bytes: [UInt8], from: Int?) throws(MediaError) -> Pcm {
        let b = from.map { Array(bytes[$0...]) } ?? bytes
        if let start = PlainAudio.MPEG.audioStart(b), let h = PlainAudio.MPEGHeader(b, start), h.layer != 3 {
            // MPEG audio layer I or II: AudioFile reads it as such; there is no gapless tag to apply.
            return try decodeFile(b, .mp3, type: h.layer == 1 ? kAudioFileMP1Type : kAudioFileMP2Type)
        }
        var pcm = try decodeFile(b, .mp3)
        if let start = PlainAudio.MPEG.audioStart(b), let h = PlainAudio.MPEGHeader(b, start), let info = PlainAudio.MPEG.info(b, start, h),
           let trim = info.trim, let delay = info.delay
        {
            let c = Int(max(pcm.channels, 1))
            let total = info.frames.map { Int(clamping: $0) * h.samplesPerFrame - Int(clamping: trim) }
            pcm.samples.removeFirst(min(Int(delay) * c, pcm.samples.count))
            if let t = total, t >= 0, t * c < pcm.samples.count { pcm.samples.removeLast(pcm.samples.count - t * c) }
        }
        return pcm
    }

    // MARK: AudioFile from memory

    private final class MemorySource {
        let bytes: [UInt8]
        init(_ b: [UInt8]) { bytes = b }
    }

    private static func fileType(_ c: Container, _ b: [UInt8]) -> AudioFileTypeID {
        switch c {
        case .wav: kAudioFileWAVEType
        case .aiff: PlainAudio.tag(b, 8) == "AIFC" ? kAudioFileAIFCType : kAudioFileAIFFType
        case .caf: kAudioFileCAFType
        case .flac: kAudioFileFLACType
        case .mp3: kAudioFileMP3Type
        case .adts: kAudioFileAAC_ADTSType
        default: 0
        }
    }

    /// A plain audio file through AudioFile and ExtAudioFile.
    static func decodeFile(_ bytes: [UInt8], _ c: Container, type: AudioFileTypeID? = nil) throws(MediaError) -> Pcm {
        let src = MemorySource(bytes)
        let ctx = Unmanaged.passRetained(src)
        defer { ctx.release() }
        let read: AudioFile_ReadProc = { client, position, count, buffer, actual in
            let s = Unmanaged<MemorySource>.fromOpaque(client).takeUnretainedValue()
            guard position >= 0, position <= Int64(s.bytes.count) else {
                actual.pointee = 0
                return OSStatus(kAudioFileEndOfFileError)
            }
            let n = min(Int(count), s.bytes.count - Int(position))
            s.bytes.withUnsafeBytes { raw in
                if n > 0, let base = raw.baseAddress { buffer.copyMemory(from: base + Int(position), byteCount: n) }
            }
            actual.pointee = UInt32(n)
            return noErr
        }
        let size: AudioFile_GetSizeProc = { client in
            Int64(Unmanaged<MemorySource>.fromOpaque(client).takeUnretainedValue().bytes.count)
        }
        var file: AudioFileID?
        guard AudioFileOpenWithCallbacks(ctx.toOpaque(), read, nil, size, nil, type ?? fileType(c, bytes), &file) == noErr, let file else {
            throw .unsupported("this audio format")
        }
        defer { AudioFileClose(file) }
        var ext: ExtAudioFileRef?
        guard ExtAudioFileWrapAudioFileID(file, false, &ext) == noErr, let ext else { throw .unsupported("this audio format") }
        defer { ExtAudioFileDispose(ext) }
        var fileFormat = AudioStreamBasicDescription()
        var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileDataFormat, &sz, &fileFormat) == noErr else {
            throw .unsupported("this audio format")
        }
        let channels = fileFormat.mChannelsPerFrame
        let rate = fileFormat.mSampleRate
        guard channels > 0, channels <= 64, rate.isFinite, rate >= 1, rate <= 1_536_000 else { throw .corrupt("no audio could be decoded") }
        var client = floatFormat(rate, channels)
        guard ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client) == noErr
        else { throw .unsupported("this audio format") }
        var out: [Float] = []
        let chunk = 4096
        var buf = [Float](repeating: 0, count: chunk * Int(channels))
        while out.count + Int(channels) <= maxPcmSamples {
            var frames = UInt32(chunk)
            let st = buf.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(raw.count),
                                                                                      mData: raw.baseAddress))
                return ExtAudioFileRead(ext, &frames, &list)
            }
            if st != noErr || frames == 0 { break }
            let n = min(Int(frames) * Int(channels), maxPcmSamples - out.count)
            out.append(contentsOf: buf[0..<n])
        }
        if out.isEmpty { throw .corrupt("no audio could be decoded") }
        return Pcm(rate: UInt32(rustCast: rate), channels: UInt16(channels), samples: out)
    }

    static func floatFormat(_ rate: Double, _ channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                    mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels, mChannelsPerFrame: channels,
                                    mBitsPerChannel: 32, mReserved: 0)
    }

    // MARK: Packets through AudioConverter

    /// A compressed stream: its format and cookie, and where its packets are.
    struct PacketStream {
        var format: AudioStreamBasicDescription
        var cookie: [UInt8]?
        var count: Int
        var packet: (Int) -> [UInt8]?
    }

    /// The converter's input: one packet at a time, in memory that stays put until the next call.
    private final class Feeder {
        let stream: PacketStream
        var next = 0
        let desc = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        var pointer: UnsafeMutableRawPointer?

        init(_ s: PacketStream) {
            stream = s
            desc.initialize(to: AudioStreamPacketDescription())
        }

        deinit {
            pointer?.deallocate()
            desc.deallocate()
        }
    }


    /// Decode `s` to float PCM at its own rate and channel count.
    static func decodePackets(_ s: PacketStream) throws(MediaError) -> Pcm {
        var input = s.format
        if let cookie = s.cookie, !cookie.isEmpty {
            // Let the codec complete the description from its cookie (object type, SBR, channels): it
            // fills only the fields left at zero.
            var filled = input
            filled.mSampleRate = 0
            filled.mChannelsPerFrame = 0
            filled.mFramesPerPacket = 0
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let st = cookie.withUnsafeBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, UInt32(raw.count), base, &size, &filled)
            }
            if st == noErr, filled.mChannelsPerFrame > 0, filled.mSampleRate > 0 {
                if filled.mFramesPerPacket == 0 { filled.mFramesPerPacket = input.mFramesPerPacket }
                input = filled
            }
        }
        let channels = input.mChannelsPerFrame
        guard channels > 0, channels <= 64, input.mSampleRate.isFinite, input.mSampleRate >= 1, input.mSampleRate <= 1_536_000 else {
            throw .corrupt("no audio could be decoded")
        }
        var output = floatFormat(input.mSampleRate, channels)
        var conv: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &conv) == noErr, let conv else { throw .unsupported("this audio format") }
        defer { AudioConverterDispose(conv) }
        if let cookie = s.cookie, !cookie.isEmpty {
            _ = cookie.withUnsafeBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return noErr }
                return AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie, UInt32(raw.count), base)
            }
        }
        let feeder = Feeder(s)
        let ctx = Unmanaged.passRetained(feeder)
        defer { ctx.release() }
        let proc: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, outDesc, user in
            guard let user else { return endOfPackets }
            let f = Unmanaged<Feeder>.fromOpaque(user).takeUnretainedValue()
            f.pointer?.deallocate()
            f.pointer = nil
            while f.next < f.stream.count {
                let i = f.next
                f.next += 1
                guard let p = f.stream.packet(i), !p.isEmpty else { continue }
                let mem = UnsafeMutableRawPointer.allocate(byteCount: p.count, alignment: 16)
                p.withUnsafeBytes { if let b = $0.baseAddress { mem.copyMemory(from: b, byteCount: p.count) } }
                f.pointer = mem
                f.desc.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(p.count))
                ioPackets.pointee = 1
                ioData.pointee.mNumberBuffers = 1
                ioData.pointee.mBuffers.mData = mem
                ioData.pointee.mBuffers.mDataByteSize = UInt32(p.count)
                ioData.pointee.mBuffers.mNumberChannels = f.stream.format.mChannelsPerFrame
                if let outDesc { outDesc.pointee = f.desc }
                return noErr
            }
            ioPackets.pointee = 0
            return endOfPackets
        }
        var out: [Float] = []
        let chunk = 4096
        var buf = [Float](repeating: 0, count: chunk * Int(channels))
        var errors = 0
        while out.count + Int(channels) <= maxPcmSamples {
            var frames = UInt32(chunk)
            let st = buf.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(raw.count),
                                                                                      mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(conv, proc, ctx.toOpaque(), &frames, &list, nil)
            }
            if frames > 0 {
                let n = min(Int(frames) * Int(channels), maxPcmSamples - out.count)
                out.append(contentsOf: buf[0..<n])
            }
            if st == endOfPackets || (st == noErr && frames == 0) { break }
            if st != noErr {
                // A packet the codec rejects: carry on with the next, give up after many.
                errors += 1
                if errors > 64 || feeder.next >= s.count { break }
            }
        }
        if out.isEmpty { throw .corrupt("no audio could be decoded") }
        return Pcm(rate: UInt32(rustCast: input.mSampleRate), channels: UInt16(channels), samples: out)
    }

    // MARK: Containers

    /// An ES_Descriptor (CoreAudio's AAC cookie) around an AudioSpecificConfig.
    static func esds(asc: [UInt8]) -> [UInt8] {
        func desc(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
            let n = UInt32(body.count)
            return [tag, UInt8(0x80 | (n >> 21) & 0x7F), UInt8(0x80 | (n >> 14) & 0x7F), UInt8(0x80 | (n >> 7) & 0x7F), UInt8(n & 0x7F)] + body
        }
        let dcd = desc(4, [0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + desc(5, asc))
        return desc(3, [0, 1, 0] + dcd + desc(6, [2]))
    }

    static func asbd(_ format: AudioFormatID, rate: Double, channels: UInt32, framesPerPacket: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: format, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: framesPerPacket,
                                    mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
    }

    /// PCM samples of `bits` to floats.
    static func pcmToFloat(_ d: [UInt8], bits: UInt16, float: Bool, bigEndian: Bool, signed: Bool, into out: inout [Float]) {
        let w = Int(bits + 7) / 8
        guard w >= 1, w <= 8 else { return }
        var i = 0
        while i + w <= d.count && out.count < maxPcmSamples {
            var v: UInt64 = 0
            for k in 0..<w { v |= UInt64(d[i + (bigEndian ? k : w - 1 - k)]) << UInt64(8 * (w - 1 - k)) }
            let s: Float
            if float {
                s = w == 4 ? Float(bitPattern: UInt32(truncatingIfNeeded: v)) : w == 8 ? Float(Double(bitPattern: v)) : 0
            } else {
                let shift = UInt64(64 - 8 * w)
                let sv = signed ? Int64(bitPattern: v << shift) >> Int64(shift) : Int64(v) - (Int64(1) << Int64(8 * w - 1))
                s = Float(Double(sv) / Double(Int64(1) << Int64(8 * w - 1)))
            }
            out.append(s.isFinite ? s : 0)
            i += w
        }
    }

    static func decodeMP4(_ bytes: [UInt8]) throws(MediaError) -> Pcm {
        let f: BMFFFile
        do { f = try BMFF.open(bytes) } catch { throw .corrupt(error.message) }
        for (ti, t) in f.tracks.enumerated() where t.kind == .audio {
            guard let e = t.entries.first else { continue }
            let rate = e.audio?.sampleRate ?? Double(t.timescale)
            let ch = e.audio?.channels ?? 2
            let packet = { (i: Int) -> [UInt8]? in (try? f.readSample(bytes, ti, i)).map(Array.init) }
            switch e.codec {
            case .aac(_, let esds):
                return try decodePackets(PacketStream(format: asbd(kAudioFormatMPEG4AAC, rate: rate, channels: ch, framesPerPacket: 1024), cookie: esds,
                                                      count: t.samples.count, packet: packet))
            case .alac(let cookie):
                return try decodePackets(PacketStream(format: asbd(kAudioFormatAppleLossless, rate: rate, channels: ch, framesPerPacket: 4096),
                                                      cookie: cookie, count: t.samples.count, packet: packet))
            case .mp3:
                // `.mp3`/`.mp2` entries and MPEG-1/2 audio in `esds` name no layer: the frame header has it.
                return try decodePackets(mpegStream(rate, ch, t.samples.count, packet))
            case .ac3:
                return try decodePackets(PacketStream(format: asbd(kAudioFormatAC3, rate: rate, channels: ch, framesPerPacket: 1536), cookie: nil,
                                                      count: t.samples.count, packet: packet))
            case .eac3:
                return try decodePackets(PacketStream(format: asbd(kAudioFormatEnhancedAC3, rate: rate, channels: ch, framesPerPacket: 1536), cookie: nil,
                                                      count: t.samples.count, packet: packet))
            case .flac(let dfLa):
                return try decodePackets(PacketStream(format: asbd(kAudioFormatFLAC, rate: rate, channels: ch, framesPerPacket: 0), cookie: Array(dfLa.dropFirst(4)),
                                                      count: t.samples.count, packet: packet))
            case .pcm(let p):
                var out: [Float] = []
                for i in t.samples.indices {
                    guard let d = packet(i) else { continue }
                    pcmToFloat(d, bits: p.bits, float: p.float, bigEndian: p.bigEndian, signed: p.signed, into: &out)
                }
                if out.isEmpty { throw .corrupt("no audio could be decoded") }
                return Pcm(rate: UInt32(rustCast: rate), channels: UInt16(truncatingIfNeeded: max(p.channels, 1)), samples: out)
            default:
                continue
            }
        }
        throw .missing("audio track we can decode")
    }

    /// MPEG audio packets, the layer (I, II or III) and frame length read from the first frame header.
    static func mpegStream(_ rate: Double, _ channels: UInt32, _ count: Int, _ packet: @escaping (Int) -> [UInt8]?) -> PacketStream {
        var format = kAudioFormatMPEGLayer3
        var frames: UInt32 = 1152
        var r = rate, ch = channels
        if let first = (0..<min(count, 8)).lazy.compactMap(packet).first, let h = PlainAudio.MPEGHeader(first, 0) {
            format = h.layer == 1 ? kAudioFormatMPEGLayer1 : h.layer == 2 ? kAudioFormatMPEGLayer2 : kAudioFormatMPEGLayer3
            frames = UInt32(h.samplesPerFrame)
            r = Double(h.rate)
            ch = UInt32(h.channels)
        }
        return PacketStream(format: asbd(format, rate: r, channels: ch, framesPerPacket: frames), cookie: nil, count: count, packet: packet)
    }

    static func decodeMatroska(_ bytes: [UInt8]) throws(MediaError) -> Pcm {
        let f: MKVFile
        do { f = try Matroska.open(bytes) } catch { throw .corrupt("the audio could not be read") }
        for (ti, t) in f.tracks.enumerated() where t.kind == .audio {
            let a = t.audio ?? MKVAudio()
            let rate = a.outputSamplingFrequency ?? a.samplingFrequency
            let ch = UInt32(clamping: a.channels)
            let packet = { (i: Int) -> [UInt8]? in try? f.readSample(bytes, ti, i) }
            switch t.codec {
            case .opus(let head):
                guard let h = OpusHead(head) else { throw .corrupt("invalid Opus header") }
                var pcm = try decodePackets(PacketStream(format: asbd(kAudioFormatOpus, rate: 48000, channels: UInt32(h.channels), framesPerPacket: 960),
                                                         cookie: nil, count: t.samples.count, packet: packet))
                trimOpus(&pcm, preSkip: Int(h.preSkip), total: nil)
                return pcm
            case .aac(let asc):
                return try decodePackets(PacketStream(format: asbd(kAudioFormatMPEG4AAC, rate: rate, channels: ch, framesPerPacket: 1024), cookie: esds(asc: asc),
                                                      count: t.samples.count, packet: packet))
            case .mp3, .mp2, .mp1:
                return try decodePackets(mpegStream(rate, ch, t.samples.count, packet))
            case .ac3:
                return try decodePackets(PacketStream(format: asbd(kAudioFormatAC3, rate: rate, channels: ch, framesPerPacket: 1536), cookie: nil,
                                                      count: t.samples.count, packet: packet))
            case .eac3:
                return try decodePackets(PacketStream(format: asbd(kAudioFormatEnhancedAC3, rate: rate, channels: ch, framesPerPacket: 1536), cookie: nil,
                                                      count: t.samples.count, packet: packet))
            case .flac(let p):
                return try decodePackets(PacketStream(format: asbd(kAudioFormatFLAC, rate: rate, channels: ch, framesPerPacket: 0), cookie: Array(p.dropFirst(4)),
                                                      count: t.samples.count, packet: packet))
            case .pcm(let float, let big, let bits):
                var out: [Float] = []
                for i in t.samples.indices {
                    guard let d = packet(i) else { continue }
                    pcmToFloat(d, bits: bits, float: float, bigEndian: big, signed: bits != 8, into: &out)
                }
                if out.isEmpty { throw .corrupt("no audio could be decoded") }
                return Pcm(rate: UInt32(rustCast: rate), channels: UInt16(clamping: max(a.channels, 1)), samples: out)
            case .vorbis:
                guard AudioSupport.vorbis else { throw .unsupported("Vorbis audio") }
                // CodecPrivate is the three Vorbis headers, Xiph-laced: AudioToolbox's Vorbis cookie.
                return try decodePackets(PacketStream(format: asbd(kAudioFormatVorbis, rate: rate, channels: ch, framesPerPacket: 0), cookie: t.codecPrivate,
                                                      count: t.samples.count, packet: packet))
            default:
                continue
            }
        }
        throw .missing("audio track we can decode")
    }

    static func decodeOgg(_ bytes: [UInt8]) throws(MediaError) -> Pcm {
        guard let f = Ogg.open(bytes) else { throw .unsupported("this audio format") }
        if let s = f.streamOf(.opus), let st = f.streams.at(s) {
            guard let first = st.headers.first, let h = OpusHead(first) else { throw .corrupt("Opus header missing") }
            var pcm = try decodePackets(PacketStream(format: asbd(kAudioFormatOpus, rate: 48000, channels: UInt32(h.channels), framesPerPacket: 960),
                                                     cookie: nil, count: st.packets.count, packet: { f.readPacket(bytes, s, $0) }))
            let total = Ogg.opusTotal(st, preSkip: UInt32(h.preSkip))
            trimOpus(&pcm, preSkip: Int(h.preSkip), total: total)
            return pcm
        }
        if let s = f.streamOf(.vorbis), let st = f.streams.at(s) {
            guard AudioSupport.vorbis else { throw .unsupported("Vorbis audio") }
            guard st.headers.count == 3, let id = st.headers.first, id.count >= 30 else { throw .corrupt("Vorbis headers missing") }
            let channels = UInt32(id[11])
            let rate = Double(UInt32(id[12]) | UInt32(id[13]) << 8 | UInt32(id[14]) << 16 | UInt32(id[15]) << 24)
            return try decodePackets(PacketStream(format: asbd(kAudioFormatVorbis, rate: rate, channels: channels, framesPerPacket: 0),
                                                  cookie: xiphLaced(st.headers), count: st.packets.count, packet: { f.readPacket(bytes, s, $0) }))
        }
        if f.streamOf(.flac) != nil { throw .unsupported("FLAC in Ogg") }
        throw .missing("audio track we can decode")
    }

    /// Codec headers in Xiph lacing (Matroska's `CodecPrivate` layout for Vorbis).
    static func xiphLaced(_ headers: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = [UInt8(truncatingIfNeeded: max(headers.count - 1, 0))]
        for h in headers.dropLast() {
            var n = h.count
            while n >= 255 {
                out.append(255)
                n -= 255
            }
            out.append(UInt8(n))
        }
        return out + headers.flatMap { $0 }
    }

    /// Drop the pre-skip and, with `total`, trim the end (RFC 7845 §4.2, §4.5).
    static func trimOpus(_ pcm: inout Pcm, preSkip: Int, total: Int64?) {
        let c = Int(max(pcm.channels, 1))
        let drop = min(preSkip * c, pcm.samples.count)
        pcm.samples.removeFirst(drop)
        if let t = total, t > 0 {
            let keep = Int(clamping: t) * c
            if keep < pcm.samples.count { pcm.samples.removeLast(pcm.samples.count - keep) }
        }
    }
}
