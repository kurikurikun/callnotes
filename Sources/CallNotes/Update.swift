import Foundation
import AppKit
import Security
import os

/// Checks GitHub Releases for a newer CallNotes: at launch, whenever the
/// menu-bar menu opens (throttled), and hourly. Install = download the zip,
/// verify it is signed by our Developer ID team, swap it into place, relaunch.
/// Public API, no auth, fails silently offline. Same design as Peripheral Speed.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var latest: (version: String, url: String)?
    @Published var updating = false
    @Published var updateError: String?

    private var timer: Timer?
    private var menuObserver: NSObjectProtocol?
    private var lastCheck = Date.distantPast
    private static let log = Logger(subsystem: "co.move-ment.callnotes", category: "update")

    nonisolated static let releasesAPI = "https://api.github.com/repos/kurikurikun/callnotes/releases/latest"
    nonisolated static let downloadURL = "https://github.com/kurikurikun/callnotes/releases/latest/download/CallNotes.zip"
    nonisolated static let teamID = "PNDN4CQY5T"
    nonisolated static let appName = "CallNotes.app"

    func start() {
        check()
        if menuObserver == nil {
            // The MenuBarExtra(.menu) is an NSMenu; this fires each time it opens.
            menuObserver = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
            ) { _ in Task { @MainActor in UpdateChecker.shared.check() } }
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in UpdateChecker.shared.check() }
        }
    }

    func check() {
        guard Date().timeIntervalSince(lastCheck) > 30 else { return }
        lastCheck = Date()
        guard let url = URL(string: Self.releasesAPI) else { return }
        Self.log.info("checking for updates")
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String,
                  let html = obj["html_url"] as? String else { return }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard Self.isNewer(version, than: AppInfo.version) else { return }
            Task { @MainActor in UpdateChecker.shared.latest = (version, html) }
        }.resume()
    }

    /// Download, verify, swap, relaunch. Any failure leaves the current app as it is.
    func installUpdate() {
        guard !updating else { return }
        updating = true
        updateError = nil
        Task.detached {
            let error = Self.performUpdate()
            await MainActor.run {
                UpdateChecker.shared.updating = false
                UpdateChecker.shared.updateError = error   // on success we never get here
            }
        }
    }

    /// Returns nil on success (the app then quits so the helper can swap it).
    nonisolated static func performUpdate() -> String? {
        let currentPath = Bundle.main.bundlePath
        guard currentPath.hasSuffix(appName) else {
            return "Not running from an installed app — update manually."
        }
        guard let url = URL(string: downloadURL) else { return "Bad update URL." }
        let sem = DispatchSemaphore(value: 0)
        var zipData: Data?
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 { zipData = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 180)
        guard let zipData, zipData.count > 100_000 else {
            return "Couldn't download the update — check your connection."
        }
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cnupdate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let zipPath = work.appendingPathComponent("update.zip")
        do { try zipData.write(to: zipPath) } catch { return "Couldn't save the update." }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-xk", zipPath.path, work.path]
        try? unzip.run()
        unzip.waitUntilExit()
        let newApp = work.appendingPathComponent(appName)
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            return "Update package looked wrong — not installed."
        }
        // Valid signature AND our Developer ID team, or we refuse.
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(newApp as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return "Couldn't inspect the update's signature." }
        var requirement: SecRequirement?
        let req = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"" as CFString
        guard SecRequirementCreateWithString(req, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
                                         requirement) == errSecSuccess else {
            return "Update failed signature verification — not installed."
        }
        let staged = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cnnew-\(UUID().uuidString).app")
        do { try FileManager.default.moveItem(at: newApp, to: staged) }
        catch { return "Couldn't stage the update." }

        // A detached shell does the swap after we quit: a running GUI app is
        // blocked from replacing an app in /Applications, a plain mv is not.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        /bin/rm -rf \(shellQuote(currentPath))
        /bin/mv \(shellQuote(staged.path)) \(shellQuote(currentPath))
        /usr/bin/xattr -dr com.apple.quarantine \(shellQuote(currentPath)) 2>/dev/null
        /usr/bin/open -n \(shellQuote(currentPath))
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do { try helper.run() } catch { return "Couldn't start the updater helper." }
        DispatchQueue.main.async { exit(0) }
        return nil
    }

    nonisolated static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
