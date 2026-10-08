import Foundation

/// Configuration is read from ~/.config/voice-shim/config.json.
/// Every field is optional; missing fields take the defaults below.
struct Config: Codable {
    /// superterm — POST the text into a superterm session (default; no
    ///             permissions beyond the microphone)
    /// paste     — clipboard + synthetic Cmd+V (requires Accessibility)
    /// clipboard — copy to clipboard only
    var mode: String = "superterm"

    /// Base URL of the superterm server, e.g. "https://wm.example.com"
    var serverURL: String?
    /// Bearer token for the superterm HTTP API
    var token: String?
    /// Target session name for superterm mode
    var session: String?

    /// Clean up raw ASR text via an OpenAI-compatible chat-completions
    /// endpoint before delivery (same shape as superterm's polish step).
    /// Fails open: on any error or timeout the raw text is delivered instead.
    var polish: Bool = false
    var polishEndpoint: String?
    var polishModel: String = "local-speech-polish"
    var polishToken: String?
    var polishTimeoutSeconds: Double = 3.0

    /// Live cumulative transcript preview while recording (shown in a
    /// floating HUD), matching the web UI's dictation overlay.
    var preview: Bool = true
    var previewSeconds: Double = 1.0

    /// Hold-to-talk hotkey. Defaults to Option+Space (keyCode 49 = Space).
    /// Modifiers: any of "command", "option", "control", "shift".
    var keyCode: UInt32 = 49
    var modifiers: [String] = ["option"]

    /// Hard cap on a single utterance.
    var maxSeconds: Double = 120

    static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voice-shim/config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: path),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config()
        }
        return cfg
    }

    // Codable with defaults: decode each field if present, else keep default.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? d.mode
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        polish = try c.decodeIfPresent(Bool.self, forKey: .polish) ?? d.polish
        polishEndpoint = try c.decodeIfPresent(String.self, forKey: .polishEndpoint)
        polishModel = try c.decodeIfPresent(String.self, forKey: .polishModel) ?? d.polishModel
        polishToken = try c.decodeIfPresent(String.self, forKey: .polishToken)
        polishTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .polishTimeoutSeconds) ?? d.polishTimeoutSeconds
        preview = try c.decodeIfPresent(Bool.self, forKey: .preview) ?? d.preview
        previewSeconds = try c.decodeIfPresent(Double.self, forKey: .previewSeconds) ?? d.previewSeconds
        keyCode = try c.decodeIfPresent(UInt32.self, forKey: .keyCode) ?? d.keyCode
        modifiers = try c.decodeIfPresent([String].self, forKey: .modifiers) ?? d.modifiers
        maxSeconds = try c.decodeIfPresent(Double.self, forKey: .maxSeconds) ?? d.maxSeconds
    }
}
