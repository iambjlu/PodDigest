// app/Summarizer.swift
// 逐字稿 → 重點。短的一次做完；長的先分段抽取筆記，再（必要時分層）合併，最後依類型格式輸出。
import Foundation

enum Summarizer {
    static func mmss(_ t: Double) -> String {
        let s = Int(max(0, t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// 把分句整理成「[mm:ss] 一段話」的行（約 30 秒一行），沒有分句時只有純文字
    static func timestampedLines(_ segs: [Segment]) -> [String] {
        var lines: [String] = []
        var cur = "", curStart = 0.0
        for s in segs {
            if cur.isEmpty { curStart = s.start }
            cur += (cur.isEmpty ? "" : " ") + s.text
            if s.end - curStart >= 30 { lines.append("[\(mmss(curStart))] \(cur)"); cur = "" }
        }
        if !cur.isEmpty { lines.append("[\(mmss(curStart))] \(cur)") }
        return lines
    }

    /// 依字數把逐字稿行切成幾份（不拆行，超長行才硬切）
    static func split(lines: [String], limit: Int) -> [String] {
        var parts: [String] = [], cur = ""
        func flush() { if !cur.isEmpty { parts.append(cur); cur = "" } }
        for var line in lines {
            while line.count > limit {                       // 沒有分行的長文：在標點處硬切
                let idx = line.index(line.startIndex, offsetBy: limit)
                let head = line[..<idx]
                let cut = head.lastIndex(where: { "。！？!?，,；;\n".contains($0) }).map { line.index(after: $0) } ?? idx
                flush()
                parts.append(String(line[..<cut]))
                line = String(line[cut...])
            }
            if cur.count + line.count + 1 > limit { flush() }
            cur += (cur.isEmpty ? "" : "\n") + line
        }
        flush()
        return parts
    }

    /// 自動偵測內容類型：取開頭、中段、結尾各一小段（最多約 5,000 字）交給 LLM 分類；失敗或看不出來就當 Podcast
    static func detect(title: String, lines: [String], duration: Double, cfg: PipelineConfig) async -> Genre {
        let text = lines.map(Pipeline.stripStamp)
        func take(_ from: Int, _ limit: Int) -> String {
            var out = "", i = max(0, min(from, text.count))
            while i < text.count, out.count < limit { out += text[i] + "\n"; i += 1 }
            return String(out.prefix(limit))
        }
        let sample = text.joined(separator: "\n").count <= 5000 ? text.joined(separator: "\n")
            : "【開頭】\n" + take(0, 2200) + "\n【中段】\n" + take(text.count / 2, 1500) + "\n【結尾】\n" + take(max(0, text.count - 6), 1300)
        let options = Genre.detectable.map { "\($0.id)＝\($0.name)：\($0.blurb)" }.joined(separator: "\n")
        var c = cfg
        c.llmTemperature = 0
        let prompt = """
        請判斷下面這段語音逐字稿（標題：\(title)，全長 \(mmss(duration))）屬於哪一種內容類型。只能從下列代號選一個，只回覆代號，不要其他文字。
        \(options)

        判斷提示：有老師教學、講概念與例題＝lecture；兩人以上固定一問一答、主題是某個人＝interview；有議題、決議、待辦＝meeting；朋友家人同事閒聊＝chat；主持人帶一個主題長談＝podcast；單人演講或影片旁白＝talk。

        ---
        \(sample)
        """
        guard let reply = try? await LLMClient.chat(system: "你是內容分類器，只輸出類型代號。", user: prompt, cfg: c) else { return Genre.podcast }
        let r = reply.lowercased()
        // 取回覆裡最早出現的代號
        let hit = Genre.detectable.compactMap { g -> (Genre, String.Index)? in r.range(of: g.id).map { (g, $0.lowerBound) } }
            .min { $0.1 < $1.1 }
        return hit?.0 ?? Genre.podcast
    }

    /// 依整理好的重點取一個簡短標題（給本地檔案／語音備忘錄自動重新命名）；失敗回 nil，沿用原名
    static func makeTitle(original: String, body: String, cfg: PipelineConfig) async -> String? {
        var c = cfg
        c.llmTemperature = 0.2
        let prompt = """
        下面是一份錄音整理出來的重點（原本的檔名：\(original)）。請為它取一個簡短、具體、能一眼看出內容的標題：
        - 使用\(cfg.outputLanguage)，20 個字以內
        - 只輸出標題本身，不要引號、書名號、井字號、句號或任何說明
        - 不要放日期、檔案副檔名

        ---
        \(String(body.prefix(2500)))
        """
        guard let reply = try? await LLMClient.chat(system: "你是標題產生器，只輸出一行標題。", user: prompt, cfg: c) else { return nil }
        let firstLine = reply.split(whereSeparator: \.isNewline).map(String.init).first ?? ""
        let drop = CharacterSet(charactersIn: "#*\"'「」『』《》“”‘’`。 ").union(.whitespacesAndNewlines)
        let t = firstLine.trimmingCharacters(in: drop)
        return t.isEmpty ? nil : String(t.prefix(40))
    }

    static func systemPrompt(_ cfg: PipelineConfig, genre: Genre) -> String {
        """
        你是專業的內容整理編輯，擅長把語音逐字稿整理成結構清楚、忠於原文的 Markdown 筆記。
        規則：
        1. 輸出語言：\(cfg.outputLanguage)。
        2. 只根據提供的內容整理，不要編造逐字稿裡沒有的資訊；沒有的段落就省略。
        3. 逐字稿由語音辨識產生，可能有錯字或同音字，請依上下文合理修正人名、專有名詞，但不要改變原意。
        4. 直接輸出 Markdown 內容，不要有前言、結語或「以下是整理」之類的說明；不要使用 H1（#）標題。
        5. 保留重要的數字、人名、案例、定義。
        \(cfg.detail.instruction)
        內容類型：\(genre.name)。
        """
    }

    static func extraBlock(_ cfg: PipelineConfig, genre: Genre, custom: String) -> String {
        var s = ""
        if genre.id == "custom", !custom.isEmpty { s += "\n使用者自訂的整理要求（優先遵守）：\(custom)" }
        let extra = cfg.extraPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { s += "\n使用者額外要求（優先遵守）：\(extra)" }
        return s
    }

    /// 回傳最終 Markdown（不含 H1 與中繼資料）
    static func summarize(title: String, lines: [String], duration: Double, genre: Genre, custom: String,
                          cfg: PipelineConfig, progress: @escaping @Sendable (Double, String) -> Void) async throws -> String {
        let sys = systemPrompt(cfg, genre: genre)
        let extra = extraBlock(cfg, genre: genre, custom: custom)
        let stamp = cfg.timestamps && lines.contains { $0.hasPrefix("[") }
            ? "逐字稿每行開頭的 [mm:ss] 是時間標記；請在重要的重點後面以（mm:ss）標註出處時間。" : ""
        let parts = split(lines: lines, limit: cfg.chunkChars)
        let finalPrompt: (String, String) -> String = { material, kind in
            """
            以下是《\(title)》\(kind)。請整合成最終的「\(genre.name)」整理（全長 \(mmss(duration))）。\(stamp)
            請嚴格依下列 Markdown 結構輸出（可依內容增減小節，但保持順序與標題風格）：

            \(genre.template)
            \(extra)

            ---
            \(material)
            """
        }

        if parts.count <= 1 {
            progress(0.2, "整理重點中…")
            let out = try await LLMClient.chat(system: sys, user: finalPrompt(parts.first ?? "", "的逐字稿全文"), cfg: cfg)
            progress(1, "完成")
            return out
        }

        // 1) 分段抽取筆記
        var notes: [String] = []
        for (i, part) in parts.enumerated() {
            try await PauseGate.checkpoint()
            progress(Double(i) / Double(parts.count + 1), "分段筆記 \(i + 1)/\(parts.count)")
            let prompt = """
            這是《\(title)》逐字稿的第 \(i + 1)／\(parts.count) 段。請把這一段整理成詳細的筆記（Markdown 條列，不要結論式總結）。\(genre.mapFocus)。\(stamp)
            \(extra)

            ---
            \(part)
            """
            notes.append(try await LLMClient.chat(system: sys, user: prompt, cfg: cfg))
        }

        // 2) 筆記太長就分層合併，直到放得進一次呼叫
        let limit = Int(Double(cfg.chunkChars) * 1.6)
        var level = 0
        while notes.joined(separator: "\n\n").count > limit && notes.count > 1 && level < 4 {
            try Task.checkCancellation()
            level += 1
            var groups: [[String]] = [], cur: [String] = [], len = 0
            for n in notes {
                if len + n.count > limit && !cur.isEmpty { groups.append(cur); cur = []; len = 0 }
                cur.append(n); len += n.count
            }
            if !cur.isEmpty { groups.append(cur) }
            if groups.count == notes.count { break }          // 每則都已超長，無法再合併
            var merged: [String] = []
            for (gi, g) in groups.enumerated() {
                progress(Double(parts.count) / Double(parts.count + 1), "合併筆記 第\(level)層 \(gi + 1)/\(groups.count)")
                let prompt = "以下是《\(title)》多段筆記。請合併成一份較精簡的筆記：去除重複、保留所有重要的論點、案例、數字、定義與時間標記，維持 Markdown 條列。\n\n---\n" + g.joined(separator: "\n\n")
                merged.append(try await LLMClient.chat(system: sys, user: prompt, cfg: cfg))
            }
            notes = merged
        }

        // 3) 依類型格式輸出
        progress(Double(parts.count) / Double(parts.count + 1), "產生最終整理…")
        let out = try await LLMClient.chat(system: sys, user: finalPrompt(notes.joined(separator: "\n\n"), "各段落的筆記"), cfg: cfg)
        progress(1, "完成")
        return out
    }
}
