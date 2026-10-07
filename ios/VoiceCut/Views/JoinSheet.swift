import AutoCutCore
import SwiftUI

/// 接點面板：調整一個剪接點（或兩個字之間）的停頓長短、銜接方式與邊界位置，可以只試聽這個接點
struct JoinSheet: View {
    @ObservedObject var model: ProjectModel
    let point: ProjectModel.JoinPoint
    @ObservedObject var player: ClipPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var edit: JoinEdit
    @State private var loaded = false
    @State private var previewing = false
    @State private var error: String?

    init(model: ProjectModel, point: ProjectModel.JoinPoint, player: ClipPlayer) {
        self.model = model
        self.point = point
        self.player = player
        _edit = State(initialValue: model.joinEdit(point))
    }

    private enum PauseMode: Hashable { case auto, asIs, custom }
    private enum FadeMode: Hashable { case auto, hard, fade }

    private var isVideo: Bool { model.meta.info?.isVideo == true }
    private var aEnd: Double { point.aEnd + edit.nudgeEnd }
    private var bStart: Double { point.bStart + edit.nudgeStart }

    private var pauseMode: Binding<PauseMode> {
        Binding(get: {
            guard let p = edit.pause else { return .auto }
            return p < 0 ? .asIs : .custom
        }, set: { m in
            switch m {
            case .auto: edit.pause = nil
            case .asIs: edit.pause = -1
            case .custom: edit.pause = edit.pause.flatMap { $0 >= 0 ? $0 : nil } ?? defaultPause
            }
        })
    }

    /// 改成自訂時的起始值：原本的停頓（有剪的地方從 0.3 秒開始）
    private var defaultPause: Double {
        point.cut ? 0.3 : min(2, max(0, ((point.bStart - point.aEnd) * 20).rounded() / 20))
    }

    private var fadeMode: Binding<FadeMode> {
        Binding(get: {
            guard let f = edit.fade else { return .auto }
            return f == 0 ? .hard : .fade
        }, set: { m in
            switch m {
            case .auto: edit.fade = nil
            case .hard: edit.fade = 0
            case .fade: edit.fade = (edit.fade ?? 0) > 0 ? edit.fade : 0.04
            }
        })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    status
                    wave
                    nudges
                    pauseSection
                    fadeSection
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                    HStack(spacing: 10) {
                        Button("還原自動") { edit = JoinEdit(after: point.after) }
                            .buttonStyle(PillButtonStyle(prominent: false))
                            .disabled(edit.isEmpty)
                        Button {
                            preview()
                        } label: {
                            Label(previewing ? "準備中…" : (player.playingID == "join" ? "停止" : "試聽這個接點"),
                                  systemImage: player.playingID == "join" ? "stop.fill" : "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PillButtonStyle())
                        .disabled(previewing)
                    }
                }
                .padding()
            }
            .navigationTitle("接點 \(ProjectModel.clock(point.bStart))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        model.setJoin(edit)
                        dismiss()
                    }
                }
            }
            .task {
                await model.ensureAnalysisQuietly()
                loaded = true
            }
            .onDisappear { if player.playingID == "join" { player.stop() } }
        }
        .presentationDetents([.medium, .large])
    }

    /// 邊界有沒有對準安靜處
    @ViewBuilder
    private var status: some View {
        let qa = loaded ? model.nearQuiet(aEnd) : nil
        let qb = loaded ? model.nearQuiet(bStart) : nil
        if qa == true && qb == true {
            Label("已對準安靜處", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
        } else if qa == false || qb == false {
            Label("這裡字黏在一起，找不到安靜處；建議試聽後用 ◀ ▶ 挪一下邊界", systemImage: "exclamationmark.circle.fill")
                .font(.footnote).foregroundStyle(.orange)
        }
    }

    /// 前後約 2 秒的聲波，標出前字結尾、後字開頭，中間剪掉的部分畫斜線
    private var wave: some View {
        let t0 = point.aEnd - 2, t1 = point.bStart + 2
        let bars = loaded ? model.energy(from: t0, to: t1, count: 140) : []
        return Canvas { gc, size in
            let w = size.width, h = size.height
            func x(_ t: Double) -> CGFloat { CGFloat((t - t0) / (t1 - t0)) * w }
            if point.cut || bStart > aEnd {
                let r = CGRect(x: x(aEnd), y: 0, width: max(1, x(bStart) - x(aEnd)), height: h)
                gc.fill(Path(r), with: .color(point.cut ? Color.red.opacity(0.18) : Color.white.opacity(0.06)))
            }
            let bw = w / CGFloat(max(1, bars.count))
            for (i, v) in bars.enumerated() {
                let bh = max(1.5, CGFloat(v) * h * 0.9)
                gc.fill(Path(CGRect(x: CGFloat(i) * bw, y: h / 2 - bh / 2, width: max(1, bw * 0.7), height: bh)),
                        with: .color(Color.accentColor.opacity(0.7)))
            }
            for t in [aEnd, bStart] {
                gc.fill(Path(CGRect(x: x(t) - 1, y: 0, width: 2, height: h)), with: .color(.white))
            }
        }
        .frame(height: 80)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("接點附近的聲波")
    }

    private var nudges: some View {
        HStack {
            nudge("前字結尾", value: $edit.nudgeEnd)
            Spacer()
            Text(point.cut ? "剪掉 " + String(format: "%.2f", point.removed) + " 秒" : "沒有剪")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            nudge("後字開頭", value: $edit.nudgeStart)
        }
    }

    private func nudge(_ title: String, value: Binding<Double>) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button { value.wrappedValue = ((value.wrappedValue - 0.05) * 100).rounded() / 100 } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel(title + "提早 0.05 秒")
                Text(value.wrappedValue == 0 ? "0" : String(format: "%+.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 40)
                Button { value.wrappedValue = ((value.wrappedValue + 0.05) * 100).rounded() / 100 } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel(title + "延後 0.05 秒")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var pauseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("停頓").font(.subheadline.weight(.semibold))
            Picker("停頓", selection: pauseMode) {
                Text("自動").tag(PauseMode.auto)
                Text("原樣").tag(PauseMode.asIs)
                Text("自訂").tag(PauseMode.custom)
            }
            .pickerStyle(.segmented)
            if let p = edit.pause, p >= 0 {
                HStack {
                    Slider(value: Binding(get: { p }, set: { edit.pause = ($0 * 20).rounded() / 20 }), in: 0...2)
                    Text(String(format: "%.2f 秒", p)).font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
                }
            }
            Text(isVideo ? "影片只能把停頓縮短，不能拉長（畫面沒有東西可以補）。"
                 : "自動：依剪輯風格壓縮過長的停頓。原樣：不壓縮也不補。自訂：比原本長的部分補環境底噪。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var fadeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("銜接").font(.subheadline.weight(.semibold))
            Picker("銜接", selection: fadeMode) {
                Text("自動").tag(FadeMode.auto)
                Text("直接切").tag(FadeMode.hard)
                Text("淡入淡出").tag(FadeMode.fade)
            }
            .pickerStyle(.segmented)
            if let f = edit.fade, f > 0 {
                HStack {
                    Slider(value: Binding(get: { f }, set: { edit.fade = ($0 * 200).rounded() / 200 }), in: 0.01...0.15)
                    Text("\(Int((f * 1000).rounded())) 毫秒").font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
                }
            }
            Text("淡入淡出越長接得越順，但太長會吃掉字頭字尾。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func preview() {
        if player.playingID == "join" {
            player.stop()
            return
        }
        previewing = true
        error = nil
        Task {
            defer { previewing = false }
            do {
                let url = try await model.previewJoin(edit, at: point)
                player.play(url, from: 0, to: 6.5, id: "join", tracksTranscript: false)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
