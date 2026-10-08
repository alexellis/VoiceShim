import FluidAudio
import Foundation

/// Wraps FluidAudio's Kokoro on the Neural Engine: the same voice family as
/// superterm's readback on Linux (af_heart by default). Models download to
/// the FluidAudio cache on first load.
actor Speaker {
    private var manager: KokoroAneManager?
    let voice: String

    /// Longest text spoken in one request, matching the Linux daemon.
    static let maxCharacters = 8000

    init(voice: String) {
        self.voice = voice
    }

    func load() async throws {
        guard manager == nil else { return }
        let m = KokoroAneManager(variant: .english, defaultVoice: voice)
        try await m.initialize()
        // The first syntheses compile the models for the Neural Engine and
        // take seconds (5s on an M2); spend that here, not on a reply.
        _ = try? await m.synthesizeDetailed(text: "Ready to speak.", voice: voice, speed: 1)
        manager = m
    }

    /// Speaks text as a 24 kHz mono WAV. A speed of 1 is normal pace.
    func wav(_ text: String, speed: Float) async throws -> Data {
        try await load()
        guard let manager else {
            throw NSError(domain: "Speaker", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "voice not loaded"])
        }
        let result = try await manager.synthesizeDetailed(text: text, voice: voice, speed: speed)
        return try AudioWAV.data(from: result.samples, sampleRate: Double(result.sampleRate))
    }
}
