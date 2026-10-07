import AutoCutCore
import Foundation

/// 逐字稿加標點與分句：Whisper 辨識中文時常常整段沒有標點。
/// 依字與字之間的停頓補上：停頓長 → 句號（「嗎」結尾用問號）並換句；停頓短 → 逗號。
/// 模型自己寫的標點會保留；只加標點，不改字
enum Punctuate {
    static let sentenceEnd: Set<Character> = Set("。！？!?…")
    static let anyPunct: Set<Character> = Set("，。、！？,.!?；;：:…")

    /// 停頓多長算一句話講完、多長算逗號（秒）
    static let fullStop = 0.5
    static let comma = 0.2
    /// 一句太長時，較短的停頓也加逗號
    static let longSentence = 40

    static func apply(_ words: inout [Word]) {
        guard !words.isEmpty else { return }
        var seg = 0
        var chars = 0
        for i in words.indices {
            words[i].seg = seg
            chars += words[i].display.count
            let last = words[i].display.last(where: { !$0.isWhitespace })
            let isLast = i == words.count - 1
            let gap = isLast ? 9.9 : words[i + 1].start - words[i].end
            if let c = last, sentenceEnd.contains(c) {
                seg += 1
                chars = 0
                continue
            }
            if let c = last, anyPunct.contains(c) { continue }
            if gap >= fullStop {
                add(&words[i], last == "嗎" || last == "吗" ? "？" : "。")
                seg += 1
                chars = 0
            } else if gap >= comma || (chars >= longSentence && gap >= 0.12) {
                add(&words[i], "，")
                if chars >= longSentence { chars = 0 }
            }
        }
    }

    private static func add(_ w: inout Word, _ p: String) {
        w.text += p
        if let e = w.edited { w.edited = e + p }
    }

    /// 已經有足夠的標點（每 30 個字至少一個）就不用再加
    static func hasPunctuation(_ words: [Word]) -> Bool {
        let text = words.map(\.display).joined()
        guard text.count >= 30 else { return true }
        let n = text.filter { anyPunct.contains($0) }.count
        return n * 30 >= text.count
    }
}
