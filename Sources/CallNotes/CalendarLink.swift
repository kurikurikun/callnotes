import EventKit
import Foundation

/// Reads the Mac's Calendar (iCloud, Google, Exchange… whatever is added in
/// System Settings → Internet Accounts) to prefill the call title and the
/// their-side label. Read-only.
enum CalendarLink {
    static let store = EKEventStore()

    struct Suggestion {
        var title: String
        var theirLabel: String?
        var eventTitle: String
        var start: Date
    }

    static var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    static var enabled: Bool { Prefs.d.object(forKey: "useCalendar") as? Bool ?? true }

    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// The meeting happening now (or starting within 15 minutes). Prefers events
    /// with a Meet / Teams / Zoom link, then the one whose start is closest.
    static func current() -> Suggestion? {
        guard enabled, status == .fullAccess else { return nil }
        let now = Date()
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-4 * 3600),
                                            end: now.addingTimeInterval(15 * 60), calendars: nil)
        let events = store.events(matching: pred).filter { e in
            !e.isAllDay && e.endDate > now.addingTimeInterval(-5 * 60) && e.startDate < now.addingTimeInterval(15 * 60)
                && e.status != .canceled
        }
        let best = events.max { a, b in score(a, now) < score(b, now) }
        guard let e = best else { return nil }
        let title = (e.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Suggestion(title: title, theirLabel: theirLabel(e), eventTitle: title, start: e.startDate)
    }

    /// The meeting that overlaps a past recording the most (for imports).
    static func event(at start: Date, duration: Double) -> Suggestion? {
        guard enabled, status == .fullAccess else { return nil }
        let end = start.addingTimeInterval(max(duration, 60))
        let pred = store.predicateForEvents(withStart: start.addingTimeInterval(-3600), end: end.addingTimeInterval(3600), calendars: nil)
        func overlap(_ e: EKEvent) -> Double { min(e.endDate, end).timeIntervalSince(max(e.startDate, start)) }
        guard let e = store.events(matching: pred).filter({ !$0.isAllDay && $0.status != .canceled && overlap($0) > 0 })
                .max(by: { overlap($0) < overlap($1) }) else { return nil }
        let t = (e.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Suggestion(title: t, theirLabel: theirLabel(e), eventTitle: t, start: e.startDate)
    }

    /// Timed events from 12 hours ago to 12 hours ahead, for picking by hand.
    static func nearby() -> [Suggestion] {
        guard enabled, status == .fullAccess else { return [] }
        let now = Date()
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600),
                                            end: now.addingTimeInterval(12 * 3600), calendars: nil)
        return store.events(matching: pred)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .map { e in
                let t = (e.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return Suggestion(title: t, theirLabel: theirLabel(e), eventTitle: t, start: e.startDate)
            }
    }

    private static func score(_ e: EKEvent, _ now: Date) -> Double {
        let text = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ").lowercased()
        let online = ["meet.google.com", "teams.microsoft.com", "teams.live.com", "zoom.us", "webex.com"].contains { text.contains($0) }
        return (online ? 10_000 : 0) - abs(e.startDate.timeIntervalSince(now)) / 60
    }

    /// Company names from guests' email domains, skipping our own and free mail.
    static func theirLabel(_ e: EKEvent) -> String? {
        let ours: Set<String> = ["move-ment.co", "filminginjapan.com"]
        let free: Set<String> = ["gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com",
                                 "hotmail.com", "live.com", "yahoo.com", "yahoo.co.jp", "docomo.ne.jp",
                                 "ezweb.ne.jp", "softbank.ne.jp", "proton.me", "protonmail.com"]
        var names: [String] = []
        for a in e.attendees ?? [] {
            let url = a.url.absoluteString.lowercased()
            guard url.hasPrefix("mailto:"), let at = url.firstIndex(of: "@") else { continue }
            let domain = String(url[url.index(after: at)...])
            if ours.contains(domain) || free.contains(domain) || domain.hasSuffix("calendar.google.com") { continue }
            let name = company(domain)
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? nil : names.prefix(3).joined(separator: " / ")
    }

    /// "jp.maersk.com" → "Maersk", "ykk.co.jp" → "YKK".
    static func company(_ domain: String) -> String {
        var parts = domain.split(separator: ".").map(String.init)
        let suffixes: Set<String> = ["com", "co", "jp", "net", "org", "io", "ne", "or", "ac", "go", "uk", "de", "fr", "us", "cn", "sg", "au", "inc", "biz", "tv"]
        while let last = parts.last, suffixes.contains(last), parts.count > 1 { parts.removeLast() }
        guard let core = parts.last else { return "" }
        return core.count <= 4 ? core.uppercased() : core.prefix(1).uppercased() + core.dropFirst()
    }
}
