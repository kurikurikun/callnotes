import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Seconds on the host clock (the clock ScreenCaptureKit stamps buffers with).
func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

/// One recorded track, written as raw 48 kHz mono 16-bit PCM and appended as it
/// arrives. A raw file has no header to finalise, so whatever reached the disk
/// before a crash is usable. Converted to AAC .m4a after the call.
final class PCMTrack {
    static let rate = 48_000.0
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!

    private let handle: FileHandle
    private let t0: Double
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var firstPTS: CMTime?
    private var startPos = 0.0
    private var lastSync = hostNow()
    private(set) var samplesWritten: Int64 = 0

    init(url: URL, t0: Double) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        self.t0 = t0
    }

    /// Appends one buffer and returns its RMS level (0…1).
    @discardableResult
    func append(_ sb: CMSampleBuffer) -> Float {
        guard CMSampleBufferDataIsReady(sb),
              let fd = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return 0 }
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return 0 }
        var asbd = asbdPtr.pointee
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { return 0 }
        if inputFormat == nil || inputFormat! != fmt {
            converter = AVAudioConverter(from: fmt, to: Self.format)
            converter?.downmix = true
            inputFormat = fmt
        }
        guard let converter,
              let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { return 0 }
        pcm.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames),
                                                           into: pcm.mutableAudioBufferList) == noErr else { return 0 }

        // Keep both tracks on one timeline (seconds since t0). The first buffer is
        // placed by arrival time; later ones by their own timestamps. Gaps (e.g. a
        // track that went quiet and stopped delivering) are filled with silence.
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let duration = Double(frames) / fmt.sampleRate
        if firstPTS == nil {
            firstPTS = pts
            startPos = max(0, hostNow() - t0 - duration)
        }
        let pos = startPos + CMTimeSubtract(pts, firstPTS!).seconds
        let gap = Int64(pos * Self.rate) - samplesWritten
        if gap > 2_400 { writeSilence(min(gap, Int64(Self.rate) * 3_600)) }

        let cap = AVAudioFrameCount(Double(frames) * Self.rate / fmt.sampleRate) + 1_024
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: cap) else { return 0 }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return pcm
        }
        let n = Int(out.frameLength)
        guard n > 0, let p = out.int16ChannelData?[0] else { return 0 }
        handle.write(Data(bytes: p, count: n * 2))
        samplesWritten += Int64(n)

        var sum = 0.0
        for i in 0..<n { let v = Double(p[i]) / 32_768; sum += v * v }
        let now = hostNow()
        if now - lastSync > 2 { try? handle.synchronize(); lastSync = now }
        return Float((sum / Double(n)).squareRoot())
    }

    private func writeSilence(_ count: Int64) {
        let chunk = Data(count: 96_000)
        var left = count * 2
        while left > 0 {
            let n = Int(min(left, Int64(chunk.count)))
            handle.write(n == chunk.count ? chunk : chunk.prefix(n))
            left -= Int64(n)
        }
        samplesWritten += count
    }

    func close() {
        try? handle.synchronize()
        try? handle.close()
    }
}

/// Records the Mac's microphone (our side) and everything the Mac plays (their
/// side) as two separate tracks via ScreenCaptureKit. Nothing joins the call.
final class CallRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "co.move-ment.callnotes.audio", qos: .userInitiated)
    private let mic: PCMTrack
    private let sys: PCMTrack
    private var lastSoundReport = 0.0

    /// Called (at most once a second) when the system track has audible sound.
    var onSystemSound: (() -> Void)?
    /// Called if macOS stops the capture (permission revoked, display change…).
    var onFailure: ((Error) -> Void)?

    init(dir: URL) throws {
        let t0 = hostNow()
        mic = try PCMTrack(url: dir.appendingPathComponent("mic.pcm"), t0: t0)
        sys = try PCMTrack(url: dir.appendingPathComponent("system.pcm"), t0: t0)
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CallNotesError("No display found to attach audio capture to.") }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        // Video is not used: the smallest, slowest picture ScreenCaptureKit allows.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.showsCursor = false
        cfg.queueDepth = 3
        cfg.capturesAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true
        cfg.captureMicrophone = true

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        queue.sync {
            mic.close()
            sys.close()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio:
            let level = sys.append(sb)
            let now = hostNow()
            if level > 0.002, now - lastSoundReport > 1 {
                lastSoundReport = now
                onSystemSound?()
            }
        case .microphone:
            mic.append(sb)
        default:
            break // screen frames are ignored
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(error)
    }
}

struct CallNotesError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
