import Foundation

/// 反覆補剪：重新辨識成品 → 找殘留語助詞 → 對回原檔時間 → 新增 cut 列
public enum Refiner {
    /// 在成品的辨識結果中找殘留的語助詞。
    /// 要很有把握才補剪：短片段單獨重聽時，常把正常字的一部分聽成嗯、欸（Python 版實測曾因此把 143 個字削短）
    public static func findResidual(_ wordsOut: [Word], speechOut: [Span]) -> [Word] {
        var ws = wordsOut
        Planner.fitWords(&ws, speech: speechOut, maxChar: 0, trimTo: 0)
        var found: [Word] = []
        for (i, w) in ws.enumerated() {
            let t = TextRules.norm(w.text)
            if t.isEmpty { continue }
            let gap = i > 0 ? w.start - ws[i - 1].end : 1.0
            let ok: Bool
            if w.extra {
                ok = TextRules.allFillerChars(t, TextRules.refineChars) && (w.logprob ?? -9) >= -0.7
            } else if TextRules.refineSure.contains(t) {
                ok = (w.prob ?? 1) >= 0.5
            } else {
                ok = TextRules.refineLoose.contains(t) && gap >= 0.15 && (w.prob ?? 1) >= 0.6
            }
            if ok { found.append(w) }
        }
        return found
    }

    /// 把殘留語助詞寫回原始 plan（raw）。回傳新增的 cut 數
    public static func merge(_ found: [Word], segs: [Seg], into raw: inout [Word], round: Int) -> Int {
        var added = 0
        for w in found {
            for sp in Renderer.toSource(segs, w.start, w.end) {
                let fs = sp.start, fe = sp.end
                if fe - fs < 0.04 { continue }
                if raw.contains(where: { $0.action == .cut && $0.start <= fs + 0.02 && $0.end >= fe - 0.02 }) {
                    continue  // 已經標過（可能因太短沒實際剪），不重複新增
                }
                // 與保留的字重疊：只允許把字稍微修短（保留至少 80%），否則代表兩次辨識矛盾，保守略過
                let hit = raw.indices.filter {
                    raw[$0].action != .cut && raw[$0].text != "～" && raw[$0].start < fe - 0.01 && raw[$0].end > fs + 0.01
                }
                if hit.contains(where: { k in
                    max(fs - raw[k].start, raw[k].end - fe) < 0.8 * (raw[k].end - raw[k].start)
                }) { continue }
                for k in hit {
                    if fs - raw[k].start >= raw[k].end - fe {
                        raw[k].end = r3(fs)
                    } else {
                        raw[k].start = r3(fe)
                    }
                }
                let seg = raw.min(by: { abs($0.start - fs) < abs($1.start - fs) })?.seg ?? 0
                raw.append(Word(seg: seg, start: r3(fs), end: r3(fe), text: w.text,
                                action: .cut, reason: "語助詞（第\(round)輪補剪）"))
                added += 1
            }
        }
        raw = stableSorted(raw) { $0.start < $1.start }
        return added
    }
}
