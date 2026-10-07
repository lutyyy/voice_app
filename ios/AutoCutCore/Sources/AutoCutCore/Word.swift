import Foundation

/// 每個字的處理方式：保留、剪掉，或交給使用者／Claude 判斷
public enum Action: String, Codable, Sendable {
    case keep, cut, review
}

/// 逐字稿中的一個字（或補抓到的片段），對應 autocut.py 的 words.json／plan.csv 一列
public struct Word: Codable, Equatable, Sendable {
    public var seg: Int
    public var start: Double
    public var end: Double
    public var text: String
    /// 主辨識的字信心分數
    public var prob: Double?
    /// 第二輪漏字補抓的片段
    public var extra: Bool
    /// 補抓片段的平均 log 機率（雜音被硬聽成字時通常 < -1）
    public var logprob: Double?
    /// 單獨重聽的結果（被聽成正常字的語助詞）
    public var misheard: String?
    public var action: Action
    public var reason: String
    /// 疑似贅詞組編號（R###），0 表示沒有
    public var rid: Int
    /// 拖音修剪前的結尾；斷句用，調整拖音參數時句子編號才不會跟著變
    public var fitEnd: Double?
    /// 使用者修正的錯字（只影響顯示與逐字稿匯出；給 Claude 的版本碼仍用原文，剪輯位置不變）
    public var edited: String?
    /// 第一次手動改之前的自動判斷（「還原自動判斷」用；沒手動改過時為 nil）
    public var autoAction: Action?
    public var autoReason: String?

    /// 畫面與匯出用的文字
    public var display: String { edited ?? text }

    public init(seg: Int, start: Double, end: Double, text: String, prob: Double? = nil,
                extra: Bool = false, logprob: Double? = nil, misheard: String? = nil,
                action: Action = .keep, reason: String = "", rid: Int = 0, fitEnd: Double? = nil, edited: String? = nil) {
        self.seg = seg
        self.start = start
        self.end = end
        self.text = text
        self.prob = prob
        self.extra = extra
        self.logprob = logprob
        self.misheard = misheard
        self.action = action
        self.reason = reason
        self.rid = rid
        self.fitEnd = fitEnd
        self.edited = edited
    }

    mutating func mark(_ action: Action, _ reason: String) {
        self.action = action
        self.reason = reason
    }
}

/// 一段時間區間（秒）
public struct Span: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(_ start: Double, _ end: Double) {
        self.start = start
        self.end = end
    }
}

/// 四捨五入到小數 3 位（與 Python 版 round(x, 3) 一致）
@inline(__always) func r3(_ x: Double) -> Double {
    (x * 1000).rounded() / 1000
}

public func formatTime(_ t: Double) -> String {
    let t = max(0, t)
    let h = Int(t / 3600)
    let m = Int(t.truncatingRemainder(dividingBy: 3600) / 60)
    let s = t.truncatingRemainder(dividingBy: 60)
    return String(format: "%02d:%02d:%06.3f", h, m, s)
}
