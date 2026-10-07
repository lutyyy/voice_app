import Foundation

/// 逐句稿、疑似贅詞清單，以及 Claude 回覆（刪除清單）的解析與套用
public enum Review {
    public static let claudePrompt = """
    以下是一段影片的逐字稿（語音辨識產生，可能有錯字），要剪掉冗詞讓節奏更緊湊。請做兩件事：

    【第一部分】逐句稿，每句前面有編號（S###）。找出應該刪掉的句子：
    1. 講錯後重講的片段（刪掉講錯的那一句，保留重講的版本）
    2. 意思完全重複的句子，或對方重複剛剛那句話的附和（保留說得比較好的那一句）
    3. 明顯的廢話或離題的自言自語（例如「等一下我想一下」「剛剛講到哪」）
    不要刪除只是口語化、但有內容的句子。

    【第二部分】疑似贅詞，每個有編號（R###），【】內是候選字，前後是上下文。
    判斷刪掉【】內的字之後，句子是否仍然通順、意思不變：
    - 是口頭禪、填空用的（例如「然後…然後」、「就是說」、「這個…」停頓用）→ 列出編號，要剪
    - 是句子的必要成分（例如「最重要的【就是】意願」、「【這個】產業」指稱特定東西、「【其實】」帶轉折語氣）→ 不要列
    - 拿不準時不要列（保留比較安全）

    請只輸出要刪除的編號，一行一個，可用範圍（例如 S012-S014、R003-R005），後面可加簡短理由。
    回覆的第一行請原樣寫上：版本碼 {code}
    """

    /// 句子／贅詞編號的指紋。plan 重新產生後編號可能改變，用來擋下過期的刪除清單
    public static func planCode(_ words: [Word]) -> String {
        let keys = words
            .filter { $0.text != "～" && !$0.reason.contains("補剪") }
            .map { "\($0.seg):\($0.rid == 0 ? "" : String($0.rid)):\($0.text)" }
            .sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) { $0.value < $1.value } }
        return String(MD5.hex(Array(keys.joined(separator: "|").utf8)).prefix(6))
    }

    public struct Sentence: Identifiable, Equatable, Sendable {
        public var id: Int
        public var start: Double
        public var text: String
    }

    /// 逐句稿（已剪掉的字不顯示）
    public static func sentences(_ words: [Word]) -> [Sentence] {
        var order: [Int] = []
        var bySeg: [Int: [Word]] = [:]
        for w in words {
            if bySeg[w.seg] == nil { order.append(w.seg) }
            bySeg[w.seg, default: []].append(w)
        }
        return order.compactMap { sid in
            let ws = bySeg[sid]!
            let txt = ws.filter { $0.action != .cut }.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            return txt.isEmpty ? nil : Sentence(id: sid, start: ws[0].start, text: txt)
        }
    }

    /// 手機上的 Whisper 沒有標點、句子常被切在停頓或字中間（例如「介｜紹一下」）；
    /// 把太短、沒有句尾標點、間隔不長的相鄰句子併起來，讓逐句稿是完整的一句話。
    /// 只改句子編號（seg），不動標記
    public static func mergeShortSentences(_ words: inout [Word], minChars: Int = 8, maxChars: Int = 30,
                                           maxGap: Double = 0.8) {
        struct Group { var seg: Int; var chars: Int; var start: Double; var end: Double; var punct: Bool }
        var groups: [Group] = []
        for w in words {
            let kept = w.action != .cut && w.text != "～"
            let n = kept ? w.text.filter { !$0.isPunctuation && !$0.isWhitespace }.count : 0
            if let last = groups.last, last.seg == w.seg {
                var g = last
                if kept {
                    if g.chars == 0 { g.start = w.start }
                    g.chars += n
                    g.end = w.end
                    g.punct = TextRules.endsWithPunct(w.text)
                }
                groups[groups.count - 1] = g
            } else {
                groups.append(Group(seg: w.seg, chars: n, start: w.start, end: w.end,
                                    punct: kept && TextRules.endsWithPunct(w.text)))
            }
        }
        var newID: [Int: Int] = [:]
        var id = -1
        var prev: Group?
        for g in groups {
            // 整句被剪（例如只有「嗯」）：跟著前一句，不打斷合併
            if g.chars == 0 {
                if id < 0 { id = 0 }
                newID[g.seg] = id
                continue
            }
            if var p = prev, !p.punct, g.start - p.end < maxGap,
               p.chars < minChars || g.chars < minChars, p.chars + g.chars <= maxChars {
                p.chars += g.chars
                p.end = g.end
                p.punct = g.punct
                prev = p
            } else {
                id += 1
                prev = g
            }
            newID[g.seg] = id
        }
        for i in words.indices { words[i].seg = newID[words[i].seg] ?? words[i].seg }
    }

    /// 同一句裡換人說話時切開（speakers 與 words 一一對應，nil = 不確定，沿用前一個字），句子重新編號
    public static func splitBySpeaker(_ words: inout [Word], speakers: [Int?]) {
        guard speakers.count == words.count else { return }
        var id = -1
        var prevSeg: Int?
        var cur: Int?
        for i in words.indices {
            let sp = speakers[i] ?? cur
            if words[i].seg != prevSeg || (sp != nil && cur != nil && sp != cur) {
                id += 1
            }
            prevSeg = words[i].seg
            cur = sp
            words[i].seg = id
        }
    }

    /// 每句的說話者（句中字數最多的人）
    public static func sentenceSpeakers(_ words: [Word], speakers: [Int?]) -> [Int: Int] {
        guard speakers.count == words.count else { return [:] }
        var tally: [Int: [Int: Int]] = [:]
        for (w, sp) in zip(words, speakers) {
            guard let sp, w.action != .cut else { continue }
            tally[w.seg, default: [:]][sp, default: 0] += 1
        }
        return tally.mapValues { $0.max { $0.value < $1.value }!.key }
    }

    /// 給 Claude 的完整文字：指令＋第一部分逐句稿＋第二部分疑似贅詞
    /// names：句子編號 → 說話者名稱（有辨識說話者時，讓 Claude 分得出誰在附和誰）
    public static func sentencesText(_ words: [Word], names: [Int: String]? = nil) -> String {
        let lines = sentences(words).map {
            "S" + pad3($0.id) + " [" + String(formatTime($0.start).prefix(8)) + "] "
                + (names?[$0.id].map { $0 + "：" } ?? "") + $0.text
        }
        let shown = words.filter { $0.action != .cut }
        var rlines: [String] = []
        var i = 0
        func ctx(_ r: Range<Int>) -> String { shown[r.clamped(to: 0..<shown.count)].map(\.text).joined() }
        while i < shown.count {
            if shown[i].action != .review {
                i += 1
                continue
            }
            var j = i
            while j + 1 < shown.count && shown[j + 1].rid == shown[i].rid { j += 1 }
            rlines.append("R" + pad3(shown[i].rid) + " …" + ctx(max(0, i - 8)..<i) + "【" + ctx(i..<(j + 1)) + "】"
                          + ctx((j + 1)..<(j + 9)) + "…")
            i = j + 1
        }
        return claudePrompt.replacingOccurrences(of: "{code}", with: planCode(words))
            + "\n\n## 第一部分：逐句稿\n\n" + lines.joined(separator: "\n")
            + "\n\n## 第二部分：疑似贅詞\n\n" + rlines.joined(separator: "\n") + "\n"
    }

    static func pad3(_ n: Int) -> String { String(format: "%03d", n) }

    public enum DeletesError: Error, Equatable, LocalizedError {
        case staleCode(found: String, current: String)
        public var errorDescription: String? {
            switch self {
            case let .staleCode(found, current):
                return "這份刪除清單是針對舊版逐字稿做的（版本碼 \(found)，目前是 \(current)），句子編號已經不同，直接套用會刪錯內容。請重新把逐句稿交給 Claude 判斷。"
            }
        }
    }

    public struct Deletes: Equatable, Sendable {
        public var sentences: Set<Int> = []
        public var reviews: Set<Int> = []
        /// 回覆中沒有版本碼（無法確認是否對應目前的逐字稿）
        public var missingCode = false
        public init() {}
    }

    /// 解析 Claude 回覆：S### = 刪整句；R### = 要剪的疑似贅詞；# 開頭的行是註解
    public static func parseDeletes(_ reply: String, words: [Word]) throws -> Deletes {
        let text = reply.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        let ns = NSRange(text.startIndex..., in: text)
        var d = Deletes()
        let code = planCode(words)
        let codeRe = try! NSRegularExpression(pattern: "版本碼\\s*[:：]?\\s*([0-9a-f]{6})")
        if let m = codeRe.firstMatch(in: text, range: ns), let r = Range(m.range(at: 1), in: text) {
            let found = String(text[r])
            if found != code { throw DeletesError.staleCode(found: found, current: code) }
        } else {
            d.missingCode = true
        }
        let idRe = try! NSRegularExpression(pattern: "\\b([SR])(\\d+)(?:\\s*[-~～到]\\s*[SR]?(\\d+))?", options: [.caseInsensitive])
        for m in idRe.matches(in: text, range: ns) {
            guard let kr = Range(m.range(at: 1), in: text), let lr = Range(m.range(at: 2), in: text),
                  let lo = Int(text[lr]) else { continue }
            var hi = lo
            if let hr = Range(m.range(at: 3), in: text), let h = Int(text[hr]) { hi = h }
            guard hi >= lo, hi - lo < 100_000 else { continue }
            if text[kr].uppercased() == "S" {
                d.sentences.formUnion(lo...hi)
            } else {
                d.reviews.formUnion(lo...hi)
            }
        }
        return d
    }

    /// 有刪除清單時，沒被列出的 review 一律保留。使用者手動改過的字（reason 以「手動」開頭）不動
    public static func apply(_ d: Deletes, to words: inout [Word]) {
        for i in words.indices where !words[i].reason.hasPrefix("手動") {
            if d.sentences.contains(words[i].seg) {
                words[i].mark(.cut, "AI標記刪句")
            } else if words[i].action == .review {
                let hit = words[i].rid > 0 && d.reviews.contains(words[i].rid)
                words[i].mark(hit ? .cut : .keep, words[i].reason + (hit ? "（Claude：剪）" : "（Claude：留）"))
            }
        }
    }

    /// 依刪除清單或「疑似贅詞全剪」決定每個字 keep 或 cut（不改動原始 plan）
    public static func decide(_ raw: [Word], deletes: Deletes?, cutReview: Bool) -> [Word] {
        var words = raw
        var cut = cutReview
        if let deletes {
            apply(deletes, to: &words)
            cut = false
        }
        for i in words.indices where words[i].action == .review {
            words[i].action = cut ? .cut : .keep
        }
        return stableSorted(words) { $0.start < $1.start }
    }
}
