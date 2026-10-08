import AppKit
import Carbon.HIToolbox
import Foundation

/// Delivers transcribed text according to the configured mode.
enum Delivery {
    /// Delivery only — polishing happens upstream so the caller can show the
    /// polished text in the preview HUD before it lands.
    static func deliver(_ text: String, config: Config) async {
        switch config.mode {
        case "superterm":
            if await postToSuperterm(text, config: config) { return }
            // Fail open: server unreachable should never eat a dictation.
            copyToClipboard(text)
        case "clipboard":
            copyToClipboard(text)
        default: // "paste"
            pasteAtCursor(text)
        }
    }

    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Clipboard + synthetic Cmd+V. Needs Accessibility; degrades to
    /// clipboard-only when the permission has not been granted.
    static func pasteAtCursor(_ text: String) {
        copyToClipboard(text)
        guard AXIsProcessTrusted() else { return }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Optional cleanup of the raw transcript via an OpenAI-compatible
    /// chat-completions endpoint (the same shape superterm's own polish step
    /// uses). Returns nil on any failure so the caller falls back to the raw
    /// transcript — dictation must fail open.
    static func polish(_ text: String, config: Config) async -> String? {
        guard let base = config.polishEndpoint,
              let url = URL(string: base + "/v1/chat/completions") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: config.polishTimeoutSeconds)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = config.polishToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": config.polishModel,
            "temperature": 0,
            "stream": false,
            "messages": [
                ["role": "system", "content":
                    "You clean up dictated text. Fix punctuation, casing, and obvious " +
                    "mis-hearings. Do not add, remove, or reorder content. Reply with " +
                    "only the cleaned text."],
                ["role": "user", "content": text],
            ],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let polished = (message["content"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !polished.isEmpty else {
            return nil
        }
        return polished
    }

    /// Sends the text into a superterm pane via the queued-sends API.
    /// Server and token come from explicit config or Discovery; the target
    /// defaults to the session the user last viewed (web UI or TUI), whose
    /// active tmux pane the server resolves itself. pressEnter is always
    /// false — dictation must never auto-submit.
    static func postToSuperterm(_ text: String, config: Config) async -> Bool {
        guard let server = Discovery.resolve(config: config) else { return false }
        var session = config.session
        if session == nil {
            session = await Discovery.lastViewedSession(server: server)
        }
        guard let session else { return false }

        func post(_ path: String, _ payload: [String: Any]) async -> [String: Any]? {
            guard let url = URL(string: server.baseURL + path) else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 5)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }

        guard let created = await post("/api/queued-sends",
                                       ["session": session, "message": text,
                                        "pressEnter": false]) else {
            return false
        }
        // Fire it now rather than leaving it queued behind agent-idle rules.
        if let id = created["id"] as? String {
            _ = await post("/api/queued-sends/send", ["id": id])
        }
        return true
    }
}
