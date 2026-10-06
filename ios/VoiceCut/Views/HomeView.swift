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

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Button {
                        showImporter = true
                    } label: {
                        Label("從「檔案」選擇音檔或影片", systemImage: "folder")
                    }
                    PhotosPicker(selection: $photoItem, matching: .videos) {
                        Label("從「照片」選擇影片", systemImage: "photo.on.rectangle")
                    }
                } footer: {
                    Text("自動剪掉語助詞（嗯、呃、欸…）、口吃重複、過長的停頓與停頓中的呼吸聲。辨識與剪輯都在 iPhone 上完成。")
                }

                if importing {
                    HStack {
                        ProgressView()
                        Text("匯入中…（雲端檔案會先下載）").foregroundStyle(.secondary)
                    }
                }

                if !store.projects.isEmpty {
                    Section("專案") {
                        ForEach(store.projects) { p in
                            NavigationLink(value: p.id) { ProjectRow(meta: p) }
                        }
                        .onDelete { idx in
                            for i in idx { store.delete(store.projects[i]) }
                        }
                    }
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
            .onOpenURL { url in importFile(url) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert("無法匯入", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") {}
            } message: {
                Text(error ?? "")
            }
            .overlay {
                if store.projects.isEmpty && !importing {
                    ContentUnavailableView {
                        Label("還沒有專案", systemImage: "waveform.badge.minus")
                    } description: {
                        Text("選一個訪談、Podcast 或口說影片開始")
                    }
                    .padding(.top, 220)
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
        HStack(spacing: 12) {
            Image(systemName: meta.info?.isVideo == true ? "film" : "waveform")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.displayName).lineLimit(1)
                HStack(spacing: 6) {
                    Text(meta.created, format: .dateTime.month().day().hour().minute())
                    if let d = meta.info?.duration { Text("· " + ProjectModel.clock(d)) }
                    if let o = meta.outputDuration, !meta.outputStale { Text("→ " + ProjectModel.clock(o)) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
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
