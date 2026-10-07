import AVFoundation
import AutoCutCore
import Foundation

/// 試聽一小段（原檔或剪好的檔案），播到指定時間自動停
@MainActor
final class ClipPlayer: ObservableObject {
    /// 正在播的位置（逐字稿的時間；試聽成品時為 nil）
    @Published private(set) var current: Double?
    /// 正在播的項目（畫面用來把按鈕變成「停止」）
    @Published private(set) var playingID: String?

    private let player = AVPlayer()
    private var url: URL?
    private var observer: Any?
    private var stopAt = 0.0
    private var offset = 0.0
    private var tracksTranscript = false
    /// 每次播放的識別；跳轉完成時已經換播別段就不動作
    private var token: UUID?
    private var skip: [Span] = []
    /// 最後播到的位置（逐字稿時間），暫停後從這裡繼續
    private(set) var lastTime: Double?
    private var boundary: Any?

    /// 播放 url 的 [a, b)；offset 是逐字稿時間 0 在檔案中的位置（只處理一段時）
    /// skip：播放時跳過的區段（逐字稿時間；預覽剪後用：跳過被剪掉的字）
    func play(_ url: URL, from a: Double, to b: Double, offset: Double = 0, id: String, tracksTranscript: Bool = true,
              skip: [Span] = []) {
        stop()
        self.skip = skip.filter { $0.end > a }
        var a = a
        // 起點剛好在剪掉的地方就直接從後面開始
        if let s = self.skip.first(where: { $0.start <= a && a < $0.end }) { a = s.end }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        if self.url != url {
            player.replaceCurrentItem(with: AVPlayerItem(asset: AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])))
            self.url = url
        }
        self.offset = offset
        self.tracksTranscript = tracksTranscript
        stopAt = b
        playingID = id
        current = tracksTranscript ? a : nil
        let token = UUID()
        self.token = token
        // 跳轉完成後才開始計時與播放，否則可能先讀到舊位置就以為播完了
        player.seek(to: CMTime(seconds: max(0, a + offset), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.startPlayback(token) }
        }
    }

    private func startPlayback(_ token: UUID) {
        guard self.token == token else { return }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        // 剛好在每段要跳過的開頭觸發，比每 1/30 秒檢查一次準
        if !skip.isEmpty {
            let times = skip.map { NSValue(time: CMTime(seconds: $0.start + offset, preferredTimescale: 600)) }
            boundary = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.jumpIfInSkip() }
            }
        }
        player.play()
    }

    /// 在要跳過的區段裡就跳到它的結尾
    private func jumpIfInSkip() {
        let t = player.currentTime().seconds - offset
        guard let s = skip.first(where: { $0.start - 0.02 <= t && t < $0.end - 0.01 }) else { return }
        player.seek(to: CMTime(seconds: s.end + offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func tick(_ s: Double) {
        let t = s - offset
        if tracksTranscript { lastTime = t }
        if !skip.isEmpty { jumpIfInSkip() }
        if t >= stopAt {
            stop()
        } else if tracksTranscript {
            current = t
        }
    }

    func stop() {
        token = nil
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        if let boundary { player.removeTimeObserver(boundary) }
        boundary = nil
        current = nil
        playingID = nil
    }
}
