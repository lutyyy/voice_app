import AutoCutCore
import SwiftUI
import UIKit

/// 只要逐字稿的結果頁：像文章一樣分段（換人或停頓久就換段），點字改錯字，長按從那裡播；
/// 沒把握的字用虛線底線標出，可以一個一個跳過去核對
struct TranscriptDocView: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var player: ClipPlayer
    @AppStorage("transcriptDropFillers") private var dropFillers = true
    @State private var editing: Word?
    @State private var editText = ""
    @State private var renaming: Int?
    @State private var renameText = ""
    @State private var query = ""
    @State private var searching = false
    @State private var checkCursor = 0
    @State private var focusWord: Double?
    @FocusState private var searchFocused: Bool

    /// 一段：同一個人連續說的話
    struct Paragraph: Identifiable {
        let id: Int
        var speaker: Int?
        var words: [Word]
        var start: Double { words.first?.start ?? 0 }
        var end: Double { words.last?.end ?? 0 }
    }

    /// 換說話者、停頓超過 1.5 秒或段落超過約 100 字就換段；只在句子交界換（像 Otter、Notta 的段落）
    static func paragraphs(_ words: [Word], speakers: [Int?]?) -> [Paragraph] {
        var out: [Paragraph] = []
        var chars = 0
        for (i, w) in words.enumerated() {
            let sp = speakers?[i] ?? nil
            if var last = out.last, let prev = last.words.last {
                let newSentence = w.seg != prev.seg
                let breakHere = sp != last.speaker || (newSentence && (w.start - prev.end > 1.5 || chars > 100))
                if !breakHere {
                    last.words.append(w)
                    out[out.count - 1] = last
                    chars += w.display.count
                    continue
                }
            }
            out.append(Paragraph(id: out.count, speaker: sp, words: [w]))
            chars = w.display.count
        }
        return out
    }

    var body: some View {
        let words = model.plan.filter { !(dropFillers && ProjectModel.isFiller($0)) && $0.text != "～" }
        let sp = model.speakerTurns.isEmpty ? nil : Subtitles.speakers(for: words, turns: model.speakerTurns)
        let paras = Self.paragraphs(words, speakers: sp)
        let checks = words.filter(ProjectModel.needsCheck)
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = q.isEmpty ? paras : paras.filter { p in
            Subtitles.join(p.words.map(\.display)).localizedCaseInsensitiveContains(q)
        }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    toolbarChips(checks: checks, proxy: proxy, paras: paras)
                    if searching { searchField }
                    if shown.isEmpty {
                        Text(q.isEmpty ? "沒有辨識到任何字" : "找不到「\(q)」").foregroundStyle(.secondary)
                    }
                    ForEach(shown) { p in
                        paragraph(p).id(p.id)
                    }
                }
                .padding()
            }
            .onChange(of: playingPara(paras)) { _, id in
                guard let id, player.playingID == TranscriptEditor.playAllID else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.3)) }
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
            Text("辨識結果：「\(editing?.text ?? "")」")
        }
        .alert("說話者名稱", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(renaming.map { "說話者 \($0 + 1)" } ?? "", text: $renameText)
            Button("儲存") {
                if let i = renaming { model.renameSpeaker(i, to: renameText.trimmingCharacters(in: .whitespaces)) }
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear { model.punctuateIfNeeded() }
        .onDisappear { player.stop() }
    }

    private func playingPara(_ paras: [Paragraph]) -> Int? {
        guard let t = player.current else { return nil }
        return paras.last(where: { $0.start <= t + 0.05 })?.id
    }

    /// 上方：去掉嗯呃、建議核對（點了跳到下一個）、搜尋
    private func toolbarChips(checks: [Word], proxy: ScrollViewProxy, paras: [Paragraph]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("去掉嗯呃", on: dropFillers) { dropFillers.toggle() }
                if !checks.isEmpty {
                    chip("\(checks.count) 個字建議核對 ›", on: false, tint: .orange) {
                        let w = checks[checkCursor % checks.count]
                        checkCursor += 1
                        focusWord = w.start
                        if let p = paras.last(where: { $0.start <= w.start + 0.01 }) {
                            withAnimation { proxy.scrollTo(p.id, anchor: UnitPoint(x: 0.5, y: 0.3)) }
                        }
                    }
                }
                chip("", icon: "magnifyingglass", on: searching || !query.isEmpty) {
                    searching.toggle()
                    if !searching { query = "" }
                }
            }
        }
    }

    private func chip(_ title: String, icon: String? = nil, on: Bool, tint: Color = .primary,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon) }
                if !title.isEmpty { Text(title) }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(on ? Color.black : tint)
            .background(on ? Color.accentColor : Color.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
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

    private func paragraph(_ p: Paragraph) -> some View {
        let here = player.playingID == TranscriptEditor.playAllID
            && (player.current.map { $0 >= p.start - 0.2 && $0 < p.end + 0.2 } ?? false)
        let cur = currentWord(p)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let s = p.speaker {
                    Button {
                        renameText = model.meta.speakerNames.flatMap { s < $0.count ? $0[s] : nil } ?? ""
                        renaming = s
                    } label: {
                        Text(model.speakerName(s))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(ExportView.color(s))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("點兩下改名字")
                }
                Button {
                    if here {
                        player.stop()
                    } else {
                        TranscriptEditor.playAll(model, player, from: max(0, p.start - 0.15), cutOnly: false)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: here ? "pause.fill" : "play.fill").font(.system(size: 8, weight: .bold))
                        Text(ProjectModel.clock(p.start)).font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(here ? Color.black : Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(here ? Color.accentColor : Color.accentColor.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(here ? "停止" : "從 \(ProjectModel.clock(p.start)) 開始播放")
            }
            FlowLayout(spacing: 0, lineSpacing: 8) {
                ForEach(Array(p.words.enumerated()), id: \.offset) { i, w in
                    DocWord(word: w, playing: i == cur, focused: focusWord == w.start)
                        .onTapGesture {
                            editText = w.display
                            editing = w
                        }
                        .contextMenu {
                            Button("從這裡播放", systemImage: "play") {
                                TranscriptEditor.playAll(model, player, from: max(0, w.start - 0.15), cutOnly: false)
                            }
                            Button("修改文字…", systemImage: "pencil") {
                                editText = w.display
                                editing = w
                            }
                            if w.edited != nil {
                                Button("還原辨識結果", systemImage: "arrow.uturn.backward") { model.editText(w, to: "") }
                            }
                        }
                }
            }
        }
    }

    private func currentWord(_ p: Paragraph) -> Int? {
        guard let t = player.current, t >= p.start - 0.05, t < p.end + 0.3 else { return nil }
        return p.words.lastIndex { $0.start <= t + 0.03 }
    }
}

/// 逐字稿的一個字：正在唸的亮起來、沒把握的虛線底線、改過的藍色底線
private struct DocWord: View {
    let word: Word
    let playing: Bool
    let focused: Bool

    var body: some View {
        Text(word.display)
            .font(.body)
            .foregroundStyle(playing ? Color.black : Color.primary)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(
                playing ? Color.accentColor : (focused ? Color.orange.opacity(0.35) : Color.clear)))
            .overlay(alignment: .bottom) {
                if word.edited != nil {
                    Rectangle().fill(Color.blue).frame(height: 1.5)
                } else if ProjectModel.needsCheck(word) {
                    Line().stroke(Color.orange, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])).frame(height: 1.5)
                }
            }
            .contentShape(Rectangle())
            .accessibilityLabel(word.display + (ProjectModel.needsCheck(word) ? "，建議核對" : ""))
            .accessibilityHint("點兩下修改文字")
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}
