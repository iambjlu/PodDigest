// app/Net.swift
// 外部語音模型（/audio/transcriptions）與外部 LLM（/chat/completions）的 OpenAI 相容客戶端。
import Foundation

struct AppError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

struct Segment: Sendable {
    var start: Double
    var end: Double
    var text: String
}

enum Net {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral          // 不寫快取到硬碟
        c.timeoutIntervalForRequest = 1800
        c.timeoutIntervalForResource = 7200
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// 把使用者填的端點整理成 .../v1（只填到 host 時自動補 /v1）
    static func endpoint(_ base: String, _ path: String) throws -> URL {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        guard !b.isEmpty else { throw AppError("尚未設定服務網址（請到「設定」頁填寫）") }
        if !b.contains("://") { b = "http://" + b }
        guard let u = URL(string: b), u.host != nil else { throw AppError("服務網址格式不正確：\(base)") }
        if u.path.isEmpty || u.path == "/" { b += "/v1" }
        guard let url = URL(string: b + path) else { throw AppError("服務網址格式不正確：\(base)") }
        return url
    }

    static func apiError(_ data: Data, _ code: Int) -> String {
        if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = j["error"] as? [String: Any], let m = e["message"] as? String { return "HTTP \(code)：\(m)" }
            if let e = j["error"] as? String { return "HTTP \(code)：\(e)" }
            if let m = j["message"] as? String { return "HTTP \(code)：\(m)" }
            if let m = j["detail"] as? String { return "HTTP \(code)：\(m)" }
        }
        let s = String(data: data.prefix(300), encoding: .utf8) ?? ""
        return "HTTP \(code)：\(s)"
    }

    /// 送出請求；429／5xx／連線中斷會自動重試（最多 3 次）
    static func send(_ req: URLRequest, retries: Int = 3) async throws -> (Data, HTTPURLResponse) {
        var lastErr: Error = AppError("未知錯誤")
        for attempt in 0..<retries {
            do {
                // 暫停時立刻中斷這個連線，繼續後重新送出同一個請求（不算一次重試）
                let (data, resp) = try await PauseGate.interruptible { try await session.data(for: req) }
                guard let http = resp as? HTTPURLResponse else { throw AppError("伺服器回應異常") }
                if (http.statusCode == 429 || http.statusCode >= 500) && attempt < retries - 1 {
                    lastErr = AppError(apiError(data, http.statusCode))
                    try await Task.sleep(nanoseconds: UInt64(2 << attempt) * 1_000_000_000)
                    continue
                }
                return (data, http)
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as URLError where e.code == .cancelled {
                throw CancellationError()
            } catch let e as URLError where attempt < retries - 1
                        && [.networkConnectionLost, .timedOut, .cannotConnectToHost].contains(e.code) {
                lastErr = e
                try await Task.sleep(nanoseconds: UInt64(2 << attempt) * 1_000_000_000)
            } catch {
                throw error
            }
        }
        throw lastErr
    }

    /// GET /models，給設定頁「取得模型清單」與連線測試用
    static func listModels(base: String, key: String) async throws -> [String] {
        var req = URLRequest(url: try endpoint(base, "/models"))
        req.timeoutInterval = 15
        if !key.isEmpty { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        let (data, http) = try await send(req, retries: 1)
        guard http.statusCode == 200 else { throw AppError(apiError(data, http.statusCode)) }
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let arr = (j?["data"] as? [[String: Any]]) ?? (j?["models"] as? [[String: Any]]) ?? []
        return arr.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }.sorted()
    }
}

// MARK: - 語音轉文字

enum STTClient {
    /// 上傳一小段音訊，回傳文字與（若伺服器有提供）分句時間
    static func transcribe(file: URL, cfg: PipelineConfig, prompt: String) async throws -> (text: String, segments: [Segment]) {
        func once(_ prompt: String) async throws -> (text: String, segments: [Segment]) {
            do {
                return try await request(file: file, cfg: cfg, prompt: prompt, format: "verbose_json")
            } catch let e as AppError where e.message.hasPrefix("HTTP 400") || e.message.hasPrefix("HTTP 422") {
                // 有些伺服器不支援 verbose_json：退回純 json
                return try await request(file: file, cfg: cfg, prompt: prompt, format: "json")
            }
        }
        let r = stripEcho(try await once(prompt), prompt: prompt)
        // Whisper 在靜音或聽不清楚時會把提示詞當成辨識結果吐回來：濾掉後如果什麼都沒剩，不帶提示詞再試一次
        if r.text.isEmpty && !prompt.isEmpty { return stripEcho(try await once(""), prompt: "") }
        return r
    }

    private static func norm(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.letters.union(.decimalDigits).contains($0) })
    }

    /// 提示詞的回音：整段文字都只是提示詞裡的句子（可重複多次）
    static func isEcho(_ text: String, prompt: String) -> Bool {
        var n = norm(text)
        guard !n.isEmpty, !prompt.isEmpty else { return false }
        let parts = prompt.components(separatedBy: CharacterSet(charactersIn: "。，！？!?,.;；\n")).map(norm).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return false }
        if norm(prompt).contains(n) { return true }
        var changed = true
        while !n.isEmpty && changed {
            changed = false
            for p in parts.sorted(by: { $0.count > $1.count }) where n.contains(p) {
                n = n.replacingOccurrences(of: p, with: ""); changed = true
            }
        }
        return n.isEmpty
    }

    static func stripEcho(_ r: (text: String, segments: [Segment]), prompt: String) -> (text: String, segments: [Segment]) {
        guard !prompt.isEmpty else { return r }
        let segs = r.segments.filter { !isEcho($0.text, prompt: prompt) }
        if !r.segments.isEmpty { return (segs.map(\.text).joined(separator: " "), segs) }
        return isEcho(r.text, prompt: prompt) ? ("", []) : r
    }

    private static func request(file: URL, cfg: PipelineConfig, prompt: String, format: String) async throws -> (String, [Segment]) {
        let boundary = "PodDigest-" + UUID().uuidString
        var body = Data()
        func field(_ k: String, _ v: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
        }
        field("model", cfg.sttModel)
        field("response_format", format)
        field("temperature", "0.1")      // 0 是貪婪解碼，遇到靜音／音樂容易陷入重複迴圈；略高一點可降低機率
        let lang = cfg.sttLanguage.trimmingCharacters(in: .whitespaces)
        if !lang.isEmpty && lang != "auto" { field("language", lang) }
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(try Data(contentsOf: file, options: .mappedIfSafe))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: try Net.endpoint(cfg.sttBaseURL, "/audio/transcriptions"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !cfg.sttAPIKey.isEmpty { req.setValue("Bearer " + cfg.sttAPIKey, forHTTPHeaderField: "Authorization") }
        req.httpBody = body
        let (data, http) = try await Net.send(req)
        guard http.statusCode == 200 else { throw AppError(Net.apiError(data, http.statusCode)) }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 少數伺服器直接回純文字
            let t = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (t, [])
        }
        let text = (j["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var segs: [Segment] = []
        for s in (j["segments"] as? [[String: Any]]) ?? [] {
            let t = (s["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            segs.append(Segment(start: (s["start"] as? Double) ?? 0, end: (s["end"] as? Double) ?? 0, text: t))
        }
        return (text, segs)
    }
}

// MARK: - LLM

enum LLMClient {
    static func chat(system: String, user: String, cfg: PipelineConfig) async throws -> String {
        var model = cfg.llmModel.trimmingCharacters(in: .whitespaces)
        if model.isEmpty {                                   // 沒填模型：用伺服器第一個
            model = try await Net.listModels(base: cfg.llmBaseURL, key: cfg.llmAPIKey).first ?? ""
            if model.isEmpty { throw AppError("LLM 沒有填模型名稱，伺服器也沒有回傳可用模型") }
        }
        var payload: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "temperature": cfg.llmTemperature,
            "stream": false,
        ]
        if cfg.llmDisableThinking { payload["chat_template_kwargs"] = ["enable_thinking": false] }
        var req = URLRequest(url: try Net.endpoint(cfg.llmBaseURL, "/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cfg.llmAPIKey.isEmpty { req.setValue("Bearer " + cfg.llmAPIKey, forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, http) = try await Net.send(req)
        guard http.statusCode == 200 else { throw AppError(Net.apiError(data, http.statusCode)) }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (j["choices"] as? [[String: Any]])?.first,
              let msg = choice["message"] as? [String: Any] else {
            throw AppError("LLM 回應格式無法解析")
        }
        var content = ""
        if let s = msg["content"] as? String { content = s }
        else if let parts = msg["content"] as? [[String: Any]] { content = parts.compactMap { $0["text"] as? String }.joined() }
        content = stripThink(content)
        if content.isEmpty { throw AppError("LLM 回傳空內容（可能是模型只輸出了思考過程，可在設定打開「關閉模型思考」）") }
        return content
    }

    static func stripThink(_ s: String) -> String {
        var t = s
        if let r = try? NSRegularExpression(pattern: "<think>.*?</think>", options: [.dotMatchesLineSeparators]) {
            t = r.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        }
        if let r = t.range(of: "</think>") { t = String(t[r.upperBound...]) }   // 只有結尾標籤的情況
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}


/// 全域暫停閘門：暫停時立刻中斷進行中的連線（語音轉文字、LLM）與外部程式（yt-dlp、ffmpeg），
/// 在原地等待；繼續後從那一步重做（下載會續傳），已完成的步驟與進度不會丟。
enum PauseGate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held = false
    static var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return held }
    static func set(_ v: Bool) { lock.lock(); held = v; lock.unlock() }

    static func checkpoint() async throws {
        try Task.checkCancellation()
        while isPaused {
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        func set() { lock.lock(); v = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    }

    /// 執行 op；執行中若被暫停就取消它（連線中斷／行程終止），等繼續後整個重做。
    static func interruptible<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) async throws -> T {
        while true {
            try await checkpoint()
            let flag = Flag()
            let work = Task { try await op() }
            let watcher = Task {
                while !Task.isCancelled {
                    if isPaused { flag.set(); work.cancel(); return }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            let result = await withTaskCancellationHandler { await work.result } onCancel: { work.cancel() }
            watcher.cancel()
            if flag.isSet && !Task.isCancelled { continue }      // 因暫停而中斷：丟掉結果，繼續後重做
            return try result.get()
        }
    }
}
