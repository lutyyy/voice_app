import Foundation

public struct RenderOptions: Codable, Equatable, Sendable {
    /// 安靜超過幾秒的停頓要壓縮
    public var maxPause: Double = 0.35
    /// 壓縮後保留幾秒（越長的停頓會略多留一點）
    public var keepPause: Double = 0.22
    /// 剪接處在句與句之間時，至少保留幾秒停頓
    public var minGapSentence: Double = 0.12
    /// 剪接處在句子中間時，至少保留幾秒
    public var minGapPhrase: Double = 0.03
    /// 要剪的內容合計短於幾秒就不剪，避免多餘的剪接點
    public var minCut: Double = 0.1
    /// 高出底噪幾 dB 以內算安靜
    public var quietDb: Float = 12
    /// 剪接點往被剪的一側找最安靜位置的範圍（秒）
    public var snap: Double = 0.04
    /// 剪接處交叉淡化長度
    public var xfade: Double = 0.02
    /// 剪在有聲音處時的淡化長度
    public var xfadeLong: Double = 0.06
    /// 停頓中高出底噪幾 dB 算呼吸／雜音
    public var breathMargin: Float = 8
    /// 呼吸／雜音最多壓低幾 dB（0 = 不處理）
    public var breathCut: Float = 18
    /// 停頓不足時補合成底噪
    public var roomtone = true
    public init() {}
}

public enum SegKind: String, Codable, Sendable { case src, noise }

/// 輸出的一段：原檔的 [start, end)，或長度為 end - start 的合成底噪
public struct Seg: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var kind: SegKind
    public init(_ start: Double, _ end: Double, _ kind: SegKind) {
        self.start = start
        self.end = end
        self.kind = kind
    }
    public var length: Double { end - start }
}

public enum RenderError: Error, LocalizedError {
    case nothingKept
    case badPause
    public var errorDescription: String? {
        switch self {
        case .nothingKept: return "全部都被剪掉了，請檢查逐字稿的標記"
        case .badPause: return "「壓縮停頓門檻」不能小於「保留停頓長度」"
        }
    }
}

/// 一個保留片段；flag = 是否在句與句之間，fill = 之後要補的底噪秒數
struct Piece {
    var start: Double
    var end: Double
    var boundary = false
    var fill = 0.0
}

/// Python 的 round()（銀行家捨入）
@inline(__always) func pyRound(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }

public enum Renderer {
    /// 決定要保留的原始片段（只管內容；停頓長短之後由 shapeSilence 依實際音量決定）。
    /// 剪掉的內容合計太短（< minCut）就不剪：多一個剪接點的代價比留下一小段聲音大
    static func planPieces(_ words: [Word], _ o: RenderOptions, duration: Double) throws -> [Piece] {
        let kept = words.filter { $0.action == .keep }
        let cuts = words.filter { $0.action == .cut }
        guard let first = kept.first, let last = kept.last else { throw RenderError.nothingKept }
        let before = cuts.filter { $0.end <= first.start + 1e-3 }.map(\.end)
        var cur = before.max() ?? 0
        var pieces: [Piece] = []
        var ci = 0
        for k in 0..<(kept.count - 1) {
            let A = kept[k], B = kept[k + 1]
            while ci < cuts.count && cuts[ci].end <= A.end + 1e-3 { ci += 1 }
            var between: [Word] = []
            var j = ci
            while j < cuts.count && cuts[j].start < B.start - 1e-3 {
                between.append(cuts[j])
                j += 1
            }
            let removed = between.reduce(0.0) { $0 + min($1.end, B.start) - max($1.start, A.end) }
            if removed < o.minCut { continue }
            let lsil = max(0, between.map(\.start).min()! - A.end)
            let rsil = max(0, B.start - between.map(\.end).max()!)
            let boundary = TextRules.endsWithPunct(A.text) || A.seg != B.seg
            pieces.append(Piece(start: cur, end: A.end + lsil, boundary: boundary))
            cur = B.start - rsil
        }
        let after = cuts.filter { $0.start >= last.end - 1e-3 }.map(\.start)
        pieces.append(Piece(start: cur, end: after.min() ?? duration))
        return pieces
    }

    /// 把每個剪接點移到附近最安靜的位置。只往「被剪掉的那一側」找 win 秒，往保留的字裡最多 10ms：
    /// 連續說話中語助詞緊貼前一個字時，對稱搜尋會切掉前字的尾音，聽起來卡卡的
    static func snapPieces(_ pieces: [Piece], E: [Float], hopS: Double, win: Double) -> [Piece] {
        func best(_ t: Double, _ back: Double, _ fwd: Double) -> Double {
            let lo = max(0, Int((t - back) / hopS)), hi = min(E.count - 1, Int((t + fwd) / hopS))
            if hi <= lo { return t }
            let mn = E[lo...hi].min()!
            var bestK = lo, bestD = Double.infinity
            for k in lo...hi where E[k] <= mn + 1 {
                let d = abs(Double(k) * hopS + hopS / 2 - t)
                if d < bestD {
                    bestD = d
                    bestK = k
                }
            }
            return Double(bestK) * hopS + hopS / 2
        }
        var ps = pieces
        for i in ps.indices {
            if i > 0 { ps[i].start = best(ps[i].start, win, 0.01) }
            if i < ps.count - 1 { ps[i].end = best(ps[i].end, 0.01, win) }
        }
        var merged: [Piece] = []
        for p in ps {
            if let l = merged.last, p.start <= l.end + 0.01 {
                merged[merged.count - 1].end = max(l.end, p.end)
                merged[merged.count - 1].boundary = p.boundary
            } else {
                merged.append(p)
            }
        }
        return merged.filter { $0.end - $0.start >= 0.02 }
    }

    /// 依實際音量調整停頓（呼吸聲壓低後也算安靜）：
    /// - 片段內部或剪接處的安靜段 > maxPause → 壓成約 keepPause（依原長略加，保留節奏變化）
    /// - 剪接處的安靜段太短 → 句與句之間補合成底噪到 minGapSentence；句中只補到 minGapPhrase
    static func shapeSilence(_ pieces: [Piece], quiet: [Bool], hopS: Double, _ o: RenderOptions, video: Bool) -> [Piece] {
        let n = quiet.count
        func run(_ t: Double, _ step: Int, _ limit: Double) -> Double {
            var k = pyRound(t / hopS) - (step < 0 ? 1 : 0)
            var c = 0
            while k >= 0 && k < n && quiet[k] && Double(c) * hopS < limit {
                c += 1
                k += step
            }
            return min(Double(c) * hopS, limit)
        }
        func target(_ L: Double) -> Double { o.keepPause + min(0.08, 0.08 * (L - o.maxPause)) }

        var split: [Piece] = []
        for p in pieces {  // 1) 片段內部的長停頓：從中間切掉多餘的部分
            let k0 = pyRound(p.start / hopS), k1 = pyRound(p.end / hopS)
            var cur = p.start
            var i = k0
            while i < k1 {
                if i < 0 || i >= n || !quiet[i] {
                    i += 1
                    continue
                }
                var j = i
                while j < k1 && j < n && quiet[j] { j += 1 }
                let L = Double(j - i) * hopS
                if i > k0 && j < k1 && L > o.maxPause {
                    let h = target(L) / 2
                    split.append(Piece(start: cur, end: Double(i) * hopS + h, boundary: true))
                    cur = Double(j) * hopS - h
                }
                i = j
            }
            split.append(Piece(start: cur, end: p.end, boundary: p.boundary))
        }

        var res = split.map { Piece(start: $0.start, end: $0.end) }
        if res.isEmpty { return res }
        for i in 0..<(res.count - 1) {  // 2) 剪接處：前段尾巴＋後段開頭的安靜合計
            let tail = run(res[i].end, -1, res[i].end - res[i].start)
            let head = run(res[i + 1].start, 1, res[i + 1].end - res[i + 1].start)
            let J = tail + head
            if J > o.maxPause {
                let t = target(J)
                var lt = min(tail, t / 2)
                let ht = min(head, t - lt)
                lt = min(tail, t - ht)
                res[i].end -= tail - lt
                res[i + 1].start += head - ht
            } else if !video {
                let mn = split[i].boundary ? o.minGapSentence : o.minGapPhrase
                res[i].fill = max(0, mn - J)
            }
        }
        let head = run(res[0].start, 1, res[0].end - res[0].start)  // 3) 開頭最多留 0.15 秒、結尾 0.4 秒
        res[0].start += max(0, head - 0.15)
        let l = res.count - 1
        let tail = run(res[l].end, -1, res[l].end - res[l].start)
        res[l].end -= max(0, tail - 0.4)
        return res.filter { $0.end - $0.start > 0.02 }
    }

    /// 停頓中高出底噪 margin dB 以上的聲音（呼吸、雜音）壓到接近底噪；人聲與保留的字不動。回傳每格的線性增益
    public static func breathGain(_ a: Analysis, keepWords: [Word], margin: Float, maxCut: Float) -> [Float] {
        let E = a.E, hopS = a.hopS
        if maxCut <= 0 { return [Float](repeating: 1, count: E.count) }
        var ns = [Bool](repeating: true, count: E.count)
        for s in a.speech + keepWords.map({ Span($0.start, $0.end) }) {
            let lo = max(0, Int((s.start - 0.06) / hopS)), hi = min(E.count, Int((s.end + 0.06) / hopS) + 1)
            if hi > lo { for k in lo..<hi { ns[k] = false } }
        }
        var g = [Float](repeating: 0, count: E.count)
        var any = false
        for k in E.indices {
            let over = E[k] - (a.floor + margin)
            if ns[k] && over > 0 {
                g[k] = -min(over, maxCut)
                any = true
            }
        }
        if any {  // 前後 25ms 取最小值再平滑，避免增益跳動
            let n = g.count
            var mn = [Float](repeating: 0, count: n)
            for i in 0..<n {
                var v = g[i]
                for d in -5...5 { v = min(v, g[min(n - 1, max(0, i + d))]) }
                mn[i] = v
            }
            for i in 0..<n {  // np.convolve(g, ones(8)/8, mode="same")
                var s: Float = 0
                for d in -4...3 where i + d >= 0 && i + d < n { s += mn[i + d] }
                g[i] = s / 8
            }
        }
        return g.map { pow(10, $0 / 20) }
    }

    /// 算出要輸出的片段（原檔片段＋合成底噪）。words 須已決定 keep / cut。
    /// fps 不為 nil 時（影片）邊界對齊影格、不補底噪，影音才能同步
    public static func segments(_ words: [Word], analysis a: Analysis, duration: Double, options o: RenderOptions,
                                fps: Double?, gain: [Float]) throws -> [Seg] {
        if o.maxPause < o.keepPause { throw RenderError.badPause }
        let quiet = a.E.indices.map { a.E[$0] + 20 * log10(gain[$0] + 1e-9) < a.floor + o.quietDb }
        var pieces = try planPieces(words, o, duration: duration)
        pieces = snapPieces(pieces, E: a.E, hopS: a.hopS, win: o.snap)
        pieces = shapeSilence(pieces, quiet: quiet, hopS: a.hopS, o, video: fps != nil)
        if let fps, fps > 0 {  // 對齊影格，避免多次剪接後影音不同步
            let snap = { (t: Double) in (t * fps).rounded(.toNearestOrEven) / fps }
            pieces = pieces.map { Piece(start: snap($0.start), end: snap($0.end)) }.filter { $0.end > $0.start }
        }
        // 結尾不超過檔案長度；影片要往下取到完整的影格，避免最後一格只有一半
        let maxEnd = fps.map { ($0 > 0 ? (duration * $0 + 1e-9).rounded(.down) / $0 : duration) } ?? duration
        pieces = pieces.map { Piece(start: max(0, $0.start), end: min(maxEnd, $0.end), fill: $0.fill) }
            .filter { $0.end - $0.start > 0.01 }
        if pieces.isEmpty { throw RenderError.nothingKept }
        var segs: [Seg] = []
        for p in pieces {
            segs.append(Seg(p.start, p.end, .src))
            if p.fill > 0.005 && a.noise != nil && o.roomtone {
                segs.append(Seg(0, p.fill, .noise))
            }
        }
        return segs
    }

    /// 依序接合片段；每個接點做長度不變的等功率交叉淡化（前段多取 h、後段提早 h 開始）。
    /// 接點附近有聲音時用較長的淡化，避免爆音與突兀。write 收到交錯排列的 Float 樣本。回傳輸出秒數
    @discardableResult
    public static func synthesize(_ src: PCMSource, segs: [Seg], analysis a: Analysis, gain: [Float],
                                  options o: RenderOptions, write: ([Float]) throws -> Void) throws -> Double {
        let sr = Double(src.sampleRate), ch = src.channels, hop = a.hop, E = a.E
        let n = segs.map { pyRound($0.end * sr) - pyRound($0.start * sr) }
        func level(_ t: Double) -> Float { E[min(E.count - 1, max(0, Int(t * sr / Double(hop))))] }

        var hs: [Int] = []
        for i in 1..<max(1, segs.count) {
            let p = segs[i - 1], q = segs[i]
            let loud = max(p.kind != .noise ? level(p.end) : a.floor, q.kind != .noise ? level(q.start) : a.floor)
            let h = loud > a.floor + 20 ? o.xfadeLong : o.xfade
            hs.append(max(1, min(Int(h / 2 * sr), n[i - 1] / 2, n[i] / 2)))
        }
        var tail: [Float] = []
        var total = 0
        for (i, s) in segs.enumerated() {
            let hin = i > 0 ? hs[i - 1] : 0
            let hout = i < segs.count - 1 ? hs[i] : 0
            let L = n[i] + hin + hout
            var buf: [Float]
            if s.kind == .noise, let prof = a.noise {
                let mono = makeNoise(L, prof, seed: i)
                buf = [Float](repeating: 0, count: L * ch)
                for f in 0..<L { for c in 0..<ch { buf[f * ch + c] = mono[f] } }
            } else {
                let a0 = pyRound(s.start * sr) - hin
                buf = []
                src.read(a0, L, into: &buf)
                let lo = max(0, a0), hi = min(src.frameCount, a0 + L)
                if hi > lo {
                    for f in lo..<hi {
                        let gi = f / hop
                        if gi >= gain.count { break }
                        let g = gain[gi]
                        if g == 1 { continue }
                        for c in 0..<ch { buf[(f - a0) * ch + c] *= g }
                    }
                }
            }
            if hin > 0 {
                let m = 2 * hin
                for k in 0..<m {
                    let w = Float(sin(Double(k) * (Double.pi / 2) / Double(m - 1)))
                    for c in 0..<ch { buf[k * ch + c] = buf[k * ch + c] * w + tail[k * ch + c] }
                }
            }
            if hout > 0 {
                let m = 2 * hout, off = L - m
                for k in 0..<m {
                    let w = Float(cos(Double(k) * (Double.pi / 2) / Double(m - 1)))
                    for c in 0..<ch { buf[(off + k) * ch + c] *= w }
                }
                try write(Array(buf[0..<(off * ch)]))
                tail = Array(buf[(off * ch)...])
                total += off
            } else {
                try write(buf)
                total += L
            }
        }
        return Double(total) / sr
    }

    /// 成品時間 [t0, t1] 對回原檔時間（可能跨多個片段；合成底噪的部分略過）
    public static func toSource(_ segs: [Seg], _ t0: Double, _ t1: Double) -> [Span] {
        var out: [Span] = []
        var pos = 0.0
        for s in segs {
            let L = s.length
            let a0 = max(t0, pos), a1 = min(t1, pos + L)
            if a1 > a0 && s.kind != .noise { out.append(Span(s.start + a0 - pos, s.start + a1 - pos)) }
            pos += L
        }
        return out
    }
}
