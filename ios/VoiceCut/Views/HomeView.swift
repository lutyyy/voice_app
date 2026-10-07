import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 首頁：匯入影音檔、專案清單
struct HomeView: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var path: [UUID] = []
    @State private var showImporter = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showSettings = false
    @State private var importing = false
    @State private var error: String?
    @State private var showDriveHelp = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if importing {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("匯入中…（雲端檔案會先下載）").foregroundStyle(.secondary)
                    }
                }
                ForEach(store.projects) { p in
                    NavigationLink(value: p.id) { ProjectRow(meta: p) }
                }
                .onDelete { idx in
                    for i in idx { store.delete(store.projects[i]) }
                }
            }
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
            .safeAreaInset(edge: .bottom) {
                Menu {
                    Button("從「檔案」選擇", systemImage: "folder") { showImporter = true }
                    PhotosPicker(selection: $photoItem, matching: .videos) {
                        Label("從「照片」選影片", systemImage: "photo.on.rectangle")
                    }
                } label: {
                    PillLabel(title: "新增專案", icon: "plus")
                }
                .disabled(importing)
                .padding(.bottom, 8)
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
            .overlay {
                if store.projects.isEmpty && !importing {
                    ContentUnavailableView {
                        Label("剪掉嗯、呃和停頓", systemImage: "waveform.badge.minus")
                    } description: {
                        Text("匯入訪談、Podcast 或口說影片，自動剪掉語助詞、口吃與過長的停頓。全程在 iPhone 上處理。")
                    } actions: {
                        Button("怎麼從 Google 雲端硬碟匯入？") { showDriveHelp = true }
                            .font(.footnote)
                    }
                }
            }
        }
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

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: meta.info?.isVideo == true ? "film" : "waveform")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.black)
                .frame(width: 46, height: 46)
                .background(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.55)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(meta.displayName).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(meta.created, format: .dateTime.month().day().hour().minute())
                    if let d = meta.info?.duration { Text("· " + ProjectModel.clock(d)) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let o = meta.outputDuration, !meta.outputStale, let d = meta.info?.duration, d > 0 {
                Text("−\(Int(((1 - o / d) * 100).rounded()))%")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .accessibilityLabel("剪後 \(ProjectModel.clock(o))")
            }
        }
        .padding(.vertical, 4)
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
