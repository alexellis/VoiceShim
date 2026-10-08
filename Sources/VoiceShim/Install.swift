import Foundation
import Security

/// `voice-shim --install` sets VoiceShim up as superterm's speech daemon on
/// this Mac: a bearer token if there is none, and a LaunchAgent that starts
/// `--speechd` at login and restarts it if it stops. `--uninstall` removes
/// the agent and leaves the token.
enum Install {
    static let label = "com.openfaas.VoiceShim.speechd"
    static let listen = "127.0.0.1:8765"

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var plistURL: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    static var tokenURL: URL { home.appendingPathComponent(".superterm/speechd-token") }
    static var logURL: URL { home.appendingPathComponent("Library/Logs/VoiceShim-speechd.log") }

    static func install() -> Int32 {
        do {
            let created = try ensureToken()
            // The binary as it lives now, inside the app bundle: move the
            // app later and run --install again.
            let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [exe, "--speechd", "--listen", listen, "--token-file", tokenURL.path],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ProcessType": "Interactive",
                "StandardOutPath": logURL.path,
                "StandardErrorPath": logURL.path,
            ]
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)

            let domain = "gui/\(getuid())"
            // An older install, if any. bootout returns before launchd has
            // finished tearing it down, and a bootstrap in that window is
            // undone by the teardown: wait until it is gone.
            if launchctl(["print", "\(domain)/\(label)"]) == 0 {
                _ = launchctl(["bootout", "\(domain)/\(label)"])
                for _ in 0..<50 where launchctl(["print", "\(domain)/\(label)"]) == 0 {
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
            guard launchctl(["bootstrap", domain, plistURL.path]) == 0 else {
                print("launchctl could not load \(plistURL.path); see \(logURL.path)")
                return 1
            }
            Thread.sleep(forTimeInterval: 1)
            guard launchctl(["print", "\(domain)/\(label)"]) == 0 else {
                print("the agent loaded, then stopped; see \(logURL.path)")
                return 1
            }
            print("""
            VoiceShim speechd is installed and starting on http://\(listen)
              agent: \(plistURL.path)
              log:   \(logURL.path)
              token: \(tokenURL.path)\(created ? " (new)" : "")
            """)
            // superterm speechd init writes the config itself.
            if CommandLine.arguments.contains("--no-config-hint") { return 0 }
            print("""

            The first start downloads the speech models (about 1GB) before it
            answers; follow the log to watch. Then add this to
            ~/.superterm/config.yaml and restart superterm:

              speech:
                endpoint: http://\(listen)
                readback_endpoint: http://\(listen)
                token_file: ~/.superterm/speechd-token
            """)
            return 0
        } catch {
            print("install: \(error.localizedDescription)")
            return 1
        }
    }

    static func uninstall() -> Int32 {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        print("VoiceShim speechd removed. The token at \(tokenURL.path) is kept.")
        return 0
    }

    /// Creates ~/.superterm/speechd-token (0600) unless it exists. Returns
    /// whether it made one.
    static func ensureToken() throws -> Bool {
        if FileManager.default.fileExists(atPath: tokenURL.path) { return false }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NSError(domain: "Install", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no random bytes for a token"])
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tokenURL.path, contents: Data((token + "\n").utf8),
                                       attributes: [.posixPermissions: 0o600])
        return true
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return 1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
