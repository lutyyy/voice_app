import AVKit
import AutoCutCore
import SwiftUI
import UIKit

/// 專案頁：處理完就是逐字稿編輯器；底部是復原、剪輯風格與「匯出」，其他功能收在右上角選單
struct ProjectView: View {
    @ObservedObject var model: ProjectModel
    @EnvironmentObject private var settings: AppSettings
    @State private var showSettings = false
    @State private var showRange = false
    @State private var showLog = false
    @State private var showExport = false
    @State private var showSubtitles = false
    @State private var showCutSettings = false

    var body: some View {
        content
            .navigationTitle(model.meta.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !model.plan.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { aiMenu }
                }
                ToolbarItem(placement: .topBarTrailing) { moreMenu }
            }
            .navigationDestination(isPresented: $showSubtitles) { ExportView(model: model) }
            .navigationDestination(isPresented: $showCutSettings) { CutSettingsView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showLog) { LogView(lines: model.log) }
            .sheet(isPresented: $showExport) {
                ExportSheet(model: model) {
                    // 等匯出畫面收起來再推進下一頁，否則推不進去
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showSubtitles = true }
                }
            }
            .sheet(isPresented: $showRange) {
                RangeSelectView(url: model.sourceURL, initial: model.meta.range, firstTime: model.needsRange) { r, fps in
                    model.setRange(r, fps: fps)
                }
            }
            .alert("提示", isPresented: Binding(get: { model.notice != nil && !showExport },
                                              set: { if !$0 { model.notice = nil } })) {
                Button("好") {}
            } message: {
                Text(model.notice ?? "")
            }
            .onAppear {
                if model.needsRange { showRange = true }
                model.prepareIfNeeded()
                model.warmUp()
            }
            .onChange(of: settings.cutReview) { _, _ in model.markStale() }
            .onChange(of: settings.cut) { _, _ in model.markStale() }
    }

    @ViewBuilder
    private var content: some View {
        if model.plan.isEmpty {
            ScrollView {
                VStack(spacing: 16) {
                    status
                }
                .padding()
            }
        } else {
            TranscriptEditor(model: model)
                .safeAreaInset(edge: .top, spacing: 0) {
                    // 輸出以外的工作（Claude 判斷、辨識說話者…）在這裡顯示進度
                    if model.isBusy && !showExport { busyBanner }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        }
    }

    // MARK: - 還沒有逐字稿

    @ViewBuilder
    private var status: some View {
        switch model.stage {
        case .working:
            ProcessingCard(model: model).card()
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 14) {
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Button("重試") { model.prepare() }.buttonStyle(PillButtonStyle())
            }
            .card()
        case .ready:
            VStack(alignment: .leading, spacing: 14) {
                Label("沒有辨識到任何字", systemImage: "exclamationmark.bubble.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("可能是範圍太短、沒有人聲，或「快速」模型聽不出這段。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("換成較準的速度重新辨識", systemImage: "arrow.clockwise") {
                    if settings.speed == .fast { settings.apply(SpeedTier.standard) }
                    model.retranscribe()
                }
                .buttonStyle(PillButtonStyle())
                Button("變更處理範圍", systemImage: "timeline.selection") { showRange = true }
                    .buttonStyle(PillButtonStyle(prominent: false))
            }
            .card()
        case .idle:
            if !model.needsRange {
                VStack(spacing: 14) {
                    Button("開始處理", systemImage: "play.fill") { model.prepare() }
                        .buttonStyle(PillButtonStyle())
                    Text("已取消。模型若正在最佳化，會在背景繼續做完，下次開始就不用再等那麼久。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            }
        }
    }

    // MARK: - 編輯器周邊

    private var busyBanner: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(model.step.isEmpty ? "處理中…" : model.step)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Button("取消") { model.cancel() }
                .font(.subheadline)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var bottomBar: some View {
        HStack(spacing: 6) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 36, height: 36) }
                .disabled(model.undoStack.isEmpty || model.isBusy)
                .accessibilityLabel("復原")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 36, height: 36) }
                .disabled(model.redoStack.isEmpty || model.isBusy)
                .accessibilityLabel("重做")
            presetMenu
            Spacer(minLength: 8)
            Button {
                showExport = true
                if !model.outputFresh && !model.isBusy { model.render() }
            } label: {
                Label("匯出", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PillButtonStyle())
            .disabled(model.isBusy && !model.steps.contains { $0.id == "cut" })
        }
        .font(.body.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// 剪輯風格：點開直接換，最下面可以進去微調
    private var presetMenu: some View {
        Menu {
            Picker("剪輯風格", selection: Binding(
                get: { settings.preset?.rawValue ?? "custom" },
                set: { if let p = CutPreset(rawValue: $0) { settings.apply(p) } })) {
                ForEach(CutPreset.allCases) { p in
                    Text(p.name).tag(p.rawValue)
                }
                if settings.preset == nil { Text("自訂").tag("custom") }
            }
            Button("微調剪輯參數…", systemImage: "slider.horizontal.3") { showCutSettings = true }
        } label: {
            HStack(spacing: 4) {
                Text(settings.preset?.name ?? "自訂")
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.12), in: Capsule())
        }
        .disabled(model.isBusy)
        .accessibilityLabel("剪輯風格：\(settings.preset?.name ?? "自訂")")
    }

    /// Claude：自動判斷、手動複製貼上、疑似贅詞的預設處理
    private var aiMenu: some View {
        Menu {
            if model.meta.deletes != nil {
                Text(model.deletes.map { "已套用：刪除 \($0.sentences.count) 句、剪掉 \($0.reviews.count) 個贅詞" }
                     ?? "Claude 的回覆和目前的逐字稿對不上，沒有套用")
            }
            if settings.claudeReady {
                Button(model.meta.deletes == nil ? "請 Claude 判斷" : "請 Claude 重新判斷", systemImage: "sparkles") {
                    model.askClaude()
                }
            } else {
                Button("設定 Claude API 金鑰…", systemImage: "key") { showSettings = true }
            }
            Menu("手動貼給 Claude", systemImage: "doc.on.clipboard") {
                Button("複製逐句稿", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = model.sentencesText
                    model.notice = "已複製。貼給 Claude，再把它的回覆複製回來，點「貼上 Claude 的回覆」。"
                }
                Button("貼上 Claude 的回覆", systemImage: "doc.on.clipboard") { pasteReply() }
            }
            if model.meta.deletes != nil {
                Button("清除 Claude 的判斷", systemImage: "xmark.circle", role: .destructive) { model.clearReply() }
            } else {
                Toggle("疑似贅詞全部剪掉", isOn: $settings.cutReview)
            }
        } label: {
            Image(systemName: model.meta.deletes == nil ? "sparkles" : "sparkles.rectangle.stack.fill")
        }
        .disabled(model.isBusy)
        .accessibilityLabel("Claude 判斷重講與贅詞")
    }

    private var moreMenu: some View {
        Menu {
            if !model.plan.isEmpty {
                Button("字幕、逐字稿、說話者", systemImage: "captions.bubble") { showSubtitles = true }
                Button("微調剪輯參數", systemImage: "slider.horizontal.3") { showCutSettings = true }
            }
            Section {
                Button(rangeTitle, systemImage: "timeline.selection") { showRange = true }
                    .disabled(model.isBusy)
                Button("重新辨識", systemImage: "arrow.clockwise") { model.retranscribe() }
                    .disabled(model.isBusy)
            }
            Section {
                if !model.log.isEmpty {
                    Button("處理紀錄", systemImage: "list.bullet.rectangle") { showLog = true }
                }
                Button("設定", systemImage: "gearshape") { showSettings = true }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private var rangeTitle: String {
        guard let r = model.meta.range else { return "變更處理範圍" }
        return "處理範圍 \(RangeSelectView.fine(r.start)) – \(RangeSelectView.fine(r.end))"
    }

    private func pasteReply() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            model.notice = "剪貼簿是空的。請先在 Claude 的回覆上按「複製」。"
            return
        }
        do {
            try model.applyReply(text)
        } catch {
            model.notice = error.localizedDescription
        }
    }
}

/// 匯出：剪接中顯示進度，完成後可以試聽、分享或儲存
private struct ExportSheet: View {
    @ObservedObject var model: ProjectModel
    let openSubtitles: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if model.isBusy {
                        ProcessingCard(model: model).card()
                    } else if model.outputFresh, let url = model.outputURL,
                              FileManager.default.fileExists(atPath: url.path) {
                        result(url)
                    } else {
                        VStack(spacing: 14) {
                            if let error {
                                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            }
                            Button("重新匯出", systemImage: "scissors") {
                                error = nil
                                model.render()
                            }
                            .buttonStyle(PillButtonStyle())
                        }
                        .padding(.top, 30)
                    }
                }
                .padding()
            }
            .navigationTitle(model.isBusy ? "匯出中" : "匯出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isBusy ? "背景處理" : "完成") { dismiss() }
                }
            }
            .onChange(of: model.notice) { _, n in
                if let n {
                    error = n
                    model.notice = nil
                }
            }
        }
    }

    private func result(_ url: URL) -> some View {
        VStack(spacing: 18) {
            PlayerView(url: url, isVideo: model.meta.info?.isVideo == true, version: model.meta.outputDuration ?? 0)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            if let info = model.meta.info, let d = model.meta.outputDuration {
                VStack(spacing: 4) {
                    Text("\(ProjectModel.clock(info.duration)) → \(ProjectModel.clock(d))")
                        .font(.title.monospacedDigit().bold())
                    Text("省下 \(ProjectModel.clock(info.duration - d))（\(Int(((1 - d / max(info.duration, 0.01)) * 100).rounded()))%）")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            ShareLink(item: url) {
                Label("分享／儲存", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle())
            Button {
                dismiss()
                openSubtitles()
            } label: {
                Label("字幕與逐字稿（SRT／TXT）", systemImage: "captions.bubble").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(prominent: false))
            Text("也可以在「檔案」App › 我的 iPhone › 語音剪輯 找到。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 播放剪好的檔案
private struct PlayerView: View {
    let url: URL
    let isVideo: Bool
    let version: Double
    @State private var player = AVPlayer()

    var body: some View {
        VideoPlayer(player: player)
            .frame(height: isVideo ? 220 : 64)
            .onAppear { reload() }
            .onChange(of: version) { _, _ in reload() }
            .onDisappear { player.pause() }
    }

    private func reload() {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
    }
}

/// 處理紀錄
private struct LogView: View {
    let lines: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.footnote).textSelection(.enabled)
            }
            .navigationTitle("處理紀錄")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button { UIPasteboard.general.string = lines.joined(separator: "\n") } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("複製全部")
                }
            }
        }
    }
}
