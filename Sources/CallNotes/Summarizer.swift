import Foundation

/// Sends the transcript to the Claude Messages API and returns summary.md text.
enum Summarizer {
    enum Outcome { case done(String), skipped(String) }

    static func languageName(_ code: String) -> String {
        switch code {
        case "ja": return "Japanese"
        case "both": return "English, then the same summary again in Japanese"
        default: return "English"
        }
    }

    static func prompt(meta: CallMeta, transcript: String) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let filled = Prefs.promptTemplate
            .replacingOccurrences(of: "{language}", with: languageName(Prefs.summaryLanguage))
            .replacingOccurrences(of: "{title}", with: meta.title.isEmpty ? "Call" : meta.title)
            .replacingOccurrences(of: "{date}", with: df.string(from: meta.start))
            .replacingOccurrences(of: "{our_label}", with: meta.ourLabel)
            .replacingOccurrences(of: "{their_label}", with: Prefs.nonEmpty(meta.theirLabel) ?? "others (not named)")
        let note = meta.singleTrack == true
            ? "\n\nNote: this is a single-microphone recording (e.g. an in-person meeting) with no speaker labels. Attribute statements to people only where the transcript makes it clear."
            : ""
        return filled + note + "\n\nHere is the transcript:\n\n<transcript>\n\(transcript)\n</transcript>"
    }

    static func summarise(meta: CallMeta, transcript: String) async throws -> Outcome {
        guard let key = Keychain.get() else { return .skipped("no API key") }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": Prefs.claudeModel,
            "max_tokens": 8_000,
            "messages": [["role": "user", "content": prompt(meta: meta, transcript: transcript)]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                                       .timedOut, .cannotConnectToHost, .dnsLookupFailed].contains(e.code) {
            return .skipped("no network")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = (json?["error"] as? [String: Any])?["message"] as? String
            throw CallNotesError("Claude API error: \(msg ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")")
        }
        let parts = (json?["content"] as? [[String: Any]]) ?? []
        let text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        guard !text.isEmpty else { throw CallNotesError("Claude returned an empty summary.") }
        return .done(text)
    }
}
