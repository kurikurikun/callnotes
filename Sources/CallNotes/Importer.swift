import AVFoundation
import Foundation

/// Brings an existing recording (a Voice Memo, a video, any audio file) in as a
/// call: one folder with call.m4a + meta.json, then the usual transcript and
/// summary. A single recording has no our/their split, so the transcript has
/// timestamps without speaker labels.
enum Importer {
    static let exts: Set<String> = ["m4a", "mp3", "wav", "aif", "aiff", "caf", "aac", "mp4", "mov", "m4v", "qta", "3gp"]

    /// `<output>/_inbox` – drop recordings here (e.g. Voice Memos → Share → Save
    /// to Files → Google Drive) and CallNotes picks them up.
    static var inbox: URL { Prefs.outputFolder.appendingPathComponent("_inbox", isDirectory: true) }
    static var watchInbox: Bool { Prefs.d.object(forKey: "watchInbox") as? Bool ?? true }

    /// When the recording was made: the file's own creation-date metadata
    /// (Voice Memos and cameras write it), else file modification time minus
    /// its length, else now.
    static func recordingStart(_ url: URL) async -> (Date, Double) {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        if let item = try? await asset.load(.creationDate), let d = try? await item.load(.dateValue) {
            return (d, duration)
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let m = attrs?[.modificationDate] as? Date { return (m.addingTimeInterval(-duration), duration) }
        return (Date().addingTimeInterval(-duration), duration)
    }

    /// Creates the call folder. `move` = take the file out of the inbox rather
    /// than copy it (never used for files picked by hand).
    static func makeCall(from src: URL, move: Bool) async throws -> CallInfo {
        guard exts.contains(src.pathExtension.lowercased()) else {
            throw CallNotesError("\(src.lastPathComponent) isn’t an audio or video file CallNotes can read.")
        }
        let (start, duration) = await recordingStart(src)
        guard duration > 1 else { throw CallNotesError("\(src.lastPathComponent) has no audio.") }

        // Title and their side from the calendar meeting at that time, else the file name.
        let fileTitle = src.deletingPathExtension().lastPathComponent
        let ev = CalendarLink.event(at: start, duration: duration)
        let title = Prefs.nonEmpty(ev?.title) ?? fileTitle

        let fm = FileManager.default
        let root = Prefs.outputFolder
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"; f.locale = Locale(identifier: "en_US_POSIX")
        let base = "\(f.string(from: start))_\(WorkSession.safeName(title).isEmpty ? "recording" : WorkSession.safeName(title))"
        var folder = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) { folder = root.appendingPathComponent("\(base)-\(n)", isDirectory: true); n += 1 }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let dst = folder.appendingPathComponent("call.m4a")
        do {
            if src.pathExtension.lowercased() == "m4a" {
                if move { try fm.moveItem(at: src, to: dst) } else { try fm.copyItem(at: src, to: dst) }
            } else {
                guard let ex = AVAssetExportSession(asset: AVURLAsset(url: src), presetName: AVAssetExportPresetAppleM4A) else {
                    throw CallNotesError("Cannot convert \(src.lastPathComponent).")
                }
                try await ex.export(to: dst, as: .m4a)
                if move { try? fm.removeItem(at: src) }
            }
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }

        let meta = CallMeta(title: title, ourLabel: Prefs.ourLabel, theirLabel: ev?.theirLabel ?? "",
                            start: start, end: start.addingTimeInterval(duration), language: Prefs.language,
                            singleTrack: true, source: src.lastPathComponent)
        try CallStore.writeMeta(meta, folder)
        return CallInfo(folder: folder, meta: meta)
    }

    /// Audio files in the inbox whose size hasn't changed since the last look
    /// (so a file still syncing from Google Drive isn't grabbed half-written).
    private static var lastSizes: [String: Int64] = [:]
    static func readyInboxFiles() -> [URL] {
        let fm = FileManager.default
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var ready: [URL] = [], sizes: [String: Int64] = [:]
        for u in files where exts.contains(u.pathExtension.lowercased()) && !u.lastPathComponent.hasPrefix(".") {
            let size = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            sizes[u.path] = size
            if size > 0, lastSizes[u.path] == size { ready.append(u) }
        }
        lastSizes = sizes
        return ready
    }
}
