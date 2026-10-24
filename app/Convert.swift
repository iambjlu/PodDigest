// app/Convert.swift
// 把已經整理好的 Markdown 檔轉成 HTML／PDF／TXT：各自一份，或合併成一本含目錄的單檔 HTML。
import Foundation

struct MDItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let title: String
    let meta: [(String, String)]     // PodDigest 自己輸出的 .md 開頭那串「- **類型**：…」會被解析成資訊列
    let body: String                 // 去掉標題與資訊列後的內容

    static func == (a: MDItem, b: MDItem) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum Converter {
    static func load(_ url: URL) throws -> MDItem {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw AppError("無法讀取 \(url.lastPathComponent)（需要 UTF-8 文字檔）") }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var title = url.deletingPathExtension().lastPathComponent
        // 開頭（前幾個非空行內）的第一個 # 標題當作標題
        if let i = lines.prefix(6).firstIndex(where: { $0.hasPrefix("# ") }) {
            title = String(lines[i].dropFirst(2)).trimmingCharacters(in: .whitespaces)
            lines.remove(at: i)
        }
        // PodDigest 輸出的資訊列：- **類型**：Podcast …，後面接 ---
        var meta: [(String, String)] = []
        var j = 0
        while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
        let start = j
        while j < lines.count, let r = lines[j].range(of: #"^- \*\*(.+?)\*\*：(.*)$"#, options: .regularExpression) {
            let l = String(lines[j][r])
            if let k = l.range(of: "**：") { meta.append((String(l.dropFirst(4)[..<l.index(k.lowerBound, offsetBy: 0)]).replacingOccurrences(of: "*", with: ""), String(l[k.upperBound...]))) }
            j += 1
        }
        if meta.count >= 2 {
            while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
            if j < lines.count, lines[j].trimmingCharacters(in: .whitespaces) == "---" { j += 1 }
            lines.removeSubrange(start..<j)
        } else { meta = [] }
        return MDItem(url: url, title: title, meta: meta, body: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func stamp() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"; return df.string(from: Date())
    }

    /// 每個檔案各自轉成一份（各一個子資料夾）
    @MainActor
    static func convertEach(_ items: [MDItem], formats: Set<OutputFormat>, outDir: URL, progress: (Int, String) -> Void) async throws -> [URL] {
        var out: [URL] = []
        for (i, it) in items.enumerated() {
            progress(i, it.title)
            var meta = it.meta
            if meta.isEmpty { meta = [("來源", it.url.lastPathComponent)] }
            meta.append(("轉檔時間", stamp()))
            let doc = DigestDoc(title: it.title, meta: meta, body: it.body, transcript: [], includeTranscript: false)
            out += try await Exporter.write(doc, formats: formats, dir: outDir.appendingPathComponent(Exporter.safeName(it.title)))
        }
        return out
    }

    /// 合併成一本：每個檔案一個章節（# 標題）；toc＝true 時 HTML 有目錄抽屜與搜尋、PDF 另有目錄頁
    @MainActor
    static func convertBook(_ items: [MDItem], title: String, formats: Set<OutputFormat>, outDir: URL, toc: Bool = true) async throws -> [URL] {
        var md = ""
        for it in items {
            md += "# \(it.title)\n\n"
            if !it.meta.isEmpty { md += "> " + it.meta.map { "\($0.0)：\($0.1)" }.joined(separator: "　｜　") + "\n\n" }
            md += it.body + "\n\n"
        }
        let doc = DigestDoc(title: title, meta: [("章節", "\(items.count)"), ("轉檔時間", stamp())], body: md, transcript: [], includeTranscript: false)
        return try await Exporter.write(doc, formats: formats, dir: outDir.appendingPathComponent(Exporter.safeName(title)), toc: toc)
    }
}
