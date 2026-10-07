import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// 匯入後選擇要處理的範圍：上面是影片（點一下播放選取的部分），下面是聲波＋兩個把手，拖把手時畫面跟著跳
struct RangeSelectView: View {
    let url: URL
    let initial: ClipRange?
    /// 第一次選（新匯入的檔案）：取消時可以選擇刪掉這個專案
    let firstTime: Bool
    /// 範圍、影格率、說話人數（只有第一次選時有：1 = 一個人、0 = 自動、2 以上 = 指定）
    let onDone: (ClipRange?, Double?, Int?) -> Void
    /// 第一次選時按「取消 › 刪除這個專案」
    var onDiscard: () -> Void = {}

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
    @State private var confirmShort = false
    @State private var confirmCancel = false
    @State private var playToken: UUID?
    /// 放大倍率與畫面左緣的時間（放大後只顯示一段，方便微調）
    @State private var zoom = 1.0
    @State private var viewStart = 0.0
    /// 說話人數：記住上次選的
    @AppStorage("lastSpeakers") private var speakers = 1
    @AppStorage("rangeHintSeen") private var hintSeen = false
    @EnvironmentObject private var settings: AppSettings
    @State private var showOptions = false
    @State private var tuneSpeed = false
    @State private var tuneCut = false
    /// 最後拖的是哪個把手（放大鏡放大那裡、畫面跳到那裡）
    @State private var editingEnd = false
    @State private var nudging: Bool?

    private var duration: Double { info?.duration ?? 0 }
    private var isWhole: Bool { start < 0.05 && end > duration - 0.05 }
    private var isVideo: Bool { info?.isVideo == true }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                screen
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        } else if info == nil {
                            ProgressView("讀取檔案…").frame(maxWidth: .infinity).padding(.top, 30)
                        } else {
                            times
                            if zoom > 1.01 {
                                Overview(peaks: peaks, duration: duration, start: start, end: end,
                                         viewStart: $viewStart, span: span)
                                    .frame(height: 28)
                            }
                            RangeWaveform(peaks: peaks, duration: duration, start: $start, end: $end, playhead: playhead,
                                          zoom: $zoom, viewStart: $viewStart, maxZoom: maxZoom) { t, isEnd in
                                    editingEnd = isEnd
                                    scrub(t)
                                }
                                .frame(height: 110)
                                .overlay(alignment: .topTrailing) { zoomButtons }
                            if peaks.isEmpty {
                                ProgressView(value: loadProgress) { Text("產生聲波…").font(.caption) }
                            }
                            if !hintSeen {
                                Text("拖兩側把手選範圍，畫面會跟著跳到那裡；拖中間整段移動。兩指捏合或按放大鏡可以放大微調，點上面的時間可以一次調 0.1 秒。只處理選取的部分，長檔案先去掉不要的開頭結尾可以省很多時間。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if firstTime { optionsRow }
                    Button {
                        if !isWhole && end - start < min(30, duration * 0.5) {
                            confirmShort = true
                        } else {
                            finish(isWhole ? nil : ClipRange(start: start, end: end))
                        }
                    } label: {
                        Text(startTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(info == nil)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("選擇範圍")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if firstTime {
                            confirmCancel = true
                        } else {
                            stop()
                            dismiss()
                        }
                    }
                    .confirmationDialog("取消新增？", isPresented: $confirmCancel, titleVisibility: .visible) {
                        Button("刪除這個專案", role: .destructive) {
                            stop()
                            onDiscard()
                            dismiss()
                        }
                        Button("保留，稍後再處理") {
                            stop()
                            dismiss()
                        }
                        Button("繼續選範圍", role: .cancel) {}
                    } message: {
                        Text("原始檔案不會受影響。")
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
            .sheet(isPresented: $showOptions) { optionsSheet }
        }
        .alert("只處理 \(ProjectModel.clock(end - start))？", isPresented: $confirmShort) {
            Button("只處理這段") { finish(ClipRange(start: start, end: end)) }
            Button("處理整個檔案") { finish(nil) }
            Button("再調整", role: .cancel) {}
        } message: {
            Text("選取的範圍很短（\(Self.fine(start)) – \(Self.fine(end))），只有這段會被辨識與輸出。")
        }
        .task { await load() }
        .onDisappear { stop() }
    }

    /// 畫面上看得到的長度
    private var span: Double { duration / max(1, zoom) }
    /// 最多放大到畫面只剩約 2 秒
    private var maxZoom: Double { max(1, duration / 2) }

    /// 放大到約 20 秒寬，並把 t 放在畫面中間
    private func focus(_ t: Double) {
        let z = max(zoom, min(maxZoom, duration / 20))
        withAnimation(.easeInOut(duration: 0.25)) {
            zoom = z
            viewStart = Self.clampView(t - duration / z / 2, span: duration / z, duration: duration)
        }
    }

    /// 以 around（沒給就是目前畫面中間）為準放大縮小
    private func setZoom(_ z: Double, around t: Double? = nil) {
        let z = min(maxZoom, max(1, z))
        let center = t ?? viewStart + span / 2
        withAnimation(.easeInOut(duration: 0.25)) {
            zoom = z
            viewStart = Self.clampView(center - duration / z / 2, span: duration / z, duration: duration)
        }
    }

    static func clampView(_ v: Double, span: Double, duration: Double) -> Double {
        min(max(0, v), max(0, duration - span))
    }

    /// 最上面：影片畫面（聲音檔是一塊播放區），點一下播放選取的範圍
    @ViewBuilder
    private var screen: some View {
        ZStack {
            if isVideo {
                PlayerSurface(player: player)
            } else {
                Rectangle().fill(Color.white.opacity(0.05))
                Image(systemName: "waveform")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.accentColor.opacity(0.5))
            }
            Image(systemName: playhead == nil ? "play.fill" : "pause.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(.black.opacity(0.45), in: Circle())
                .opacity(info == nil ? 0 : 1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: isVideo ? 230 : 120)
        .background(Color.black)
        .clipped()
        .overlay(alignment: .bottomLeading) {
            if let p = playhead {
                Text(Self.fine(p))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard info != nil else { return }
            if playhead == nil { play(from: start, to: end) } else { stop() }
        }
        .accessibilityElement()
        .accessibilityLabel(playhead == nil ? "播放選取的範圍" : "停止")
        .accessibilityAddTraits(.isButton)
    }

    /// 開始／長度／結束；點開始或結束可以微調
    private var times: some View {
        HStack {
            timeButton(start, isEnd: false)
            Spacer()
            VStack(spacing: 0) {
                Text("長度").font(.caption2).foregroundStyle(.secondary)
                Text(ProjectModel.clock(end - start))
                    .font(.title3.monospacedDigit().bold())
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            timeButton(end, isEnd: true)
        }
    }

    private func timeButton(_ t: Double, isEnd: Bool) -> some View {
        Button {
            nudging = isEnd
        } label: {
            VStack(alignment: isEnd ? .trailing : .leading, spacing: 2) {
                Text(isEnd ? "結束" : "開始").font(.caption2).foregroundStyle(.secondary)
                Text(Self.fine(t))
                    .font(.body.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(nudging == isEnd ? 0.18 : 0.08), in: Capsule())
            }
        }
        .popover(isPresented: Binding(get: { nudging == isEnd }, set: { if !$0 { nudging = nil } })) {
            nudgePanel(isEnd: isEnd)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel((isEnd ? "結束 " : "開始 ") + Self.fine(t))
        .accessibilityHint("微調時間")
    }

    /// 微調：−1／−0.1／+0.1／+1 秒，畫面跟著跳
    private func nudgePanel(isEnd: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach([-1.0, -0.1, 0.1, 1.0], id: \.self) { d in
                Button((d < 0 ? "−" : "+") + (abs(d) < 1 ? "0.1" : "1")) { nudge(isEnd: isEnd, by: d) }
                    .buttonStyle(.bordered)
                    .font(.subheadline.monospacedDigit())
                    .accessibilityLabel((d < 0 ? "提早 " : "延後 ") + "\(abs(d)) 秒")
            }
        }
        .padding(12)
    }

    private func nudge(isEnd: Bool, by d: Double) {
        let minLen = min(1, duration)
        if isEnd {
            end = min(duration, max(start + minLen, end + d))
            scrub(end)
        } else {
            start = max(0, min(end - minLen, start + d))
            scrub(start)
        }
        editingEnd = isEnd
    }

    /// 放大鏡：放大到最後拖的把手附近；放大後多一顆回到全部
    private var zoomButtons: some View {
        HStack(spacing: 10) {
            if zoom > 1.01 {
                Text("\(Int(zoom.rounded()))×")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(Color.accentColor)
                Button { setZoom(1) } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .accessibilityLabel("看全部")
            }
            Button {
                let t = editingEnd ? end : start
                if zoom > 1.01 { setZoom(zoom * 2, around: t) } else { focus(t) }
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(zoom >= maxZoom || peaks.isEmpty)
            .accessibilityLabel(editingEnd ? "放大結尾" : "放大開頭")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.6), in: Capsule())
    }

    private var startTitle: String {
        isWhole ? "處理整個檔案" : "處理選取的 \(ProjectModel.clock(end - start))"
    }

    /// 人數、速度、風格收成一行，點開再改
    private var optionsRow: some View {
        Button {
            showOptions = true
        } label: {
            HStack {
                Image(systemName: speakers == 1 ? "person.fill" : "person.2.fill").foregroundStyle(Color.accentColor)
                Text(optionsSummary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("更改").font(.subheadline).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityLabel("處理設定：" + optionsSummary)
        .accessibilityHint("更改人數、速度與剪輯風格")
    }

    private var optionsSummary: String {
        let who: String
        switch speakers {
        case 0: who = "多人"
        case 1: who = "1 人"
        default: who = "\(speakers) 人"
        }
        return [who, settings.speed?.name ?? "自訂速度", settings.preset?.name ?? "自訂風格"].joined(separator: " · ")
    }

    /// 人數、速度、風格；速度和風格都有「自訂」，點了進微調頁，之後顯示目前的參數摘要
    private var optionsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("幾個人說話").font(.subheadline.weight(.semibold))
                    Picker("幾個人說話", selection: $speakers) {
                        Text("1 人").tag(1)
                        Text("2 人").tag(2)
                        Text("3 人").tag(3)
                        Text("更多").tag(0)
                    }
                    .pickerStyle(.segmented)
                    Text(speakers == 1 ? "單人口說、Vlog。" : "訪談、對談、會議：逐字稿會標出誰在說話（第一次要下載語者辨識模型，請連 Wi‑Fi）。")
                        .font(.caption).foregroundStyle(.secondary)

                    Text("處理速度").font(.subheadline.weight(.semibold)).padding(.top, 8)
                    SpeedPicker { tuneSpeed = true }
                    tuneLink(settings.speed?.note ?? "已自訂辨識模型、漏字補抓與補剪", title: "微調辨識設定") { tuneSpeed = true }

                    Text("剪輯風格").font(.subheadline.weight(.semibold)).padding(.top, 8)
                    PresetPicker { tuneCut = true }
                    tuneLink(settings.preset?.note ?? "已自訂停頓、拖音與剪接參數", title: "微調剪輯參數") { tuneCut = true }
                }
                .padding()
            }
            .navigationTitle("處理設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { showOptions = false } }
            }
            .navigationDestination(isPresented: $tuneSpeed) { AdvancedSettingsView() }
            .navigationDestination(isPresented: $tuneCut) { CutSettingsView() }
        }
        .presentationDetents([.large])
    }

    /// 說明＋「微調…」連結
    private func tuneLink(_ note: String, title: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note).font(.caption).foregroundStyle(.secondary)
            Button(action: action) {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                    Text(title)
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }

    /// 畫面跳到 t（只有影片需要；聲音檔沒有畫面）
    private func scrub(_ t: Double) {
        guard isVideo, playhead == nil else { return }
        let tol = CMTime(value: 1, timescale: 30)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol)
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
            player.replaceCurrentItem(with: AVPlayerItem(asset: AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])))
            scrub(start)
            // 每格約 20 毫秒，放大後也看得清楚；很長的檔案限制在 20 萬格
            let bins = max(320, min(200_000, Int(i.duration * 50)))
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
        playhead = a
        let token = UUID()
        playToken = token
        // 跳轉完成後才開始計時與播放，否則可能先讀到舊位置就停掉
        player.seek(to: CMTime(seconds: a, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in
                guard playToken == token else { return }
                observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { t in
                    MainActor.assumeIsolated {
                        let s = t.seconds
                        if s >= stopAt { stop() } else { playhead = s }
                    }
                }
                player.play()
            }
        }
    }

    private func stop() {
        playToken = nil
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        playhead = nil
    }

    private func finish(_ r: ClipRange?) {
        stop()
        hintSeen = true
        onDone(r, info?.fps, firstTime ? speakers : nil)
        dismiss()
    }

    /// 例如 1:05.3
    static func fine(_ t: Double) -> String {
        let t = max(0, t)
        let tenths = Int((t * 10).rounded(.down)) % 10
        return ProjectModel.clock(t) + ".\(tenths)"
    }
}

/// 把細的聲波（每格約 20 毫秒）在 [t0, t1) 之間縮成 n 根，每根取最大值
private func bars(_ peaks: [Float], duration: Double, from t0: Double, to t1: Double, count n: Int) -> [Float] {
    guard !peaks.isEmpty, duration > 0, n > 0, t1 > t0 else { return [] }
    let per = Double(peaks.count) / duration
    var out = [Float](repeating: 0, count: n)
    for k in 0..<n {
        let a = t0 + (t1 - t0) * Double(k) / Double(n)
        let b = t0 + (t1 - t0) * Double(k + 1) / Double(n)
        let i0 = max(0, min(peaks.count - 1, Int(a * per)))
        let i1 = max(i0 + 1, min(peaks.count, Int((b * per).rounded(.up))))
        var m: Float = 0
        for i in i0..<i1 { m = max(m, peaks[i]) }
        out[k] = m
    }
    return out
}

/// 放大後的整檔縮圖：框出目前看得到的部分，點或拖可以跳過去
private struct Overview: View {
    let peaks: [Float]
    let duration: Double
    let start: Double
    let end: Double
    @Binding var viewStart: Double
    let span: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Canvas { gc, size in
                let h = size.height
                let n = max(1, Int(w / 3))
                let bs = bars(peaks, duration: duration, from: 0, to: duration, count: n)
                let bw = w / CGFloat(max(1, bs.count))
                for (i, v) in bs.enumerated() {
                    let t = (Double(i) + 0.5) / Double(bs.count) * duration
                    let bh = max(1, CGFloat(v) * h * 0.8)
                    gc.fill(Path(CGRect(x: CGFloat(i) * bw, y: h / 2 - bh / 2, width: max(1, bw * 0.7), height: bh)),
                            with: .color(t >= start && t <= end ? Color.accentColor.opacity(0.6) : .secondary.opacity(0.3)))
                }
                let x0 = CGFloat(viewStart / duration) * w, x1 = CGFloat((viewStart + span) / duration) * w
                let r = CGRect(x: x0, y: 0, width: max(4, x1 - x0), height: h)
                gc.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(.white.opacity(0.12)))
                gc.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(.white.opacity(0.8)), lineWidth: 1.5)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard w > 0 else { return }
                let t = Double(g.location.x / w) * duration
                viewStart = RangeSelectView.clampView(t - span / 2, span: span, duration: duration)
            })
        }
        .accessibilityElement()
        .accessibilityLabel("整檔縮圖")
        .accessibilityValue("目前看 \(RangeSelectView.fine(viewStart)) 到 \(RangeSelectView.fine(viewStart + span))")
    }
}

/// 聲波＋兩個把手；範圍外變暗。可以兩指捏合放大，放大後拖範圍外左右捲動
private struct RangeWaveform: View {
    let peaks: [Float]
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    let playhead: Double?
    @Binding var zoom: Double
    @Binding var viewStart: Double
    let maxZoom: Double
    /// 拖把手或整段移動時回報目前時間（第二個參數：是不是結尾把手）
    var onScrub: (Double, Bool) -> Void = { _, _ in }

    private enum Target { case start, end, move, pan, ignore }
    @State private var target: Target?
    @State private var origin = (start: 0.0, end: 0.0, view: 0.0)
    @State private var pinchBase: Double?

    private var span: Double { duration / max(1, zoom) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Canvas { gc, size in draw(gc, size) }
                .contentShape(Rectangle())
                // 要真的橫向拖曳才動，避免上下捲動或點一下就把範圍改掉
                .gesture(DragGesture(minimumDistance: 8)
                    .onChanged { g in drag(g, width: w) }
                    .onEnded { _ in target = nil })
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { g in pinch(g.magnification) }
                    .onEnded { _ in
                        pinchBase = nil
                        target = nil
                    })
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

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { span > 0 ? CGFloat((t - viewStart) / span) * w : 0 }

    /// 以畫面中間為準縮放
    private func pinch(_ m: CGFloat) {
        if pinchBase == nil {
            pinchBase = zoom
            target = .ignore  // 捏合時不要動到把手
        }
        let center = viewStart + span / 2
        let z = min(maxZoom, max(1, (pinchBase ?? 1) * Double(m)))
        zoom = z
        viewStart = RangeSelectView.clampView(center - duration / z / 2, span: duration / z, duration: duration)
    }

    private func drag(_ g: DragGesture.Value, width w: CGFloat) {
        guard duration > 0, w > 0, pinchBase == nil else { return }
        if target == nil {
            let sx = x(start, w), ex = x(end, w), px = g.startLocation.x
            let ds = abs(px - sx), de = abs(px - ex)
            if abs(g.translation.height) > abs(g.translation.width) {
                target = .ignore
            } else if min(ds, de) < 32 {
                target = ds <= de ? .start : .end
            } else if px > sx && px < ex {
                target = .move
            } else {
                target = zoom > 1.01 ? .pan : .ignore
            }
            origin = (start, end, viewStart)
        }
        let minLen = min(1, duration)
        // 用拖曳的位移（不是手指的絕對位置），把手才不會一按就跳；放大後同樣的位移代表更短的時間
        let d = Double(g.translation.width / w) * span
        switch target {
        case .start:
            start = min(max(0, origin.start + d), end - minLen)
            onScrub(start, false)
        case .end:
            end = max(min(duration, origin.end + d), start + minLen)
            onScrub(end, true)
        case .move:
            let len = origin.end - origin.start
            let s = min(max(0, origin.start + d), duration - len)
            start = s
            end = s + len
            onScrub(s, false)
        case .pan: viewStart = RangeSelectView.clampView(origin.view - d, span: span, duration: duration)
        case .ignore, nil: break
        }
    }

    private func draw(_ gc: GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        let lane = CGRect(x: 0, y: 14, width: w, height: h - 28)
        let accent = Color.accentColor
        // 聲波：只畫看得到的部分，每根約 3 點寬
        let bs = bars(peaks, duration: duration, from: viewStart, to: viewStart + span, count: max(1, Int(w / 3)))
        if bs.isEmpty {
            gc.fill(Path(CGRect(x: 0, y: lane.midY - 1, width: w, height: 2)), with: .color(.secondary.opacity(0.4)))
        } else {
            let bw = w / CGFloat(bs.count)
            for (i, v) in bs.enumerated() {
                let t = viewStart + (Double(i) + 0.5) / Double(bs.count) * span
                let inside = t >= start && t <= end
                let bh = max(1.5, CGFloat(v) * lane.height)
                let r = CGRect(x: CGFloat(i) * bw, y: lane.midY - bh / 2, width: max(1, bw * 0.75), height: bh)
                gc.fill(Path(r), with: .color(inside ? accent.opacity(0.85) : .secondary.opacity(0.35)))
            }
        }
        // 範圍外變暗、範圍框
        let sx = x(start, w), ex = x(end, w)
        let csx = min(max(sx, -10), w + 10), cex = min(max(ex, -10), w + 10)
        if csx > 0 { gc.fill(Path(CGRect(x: 0, y: 0, width: csx, height: h)), with: .color(.black.opacity(0.35))) }
        if cex < w { gc.fill(Path(CGRect(x: cex, y: 0, width: w - cex, height: h)), with: .color(.black.opacity(0.35))) }
        gc.stroke(Path(roundedRect: CGRect(x: csx, y: 6, width: max(0, cex - csx), height: h - 12), cornerRadius: 6),
                  with: .color(accent), lineWidth: 2)
        // 把手（在畫面內才畫）
        for hx in [sx, ex] where hx >= -7 && hx <= w + 7 {
            let knob = CGRect(x: hx - 7, y: h / 2 - 22, width: 14, height: 44)
            gc.fill(Path(roundedRect: knob, cornerRadius: 7), with: .color(accent))
            gc.fill(Path(roundedRect: CGRect(x: hx - 1, y: h / 2 - 10, width: 2, height: 20), cornerRadius: 1),
                    with: .color(.black.opacity(0.6)))
            // 放大時把手連成一條細線，方便對準聲波
            if zoom > 1.01 {
                gc.fill(Path(CGRect(x: hx - 0.5, y: 0, width: 1, height: h)), with: .color(accent.opacity(0.7)))
            }
        }
        // 試聽位置
        if let p = playhead {
            let px = x(p, w)
            if px >= 0 && px <= w {
                gc.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: h)), with: .color(.orange))
            }
        }
    }
}

/// 沒有控制列的影片畫面（AVPlayerLayer），播放與跳轉由選範圍頁控制
private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}
