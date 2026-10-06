import Foundation

/// 語助詞、口吃、幻覺字幕等文字規則（與 autocut.py 相同）
public enum TextRules {
    /// 一定是贅詞：直接剪
    public static let sureFillers: Set<String> = [
        "嗯", "嗯嗯", "呃", "呃呃", "額", "额", "欸", "誒", "恩", "唔",
        "um", "uh", "umm", "uhh", "erm", "hmm", "mm",
    ]
    /// 可能是贅詞：只標記 review，讓使用者（或 Claude）決定
    public static let maybeFillers: Set<String> = [
        "那個", "就是", "就是說", "然後", "然後呢", "對", "對對", "對對對",
        "啊", "喔", "哦", "齁", "吼", "這個", "反正", "其實", "基本上", "所以說", "好像",
        // Whisper 有時輸出簡體，一併涵蓋
        "那个", "然后", "然后呢", "对", "对对", "对对对", "这个", "其实", "所以说",
    ]
    /// 正常的疊字：中間沒有停頓時不當成口吃
    public static let redup: Set<String> = {
        var s = Set("謝看剛常慢媽爸哥姐弟妹天人好試想說談走聽等往漸個偏明稍大小多星寶默紛輕悄統通僅處時年層步點一乖剛謝".map { String($0) + String($0) })
        s.formUnion(["谢谢", "刚刚", "妈妈", "爸爸", "试试", "说说", "谈谈", "听听", "渐渐", "个个", "稍稍", "宝宝",
                     "纷纷", "轻轻", "统统", "通通", "仅仅", "处处", "时时", "层层", "步步", "点点"])
        return s
    }()
    /// 第二輪補回的片段只由這些字組成 → 視為語助詞（含呼吸聲常被聽成的嗨、哈、哎）
    public static let fillerChars: Set<Character> = Set("嗯呃額额欸誒诶恩唔啊阿喔哦噢耶嗨哈哎呦呀嘿")
    public static let backchannels: Set<String> = [
        "是", "是是", "好", "好好", "對", "对", "對啊", "對阿", "对啊", "嗯對", "是的", "對對", "对对",
    ]
    /// 成品裡仍聽得到、一定是贅詞的字（refine 用）
    public static let refineSure: Set<String> = ["嗯", "呃", "額", "额", "欸", "誒", "诶", "恩", "唔", "噢", "哎", "um", "uh", "hmm", "mm"]
    /// 啊、喔等只有前面有停頓（不是接在字後面的語尾）才算
    public static let refineLoose: Set<String> = ["啊", "阿", "喔", "哦", "呀", "耶"]
    public static let refineChars: Set<Character> = Set("嗯呃額额欸誒诶恩唔")

    static let punctChars: Set<Character> = Set("，。、！？,.!?；;：:「」『』\"'（）()…—-~﹗﹐﹑﹔﹖﹕")
    static let endPunctChars: Set<Character> = Set("，。、！？,.!?；;：…﹗﹐﹑﹔﹖")
    static let sentenceEndChars: Set<Character> = Set("。！？!?")

    static let hallucination = try! NSRegularExpression(
        pattern: "字幕|訂閱|订阅|頻道|频道|Amara|感謝觀看|感谢观看|點贊|点赞|請不吝|请不吝|明鏡|明镜|李宗盛|剪輯|作詞|作曲|字幕by|MING PAO|明報|明报",
        options: [.caseInsensitive])

    /// 去掉標點與空白、轉小寫，用來比對
    public static func norm(_ t: String) -> String {
        String(t.filter { !punctChars.contains($0) && !$0.isWhitespace }).lowercased()
    }

    static func lastNonSpace(_ t: String) -> Character? {
        t.last(where: { !$0.isWhitespace })
    }

    /// 結尾是逗號、句號等標點（句子或片語的邊界）
    public static func endsWithPunct(_ t: String) -> Bool {
        guard let c = lastNonSpace(t) else { return false }
        return endPunctChars.contains(c)
    }

    /// 結尾是句號、問號、驚嘆號（一句話講完了）
    static func endsSentence(_ t: String) -> Bool {
        guard let c = lastNonSpace(t) else { return false }
        return sentenceEndChars.contains(c)
    }

    static func isHallucination(_ t: String) -> Bool {
        hallucination.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    static func isASCII(_ t: String) -> Bool {
        t.unicodeScalars.allSatisfy { $0.isASCII }
    }

    static func allFillerChars(_ t: String, _ set: Set<Character> = fillerChars) -> Bool {
        !t.isEmpty && t.allSatisfy { set.contains($0) }
    }
}
