import Foundation

/// 全部剪輯參數：標記（拖音）＋輸出（停頓、剪接點、呼吸聲、底噪）
public struct CutSettings: Codable, Equatable, Sendable {
    public var plan = PlanOptions()
    public var render = RenderOptions()
    public init() {}

    /// 輸出前修正互相矛盾的值（例如壓縮門檻小於保留長度）
    public var sanitized: CutSettings {
        var s = self
        s.render.maxPause = max(s.render.maxPause, s.render.keepPause)
        s.render.minGapSentence = min(s.render.minGapSentence, s.render.keepPause)
        s.render.minGapPhrase = min(s.render.minGapPhrase, s.render.minGapSentence)
        s.render.xfadeLong = max(s.render.xfadeLong, s.render.xfade)
        s.plan.trimTo = min(s.plan.trimTo, s.plan.maxChar)
        return s
    }
}

/// 剪輯風格的預設組合；使用者套用後可以再微調個別參數（改過就變成「自訂」）
public enum CutPreset: String, CaseIterable, Identifiable, Sendable {
    case natural, standard, compact

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .natural: return "自然"
        case .standard: return "標準"
        case .compact: return "精簡"
        }
    }

    public var note: String {
        switch self {
        case .natural: return "停頓留得比較多、剪接最不明顯，適合訪談、Podcast"
        case .standard: return "與電腦版相同的設定，兼顧節奏與自然"
        case .compact: return "停頓壓到最短、拖音也剪，長度最短，適合短影音"
        }
    }

    /// 沒有 Claude 判斷時，疑似贅詞要不要剪
    public var cutReview: Bool { self != .natural }

    public var settings: CutSettings {
        var s = CutSettings()
        switch self {
        case .standard:
            break
        case .natural:
            s.render.maxPause = 0.6
            s.render.keepPause = 0.35
            s.render.minGapSentence = 0.2
            s.render.minGapPhrase = 0.05
            s.render.minCut = 0.15
            s.render.xfade = 0.03
            s.render.xfadeLong = 0.08
            s.render.breathCut = 10
            s.plan.maxChar = 0.9
            s.plan.trimTo = 0.6
        case .compact:
            s.render.maxPause = 0.25
            s.render.keepPause = 0.12
            s.render.minGapSentence = 0.08
            s.render.minGapPhrase = 0.02
            s.render.minCut = 0.06
            s.render.breathCut = 24
            s.plan.maxChar = 0.45
            s.plan.trimTo = 0.3
        }
        return s
    }

    /// 目前的參數符合哪個預設；都不符合（使用者改過）時為 nil
    public static func matching(_ s: CutSettings) -> CutPreset? {
        allCases.first { $0.settings == s }
    }
}
