import Foundation

/// Zero-config discovery of a superterm server from the state its own
/// clients leave behind. If superterm-tui has ever connected from this Mac,
/// the shim can too: `~/.superterm/session-<host>` files carry the host in
/// their name and a session JWT as content, and `~/.superterm/token` holds
/// the shared API token. Explicit config always wins.
enum Discovery {
    struct Server {
        let baseURL: String
        let token: String
    }

    static func resolve(config: Config) -> Server? {
        if let url = config.serverURL, let tok = config.token {
            return Server(baseURL: url, token: tok)
        }
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".superterm")

        var baseURL = config.serverURL
        var token = config.token

        // Newest session-<host> file = the server the user last logged into.
        let sessionFiles = ((try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("session-") }
        let newest = sessionFiles.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return da < db
        }
        if baseURL == nil, let newest {
            baseURL = hostToURL(String(newest.lastPathComponent.dropFirst("session-".count)))
            if token == nil {
                token = (try? String(contentsOf: newest, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if token == nil || token?.isEmpty == true {
            token = (try? String(contentsOf: dir.appendingPathComponent("token"),
                                 encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let baseURL, let token, !token.isEmpty else { return nil }
        return Server(baseURL: baseURL, token: token)
    }

    /// Session cache filenames replace ':' and '/' with '_', so a trailing
    /// numeric segment is a port. Bare hostnames default to https.
    static func hostToURL(_ host: String) -> String {
        if let idx = host.lastIndex(of: "_"),
           let port = Int(host[host.index(after: idx)...]) {
            let bare = String(host[..<idx])
            let scheme = port == 443 ? "https" : "http"
            return "\(scheme)://\(bare):\(port)"
        }
        return "https://\(host)"
    }

    /// The session the user most recently looked at. Both the web UI and a
    /// superterm-tui attach update lastViewed server-side, so "the pane I'm
    /// viewing" falls out of GET /api/sessions without any client changes.
    static func lastViewedSession(server: Server) async -> String? {
        guard let url = URL(string: server.baseURL + "/api/sessions") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let sessions = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var best: (name: String, viewed: Date)?
        for s in sessions {
            guard let name = s["name"] as? String,
                  let raw = s["lastViewed"] as? String,
                  let viewed = fractional.date(from: raw) ?? plain.date(from: raw),
                  viewed.timeIntervalSince1970 > 0 else { continue }
            if best == nil || viewed > best!.viewed {
                best = (name, viewed)
            }
        }
        return best?.name
    }
}
