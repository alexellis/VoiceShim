import AppKit
import AVFoundation
import Foundation

// CLI mode: `voice-shim --transcribe file.wav` transcribes a file and
// prints the text. Exists so the ASR path can be exercised headless (e.g. over
// ssh, where TCC microphone prompts cannot be approved).
if let idx = CommandLine.arguments.firstIndex(of: "--transcribe"),
   CommandLine.arguments.count > idx + 1 {
    let path = CommandLine.arguments[idx + 1]
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let transcriber = Transcriber()
            FileHandle.standardError.write("Loading models (first run downloads ~600MB)...\n".data(using: .utf8)!)
            try await transcriber.load()
            let samples = try loadWav16kMono(path: path)
            let start = Date()
            let text = try await transcriber.transcribe(samples)
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(start))
            FileHandle.standardError.write("Transcribed \(samples.count / 16_000)s of audio in \(elapsed)s\n".data(using: .utf8)!)
            print(text)
            exit(0)
        } catch {
            FileHandle.standardError.write("Error: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    sem.wait()
}

/// Reads any audio file AVFoundation understands and converts to 16 kHz mono.
func loadWav16kMono(path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let inFormat = file.processingFormat
    guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                        channels: 1, interleaved: false),
          let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat,
                                       frameCapacity: AVAudioFrameCount(file.length)) else {
        throw NSError(domain: "wav", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad audio format"])
    }
    try file.read(into: inBuf)
    if inFormat.sampleRate == 16_000, inFormat.channelCount == 1,
       let ch = inBuf.floatChannelData?[0] {
        return Array(UnsafeBufferPointer(start: ch, count: Int(inBuf.frameLength)))
    }
    guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
        throw NSError(domain: "wav", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot convert to 16kHz"])
    }
    let ratio = 16_000.0 / inFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 16
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
        throw NSError(domain: "wav", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate buffer"])
    }
    var fed = false
    converter.convert(to: outBuf, error: nil) { _, outStatus in
        if fed { outStatus.pointee = .endOfStream; return nil }
        fed = true
        outStatus.pointee = .haveData
        return inBuf
    }
    guard let ch = outBuf.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
}

// Daemon mode: `voice-shim --speechd [--listen 127.0.0.1:8765]
// [--token TOKEN | --token-file PATH] [--voice af_heart | --no-tts]` — serve
// the Linux speechd REST contract: Parakeet on the ANE listens, Kokoro on
// the ANE speaks. No microphone, no TCC.
// Setup: `voice-shim --install` makes this Mac's speechd start at login, as
// `superterm speechd init` does; `--uninstall` undoes it.
if CommandLine.arguments.contains("--install") { exit(Install.install()) }
if CommandLine.arguments.contains("--uninstall") { exit(Install.uninstall()) }

if CommandLine.arguments.contains("--speechd") {
    func flagValue(_ name: String) -> String? {
        guard let idx = CommandLine.arguments.firstIndex(of: name),
              CommandLine.arguments.count > idx + 1 else { return nil }
        return CommandLine.arguments[idx + 1]
    }
    let listen = flagValue("--listen") ?? "127.0.0.1:8765"
    let listenParts = listen.split(separator: ":")
    let host = listenParts.count == 2 ? String(listenParts[0]) : "127.0.0.1"
    let port = UInt16(listenParts.last.map(String.init) ?? "8765") ?? 8765
    var token = flagValue("--token")
    if token == nil, let tokenFile = flagValue("--token-file") {
        token = (try? String(contentsOfFile: (tokenFile as NSString).expandingTildeInPath,
                             encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if token?.isEmpty == true { token = nil }

    func logLine(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
    let sem = DispatchSemaphore(value: 0)
    let resolvedToken = token
    let speaker = CommandLine.arguments.contains("--no-tts")
        ? nil : Speaker(voice: flagValue("--voice") ?? "af_heart")
    Task.detached {
        do {
            let transcriber = Transcriber()
            logLine("speechd: loading Parakeet models (first run downloads ~500MB)...")
            try await transcriber.load { fraction in
                logLine(String(format: "speechd: model download %.0f%%", fraction * 100))
            }
            logLine("speechd: models ready")
            if let speaker {
                // Before listening, so the first spoken reply is not stuck
                // behind a model download.
                logLine("speechd: loading the Kokoro voice \(speaker.voice)...")
                try await speaker.load()
                logLine("speechd: voice ready")
            }
            let server = SpeechServer(transcriber: transcriber, speaker: speaker, config: Config.load(),
                                      token: resolvedToken, host: host, port: port)
            SpeechServer.retained = server
            try server.start()
            logLine("speechd listening on http://\(host):\(port) (auth \(resolvedToken == nil ? "disabled" : "enabled"))")
            logLine("speechd backend: parakeet-tdt-0.6b-v3-coreml (ane)" + (speaker == nil ? ", no tts" : ", kokoro (ane) tts"))
        } catch {
            logLine("speechd: \(error.localizedDescription)")
            exit(1)
        }
    }
    sem.wait()
}

// CLI mode: `voice-shim --send "text"` delivers text through the superterm
// API using the same discovery the app uses. Lets the delivery path be
// proven end-to-end over ssh, no microphone involved.
if let idx = CommandLine.arguments.firstIndex(of: "--send"),
   CommandLine.arguments.count > idx + 1 {
    let text = CommandLine.arguments[idx + 1]
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        var cfg = Config.load()
        cfg.mode = "superterm"
        if let server = Discovery.resolve(config: cfg) {
            FileHandle.standardError.write("server: \(server.baseURL)\n".data(using: .utf8)!)
            var session = cfg.session
            if session == nil {
                session = await Discovery.lastViewedSession(server: server)
            }
            FileHandle.standardError.write("target session: \(session ?? "?")\n".data(using: .utf8)!)
        } else {
            FileHandle.standardError.write("no server discovered\n".data(using: .utf8)!)
        }
        let ok = await Delivery.postToSuperterm(text, config: cfg)
        print(ok ? "sent" : "failed")
        exit(ok ? 0 : 1)
    }
    sem.wait()
}

// Menu-bar app mode.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let config = Config.load()
    let transcriber = Transcriber()
    let recorder = Recorder()
    let hotKey = HotKey()
    var statusItem: NSStatusItem!
    var lastTranscript = ""
    var modelsReady = false
    var recording = false
    let hud = PreviewHUD()
    var previewTimer: Timer?
    var previewInFlight = false

    // The menu is built once and mutated in place: replacing statusItem.menu
    // while the menu is open leaves the on-screen copy frozen, whereas
    // NSMenuItem title changes render live.
    let menu = NSMenu()
    let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    let copyLastItem = NSMenuItem(title: "", action: #selector(copyLast), keyEquivalent: "")
    let modeLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let axItem = NSMenuItem(title: "Grant Accessibility (needed to paste)…",
                            action: #selector(openAccessibility), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(recording: false)
        makeMenu()
        setStatus("Loading models…")

        // Left-click toggles recording (parity with the web UI's mic button);
        // right-click opens the menu.
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        Task {
            let granted = await Recorder.requestPermission()
            if !granted {
                await MainActor.run { self.setStatus("No microphone permission") }
            }
            do {
                try await transcriber.load { fraction in
                    let pct = Int(fraction * 100)
                    Task { @MainActor in
                        self.statusItem.button?.title = " \(pct)%"
                        self.setStatus("Downloading models… \(pct)%")
                    }
                }
                await MainActor.run {
                    self.modelsReady = true
                    self.statusItem.button?.title = ""
                    self.setStatus("Ready — hold \(self.hotKeyLabel()) to talk")
                }
            } catch {
                await MainActor.run {
                    self.statusItem.button?.title = ""
                    self.setStatus("Model load failed: \(error.localizedDescription)")
                }
            }
        }

        hotKey.onDown = { [weak self] in Task { @MainActor in self?.startRecording() } }
        hotKey.onUp = { [weak self] in Task { @MainActor in self?.stopRecording() } }
        let mods = HotKey.carbonModifiers(config.modifiers)
        if !hotKey.register(keyCode: config.keyCode, modifiers: mods) {
            setStatus("Hotkey registration failed")
        }

        // Accessibility is only requested when paste mode is explicitly
        // configured — the superterm default needs nothing beyond the mic.
        if config.mode == "paste", !AXIsProcessTrusted() {
            openAccessibility()
        }
    }

    func hotKeyLabel() -> String {
        let names = config.modifiers.map { $0.capitalized }.joined(separator: "+")
        let key = config.keyCode == 49 ? "Space" : "key \(config.keyCode)"
        return "\(names)+\(key)"
    }

    func startRecording() {
        guard modelsReady, !recording else { return }
        do {
            try recorder.start(maxSeconds: config.maxSeconds)
            recording = true
            setIcon(recording: true)
            hud.show("Listening…")
            if config.preview {
                let timer = Timer(timeInterval: config.previewSeconds, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.previewTick() }
                }
                RunLoop.main.add(timer, forMode: .common)
                previewTimer = timer
            }
        } catch {
            NSSound.beep()
            hud.hide()
            setStatus("Mic error: \(error.localizedDescription)")
        }
    }

    /// Cumulative preview: re-transcribe the whole buffer so far and show it.
    /// Skips a tick if the previous preview is still running.
    func previewTick() {
        guard recording, !previewInFlight else { return }
        let samples = recorder.snapshot()
        guard samples.count > 8000 else { return } // wait for ~0.5s of audio
        previewInFlight = true
        Task {
            let text = (try? await transcriber.transcribe(samples)) ?? ""
            await MainActor.run {
                self.previewInFlight = false
                if self.recording, !text.isEmpty {
                    self.hud.show(text)
                }
            }
        }
    }

    func stopRecording() {
        guard recording else { return }
        recording = false
        setIcon(recording: false)
        previewTimer?.invalidate()
        previewTimer = nil
        let samples = recorder.stop()
        guard samples.count > 1600 else { // <0.1s: ignore accidental taps
            hud.hide()
            return
        }
        Task {
            do {
                let raw = try await transcriber.transcribe(samples)
                guard !raw.isEmpty else {
                    await MainActor.run { self.hud.hide() }
                    return
                }
                await MainActor.run { self.hud.show(raw) }

                var text = raw
                if self.config.polish {
                    await MainActor.run { self.hud.show(raw + "  ⋯") }
                    if let polished = await Delivery.polish(raw, config: self.config) {
                        text = polished
                    }
                }

                let final = text
                await MainActor.run {
                    self.lastTranscript = final
                    self.hud.show(final)
                    self.hud.hide(after: 1.2)
                    self.setStatus("Ready — hold \(self.hotKeyLabel()) to talk")
                }
                await Delivery.deliver(final, config: self.config)
                if self.config.mode == "paste", !AXIsProcessTrusted() {
                    await MainActor.run {
                        self.setStatus("On clipboard — grant Accessibility to auto-paste")
                    }
                }
            } catch {
                await MainActor.run {
                    self.hud.hide()
                    self.setStatus("ASR error: \(error.localizedDescription)")
                }
            }
        }
    }

    func setIcon(recording: Bool) {
        let name = recording ? "mic.fill" : "mic"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "voice-shim")
        statusItem.button?.image = img
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    func makeMenu() {
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        copyLastItem.target = self
        copyLastItem.isHidden = true
        modeLine.isEnabled = false
        modeLine.title = "Mode: \(config.mode)"
        axItem.target = self
        menu.addItem(statusLine)
        menu.addItem(copyLastItem)
        menu.addItem(.separator())
        menu.addItem(modeLine)
        menu.addItem(axItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        // Not assigned to statusItem.menu permanently — that would make every
        // click open the menu and swallow the toggle action.
    }

    @objc func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        recording ? stopRecording() : startRecording()
    }

    func setStatus(_ text: String) {
        statusLine.title = text
        if lastTranscript.isEmpty {
            copyLastItem.isHidden = true
        } else {
            copyLastItem.isHidden = false
            copyLastItem.title = "Copy last: “\(String(lastTranscript.prefix(48)))…”"
        }
        axItem.isHidden = !(config.mode == "paste" && !AXIsProcessTrusted())
    }

    @objc func copyLast() {
        Delivery.copyToClipboard(lastTranscript)
    }

    @objc func openAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
