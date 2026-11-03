import SwiftUI
import AppKit
import UserNotifications
import AVFoundation

@main
struct CallNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    init() {
        Prefs.register()
        SelfTest.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(state)
        } label: {
            MenuLabel().environmentObject(state)
        }
        .menuBarExtraStyle(.menu)

        Window("Start recording", id: "start") {
            StartView().environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("CallNotes Settings", id: "settings") {
            SettingsView().environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Welcome to CallNotes", id: "welcome") {
            WelcomeView().environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(Prefs.welcomeDone && CGPreflightScreenCaptureAccess()
                                && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .suppressed : .presented)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // A menu-bar-only app has no Edit menu, so ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z never
        // reach text fields. Route them by hand.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.shift) == .command,
                  let key = e.charactersIgnoringModifiers?.lowercased() else { return e }
            let action: Selector?
            switch key {
            case "x": action = #selector(NSText.cut(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "v": action = #selector(NSText.paste(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            case "z": action = e.modifierFlags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
            default: action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: nil) { return nil }
            return e
        }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Task { @MainActor in AppState.shared.launch() }
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppState.shared.mode == .recording else { return .terminateNow }
        Task { @MainActor in
            await AppState.shared.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

enum Icons {
    /// The whole menu bar item as ONE image (symbol + optional text). Keeping the
    /// SwiftUI label a single Image stops macOS from removing and re-adding the
    /// status item when the state changes (which made it vanish for a while).
    /// Drawn lazily, so the text colour follows the menu bar's light/dark look.
    static func label(_ symbol: String, color: NSColor? = nil, text: String? = nil) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .regular), weight: .regular)
        let symCfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(color.map { NSImage.SymbolConfiguration(paletteColors: [$0]) } ?? NSImage.SymbolConfiguration())
        let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: text ?? "CallNotes")?
            .withSymbolConfiguration(symCfg) ?? NSImage()
        let textSize = text.map { ($0 as NSString).size(withAttributes: [.font: font]) } ?? .zero
        let gap: CGFloat = text == nil ? 0 : 4
        let size = NSSize(width: ceil(sym.size.width + gap + textSize.width), height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            let symY = (size.height - sym.size.height) / 2
            if color == nil {
                sym.draw(in: NSRect(x: 0, y: symY, width: sym.size.width, height: sym.size.height))
            } else {
                sym.draw(at: NSPoint(x: 0, y: symY), from: .zero, operation: .sourceOver, fraction: 1)
            }
            if let text {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color == nil ? NSColor.black : NSColor.labelColor]
                (text as NSString).draw(at: NSPoint(x: sym.size.width + gap, y: (size.height - textSize.height) / 2), withAttributes: attrs)
            }
            return true
        }
        img.isTemplate = color == nil // black + template = follows menu bar colour
        return img
    }
}

struct MenuLabel: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Image(nsImage: image)
    }

    private var image: NSImage {
        switch state.mode {
        case .recording:
            return state.silent
                ? Icons.label("exclamationmark.circle.fill", color: .systemOrange, text: state.elapsed)
                : Icons.label("record.circle.fill", color: .systemRed, text: state.elapsed)
        case .starting:
            return Icons.label("record.circle")
        case .idle:
            if let job = state.jobStatus {
                return Icons.label("waveform.badge.ellipsis", text: job.replacingOccurrences(of: "…", with: ""))
            }
            return Icons.label("waveform")
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch state.mode {
        case .idle:
            Button("Start recording…") { show("start") }
                .keyboardShortcut("r")
        case .starting:
            Text("Starting…")
        case .recording:
            Text("Recording  \(state.elapsed)")
            if state.silent {
                Text("⚠︎ No sound from the call for 2 minutes")
            }
            Button("Stop recording") { Task { await state.stop() } }
                .keyboardShortcut("s")
        }

        if let s = state.jobStatus {
            Divider()
            Text(s)
        }

        if let c = state.lastFinished {
            Divider()
            Text(c.displayName)
            Button("Open notes") { state.open(c) }
            Button("Copy summary") { state.copySummary(c) }
                .disabled(!FileManager.default.fileExists(atPath: c.summaryURL.path))
            Button("Copy transcript") { state.copyTranscript(c) }
                .disabled(!FileManager.default.fileExists(atPath: c.transcriptURL.path))
        }

        if !state.unfinished.isEmpty {
            Divider()
            ForEach(state.unfinished) { w in
                Menu("Recover unfinished call: \(w.meta.title.isEmpty ? "Call" : w.meta.title)") {
                    Button("Recover and transcribe") { state.recover(w) }
                    Button("Discard…") { state.discard(w) }
                }
            }
        }

        Divider()
        Menu("Recent calls") {
            if state.recent.isEmpty { Text("No calls yet") }
            ForEach(state.recent) { c in
                Menu(c.displayName) {
                    Button("Open folder") { state.open(c) }
                    Button("Copy summary") { state.copySummary(c) }
                    Button("Copy transcript") { state.copyTranscript(c) }
                    Button("Re-run summary") { state.resummarise(c) }
                    Button("Transcribe again") { state.retranscribe(c) }
                }
            }
        }
        Button("Transcribe audio file…") { state.chooseFilesToImport() }
            .disabled(state.mode != .idle)
        Button("Open inbox folder") {
            try? FileManager.default.createDirectory(at: Importer.inbox, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Importer.inbox)
        }
        Button("Open CallNotes folder") {
            try? FileManager.default.createDirectory(at: Prefs.outputFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Prefs.outputFolder)
        }
        Button("Settings…") { show("settings") }
            .keyboardShortcut(",")
        Button("Welcome & permissions…") { show("welcome") }
        Divider()
        Button("Quit CallNotes") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
