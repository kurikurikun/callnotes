import SwiftUI
import AppKit
import AVFoundation

struct StartView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var title = Prefs.d.string(forKey: Prefs.Key.lastTitle) ?? ""
    @State private var their = Prefs.d.string(forKey: Prefs.Key.lastTheirLabel) ?? "Client"
    @State private var fromCalendar: String?
    @State private var calStatus = CalendarLink.status

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                TextField("Call title", text: $title, prompt: Text("e.g. Maersk kickoff"))
                TextField("Their side", text: $their, prompt: Text("Client"))
            }
            if CalendarLink.enabled && calStatus == .fullAccess {
                HStack {
                    Label(fromCalendar.map { "From your calendar: \($0)" } ?? "No meeting in your calendar right now.",
                          systemImage: "calendar")
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer()
                    let events = CalendarLink.nearby()
                    if !events.isEmpty {
                        Menu("Pick…") {
                            ForEach(Array(events.enumerated()), id: \.offset) { _, ev in
                                Button("\(Self.time.string(from: ev.start))  \(ev.eventTitle.isEmpty ? "(no title)" : ev.eventTitle)") { use(ev) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            } else if CalendarLink.enabled && calStatus == .notDetermined {
                Button {
                    Task {
                        _ = await CalendarLink.requestAccess()
                        calStatus = CalendarLink.status
                        fillFromCalendar()
                    }
                } label: { Label("Fill in from my calendar", systemImage: "calendar") }
                .buttonStyle(.link)
            }
            Label("Let participants know this call is being recorded.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
                .font(.callout)
            HStack {
                Spacer()
                Button("Cancel") { dismissWindow(id: "start") }
                    .keyboardShortcut(.cancelAction)
                Button("Start recording") {
                    dismissWindow(id: "start")
                    Task { await state.start(title: title, theirLabel: their) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            title = Prefs.d.string(forKey: Prefs.Key.lastTitle) ?? ""
            their = Prefs.d.string(forKey: Prefs.Key.lastTheirLabel) ?? "Client"
            calStatus = CalendarLink.status
            fillFromCalendar()
        }
    }

    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    private func fillFromCalendar() {
        fromCalendar = nil
        if let s = CalendarLink.current() { use(s) }
    }

    private func use(_ s: CalendarLink.Suggestion) {
        if !s.title.isEmpty { title = s.title }
        if let t = s.theirLabel { their = t }
        fromCalendar = "“\(s.eventTitle)” at \(Self.time.string(from: s.start))"
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage(Prefs.Key.outputFolder) private var outputFolder = Prefs.defaultOutputFolder
    @AppStorage(Prefs.Key.ourLabel) private var ourLabel = "move-ment"
    @AppStorage(Prefs.Key.lastTheirLabel) private var theirLabel = "Client"
    @AppStorage(Prefs.Key.language) private var language = "auto"
    @AppStorage(Prefs.Key.summaryLanguage) private var summaryLanguage = "en"
    @AppStorage(Prefs.Key.whisperModel) private var whisperModel = Prefs.defaultWhisperModel
    @AppStorage(Prefs.Key.claudeModel) private var claudeModel = Prefs.defaultClaudeModel
    @AppStorage(Prefs.Key.promptTemplate) private var prompt = Prefs.defaultPrompt
    @AppStorage(Prefs.Key.retentionDays) private var retentionDays = 0
    @AppStorage("useCalendar") private var useCalendar = true
    @AppStorage("appendTranscript") private var appendTranscript = true
    @AppStorage("watchInbox") private var watchInbox = true
    @State private var apiKey = ""
    @State private var hasKey = Keychain.get() != nil

    var body: some View {
        TabView {
            Form {
                LabeledContent("Save calls in") {
                    HStack {
                        Text(outputFolder).lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .leading)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                TextField("Our side label", text: $ourLabel)
                TextField("Their side label (default)", text: $theirLabel)
                Toggle("Transcribe recordings dropped in the _inbox folder", isOn: $watchInbox)
                Text("Put Voice Memos or other recordings in “_inbox” inside the CallNotes folder (on iPhone: Share → Save to Files). They’re moved into their own call folder and transcribed.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Fill in title and their side from my calendar", isOn: $useCalendar)
                    .onChange(of: useCalendar) { if useCalendar { Task { _ = await CalendarLink.requestAccess() } } }
                Picker("Delete audio after", selection: $retentionDays) {
                    Text("Never").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                Text("Only the .m4a files are deleted; transcripts and summaries stay.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Picker("Call language", selection: $language) {
                    Text("Auto (handles Japanese/English switching)").tag("auto")
                    Text("Japanese").tag("ja")
                    Text("English").tag("en")
                }
                Picker("Whisper model", selection: $whisperModel) {
                    ForEach(Prefs.whisperModels, id: \.id) { Text($0.name).tag($0.id) }
                }
                HStack {
                    Text(Prefs.modelPath(whisperModel).map { FileManager.default.fileExists(atPath: $0) } == true
                         ? "Downloaded – works offline." : "Not downloaded yet.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Download now") { state.downloadModel() }
                        .disabled(state.jobStatus != nil)
                }
            }
            .tabItem { Label("Transcription", systemImage: "waveform") }

            Form {
                LabeledContent {
                    HStack {
                        SecureField(hasKey ? "Paste a new key to replace it" : "Paste your key here", text: $apiKey)
                            .frame(width: 220)
                        Button("Paste") {
                            if let k = NSPasteboard.general.string(forType: .string)?
                                .trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
                                apiKey = k
                            }
                        }
                        Button("Save") {
                            if Keychain.set(apiKey) { hasKey = Keychain.get() != nil; apiKey = "" }
                        }.disabled(apiKey.isEmpty)
                        if hasKey {
                            Button("Remove") { Keychain.set(nil); hasKey = false }
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude API key")
                        Label(hasKey ? "Saved in Keychain" : "No key saved – summaries are skipped",
                              systemImage: hasKey ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(hasKey ? .green : .orange)
                    }
                }
                TextField("Claude model", text: $claudeModel)
                Toggle("Add the full transcript at the end of summary.md", isOn: $appendTranscript)
                Picker("Summary language", selection: $summaryLanguage) {
                    Text("English").tag("en")
                    Text("Japanese").tag("ja")
                    Text("Both").tag("both")
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("Prompt template")
                        Spacer()
                        Button("Reset") { prompt = Prefs.defaultPrompt }
                    }
                    TextEditor(text: $prompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 220)
                    Text("Placeholders: {language} {title} {date} {our_label} {their_label}. The transcript is added after the template.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("Summary", systemImage: "text.alignleft") }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
        .onChange(of: outputFolder) { state.refreshRecent() }
        .onChange(of: retentionDays) { Task.detached { CallStore.applyRetention() } }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Use this folder"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { outputFolder = u.path }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var screen = CGPreflightScreenCaptureAccess()
    @State private var cal = CalendarLink.status

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CallNotes records your online calls from the menu bar, transcribes them on this Mac, and writes a short summary with Claude. No bot joins the call.")
                .fixedSize(horizontal: false, vertical: true)

            step(done: mic == .authorized, title: "Microphone",
                 text: "Records your side of the call.") {
                Task {
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                    mic = AVCaptureDevice.authorizationStatus(for: .audio)
                    if mic == .denied { openPane("Privacy_Microphone") }
                }
            }
            step(done: screen, title: "Screen & System Audio Recording",
                 text: "Records what the other participants say, by capturing the sound this Mac plays. No video is kept. After you turn it on, macOS quits and reopens CallNotes – that’s normal, and this window comes back.") {
                if !CGRequestScreenCaptureAccess() { openPane("Privacy_ScreenCapture") }
                screen = CGPreflightScreenCaptureAccess()
            }
            step(done: Prefs.modelPath(Prefs.whisperModel) != nil, title: "Transcription model",
                 text: "Downloads once (about 1.6 GB), then transcription works with no network. A smaller model can be picked in Settings.", button: "Download") {
                state.downloadModel()
            }
            step(done: cal == .fullAccess, title: "Calendar (optional)",
                 text: "Fills in the call title and the other side’s company from the meeting in your calendar. Read-only.") {
                Task { _ = await CalendarLink.requestAccess(); cal = CalendarLink.status }
            }
            if let s = state.jobStatus { Text(s).font(.callout).foregroundStyle(.secondary) }

            Text("Add your Claude API key in Settings → Summary to get summaries.")
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Done") {
                    Prefs.d.set(true, forKey: Prefs.Key.welcomeDone)
                    dismissWindow(id: "welcome")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            mic = AVCaptureDevice.authorizationStatus(for: .audio)
            screen = CGPreflightScreenCaptureAccess()
            cal = CalendarLink.status
        }
    }

    private func step(done: Bool, title: String, text: String, button: String = "Allow", action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !done { Button(button, action: action) }
        }
    }

    private func openPane(_ pane: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(u)
        }
    }
}
