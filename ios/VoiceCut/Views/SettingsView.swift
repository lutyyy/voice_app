import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var transcriber = Transcriber.shared
    @State private var preparing = false
    @State private var prepareStatus = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SpeedPicker()
                    Text(settings.speed?.note ?? "已自訂模型與補抓、補剪設定").font(.caption).foregroundStyle(.secondary)
                    if let w = settings.speed?.warning {
                        Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    modelStatus
                } header: {
                    Text("處理速度")
                } footer: {
                    Text("這支手機建議「\(SpeedTier.recommended.name)」。越慢越準；換速度要重新辨識。")
                }

                Section {
                    PresetPicker()
                    Text(settings.preset?.note ?? "已自訂參數").font(.caption).foregroundStyle(.secondary)
                    NavigationLink("微調剪輯參數") { CutSettingsView() }
                } header: {
                    Text("剪輯風格")
                } footer: {
                    Text("隨時可以換，不用重新辨識。")
                }

                Section {
                    NavigationLink {
                        ClaudeSettingsView()
                    } label: {
                        LabeledContent {
                            Text(settings.claudeReady ? "已啟用" : "未設定")
                        } label: {
                            Label("Claude 自動判斷", systemImage: "sparkles")
                        }
                    }
                    NavigationLink {
                        AdvancedSettingsView()
                    } label: {
                        Label("進階", systemImage: "gearshape.2")
                    }
                }

                Section {
                    NavigationLink("隱私權說明") { PrivacyView() }
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// 模型是否已下載並最佳化；還沒有就可以先準備（iOS 26 以上可以切到背景）
    @ViewBuilder
    private var modelStatus: some View {
        if transcriber.readyModel == currentModel {
            Label("\(name(currentModel)) 模型已準備好", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
        } else {
            Button {
                prepareModel()
            } label: {
                Label(preparing ? prepareStatus : "預先下載並準備模型（約 2～10 分鐘）",
                      systemImage: preparing ? "hourglass" : "arrow.down.circle")
            }
            .disabled(preparing)
            if !preparing, prepareStatus.hasPrefix("失敗") {
                Text(prepareStatus).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var currentModel: String { settings.resolvedModel }

    private func prepareModel() {
        preparing = true
        prepareStatus = "準備中…"
        let model = currentModel
        let title = "準備 \(name(model)) 模型"
        let bg = BackgroundWork.shared
        bg.begin(title: title)
        Task {
            do {
                try await Transcriber.shared.load(model: model) { p, s in
                    Task { @MainActor in
                        prepareStatus = p.isNaN ? s + "…" : "\(s) \(Int(p * 100))%"
                        bg.update(p.isNaN ? nil : p, step: s)
                    }
                }
                prepareStatus = ""
                bg.end(success: true, message: "模型準備好了，可以開始處理", title: title)
            } catch {
                prepareStatus = "失敗：\(error.localizedDescription)"
                bg.end(success: false, message: prepareStatus, title: title)
            }
            preparing = false
        }
    }

    private func name(_ id: String) -> String {
        Transcriber.candidates.first { $0.id == id }?.name ?? id
    }
}

/// 辨識模型、補抓、補剪、輸出格式
private struct AdvancedSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("辨識模型", selection: $settings.model) {
                    Text("自動（\(name(Transcriber.defaultModel))）").tag("")
                    ForEach(Transcriber.candidates.filter { Transcriber.supported.contains($0.id) || $0.id == settings.model }) { m in
                        Text(m.name).tag(m.id)
                    }
                }
                ForEach(Transcriber.candidates.filter { Transcriber.supported.contains($0.id) }) { m in
                    Text("\(m.name)：\(m.note)").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("第二輪漏字補抓", isOn: $settings.gapFill)
                Stepper("反覆補剪：\(settings.refineRounds == 0 ? "不做" : "\(settings.refineRounds) 輪")",
                        value: $settings.refineRounds, in: 0...3)
            } header: {
                Text("語音辨識")
            } footer: {
                Text("「處理速度」就是這三項的組合。漏字補抓會把「有聲音但沒有字」的片段再聽一次，救回漏掉的語助詞；反覆補剪會重新辨識成品、補剪殘留的語助詞，品質較好但比較久。模型第一次使用要下載並由 iPhone 最佳化，請連 Wi‑Fi。")
            }

            Section {
                Picker("音訊格式", selection: $settings.audioFormat) {
                    Text("M4A（檔案小）").tag("m4a")
                    Text("WAV（無損）").tag("wav")
                }
            } header: {
                Text("輸出")
            } footer: {
                Text("影片一律輸出 MP4。")
            }
        }
        .navigationTitle("進階")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func name(_ id: String) -> String {
        Transcriber.candidates.first { $0.id == id }?.name ?? id
    }
}

/// Claude API 金鑰與同意傳送
private struct ClaudeSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var key = ""
    @State private var keySaved = false

    var body: some View {
        Form {
            Section {
                SecureField("API 金鑰（sk-ant-…）", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(keySaved ? "已儲存" : "儲存金鑰") {
                    settings.claudeKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    keySaved = true
                }
                .disabled(key.isEmpty)
                if !settings.claudeKey.isEmpty {
                    Button("刪除金鑰", role: .destructive) {
                        settings.claudeKey = ""
                        key = ""
                    }
                }
                Toggle("同意把逐字稿傳送給 Anthropic", isOn: $settings.claudeConsent)
                Link("取得 API 金鑰", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
            } footer: {
                Text("Claude 會看上下文，挑出講錯重講的句子，並判斷哪些「然後、就是、那個」可以剪；也能把逐字稿整理成文章、摘要與章節。只會傳送逐字稿文字（不含聲音），費用由你的 Anthropic 帳號支付。金鑰只存在這支手機的鑰匙圈。")
            }
        }
        .navigationTitle("Claude 自動判斷")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { key = settings.claudeKey }
    }
}

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("隱私權說明").font(.title2.bold())
                Group {
                    Text("• 你匯入的音檔與影片只存在這支手機上的 App 資料夾，語音辨識與剪輯都在手機上完成，不會上傳。")
                    Text("• 第一次使用時，App 會從 Hugging Face 下載語音辨識模型（WhisperKit）；第一次辨識說話者時會下載語者辨識模型（SpeakerKit）。下載時不會傳送你的任何資料。")
                    Text("• 只有在你設定了自己的 Claude API 金鑰、同意傳送，並按下「請 Claude 判斷」時，或「用 Claude 整理」時，App 才會把逐字稿文字（不含聲音）傳送給 Anthropic，用來判斷要刪的句子與贅詞，或整理成文章、摘要與章節。Anthropic 如何處理 API 資料，請見其隱私權政策。")
                    Text("• 選「用 Claude／Gemini App 判斷」時，是你自己透過分享面板把逐字稿文字傳給那個 App，適用該服務的隱私權政策。")
                    Text("• App 不收集使用數據、不做廣告追蹤，也沒有帳號系統。")
                    Text("• 刪除專案（在首頁向左滑）就會刪除該專案的所有檔案。刪除 App 會刪除全部資料。")
                }
                .font(.body)
                Link("Anthropic 隱私權政策", destination: URL(string: "https://www.anthropic.com/legal/privacy")!)
            }
            .padding()
        }
        .navigationTitle("隱私權")
        .navigationBarTitleDisplayMode(.inline)
    }
}
