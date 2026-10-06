import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var keySaved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("辨識模型", selection: $settings.model) {
                        Text("自動（\(name(Transcriber.defaultModel))）").tag("")
                        ForEach(Transcriber.candidates.filter { Transcriber.supported.contains($0.id) }, id: \.id) { m in
                            Text(m.name).tag(m.id)
                        }
                    }
                    ForEach(Transcriber.candidates.filter { Transcriber.supported.contains($0.id) }, id: \.id) { m in
                        Text("\(m.name)：\(m.note)").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("第二輪漏字補抓", isOn: $settings.gapFill)
                    Stepper("反覆補剪：\(settings.refineRounds == 0 ? "不做" : "\(settings.refineRounds) 輪")",
                            value: $settings.refineRounds, in: 0...3)
                    TextField("提示詞（專有名詞，可留空）", text: $settings.prompt)
                } header: {
                    Text("語音辨識")
                } footer: {
                    Text("模型第一次使用時會下載。漏字補抓會把「有聲音但沒有字」的片段再聽一次，救回漏掉的語助詞；反覆補剪會重新辨識成品、補剪殘留的語助詞，品質較好但比較久。")
                }

                Section {
                    Picker("音訊格式", selection: $settings.audioFormat) {
                        Text("M4A（AAC，檔案小）").tag("m4a")
                        Text("WAV（無損）").tag("wav")
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "超過 %.2f 秒的停頓要壓縮", settings.maxPause))
                        Slider(value: $settings.maxPause, in: 0.25...1.0, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "壓縮後保留約 %.2f 秒", settings.keepPause))
                        Slider(value: $settings.keepPause, in: 0.1...0.5, step: 0.01)
                    }
                    Toggle("壓低停頓中的呼吸聲", isOn: $settings.breathCut)
                    Toggle("停頓太短時補環境底噪", isOn: $settings.roomtone)
                } header: {
                    Text("輸出")
                } footer: {
                    Text("影片一律輸出 MP4。")
                }

                Section {
                    SecureField("Claude API 金鑰（sk-ant-…）", text: $key)
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
                } header: {
                    Text("Claude 自動判斷（選用）")
                } footer: {
                    Text("按下「請 Claude 判斷」時，只會把逐字稿文字（不含聲音）用你的金鑰傳送給 Anthropic 的 Claude，判斷哪些句子是講錯重講、哪些贅詞能剪。費用由你的 Anthropic 帳號支付。金鑰只存在這支手機的鑰匙圈。")
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
            .onAppear { key = settings.claudeKey }
            .onChange(of: settings.keepPause) { _, v in
                if settings.maxPause < v { settings.maxPause = v }
            }
        }
    }

    private func name(_ id: String) -> String {
        Transcriber.candidates.first { $0.id == id }?.name ?? id
    }
}

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("隱私權說明").font(.title2.bold())
                Group {
                    Text("• 你匯入的音檔與影片只存在這支手機上的 App 資料夾，語音辨識與剪輯都在手機上完成，不會上傳。")
                    Text("• 第一次使用時，App 會從 Hugging Face 下載語音辨識模型（WhisperKit），下載時不會傳送你的任何資料。")
                    Text("• 只有在你設定了自己的 Claude API 金鑰、同意傳送，並按下「請 Claude 判斷」時，App 才會把逐字稿文字（不含聲音）傳送給 Anthropic，用來判斷要刪的句子與贅詞。Anthropic 如何處理 API 資料，請見其隱私權政策。")
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
