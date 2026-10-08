import AVFoundation
import Foundation

/// Captures microphone audio with AVAudioEngine and accumulates it as
/// 16 kHz mono Float32 samples — the format Parakeet expects.
final class Recorder {
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let lock = NSLock()
    private var maxSamples = 16_000 * 120

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start(maxSeconds: Double) throws {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        maxSamples = Int(16_000 * maxSeconds)
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "Recorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio input device"])
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "Recorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot build 16kHz converter"])
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

            var fed = false
            converter.convert(to: out, error: nil) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))

            self.lock.lock()
            if self.samples.count < self.maxSamples {
                self.samples.append(contentsOf: chunk)
            }
            self.lock.unlock()
        }

        engine.prepare()
        try engine.start()
    }

    /// Copy of everything recorded so far, without stopping capture.
    /// Used for cumulative live previews while the user is still speaking.
    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// Stops capture and returns everything recorded since start().
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }
}
