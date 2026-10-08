import AVFoundation
import Foundation
import Network

/// speechd for Darwin: a warmed HTTP daemon implementing the same REST
/// contract as `superterm speechd` on Linux, backed by Parakeet on the
/// Neural Engine instead of the Python/ONNX worker.
///
///   GET  /health         -> {ok, version, configured, backend, authEnabled, ttsEnabled}
///   POST /v1/transcribe  -> multipart field "audio" -> {text, rawText, polished}  (polish on)
///   POST /v1/preview     -> same, polish off
///   POST /tts            -> 404 until TTS is wired
///
/// Point a superterm server at it with:
///   speech:
///     endpoint: http://127.0.0.1:8765
final class SpeechServer: @unchecked Sendable {
    /// Keeps the daemon alive for the process lifetime — the listener's
    /// callbacks only hold the server weakly.
    nonisolated(unsafe) static var retained: SpeechServer?

    let transcriber: Transcriber
    let config: Config
    let token: String?
    let host: String
    let port: UInt16
    static let maxBodyBytes = 26 << 20

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "speechd")
    fileprivate var activeConnections = 0
    static let maxConnections = 32

    init(transcriber: Transcriber, config: Config, token: String?, host: String, port: UInt16) {
        self.transcriber = transcriber
        self.config = config
        self.token = token
        self.host = host
        self.port = port
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            guard self.activeConnections < SpeechServer.maxConnections else {
                conn.cancel()
                return
            }
            self.activeConnections += 1
            HTTPConnection(conn: conn, server: self, queue: self.queue).run()
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    // MARK: - Routing

    func handle(method: String, path: String, headers: [String: String], body: Data,
                respond: @escaping (Int, String, Data) -> Void) {
        func textError(_ code: Int, _ message: String) {
            respond(code, "text/plain; charset=utf-8", Data((message + "\n").utf8))
        }
        switch path {
        case "/health":
            guard method == "GET" else { return textError(405, "method not allowed") }
            let health: [String: Any] = [
                "ok": true,
                "version": "voice-shim/0.1.0",
                "configured": true,
                "backend": "parakeet-tdt-0.6b-v3-coreml (ane)",
                "authEnabled": token != nil,
                "ttsEnabled": false,
            ]
            let json = (try? JSONSerialization.data(withJSONObject: health)) ?? Data()
            respond(200, "application/json", json + Data("\n".utf8))
        case "/v1/transcribe", "/v1/preview":
            guard method == "POST" else { return textError(405, "method not allowed") }
            guard authorized(headers) else { return textError(401, "unauthorized") }
            guard let contentType = headers["content-type"],
                  contentType.lowercased().contains("multipart/form-data"),
                  let audio = Self.multipartField(named: "audio", body: body, contentType: contentType),
                  !audio.isEmpty else {
                return textError(400, "audio field is required")
            }
            let polish = path == "/v1/transcribe"
            transcribe(audio: audio, polish: polish) { result in
                switch result {
                case .success(let payload):
                    respond(200, "application/json", payload)
                case .failure(let err):
                    textError(502, "transcribe: \(err.localizedDescription)")
                }
            }
        case "/tts":
            guard method == "POST" else { return textError(405, "method not allowed") }
            guard authorized(headers) else { return textError(401, "unauthorized") }
            textError(404, "text-to-speech is not configured")
        default:
            textError(404, "not found")
        }
    }

    private func authorized(_ headers: [String: String]) -> Bool {
        guard let token else { return true }
        let header = headers["authorization"]?.trimmingCharacters(in: .whitespaces) ?? ""
        guard header.hasPrefix("Bearer ") else { return false }
        let got = String(header.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
        // Constant-time compare, matching the Linux daemon.
        guard got.utf8.count == token.utf8.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(got.utf8, token.utf8) { diff |= a ^ b }
        return diff == 0
    }

    private func transcribe(audio: Data, polish: Bool,
                            completion: @escaping (Result<Data, Error>) -> Void) {
        Task {
            do {
                let samples = try Self.decodeAudio(audio)
                let raw = try await self.transcriber.transcribe(samples)
                var text = raw
                if polish, self.config.polishEndpoint != nil, !raw.isEmpty,
                   let polished = await Delivery.polish(raw, config: self.config) {
                    text = polished
                }
                let payload: [String: Any] = [
                    "text": text,
                    "rawText": raw,
                    "polished": text != raw,
                ]
                let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
                completion(.success(json + Data("\n".utf8)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Decode an uploaded audio file (WAV from the product path; anything
    /// AVAudioFile reads otherwise) to 16 kHz mono Float32.
    static func decodeAudio(_ data: Data) throws -> [Float] {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-shim-\(UUID().uuidString).audio")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try loadWav16kMono(path: tmp.path)
    }

    static func multipartField(named name: String, body: Data, contentType: String) -> Data? {
        guard let boundaryRange = contentType.range(of: "boundary=") else { return nil }
        var boundary = String(contentType[boundaryRange.upperBound...])
        if let semi = boundary.firstIndex(of: ";") { boundary = String(boundary[..<semi]) }
        boundary = boundary.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        guard !boundary.isEmpty else { return nil }
        let delimiter = Data(("--" + boundary).utf8)

        var parts: [Data] = []
        var cursor = body.startIndex
        while let hit = body.range(of: delimiter, in: cursor..<body.endIndex) {
            if hit.lowerBound > cursor {
                parts.append(body.subdata(in: cursor..<hit.lowerBound))
            }
            cursor = hit.upperBound
        }
        for part in parts {
            guard let headerEnd = part.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let headerText = String(data: part.subdata(in: part.startIndex..<headerEnd.lowerBound),
                                    encoding: .utf8) ?? ""
            guard headerText.lowercased().contains("name=\"\(name)\"") else { continue }
            var payload = part.subdata(in: headerEnd.upperBound..<part.endIndex)
            if payload.suffix(2) == Data("\r\n".utf8) { payload = payload.dropLast(2) }
            return Data(payload)
        }
        return nil
    }
}

/// Minimal HTTP/1.1 request handler for loopback use: buffered bodies with
/// Content-Length (which is what superterm's Go client sends), one request
/// per connection, Connection: close.
final class HTTPConnection: @unchecked Sendable {
    private let conn: NWConnection
    private let server: SpeechServer
    private let queue: DispatchQueue
    private var buffer = Data()
    private var finished = false
    static let idleDeadline: TimeInterval = 30

    init(conn: NWConnection, server: SpeechServer, queue: DispatchQueue) {
        self.conn = conn
        self.server = server
        self.queue = queue
    }

    func run() {
        conn.start(queue: queue)
        // Reap connections that never complete a request — without this, a
        // half-open socket pins this object (and its buffer) forever.
        queue.asyncAfter(deadline: .now() + Self.idleDeadline) {
            if !self.finished {
                self.finish()
            }
        }
        receive()
    }

    /// Idempotent teardown: releases the connection slot exactly once.
    private func finish() {
        guard !finished else { return }
        finished = true
        server.activeConnections -= 1
        conn.cancel()
    }

    private func receive() {
        // Strong self: nothing else retains this connection object, and the
        // cycle ends when the connection is cancelled.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
            if self.finished { return }
            if let data { self.buffer.append(data) }
            if error != nil { self.finish(); return }
            if self.buffer.count > SpeechServer.maxBodyBytes + (1 << 20) {
                self.respond(413, "text/plain; charset=utf-8", Data("request too large\n".utf8))
                return
            }
            if self.tryDispatch() { return }
            if complete { self.finish(); return }
            self.receive()
        }
    }

    /// Returns true once a full request has been read and dispatched.
    private func tryDispatch() -> Bool {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            respond(400, "text/plain; charset=utf-8", Data("bad request\n".utf8))
            return true
        }
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return false }
        lines.removeFirst()
        let requestParts = requestLine.components(separatedBy: " ")
        guard requestParts.count >= 2 else {
            respond(400, "text/plain; charset=utf-8", Data("bad request\n".utf8))
            return true
        }
        let method = requestParts[0]
        let path = requestParts[1].components(separatedBy: "?")[0]

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            respond(411, "text/plain; charset=utf-8", Data("length required\n".utf8))
            return true
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? -1
        guard contentLength >= 0 else {
            respond(400, "text/plain; charset=utf-8", Data("bad content-length\n".utf8))
            return true
        }
        guard contentLength <= SpeechServer.maxBodyBytes else {
            respond(413, "text/plain; charset=utf-8", Data("request too large\n".utf8))
            return true
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - buffer.distance(from: buffer.startIndex, to: bodyStart) >= contentLength else {
            return false
        }
        let body = buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: contentLength))
        server.handle(method: method, path: path, headers: headers, body: body) { code, type, payload in
            self.respond(code, type, payload)
        }
        return true
    }

    private func respond(_ code: Int, _ contentType: String, _ body: Data) {
        let reason: String
        switch code {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 411: reason = "Length Required"
        case 413: reason = "Payload Too Large"
        default: reason = "Bad Gateway"
        }
        var head = "HTTP/1.1 \(code) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in
            self.queue.async { self.finish() }
        })
    }
}
