import AppKit
import AVFoundation
import ScreenCaptureKit
import UserNotifications

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Mode { case idle, starting, recording }
    @Published var mode: Mode = .idle
    @Published var elapsed = "0:00"
    @Published var silent = false
    @Published var jobStatus: String?
    @Published var lastFinished: CallInfo?
    @Published var recent: [CallInfo] = []
    @Published var unfinished: [WorkSession] = []

    private var recorder: CallRecorder?
    private var session: WorkSession?
    private var timer: Timer?
    private var lastSound = Date()
    private var silenceNotified = false
    private var tail: Task<Void, Never>?

    // MARK: launch

    func launch() {
        Prefs.register()
        refreshRecent()
        unfinished = WorkSession.loadAll()
        UpdateChecker.shared.start()
        Task.detached { CallStore.applyRetention() }
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkInbox() }
        }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task.detached { CallStore.applyRetention() }
        }
        if let w = unfinished.first {
            let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
            let a = NSAlert()
            a.messageText = "Recover unfinished recording?"
            a.informativeText = "“\(w.meta.title.isEmpty ? "Call" : w.meta.title)” from \(df.string(from: w.meta.start)) was not finished (the app or the Mac stopped mid-call). CallNotes can save what was recorded and transcribe it."
            a.addButton(withTitle: "Recover")
            a.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { recover(w) }
        }
    }

    func refreshRecent() { recent = CallStore.recent(10) }

    // MARK: recording

    var hasScreenAccess: Bool { CGPreflightScreenCaptureAccess() }
    var micStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    func start(title: String, theirLabel: String) async {
        guard mode == .idle else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let their = Prefs.nonEmpty(theirLabel) ?? "Client"
        Prefs.d.set(title, forKey: Prefs.Key.lastTitle)
        Prefs.d.set(their, forKey: Prefs.Key.lastTheirLabel)

        if micStatus == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        guard micStatus == .authorized else {
            alert("Microphone access is off",
                  "Turn on CallNotes in System Settings → Privacy & Security → Microphone, then start again.",
                  settingsPane: "Privacy_Microphone")
            return
        }
        guard hasScreenAccess else {
            CGRequestScreenCaptureAccess()
            alert("Allow system audio recording",
                  "CallNotes hears the other participants through macOS screen & system audio capture (no video is kept). Turn on CallNotes in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen CallNotes.",
                  settingsPane: "Privacy_ScreenCapture")
            return
        }

        mode = .starting
        var created: WorkSession?
        do {
            let w = try WorkSession.create(title: title, theirLabel: their)
            created = w
            let r = try CallRecorder(dir: w.dir)
            r.onSystemSound = { [weak self] in Task { @MainActor in self?.heardSound() } }
            r.onFailure = { [weak self] err in Task { @MainActor in self?.captureFailed(err) } }
            try await r.start()
            session = w
            recorder = r
            mode = .recording
            lastSound = Date()
            silent = false
            silenceNotified = false
            elapsed = "0:00"
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            mode = .idle
            created?.discard()
            session = nil
            recorder = nil
            alert("Could not start recording", error.localizedDescription)
        }
    }

    func stop() async {
        guard mode == .recording, let r = recorder, var w = session else { return }
        timer?.invalidate(); timer = nil
        await r.stop()
        recorder = nil
        session = nil
        mode = .idle
        silent = false
        w.state = "stopped"
        w.lastUpdate = Date()
        try? w.save()
        enqueue(w)
    }

    private func tick() {
        guard mode == .recording, var w = session else { return }
        let secs = Int(Date().timeIntervalSince(w.meta.start))
        elapsed = secs >= 3600 ? String(format: "%d:%02d:%02d", secs / 3600, (secs / 60) % 60, secs % 60)
                               : String(format: "%d:%02d", secs / 60, secs % 60)
        if secs % 10 == 0 { w.lastUpdate = Date(); session = w; try? w.save() }
        let quiet = Date().timeIntervalSince(lastSound)
        silent = quiet >= 120
        if silent && !silenceNotified {
            silenceNotified = true
            notify("No sound from the call", "Nothing has played on this Mac for 2 minutes. Check the output device, or that the call isn’t muted.")
        }
    }

    private func heardSound() {
        lastSound = Date()
        if silent { silent = false; silenceNotified = false }
    }

    private func captureFailed(_ error: Error) {
        guard mode == .recording else { return }
        Task {
            await stop()
            alert("Recording stopped", "macOS stopped the audio capture: \(error.localizedDescription)\nWhat was recorded so far is being saved.")
        }
    }

    // MARK: after the call

    func recover(_ w: WorkSession) {
        unfinished.removeAll { $0.id == w.id }
        enqueue(w)
    }

    func discard(_ w: WorkSession) {
        let a = NSAlert()
        a.messageText = "Discard this unfinished recording?"
        a.informativeText = "The recorded audio will be deleted. This can’t be undone."
        a.addButton(withTitle: "Discard"); a.addButton(withTitle: "Cancel")
        a.buttons[0].hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        w.discard()
        unfinished.removeAll { $0.id == w.id }
    }

    /// Jobs run one after another so two calls never transcribe at once.
    private func run(_ job: @escaping @MainActor () async -> Void) {
        let prev = tail
        tail = Task { @MainActor in
            await prev?.value
            await job()
        }
    }

    private func enqueue(_ w: WorkSession) {
        run { [weak self] in
            guard let self else { return }
            self.jobStatus = "Saving audio…"
            do {
                let call = try await Task.detached { try CallStore.finalize(w) }.value
                self.refreshRecent()
                if let c = await self.transcribeJob(call) { await self.summaryJob(c) }
            } catch {
                self.unfinished = WorkSession.loadAll()
                self.alert("Could not save the recording", "\(error.localizedDescription)\nThe raw audio is kept; use “Recover unfinished call” to try again.")
            }
            self.jobStatus = nil
        }
    }

    /// Imports recordings picked by hand (copied) or found in the inbox (moved).
    func importFiles(_ urls: [URL], fromInbox: Bool = false) {
        for url in urls {
            run { [weak self] in
                guard let self else { return }
                self.jobStatus = "Importing…"
                do {
                    let call = try await Importer.makeCall(from: url, move: fromInbox)
                    self.refreshRecent()
                    if let c = await self.transcribeJob(call) { await self.summaryJob(c) }
                } catch {
                    if fromInbox { self.notify("Could not import \(url.lastPathComponent)", error.localizedDescription) }
                    else { self.alert("Could not import \(url.lastPathComponent)", error.localizedDescription) }
                }
                self.jobStatus = nil
            }
        }
    }

    func chooseFilesToImport() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.audio, .movie]
        p.message = "Choose recordings to transcribe (Voice Memos, audio or video files)."
        p.prompt = "Transcribe"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { importFiles(p.urls) }
    }

    private var inboxBusy = Set<String>()
    private func checkInbox() {
        guard Importer.watchInbox, mode != .recording else { return }
        let ready = Importer.readyInboxFiles().filter { !inboxBusy.contains($0.path) }
        guard !ready.isEmpty else { return }
        ready.forEach { inboxBusy.insert($0.path) }
        importFiles(ready, fromInbox: true)
    }

    func retranscribe(_ c: CallInfo) {
        run { [weak self] in
            guard let self else { return }
            if let c = await self.transcribeJob(c) { await self.summaryJob(c) }
            self.jobStatus = nil
        }
    }

    func resummarise(_ c: CallInfo) {
        run { [weak self] in
            guard let self else { return }
            await self.summaryJob(CallInfo(folder: c.folder, meta: CallStore.readMeta(c.folder) ?? c.meta), force: true)
            self.jobStatus = nil
        }
    }

    func downloadModel() {
        run { [weak self] in
            guard let self else { return }
            let model = Prefs.whisperModel
            self.jobStatus = "Downloading model…"
            do {
                _ = try await Transcriber.shared.ensureModel(model) { p in
                    Task { @MainActor in AppState.shared.jobStatus = "Downloading model… \(Int(p * 100))%" }
                }
                self.notify("Transcription model ready", "CallNotes can now transcribe with no network.")
            } catch {
                self.alert("Model download failed", error.localizedDescription)
            }
            self.jobStatus = nil
        }
    }

    func transcribeJob(_ call: CallInfo) async -> CallInfo? {
        var meta = call.meta
        let model = Prefs.whisperModel
        do {
            jobStatus = "Loading transcription model…"
            let kit = try await Transcriber.shared.ensureModel(model) { p in
                Task { @MainActor in AppState.shared.jobStatus = "Downloading model… \(Int(p * 100))%" }
            }
            let lang: String? = meta.language == "auto" ? nil : meta.language
            let micURL = call.folder.appendingPathComponent("mic.m4a")
            let sysURL = call.folder.appendingPathComponent("system.m4a")
            // Imported recordings have only call.m4a: transcribe it as one track.
            let single = meta.singleTrack == true
            let callURL = call.folder.appendingPathComponent("call.m4a")
            let micAudio = !single && FileManager.default.fileExists(atPath: micURL.path) ? try AudioFiles.load16k(micURL) : []
            let sysAudio = single ? try AudioFiles.load16k(callURL)
                : FileManager.default.fileExists(atPath: sysURL.path) ? try AudioFiles.load16k(sysURL) : []
            let total = Double(max(1, micAudio.count + sysAudio.count))
            let micShare = Double(micAudio.count) / total

            jobStatus = "Transcribing… 0%"
            let m = try await Transcriber.shared.transcribe(micAudio, kit: kit, language: lang) { p in
                Task { @MainActor in AppState.shared.jobStatus = "Transcribing… \(Int(p * micShare * 100))%" }
            }
            let s = try await Transcriber.shared.transcribe(sysAudio, kit: kit, language: lang) { p in
                Task { @MainActor in AppState.shared.jobStatus = "Transcribing… \(Int((micShare + p * (1 - micShare)) * 100))%" }
            }
            let lines = TranscriptBuilder.merge(mic: m.segments, micAudio: micAudio, sys: s.segments, sysAudio: sysAudio,
                                                silent: single ? 0.001 : 0.003)
            meta.whisperModel = model
            meta.detectedLanguages = Array(m.languages.union(s.languages)).sorted()
            meta.transcriptStatus = "done"
            try TranscriptBuilder.markdown(lines, meta: meta).write(to: call.transcriptURL, atomically: true, encoding: .utf8)
            try CallStore.writeMeta(meta, call.folder)
            refreshRecent()
            return CallInfo(folder: call.folder, meta: meta)
        } catch {
            meta.transcriptStatus = "failed: \(error.localizedDescription)"
            try? CallStore.writeMeta(meta, call.folder)
            refreshRecent()
            notify("Transcription failed", "\(error.localizedDescription) – the audio is saved; use Recent calls → Transcribe again.")
            return nil
        }
    }

    private func summaryJob(_ call: CallInfo, force: Bool = false) async {
        var meta = call.meta
        guard let transcript = try? String(contentsOf: call.transcriptURL, encoding: .utf8) else {
            alert("No transcript yet", "Transcribe this call first.")
            return
        }
        jobStatus = "Summarising…"
        do {
            switch try await Summarizer.summarise(meta: meta, transcript: transcript) {
            case .done(let text):
                var doc = text
                if Prefs.d.object(forKey: "appendTranscript") as? Bool ?? true {
                    doc += "\n\n---\n\n## Full transcript\n\n" + TranscriptBuilder.body(transcript)
                }
                try doc.write(to: call.summaryURL, atomically: true, encoding: .utf8)
                meta.summaryStatus = "done"
                meta.claudeModel = Prefs.claudeModel
                meta.summaryLanguage = Prefs.summaryLanguage
                notifyDone(CallInfo(folder: call.folder, meta: meta), "Call notes ready",
                           meta.title.isEmpty ? "Summary saved." : "“\(meta.title)” – summary saved.")
            case .skipped(let why):
                meta.summaryStatus = "skipped: \(why)"
                if force { alert("Summary not made", why == "no API key" ? "Add your Claude API key in Settings first." : "No network connection. Try again when online.") }
                else { notifyDone(CallInfo(folder: call.folder, meta: meta), "Transcript saved", "Summary skipped (\(why)). Run it later from Recent calls.") }
            }
        } catch {
            meta.summaryStatus = "failed: \(error.localizedDescription)"
            notify("Summary failed", error.localizedDescription)
        }
        try? CallStore.writeMeta(meta, call.folder)
        lastFinished = CallInfo(folder: call.folder, meta: meta)
        refreshRecent()
    }

    // MARK: helpers

    func open(_ c: CallInfo) { NSWorkspace.shared.open(c.folder) }

    func copyTranscript(_ c: CallInfo) {
        guard let s = try? String(contentsOf: c.transcriptURL, encoding: .utf8) else {
            alert("No transcript yet", "This call has no transcript.md.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func copySummary(_ c: CallInfo) {
        guard let s = try? String(contentsOf: c.summaryURL, encoding: .utf8) else {
            alert("No summary yet", "This call has no summary.md.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func alert(_ title: String, _ text: String, settingsPane: String? = nil) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        if settingsPane != nil { a.addButton(withTitle: "Open System Settings") }
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn, let pane = settingsPane,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// "Done" message: a notification if they're allowed, otherwise a small
    /// popup with Open notes, so the end of processing is never silent.
    func notifyDone(_ c: CallInfo, _ title: String, _ body: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized && settings.alertStyle != .none
            Task { @MainActor in
                if allowed { self.notify(title, body); return }
                let a = NSAlert()
                a.messageText = title
                a.informativeText = body
                a.addButton(withTitle: "Open notes")
                a.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn { self.open(c) }
            }
        }
    }

    func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
