import AVFoundation
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

    /// 播放 url 的 [a, b)；offset 是逐字稿時間 0 在檔案中的位置（只處理一段時）
    func play(_ url: URL, from a: Double, to b: Double, offset: Double = 0, id: String, tracksTranscript: Bool = true) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        if self.url != url {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
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
        player.play()
    }

    private func tick(_ s: Double) {
        let t = s - offset
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
        current = nil
        playingID = nil
    }
}
