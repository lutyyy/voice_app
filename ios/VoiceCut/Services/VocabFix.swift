import AutoCutCore
import Foundation

/// 專有名詞校正：逐字稿裡和專有名詞「同音不同字」的地方改成專有名詞的寫法（例如 探真卡 → 探針卡）。
/// 不用提示詞（實測提示詞會讓模型把提示的字補進逐字稿），只改讀音完全相同的字，不會憑空多出字。
/// 改過的字寫在 edited，原本的辨識結果還在，可以還原
enum VocabFix {
    /// 回傳改了幾處
    @discardableResult
    static func apply(_ words: inout [Word], vocab: [String]) -> Int {
        let terms = vocab.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 && $0.allSatisfy(isHan) }
        guard !terms.isEmpty, !words.isEmpty else { return 0 }
        // 每個字（中文字元）在哪個 Word 的第幾個字元
        struct Ch { var w: Int; var k: Int; var c: Character }
        var texts = words.map { Array($0.display) }
        var count = 0
        // 依句子分開比對，標點會打斷
        var runs: [[Ch]] = []
        var cur: [Ch] = []
        var lastSeg = words[0].seg
        for (wi, w) in words.enumerated() {
            if w.seg != lastSeg {
                runs.append(cur)
                cur = []
                lastSeg = w.seg
            }
            for (k, c) in texts[wi].enumerated() {
                if isHan(c) {
                    cur.append(Ch(w: wi, k: k, c: c))
                } else {
                    runs.append(cur)
                    cur = []
                }
            }
        }
        runs.append(cur)
        for term in terms.sorted(by: { $0.count > $1.count }) {
            let tc = Array(term)
            let strict = tc.count == 2  // 兩個字的詞連聲調都要一樣，避免誤改
            let key = tc.map { pinyin($0, tones: strict) }
            for run in runs where run.count >= tc.count {
                var i = 0
                while i + tc.count <= run.count {
                    let win = run[i..<(i + tc.count)]
                    let now = win.map { texts[$0.w][$0.k] }
                    if now != tc, win.map({ pinyin(texts[$0.w][$0.k], tones: strict) }) == key {
                        for (j, ch) in win.enumerated() { texts[ch.w][ch.k] = tc[j] }
                        count += 1
                        i += tc.count
                    } else {
                        i += 1
                    }
                }
            }
        }
        for i in words.indices {
            let t = String(texts[i])
            if t != words[i].display { words[i].edited = t == words[i].text ? nil : t }
        }
        return count
    }

    static func isHan(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }

    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    /// 一個字的拼音（tones = false 時去掉聲調）
    static func pinyin(_ c: Character, tones: Bool) -> String {
        let k = String(c) + (tones ? "1" : "0")
        lock.lock()
        defer { lock.unlock() }
        if let v = cache[k] { return v }
        var s = String(c).applyingTransform(.mandarinToLatin, reverse: false) ?? String(c)
        if !tones { s = s.applyingTransform(.stripDiacritics, reverse: false) ?? s }
        s = s.lowercased()
        cache[k] = s
        return s
    }
}
