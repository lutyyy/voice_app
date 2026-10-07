import Foundation

public struct PlanOptions: Codable, Equatable, Sendable {
    /// 單一中文字超過幾秒算拖音（0 = 不處理）
    public var maxChar: Double = 0.6
    /// 拖音字保留前幾秒
    public var trimTo: Double = 0.4
    /// 漏字補抓的片段信心低於此值 → 標 review
    public var minLogprob: Double = -1.0
    /// 給 Claude 的逐句稿：停頓超過幾秒就斷句
    public var splitGap: Double = 0.3
    public init() {}
}

public struct PlanSummary: Equatable, Sendable {
    public var fillers = 0
    public var repeats = 0
    public var drags = 0
    public var noise = 0
    public var review = 0
}

public enum Planner {
    /// Whisper 常把字的時間碼拉長、蓋住停頓或拖長音：
    /// 1) 把每個字縮到它與人聲區間重疊最多的那一段
    /// 2) 單一中文字仍長於 maxChar → 只留前 trimTo 秒，尾巴另成一列標記 cut（拖音）
    /// 回傳拖音列，由呼叫端在標記完語助詞／重複後再併入
    @discardableResult
    public static func fitWords(_ words: inout [Word], speech: [Span], maxChar: Double, trimTo: Double) -> [Word] {
        var drags: [Word] = []
        for i in words.indices {
            var s = words[i].start, e = words[i].end
            var best: Span?
            for sp in speech where sp.start < e && sp.end > s {
                let ov = Span(max(s, sp.start), min(e, sp.end))
                if best == nil || ov.end - ov.start > best!.end - best!.start {
                    best = ov
                }
            }
            if let b = best, b.end - b.start >= 0.08 {
                s = b.start
                e = b.end
            }
            words[i].start = r3(s)
            words[i].end = r3(e)
            words[i].fitEnd = words[i].end
            let t = TextRules.norm(words[i].text)
            if maxChar > 0 && t.count == 1 && !TextRules.isASCII(t) && e - s > maxChar {
                words[i].end = r3(s + trimTo)
                drags.append(Word(seg: words[i].seg, start: words[i].end, end: r3(e), text: "～",
                                  action: .cut, reason: "拖音"))
            }
        }
        return drags
    }

    /// 人聲區間中沒有被任何字覆蓋的片段（Whisper 漏掉的語助詞，偶爾是整句）
    public static func uncoveredSpeech(words: [Word], speech: [Span], minLen: Double = 0.15) -> [Span] {
        let spans = words.map { Span($0.start, $0.end) }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var out: [Span] = []
        for sp in speech {
            var t = sp.start
            for w in spans {
                if w.end <= t || w.start >= sp.end { continue }
                if w.start - t > minLen { out.append(Span(t, w.start)) }
                t = max(t, w.end)
            }
            if sp.end - t > minLen { out.append(Span(t, sp.end)) }
        }
        return out
    }

    static func boundaryBefore(_ words: [Word], _ i: Int) -> Bool {
        if i == 0 || words[i - 1].seg != words[i].seg { return true }
        return words[i].start - words[i - 1].end >= 0.15 || TextRules.endsWithPunct(words[i - 1].text)
    }

    static func boundaryAfter(_ words: [Word], _ j: Int) -> Bool {
        if j == words.count - 1 || words[j + 1].seg != words[j].seg { return true }
        return words[j + 1].start - words[j].end >= 0.15 || TextRules.endsWithPunct(words[j].text)
    }

    /// Whisper 的 segment 常長達 30 秒；在標點或停頓處重新切成短句，讓 Claude 能逐句挑選。
    /// 需在標記完重複之後才做，否則跨標點的「那，那所以」會被切開而偵測不到
    static func resegment(_ words: inout [Word], splitGap: Double) {
        var seg = 0
        var prev: Word?
        var prevOrig = 0
        for i in words.indices {
            let orig = words[i].seg
            if words[i].text != "～" {
                if let p = prev, orig != prevOrig || TextRules.endsWithPunct(p.text)
                    || words[i].start - (p.fitEnd ?? p.end) >= splitGap {
                    seg += 1
                }
                prev = words[i]
                prevOrig = orig
            }
            words[i].seg = seg
        }
    }

    /// 自動標記要剪的地方（autocut.py 的 plan）。speech 為 nil 時不校正時間碼、不處理拖音
    public static func plan(_ input: [Word], speech: [Span]?, options o: PlanOptions = PlanOptions()) -> [Word] {
        var words = input
        for i in words.indices { words[i].mark(.keep, "") }
        var drags: [Word] = []
        if let speech {
            drags = fitWords(&words, speech: speech, maxChar: o.maxChar, trimTo: o.trimTo)
        }
        let n = words.map { TextRules.norm($0.text) }
        let N = words.count

        // 1) 確定的語助詞；第二輪補回的片段若全是語助詞字也剪，只有附和（是、好、對）標 review
        for i in 0..<N {
            let w = words[i]
            if TextRules.sureFillers.contains(n[i]) {
                words[i].mark(.cut, "語助詞")
            } else if let m = w.misheard, !w.extra {
                words[i].mark(.review, "疑似聽錯（單獨重聽是「\(m)」）")
            } else if !w.extra {
                continue
            } else if n[i].isEmpty {  // 只辨識出標點：多半是雜音
                words[i].mark(.cut, "雜音")
            } else if TextRules.allFillerChars(n[i]) {
                words[i].mark(.cut, "語助詞（漏字補抓）")
            } else if TextRules.isHallucination(w.text) || Double(n[i].count) > 12 * (w.end - w.start) + 2 {
                words[i].mark(.cut, "雜音（辨識幻覺）")  // 字數多到講不完
            } else if TextRules.backchannels.contains(n[i]) {
                words[i].mark(.review, "附和")
            } else if (w.logprob ?? 0) < o.minLogprob {
                words[i].mark(.review, "漏字（不確定，多半是雜音或語助詞）")
            }
        }

        // 2) 口吃／立即重複：「我我我們」「這個這個」「做［呃］做」→ 剪掉前面的
        //    跳過已剪掉的語助詞再比對；兩次相隔 2 秒內都算
        let idx = (0..<N).filter { k in
            !n[k].isEmpty && words[k].action != .cut && !(words[k].extra && words[k].action == .review)
        }
        let M = idx.count
        for p in 0..<M {
            for L in [4, 3, 2, 1] {
                if p + 2 * L > M { continue }
                let A = (p..<(p + L)).map { n[idx[$0]] }
                let B = ((p + L)..<(p + 2 * L)).map { n[idx[$0]] }
                if A != B || (p..<(p + L)).contains(where: { words[idx[$0]].action != .keep }) { continue }
                let last = words[idx[p + L - 1]], nxt = words[idx[p + L]]
                let gap = nxt.start - last.end
                if gap > 2.0 || gap < -0.05 { continue }  // 隔太久不算；時間重疊是同一段聲音被辨識兩次
                if TextRules.endsSentence(last.text) { continue }  // 前一次已是句尾
                if L == 1 && A[0].count == 1 && TextRules.redup.contains(A[0] + A[0]) && gap < 0.12 {
                    continue  // 正常疊字（謝謝、看看）
                }
                for q in p..<(p + L) { words[idx[q]].mark(.cut, "重複") }
                break
            }
        }

        // 3) 可能的贅詞：標 review
        var i = 0
        while i < N {
            var hit = false
            for L in [3, 2, 1] {
                let j = i + L - 1
                if j >= N || words[i].seg != words[j].seg { continue }
                let joined = n[i...j].joined()
                if !TextRules.maybeFillers.contains(joined) { continue }
                if (i...j).contains(where: { words[$0].action != .keep }) { continue }
                if joined.count == 1 && !(boundaryBefore(words, i) && boundaryAfter(words, j)) {
                    continue  // 單字（對、啊）只在前後有停頓時才標記
                }
                for k in i...j { words[k].mark(.review, "疑似贅詞") }
                i = j + 1
                hit = true
                break
            }
            if !hit { i += 1 }
        }

        words = stableSorted(words + drags) { a, b in
            if a.start != b.start { return a.start < b.start }
            return a.text != "～" && b.text == "～"
        }
        resegment(&words, splitGap: o.splitGap)

        // 連續的 review 字編成一組 R###，讓 Claude 看上下文逐一決定
        var rid = 0
        for k in words.indices {
            words[k].rid = 0
            if words[k].action == .review {
                if !(k > 0 && words[k - 1].action == .review && words[k - 1].seg == words[k].seg) {
                    rid += 1
                }
                words[k].rid = rid
            }
        }
        return words
    }

    public static func summary(_ words: [Word]) -> PlanSummary {
        var s = PlanSummary()
        for w in words {
            switch (w.action, w.reason) {
            case (.cut, "語助詞"), (.cut, "語助詞（漏字補抓）"): s.fillers += 1
            case (.cut, "重複"): s.repeats += 1
            case (.cut, "拖音"): s.drags += 1
            case (.cut, let r) where r.hasPrefix("雜音"): s.noise += 1
            case (.review, _): s.review += 1
            default: break
            }
        }
        return s
    }
}

/// Swift 的 sort 不保證穩定；Python 的 sorted 是穩定排序，這裡維持相同結果
func stableSorted<T>(_ a: [T], by less: (T, T) -> Bool) -> [T] {
    a.enumerated().sorted { x, y in
        if less(x.element, y.element) { return true }
        if less(y.element, x.element) { return false }
        return x.offset < y.offset
    }.map(\.element)
}
