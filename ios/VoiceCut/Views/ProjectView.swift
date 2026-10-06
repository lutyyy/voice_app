import AVKit
import AutoCutCore
import SwiftUI
import UIKit

/// 專案頁：處理進度、標記摘要、Claude 判斷、輸出與分享
struct ProjectView: View {
    @ObservedObject var model: ProjectModel
    @EnvironmentObject private var settings: AppSettings
    @State private var showSettings = false
    @State private var copied = false
    @State private var showRange = false

    var body: some View {
        List {
            header
            switch model.stage {
            case .working: working
            case .failed(let msg): failed(msg)
            case .idle where model.plan.isEmpty && !model.needsRange: idle
            default: EmptyView()
            }
            if !model.plan.isEmpty {
                summary
                claude
                output
            }
            if !model.log.isEmpty {
                Section {
                    DisclosureGroup("處理紀錄") {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(model.meta.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("重新辨識", systemImage: "arrow.clockwise") { model.retranscribe() }
                        .disabled(model.isBusy)
                    Button("變更處理範圍", systemImage: "timeline.selection") { showRange = true }
                        .disabled(model.isBusy)
                    Button("設定", systemImage: "gearshape") { showSettings = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showRange) {
            RangeSelectView(url: model.sourceURL, initial: model.meta.range, firstTime: model.needsRange) { r, fps in
                model.setRange(r, fps: fps)
            }
        }
        .alert("提示", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
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

    /// 取消後（還沒有辨識結果）：可以重新開始
    private var idle: some View {
        Section {
            Button {
                model.prepare()
            } label: {
                Label("開始處理", systemImage: "play.fill")
            }
        } footer: {
            Text("已取消。模型若正在最佳化，會在背景繼續做完，下次開始就不用再等那麼久。")
        }
    }

    private var header: some View {
        Section {
            if let r = model.meta.range {
                LabeledContent("處理範圍", value: "\(RangeSelectView.fine(r.start)) – \(RangeSelectView.fine(r.end))")
            }
            if let info = model.meta.info {
                LabeledContent(model.meta.range == nil ? "長度" : "範圍長度", value: ProjectModel.clock(info.duration))
                LabeledContent("類型", value: info.isVideo ? "影片" : "音訊")
            }
            LabeledContent("檔名", value: model.meta.name)
        }
    }

    private var working: some View {
        Section {
            ProcessingCard(model: model)
        }
    }

    private func failed(_ msg: String) -> some View {
        Section {
            Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            Button("重試") { model.prepare() }
        }
    }

    private var summary: some View {
        let s = Planner.summary(model.plan)
        return Section {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    stat("語助詞", s.fillers)
                    stat("口吃重複", s.repeats)
                    stat("拖音", s.drags)
                }
                GridRow {
                    stat("雜音", s.noise)
                    stat("疑似贅詞", s.review)
                    Color.clear.frame(height: 1)
                }
            }
            .padding(.vertical, 4)
            NavigationLink {
                TranscriptView(model: model)
            } label: {
                Label("檢視／修改逐字稿", systemImage: "text.badge.checkmark")
            }
            NavigationLink {
                ExportView(model: model)
            } label: {
                Label("逐字稿、字幕、說話者、AI 整理", systemImage: "captions.bubble")
            }
        } header: {
            Text("自動標記")
        } footer: {
            Text("語助詞、口吃、拖音、雜音一律剪掉；疑似贅詞（然後、就是、那個…）依下方設定或 Claude 的判斷。")
        }
    }

    private func stat(_ name: String, _ n: Int) -> some View {
        VStack(alignment: .leading) {
            Text("\(n)").font(.title2.monospacedDigit().bold())
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var claude: some View {
        Section {
            if model.meta.deletes != nil {
                if let d = model.deletes {
                    Label("已套用：刪除 \(d.sentences.count) 句、剪掉 \(d.reviews.count) 個疑似贅詞", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                } else {
                    Label("Claude 的回覆和目前的逐字稿對不上（版本碼不同），沒有套用。請重新判斷。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Button("清除 Claude 的判斷", role: .destructive) { model.clearReply() }
                    .disabled(model.isBusy)
            } else {
                Toggle("疑似贅詞全部剪掉", isOn: $settings.cutReview)
            }

            if settings.claudeReady {
                Button {
                    model.askClaude()
                } label: {
                    Label(model.meta.deletes == nil ? "請 Claude 判斷" : "請 Claude 重新判斷", systemImage: "sparkles")
                }
                .disabled(model.isBusy)
            } else {
                Button {
                    showSettings = true
                } label: {
                    Label("設定 Claude API 金鑰，自動判斷", systemImage: "key")
                }
            }
            Button {
                UIPasteboard.general.string = model.sentencesText
                copied = true
            } label: {
                Label(copied ? "已複製，貼給 Claude 後把回覆複製回來" : "複製逐句稿（手動貼給 Claude）", systemImage: "doc.on.doc")
            }
            Button {
                pasteReply()
            } label: {
                Label("貼上 Claude 的回覆", systemImage: "doc.on.clipboard")
            }
            .disabled(model.isBusy)
        } header: {
            Text("重講的句子與贅詞")
        } footer: {
            Text("Claude 會看上下文，挑出講錯重講、重複的句子，並判斷哪些「然後、就是、這個」可以剪。沒有 Claude 判斷時，可以用上面的開關決定疑似贅詞要不要剪。")
        }
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

    private var output: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                PresetPicker()
                    .disabled(model.isBusy)
                Text(settings.preset?.note ?? "自訂參數")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            NavigationLink {
                CutSettingsView()
            } label: {
                Label("微調剪輯參數", systemImage: "slider.horizontal.3")
            }
            if let info = model.meta.info, let e = model.estimate {
                LabeledContent("預估剪後長度") {
                    Text("約 \(ProjectModel.clock(e))（省下 \(Int(((1 - e / max(info.duration, 0.01)) * 100).rounded()))%）")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.default, value: e)
                }
            }
            if let url = model.outputURL, FileManager.default.fileExists(atPath: url.path) {
                PlayerView(url: url, isVideo: model.meta.info?.isVideo == true,
                           version: model.meta.outputDuration ?? 0)
                if let info = model.meta.info, let d = model.meta.outputDuration {
                    LabeledContent("剪後長度", value: "\(ProjectModel.clock(d))（省下 \(ProjectModel.clock(info.duration - d))）")
                }
                if model.meta.outputStale {
                    Label("標記改過了，重新輸出才會套用", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
                ShareLink(item: url) {
                    Label("分享／儲存剪好的檔案", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                model.render()
            } label: {
                Label(model.outputURL == nil ? "輸出剪好的檔案" : "重新輸出", systemImage: "scissors")
                    .font(.headline)
            }
            .disabled(model.isBusy)
        } header: {
            Text("輸出")
        } footer: {
            Text(settings.refineRounds > 0
                 ? "輸出後會重新辨識成品，補剪殘留的語助詞（最多 \(settings.refineRounds) 輪，可在設定調整）。"
                 : "剪接處自動交叉淡化、壓低停頓中的呼吸聲、補上環境底噪。")
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
            .listRowInsets(EdgeInsets())
            .onAppear { reload() }
            .onChange(of: version) { _, _ in reload() }
            .onDisappear { player.pause() }
    }

    private func reload() {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
    }
}
