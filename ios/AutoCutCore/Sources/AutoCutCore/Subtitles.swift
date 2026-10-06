import Foundation

/// 說話者分段（語者辨識的結果）
public struct SpeakerTurn: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: Int
    public init(start: Double, end: Double, speaker: Int) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// 一則字幕
public struct Cue: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: Int?
    public init(start: Double, end: Double, text: String, speaker: Int? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

/// 逐字稿與字幕：TXT／SRT／VTT
public enum Subtitles {
    static let breakPunct: Set<Character> = ["，", "。", "？", "！", "、", "；", "：", ",", ".", "?", "!", ";", ":"]
    static let endPunct: Set<Character> = ["。", "？", "！", ".", "?", "!"]

    /// 把字接成一句：中文直接相接，英數字之間補空白
    public static func join(_ parts: [String]) -> String {
        var out = ""
        for p in parts where !p.isEmpty {
            if let a = out.last, let b = p.first, isLatin(a), isLatin(b) { out.append(" ") }
            out += p
        }
        return out
    }

    private static func isLatin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

    /// 每個字的說話者：和哪個說話者的時間重疊最多
    public static func speakers(for words: [Word], turns: [SpeakerTurn]) -> [Int?] {
        if turns.isEmpty { return words.map { _ in nil } }
        let sorted = turns.sorted { $0.start < $1.start }
        var lo = 0
        return words.map { w in
            while lo < sorted.count && sorted[lo].end < w.start - 30 { lo += 1 }
            var best: (Int, Double)?
            var k = lo
            while k < sorted.count && sorted[k].start < w.end + 0.5 {
                let t = sorted[k]
                let ov = min(w.end, t.end) - max(w.start, t.start)
                // 沒有重疊時，取最近的（負值越接近 0 越近）
                if best == nil || ov > best!.1 { best = (t.speaker, ov) }
                k += 1
            }
            if let b = best, b.1 > -0.5 { return b.0 }
            return nil
        }
    }

    /// 只留保留的字，時間換成剪好的檔案中的時間
    public static func mapToOutput(_ words: [Word], segs: [Seg]) -> [(word: Word, index: Int)] {
        var out: [(Word, Int)] = []
        for (i, w) in words.enumerated() where w.action == .keep {
            guard let s = Renderer.toOutput(segs, w.start), let e0 = Renderer.toOutput(segs, max(w.start, w.end - 0.001)) else { continue }
            var m = w
            m.start = (s * 1000).rounded() / 1000
            m.end = max(m.start + 0.01, ((e0 + 0.001) * 1000).rounded() / 1000)
            out.append((m, i))
        }
        return out
    }

    /// 字幕分段：換句、換說話者、停頓太久、字數或時間太長就換一則。句尾標點去掉
    public static func cues(_ words: [Word], speakers: [Int?]? = nil, maxChars: Int = 18, maxDuration: Double = 6,
                            maxGap: Double = 0.8) -> [Cue] {
        var out: [Cue] = []
        var cur: [Word] = []
        var curSpeaker: Int?
        func flush() {
            guard let a = cur.first, let b = cur.last else { return }
            var text = join(cur.map(\.display)).trimmingCharacters(in: .whitespaces)
            while let l = text.last, breakPunct.contains(l) { text.removeLast() }
            if !text.isEmpty { out.append(Cue(start: a.start, end: b.end, text: text, speaker: curSpeaker)) }
            cur = []
        }
        for (i, w) in words.enumerated() {
            let sp = speakers?[i] ?? nil
            if let last = cur.last {
                let len = join(cur.map(\.display)).count
                if w.seg != last.seg || sp != curSpeaker || w.start - last.end > maxGap
                    || len + w.display.count > maxChars || w.end - cur[0].start > maxDuration {
                    flush()
                }
            }
            if cur.isEmpty { curSpeaker = sp }
            cur.append(w)
            // 句中標點後，字數過半就先斷
            if let c = w.display.last, breakPunct.contains(c), join(cur.map(\.display)).count >= maxChars / 2 { flush() }
        }
        flush()
        // 下一則開始前結束，避免重疊
        for i in out.indices.dropLast() where out[i].end > out[i + 1].start {
            out[i].end = out[i + 1].start
        }
        return out
    }

    static func stamp(_ t: Double, _ sep: Character) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60)
            + String(sep) + String(format: "%03d", ms % 1000)
    }

    public static func srt(_ cues: [Cue], names: (Int) -> String = { "說話者 \($0 + 1)" }) -> String {
        cues.enumerated().map { i, c in
            "\(i + 1)\n\(stamp(c.start, ",")) --> \(stamp(c.end, ","))\n\(label(c, names))\n"
        }.joined(separator: "\n")
    }

    public static func vtt(_ cues: [Cue], names: (Int) -> String = { "說話者 \($0 + 1)" }) -> String {
        "WEBVTT\n\n" + cues.map { c in
            let text = c.speaker.map { "<v \(names($0))>" + c.text } ?? c.text
            return "\(stamp(c.start, ".")) --> \(stamp(c.end, "."))\n\(text)\n"
        }.joined(separator: "\n")
    }

    private static func label(_ c: Cue, _ names: (Int) -> String) -> String {
        c.speaker.map { "\(names($0))：" + c.text } ?? c.text
    }

    /// 純文字逐字稿：每句一行；有說話者時換人就加上名字並空一行；可選擇加時間
    public static func text(_ words: [Word], speakers: [Int?]? = nil, timestamps: Bool = false,
                            names: (Int) -> String = { "說話者 \($0 + 1)" }) -> String {
        var lines: [String] = []
        var i = 0
        var lastSpeaker: Int??
        while i < words.count {
            var j = i
            while j < words.count && words[j].seg == words[i].seg && (speakers?[j] ?? nil) == (speakers?[i] ?? nil) { j += 1 }
            let sp = speakers?[i] ?? nil
            var line = join(words[i..<j].map(\.display))
            if let l = line.last, !endPunct.contains(l), !breakPunct.contains(l) { line += "。" }
            if timestamps { line = "[\(clock(words[i].start))] " + line }
            if let sp, lastSpeaker != .some(sp) {
                if !lines.isEmpty { lines.append("") }
                lines.append("\(names(sp))：")
            }
            lastSpeaker = .some(sp)
            lines.append(line)
            i = j
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func clock(_ t: Double) -> String {
        let s = Int(max(0, t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
