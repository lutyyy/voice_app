import AutoCutCore
import SwiftUI

/// 使用者設定（存在 UserDefaults；Claude API 金鑰另存在鑰匙圈）
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// WhisperKit 模型名稱；空字串 = 依裝置自動選擇
    @AppStorage("model") var model = ""
    /// 第二輪：有人聲但沒有字的片段單獨再辨識（救回漏掉的語助詞與整句）
    @AppStorage("gapFill") var gapFill = true
    /// 輸出後重新辨識成品、補剪殘留語助詞的輪數（0 = 不做）
    @AppStorage("refineRounds") var refineRounds = 1
    /// 沒有 Claude 判斷時，疑似贅詞全部剪掉（與電腦版 run.bat 相同）
    @AppStorage("cutReview") var cutReview = true
    /// 音訊輸出格式：m4a / wav（影片一律輸出 mp4）
    @AppStorage("audioFormat") var audioFormat = "m4a"
    /// 自訂辨識提示詞（可放專有名詞）
    @AppStorage("prompt") var prompt = ""

    /// 舊版的四個輸出設定；只用來把舊設定搬到 cutSettings
    @AppStorage("maxPause") private var legacyMaxPause = 0.35
    @AppStorage("keepPause") private var legacyKeepPause = 0.22
    @AppStorage("breathCut") private var legacyBreathCut = true
    @AppStorage("roomtone") private var legacyRoomtone = true
    /// 全部剪輯參數（JSON）；空的代表還沒改過，沿用舊版設定
    @AppStorage("cutSettings") private var cutData = Data()

    /// 已同意把逐字稿傳送給 Anthropic（App Review 5.1.2(i)：傳給第三方 AI 前需取得同意）
    @AppStorage("claudeConsent") var claudeConsent = false

    /// 目前的剪輯參數（預設＋使用者微調）
    var cut: CutSettings {
        get {
            if let c = try? JSONDecoder().decode(CutSettings.self, from: cutData) { return c }
            var c = CutSettings()
            c.render.maxPause = max(legacyMaxPause, legacyKeepPause)
            c.render.keepPause = legacyKeepPause
            c.render.breathCut = legacyBreathCut ? 18 : 0
            c.render.roomtone = legacyRoomtone
            return c.sanitized
        }
        set { cutData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// 目前的參數屬於哪個預設；改過任何一個值就是 nil（自訂）
    var preset: CutPreset? { CutPreset.matching(cut) }

    func apply(_ p: CutPreset) {
        cut = p.settings
        cutReview = p.cutReview
    }

    /// 實際使用的辨識模型
    @MainActor
    var resolvedModel: String { model.isEmpty ? Transcriber.defaultModel : model }

    /// 目前的模型／補抓／補剪組合屬於哪個速度等級；自訂時為 nil
    @MainActor
    var speed: SpeedTier? {
        SpeedTier.allCases.first { $0.model == resolvedModel && $0.gapFill == gapFill && $0.refineRounds == refineRounds }
    }

    func apply(_ t: SpeedTier) {
        model = t.model
        gapFill = t.gapFill
        refineRounds = t.refineRounds
    }

    var renderOptions: RenderOptions { cut.sanitized.render }
    var planOptions: PlanOptions { cut.sanitized.plan }

    var claudeKey: String {
        get { Keychain.read("claude-api-key") ?? "" }
        set {
            objectWillChange.send()
            if newValue.isEmpty {
                Keychain.delete("claude-api-key")
            } else {
                Keychain.write("claude-api-key", newValue)
            }
        }
    }

    var claudeReady: Bool { claudeConsent && !claudeKey.isEmpty }
}
