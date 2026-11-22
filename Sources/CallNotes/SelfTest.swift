import Foundation
import AppKit

/// Hidden test: `CallNotes --selftest <ours.audio> <theirs.audio> [-outputFolder dir]`
/// Fakes a crashed two-track recording (their audio also leaks into the mic at
/// low level, like speakers without headphones), then runs recovery,
/// transcription and merging exactly as the app does, and prints transcript.md.
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if args.contains("--install-update") {
            // dev/test hook: run the full self-update synchronously
            if let err = UpdateChecker.performUpdate() { print("update failed: \(err)"); exit(1) }
            print("update installed, new version launched"); exit(0)
        }
        if let i = args.firstIndex(of: "--import"), args.count > i + 1 {
            // Imports one recording like the inbox does (moves it) and prints the transcript.
            Prefs.register()
            let src = URL(fileURLWithPath: args[i + 1])
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in
                do {
                    let call = try await Importer.makeCall(from: src, move: true)
                    print("imported → \(call.folder.lastPathComponent), start \(call.meta.start), title \(call.meta.title)")
                    if let c = await AppState.shared.transcribeJob(call) {
                        print((try? String(contentsOf: c.transcriptURL, encoding: .utf8)) ?? "")
                    }
                } catch { print("IMPORT FAILED: \(error.localizedDescription)") }
                done.signal()
            }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            exit(0)
        }
        if args.contains("--calendars") {
            // Writes which calendars and today's events the app can see (titles only).
            var out = "access: \(CalendarLink.status.rawValue) (3 = full)\n"
            for c in CalendarLink.store.calendars(for: .event) {
                out += "calendar: \(c.title) [\(c.source.title)]\n"
            }
            let start = Calendar.current.startOfDay(for: Date())
            let pred = CalendarLink.store.predicateForEvents(withStart: start, end: start.addingTimeInterval(86_400), calendars: nil)
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            for e in CalendarLink.store.events(matching: pred) {
                out += "event: \(f.string(from: e.startDate))–\(f.string(from: e.endDate)) \(e.isAllDay ? "(all day) " : "")\(e.title ?? "") [\(e.calendar.title)]\n"
            }
            try? out.write(to: AppPaths.support.appendingPathComponent("calendars.txt"), atomically: true, encoding: .utf8)
            exit(0)
        }
        if let i = args.firstIndex(of: "--dump"), args.count > i + 1 {
            Prefs.register()
            let file = URL(fileURLWithPath: args[i + 1])
            let done = DispatchSemaphore(value: 0)
            Task {
                let t0 = Date()
                let kit = try await Transcriber.shared.ensureModel(Prefs.whisperModel) { _ in }
                print("model loaded in \(Int(Date().timeIntervalSince(t0))) s")
                let audio = try AudioFiles.load16k(file)
                for u in Transcriber.utterances(audio) {
                    let d = try? await kit.detectLangauge(audioArray: Array(audio[u]))
                    let top = (d?.langProbs ?? [:]).sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) \(String(format: "%.2f", $0.value))" }
                    print(String(format: "utt %.2f–%.2f", Double(u.lowerBound) / 16_000, Double(u.upperBound) / 16_000), d?.language ?? "nil", top)
                }
                let t1 = Date()
                let r = try await Transcriber.shared.transcribe(audio, kit: kit, language: nil) { _ in }
                print("transcribed \(audio.count / 16_000) s in \(Int(Date().timeIntervalSince(t1))) s, langs \(r.languages)")
                for s in r.segments {
                    print(String(format: "%.2f–%.2f rms %.4f  %@", s.0, s.1, AudioFiles.rms(audio, from: s.0, to: s.1), s.2))
                }
                done.signal()
            }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            exit(0)
        }
        guard let i = args.firstIndex(of: "--selftest"), args.count > i + 2 else { return }
        let ours = URL(fileURLWithPath: args[i + 1]), theirs = URL(fileURLWithPath: args[i + 2])
        Prefs.register()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            do { try await run(ours: ours, theirs: theirs) } catch { print("SELFTEST FAILED: \(error.localizedDescription)") ; exit(1) }
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        exit(0)
    }

    @MainActor
    static func run(ours: URL, theirs: URL) async throws {
        let a = try AudioFiles.load16k(ours, rate: 48_000)
        let b = try AudioFiles.load16k(theirs, rate: 48_000)
        let gapA = 48_000, theirStart = a.count + 2 * 48_000
        let n = theirStart + b.count + 48_000
        var mic = [Float](repeating: 0, count: n), sys = [Float](repeating: 0, count: n)
        for k in 0..<a.count { mic[gapA + k > n - 1 ? n - 1 : gapA + k] += a[k] }
        for k in 0..<b.count { sys[theirStart + k] += b[k]; mic[theirStart + k] += b[k] * 0.12 } // echo

        var w = try WorkSession.create(title: "Selftest", theirLabel: "Client")
        func raw(_ s: [Float]) -> Data {
            var d = Data(capacity: s.count * 2)
            for v in s { var x = Int16(clamping: Int(v * 32_767)); withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
            return d
        }
        try raw(mic).write(to: w.micRaw)
        try raw(sys).write(to: w.systemRaw)
        w.state = "recording"   // as if the app crashed mid-call
        try w.save()

        let found = WorkSession.loadAll().contains { $0.id == w.id }
        print("recovery found unfinished session: \(found)")
        let call = try CallStore.finalize(w)
        print("finalized → \(call.folder.path)")
        for f in ["mic.m4a", "system.m4a", "call.m4a"] {
            print("  \(f): \(String(format: "%.1f", AudioFiles.duration(call.folder.appendingPathComponent(f)))) s")
        }
        print("raw work folder removed: \(!FileManager.default.fileExists(atPath: w.dir.path))")
        let t0 = Date()
        guard let c = await AppState.shared.transcribeJob(call) else { throw CallNotesError("transcription failed: \(CallStore.readMeta(call.folder)?.transcriptStatus ?? "")") }
        print("transcribed in \(Int(Date().timeIntervalSince(t0))) s; languages: \(c.meta.detectedLanguages ?? [])")
        print("----- transcript.md -----")
        print((try? String(contentsOf: c.transcriptURL, encoding: .utf8)) ?? "")
    }
}
