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
        player.seek(to: CMTime(seconds: max(0, a + offset), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
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
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        current = nil
        playingID = nil
    }
}
