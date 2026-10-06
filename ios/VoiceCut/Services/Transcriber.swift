import AutoCutCore
import Foundation
import WhisperKit

/// 在 iPhone 上用 WhisperKit 辨識（對應 autocut.py 的 asr／fill_gaps）
@MainActor
final class Transcriber: ObservableObject {
    static let shared = Transcriber()

    /// 在提示中放語助詞，Whisper 比較願意把「嗯、呃」寫出來，而不是自動美化掉；用繁體字也比較不會輸出簡體
    static let defaultPrompt = "嗯，這個，呃，就是說，我們今天，然後，那個，欸，對，我覺得啊，喔。"
    static let fillerPrompt = "嗯，呃，欸，啊，喔"

    struct ModelChoice: Identifiable {
        let id: String
        let name: String
        let note: String
    }

    /// 介面上可選的模型（由小到大）
    static let candidates: [ModelChoice] = [
        ModelChoice(id: "openai_whisper-base", name: "Base", note: "最快、約 140MB，中文準確度較低"),
        ModelChoice(id: "openai_whisper-small", name: "Small", note: "約 480MB，速度與準確度平衡"),
        ModelChoice(id: "openai_whisper-large-v3-v20240930_626MB", name: "Large v3 Turbo", note: "約 630MB，最準（建議 iPhone 14 以上）"),
    ]

    /// 這台裝置支援的模型
    static var supported: [String] {
        let s = Set(WhisperKit.recommendedModels().supported)
        return candidates.map(\.id).filter { s.contains($0) }
    }

    /// 沒有指定時：能跑 Large v3 Turbo 就用它，否則 Small，再不行用 Base
    static var defaultModel: String {
        let s = supported
        for id in candidates.map(\.id).reversed() where s.contains(id) { return id }
        return "openai_whisper-base"
    }

    private var pipe: WhisperKit?
    private var loaded: String?
    private var loading: (model: String, task: Task<Void, Error>)?
    /// 目前準備好的模型（設定頁顯示用）
    @Published private(set) var readyModel: String?

    /// 下載並載入模型。progress 的進度為 nan 時代表無法估計（例如最佳化中）。
    /// 同一個模型正在載入時不會重複載入，等前一次完成即可
    func load(model: String, progress: @escaping (Double, String) -> Void) async throws {
        if loaded == model, pipe != nil { return }
        if let l = loading, l.model == model {
            progress(.nan, Self.optimizing)
            try await l.task.value
            return
        }
        pipe = nil
        loaded = nil
        readyModel = nil
        let task = Task { [self] in
            progress(0, "下載辨識模型（只有第一次需要）")
            let folder = try await WhisperKit.download(variant: model, progressCallback: { p in
                progress(p.fractionCompleted, "下載辨識模型（只有第一次需要）")
            })
            progress(.nan, Self.optimizing)
            // 背景不能用 GPU：聲譜計算改用 CPU（很輕），編碼與解碼本來就用神經網路引擎
            let compute = ModelComputeOptions(melCompute: .cpuOnly)
            let config = WhisperKitConfig(model: model, modelFolder: folder.path, computeOptions: compute, verbose: false,
                                          logLevel: .error, prewarm: true, load: true, download: false)
            let p = try await WhisperKit(config)
            pipe = p
            loaded = model
            readyModel = model
        }
        loading = (model, task)
        defer { if loading?.model == model { loading = nil } }
        try await task.value
    }

    static let optimizing = "載入並最佳化辨識模型"

    func unload() {
        pipe = nil
        loaded = nil
        readyModel = nil
    }

    private func tokens(_ prompt: String) -> [Int]? {
        guard let tok = pipe?.tokenizer else { return nil }
        return tok.encode(text: " " + prompt.trimmingCharacters(in: .whitespaces))
            .filter { $0 < tok.specialTokens.specialTokenBegin }
    }

    /// 主辨識：逐字時間碼。audio 為 16kHz 單聲道；onText 會收到剛辨識出的句子（畫面即時顯示用）
    func transcribe(_ audio: [Float], prompt: String, progress: @escaping (Double) -> Void,
                    onText: ((String) -> Void)? = nil) async throws -> [Word] {
        guard let pipe else { throw MediaError.readFailed("模型尚未載入") }
        let total = Double(audio.count) / 16000
        let opts = DecodingOptions(
            task: .transcribe, language: "zh", temperature: 0, usePrefillPrompt: true, skipSpecialTokens: true,
            wordTimestamps: true, promptTokens: tokens(prompt), chunkingStrategy: .vad)
        pipe.segmentDiscoveryCallback = { segs in
            if let e = segs.map(\.end).max(), total > 0 { progress(min(1, Double(e) / total)) }
            if let onText {
                for s in segs {
                    let t = Self.clean(s.text)
                    if !t.isEmpty { onText(t) }
                }
            }
        }
        defer { pipe.segmentDiscoveryCallback = nil }
        let results = try await pipe.transcribe(audioArray: audio, decodeOptions: opts, callback: { _ in
            Task.isCancelled ? false : nil
        })
        try Task.checkCancellation()
        var words: [Word] = []
        var si = 0
        let segments = results.flatMap(\.segments).sorted { $0.start < $1.start }
        for s in segments {
            for w in s.words ?? [] {
                let text = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty || text.hasPrefix("<|") { continue }
                words.append(Word(seg: si, start: r3(Double(w.start)), end: r3(Double(w.end)), text: text,
                                  prob: (Double(w.probability) * 1000).rounded() / 1000))
            }
            si += 1
        }
        return words
    }

    /// 單獨辨識一小段（前後補 0.5 秒靜音），回傳文字與最低平均 log 機率
    func transcribeClip(_ clip: [Float]) async throws -> (text: String, logprob: Double) {
        guard let pipe else { throw MediaError.readFailed("模型尚未載入") }
        let pad = [Float](repeating: 0, count: 8000)
        let opts = DecodingOptions(task: .transcribe, language: "zh", temperature: 0, usePrefillPrompt: true,
                                   skipSpecialTokens: true, promptTokens: tokens(Self.fillerPrompt))
        let results = try await pipe.transcribe(audioArray: pad + clip + pad, decodeOptions: opts)
        let segs = results.flatMap(\.segments)
        let text = segs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, Double(segs.map(\.avgLogprob).min() ?? 0))
    }

    /// 去掉 <|0.00|> 之類的特殊標記
    nonisolated static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}

/// 處理速度：對應不同的辨識模型與補抓／補剪輪數
enum SpeedTier: String, CaseIterable, Identifiable {
    case fast, standard, ultimate

    var id: String { rawValue }

    var name: String {
        switch self {
        case .fast: return "快速"
        case .standard: return "標準"
        case .ultimate: return "極致"
        }
    }

    var model: String {
        switch self {
        case .fast: return "openai_whisper-base"
        case .standard: return "openai_whisper-small"
        case .ultimate: return "openai_whisper-large-v3-v20240930_626MB"
        }
    }

    var gapFill: Bool { self != .fast }
    var refineRounds: Int {
        switch self {
        case .fast: return 0
        case .standard: return 1
        case .ultimate: return 2
        }
    }

    var note: String {
        switch self {
        case .fast: return "Base 模型、不補抓不補剪。最快，但較容易漏掉語助詞，適合先試剪"
        case .standard: return "Small 模型＋漏字補抓＋補剪 1 輪。速度與品質平衡"
        case .ultimate: return "Large v3 Turbo 模型＋漏字補抓＋補剪 2 輪。最乾淨，處理時間約是標準的 2～3 倍"
        }
    }

    /// 這支手機跑這個等級的風險；沒問題時為 nil
    @MainActor
    var warning: String? {
        let modelName = Transcriber.candidates.first { $0.id == model }?.name ?? model
        if !Transcriber.supported.contains(model) {
            return "這支 iPhone 的晶片不建議跑 \(modelName) 模型：可能非常慢、發燙，或因記憶體不足而閃退。建議改用「\(SpeedTier.recommended.name)」。"
        }
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if self == .ultimate && gb < 5 {
            return String(format: "這支 iPhone 的記憶體約 %.0f GB，極致模式處理長檔案（30 分鐘以上）可能很慢，或在背景被系統中止。", gb.rounded())
        }
        return nil
    }

    /// 這支手機能順跑的最高等級
    @MainActor
    static var recommended: SpeedTier {
        allCases.last { Transcriber.supported.contains($0.model) } ?? .fast
    }
}
