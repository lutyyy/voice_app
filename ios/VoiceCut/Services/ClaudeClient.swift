import Foundation

/// 請 Claude 判斷逐句稿：挑出講錯重講、重複的句子，以及能剪的疑似贅詞（電腦版需要手動貼上的步驟）
struct ClaudeClient {
    let apiKey: String
    var model = "claude-opus-5-5"

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 送出 sentencesText，回傳 Claude 的回覆（第一行是版本碼，接著 S###／R### 編號）
    func judge(_ sentencesText: String) async throws -> String {
        try await send(sentencesText)
    }

    /// 整理逐字稿：潤飾成文章、重點摘要或 YouTube 章節
    func polish(_ transcript: String, task: PolishTask) async throws -> String {
        try await send(task.instruction + "\n\n<逐字稿>\n" + transcript + "</逐字稿>")
    }

    /// 一般請求（例如加標點）：直接送出內容
    func complete(_ content: String) async throws -> String {
        try await send(content)
    }

    private func send(_ content: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // 安全分類器拒答時，由伺服器自動改用合適的模型重試
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "fallbacks": "default",
            "output_config": ["effort": "medium"],
            "messages": [["role": "user", "content": content]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            switch status {
            case 401: throw APIError(message: "API 金鑰無效，請到設定重新輸入。（\(msg)）")
            case 429: throw APIError(message: "請求太頻繁或額度不足，請稍後再試。（\(msg)）")
            default: throw APIError(message: "Claude 回應錯誤：\(msg)")
            }
        }
        if json["stop_reason"] as? String == "refusal" {
            throw APIError(message: "Claude 拒絕處理這段內容，請改用手動標記。")
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        if text.isEmpty { throw APIError(message: "Claude 沒有回覆內容") }
        return text
    }
}

/// 用 Claude 整理逐字稿的種類
enum PolishTask: String, CaseIterable, Identifiable {
    case article, summary, chapters

    var id: String { rawValue }

    var name: String {
        switch self {
        case .article: return "潤飾成文章"
        case .summary: return "重點摘要"
        case .chapters: return "YouTube 章節"
        }
    }

    var icon: String {
        switch self {
        case .article: return "doc.richtext"
        case .summary: return "list.bullet.rectangle"
        case .chapters: return "list.number"
        }
    }

    var instruction: String {
        let head = "以下是一段口語錄音的逐字稿，每行一句，開頭的 [分:秒] 是時間；可能有「說話者 N：」標示換人說話，也可能有語音辨識的同音錯字。"
        switch self {
        case .article:
            return head + "請整理成通順好讀的文章：加上標點與分段、修正明顯的同音錯字、刪除口頭禪與重複的字句，但保留說話者的原意、用詞與語氣，不要加入原文沒有的內容。有多位說話者時保留對話形式。使用繁體中文（台灣用語）。只輸出整理後的文章，不要時間碼，也不要任何說明。"
        case .summary:
            return head + "請用繁體中文（台灣用語）寫：\n1. 一段 3～5 句的摘要\n2. 條列 5～10 個重點\n3. 如果有提到結論、待辦事項或數字資料，另外條列\n只根據逐字稿內容，不要補充外部資訊。"
        case .chapters:
            return head + "請產生 YouTube 影片的章節列表：第一行必須是 00:00，每行格式為「分:秒 章節標題」（超過一小時用「時:分:秒」），時間取自逐字稿，章節之間至少間隔 1 分鐘，總長太短就少分幾章；標題簡短（15 字以內）、具體。使用繁體中文（台灣用語）。只輸出章節列表。"
        }
    }
}
