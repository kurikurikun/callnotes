import AVFoundation

/// Converting the raw recording into .m4a files, and reading audio for Whisper.
enum AudioFiles {
    static let chunkSamples = 480_000 // 10 s at 48 kHz

    private static func aacSettings(bitRate: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC,
         AVSampleRateKey: PCMTrack.rate,
         AVNumberOfChannelsKey: 1,
         AVEncoderBitRateKey: bitRate]
    }

    /// Number of samples in a raw track (odd trailing byte from a crash is ignored).
    static func sampleCount(_ raw: URL) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: raw.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size / 2
    }

    /// Raw 48 kHz mono Int16 → AAC .m4a.
    static func encode(raw: URL, to out: URL) throws {
        try mix(raws: [raw], to: out, bitRate: 96_000)
    }

    /// Sums one or more raw tracks into one AAC .m4a (one track = plain encode).
    static func mix(raws: [URL], to out: URL, bitRate: Int = 128_000) throws {
        try? FileManager.default.removeItem(at: out)
        let file = try AVAudioFile(forWriting: out, settings: aacSettings(bitRate: bitRate),
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        let handles = try raws.map { try FileHandle(forReadingFrom: $0) }
        defer { handles.forEach { try? $0.close() } }
        let buf = AVAudioPCMBuffer(pcmFormat: PCMTrack.format, frameCapacity: AVAudioFrameCount(chunkSamples))!
        while true {
            let datas = handles.map { $0.readData(ofLength: chunkSamples * 2) }
            let n = (datas.map(\.count).max() ?? 0) / 2
            if n == 0 { break }
            let dst = buf.int16ChannelData![0]
            if datas.count == 1 {
                datas[0].withUnsafeBytes { src in
                    let s = src.bindMemory(to: Int16.self)
                    for i in 0..<n { dst[i] = i < s.count ? s[i] : 0 }
                }
            } else {
                var acc = [Int32](repeating: 0, count: n)
                for d in datas {
                    d.withUnsafeBytes { src in
                        let s = src.bindMemory(to: Int16.self)
                        for i in 0..<min(n, s.count) { acc[i] += Int32(s[i]) }
                    }
                }
                for i in 0..<n { dst[i] = Int16(clamping: acc[i]) }
            }
            buf.frameLength = AVAudioFrameCount(n)
            try file.write(from: buf)
        }
        file.close()
    }

    /// Duration in seconds of an audio file, 0 if unreadable.
    static func duration(_ url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    /// Any audio file → 16 kHz mono Float, what Whisper wants.
    static func load16k(_ url: URL, rate: Double = 16_000) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        guard let conv = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw CallNotesError("Cannot read \(url.lastPathComponent).")
        }
        conv.downmix = true
        var out = [Float]()
        out.reserveCapacity(Int(Double(file.length) / file.fileFormat.sampleRate * rate) + 16_000)
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536)!
        var eof = false
        while true {
            let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 32_768)!
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, st in
                if eof { st.pointee = .endOfStream; return nil }
                do { try file.read(into: inBuf, frameCount: 65_536) } catch { eof = true }
                if eof || inBuf.frameLength == 0 { eof = true; st.pointee = .endOfStream; return nil }
                st.pointee = .haveData
                return inBuf
            }
            if status == .error { throw err ?? CallNotesError("Audio conversion failed for \(url.lastPathComponent).") }
            if let p = outBuf.floatChannelData?[0], outBuf.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream || (eof && outBuf.frameLength == 0) { break }
        }
        return out
    }

    /// RMS of a 16 kHz array between two times (seconds).
    static func rms(_ s: [Float], from a: Double, to b: Double) -> Float {
        let i = max(0, min(s.count, Int(a * 16_000)))
        let j = max(i, min(s.count, Int(b * 16_000)))
        guard j > i else { return 0 }
        var sum: Float = 0
        for k in i..<j { sum += s[k] * s[k] }
        return (sum / Float(j - i)).squareRoot()
    }
}
