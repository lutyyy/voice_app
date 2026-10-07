import AutoCutCore
import Foundation
import SpeakerKit

/// 用 SpeakerKit（Pyannote）在手機上辨識誰在說話
enum Diarizer {
    /// audio 為 16kHz 單聲道；speakers 為 nil 時自動判斷人數。說話者依第一次出現的順序編號（0 起）
    static func run(_ audio: [Float], speakers: Int?, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeakerTurn] {
        let kit = try await SpeakerKit()
        let options = PyannoteDiarizationOptions(numberOfSpeakers: speakers)
        let result = try await kit.diarize(audioArray: audio, options: options, progressCallback: { p in
            progress(p.fractionCompleted)
        })
        await kit.unloadModels()
        var order: [Int: Int] = [:]
        return result.segments
            .sorted { $0.startTime < $1.startTime }
            .compactMap { s -> SpeakerTurn? in
                guard let id = s.speaker.speakerId, s.endTime > s.startTime else { return nil }
                let n = order[id] ?? order.count
                order[id] = n
                return SpeakerTurn(start: Double(s.startTime), end: Double(s.endTime), speaker: n)
            }
    }
}
