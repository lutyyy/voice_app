import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 首頁：匯入影音檔、專案清單
struct HomeView: View {
    @EnvironmentObject private var store: ProjectStore
    @ObservedObject private var transcriber = Transcriber.shared
    @State private var path: [UUID] = []
    @State private var showImporter = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showSettings = false
    @State private var importing = false
    @State private var error: String?
    @State private var showDriveHelp = false

    @State private var pendingDelete: ProjectMeta?
    @State private var renaming: ProjectMeta?
    @State private var renameText = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    newProjectCard
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if transcriber.prewarming {
                    Label("App 更新後要重新準備辨識模型，正在背景進行，不用等它", systemImage: "cpu")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if store.projects.isEmpty && !importing {
                    emptyHint
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(store.projects) { p in
                    NavigationLink(value: p.id) { ProjectRow(meta: p, model: store.existingModel(p.id)) }
                        .contextMenu {
                            Button("重新命名", systemImage: "pencil") {
                                renameText = p.displayName
                                renaming = p
                            }
                            Button("刪除", systemImage: "trash", role: .destructive) { pendingDelete = p }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("刪除", systemImage: "trash") { pendingDelete = p }
                                .tint(.red)
                        }
                }
            }
            .listStyle(.plain)
            .navigationTitle("語音剪輯")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("設定")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let meta = store.projects.first(where: { $0.id == id }) {
                    ProjectView(model: store.model(for: meta))
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .movie]) { result in
                switch result {
                case .success(let url): importFile(url)
                case .failure(let e): error = e.localizedDescription
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                importing = true
                Task {
                    defer {
                        importing = false
                        photoItem = nil
                    }
                    do {
                        guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { return }
                        let meta = try await store.create(from: movie.url, move: true)
                        path = [meta.id]
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            // 只處理其他 App 分享進來的檔案；SideStore 安裝／重新簽章後會用 sidestore-… 網址打開 App，忽略即可
            .onOpenURL { url in
                if url.isFileURL { importFile(url) }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert("無法匯入", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") {}
            } message: {
                Text(error ?? "")
            }
            .alert("從 Google 雲端硬碟匯入", isPresented: $showDriveHelp) {
                Button("好") {}
            } message: {
                Text("點「新增專案 › 從「檔案」選擇」，在右下角「瀏覽」選「Drive」。看不到的話，先安裝並登入「Google 雲端硬碟」App，再到「瀏覽」右上角「⋯ › 編輯」把 Drive 打開。")
            }
            .confirmationDialog("刪除「\(pendingDelete?.displayName ?? "")」？",
                                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("刪除專案", role: .destructive) {
                    if let p = pendingDelete { store.delete(p) }
                }
            } message: {
                Text("會刪除這個專案的逐字稿和剪好的檔案，無法復原。照片或「檔案」裡的原始檔不受影響。")
            }
            .alert("重新命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("專案名稱", text: $renameText)
                Button("儲存") {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if let p = renaming, !name.isEmpty { store.rename(p, to: name) }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    /// 最上面的「新增專案」卡片：點開選照片或檔案
    private var newProjectCard: some View {
        Menu {
            PhotosPicker(selection: $photoItem, matching: .videos) {
                Label("從「照片」選影片", systemImage: "photo.on.rectangle")
            }
            Button("從「檔案」選擇", systemImage: "folder") { showImporter = true }
            Section {
                Button("怎麼從 Google 雲端硬碟匯入？", systemImage: "questionmark.circle") { showDriveHelp = true }
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.accentColor)
                    if importing {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "plus").font(.title2.weight(.bold)).foregroundStyle(.black)
                    }
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(importing ? "匯入中…" : "新增專案").font(.title3.weight(.bold)).foregroundStyle(.primary)
                    Text(importing ? "雲端檔案會先下載到手機" : "從照片或檔案匯入影片、錄音")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.06)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .disabled(importing)
        .accessibilityLabel("新增專案")
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.minus")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("剪掉嗯、呃和停頓").font(.headline)
            Text("匯入訪談、Podcast 或口說影片，自動剪掉語助詞、口吃與過長的停頓。全程在 iPhone 上處理。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func importFile(_ url: URL) {
        importing = true
        Task {
            defer { importing = false }
            do {
                let meta = try await store.create(from: url)
                path = [meta.id]
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct ProjectRow: View {
    let meta: ProjectMeta
    let model: ProjectModel?

    var body: some View {
        HStack(spacing: 14) {
            Thumbnail(meta: meta)
            VStack(alignment: .leading, spacing: 3) {
                Text(meta.displayName).font(.body.weight(.medium)).lineLimit(1)
                if let model {
                    LiveStatus(model: model, meta: meta)
                } else {
                    Text(Self.summary(meta)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if model?.isBusy != true { badge }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var badge: some View {
        if meta.rangeChosen == false {
            StatusBadge(text: "未處理", color: .orange)
        } else if case .failed? = model?.stage {
            StatusBadge(text: "失敗", color: .red)
        } else if meta.isTranscript {
            StatusBadge(text: "逐字稿", color: .secondary)
        } else if let o = meta.outputDuration, !meta.outputStale,
                  let d = meta.range.map({ $0.end - $0.start }) ?? meta.info?.duration, d > 0 {
            StatusBadge(text: "−\(Int(((1 - o / d) * 100).rounded()))%", color: .accentColor)
                .accessibilityLabel("剪後 \(ProjectModel.clock(o))")
        }
    }

    /// 只處理一段的標出「片段 2:14–2:38」；剪好的顯示「長度 → 剪後」，否則顯示長度；後面接日期
    static func summary(_ meta: ProjectMeta) -> String {
        var parts: [String] = []
        if let r = meta.range {
            parts.append("片段 " + ProjectModel.clock(r.start) + "–" + ProjectModel.clock(r.end))
        }
        if let d = meta.range.map({ $0.end - $0.start }) ?? meta.info?.duration {
            if let o = meta.outputDuration, !meta.outputStale {
                parts.append(ProjectModel.clock(d) + " → " + ProjectModel.clock(o))
            } else {
                parts.append(ProjectModel.clock(d))
            }
        }
        parts.append(meta.created.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}

/// 專案開著時跟著處理進度更新
private struct LiveStatus: View {
    @ObservedObject var model: ProjectModel
    let meta: ProjectMeta

    var body: some View {
        if model.isBusy {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.progress.map { "處理中 \(Int($0 * 100))%" } ?? "處理中…")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                ProgressView(value: model.progress ?? 0)
                    .tint(Color.accentColor)
                    .frame(maxWidth: 160)
            }
        } else {
            Text(ProjectRow.summary(model.meta)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit().bold())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// 影片用第一格畫面當縮圖（存在專案資料夾，下次直接讀），右下角標長度；聲音檔顯示聲波圖示
private struct Thumbnail: View {
    let meta: ProjectMeta
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.white.opacity(0.08))
                Image(systemName: meta.info?.isVideo == false ? "waveform" : "film")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let d = meta.info?.duration, meta.info?.isVideo == true {
                Text(ProjectModel.clock(d))
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .padding(3)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: meta.id) { image = await Self.load(meta) }
    }

    static func load(_ meta: ProjectMeta) async -> UIImage? {
        guard meta.info?.isVideo != false else { return nil }
        let dir = ProjectStore.folder(meta.id)
        let cache = dir.appendingPathComponent("thumb.jpg")
        if let img = UIImage(contentsOfFile: cache.path) { return img }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: dir.appendingPathComponent(meta.sourceName)))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 200, height: 200)
        guard let cg = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image else { return nil }
        let img = UIImage(cgImage: cg)
        try? img.jpegData(compressionQuality: 0.8)?.write(to: cache)
        return img
    }
}

/// 從「照片」取得的影片：先複製到暫存資料夾
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("影片-\(Int(Date().timeIntervalSince1970)).\(ext)")
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: received.file, to: dst)
            return PickedMovie(url: dst)
        }
    }
}
