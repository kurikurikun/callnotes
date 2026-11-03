import Foundation
import Security

/// Settings, stored in UserDefaults. The Claude API key lives in the Keychain.
enum Prefs {
    static let d = UserDefaults.standard

    enum Key {
        static let outputFolder = "outputFolder"
        static let ourLabel = "ourLabel"
        static let lastTheirLabel = "lastTheirLabel"
        static let lastTitle = "lastTitle"
        static let language = "language"              // auto | ja | en
        static let summaryLanguage = "summaryLanguage" // en | ja | both
        static let whisperModel = "whisperModel"
        static let claudeModel = "claudeModel"
        static let promptTemplate = "promptTemplate"
        static let retentionDays = "retentionDays"     // 0 = never delete
        static let welcomeDone = "welcomeDone"
    }

    static let defaultOutputFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/CallNotes").path
    static let defaultWhisperModel = "openai_whisper-large-v3-v20240930_turbo"
    static let defaultClaudeModel = "claude-sonnet-5-5"

    static let whisperModels: [(id: String, name: String)] = [
        ("openai_whisper-large-v3-v20240930_turbo", "Large v3 Turbo (best, ~1.6 GB)"),
        ("openai_whisper-large-v3-v20240930_turbo_632MB", "Large v3 Turbo compressed (~630 MB)"),
        ("openai_whisper-small", "Small (~480 MB, faster, weaker Japanese)"),
        ("openai_whisper-base", "Base (~150 MB, fastest, rough)"),
    ]

    static let defaultPrompt = """
    You are summarising a client call for move-ment, a Tokyo video production company.
    Write in {language}. Use only what is in the transcript; if something is unclear, say so.

    # {title} – {date}
    Participants: {our_label} / {their_label}

    ## Summary
    3–5 sentences: purpose of the call and the outcome.

    ## Decisions

    ## Action items
    One line each: owner – action – due date (if mentioned).

    ## Open questions

    ## Details worth keeping
    Names, numbers, dates, locations, deliverables and specs mentioned on the call,
    plus any wording the client used that we may want to quote.
    """

    static func register() {
        d.register(defaults: [
            Key.outputFolder: defaultOutputFolder,
            Key.ourLabel: "move-ment",
            Key.lastTheirLabel: "Client",
            Key.lastTitle: "",
            Key.language: "auto",
            Key.summaryLanguage: "en",
            Key.whisperModel: defaultWhisperModel,
            Key.claudeModel: defaultClaudeModel,
            Key.promptTemplate: defaultPrompt,
            Key.retentionDays: 0,
            Key.welcomeDone: false,
        ])
    }

    static var outputFolder: URL {
        let p = nonEmpty(d.string(forKey: Key.outputFolder)) ?? defaultOutputFolder
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
    }
    static var ourLabel: String { nonEmpty(d.string(forKey: Key.ourLabel)) ?? "move-ment" }
    static var language: String { d.string(forKey: Key.language) ?? "auto" }
    static var summaryLanguage: String { d.string(forKey: Key.summaryLanguage) ?? "en" }
    static var whisperModel: String { nonEmpty(d.string(forKey: Key.whisperModel)) ?? defaultWhisperModel }
    static var claudeModel: String { nonEmpty(d.string(forKey: Key.claudeModel)) ?? defaultClaudeModel }
    static var promptTemplate: String { nonEmpty(d.string(forKey: Key.promptTemplate)) ?? defaultPrompt }
    static var retentionDays: Int { d.integer(forKey: Key.retentionDays) }
    static var welcomeDone: Bool { d.bool(forKey: Key.welcomeDone) }

    /// Where a downloaded Whisper model was saved, so it can load with no network.
    static func modelPath(_ model: String) -> String? { d.string(forKey: "modelPath." + model) }
    static func setModelPath(_ model: String, _ path: String) { d.set(path, forKey: "modelPath." + model) }

    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

enum Keychain {
    static let service = "co.move-ment.callnotes"
    static let apiKeyAccount = "anthropic-api-key"

    static func get(_ account: String = apiKeyAccount) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String?, account: String = apiKeyAccount) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let v = Prefs.nonEmpty(value) else { return true }
        var add = base
        add[kSecValueData as String] = Data(v.utf8)
        add[kSecAttrLabel as String] = "CallNotes – Claude API key"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
