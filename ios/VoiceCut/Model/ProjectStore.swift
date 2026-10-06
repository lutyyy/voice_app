import AutoCutCore
import Foundation

/// 一個剪輯專案（一個匯入的影音檔），存在 Documents/Projects/<id>/
struct ProjectMeta: Codable, Identifiable, Equatable {
    var id: UUID
    /// 原始檔名（顯示用）
    var name: String
    /// 專案資料夾內的原檔檔名
    var sourceName: String
    var created: Date
    var info: MediaInfo?
    /// 剪好的檔案（專案資料夾內）
    var outputName: String?
    var outputDuration: Double?
    /// 標記改過、還沒重新輸出
    var outputStale = false
    /// Claude 的回覆（刪除清單）
    var deletes: String?
    /// 產生目前標記時用的拖音參數（nil = 舊版預設）；設定改了就重新標記
    var planOptions: PlanOptions?
    /// 只處理原檔的這一段；nil = 整個檔案
    var range: ClipRange?
    /// false = 新匯入、還沒選範圍（舊專案沒有這個欄位，視為已選）
    var rangeChosen: Bool?
    /// 說話者自訂名稱（依編號）
    var speakerNames: [String]?

    var displayName: String { (name as NSString).deletingPathExtension }
}

/// 專案清單
@MainActor
final class ProjectStore: ObservableObject {
    static let shared = ProjectStore()

    @Published private(set) var projects: [ProjectMeta] = []
    private var models: [UUID: ProjectModel] = [:]

    static var root: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Projects")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }

    init() { reload() }

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        projects = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")) else { return nil }
            return try? JSONDecoder.iso.decode(ProjectMeta.self, from: data)
        }.sorted { $0.created > $1.created }
    }

    func model(for meta: ProjectMeta) -> ProjectModel {
        if let m = models[meta.id] { return m }
        let m = ProjectModel(meta: meta, store: self)
        models[meta.id] = m
        return m
    }

    /// 匯入檔案：複製到專案資料夾（原檔不動）。
    /// 在背景複製，並透過 NSFileCoordinator 讀取：Google 雲端硬碟、iCloud 等雲端檔案會先下載到手機
    func create(from url: URL, move: Bool = false) async throws -> ProjectMeta {
        let id = UUID()
        let dir = Self.folder(id)
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
        let dst = dir.appendingPathComponent("source." + ext)
        try await offMainThrowing {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                if move {
                    try FileManager.default.moveItem(at: url, to: dst)
                } else {
                    var coordError: NSError?
                    var copyError: Error?
                    NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordError) { readURL in
                        do {
                            try FileManager.default.copyItem(at: readURL, to: dst)
                        } catch {
                            copyError = error
                        }
                    }
                    if let e = (coordError as Error?) ?? copyError { throw e }
                }
            } catch {
                try? FileManager.default.removeItem(at: dir)
                throw error
            }
        }
        var meta = ProjectMeta(id: id, name: url.lastPathComponent, sourceName: dst.lastPathComponent, created: Date())
        meta.rangeChosen = false
        try save(meta)
        reload()
        return meta
    }

    func save(_ meta: ProjectMeta) throws {
        let data = try JSONEncoder.iso.encode(meta)
        try data.write(to: Self.folder(meta.id).appendingPathComponent("meta.json"), options: .atomic)
        if let i = projects.firstIndex(where: { $0.id == meta.id }) { projects[i] = meta }
    }

    func delete(_ meta: ProjectMeta) {
        models[meta.id]?.cancel()
        models[meta.id] = nil
        try? FileManager.default.removeItem(at: Self.folder(meta.id))
        reload()
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
