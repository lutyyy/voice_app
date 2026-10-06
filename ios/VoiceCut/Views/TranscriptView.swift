import AutoCutCore
import SwiftUI

/// 逐字稿編輯：聲波時間軸、試聽、篩選、整句滑動、同字批次、復原、搜尋、修正錯字
struct TranscriptView: View {
    @ObservedObject var model: ProjectModel
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var player = ClipPlayer()
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var editing: Word?
    @State private var editText = ""
    @State private var toast: String?

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

    private func visible(_ all: [Sentence]) -> [Sentence] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return all.filter { s in
            let pass: Bool
            switch filter {
            case .all: pass = true
            case .cuts: pass = s.words.contains { $0.action == .cut }
            case .review: pass = s.words.contains { WordChip.isReviewOrigin($0) }
            case .manual: pass = s.words.contains { $0.reason.hasPrefix("手動") || $0.edited != nil }
            }
            return pass && (q.isEmpty || s.text.localizedCaseInsensitiveContains(q))
        }
    }

    var body: some View {
        let words = model.decided
        let all = Self.sentences(words)
        let shown = visible(all)
        ScrollViewReader { proxy in
            List {
                Section {
                    TimelineStrip(waveform: model.waveform, duration: model.meta.info?.duration ?? (words.last?.end ?? 0),
                                  cuts: Self.cutSpans(words), playhead: player.current) { t in
                        if let s = all.last(where: { $0.start <= t + 0.05 }) ?? all.first {
                            if !shown.contains(where: { $0.id == s.id }) {
                                filter = .all
                                query = ""
                            }
                            withAnimation { proxy.scrollTo(s.id, anchor: .top) }
                        }
                    }
                    .frame(height: 56)
                    .listRowSeparator(.hidden)
                    Picker("篩選", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    legend
                }
                if shown.isEmpty {
                    Text(query.isEmpty ? "沒有符合的句子" : "找不到「\(query)」")
                        .foregroundStyle(.secondary)
                }
                ForEach(shown) { s in
                    sentenceRow(s)
                        .id(s.id)
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
        }
        .searchable(text: $query, prompt: "搜尋逐字稿")
        .navigationTitle("逐字稿")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(model.undoStack.isEmpty || model.isBusy)
                    .accessibilityLabel("復原")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(model.redoStack.isEmpty || model.isBusy)
                    .accessibilityLabel("重做")
            }
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
        .onDisappear { player.stop() }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                WordChip(word: Word(seg: 0, start: 0, end: 0, text: "保留"), playing: false, onTap: {}).allowsHitTesting(false)
                WordChip(word: Word(seg: 0, start: 0, end: 0, text: "剪掉", action: .cut), playing: false, onTap: {}).allowsHitTesting(false)
                WordChip(word: Word(seg: 0, start: 0, end: 0, text: "疑似贅詞", reason: "疑似贅詞"), playing: false, onTap: {}).allowsHitTesting(false)
            }
            Text("點字切換保留／剪掉；長按字可以試聽、改錯字、把同樣的字一起剪。句子向左滑整句剪掉、向右滑整句保留。點上方聲波跳到該處。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func sentenceRow(_ s: Sentence) -> some View {
        let srcID = "src\(s.id)", outID = "out\(s.id)"
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(String(format: "S%03d · %@", s.id, ProjectModel.clock(s.start)))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if player.playingID == srcID {
                        player.stop()
                    } else {
                        player.play(model.sourceURL, from: max(0, s.start - 0.2), to: s.end + 0.3,
                                    offset: model.sourceOffset, id: srcID)
                    }
                } label: {
                    Label("原音", systemImage: player.playingID == srcID ? "stop.fill" : "play.fill")
                        .font(.caption)
                }
                .accessibilityLabel(player.playingID == srcID ? "停止" : "播放這句原音")
                if let out = model.outputURL, let o = model.outputTime(for: s.start) {
                    Button {
                        if player.playingID == outID {
                            player.stop()
                        } else {
                            let kept = s.words.filter { $0.action == .keep }.reduce(0) { $0 + $1.end - $1.start }
                            player.play(out, from: max(0, o - 1), to: o + max(2, kept + 0.8), id: outID, tracksTranscript: false)
                        }
                    } label: {
                        Label("剪後", systemImage: player.playingID == outID ? "stop.fill" : "scissors")
                            .font(.caption)
                    }
                    .accessibilityLabel(player.playingID == outID ? "停止" : "試聽剪好的這句")
                }
            }
            .buttonStyle(.borderless)
            FlowLayout(spacing: 2, lineSpacing: 4) {
                ForEach(Array(s.words.enumerated()), id: \.offset) { _, w in
                    WordChip(word: w, playing: isPlaying(w)) { model.toggle(w, to: w.action == .cut) }
                        .contextMenu { menu(w) }
                        .disabled(model.isBusy)
                }
            }
        }
        .padding(.vertical, 4)
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

    var body: some View {
        let cut = word.action == .cut
        Text(word.display)
            .font(.body)
            .underline(word.edited != nil, color: .blue)
            .strikethrough(cut, color: .red)
            .foregroundStyle(cut ? Color.red.opacity(0.8) : (word.extra ? Color.secondary : Color.primary))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(
                playing ? Color.orange.opacity(0.35) : (cut ? Color.red.opacity(0.12) : Color.clear)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Self.isReviewOrigin(word) ? Color.orange : .clear, lineWidth: 1))
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
