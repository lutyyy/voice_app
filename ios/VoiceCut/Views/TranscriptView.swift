import AutoCutCore
import SwiftUI

/// 逐字稿：每句一段，會剪掉的字畫刪除線；點一下切換保留／剪掉
struct TranscriptView: View {
    @ObservedObject var model: ProjectModel
    @EnvironmentObject private var settings: AppSettings
    @State private var onlyCuts = false

    private struct Sentence: Identifiable {
        let id: Int
        let start: Double
        let words: [Word]
    }

    private var sentences: [Sentence] {
        var out: [Sentence] = []
        for w in model.decided {
            if let last = out.last, last.id == w.seg {
                out[out.count - 1] = Sentence(id: last.id, start: last.start, words: last.words + [w])
            } else {
                out.append(Sentence(id: w.seg, start: w.start, words: [w]))
            }
        }
        return onlyCuts ? out.filter { $0.words.contains { $0.action == .cut } } : out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                legend
                Toggle("只顯示有剪的句子", isOn: $onlyCuts)
                    .font(.subheadline)
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(sentences) { s in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(format: "S%03d · %@", s.id, ProjectModel.clock(s.start)))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            FlowLayout(spacing: 2, lineSpacing: 4) {
                                ForEach(Array(s.words.enumerated()), id: \.offset) { _, w in
                                    WordChip(word: w) { model.toggle(w, to: w.action == .cut) }
                                        .disabled(model.isBusy)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("逐字稿")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                WordChip(word: Word(seg: 0, start: 0, end: 0, text: "保留"), onTap: {}).allowsHitTesting(false)
                WordChip(word: Word(seg: 0, start: 0, end: 0, text: "剪掉", action: .cut), onTap: {}).allowsHitTesting(false)
                WordChip(word: Word(seg: 0, start: 0, end: 0, text: "疑似贅詞", reason: "疑似贅詞"), onTap: {}).allowsHitTesting(false)
            }
            Text("點一下字可以切換保留／剪掉；長按看剪掉的原因。逐字稿由語音辨識產生，可能有錯字，但不影響剪輯位置。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WordChip: View {
    let word: Word
    let onTap: () -> Void

    private var isReviewOrigin: Bool {
        ["疑似贅詞", "附和", "漏字", "疑似聽錯"].contains { word.reason.contains($0) }
    }

    var body: some View {
        let cut = word.action == .cut
        Text(word.text)
            .font(.body)
            .strikethrough(cut, color: .red)
            .foregroundStyle(cut ? Color.red.opacity(0.8) : (word.extra ? Color.secondary : Color.primary))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(cut ? Color.red.opacity(0.12) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(isReviewOrigin ? Color.orange : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .contextMenu {
                if !word.reason.isEmpty { Text(word.reason) }
                Text(String(format: "%.2f – %.2f 秒", word.start, word.end))
                Button(cut ? "保留" : "剪掉", action: onTap)
            }
            .accessibilityLabel(word.text + (cut ? "，會剪掉" : ""))
            .accessibilityHint("點兩下切換保留或剪掉")
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
