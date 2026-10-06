import AVFoundation
import AVKit
import SwiftUI

/// 匯入後選擇要處理的範圍：整檔聲波＋兩個把手，可以試聽開頭與結尾
struct RangeSelectView: View {
    let url: URL
    let initial: ClipRange?
    /// 第一次選（新匯入的檔案）：沒有「取消」，只能用整段或選好範圍
    let firstTime: Bool
    let onDone: (ClipRange?, Double?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var info: MediaInfo?
    @State private var peaks: [Float] = []
    @State private var loadProgress = 0.0
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var player = AVPlayer()
    @State private var playhead: Double?
    @State private var stopAt: Double = 0
    @State private var observer: Any?
    @State private var error: String?

    private var duration: Double { info?.duration ?? 0 }
    private var isWhole: Bool { start < 0.05 && end > duration - 0.05 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if info?.isVideo == true {
                        VideoPlayer(player: player)
                            .frame(height: 210)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    } else if info == nil {
                        ProgressView("讀取檔案…").frame(maxWidth: .infinity)
                    } else {
                        summary
                        RangeWaveform(peaks: peaks, duration: duration, start: $start, end: $end, playhead: playhead)
                            .frame(height: 120)
                        if peaks.isEmpty {
                            ProgressView(value: loadProgress) { Text("產生聲波…").font(.caption) }
                        }
                        fineTune
                        preview
                        Text("拖曳兩側的把手選擇範圍，拖中間可以整段移動。只會辨識與輸出選取的部分，長檔案先剪掉不需要的開頭結尾可以省下很多時間。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    finish(isWhole ? nil : ClipRange(start: start, end: end))
                } label: {
                    Text(isWhole ? "處理整個檔案" : "處理選取的 \(ProjectModel.clock(end - start))")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(info == nil)
                .padding()
                .background(.bar)
            }
            .navigationTitle("選擇處理範圍")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if firstTime {
                        Button("用整段") { finish(nil) }
                    } else {
                        Button("取消") {
                            stop()
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("全選") {
                        start = 0
                        end = duration
                    }
                    .disabled(info == nil || isWhole)
                }
            }
        }
        .interactiveDismissDisabled(firstTime)
        .task { await load() }
        .onDisappear { stop() }
    }

    private var summary: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("開始").font(.caption).foregroundStyle(.secondary)
                Text(Self.fine(start)).font(.title3.monospacedDigit())
            }
            Spacer()
            VStack {
                Text("長度").font(.caption).foregroundStyle(.secondary)
                Text(ProjectModel.clock(end - start)).font(.title3.monospacedDigit().bold()).foregroundStyle(.tint)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text("結束").font(.caption).foregroundStyle(.secondary)
                Text(Self.fine(end)).font(.title3.monospacedDigit())
            }
        }
    }

    private var fineTune: some View {
        HStack {
            nudge("開始", value: $start, lo: 0, hi: end - 1)
            Spacer()
            nudge("結束", value: $end, lo: start + 1, hi: duration)
        }
    }

    private func nudge(_ name: String, value: Binding<Double>, lo: Double, hi: Double) -> some View {
        HStack(spacing: 4) {
            Button { value.wrappedValue = max(lo, value.wrappedValue - 0.5) } label: { Image(systemName: "minus") }
                .accessibilityLabel(name + "提早 0.5 秒")
            Text(name).font(.caption).foregroundStyle(.secondary)
            Button { value.wrappedValue = min(hi, value.wrappedValue + 0.5) } label: { Image(systemName: "plus") }
                .accessibilityLabel(name + "延後 0.5 秒")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var preview: some View {
        HStack {
            Button {
                playhead == nil ? play(from: start, to: min(end, start + 8)) : stop()
            } label: {
                Label(playhead == nil ? "試聽開頭" : "停止", systemImage: playhead == nil ? "play.fill" : "stop.fill")
            }
            Spacer()
            Button {
                play(from: max(start, end - 5), to: end)
            } label: {
                Label("試聽結尾", systemImage: "forward.end.fill")
            }
            .disabled(playhead != nil)
        }
        .buttonStyle(.bordered)
    }

    private func load() async {
        do {
            let i = try await MediaIO.info(url)
            info = i
            start = min(initial?.start ?? 0, i.duration)
            end = min(initial?.end ?? i.duration, i.duration)
            if end - start < 1 {
                start = 0
                end = i.duration
            }
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            let bins = 320
            peaks = try await MediaIO.peaks(url, duration: i.duration, bins: bins) { p in
                Task { @MainActor in loadProgress = p }
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func play(from a: Double, to b: Double) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        stopAt = b
        player.seek(to: CMTime(seconds: a, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = a
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { t in
            MainActor.assumeIsolated {
                let s = t.seconds
                if s >= stopAt { stop() } else { playhead = s }
            }
        }
        player.play()
    }

    private func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        playhead = nil
    }

    private func finish(_ r: ClipRange?) {
        stop()
        onDone(r, info?.fps)
        dismiss()
    }

    /// 例如 1:05.3
    static func fine(_ t: Double) -> String {
        let t = max(0, t)
        let tenths = Int((t * 10).rounded(.down)) % 10
        return ProjectModel.clock(t) + ".\(tenths)"
    }
}

/// 整檔聲波＋兩個把手；範圍外變暗
private struct RangeWaveform: View {
    let peaks: [Float]
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    let playhead: Double?

    private enum Target { case start, end, move }
    @State private var target: Target?
    @State private var origin = (start: 0.0, end: 0.0)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Canvas { gc, size in draw(gc, size) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in drag(g, width: w) }
                    .onEnded { _ in target = nil })
        }
        .accessibilityElement()
        .accessibilityLabel("選取範圍")
        .accessibilityValue("從 \(RangeSelectView.fine(start)) 到 \(RangeSelectView.fine(end))")
        .accessibilityAdjustableAction { dir in
            let step = max(1, duration / 50)
            switch dir {
            case .increment: end = min(duration, end + step)
            case .decrement: end = max(start + 1, end - step)
            @unknown default: break
            }
        }
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { duration > 0 ? CGFloat(t / duration) * w : 0 }

    private func drag(_ g: DragGesture.Value, width w: CGFloat) {
        guard duration > 0, w > 0 else { return }
        if target == nil {
            let sx = x(start, w), ex = x(end, w), px = g.startLocation.x
            let ds = abs(px - sx), de = abs(px - ex)
            if min(ds, de) < 28 {
                target = ds <= de ? .start : .end
            } else if px > sx && px < ex {
                target = .move
            } else {
                target = px < sx ? .start : .end
            }
            origin = (start, end)
        }
        let minLen = min(1, duration)
        let t = Double(g.location.x / w) * duration
        switch target {
        case .start: start = min(max(0, t), end - minLen)
        case .end: end = max(min(duration, t), start + minLen)
        case .move:
            let len = origin.end - origin.start
            let d = Double(g.translation.width / w) * duration
            let s = min(max(0, origin.start + d), duration - len)
            start = s
            end = s + len
        case nil: break
        }
    }

    private func draw(_ gc: GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        let lane = CGRect(x: 0, y: 14, width: w, height: h - 28)
        let accent = Color.accentColor
        // 聲波
        if peaks.isEmpty {
            gc.fill(Path(CGRect(x: 0, y: lane.midY - 1, width: w, height: 2)), with: .color(.secondary.opacity(0.4)))
        } else {
            let n = peaks.count
            let bw = w / CGFloat(n)
            for i in 0..<n {
                let t = (Double(i) + 0.5) / Double(n) * duration
                let inside = t >= start && t <= end
                let bh = max(1.5, CGFloat(peaks[i]) * lane.height)
                let r = CGRect(x: CGFloat(i) * bw, y: lane.midY - bh / 2, width: max(1, bw * 0.75), height: bh)
                gc.fill(Path(r), with: .color(inside ? accent.opacity(0.85) : .secondary.opacity(0.35)))
            }
        }
        // 範圍外變暗、範圍框
        let sx = x(start, w), ex = x(end, w)
        gc.fill(Path(CGRect(x: 0, y: 0, width: sx, height: h)), with: .color(.black.opacity(0.18)))
        gc.fill(Path(CGRect(x: ex, y: 0, width: w - ex, height: h)), with: .color(.black.opacity(0.18)))
        gc.stroke(Path(roundedRect: CGRect(x: sx, y: 6, width: ex - sx, height: h - 12), cornerRadius: 6),
                  with: .color(accent), lineWidth: 2)
        // 把手
        for hx in [sx, ex] {
            let knob = CGRect(x: hx - 7, y: h / 2 - 22, width: 14, height: 44)
            gc.fill(Path(roundedRect: knob, cornerRadius: 7), with: .color(accent))
            gc.fill(Path(roundedRect: CGRect(x: hx - 1, y: h / 2 - 10, width: 2, height: 20), cornerRadius: 1),
                    with: .color(.white.opacity(0.9)))
        }
        // 試聽位置
        if let p = playhead {
            let px = x(p, w)
            gc.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: h)), with: .color(.orange))
        }
    }
}
