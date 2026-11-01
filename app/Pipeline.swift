// app/Pipeline.swift
// 一個項目的完整流程：取得音訊 → 切段 → 外部語音模型轉文字 → 外部 LLM 整理 → 輸出檔案。UI 無關，可單獨測試。
import Foundation

enum JobSource {
    case file(URL)
    case files([URL])          // 多段錄音依序接成一份
    case remote(String)

    var isLocal: Bool { if case .remote = self { return false } else { return true } }
}

enum Stage: String {
    case queued, awaiting, downloading, preparing, transcribing, summarizing, exporting, done, failed, cancelled
    var label: String {
        switch self {
        case .queued: return "排隊中"
        case .awaiting: return "等待整理"
        case .downloading: return "下載中"
        case .preparing: return "處理音訊"
        case .transcribing: return "語音轉文字"
        case .summarizing: return "整理重點"
        case .exporting: return "輸出檔案"
        case .done: return "完成"
        case .failed: return "失敗"
        case .cancelled: return "已取消"
        }
    }
    var pending: Bool { self == .queued || self == .awaiting }
    var running: Bool { [.downloading, .preparing, .transcribing, .summarizing, .exporting].contains(self) }
}

struct JobInput {
    let title: String
    let source: JobSource
    let genre: Genre
    let custom: String          // 自訂類型的整理要求
    let folder: String?         // 播放清單名稱 → 輸出子資料夾
}

struct PipelineOutput {
    var transcript: [String]
    var body: String
    var duration: Double
    var files: [URL]
    var doc: DigestDoc
}

typealias Report = @Sendable (Stage, Double, String) -> Void

/// 一次加入的設定（內容類型、詳細程度、輸出格式、額外要求）
struct BatchOptions {
    var genre: Genre
    var extra: String
    var detail: DetailLevel
    var formats: Set<OutputFormat>
}

/// 處理途中可以改的設定：流程在每個階段開始時才讀，所以還沒走到的階段會吃到新設定
final class OptionsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: BatchOptions
    init(_ v: BatchOptions) { self.v = v }
    func get() -> BatchOptions { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ n: BatchOptions) { lock.lock(); v = n; lock.unlock() }
}

/// 轉文字階段的產物（分階段處理時，先存著等 LLM 階段用）
struct Transcript {
    var lines: [String]
    var duration: Double
    var sourceLabel: String
}

enum Pipeline {
    /// 完整流程：轉文字 → 整理 → 輸出
    static func run(_ input: JobInput, cfg: PipelineConfig, box: OptionsBox? = nil, report: @escaping Report,
                    log: @escaping @Sendable (String) -> Void,
                    onLines: @escaping @Sendable ([String]) -> Void = { _ in }) async throws -> PipelineOutput {
        let box = box ?? OptionsBox(BatchOptions(genre: input.genre, extra: cfg.extraPrompt, detail: cfg.detail, formats: cfg.formats))
        let t = try await transcribe(input, cfg: cfg, box: box, report: report, log: log, onLines: onLines)
        return try await finish(input, cfg: cfg, box: box, lines: t.lines, duration: t.duration, sourceLabel: t.sourceLabel,
                                base: 0.55, report: report)
    }

    /// 只做到逐字稿（取得音訊 → 切段 → 語音轉文字）
    static func transcribe(_ input: JobInput, cfg: PipelineConfig, box: OptionsBox, report: @escaping Report,
                           log: @escaping @Sendable (String) -> Void,
                           onLines: @escaping @Sendable ([String]) -> Void = { _ in }) async throws -> Transcript {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PodDigest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }       // 暫存音訊用完即刪

        // 1) 取得音訊（一個或多個檔案；多個檔案依順序接成一份）
        var audios: [URL]
        var sourceLabel: String
        switch input.source {
        case .file(let u):
            audios = [u]; sourceLabel = u.lastPathComponent
        case .files(let us):
            audios = us; sourceLabel = "合併 \(us.count) 個檔案：" + us.map(\.lastPathComponent).joined(separator: " ＋ ")
        case .remote(let link):
            report(.downloading, 0, "下載音訊…")
            log("下載 \(link)")
            var dl = try await YouTube.download(link, to: tmp, cfg: cfg) { report(.downloading, $0 * 0.08, "下載音訊 \(Int($0 * 100))%") }
            if cfg.keepAudio {      // 勾了「保留下載的音訊」：直接放進輸出資料夾，不另外複製一份
                let dir = outputDir(input, cfg)
                let dst = dir.appendingPathComponent(Exporter.safeName(input.title) + "." + dl.pathExtension)
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: dst)
                    try FileManager.default.moveItem(at: dl, to: dst)
                    dl = dst
                    log("已保留音訊：\(dst.lastPathComponent)")
                } catch { log("保留音訊失敗：\(error.localizedDescription)") }
            }
            audios = [dl]
            sourceLabel = link
        }

        // 2) 切段（多個檔案的時間軸接在一起）
        var allChunks: [AudioChunk] = []
        var starts: [Double: String] = [:]          // 每個檔案的起點 → 檔名，用來在逐字稿插入分隔
        var duration = 0.0
        for (i, a) in audios.enumerated() {
            try Task.checkCancellation()
            let sub = tmp.appendingPathComponent("part\(i)")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let label = audios.count > 1 ? "切割音訊 \(i + 1)/\(audios.count)" : "切割音訊"
            report(.preparing, 0.08 + 0.04 * Double(i) / Double(audios.count), label + "…")
            let prepared = try await AudioPrep.chunks(of: a, minutes: cfg.audioChunkMinutes, tmp: sub) { f in
                report(.preparing, 0.08 + 0.04 * (Double(i) + f) / Double(audios.count), label)
            }
            if audios.count > 1 { starts[duration] = a.lastPathComponent }
            allChunks += prepared.chunks.map { AudioChunk(url: $0.url, offset: $0.offset + duration) }
            duration += prepared.duration
        }
        log("音訊長度 \(Summarizer.mmss(duration))，共 \(allChunks.count) 段" + (audios.count > 1 ? "（\(audios.count) 個檔案合併）" : ""))

        // 3) 轉文字
        var lines: [String] = []
        var prevTail = ""
        let n = allChunks.count
        for (i, ch) in allChunks.enumerated() {
            if let name = starts[ch.offset] {
                let mark = "【第 \(starts.keys.filter { $0 <= ch.offset }.count)／\(audios.count) 段：\(name)】"
                lines.append(mark); onLines([mark])
            }
            try Task.checkCancellation()
            report(.transcribing, 0.12 + 0.43 * Double(i) / Double(n), "語音轉文字 \(i + 1)/\(n)")
            let hint = cfg.sttUsePrompt ? box.get().genre.sttHint + (prevTail.isEmpty ? "" : prevTail) : ""
            let r = try await STTClient.transcribe(file: ch.url, cfg: cfg, prompt: hint)
            try? FileManager.default.removeItem(at: ch.url)
            let new: [String]
            if r.segments.isEmpty {
                new = paragraphs(r.text, at: ch.offset)
            } else {
                new = Summarizer.timestampedLines(r.segments.map {
                    Segment(start: $0.start + ch.offset, end: $0.end + ch.offset, text: $0.text) })
            }
            lines += new
            onLines(new)
            prevTail = String(r.text.suffix(60))
        }
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw AppError("沒有辨識到任何語音內容")
        }
        let chars = lines.map(stripStamp).joined().filter { !$0.isWhitespace }.count
        log("逐字稿 \(chars) 字")
        if chars < 20 {
            throw AppError("只辨識到 \(chars) 個字，內容太少沒辦法整理。可能是錄音太安靜、沒有人聲，或語言設定不對（設定頁「語音轉文字」的語言代碼）。")
        }
        return Transcript(lines: lines, duration: duration, sourceLabel: sourceLabel)
    }

    /// 沿用已經轉好的逐字稿，用目前的設定再整理一份（不用重新轉文字）
    static func regenerate(_ input: JobInput, prior: PipelineOutput, cfg: PipelineConfig, box: OptionsBox,
                           report: @escaping Report) async throws -> PipelineOutput {
        let src = prior.doc.meta.first { $0.0 == "來源" }?.1 ?? ""
        return try await finish(input, cfg: cfg, box: box, lines: prior.transcript, duration: prior.duration,
                                sourceLabel: src, base: 0, report: report, title: prior.doc.title)
    }

    static func finish(_ input: JobInput, cfg: PipelineConfig, box: OptionsBox, lines: [String], duration: Double,
                               sourceLabel: String, base: Double, report: @escaping Report,
                               title: String? = nil) async throws -> PipelineOutput {
        // 4) 整理重點（這時才讀目前的類型／詳細程度／額外要求）
        var o = box.get()
        var c = cfg
        c.detail = o.detail; c.extraPrompt = o.extra
        var autoNote = ""
        if o.genre.id == "auto" {
            report(.summarizing, base + (0.95 - base) * 0.02, "自動偵測內容類型…")
            o.genre = await Summarizer.detect(title: input.title, lines: lines, duration: duration, cfg: c)
            autoNote = "（自動偵測）"
        }
        let llmLines = c.timestamps ? lines : lines.map(stripStamp)
        let body = try await Summarizer.summarize(title: input.title, lines: llmLines, duration: duration, genre: o.genre,
                                                  custom: input.custom, cfg: c) { f, msg in
            report(.summarizing, base + (0.95 - base) * f, msg)
        }

        // 標題：沿用指定的（再做一份時沿用上一版）；本地檔案／語音備忘錄開了「自動命名」就請 LLM 依內容取一個
        var docTitle = title ?? input.title
        if title == nil, cfg.autoTitle, input.source.isLocal {
            report(.summarizing, 0.94, "產生標題…")
            if let t = await Summarizer.makeTitle(original: input.title, body: body, cfg: c) { docTitle = t }
        }

        // 5) 輸出（這時才讀輸出格式）
        report(.exporting, 0.95, "輸出檔案…")
        let o2 = box.get()
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        let doc = DigestDoc(
            title: docTitle,
            meta: [("類型", o.genre.name + autoNote), ("長度", Summarizer.mmss(duration)),
                   ("來源", sourceLabel), ("整理時間", df.string(from: Date())),
                   ("語音模型", cfg.sttModel), ("LLM", cfg.llmModel.isEmpty ? "（伺服器預設）" : cfg.llmModel)],
            body: body, transcript: lines, includeTranscript: cfg.includeTranscript)
        let dir = outputDir(input, cfg, title: docTitle)
        let files = try await Exporter.write(doc, formats: o2.formats, dir: dir)
        report(.done, 1, "完成")
        return PipelineOutput(transcript: lines, body: body, duration: duration, files: files, doc: doc)
    }

    /// 啟動時清掉上次被強制結束而殘留的暫存資料夾（正常結束時 transcribe 的 defer 已刪）
    static func cleanStaleTemp() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        for u in items where u.lastPathComponent.hasPrefix("PodDigest-") { try? fm.removeItem(at: u) }
    }

    /// 輸出資料夾：[播放清單/]標題（每個音檔一個子資料夾，檔案不會散在一起）
    static func outputDir(_ input: JobInput, _ cfg: PipelineConfig, title: String? = nil) -> URL {
        var dir = URL(fileURLWithPath: (cfg.outputDir as NSString).expandingTildeInPath)
        if let f = input.folder, !f.isEmpty { dir.appendPathComponent(Exporter.safeName(f)) }
        return dir.appendingPathComponent(Exporter.safeName(title ?? input.title))
    }

    static func stripStamp(_ s: String) -> String {
        guard s.hasPrefix("["), let r = s.range(of: "] ") else { return s }
        return String(s[r.upperBound...])
    }

    /// 伺服器沒給分句時間時：依句號切成約 300 字一段，只在每段 chunk 開頭放時間標記
    static func paragraphs(_ text: String, at offset: Double) -> [String] {
        var out: [String] = [], cur = ""
        for ch in text {
            cur.append(ch)
            if cur.count >= 300, "。！？!?.".contains(ch) { out.append(cur); cur = "" }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur) }
        return out.enumerated().map { $0.offset == 0 ? "[\(Summarizer.mmss(offset))] \($0.element)" : $0.element }
    }
}
