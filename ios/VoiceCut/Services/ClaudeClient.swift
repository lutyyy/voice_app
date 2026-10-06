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
            "messages": [["role": "user", "content": sentencesText]],
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
