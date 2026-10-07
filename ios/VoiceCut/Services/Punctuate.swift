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

    // MARK: - 只給畫面用（剪輯模式）

    /// 依停頓該加的標點（字的索引 → 標點），不改資料：剪輯模式只在畫面上顯示，不影響剪接與 Claude 判斷
    static func marks(_ words: [Word]) -> [Int: String] {
        var out: [Int: String] = [:]
        var chars = 0
        for i in words.indices {
            chars += words[i].display.count
            let last = words[i].display.last(where: { !$0.isWhitespace })
            if let c = last, anyPunct.contains(c) {
                if sentenceEnd.contains(c) { chars = 0 }
                continue
            }
            let gap = i == words.count - 1 ? 9.9 : words[i + 1].start - words[i].end
            if gap >= fullStop {
                out[i] = last == "嗎" || last == "吗" ? "？" : "。"
                chars = 0
            } else if gap >= comma || (chars >= longSentence && gap >= 0.12) {
                out[i] = "，"
                if chars >= longSentence { chars = 0 }
            }
        }
        return out
    }

    // MARK: - 請 Claude 依語意加標點

    /// 送出的開頭；貼回來的內容含這行代表貼到的是自己送出去的文字，不是回覆
    static let requestMarker = "## 請幫逐字稿加標點"

    /// 給 Claude（API 或 App）的請求：拿掉現有標點的原文，停頓很長處換行當作提示
    static func request(_ words: [Word]) -> String {
        var text = ""
        for (i, w) in words.enumerated() {
            text += strip(w.display)
            if i + 1 < words.count, words[i + 1].start - w.end >= 1.5 { text += "\n" }
        }
        return requestMarker + """

        請只幫下面這段中文口語逐字稿加上全形標點符號（，。？！、：；），讓它好讀。
        規則：
        1. 絕對不能增加、刪除或修改任何一個字，錯字、語助詞、重複的字也都照原樣保留。
        2. 只加標點，不要分段標題、不要說明、不要引號。
        3. 直接輸出加好標點的全文。

        """ + text
    }

    static func strip(_ s: String) -> String {
        String(s.filter { !anyPunct.contains($0) && !otherPunct.contains($0) }).trimmingCharacters(in: .whitespaces)
    }

    static let otherPunct: Set<Character> = Set("「」『』（）()“”\"'—-～~")

    enum ApplyError: LocalizedError {
        case notReply, changed(Double)
        var errorDescription: String? {
            switch self {
            case .notReply: return "貼上的是送出去的逐字稿本身，不是回覆。請在 Claude／Gemini 的回覆下方按「複製」再回來。"
            case .changed(let r):
                return "回覆的字和逐字稿對不上（只對上 \(Int(r * 100))%），可能被改了字，所以沒有套用。可以再試一次。"
            }
        }
    }

    /// 把 Claude 加好標點的全文對回逐字稿：只取標點，字一個都不改；對不上的比例太高就不套用。
    /// 會先拿掉原本的標點再加上新的，並依句號重新分句。回傳加了幾個標點
    @discardableResult
    static func applyReply(_ reply: String, to words: inout [Word]) throws -> Int {
        if reply.contains(requestMarker) { throw ApplyError.notReply }
        // 逐字稿的每個字元（不含標點、空白）記下屬於哪個 Word、是不是那個 Word 的最後一個字元
        struct Ch { var c: Character; var w: Int; var last: Bool }
        var orig: [Ch] = []
        for (wi, w) in words.enumerated() {
            let cs = Array(strip(w.display).filter { !$0.isWhitespace })
            for (k, c) in cs.enumerated() { orig.append(Ch(c: c, w: wi, last: k == cs.count - 1)) }
        }
        guard !orig.isEmpty else { return 0 }
        func same(_ a: Character, _ b: Character) -> Bool { String(a).lowercased() == String(b).lowercased() }
        let keep: Set<Character> = Set("，。？！、：；")
        let map: [Character: Character] = [",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；"]
        var marks: [Int: Character] = [:]
        var i = 0, matched = 0
        for c0 in reply {
            let c = map[c0] ?? c0
            if keep.contains(c) {
                if i > 0 { marks[i - 1] = c }
                continue
            }
            if c.isWhitespace || anyPunct.contains(c) || otherPunct.contains(c) { continue }
            guard i < orig.count else { break }
            if same(c, orig[i].c) {
                i += 1
                matched += 1
            } else if i + 1 < orig.count && same(c, orig[i + 1].c) {
                i += 2  // 回覆少了一個字：跳過
                matched += 1
            }
            // 其他情況：回覆多出來的字，略過
        }
        let ratio = Double(matched) / Double(orig.count)
        guard ratio >= 0.95 else { throw ApplyError.changed(ratio) }
        // 先拿掉原本結尾的標點，再加上新的
        for wi in words.indices {
            words[wi].text = trimEnd(words[wi].text)
            if let e = words[wi].edited { words[wi].edited = trimEnd(e) }
        }
        var n = 0
        for (k, p) in marks where orig[k].last {
            let wi = orig[k].w
            words[wi].text += String(p)
            if let e = words[wi].edited { words[wi].edited = e + String(p) }
            n += 1
        }
        resegment(&words)
        return n
    }

    /// 依句號、問號重新分句（seg 從 0 開始連續編號）
    static func resegment(_ words: inout [Word]) {
        var seg = 0
        for wi in words.indices {
            words[wi].seg = seg
            if let c = words[wi].display.last, sentenceEnd.contains(c) { seg += 1 }
        }
    }

    private static func trimEnd(_ s: String) -> String {
        var s = s
        while let c = s.last, anyPunct.contains(c) { s.removeLast() }
        return s
    }
}
