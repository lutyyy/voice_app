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

    @AppStorage("maxPause") var maxPause = 0.35
    @AppStorage("keepPause") var keepPause = 0.22
    @AppStorage("breathCut") var breathCut = true
    @AppStorage("roomtone") var roomtone = true

    /// 已同意把逐字稿傳送給 Anthropic（App Review 5.1.2(i)：傳給第三方 AI 前需取得同意）
    @AppStorage("claudeConsent") var claudeConsent = false

    var renderOptions: RenderOptions {
        var o = RenderOptions()
        o.maxPause = max(maxPause, keepPause)
        o.keepPause = keepPause
        o.breathCut = breathCut ? 18 : 0
        o.roomtone = roomtone
        return o
    }

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
