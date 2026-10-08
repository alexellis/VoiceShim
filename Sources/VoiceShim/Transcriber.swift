import FluidAudio
import Foundation

/// Wraps FluidAudio's Parakeet TDT 0.6B v3 ASR. Models download to
/// ~/.cache/fluidaudio on first use and load onto the Neural Engine.
actor Transcriber {
    private var manager: AsrManager?

    var isReady: Bool { manager != nil }

    /// Loads models, reporting download progress in [0, 1]. The callback
    /// arrives on an unspecified queue — hop to the main actor for UI.
    func load(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(progressHandler: { p in
            progress?(p.fractionCompleted)
        })
        manager = AsrManager(config: .default, models: models)
    }

    /// Transcribe 16 kHz mono Float32 samples. Each utterance gets a fresh
    /// decoder state — hold-to-talk utterances are independent.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else {
            throw NSError(domain: "Transcriber", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Models not loaded yet"])
        }
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
