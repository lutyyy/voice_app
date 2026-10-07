import AVKit
import AutoCutCore
import SwiftUI
import UIKit

/// 專案頁：處理完就是逐字稿編輯器；底部是復原、剪輯風格與「匯出」，其他功能收在右上角選單
struct ProjectView: View {
    @ObservedObject var model: ProjectModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var showSettings = false
    @State private var showRange = false
    @State private var showLog = false
    @State private var showExport = false
    @State private var showSubtitles = false
    @State private var showCutSettings = false
    @State private var showAsk = false
    @State private var discard = false
    @State private var confirmCancel = false

    var body: some View {
        content
            .navigationTitle(model.meta.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !model.plan.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { aiMenu }
                }
                if model.plan.isEmpty && model.isBusy {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("取消") { confirmCancel = true }
                            .confirmationDialog("停止處理？", isPresented: $confirmCancel, titleVisibility: .visible) {
                                Button("停止處理", role: .destructive) { model.cancel() }
                                Button("繼續處理", role: .cancel) {}
                            } message: {
                                Text("之後可以再按「開始處理」重新開始。")
                            }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { moreMenu }
            }
            .navigationDestination(isPresented: $showSubtitles) { ExportView(model: model) }
            .navigationDestination(isPresented: $showCutSettings) { CutSettingsView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showLog) { LogView(lines: model.log) }
            .sheet(isPresented: $showAsk) { AskAppSheet(model: model) }
            .sheet(isPresented: $showExport) {
                ExportSheet(model: model) {
                    // 等匯出畫面收起來再推進下一頁，否則推不進去
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showSubtitles = true }
                }
            }
            .sheet(isPresented: $showRange, onDismiss: rangeDismissed) {
                RangeSelectView(url: model.sourceURL, initial: model.meta.range, firstTime: model.needsRange,
                                onDone: { r, fps, n in model.setRange(r, fps: fps, speakers: n) },
                                onDiscard: { discard = true })
            }
            .alert("提示", isPresented: Binding(get: { model.notice != nil && !showExport && !showAsk },
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

    /// 新專案還沒選範圍就關掉（取消或往下滑）：回到首頁；選了刪除就等返回動畫結束再刪
    private func rangeDismissed() {
        guard model.needsRange else { return }
        dismiss()
        if discard {
            let meta = model.meta
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { store.delete(meta) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.plan.isEmpty && model.stage == .working {
            ProcessingHero(model: model)
        } else if model.plan.isEmpty {
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
            Button("用 Claude／Gemini App 判斷（用你的訂閱）", systemImage: "arrow.up.forward.app") { showAsk = true }
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

/// 用 Claude／Gemini App（使用者自己的訂閱）判斷：分享逐字稿過去，複製回覆後回來一鍵貼上
private struct AskAppSheet: View {
    @ObservedObject var model: ProjectModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    /// 打開這頁時的剪貼簿版本；之後變了代表複製了新東西
    @State private var baseline = UIPasteboard.general.changeCount
    /// 已經切到別的 App 過
    @State private var left = false
    @State private var hasNew = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    step(1, "傳給 Claude 或 Gemini", done: left) {
                        Text("分享面板裡選 Claude 或 Gemini App（沒看到就按「拷貝」，再自己打開 App 貼上）。指示已經包含在內容裡，不用另外打字。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ShareLink(item: model.sentencesText) {
                            Label("分享逐字稿", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PillButtonStyle(prominent: !left))
                    }
                    step(2, "等它回完，按回覆下方的「複製」", done: hasNew) {
                        Text(hasNew ? "偵測到剪貼簿有新內容。" : "複製後回到這裡。")
                            .font(.subheadline)
                            .foregroundStyle(hasNew ? Color.accentColor : .secondary)
                    }
                    step(3, "貼上並套用", done: false) {
                        PasteButton(payloadType: String.self) { strings in
                            Task { @MainActor in apply(strings.joined(separator: "\n")) }
                        }
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .tint(hasNew ? Color.accentColor : Color.white.opacity(0.25))
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text("回覆要包含「版本碼」那一行，App 才能確認它對應的是目前的逐字稿。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("用 Claude／Gemini App 判斷")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .onChange(of: phase) { _, p in
                if p == .background { left = true }
                if p == .active { check() }
            }
        }
    }

    /// 讀 changeCount 不會跳出「允許貼上」的詢問
    private func check() {
        let pb = UIPasteboard.general
        hasNew = pb.hasStrings && pb.changeCount != baseline
    }

    private func apply(_ text: String) {
        // 貼上的是我們自己送出去的逐字稿（例如在分享面板按了「拷貝」），不是回覆
        if text.contains("## 第一部分：逐句稿") {
            error = "剪貼簿裡是逐字稿本身，不是回覆。請在 Claude／Gemini 的回覆下方按「複製」再回來。"
            return
        }
        do {
            try model.applyReply(text)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func step<C: View>(_ n: Int, _ title: String, done: Bool, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.accentColor : Color.white.opacity(0.12)).frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.black)
                } else {
                    Text("\(n)").font(.subheadline.bold())
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                content()
            }
        }
        .card()
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
