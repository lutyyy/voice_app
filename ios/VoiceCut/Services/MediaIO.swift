import AVFoundation
import AutoCutCore
import Foundation

/// 影音檔的基本資訊
struct MediaInfo: Codable, Equatable {
    var duration: Double
    /// 影片的影格率；純音訊為 nil
    var fps: Double?
    var sampleRate: Int
    var channels: Int
    var isVideo: Bool { fps != nil }
}

enum MediaError: LocalizedError {
    case noAudio
    case readFailed(String)
    case exportFailed(String)
    var errorDescription: String? {
        switch self {
        case .noAudio: return "這個檔案沒有聲音"
        case .readFailed(let m): return "讀取檔案失敗：\(m)"
        case .exportFailed(let m): return "輸出失敗：\(m)"
        }
    }
}

enum MediaIO {
    static func info(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let audio = try await asset.loadTracks(withMediaType: .audio).first else { throw MediaError.noAudio }
        var sr = 44100, ch = 1
        if let fd = try await audio.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
            sr = Int(asbd.mSampleRate)
            ch = Int(asbd.mChannelsPerFrame)
        }
        var fps: Double?
        if let video = try await asset.loadTracks(withMediaType: .video).first {
            let f = Double(try await video.load(.nominalFrameRate))
            fps = f > 0 ? f : 30
        }
        // AAC 編碼最高 48kHz；超過的話解碼時就降下來
        return MediaInfo(duration: duration, fps: fps, sampleRate: min(max(sr, 8000), 48000), channels: min(max(ch, 1), 2))
    }

    /// 解碼成 Float32 交錯排列（AVAssetReader 會順便重新取樣與混音），逐段交給 sink
    static func decode(_ url: URL, sampleRate: Int, channels: Int,
                       progress: ((Double) -> Void)? = nil, sink: (UnsafeBufferPointer<Float>) throws -> Void) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        if tracks.isEmpty { throw MediaError.noAudio }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw MediaError.readFailed(reader.error?.localizedDescription ?? "") }
        var frames = 0
        var scratch = [Float]()
        while let sb = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let bytes = CMBlockBufferGetDataLength(bb)
            let n = bytes / 4
            if scratch.count < n { scratch = [Float](repeating: 0, count: n) }
            try scratch.withUnsafeMutableBytes { raw in
                guard CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: bytes, destination: raw.baseAddress!) == noErr else {
                    throw MediaError.readFailed("無法複製音訊資料")
                }
            }
            try scratch.withUnsafeBufferPointer { try sink(UnsafeBufferPointer(rebasing: $0[0..<n])) }
            frames += n / channels
            if duration > 0 { progress?(min(1, Double(frames) / Double(sampleRate) / duration)) }
        }
        if reader.status == .failed { throw MediaError.readFailed(reader.error?.localizedDescription ?? "") }
    }

    /// 解碼成原始 Float32 檔（之後以記憶體映射讀取，長檔也不吃記憶體）
    static func decodeToFile(_ url: URL, to raw: URL, sampleRate: Int, channels: Int,
                             progress: ((Double) -> Void)? = nil) async throws {
        FileManager.default.createFile(atPath: raw.path, contents: nil)
        let fh = try FileHandle(forWritingTo: raw)
        defer { try? fh.close() }
        try await decode(url, sampleRate: sampleRate, channels: channels, progress: progress) { buf in
            try fh.write(contentsOf: Data(buffer: buf))
        }
    }

    /// 解碼成 16kHz 單聲道（Whisper 的輸入格式）
    static func decode16k(_ url: URL, progress: ((Double) -> Void)? = nil) async throws -> [Float] {
        var out = [Float]()
        try await decode(url, sampleRate: 16000, channels: 1, progress: progress) { out.append(contentsOf: $0) }
        return out
    }
}

/// 把交錯排列的 Float 樣本寫成 m4a（AAC）或 wav
final class AudioFileWriter {
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let channels: Int

    init(url: URL, sampleRate: Int, channels: Int, wav: Bool, bitRate: Int = 128_000) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = wav ? [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ] : [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        format = file.processingFormat
        self.channels = channels
    }

    func write(_ samples: [Float]) throws {
        let frames = samples.count / channels
        if frames == 0 { return }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        let dst = buf.floatChannelData!
        for c in 0..<channels {
            let p = dst[c]
            for f in 0..<frames { p[f] = max(-1, min(1, samples[f * channels + c])) }
        }
        try file.write(from: buf)
    }
}

enum VideoExporter {
    /// 依片段剪接影片畫面，配上已經剪好的音訊，輸出 mp4
    static func export(source: URL, segs: [Seg], audio: URL, to out: URL,
                       progress: ((Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: source)
        guard let vt = try await asset.loadTracks(withMediaType: .video).first else { throw MediaError.exportFailed("找不到影像") }
        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaError.exportFailed("無法建立剪輯")
        }
        cv.preferredTransform = try await vt.load(.preferredTransform)
        let ts: CMTimeScale = 90000
        var cursor = CMTime.zero
        for s in segs where s.kind == .src {
            let range = CMTimeRange(start: CMTime(seconds: s.start, preferredTimescale: ts),
                                    end: CMTime(seconds: s.end, preferredTimescale: ts))
            try cv.insertTimeRange(range, of: vt, at: cursor)
            cursor = cursor + range.duration
        }
        let aAsset = AVURLAsset(url: audio)
        if let at = try await aAsset.loadTracks(withMediaType: .audio).first {
            let aDur = try await aAsset.load(.duration)
            try ca.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(aDur, cursor)), of: at, at: .zero)
        }
        try? FileManager.default.removeItem(at: out)
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw MediaError.exportFailed("無法建立輸出工作")
        }
        ex.outputURL = out
        ex.outputFileType = .mp4
        ex.shouldOptimizeForNetworkUse = true
        let timer = Task {
            while !Task.isCancelled {
                progress?(Double(ex.progress))
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { timer.cancel() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            ex.exportAsynchronously { c.resume() }
        }
        if ex.status != .completed {
            throw MediaError.exportFailed(ex.error?.localizedDescription ?? "未知錯誤")
        }
    }
}
