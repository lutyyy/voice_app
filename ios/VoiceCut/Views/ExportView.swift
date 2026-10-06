import AutoCutCore
import SwiftUI
import UIKit

/// 逐字稿與字幕：匯出 TXT／SRT／VTT、辨識說話者、請 Claude 整理
struct ExportView: View {
    @ObservedObject var model: ProjectModel
    @EnvironmentObject private var settings: AppSettings
    @State private var base: ProjectModel.TimeBase = .output
    @State private var files: [URL] = []
    @State private var exportError: String?
    @State private var speakerCount = 0
    @State private var showSettings = false
    @State private var showing: PolishTask?

    var body: some View {
        List {
            if model.isBusy {
                Section { ProcessingCard(model: model) }
            }
            exportSection
            speakerSection
            claudeSection
            previewSection
        }
        .navigationTitle("逐字稿與字幕")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: $showing) { t in PolishResultView(task: t, text: model.polished[t] ?? "") }
        .onAppear {
            if !model.outputFresh { base = .source }
            refresh()
        }
        .onChange(of: base) { _, _ in refresh() }
        .onChange(of: model.speakerTurns) { _, _ in refresh() }
        .onChange(of: model.plan) { _, _ in refresh() }
        .onChange(of: model.meta.speakerNames) { _, _ in refresh() }
    }

    private func refresh() {
        do {
            files = try model.exportFiles(base)
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }

    private var exportSection: some View {
        Section {
            Picker("時間", selection: $base) {
                ForEach(ProjectModel.TimeBase.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if base == .output && !model.outputFresh {
                Label("還沒有輸出，或標記改過了。先按「輸出剪好的檔案」，字幕才能對齊成品；現在會先用原始檔案的時間。",
                      systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(files, id: \.self) { f in
                ShareLink(item: f) {
                    Label(label(f), systemImage: icon(f))
                }
            }
            if let exportError {
                Text(exportError).foregroundStyle(.red).font(.caption)
            }
        } header: {
            Text("匯出")
        } footer: {
            Text("只包含保留下來的字（剪掉的語助詞、重講不會出現）。SRT／VTT 可以匯入 YouTube、CapCut、Premiere 等；對齊剪好的檔案時，字幕時間和成品一致。錯字可以在「檢視／修改逐字稿」長按字修改。")
        }
    }

    private func label(_ f: URL) -> String {
        switch f.pathExtension {
        case "txt": return "逐字稿（TXT）"
        case "srt": return "字幕（SRT）"
        default: return "字幕（VTT）"
        }
    }

    private func icon(_ f: URL) -> String {
        f.pathExtension == "txt" ? "doc.plaintext" : "captions.bubble"
    }

    private var speakerSection: some View {
        Section {
            if model.speakerTurns.isEmpty {
                Picker("人數", selection: $speakerCount) {
                    Text("自動判斷").tag(0)
                    ForEach(2...6, id: \.self) { Text("\($0) 人").tag($0) }
                }
                Button {
                    model.diarize(speakers: speakerCount == 0 ? nil : speakerCount)
                } label: {
                    Label("辨識說話者", systemImage: "person.2.wave.2")
                }
                .disabled(model.isBusy)
            } else {
                ForEach(0..<model.speakerCount, id: \.self) { i in
                    HStack {
                        Circle().fill(Self.color(i)).frame(width: 10, height: 10)
                        TextField("說話者 \(i + 1)", text: Binding(
                            get: { model.meta.speakerNames.flatMap { i < $0.count ? $0[i] : nil } ?? "" },
                            set: { model.renameSpeaker(i, to: $0) }))
                        Spacer()
                        Text(share(i)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Button("清除說話者", role: .destructive) { model.clearSpeakers() }
                    .disabled(model.isBusy)
            }
        } header: {
            Text("說話者")
        } footer: {
            Text(model.speakerTurns.isEmpty
                 ? "訪談、對談或會議可以標出誰在說話，逐字稿與字幕會加上名字。在手機上用 SpeakerKit 處理，第一次會下載約 30MB 的模型；知道人數時指定人數會更準。"
                 : "點名字可以改名（例如主持人、來賓）。")
        }
    }

    private func share(_ i: Int) -> String {
        let total = model.speakerTurns.reduce(0) { $0 + $1.end - $1.start }
        let mine = model.speakerTurns.filter { $0.speaker == i }.reduce(0) { $0 + $1.end - $1.start }
        return total > 0 ? "\(Int((mine / total * 100).rounded()))%" : ""
    }

    static func color(_ i: Int) -> Color {
        [Color.blue, .orange, .green, .purple, .pink, .teal][i % 6]
    }

    private var claudeSection: some View {
        Section {
            if settings.claudeReady {
                ForEach(PolishTask.allCases) { t in
                    HStack {
                        Button {
                            model.polish(t)
                        } label: {
                            Label(model.polished[t] == nil ? t.name : "重新\(t.name)", systemImage: t.icon)
                        }
                        .disabled(model.isBusy)
                        Spacer()
                        if model.polished[t] != nil {
                            Button("查看") { showing = t }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Button {
                    showSettings = true
                } label: {
                    Label("設定 Claude API 金鑰", systemImage: "key")
                }
            }
        } header: {
            Text("用 Claude 整理")
        } footer: {
            Text("把保留下來的逐字稿（文字，不含聲音）傳給 Claude：潤飾成好讀的文章、寫重點摘要，或產生可以直接貼到 YouTube 說明欄的章節時間。")
        }
    }

    private var previewSection: some View {
        Section("預覽") {
            let e = model.exportWords(base)
            let text = Subtitles.text(e.words, speakers: model.speakerTurns.isEmpty ? nil : e.speakers, timestamps: true,
                                      names: { model.speakerName($0) })
            Text(text.count > 3000 ? String(text.prefix(3000)) + "…" : text)
                .font(.callout)
                .textSelection(.enabled)
        }
    }
}

/// Claude 整理的結果：可以選取、複製、分享
private struct PolishResultView: View {
    let task: PolishTask
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(task.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = text
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel("複製")
                    ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
    }
}
