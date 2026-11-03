import Foundation

enum AppPaths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    /// Raw recordings live here while a call is running (never in a synced folder).
    static let work: URL = {
        let u = support.appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let models: URL = {
        let u = support.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
}

/// meta.json in each call folder.
struct CallMeta: Codable {
    var title: String
    var ourLabel: String
    var theirLabel: String
    var start: Date
    var end: Date?
    var language: String              // setting used: auto | ja | en
    var detectedLanguages: [String]?
    var whisperModel: String?
    var claudeModel: String?
    var summaryLanguage: String?
    var transcriptStatus: String?     // done | failed: …
    var summaryStatus: String?        // done | skipped: … | failed: …
    var audioDeleted: Bool?
    var singleTrack: Bool?            // imported recording: one track, no our/their split
    var source: String?               // imported file name
}

struct CallInfo: Identifiable, Equatable {
    var folder: URL
    var meta: CallMeta
    var id: String { folder.path }
    var displayName: String {
        let f = DateFormatter(); f.dateFormat = "MMM d, HH:mm"
        return "\(f.string(from: meta.start)) – \(meta.title.isEmpty ? "Call" : meta.title)"
    }
    static func == (a: CallInfo, b: CallInfo) -> Bool { a.folder == b.folder }
    var transcriptURL: URL { folder.appendingPathComponent("transcript.md") }
    var summaryURL: URL { folder.appendingPathComponent("summary.md") }
}

enum JSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}

/// A call in progress (or one that never got finalised: crash, quit, full disk).
struct WorkSession: Codable, Identifiable {
    var id: String
    var folderName: String
    var meta: CallMeta
    var state: String          // recording | stopped
    var lastUpdate: Date

    var dir: URL { AppPaths.work.appendingPathComponent(id, isDirectory: true) }
    var micRaw: URL { dir.appendingPathComponent("mic.pcm") }
    var systemRaw: URL { dir.appendingPathComponent("system.pcm") }

    static func create(title: String, theirLabel: String) throws -> WorkSession {
        let start = Date()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"; f.locale = Locale(identifier: "en_US_POSIX")
        let safe = Self.safeName(title)
        let s = WorkSession(
            id: UUID().uuidString,
            folderName: "\(f.string(from: start))_\(safe.isEmpty ? "call" : safe)",
            meta: CallMeta(title: title, ourLabel: Prefs.ourLabel, theirLabel: theirLabel, start: start,
                           language: Prefs.language),
            state: "recording", lastUpdate: start)
        try FileManager.default.createDirectory(at: s.dir, withIntermediateDirectories: true)
        try s.save()
        return s
    }

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        return s.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .prefix(60).description
    }

    func save() throws {
        try JSON.encoder.encode(self).write(to: dir.appendingPathComponent("session.json"), options: .atomic)
    }

    static func loadAll() -> [WorkSession] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: AppPaths.work, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { d in
            guard let data = try? Data(contentsOf: d.appendingPathComponent("session.json")) else { return nil }
            return try? JSON.decoder.decode(WorkSession.self, from: data)
        }.sorted { $0.meta.start < $1.meta.start }
    }

    func discard() { try? FileManager.default.removeItem(at: dir) }
}

enum CallStore {
    static func readMeta(_ folder: URL) -> CallMeta? {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent("meta.json")) else { return nil }
        return try? JSON.decoder.decode(CallMeta.self, from: d)
    }

    static func writeMeta(_ m: CallMeta, _ folder: URL) throws {
        try JSON.encoder.encode(m).write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
    }

    static func allCalls() -> [CallInfo] {
        let root = Prefs.outputFolder
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { d in readMeta(d).map { CallInfo(folder: d, meta: $0) } }
            .sorted { $0.meta.start > $1.meta.start }
    }

    static func recent(_ n: Int = 10) -> [CallInfo] { Array(allCalls().prefix(n)) }

    /// Turns a work session into a call folder: mic.m4a, system.m4a, call.m4a and
    /// meta.json. The raw files are removed only once the .m4a files read back.
    static func finalize(_ w: WorkSession) throws -> CallInfo {
        let fm = FileManager.default
        let root = Prefs.outputFolder
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var folder = root.appendingPathComponent(w.folderName, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = root.appendingPathComponent("\(w.folderName)-\(n)", isDirectory: true); n += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let micN = AudioFiles.sampleCount(w.micRaw)
        let sysN = AudioFiles.sampleCount(w.systemRaw)
        guard micN + sysN > 0 else {
            try? fm.removeItem(at: folder)
            throw CallNotesError("The recording is empty – no audio reached the disk.")
        }
        var raws: [URL] = []
        if micN > 0 { try AudioFiles.encode(raw: w.micRaw, to: folder.appendingPathComponent("mic.m4a")); raws.append(w.micRaw) }
        if sysN > 0 { try AudioFiles.encode(raw: w.systemRaw, to: folder.appendingPathComponent("system.m4a")); raws.append(w.systemRaw) }
        try AudioFiles.mix(raws: raws, to: folder.appendingPathComponent("call.m4a"))

        var meta = w.meta
        meta.end = w.meta.start.addingTimeInterval(Double(max(micN, sysN)) / PCMTrack.rate)
        try writeMeta(meta, folder)

        // Only drop the raw audio once the encoded files are readable.
        let expected = Double(max(micN, sysN)) / PCMTrack.rate
        if AudioFiles.duration(folder.appendingPathComponent("call.m4a")) > expected - 1 {
            w.discard()
        }
        return CallInfo(folder: folder, meta: meta)
    }

    /// Deletes the audio of calls older than the retention setting (0 = never).
    static func applyRetention() {
        let days = Prefs.retentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for c in allCalls() where c.meta.start < cutoff && c.meta.audioDeleted != true {
            for name in ["call.m4a", "mic.m4a", "system.m4a"] {
                try? FileManager.default.removeItem(at: c.folder.appendingPathComponent(name))
            }
            var m = c.meta; m.audioDeleted = true
            try? writeMeta(m, c.folder)
        }
    }
}
