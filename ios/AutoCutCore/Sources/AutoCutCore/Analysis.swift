import Foundation

/// numpy.percentile（線性內插）
func percentile(_ a: [Float], _ q: Double) -> Float {
    if a.isEmpty { return 0 }
    let s = a.sorted()
    let pos = q / 100 * Double(s.count - 1)
    let lo = Int(pos.rounded(.down)), hi = min(s.count - 1, lo + 1)
    let f = Float(pos - Double(lo))
    return s[lo] + (s[hi] - s[lo]) * f
}

/// 每 hop 個影格一格的音量（dB）
public func energyDB(_ src: PCMSource, hop: Int) -> [Float] {
    let n = src.frameCount / hop
    var out = [Float](repeating: 0, count: n)
    let block = hop * 4000
    var f0 = 0
    while f0 < n * hop {
        let cnt = min(block, n * hop - f0)
        let x = src.readMono(f0, cnt)
        for k in 0..<(cnt / hop) {
            var s: Float = 0
            for i in 0..<hop {
                let v = x[k * hop + i]
                s += v * v
            }
            out[f0 / hop + k] = 20 * log10(sqrt(s / Float(hop)) + 1e-9)
        }
        f0 += cnt
    }
    return out
}

/// 以音量偵測人聲區間（取代 Python 版的 Silero VAD）。
/// 門檻取「底噪 + minAboveFloor」與「響亮處 - belowPeak」較高者，避開呼吸聲與雜音；
/// 再把短於 minSilence 的空隙接起來、丟掉短於 minSpeech 的片段、前後各留 pad
public struct EnergyVAD: Codable, Equatable, Sendable {
    public var minAboveFloor: Float = 18
    public var belowPeak: Float = 35
    public var minSilence: Double = 0.15
    public var minSpeech: Double = 0.1
    public var pad: Double = 0.03
    public init() {}

    public func regions(E: [Float], hopS: Double) -> [Span] {
        if E.isEmpty { return [] }
        let floor = percentile(E, 5), peak = percentile(E, 95)
        let thr = max(floor + minAboveFloor, peak - belowPeak)
        var raw: [Span] = []
        var i = 0
        while i < E.count {
            if E[i] <= thr {
                i += 1
                continue
            }
            var j = i
            while j < E.count && E[j] > thr { j += 1 }
            raw.append(Span(Double(i) * hopS, Double(j) * hopS))
            i = j
        }
        var merged: [Span] = []
        for r in raw {
            if let last = merged.last, r.start - last.end < minSilence {
                merged[merged.count - 1].end = r.end
            } else {
                merged.append(r)
            }
        }
        let total = Double(E.count) * hopS
        return merged.filter { $0.end - $0.start >= minSpeech }
            .map { Span(max(0, $0.start - pad), min(total, $0.end + pad)) }
    }
}

/// 底噪的平均頻譜，用來合成「環境底噪」填補太短的停頓
public struct NoiseProfile: Codable, Equatable, Sendable {
    public var psd: [Double]
    public var rms: Double
}

/// 原始檔的分析結果；多輪輸出時共用，不必每次重新計算
public struct Analysis: Sendable {
    public let sampleRate: Int
    public let hop: Int
    public let hopS: Double
    public let E: [Float]
    public let floor: Float
    public let speech: [Span]
    public let noise: NoiseProfile?

    public init(src: PCMSource, speech: [Span]? = nil, vad: EnergyVAD = EnergyVAD()) {
        sampleRate = src.sampleRate
        hop = max(1, src.sampleRate / 200)
        hopS = Double(hop) / Double(sampleRate)
        E = energyDB(src, hop: hop)
        floor = percentile(E, 5)
        self.speech = speech ?? vad.regions(E: E, hopS: hopS)
        noise = Analysis.noiseProfile(src: src, E: E, speech: self.speech, hop: hop, floor: floor)
    }

    /// 測試用：直接給定音量序列
    init(sampleRate: Int, hop: Int, E: [Float], floor: Float, speech: [Span], noise: NoiseProfile? = nil) {
        self.sampleRate = sampleRate
        self.hop = hop
        hopS = Double(hop) / Double(sampleRate)
        self.E = E
        self.floor = floor
        self.speech = speech
        self.noise = noise
    }

    /// 取最安靜、沒有人聲的片段，算出底噪的平均頻譜。
    /// 不直接複製原音：口語錄音常常找不到夠長的純靜音，短片段重複貼上會聽得出來、甚至帶到人聲
    static func noiseProfile(src: PCMSource, E: [Float], speech: [Span], hop: Int, floor: Float) -> NoiseProfile? {
        let hopS = Double(hop) / Double(src.sampleRate)
        var quiet = E.map { $0 < floor + 3 }
        for s in speech {
            let a = max(0, Int((s.start - 0.1) / hopS)), b = min(quiet.count, Int((s.end + 0.1) / hopS))
            if b > a { for k in a..<b { quiet[k] = false } }
        }
        let idx = quiet.indices.filter { quiet[$0] }
        if idx.count < 20 { return nil }
        let N = 1024
        let win = (0..<N).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(N - 1)) }
        var P = [Double](repeating: 0, count: N / 2 + 1)
        var cnt = 0
        let m = min(300, idx.count)
        for t in 0..<m {
            let pos = m == 1 ? 0 : Int(Double(t) * Double(idx.count - 1) / Double(m - 1))
            let k = idx[pos]
            if k * hop + N > src.frameCount { continue }
            let x = src.readMono(k * hop, N)
            let (re, im) = FFT.rfft((0..<N).map { Double(x[$0]) * win[$0] })
            for f in 0..<P.count { P[f] += re[f] * re[f] + im[f] * im[f] }
            cnt += 1
        }
        if cnt == 0 { return nil }
        let rms = sqrt(idx.map { pow(10, Double(E[$0]) / 10) }.reduce(0, +) / Double(idx.count))
        return NoiseProfile(psd: P.map { $0 / Double(cnt) }, rms: rms)
    }
}

/// 依底噪頻譜合成指定長度的雜訊（每次隨機，不會有重複感）；回傳單聲道
func makeNoise(_ n: Int, _ prof: NoiseProfile, seed: Int) -> [Float] {
    var rng = SeededRandom(seed: UInt64(seed))
    var m = 2048
    while m < max(n, 2) { m <<= 1 }
    var (re, im) = FFT.rfft((0..<m).map { _ in rng.normal() })
    let L = re.count, P = prof.psd.count
    for k in 0..<L {
        // np.interp(linspace(0,1,L), linspace(0,1,P), psd)
        let x = L == 1 ? 0 : Double(k) / Double(L - 1) * Double(P - 1)
        let i = min(P - 2, Int(x)), f = x - Double(i)
        let v = P == 1 ? prof.psd[0] : prof.psd[i] + (prof.psd[i + 1] - prof.psd[i]) * f
        let g = sqrt(max(0, v))
        re[k] *= g
        im[k] *= g
    }
    var y = Array(FFT.irfft(re, im, n: m).prefix(n))
    let cur = sqrt(y.map { $0 * $0 }.reduce(0, +) / Double(max(1, y.count)))
    let scale = prof.rms / (cur + 1e-12)
    for i in y.indices { y[i] *= scale }
    return y.map { Float($0) }
}
