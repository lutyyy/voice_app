import AutoCutCore
import Foundation
import WhisperKit

/// 在 iPhone 上用 WhisperKit 辨識（對應 autocut.py 的 asr／fill_gaps）
@MainActor
final class Transcriber: ObservableObject {
    static let shared = Transcriber()

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
            try await Self.waitCancellable(l.task)
            return
        }
        // 另一個模型還在載入（之前取消的）：先等它結束，避免兩個模型同時佔用記憶體
        if let l = loading {
            progress(.nan, Self.optimizing)
            _ = try? await Self.waitCancellable(l.task)
            try Task.checkCancellation()
            if loaded == model, pipe != nil { return }
        }
        pipe = nil
        loaded = nil
        readyModel = nil
        let task = Task { [self] in
            defer { if loading?.model == model { loading = nil } }
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
            guard loading?.model == model else { return }  // 已經改要別的模型
            pipe = p
            loaded = model
            readyModel = model
        }
        loading = (model, task)
        try await Self.waitCancellable(task)
    }

    /// 等待載入完成，但按「取消」時立刻返回。
    /// 載入模型（尤其第一次最佳化）本身無法中斷，會在背景繼續做完，下次開始就不用再等
    private static func waitCancellable(_ task: Task<Void, Error>) async throws {
        let once = ResumeOnce()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                once.set(c)
                Task {
                    do {
                        try await task.value
                        once.resume(nil)
                    } catch {
                        once.resume(error)
                    }
                }
            }
        } onCancel: {
            once.resume(CancellationError())
        }
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

    /// 主辨識：逐字時間碼。audio 為 16kHz 單聲道；prompt 是使用者填的專有名詞（可為 nil）；
    /// onText 會收到剛辨識出的句子（畫面即時顯示用）。
    /// 實測（CI 上用合成中文語音）：提示詞會讓 Large v3 Turbo 整段輸出空白，所以預設不加提示詞；
    /// 有提示詞但辨識不出字時，自動拿掉提示詞再試一次
    func transcribe(_ audio: [Float], prompt: String?, progress: @escaping (Double) -> Void,
                    onText: ((String) -> Void)? = nil) async throws -> [Word] {
        let p = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p, !p.isEmpty {
            let words = try await transcribeOnce(audio, prompt: p, progress: progress, onText: onText)
            if !words.isEmpty { return words }
        }
        return try await transcribeOnce(audio, prompt: nil, progress: progress, onText: onText)
    }

    private func transcribeOnce(_ audio: [Float], prompt: String?, progress: @escaping (Double) -> Void,
                                onText: ((String) -> Void)?) async throws -> [Word] {
        guard let pipe else { throw MediaError.readFailed("模型尚未載入") }
        let total = Double(audio.count) / 16000
        let opts = DecodingOptions(
            task: .transcribe, language: "zh", temperature: 0, usePrefillPrompt: true, skipSpecialTokens: true,
            wordTimestamps: true, promptTokens: prompt.flatMap { tokens($0) }, chunkingStrategy: .vad)
        pipe.segmentDiscoveryCallback = { segs in
            if let e = segs.map(\.end).max(), total > 0 { progress(min(1, Double(e) / total)) }
            if let onText {
                for s in segs {
                    let t = Self.traditional(Self.clean(s.text))
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
            var added = false
            for w in s.words ?? [] {
                let text = Self.traditional(w.word.trimmingCharacters(in: .whitespacesAndNewlines))
                if text.isEmpty || text.hasPrefix("<|") { continue }
                words.append(Word(seg: si, start: r3(Double(w.start)), end: r3(Double(w.end)), text: text,
                                  prob: (Double(w.probability) * 1000).rounded() / 1000))
                added = true
            }
            // 沒有逐字時間（對齊失敗）時，用整句的時間平均分給每個字，至少不會漏掉整句
            if !added {
                let chars = Self.traditional(Self.clean(s.text)).filter { !$0.isWhitespace && !$0.isPunctuation }.map(String.init)
                if !chars.isEmpty, s.end > s.start {
                    let step = Double(s.end - s.start) / Double(chars.count)
                    for (k, c) in chars.enumerated() {
                        let a = Double(s.start) + step * Double(k)
                        words.append(Word(seg: si, start: r3(a), end: r3(a + step), text: c, prob: 0.5))
                    }
                    added = true
                }
            }
            if added { si += 1 }
        }
        // 超出音訊長度的字是模型幻覺（實測有提示詞時會在結尾補出提示詞）
        return words.filter { $0.start < total }
    }

    /// 簡體轉繁體（Whisper 指定中文時常輸出簡體）
    nonisolated static func traditional(_ text: String) -> String {
        text.applyingTransform(StringTransform(rawValue: "Hans-Hant"), reverse: false) ?? text
    }

    /// 單獨辨識一小段（前後補 0.5 秒靜音），回傳文字與最低平均 log 機率
    func transcribeClip(_ clip: [Float]) async throws -> (text: String, logprob: Double) {
        guard let pipe else { throw MediaError.readFailed("模型尚未載入") }
        let pad = [Float](repeating: 0, count: 8000)
        let opts = DecodingOptions(task: .transcribe, language: "zh", temperature: 0, usePrefillPrompt: true,
                                   skipSpecialTokens: true, promptTokens: tokens(Self.fillerPrompt))
        let results = try await pipe.transcribe(audioArray: pad + clip + pad, decodeOptions: opts)
        let segs = results.flatMap(\.segments)
        let text = Self.traditional(segs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines))
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

/// 只讓 continuation 恢復一次（完成與取消可能同時發生）
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Error>?
    private var pending: Error??

    func set(_ c: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let p = pending {
            lock.unlock()
            if let e = p { c.resume(throwing: e) } else { c.resume() }
            return
        }
        cont = c
        lock.unlock()
    }

    /// nil = 成功
    func resume(_ error: Error?) {
        lock.lock()
        guard pending == nil else { lock.unlock(); return }
        pending = .some(error)
        let c = cont
        cont = nil
        lock.unlock()
        if let c { if let error { c.resume(throwing: error) } else { c.resume() } }
    }
}
