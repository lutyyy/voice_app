import AutoCutCore
import SwiftUI

/// 逐字稿編輯器（專案頁的主畫面）：聲波時間軸、試聽、篩選、整句滑動、同字批次、搜尋、修正錯字
struct TranscriptEditor: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var player: ClipPlayer
    /// 播放剪後（跳過剪掉的字）還是原音
    var playCut = true
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var editing: Word?
    @State private var editText = ""
    @State private var toast: String?
    @State private var renaming: Int?
    @State private var renameText = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    @AppStorage("editorHintSeen") private var hintSeen = false

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", cuts = "有剪的", review = "疑似贅詞", manual = "手動改過"
        var id: String { rawValue }
    }

    struct Sentence: Identifiable {
        let id: Int
        var words: [Word]
        var start: Double { words.first?.start ?? 0 }
        var end: Double { words.last?.end ?? 0 }
        var text: String { words.map(\.display).joined() }
    }

    static func sentences(_ words: [Word]) -> [Sentence] {
        var out: [Sentence] = []
        for w in words {
            if let last = out.last, last.id == w.seg {
                out[out.count - 1].words.append(w)
            } else {
                out.append(Sentence(id: w.seg, words: [w]))
            }
        }
        return out
    }

    private static func matches(_ f: Filter, _ s: Sentence) -> Bool {
        switch f {
        case .all: return true
        case .cuts: return s.words.contains { $0.action == .cut }
        case .review: return s.words.contains { WordChip.isReviewOrigin($0) }
        case .manual: return s.words.contains { $0.reason.hasPrefix("手動") || $0.edited != nil }
        }
    }

    private func visible(_ all: [Sentence]) -> [Sentence] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return all.filter { s in
            Self.matches(filter, s) && (q.isEmpty || s.text.localizedCaseInsensitiveContains(q))
        }
    }

    var body: some View {
        let words = model.decided
        let all = Self.sentences(words)
        let shown = visible(all)
        let who = model.sentenceSpeaker
        ScrollViewReader { proxy in
            List {
                Section {
                    header(words, all: all, shown: shown, proxy: proxy)
                        .listRowSeparator(.hidden)
                    chips(all)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                    if searching {
                        searchField
                            .listRowSeparator(.hidden)
                    }
                }
                if shown.isEmpty {
                    Text(query.isEmpty ? "沒有符合的句子" : "找不到「\(query)」")
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
                ForEach(shown) { s in
                    sentenceRow(s, speaker: who[s.id])
                        .id(s.id)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing) {
                            Button {
                                model.setSentence(s.id, keep: false)
                            } label: {
                                Label("整句剪掉", systemImage: "scissors")
                            }
                            .tint(.red)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                model.setSentence(s.id, keep: true)
                            } label: {
                                Label("整句保留", systemImage: "arrow.uturn.backward")
                            }
                            .tint(.green)
                        }
                }
            }
            .listStyle(.plain)
            // 播放時逐字稿跟著捲到正在播的那句
            .onChange(of: playingSentence(all)) { _, id in
                guard let id, player.playingID == Self.playAllID else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .alert("說話者名稱", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(renaming.map { "說話者 \($0 + 1)" } ?? "", text: $renameText)
            Button("儲存") {
                if let i = renaming { model.renameSpeaker(i, to: renameText.trimmingCharacters(in: .whitespaces)) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("例如：主持人、來賓。逐字稿、字幕和給 Claude 的內容都會用這個名字。")
        }
        .alert("修改文字", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("正確的文字", text: $editText)
            Button("儲存") {
                if let w = editing { model.editText(w, to: editText) }
            }
            if editing?.edited != nil {
                Button("還原辨識結果", role: .destructive) {
                    if let w = editing { model.editText(w, to: "") }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只修正逐字稿上的錯字（匯出逐字稿時使用），不影響剪輯位置。辨識結果：「\(editing?.text ?? "")」")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: toast)
        .onDisappear {
            player.stop()
            hintSeen = true
        }
    }

    /// 正在播的那句
    private func playingSentence(_ all: [Sentence]) -> Int? {
        guard let t = player.current else { return nil }
        return all.last(where: { $0.start <= t + 0.05 })?.id
    }

    // MARK: - 播放

    static let playAllID = "all"

    /// 從 t 開始播到最後；剪後模式會跳過被剪掉的字
    static func playAll(_ model: ProjectModel, _ player: ClipPlayer, from t: Double, cutOnly: Bool) {
        let words = model.decided
        guard let last = words.last else { return }
        let start = t >= last.end - 0.1 ? 0 : t
        player.play(model.sourceURL, from: max(0, start), to: last.end + 0.5, offset: model.sourceOffset,
                    id: playAllID, skip: cutOnly ? cutSpans(words) : [])
    }

    // MARK: - 上方

    /// 聲波時間軸（上面疊「原長 → 剪後」），下面一行剪幾處、Claude 狀態；操作提示只在第一次顯示
    private func header(_ words: [Word], all: [Sentence], shown: [Sentence], proxy: ScrollViewProxy) -> some View {
        let total = model.meta.info?.duration ?? (words.last?.end ?? 0)
        let cuts = Self.cutSpans(words)
        return VStack(alignment: .leading, spacing: 8) {
            TimelineStrip(waveform: model.waveform, duration: total, cuts: cuts, playhead: player.current) { t in
                if let s = all.last(where: { $0.start <= t + 0.05 }) ?? all.first {
                    if !shown.contains(where: { $0.id == s.id }) {
                        filter = .all
                        query = ""
                    }
                    withAnimation { proxy.scrollTo(s.id, anchor: .top) }
                }
            }
            .frame(height: 60)
            .overlay(alignment: .topLeading) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let e = model.estimate {
                        Text("\(ProjectModel.clock(total)) → \(ProjectModel.clock(e))")
                            .font(.headline.monospacedDigit())
                            .contentTransition(.numericText())
                            .animation(.default, value: e)
                        Text("−\(Int(((1 - e / max(total, 0.01)) * 100).rounded()))%")
                            .font(.subheadline.monospacedDigit().bold())
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Text(ProjectModel.clock(total)).font(.headline.monospacedDigit())
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(4)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                Text("剪 \(cuts.count) 處")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(4)
                    .allowsHitTesting(false)
            }
            if model.meta.deletes != nil {
                if let d = model.deletes {
                    Label("Claude 已判斷：刪 \(d.sentences.count) 句、\(d.reviews.count) 個贅詞", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                } else {
                    Label("Claude 的回覆和目前的逐字稿對不上，沒有套用", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if !hintSeen {
                Text("點字切換剪／留 · 長按試聽或改字 · 左右滑整句 · 點時間從那句播")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜尋逐字稿", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
            Button("取消") {
                query = ""
                searching = false
            }
            .font(.subheadline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.08), in: Capsule())
        .onAppear { searchFocused = true }
    }

    /// 篩選：膠囊按鈕，後面是句數
    private func chips(_ all: [Sentence]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { f in
                    let n = count(f, all)
                    Button {
                        filter = f
                    } label: {
                        HStack(spacing: 4) {
                            Text(f.rawValue)
                            if f != .all { Text("\(n)").monospacedDigit().opacity(0.7) }
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .foregroundStyle(filter == f ? Color.black : Color.primary)
                        .background(filter == f ? Color.accentColor : Color.white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == f ? .isSelected : [])
                }
                Button {
                    searching.toggle()
                    if !searching { query = "" }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .foregroundStyle(searching || !query.isEmpty ? Color.black : Color.primary)
                        .background(searching || !query.isEmpty ? Color.accentColor : Color.white.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜尋逐字稿")
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private func count(_ f: Filter, _ all: [Sentence]) -> Int {
        all.filter { Self.matches(f, $0) }.count
    }

    /// 一句：句首灰色小時間（點了從這句開始播）、說話者名字，接著字一個貼一個排
    private func sentenceRow(_ s: Sentence, speaker: Int?) -> some View {
        let here = player.playingID == Self.playAllID && playingSentenceID(s)
        return FlowLayout(spacing: 0, lineSpacing: 6) {
            if let sp = speaker {
                Button {
                    renameText = model.meta.speakerNames.flatMap { sp < $0.count ? $0[sp] : nil } ?? ""
                    renaming = sp
                } label: {
                    Text(model.speakerName(sp))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(ExportView.color(sp))
                        .padding(.trailing, 6)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderless)
                .accessibilityHint("點兩下改名字")
            }
            Button {
                if here {
                    player.stop()
                } else {
                    Self.playAll(model, player, from: max(0, s.start - 0.15), cutOnly: playCut)
                }
            } label: {
                Text(ProjectModel.clock(s.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(here ? Color.accentColor : Color.secondary)
                    .padding(.trailing, 8)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(here ? "停止" : "從 \(ProjectModel.clock(s.start)) 開始播放")
            ForEach(Array(s.words.enumerated()), id: \.offset) { _, w in
                WordChip(word: w, playing: isPlaying(w)) { model.toggle(w, to: w.action == .cut) }
                    .contextMenu { menu(w) }
                    .disabled(model.isBusy)
            }
        }
        .padding(.vertical, 6)
    }

    private func playingSentenceID(_ s: Sentence) -> Bool {
        guard let t = player.current else { return false }
        return t >= s.start - 0.2 && t < s.end + 0.2
    }

    private func isPlaying(_ w: Word) -> Bool {
        guard let t = player.current else { return false }
        return t >= w.start && t < w.end
    }

    @ViewBuilder
    private func menu(_ w: Word) -> some View {
        let cut = w.action == .cut
        if !w.reason.isEmpty { Text(w.reason) }
        Text(String(format: "%.2f – %.2f 秒", w.start, w.end))
        Button(cut ? "保留" : "剪掉", systemImage: cut ? "checkmark" : "scissors") { model.toggle(w, to: cut) }
        Button("試聽這裡", systemImage: "play") {
            player.play(model.sourceURL, from: max(0, w.start - 0.6), to: w.end + 0.6, offset: model.sourceOffset, id: "w")
        }
        Button("修改文字…", systemImage: "pencil") {
            editText = w.display
            editing = w
        }
        let label = TextRules.norm(w.text)
        if !label.isEmpty {
            Button("所有「\(label)」都剪掉", systemImage: "scissors.badge.ellipsis") {
                show("已剪掉 \(model.setAll(like: w, keep: false)) 個「\(label)」")
            }
            Button("所有「\(label)」都保留", systemImage: "checkmark.circle") {
                show("已保留 \(model.setAll(like: w, keep: true)) 個「\(label)」")
            }
        }
    }

    private func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toast == message { toast = nil }
        }
    }

    /// 連續被剪的字合併成一段（時間軸上畫紅色）
    static func cutSpans(_ words: [Word]) -> [Span] {
        var out: [Span] = []
        for w in words where w.action == .cut {
            if let last = out.last, w.start - last.end < 0.05 {
                out[out.count - 1].end = max(last.end, w.end)
            } else {
                out.append(Span(w.start, w.end))
            }
        }
        return out
    }
}

/// 整段聲波，被剪的地方標紅；點一下跳到該處的句子
private struct TimelineStrip: View {
    let waveform: [Float]
    let duration: Double
    let cuts: [Span]
    let playhead: Double?
    let onTap: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { gc, size in draw(gc, size) }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { v in
                    guard duration > 0, geo.size.width > 0 else { return }
                    onTap(Double(v.location.x / geo.size.width) * duration)
                })
        }
        .accessibilityElement()
        .accessibilityLabel("整段聲波，紅色是會剪掉的地方，共 \(cuts.count) 處")
    }

    private func draw(_ gc: GraphicsContext, _ size: CGSize) {
        guard duration > 0 else { return }
        let w = size.width, h = size.height
        for c in cuts {
            let x0 = CGFloat(c.start / duration) * w, x1 = CGFloat(c.end / duration) * w
            gc.fill(Path(CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: h)), with: .color(.red.opacity(0.28)))
        }
        if waveform.isEmpty {
            gc.fill(Path(CGRect(x: 0, y: h / 2 - 1, width: w, height: 2)), with: .color(.secondary.opacity(0.4)))
        } else {
            let n = waveform.count
            let bw = w / CGFloat(n)
            for i in 0..<n {
                let bh = max(1.5, CGFloat(waveform[i]) * h * 0.9)
                gc.fill(Path(roundedRect: CGRect(x: CGFloat(i) * bw, y: h / 2 - bh / 2, width: max(1, bw * 0.7), height: bh),
                             cornerRadius: 1),
                        with: .color(Color.accentColor.opacity(0.75)))
            }
        }
        for c in cuts {
            let x0 = CGFloat(c.start / duration) * w, x1 = CGFloat(c.end / duration) * w
            gc.fill(Path(CGRect(x: x0, y: h - 3, width: max(1.5, x1 - x0), height: 3)), with: .color(.red))
        }
        if let p = playhead {
            let x = CGFloat(p / duration) * w
            gc.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: h)), with: .color(.orange))
        }
    }
}

struct WordChip: View {
    let word: Word
    let playing: Bool
    let onTap: () -> Void

    static func isReviewOrigin(_ w: Word) -> Bool {
        ["疑似贅詞", "附和", "漏字", "疑似聽錯"].contains { w.reason.contains($0) }
    }

    private var cut: Bool { word.action == .cut }

    private var textColor: Color {
        if cut { return Color.red.opacity(0.8) }
        return word.extra ? Color.secondary : Color.primary
    }

    private var fillColor: Color {
        if playing { return Color.orange.opacity(0.35) }
        return cut ? Color.red.opacity(0.12) : Color.clear
    }

    var body: some View {
        Text(word.display)
            .font(.body)
            .underline(word.edited != nil, color: Color.blue)
            .strikethrough(cut, color: Color.red)
            .foregroundStyle(textColor)
            .padding(.horizontal, 0.5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(fillColor))
            // 疑似贅詞：橘色底線
            .overlay(alignment: .bottom) {
                if Self.isReviewOrigin(word) {
                    Capsule().fill(Color.orange).frame(height: 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .accessibilityLabel(word.display + (cut ? "，會剪掉" : ""))
            .accessibilityHint("點兩下切換保留或剪掉，長按有更多選項")
    }
}

/// 自動換行的排版（字一個接一個排，排不下就換行）
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width {
                y += lineH + lineSpacing
                x = 0
                lineH = 0
            }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            lineH = max(lineH, s.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                y += lineH + lineSpacing
                x = bounds.minX
                lineH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}
