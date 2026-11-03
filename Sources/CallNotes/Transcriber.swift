import Foundation
import WhisperKit

struct Line {
    var start: Double
    var end: Double
    var text: String
    var ours: Bool        // mic track
    var level: Float      // RMS on its own track
}

/// Local transcription with WhisperKit. Audio never leaves the Mac.
actor Transcriber {
    static let shared = Transcriber()
    private var kit: WhisperKit?
    private var loadedModel: String?

    /// Loads the model, downloading it once if needed. Works offline after that.
    func ensureModel(_ model: String, progress: @escaping @Sendable (Double) -> Void) async throws -> WhisperKit {
        if let kit, loadedModel == model { return kit }
        kit = nil
        var folder: URL
        if let p = Prefs.modelPath(model), FileManager.default.fileExists(atPath: p) {
            folder = URL(fileURLWithPath: p)
        } else {
            folder = try await WhisperKit.download(variant: model, downloadBase: AppPaths.models,
                                                   progressCallback: { p in progress(p.fractionCompleted) })
            Prefs.setModelPath(model, folder.path)
        }
        let k = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, verbose: false,
                                                       logLevel: .error, prewarm: false, load: true, download: false))
        kit = k
        loadedModel = model
        return k
    }

    /// Transcribes one 16 kHz track. Cuts it at quiet points into chunks of at
    /// most ~28 s (one Whisper window). Each chunk gets its own language check,
    /// limited to Japanese / English in Auto mode, so calls that switch language
    /// keep both. Start times are tightened to where sound actually begins.
    func transcribe(_ samples: [Float], kit: WhisperKit, language: String?,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> (segments: [(Double, Double, String)], languages: Set<String>) {
        // 1. Utterances: runs of sound separated by pauses of 0.3 s or more.
        var utts = Self.utterances(samples)
        // 2. Language per utterance (short ones inherit their neighbour's).
        //    Long utterances are checked every 4 s and cut where the language
        //    changes, since people switch mid-flow without pausing.
        var langOf = [String?](repeating: language, count: utts.count)
        if language == nil {
            var split: [Range<Int>] = [], splitLang: [String?] = []
            for (k, u) in utts.enumerated() {
                progress(0.3 * Double(k) / Double(max(1, utts.count)))
                let block = 4 * 16_000
                let blocks: [Range<Int>] = u.count > 8 * 16_000
                    ? stride(from: u.lowerBound, to: u.upperBound, by: block).map { $0..<min(u.upperBound, $0 + block) }
                    : [u]
                var bl: [String?] = []
                for r in blocks { bl.append(r.count >= 16_000 ? await detectJaEn(kit, Array(samples[r])) : nil) }
                // Fill gaps, then merge runs of the same language.
                for i in bl.indices where bl[i] == nil { bl[i] = (i > 0 ? bl[i - 1] : nil) ?? bl.first(where: { $0 != nil }) ?? nil }
                var start = u.lowerBound
                for i in blocks.indices {
                    let isLast = i == blocks.count - 1
                    if isLast || bl[i + 1] != bl[i] {
                        var end = blocks[i].upperBound
                        if !isLast { end = Self.quietestPoint(samples, around: end, within: 16_000) }
                        if end > start { split.append(start..<end); splitLang.append(bl[i]) }
                        start = end
                    }
                }
            }
            utts = split
            langOf = splitLang
            var last: String? = langOf.first(where: { $0 != nil }) ?? "en"
            for k in langOf.indices { if let l = langOf[k] { last = l } else { langOf[k] = last } }
        }
        // 3. Group neighbours with the same language into chunks of at most 28 s.
        var chunks: [(Range<Int>, String?)] = []
        for (k, u) in utts.enumerated() {
            if let lastChunk = chunks.last, lastChunk.1 == langOf[k], u.upperBound - lastChunk.0.lowerBound <= 28 * 16_000 {
                chunks[chunks.count - 1].0 = lastChunk.0.lowerBound..<u.upperBound
            } else {
                chunks.append((u, langOf[k]))
            }
        }
        utts = []
        var out: [(Double, Double, String)] = []
        var langs = Set<String>()
        for (i, (r, lang)) in chunks.enumerated() {
            try Task.checkCancellation()
            defer { progress(0.3 + 0.7 * Double(i + 1) / Double(chunks.count)) }
            let chunk = Array(samples[r])
            let offset = Double(r.lowerBound) / 16_000
            let opts = DecodingOptions(
                verbose: false, task: .transcribe, language: lang,
                temperatureFallbackCount: 3, usePrefillPrompt: true, detectLanguage: false,
                skipSpecialTokens: true)
            let results = try await kit.transcribe(audioArray: chunk, decodeOptions: opts)
            for res in results {
                for seg in res.segments {
                    let t = Self.clean(seg.text)
                    if t.isEmpty || seg.noSpeechProb > 0.8 { continue }
                    let end = min(Double(seg.end), Double(chunk.count) / 16_000)
                    let start = Self.firstSound(chunk, from: Double(seg.start), to: end)
                    guard end > start else { continue }
                    out.append((offset + start, offset + end, t))
                    if let lang { langs.insert(lang) }
                }
            }
        }
        return (out.sorted { $0.0 < $1.0 }, langs)
    }

    private func detectJaEn(_ kit: WhisperKit, _ audio: [Float]) async -> String? {
        guard let det = try? await kit.detectLangauge(audioArray: audio) else { return nil }
        if det.language == "ja" || det.language == "en" { return det.language }
        let ja = det.langProbs["ja"] ?? -.infinity, en = det.langProbs["en"] ?? -.infinity
        return ja > en ? "ja" : "en"
    }

    static func quietestPoint(_ s: [Float], around c: Int, within w: Int) -> Int {
        var best = c, bestE = Float.greatestFiniteMagnitude
        var p = max(0, c - w)
        while p + 1_600 <= min(s.count, c + w) {
            var e: Float = 0
            for k in p..<(p + 1_600) { e += s[k] * s[k] }
            if e < bestE { bestE = e; best = p + 800 }
            p += 800
        }
        return best
    }

    /// Whisper often starts a segment at the beginning of leading silence;
    /// move the start to the first 50 ms frame with sound.
    static func firstSound(_ s: [Float], from a: Double, to b: Double) -> Double {
        var t = a
        while t + 0.05 <= b {
            if AudioFiles.rms(s, from: t, to: t + 0.05) > 0.005 { return t }
            t += 0.05
        }
        return a
    }

    /// Splits audio into stretches of sound separated by pauses (≥ 0.3 s),
    /// padded by 0.1 s; anything longer than 28 s is cut at its quietest points.
    static func utterances(_ s: [Float]) -> [Range<Int>] {
        let frame = 800 // 50 ms
        let n = s.count / frame
        var voiced = [Bool](repeating: false, count: n)
        for f in 0..<n { voiced[f] = AudioFiles.rms(s, from: Double(f * frame) / 16_000, to: Double((f + 1) * frame) / 16_000) > 0.005 }
        var runs: [Range<Int>] = []
        var f = 0
        while f < n {
            guard voiced[f] else { f += 1; continue }
            var e = f, quiet = 0
            var g = f
            while g < n && quiet < 6 { if voiced[g] { e = g; quiet = 0 } else { quiet += 1 }; g += 1 }
            if e - f >= 3 { // ignore clicks under 0.2 s
                let a = max(0, f * frame - 1_600), b = min(s.count, (e + 1) * frame + 1_600)
                if let last = runs.last, a <= last.upperBound { runs[runs.count - 1] = last.lowerBound..<b } else { runs.append(a..<b) }
            }
            f = g
        }
        return runs.flatMap { r -> [Range<Int>] in
            guard r.count > 28 * 16_000 else { return [r] }
            return pieces(Array(s[r]), target: 28 * 16_000, search: 6 * 16_000)
                .map { (r.lowerBound + $0.lowerBound)..<(r.lowerBound + $0.upperBound) }
        }
    }

    static func pieces(_ s: [Float], target: Int, search: Int) -> [Range<Int>] {
        let win = 1_600
        var ranges: [Range<Int>] = []
        var a = 0
        while a < s.count {
            var b = min(s.count, a + target)
            if b < s.count {
                // Cut at the quietest 0.1 s shortly before the target length.
                var best = b, bestE = Float.greatestFiniteMagnitude
                var p = max(a + win, b - search)
                while p + win <= b {
                    var e: Float = 0
                    for k in p..<(p + win) { e += s[k] * s[k] }
                    if e < bestE { bestE = e; best = p + win / 2 }
                    p += win
                }
                b = best
            }
            ranges.append(a..<b)
            a = b
        }
        return ranges
    }

    static func clean(_ t: String) -> String {
        t.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TranscriptBuilder {
    /// Merges both tracks into one timeline. Drops lines that sit in silence on
    /// their own track (Whisper "hallucinations"), and where the same speech is on
    /// both tracks (speaker echo into the mic) keeps the louder copy.
    static func merge(mic: [(Double, Double, String)], micAudio: [Float],
                      sys: [(Double, Double, String)], sysAudio: [Float], silent: Float = 0.003) -> [Line] {
        var m = mic.map { Line(start: $0.0, end: $0.1, text: $0.2, ours: true, level: AudioFiles.rms(micAudio, from: $0.0, to: $0.1)) }
            .filter { $0.level > silent }
        var s = sys.map { Line(start: $0.0, end: $0.1, text: $0.2, ours: false, level: AudioFiles.rms(sysAudio, from: $0.0, to: $0.1)) }
            .filter { $0.level > silent }

        var dropM = Set<Int>(), dropS = Set<Int>()
        for (i, a) in m.enumerated() {
            for (j, b) in s.enumerated() where !dropS.contains(j) {
                let overlap = min(a.end, b.end) - max(a.start, b.start)
                guard overlap > 0, overlap / max(0.1, min(a.end - a.start, b.end - b.start)) > 0.5 else { continue }
                guard similarity(a.text, b.text) > 0.6 else { continue }
                if a.level >= b.level { dropS.insert(j) } else { dropM.insert(i); break }
            }
        }
        m = m.enumerated().filter { !dropM.contains($0.offset) }.map(\.element)
        s = s.enumerated().filter { !dropS.contains($0.offset) }.map(\.element)
        return (m + s).sorted { $0.start < $1.start }
    }

    /// How much of the shorter text's character bigrams appear in the longer one
    /// (0…1). Works for Japanese and English alike, and still matches when Whisper
    /// split the two copies into sentences differently.
    static func similarity(_ a: String, _ b: String) -> Double {
        func grams(_ s: String) -> [String: Int] {
            let c = Array(s.lowercased().filter { $0.isLetter || $0.isNumber })
            var g: [String: Int] = [:]
            if c.count < 2 { if let f = c.first { g[String(f)] = 1 }; return g }
            for i in 0..<(c.count - 1) { g[String(c[i...i + 1]), default: 0] += 1 }
            return g
        }
        let ga = grams(a), gb = grams(b)
        let shorter = min(ga.values.reduce(0, +), gb.values.reduce(0, +))
        guard shorter > 0 else { return 0 }
        var common = 0
        for (k, v) in ga { common += min(v, gb[k] ?? 0) }
        return Double(common) / Double(shorter)
    }

    static func stamp(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    /// transcript.md: consecutive lines from the same side become one paragraph.
    static func markdown(_ lines: [Line], meta: CallMeta) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        var md = "# \(meta.title.isEmpty ? "Call" : meta.title) – \(df.string(from: meta.start))\n\n"
        let single = meta.singleTrack == true
        if single {
            md += "Recording: \(meta.source ?? "imported")\(meta.theirLabel.isEmpty ? "" : " · With: \(meta.theirLabel)")  \n"
        } else {
            md += "Participants: \(meta.ourLabel) / \(meta.theirLabel)  \n"
        }
        let langs = (meta.detectedLanguages ?? []).sorted().joined(separator: ", ")
        md += "Language: \(meta.language)\(langs.isEmpty ? "" : " (heard: \(langs))") · Model: \(meta.whisperModel ?? "")\n\n"
        if lines.isEmpty { return md + "_No speech was recognised._\n" }

        var i = 0
        while i < lines.count {
            let first = lines[i]
            var text = first.text
            var j = i + 1
            while j < lines.count, lines[j].ours == first.ours,
                  lines[j].start - lines[j - 1].end < 2.5, lines[j].start - first.start < (single ? 30 : 90) {
                text += (needsSpace(text, lines[j].text) ? " " : "") + lines[j].text
                j += 1
            }
            if single {
                md += "**[\(stamp(first.start))]** \(text)\n\n"
            } else {
                let who = first.ours ? meta.ourLabel : meta.theirLabel
                md += "**[\(stamp(first.start))] \(who):** \(text)\n\n"
            }
            i = j
        }
        return md
    }

    /// transcript.md without its title block: just the timestamped lines.
    static func body(_ md: String) -> String {
        guard let r = md.range(of: "**[") else { return md }
        return String(md[r.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Japanese runs together without spaces; Latin text needs them.
    private static func needsSpace(_ a: String, _ b: String) -> Bool {
        guard let x = a.unicodeScalars.last, let y = b.unicodeScalars.first else { return false }
        return x.value < 0x3000 || y.value < 0x3000
    }
}
