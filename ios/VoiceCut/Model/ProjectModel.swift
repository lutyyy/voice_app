import AutoCutCore
import Foundation
import UIKit

/// 單一專案的處理流程：解碼 → 辨識 → 漏字補抓 → 標記 → （Claude 判斷）→ 輸出 → 反覆補剪
@MainActor
final class ProjectModel: ObservableObject {
    enum Stage: Equatable {
        case idle
        case working
        case ready
        case failed(String)
    }

    @Published var meta: ProjectMeta
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var step = ""
    @Published private(set) var progress: Double?
    /// 目前步驟開始的時間（畫面顯示「已經過」）
    @Published private(set) var stepStarted = Date()
    @Published private(set) var log: [String] = []
    /// 標記結果（每個字一列；refine 補剪的列也寫回這裡）
    @Published private(set) var plan: [Word] = []
    @Published var notice: String?

    private weak var store: ProjectStore?
    private var task: Task<Void, Never>?
    private var pcm: MappedPCM?
    private var analysis: Analysis?
    private let settings = AppSettings.shared

    init(meta: ProjectMeta, store: ProjectStore) {
        self.meta = meta
        self.store = store
        plan = (try? load([Word].self, "plan.json")) ?? []
        if !plan.isEmpty { stage = .ready }
    }

    // MARK: - 檔案

    var folder: URL { ProjectStore.folder(meta.id) }
    var sourceURL: URL { folder.appendingPathComponent(meta.sourceName) }
    var outputURL: URL? { meta.outputName.map { folder.appendingPathComponent($0) } }
    var isBusy: Bool { stage == .working }

    private func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    private func load<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: url(name)))
    }

    private func save<T: Encodable>(_ value: T, _ name: String) throws {
        try JSONEncoder().encode(value).write(to: url(name), options: .atomic)
    }

    private func saveMeta() {
        try? store?.save(meta)
    }

    // MARK: - 狀態

    private func say(_ s: String, _ p: Double? = nil) {
        step = s
        stepStarted = Date()
        progress = p
        log.append(s)
    }

    /// 給 Transcriber 等回報進度用：nan 代表無法估計，畫面改成轉圈圈
    private func report(_ p: Double, _ s: String) {
        if step != s { say(s) }
        progress = p.isNaN ? nil : p
    }

    func cancel() {
        task?.cancel()
    }

    /// 在背景執行一段工作；處理期間不讓螢幕自動鎖定（iOS 會在鎖定或切到背景時暫停 App）
    private func run(_ work: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        stage = .working
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            do {
                try await work()
                stage = .ready
                step = ""
                progress = nil
            } catch is CancellationError {
                stage = plan.isEmpty ? .idle : .ready
                say("已取消")
            } catch {
                stage = plan.isEmpty ? .failed(error.localizedDescription) : .ready
                notice = error.localizedDescription
                log.append("錯誤：\(error.localizedDescription)")
            }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - 辨識與標記

    /// 開啟專案時呼叫：還沒有標記結果就從頭處理
    func prepareIfNeeded() {
        if plan.isEmpty && stage == .idle { prepare() }
    }

    /// 重新辨識（刪除逐字稿與標記，從頭來）
    func retranscribe() {
        for f in ["words.json", "plan.json", "pcm.f32"] { try? FileManager.default.removeItem(at: url(f)) }
        plan = []
        meta.info = nil
        analysis = nil
        pcm = nil
        meta.deletes = nil
        meta.outputStale = true
        saveMeta()
        stage = .idle
        prepare()
    }

    func prepare() {
        run { [self] in
            try await ensureAnalysis()
            let a = analysis!
            var words: [Word]
            if let cached = try? load([Word].self, "words.json") {
                words = cached
            } else {
                say("轉成辨識用的格式…", 0)
                let audio = try await MediaIO.decode16k(sourceURL) { p in Task { @MainActor in self.progress = p } }
                let model = settings.model.isEmpty ? Transcriber.defaultModel : settings.model
                try await Transcriber.shared.load(model: model) { p, s in
                    Task { @MainActor in self.report(p, s) }
                }
                say("語音辨識中…", 0)
                let prompt = settings.prompt.isEmpty ? Transcriber.defaultPrompt : settings.prompt + "，" + Transcriber.defaultPrompt
                words = try await Transcriber.shared.transcribe(audio, prompt: prompt) { p in
                    Task { @MainActor in self.progress = p }
                }
                log.append("辨識出 \(words.count) 個字")
                if settings.gapFill {
                    words = try await fillGaps(words, audio: audio, speech: a.speech)
                }
                try save(words, "words.json")
            }
            say("標記要剪的地方…")
            let input = words
            let p = await offMain { Planner.plan(input, speech: a.speech) }
            plan = p
            try save(p, "plan.json")
            let s = Planner.summary(p)
            log.append("語助詞 \(s.fillers) 處、重複 \(s.repeats) 處、拖音 \(s.drags) 處、雜音 \(s.noise) 處 → 會剪；疑似贅詞 \(s.review) 處")
            meta.outputStale = meta.outputName != nil
            saveMeta()
        }
    }

    /// 解碼原檔並分析音量、人聲區間（同一次開啟只做一次）
    private func ensureAnalysis() async throws {
        if analysis != nil, pcm != nil { return }
        if meta.info == nil {
            meta.info = try await MediaIO.info(sourceURL)
            saveMeta()
        }
        if let sr = meta.info?.sampleRate, MediaInfo.workingRate(sr) != sr {
            meta.info?.sampleRate = MediaInfo.workingRate(sr)  // 舊版建立的專案：改用 44.1kHz 重新解碼
            saveMeta()
        }
        let info = meta.info!
        let raw = url("pcm.f32")
        let expect = Int(info.duration * Double(info.sampleRate)) * info.channels * 4
        let size = (try? FileManager.default.attributesOfItem(atPath: raw.path)[.size] as? Int) ?? 0
        if size == 0 || abs(size - expect) > info.sampleRate * info.channels * 4 {
            say("解碼音訊…", 0)
            try await MediaIO.decodeToFile(sourceURL, to: raw, sampleRate: info.sampleRate, channels: info.channels) { p in
                Task { @MainActor in self.progress = p }
            }
        }
        let src = try MappedPCM(url: raw, sampleRate: info.sampleRate, channels: info.channels)
        say("分析音量與人聲區間…")
        analysis = await offMain { Analysis(src: src) }
        pcm = src
    }

    /// 第二輪：有人聲但沒有字覆蓋的片段單獨再辨識，補進逐字稿（標記 extra），由 plan 判斷是語助詞還是內容
    private func fillGaps(_ words: [Word], audio: [Float], speech: [Span]) async throws -> [Word] {
        var fitted = words
        Planner.fitWords(&fitted, speech: speech, maxChar: 0, trimTo: 0)
        let gaps = Planner.uncoveredSpeech(words: fitted, speech: speech)
        if gaps.isEmpty { return words }
        say("第二輪：檢查漏字（\(gaps.count) 段）…", 0)
        var extra: [Word] = []
        for (k, g) in gaps.enumerated() {
            try Task.checkCancellation()
            progress = Double(k) / Double(gaps.count)
            let lo = max(0, Int(g.start * 16000)), hi = min(audio.count, Int(g.end * 16000))
            if hi <= lo { continue }
            let (text, lp) = try await Transcriber.shared.transcribeClip(Array(audio[lo..<hi]))
            if TextRules.norm(text).isEmpty { continue }
            let seg = words.filter { $0.start <= g.start }.map(\.seg).max() ?? 0
            extra.append(Word(seg: seg, start: (g.start * 1000).rounded() / 1000, end: (g.end * 1000).rounded() / 1000,
                              text: text, extra: true, logprob: (lp * 100).rounded() / 100))
        }
        log.append("補回 \(extra.count) 個片段")
        return (words + extra).sorted { $0.start < $1.start }
    }

    // MARK: - Claude 判斷

    var sentencesText: String { Review.sentencesText(plan) }

    /// 目前生效的刪除清單（版本碼不符時為 nil，並顯示提示）
    var deletes: Review.Deletes? {
        guard let text = meta.deletes else { return nil }
        return try? Review.parseDeletes(text, words: plan)
    }

    func askClaude() {
        let key = settings.claudeKey
        run { [self] in
            say("請 Claude 判斷重講的句子與贅詞…")
            let reply = try await ClaudeClient(apiKey: key).judge(sentencesText)
            try applyReply(reply)
        }
    }

    /// 套用 Claude 的回覆（API 或手動貼上）
    func applyReply(_ reply: String) throws {
        let d = try Review.parseDeletes(reply, words: plan)
        meta.deletes = reply
        meta.outputStale = meta.outputName != nil
        saveMeta()
        objectWillChange.send()
        notice = "Claude 判斷：刪除 \(d.sentences.count) 句、剪掉 \(d.reviews.count) 個疑似贅詞（其餘保留）"
            + (d.missingCode ? "\n注意：回覆中沒有版本碼，無法確認是否對應目前的逐字稿。" : "")
        log.append(notice!)
    }

    func clearReply() {
        meta.deletes = nil
        meta.outputStale = meta.outputName != nil
        saveMeta()
        objectWillChange.send()
    }

    // MARK: - 手動修改

    /// 設定改了（例如疑似贅詞要不要剪），已輸出的檔案需要重新輸出
    func markStale() {
        guard meta.outputName != nil, !meta.outputStale else { return }
        meta.outputStale = true
        saveMeta()
    }

    /// 依目前設定，每個字最後是保留還是剪掉
    var decided: [Word] { Review.decide(plan, deletes: deletes, cutReview: settings.cutReview) }

    /// 點一下切換保留／剪掉（手動的決定優先於 Claude 與自動規則）
    func toggle(_ w: Word, to keep: Bool) {
        guard let i = plan.firstIndex(where: { $0.start == w.start && $0.text == w.text && $0.end == w.end }) else { return }
        plan[i].action = keep ? .keep : .cut
        plan[i].reason = keep ? "手動保留" : "手動剪"
        try? save(plan, "plan.json")
        meta.outputStale = meta.outputName != nil
        saveMeta()
    }

    // MARK: - 輸出

    func render() {
        run { [self] in
            try await ensureAnalysis()
            var segs = try await renderOnce()
            let rounds = settings.refineRounds
            if rounds > 0 {
                for rnd in 1...rounds {
                    try Task.checkCancellation()
                    say("第 \(rnd) 輪：重新辨識成品，找殘留語助詞…", 0)
                    let added = try await refineRound(rnd, segs: segs)
                    log.append("補剪 \(added) 處")
                    if added == 0 { break }
                    segs = try await renderOnce()
                }
            }
            meta.outputStale = false
            saveMeta()
            if let info = meta.info, let d = meta.outputDuration {
                notice = "完成！原長 \(Self.clock(info.duration)) → 剪後 \(Self.clock(d))，省下 \(Self.clock(info.duration - d))"
                log.append(notice!)
            }
        }
    }

    /// 依目前的標記輸出一次，回傳輸出的片段
    private func renderOnce() async throws -> [Seg] {
        guard let pcm, let a = analysis, let info = meta.info else { throw MediaError.readFailed("尚未分析") }
        let words = decided
        let o = settings.renderOptions
        say("計算剪接點、停頓與呼吸聲…")
        let (segs, gain) = try await offMainThrowing { () throws -> ([Seg], [Float]) in
            let keep = words.filter { $0.action == .keep }
            let gain = Renderer.breathGain(a, keepWords: keep, margin: o.breathMargin, maxCut: o.breathCut)
            let segs = try Renderer.segments(words, analysis: a, duration: min(info.duration, pcm.duration),
                                             options: o, fps: info.fps, gain: gain)
            return (segs, gain)
        }
        let video = info.isVideo
        let wav = !video && settings.audioFormat == "wav"
        let outName = video ? "output.mp4" : (wav ? "output.wav" : "output.m4a")
        let audioURL = video ? url("output-audio.m4a") : url(outName)
        say("輸出音訊（交叉淡化、壓低呼吸聲、補環境底噪）…")
        let seconds = try await offMainThrowing { () throws -> Double in
            let writer = try AudioFileWriter(url: audioURL, sampleRate: pcm.sampleRate, channels: pcm.channels,
                                             wav: wav, bitRate: video ? 192_000 : 128_000)
            return try Renderer.synthesize(pcm, segs: segs, analysis: a, gain: gain, options: o) { try writer.write($0) }
        }
        if video {
            say("輸出影片…", 0)
            try await VideoExporter.export(source: sourceURL, segs: segs, audio: audioURL, to: url(outName)) { p in
                Task { @MainActor in self.progress = p }
            }
            try? FileManager.default.removeItem(at: audioURL)
        }
        for old in ["output.mp4", "output.wav", "output.m4a"] where old != outName {
            try? FileManager.default.removeItem(at: url(old))
        }
        try save(segs, "segs.json")
        meta.outputName = outName
        meta.outputDuration = seconds
        saveMeta()
        let fills = segs.filter { $0.kind == .noise }.count
        log.append("原長 \(Self.clock(info.duration)) → 剪後 \(Self.clock(seconds))（\(segs.count - fills) 段、補底噪 \(fills) 處）")
        return segs
    }

    /// 反覆補剪：重新辨識成品 → 找殘留語助詞 → 對回原檔 → 寫回標記。回傳新增的 cut 數
    private func refineRound(_ rnd: Int, segs: [Seg]) async throws -> Int {
        guard let out = outputURL else { return 0 }
        let audio = try await MediaIO.decode16k(out)
        let model = settings.model.isEmpty ? Transcriber.defaultModel : settings.model
        try await Transcriber.shared.load(model: model) { p, s in
            Task { @MainActor in self.report(p, s) }
        }
        say("第 \(rnd) 輪：重新辨識成品…", 0)
        let prompt = settings.prompt.isEmpty ? Transcriber.defaultPrompt : settings.prompt + "，" + Transcriber.defaultPrompt
        var words = try await Transcriber.shared.transcribe(audio, prompt: prompt) { p in
            Task { @MainActor in self.progress = p }
        }
        let speechOut = await offMain { Analysis(src: ArrayPCM(samples: audio, sampleRate: 16000)).speech }
        if settings.gapFill {
            words = try await fillGaps(words, audio: audio, speech: speechOut)
        }
        let found = Refiner.findResidual(words, speechOut: speechOut)
        var raw = plan
        let added = Refiner.merge(found, segs: segs, into: &raw, round: rnd)
        log.append("找到 \(found.count) 個殘留語助詞")
        if added > 0 {
            plan = raw
            try save(raw, "plan.json")
        }
        return added
    }

    static func clock(_ t: Double) -> String {
        let t = max(0, t)
        let m = Int(t) / 60, s = Int(t) % 60
        return m >= 60 ? String(format: "%d:%02d:%02d", m / 60, m % 60, s) : String(format: "%d:%02d", m, s)
    }
}

/// 在背景執行緒做大量計算，不卡住畫面
func offMainThrowing<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) { try work() }.value
}

func offMain<T>(_ work: @escaping () -> T) async -> T {
    await Task.detached(priority: .userInitiated) { work() }.value
}
