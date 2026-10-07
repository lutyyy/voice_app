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
    @Published private(set) var step = "" { didSet { reportBackground() } }
    @Published private(set) var progress: Double? { didSet { reportBackground() } }
    /// 目前步驟開始的時間（畫面顯示「已經過」）
    @Published private(set) var stepStarted = Date()
    @Published private(set) var log: [String] = []
    /// 標記結果（每個字一列；refine 補剪的列也寫回這裡）
    @Published private(set) var plan: [Word] = []
    @Published var notice: String?
    /// 這次處理的步驟清單（畫面打勾用）
    @Published private(set) var steps: [PipelineStep] = []
    /// 辨識中即時出現的句子（最新的在最後）
    @Published private(set) var liveLines: [String] = []
    /// 聲波概覽（0～1），分析完音量後才有
    @Published private(set) var waveform: [Float] = []
    /// 依目前標記與參數預估的剪後長度（秒）；還沒分析音量時為 nil
    @Published private(set) var estimate: Double?
    private var estimateTask: Task<Void, Never>?
    /// 語者辨識結果（speakers.json）
    @Published private(set) var speakerTurns: [SpeakerTurn] = []
    /// Claude 整理的結果（依種類）
    @Published private(set) var polished: [PolishTask: String] = [:]
    private var warmTask: Task<Void, Never>?
    /// 每次重新辨識或改範圍就加一；背景載入完成時版本不同就丟掉結果
    private var generation = 0

    private weak var store: ProjectStore?
    private var task: Task<Void, Never>?
    private var pcm: MappedPCM?
    private var analysis: Analysis?
    private let settings = AppSettings.shared

    init(meta: ProjectMeta, store: ProjectStore) {
        self.meta = meta
        self.store = store
        plan = (try? load([Word].self, "plan.json")) ?? []
        speakerTurns = (try? load([SpeakerTurn].self, "speakers.json")) ?? []
        for t in PolishTask.allCases {
            if let text = try? String(contentsOf: url("polish-\(t.rawValue).txt"), encoding: .utf8) { polished[t] = text }
        }
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
        guard isBusy else { return }  // 取消後模型仍在背景載入，不再更新畫面
        if step != s { say(s) }
        progress = p.isNaN ? nil : p
    }

    /// 預估剩餘時間（秒）：用目前步驟的進度與經過時間推算，太早或無法估計時為 nil
    func eta(at now: Date) -> Double? {
        guard let p = progress, p > 0.03, p < 1 else { return nil }
        let elapsed = now.timeIntervalSince(stepStarted)
        guard elapsed > 3 else { return nil }
        return elapsed * (1 - p) / p
    }

    /// 開始一次處理前，列出會經過的步驟
    private func setSteps(_ list: [(String, String)]) {
        guard !isBusy else { return }
        steps = list.map { PipelineStep(id: $0.0, title: $0.1) }
        liveLines = []
    }

    /// 進入某個步驟：前面的步驟視為完成（有快取而跳過的也算）
    private func enter(_ id: String) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        for k in 0..<i where steps[k].state != .done {
            steps[k].state = .done
            steps[k].finished = now
        }
        if steps[i].state != .running {
            steps[i].state = .running
            steps[i].started = now
        }
    }

    /// 把整體進度交給背景工作（iOS 26 會顯示在系統的進度提示）
    private func reportBackground() {
        guard isBusy, !steps.isEmpty else { return }
        let done = steps.filter { $0.state == .done }.count
        let within = progress.map { $0.isFinite ? min(1, max(0, $0)) : 0 } ?? 0
        BackgroundWork.shared.update((Double(done) + within) / Double(steps.count), step: step)
    }

    private func finishSteps() {
        let now = Date()
        for k in steps.indices where steps[k].state == .running {
            steps[k].state = .done
            steps[k].finished = now
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// 在背景執行一段工作；處理期間不讓螢幕自動鎖定（iOS 會在鎖定或切到背景時暫停 App）
    private func run(_ work: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        stage = .working
        UIApplication.shared.isIdleTimerDisabled = true
        let bg = BackgroundWork.shared
        bg.begin(title: meta.displayName)
        task = Task {
            do {
                try await work()
                finishSteps()
                stage = .ready
                step = ""
                progress = nil
                bg.end(success: true, message: "處理好了，點這裡回到 App 查看")
            } catch is CancellationError {
                stage = plan.isEmpty ? .idle : .ready
                say("已取消")
                bg.end(success: false, message: "已取消")
            } catch {
                stage = plan.isEmpty ? .failed(error.localizedDescription) : .ready
                notice = error.localizedDescription
                log.append("錯誤：\(error.localizedDescription)")
                bg.end(success: false, message: "發生問題：\(error.localizedDescription)")
            }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - 辨識與標記

    /// 開啟專案時呼叫：還沒有標記結果就從頭處理
    func prepareIfNeeded() {
        if plan.isEmpty && stage == .idle && !needsRange { prepare() }
    }

    /// 新匯入的檔案要先選範圍
    var needsRange: Bool { meta.rangeChosen == false }

    /// 選好範圍（nil = 整個檔案）：之前的辨識結果都作廢，從頭處理
    func setRange(_ r: ClipRange?, fps: Double?) {
        guard !isBusy else { return }
        var r = r
        if var x = r, let fps, fps > 0 {  // 影片：開頭對齊影格，畫面才不會差一格
            x.start = (x.start * fps).rounded(.down) / fps
            r = x
        }
        let changed = r != meta.range
        meta.range = r
        meta.rangeChosen = true
        saveMeta()
        if changed || plan.isEmpty { retranscribe() }
    }

    /// 重新辨識（刪除逐字稿與標記，從頭來）
    func retranscribe() {
        warmTask?.cancel()
        warmTask = nil
        generation += 1
        for f in ["words.json", "plan.json", "pcm.f32", "speakers.json"] { try? FileManager.default.removeItem(at: url(f)) }
        speakerTurns = []
        plan = []
        meta.info = nil
        analysis = nil
        pcm = nil
        waveform = []
        estimate = nil
        undoStack = []
        redoStack = []
        segsCache = nil
        meta.deletes = nil
        meta.planOptions = nil
        meta.outputStale = true
        saveMeta()
        stage = .idle
        prepare()
    }

    func prepare() {
        var list = [("decode", "解碼音訊"), ("analyze", "分析音量與人聲"), ("model", "準備辨識模型"), ("asr", "語音辨識")]
        if settings.gapFill { list.append(("gaps", "檢查漏字")) }
        list.append(("plan", "標記要剪的地方"))
        setSteps(list)
        run { [self] in
            try await ensureAnalysis()
            let a = analysis!
            var words: [Word]
            if let cached = try? load([Word].self, "words.json") {
                words = cached
            } else {
                enter("model")
                say("轉成辨識用的格式…", 0)
                let audio = try await MediaIO.decode16k(sourceURL, range: meta.range) { p in
                    Task { @MainActor in self.progress = p }
                }
                let model = settings.resolvedModel
                try await Transcriber.shared.load(model: model) { p, s in
                    Task { @MainActor in self.report(p, s) }
                }
                enter("asr")
                say("語音辨識中…", 0)
                // 不用提示詞：實測會讓模型把提示詞的字直接補進逐字稿（或整段輸出空白）
                let prompt: String? = nil
                words = try await Transcriber.shared.transcribe(audio, prompt: prompt, progress: { p in
                    Task { @MainActor in self.progress = p }
                }, onText: { t in
                    Task { @MainActor in self.addLive(t) }
                })
                log.append("辨識出 \(words.count) 個字")
                if settings.gapFill {
                    words = try await fillGaps(words, audio: audio, speech: a.speech)
                }
                try save(words, "words.json")
            }
            enter("plan")
            say("標記要剪的地方…")
            let input = words
            let opts = settings.planOptions
            let p = await offMain { Planner.plan(input, speech: a.speech, options: opts) }
            plan = p
            try save(p, "plan.json")
            meta.planOptions = opts
            let s = Planner.summary(p)
            log.append("語助詞 \(s.fillers) 處、重複 \(s.repeats) 處、拖音 \(s.drags) 處、雜音 \(s.noise) 處 → 會剪；疑似贅詞 \(s.review) 處")
            meta.outputStale = meta.outputName != nil
            saveMeta()
            refreshEstimate()
        }
    }

    /// 開啟已處理過的專案時，在背景載入音量分析（不顯示處理畫面），
    /// 以便預估剪後長度；拖音參數改過就順便重新標記
    func warmUp() {
        guard analysis == nil, warmTask == nil, !isBusy, !plan.isEmpty, let info = meta.info,
              MediaInfo.workingRate(info.sampleRate) == info.sampleRate, pcmLooksValid(info) else { return }
        let raw = url("pcm.f32")
        let gen = generation
        warmTask = Task { [self] in
            defer { if gen == generation { warmTask = nil } }
            guard let src = try? MappedPCM(url: raw, sampleRate: info.sampleRate, channels: info.channels) else { return }
            let a = await offMain { Analysis(src: src) }
            guard gen == generation, !Task.isCancelled else { return }
            if analysis == nil {
                analysis = a
                pcm = src
                waveform = a.overview(bins: 160)
            }
            if !isBusy { await replanIfNeeded() }
            refreshEstimate()
        }
    }

    private func pcmLooksValid(_ info: MediaInfo) -> Bool {
        let expect = Int(info.duration * Double(info.sampleRate)) * info.channels * 4
        let size = (try? FileManager.default.attributesOfItem(atPath: url("pcm.f32").path)[.size] as? Int) ?? 0
        return size > 0 && abs(size - expect) <= info.sampleRate * info.channels * 4
    }

    /// 拖音參數和產生標記時不同 → 用逐字稿重新標記，保留手動的決定與補剪找到的語助詞
    private func replanIfNeeded() async {
        let opts = settings.planOptions
        guard !plan.isEmpty, (meta.planOptions ?? PlanOptions()) != opts, let a = analysis,
              let words = try? load([Word].self, "words.json") else { return }
        let old = plan
        var p = await offMain { Planner.plan(words, speech: a.speech, options: opts) }
        let manual = Self.manualMarks(old)
        Self.forEachKey(p) { i, key in
            if let m = manual[key] {
                if m.reason.hasPrefix("手動") {
                    p[i].action = m.action
                    p[i].reason = m.reason
                }
                p[i].edited = m.edited
            }
        }
        p = (p + old.filter { Self.isRefineRow($0) }).enumerated()
            .sorted { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }
            .map(\.element)
        plan = p
        try? save(p, "plan.json")
        meta.planOptions = opts
        meta.outputStale = meta.outputName != nil
        saveMeta()
        log.append("拖音設定改了，已重新標記（保留手動修改）")
    }

    /// 補剪（重新辨識成品）新增的列：不在逐字稿裡，重新標記時要原樣保留
    private static func isRefineRow(_ w: Word) -> Bool { w.reason.contains("補剪") }

    /// 每個字的識別碼：句子編號＋文字＋在句中第幾次出現（拖音參數不影響）
    private static func forEachKey(_ ws: [Word], _ body: (Int, String) -> Void) {
        var count: [String: Int] = [:]
        for (i, w) in ws.enumerated() where w.text != "～" && !isRefineRow(w) {
            let k = "\(w.seg)|\(w.text)"
            let n = count[k, default: 0]
            count[k] = n + 1
            body(i, "\(k)|\(n)")
        }
    }

    private static func manualMarks(_ ws: [Word]) -> [String: (action: Action, reason: String, edited: String?)] {
        var out: [String: (action: Action, reason: String, edited: String?)] = [:]
        forEachKey(ws) { i, key in
            if ws[i].reason.hasPrefix("手動") || ws[i].edited != nil { out[key] = (ws[i].action, ws[i].reason, ws[i].edited) }
        }
        return out
    }

    /// 重新計算預估的剪後長度（只算剪接點，不輸出檔案，約零點幾秒）
    func refreshEstimate() {
        guard let a = analysis, let info = meta.info, !plan.isEmpty else { return }
        let words = decided
        let o = settings.renderOptions
        let duration = min(info.duration, pcm?.duration ?? info.duration)
        estimateTask?.cancel()
        estimateTask = Task { [self] in
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            let secs = await offMain { () -> Double? in
                let keep = words.filter { $0.action == .keep }
                let gain = Renderer.breathGain(a, keepWords: keep, margin: o.breathMargin, maxCut: o.breathCut)
                let segs = try? Renderer.segments(words, analysis: a, duration: duration, options: o, fps: info.fps, gain: gain)
                return segs?.reduce(0) { $0 + $1.length }
            }
            if !Task.isCancelled { estimate = secs }
        }
    }

    /// 解碼原檔並分析音量、人聲區間（同一次開啟只做一次）
    private func ensureAnalysis() async throws {
        if analysis != nil, pcm != nil { return }
        if meta.info == nil {
            var info = try await MediaIO.info(sourceURL)
            if let r = meta.range { info.duration = min(info.duration, r.end) - r.start }
            meta.info = info
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
            enter("decode")
            say("解碼音訊…", 0)
            try await MediaIO.decodeToFile(sourceURL, to: raw, sampleRate: info.sampleRate, channels: info.channels,
                                           range: meta.range) { p in
                Task { @MainActor in self.progress = p }
            }
        }
        let src = try MappedPCM(url: raw, sampleRate: info.sampleRate, channels: info.channels)
        if let a = analysis {  // 背景已經分析過（warmUp）
            pcm = src
            waveform = a.overview(bins: 160)
            return
        }
        enter("analyze")
        say("分析音量與人聲區間…")
        let a = await offMain { Analysis(src: src) }
        analysis = a
        waveform = a.overview(bins: 160)
        pcm = src
    }

    /// 第二輪：有人聲但沒有字覆蓋的片段單獨再辨識，補進逐字稿（標記 extra），由 plan 判斷是語助詞還是內容
    private func fillGaps(_ words: [Word], audio: [Float], speech: [Span]) async throws -> [Word] {
        var fitted = words
        Planner.fitWords(&fitted, speech: speech, maxChar: 0, trimTo: 0)
        let gaps = Planner.uncoveredSpeech(words: fitted, speech: speech)
        if gaps.isEmpty { return words }
        enter("gaps")
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
        setSteps([("claude", "Claude 判斷重講的句子與贅詞")])
        run { [self] in
            enter("claude")
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
        refreshEstimate()
        notice = "Claude 判斷：刪除 \(d.sentences.count) 句、剪掉 \(d.reviews.count) 個疑似贅詞（其餘保留）"
            + (d.missingCode ? "\n注意：回覆中沒有版本碼，無法確認是否對應目前的逐字稿。" : "")
        log.append(notice!)
    }

    func clearReply() {
        meta.deletes = nil
        meta.outputStale = meta.outputName != nil
        saveMeta()
        objectWillChange.send()
        refreshEstimate()
    }

    // MARK: - 手動修改

    /// 設定改了（例如疑似贅詞要不要剪），已輸出的檔案需要重新輸出
    func markStale() {
        refreshEstimate()
        guard meta.outputName != nil, !meta.outputStale else { return }
        meta.outputStale = true
        saveMeta()
    }

    /// 依目前設定，每個字最後是保留還是剪掉
    var decided: [Word] { Review.decide(plan, deletes: deletes, cutReview: settings.cutReview) }

    @Published private(set) var undoStack: [[Word]] = []
    @Published private(set) var redoStack: [[Word]] = []

    /// 修改標記：可以復原，存檔並標記需要重新輸出
    private func edit(_ change: (inout [Word]) -> Void) {
        guard !isBusy else { return }
        var p = plan
        change(&p)
        if p == plan { return }
        undoStack.append(plan)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack = []
        commit(p)
    }

    private func commit(_ p: [Word]) {
        plan = p
        try? save(p, "plan.json")
        meta.outputStale = meta.outputName != nil
        saveMeta()
        refreshEstimate()
    }

    func undo() {
        guard !isBusy, let p = undoStack.popLast() else { return }
        redoStack.append(plan)
        commit(p)
    }

    func redo() {
        guard !isBusy, let p = redoStack.popLast() else { return }
        undoStack.append(plan)
        commit(p)
    }

    private func index(of w: Word, in p: [Word]) -> Int? {
        p.firstIndex { $0.start == w.start && $0.text == w.text && $0.end == w.end }
    }

    private static func manual(_ w: inout Word, keep: Bool) {
        w.action = keep ? .keep : .cut
        w.reason = keep ? "手動保留" : "手動剪"
    }

    /// 點一下切換保留／剪掉（手動的決定優先於 Claude 與自動規則）
    func toggle(_ w: Word, to keep: Bool) {
        edit { p in
            if let i = index(of: w, in: p) { Self.manual(&p[i], keep: keep) }
        }
    }

    /// 整句保留或剪掉
    func setSentence(_ seg: Int, keep: Bool) {
        edit { p in
            for i in p.indices where p[i].seg == seg { Self.manual(&p[i], keep: keep) }
        }
    }

    /// 同樣的字（例如所有的「然後」）一起保留或剪掉；回傳改了幾個
    @discardableResult
    func setAll(like w: Word, keep: Bool) -> Int {
        let key = TextRules.norm(w.text)
        var n = 0
        edit { p in
            for i in p.indices where TextRules.norm(p[i].text) == key {
                Self.manual(&p[i], keep: keep)
                n += 1
            }
        }
        return n
    }

    /// 修正錯字（空字串 = 還原成辨識結果）
    func editText(_ w: Word, to text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        edit { p in
            if let i = index(of: w, in: p) { p[i].edited = t.isEmpty || t == p[i].text ? nil : t }
        }
    }

    // MARK: - 試聽

    /// 原檔中的時間（處理範圍的開頭）
    var sourceOffset: Double { meta.range?.start ?? 0 }

    private var segsCache: [Seg]?

    /// 原檔時間 t 在剪好的檔案中的位置；沒有輸出或輸出過期時為 nil
    func outputTime(for t: Double) -> Double? {
        guard meta.outputName != nil, !meta.outputStale else { return nil }
        if segsCache == nil { segsCache = try? load([Seg].self, "segs.json") }
        guard let segs = segsCache else { return nil }
        return Renderer.toOutput(segs, t)
    }

    // MARK: - 輸出

    func render() {
        let rounds = settings.refineRounds
        var list = [("decode", "解碼音訊"), ("analyze", "分析音量與人聲"), ("cut", "計算剪接點、停頓與呼吸聲"),
                    ("audio", "輸出音訊")]
        if meta.info?.isVideo == true { list.append(("video", "輸出影片")) }
        if rounds > 0 { list += (1...rounds).map { ("refine\($0)", "第 \($0) 輪：重新辨識成品並補剪") } }
        setSteps(list)
        run { [self] in
            try await ensureAnalysis()
            await replanIfNeeded()
            var segs = try await renderOnce(stepped: true)
            if rounds > 0 {
                for rnd in 1...rounds {
                    try Task.checkCancellation()
                    enter("refine\(rnd)")
                    say("第 \(rnd) 輪：重新辨識成品，找殘留語助詞…", 0)
                    let added = try await refineRound(rnd, segs: segs)
                    log.append("補剪 \(added) 處")
                    if added == 0 { break }
                    segs = try await renderOnce(stepped: false)
                }
            }
            meta.outputStale = false
            saveMeta()
            if let info = meta.info, let d = meta.outputDuration {
                log.append("完成！原長 \(Self.clock(info.duration)) → 剪後 \(Self.clock(d))，省下 \(Self.clock(info.duration - d))")
            }
        }
    }

    /// 依目前的標記輸出一次，回傳輸出的片段
    private func renderOnce(stepped: Bool) async throws -> [Seg] {
        guard let pcm, let a = analysis, let info = meta.info else { throw MediaError.readFailed("尚未分析") }
        let words = decided
        let o = settings.renderOptions
        if stepped { enter("cut") }
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
        if stepped { enter("audio") }
        say("輸出音訊（交叉淡化、壓低呼吸聲、補環境底噪）…")
        let seconds = try await offMainThrowing { () throws -> Double in
            let writer = try AudioFileWriter(url: audioURL, sampleRate: pcm.sampleRate, channels: pcm.channels,
                                             wav: wav, bitRate: video ? 192_000 : 128_000)
            return try Renderer.synthesize(pcm, segs: segs, analysis: a, gain: gain, options: o) { try writer.write($0) }
        }
        if video {
            if stepped { enter("video") }
            say("輸出影片…", 0)
            try await VideoExporter.export(source: sourceURL, segs: segs, audio: audioURL, to: url(outName),
                                           offset: meta.range?.start ?? 0) { p in
                Task { @MainActor in self.progress = p }
            }
            try? FileManager.default.removeItem(at: audioURL)
        }
        for old in ["output.mp4", "output.wav", "output.m4a"] where old != outName {
            try? FileManager.default.removeItem(at: url(old))
        }
        try save(segs, "segs.json")
        segsCache = segs
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
        let model = settings.resolvedModel
        try await Transcriber.shared.load(model: model) { p, s in
            Task { @MainActor in self.report(p, s) }
        }
        say("第 \(rnd) 輪：重新辨識成品…", 0)
        // 不用提示詞：實測會讓模型把提示詞的字直接補進逐字稿（或整段輸出空白）
        let prompt: String? = nil
        var words = try await Transcriber.shared.transcribe(audio, prompt: prompt, progress: { p in
            Task { @MainActor in self.progress = p }
        }, onText: { t in
            Task { @MainActor in self.addLive(t) }
        })
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

    private func addLive(_ t: String) {
        if liveLines.contains(t) { return }
        liveLines.append(t)
        if liveLines.count > 6 { liveLines.removeFirst(liveLines.count - 6) }
    }

    // MARK: - 逐字稿、字幕、說話者

    var speakerCount: Int { Set(speakerTurns.map(\.speaker)).count }

    func speakerName(_ i: Int) -> String {
        if let n = meta.speakerNames, i < n.count, !n[i].trimmingCharacters(in: .whitespaces).isEmpty { return n[i] }
        return "說話者 \(i + 1)"
    }

    func renameSpeaker(_ i: Int, to name: String) {
        var n = meta.speakerNames ?? []
        while n.count <= i { n.append("") }
        n[i] = name
        meta.speakerNames = n
        saveMeta()
    }

    /// 辨識說話者（speakers 為 nil = 自動判斷人數）
    func diarize(speakers: Int?) {
        setSteps([("decode16", "轉成辨識用的格式"), ("diarize", "辨識說話者")])
        run { [self] in
            enter("decode16")
            say("轉成辨識用的格式…", 0)
            let audio = try await MediaIO.decode16k(sourceURL, range: meta.range) { p in
                Task { @MainActor in self.progress = p }
            }
            enter("diarize")
            say("辨識說話者（第一次會下載模型）…")
            let turns = try await Diarizer.run(audio, speakers: speakers) { p in
                Task { @MainActor in self.progress = p }
            }
            try Task.checkCancellation()
            speakerTurns = turns
            try save(turns, "speakers.json")
            log.append("辨識出 \(speakerCount) 位說話者")
        }
    }

    func clearSpeakers() {
        speakerTurns = []
        try? FileManager.default.removeItem(at: url("speakers.json"))
    }

    enum TimeBase: String, CaseIterable, Identifiable {
        case output = "對齊剪好的檔案", source = "對齊原始檔案"
        var id: String { rawValue }
    }

    /// 剪好的檔案是否和目前的標記一致（字幕才能對齊成品）
    var outputFresh: Bool { meta.outputName != nil && !meta.outputStale && outputTime(for: 0) != nil }

    /// 保留的字與說話者；時間換成成品或原檔（含處理範圍的開頭）
    func exportWords(_ base: TimeBase) -> (words: [Word], speakers: [Int?]) {
        let all = decided
        let sp = Subtitles.speakers(for: all, turns: speakerTurns)
        if base == .output, outputFresh, let segs = segsCache {
            let m = Subtitles.mapToOutput(all, segs: segs)
            return (m.map(\.word), m.map { sp[$0.index] })
        }
        let off = sourceOffset
        var words: [Word] = []
        var spk: [Int?] = []
        for (i, w) in all.enumerated() where w.action == .keep {
            var x = w
            x.start += off
            x.end += off
            words.append(x)
            spk.append(sp[i])
        }
        return (words, spk)
    }

    /// 寫出 TXT／SRT／VTT 到專案的 export 資料夾，回傳檔案
    func exportFiles(_ base: TimeBase) throws -> [URL] {
        let dir = url("export")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (words, sp) = exportWords(base)
        let names: (Int) -> String = { [self] in speakerName($0) }
        let hasSpeakers = !speakerTurns.isEmpty
        let cues = Subtitles.cues(words, speakers: hasSpeakers ? sp : nil)
        let name = meta.displayName.replacingOccurrences(of: "/", with: "-")
        let files: [(String, String)] = [
            ("\(name).txt", Subtitles.text(words, speakers: hasSpeakers ? sp : nil, names: names)),
            ("\(name).srt", Subtitles.srt(cues, names: names)),
            ("\(name).vtt", Subtitles.vtt(cues, names: names)),
        ]
        return try files.map { f, text in
            let u = dir.appendingPathComponent(f)
            try text.write(to: u, atomically: true, encoding: .utf8)
            return u
        }
    }

    /// 請 Claude 整理逐字稿
    func polish(_ task: PolishTask) {
        let key = settings.claudeKey
        let (words, sp) = exportWords(.output)
        let text = Subtitles.text(words, speakers: speakerTurns.isEmpty ? nil : sp, timestamps: true,
                                  names: { [self] in speakerName($0) })
        setSteps([("claude", "Claude：\(task.name)")])
        run { [self] in
            enter("claude")
            say("請 Claude \(task.name)…")
            let reply = try await ClaudeClient(apiKey: key).polish(text, task: task)
            polished[task] = reply
            try reply.write(to: url("polish-\(task.rawValue).txt"), atomically: true, encoding: .utf8)
        }
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

/// 處理流程中的一個步驟
struct PipelineStep: Identifiable, Equatable {
    enum State { case pending, running, done }
    let id: String
    let title: String
    var state: State = .pending
    var started: Date?
    var finished: Date?
}
