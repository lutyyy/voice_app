import Foundation

/// 基本的 radix-2 FFT（底噪頻譜分析與合成用；Accelerate 在 Linux 上沒有）
enum FFT {
    /// 原地複數 FFT，長度必須是 2 的次方；inverse 時不做 1/n 縮放
    static func transform(_ re: inout [Double], _ im: inout [Double], inverse: Bool = false) {
        let n = re.count
        precondition(n > 0 && n & (n - 1) == 0, "FFT 長度必須是 2 的次方")
        var j = 0
        for i in 1..<max(n, 2) where i < n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j |= bit
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
        var len = 2
        while len <= n {
            let ang = 2 * Double.pi / Double(len) * (inverse ? 1 : -1)
            let wr = cos(ang), wi = sin(ang)
            var i = 0
            while i < n {
                var cr = 1.0, ci = 0.0
                for k in 0..<(len / 2) {
                    let a = i + k, b = i + k + len / 2
                    let tr = re[b] * cr - im[b] * ci
                    let ti = re[b] * ci + im[b] * cr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                    let ncr = cr * wr - ci * wi
                    ci = cr * wi + ci * wr
                    cr = ncr
                }
                i += len
            }
            len <<= 1
        }
    }

    /// 實數 FFT：回傳前 n/2+1 個頻率的 (re, im)
    static func rfft(_ x: [Double]) -> ([Double], [Double]) {
        var re = x, im = [Double](repeating: 0, count: x.count)
        transform(&re, &im)
        let h = x.count / 2 + 1
        return (Array(re[0..<h]), Array(im[0..<h]))
    }

    /// rfft 的反轉換（長度 n，含 1/n 縮放）
    static func irfft(_ re: [Double], _ im: [Double], n: Int) -> [Double] {
        var fr = [Double](repeating: 0, count: n), fi = [Double](repeating: 0, count: n)
        for k in 0..<min(re.count, n / 2 + 1) {
            fr[k] = re[k]
            fi[k] = im[k]
        }
        // 共軛對稱補齊負頻率；DC 與 Nyquist 的虛部視為 0
        fi[0] = 0
        if n % 2 == 0 { fi[n / 2] = 0 }
        for k in 1..<(n / 2 + (n % 2)) where n - k > n / 2 {
            fr[n - k] = fr[k]
            fi[n - k] = -fi[k]
        }
        transform(&fr, &fi, inverse: true)
        return fr.map { $0 / Double(n) }
    }
}

/// 可重現的亂數（SplitMix64 + Box-Muller），合成底噪用
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func normal() -> Double {
        let u1 = max(uniform(), 1e-300), u2 = uniform()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
