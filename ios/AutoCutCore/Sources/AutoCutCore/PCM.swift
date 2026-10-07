import Foundation

/// 解碼後的音訊（Float32、交錯排列、範圍 -1～1）
public protocol PCMSource: AnyObject {
    var sampleRate: Int { get }
    var channels: Int { get }
    var frameCount: Int { get }
    /// 讀取 [start, start+count) 的影格到 out（交錯排列；超出範圍補 0）
    func read(_ start: Int, _ count: Int, into out: inout [Float])
}

extension PCMSource {
    public var duration: Double { Double(frameCount) / Double(sampleRate) }

    /// 讀一段並混成單聲道
    public func readMono(_ start: Int, _ count: Int) -> [Float] {
        var buf: [Float] = []
        read(start, count, into: &buf)
        if channels == 1 { return buf }
        var out = [Float](repeating: 0, count: count)
        let inv = 1 / Float(channels)
        for f in 0..<count {
            var s: Float = 0
            for c in 0..<channels { s += buf[f * channels + c] }
            out[f] = s * inv
        }
        return out
    }
}

/// 記憶體中的音訊（測試用、或短檔案）
public final class ArrayPCM: PCMSource {
    public let sampleRate: Int
    public let channels: Int
    public let samples: [Float]
    public var frameCount: Int { samples.count / channels }

    public init(samples: [Float], sampleRate: Int, channels: Int = 1) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public func read(_ start: Int, _ count: Int, into out: inout [Float]) {
        out = [Float](repeating: 0, count: count * channels)
        let lo = max(0, start), hi = min(frameCount, start + count)
        if hi <= lo { return }
        for f in lo..<hi {
            for c in 0..<channels {
                out[(f - start) * channels + c] = samples[f * channels + c]
            }
        }
    }
}

/// 以記憶體映射讀取的原始 Float32 檔（長檔案也不會吃光記憶體，對應 Python 版的 memmap）
public final class MappedPCM: PCMSource {
    public let sampleRate: Int
    public let channels: Int
    public let frameCount: Int
    private let data: Data

    public init(url: URL, sampleRate: Int, channels: Int) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        self.sampleRate = sampleRate
        self.channels = channels
        frameCount = data.count / (4 * channels)
    }

    public func read(_ start: Int, _ count: Int, into out: inout [Float]) {
        out = [Float](repeating: 0, count: count * channels)
        let lo = max(0, start), hi = min(frameCount, start + count)
        if hi <= lo { return }
        let ch = channels
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Float.self)
            out.withUnsafeMutableBufferPointer { dst in
                let n = (hi - lo) * ch
                let d = (lo - start) * ch
                for i in 0..<n { dst[d + i] = src[lo * ch + i] }
            }
        }
    }
}
