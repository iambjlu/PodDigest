// app/Jobs.swift
// 工作佇列：加入本地檔案／資料夾／YouTube 影片與播放清單，依序處理，狀態只放記憶體（結果檔寫到輸出資料夾）。
import AppKit
import Combine
import Foundation

/// 存到硬碟的待辦（不含 API Key 與結果；完成的項目輸出檔已經在輸出資料夾）
struct SavedJob: Codable {
    var title: String
    var remote: Bool
    var value: String               // 檔案路徑或連結
    var genreID: String
    var custom: String
    var folder: String?
    var extra: String
    var detail: String
    var formats: [String]
    var paths: [String]? = nil      // 合併多個檔案（或多部影片）時的完整清單
    var partTitles: [String]? = nil // 合併多部影片時各部的標題
}

enum QueueStore {
    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PodDigest/queue.json")
    }
    static func load() -> [SavedJob] {
        guard let d = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([SavedJob].self, from: d)) ?? []
    }
    static func save(_ jobs: [SavedJob]) {
        if jobs.isEmpty { try? FileManager.default.removeItem(at: file); return }     // 沒待辦就不留檔
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(jobs).write(to: file, options: .atomic)
    }
}

@MainActor
final class Job: ObservableObject, Identifiable {
    let id = UUID()
    let input: JobInput
    let cfg: PipelineConfig
    let box: OptionsBox
    @Published var options: BatchOptions { didSet { box.set(options) } }     // 做完前後都能改；流程在每個階段開始時才讀
    @Published var stage: Stage = .queued
    @Published var progress: Double = 0
    @Published var detail: String = ""
    @Published var error: String = ""
    @Published var versions: [PipelineOutput] = []        // 每「再做一份」就多一個版本（逐字稿共用）
    @Published var viewing = 0                            // 目前看第幾個版本
    @Published var liveLines: [String] = []               // 即時逐字稿
    var transcript: Transcript?                           // 分階段處理：轉好的逐字稿，等 LLM 階段用
    var regen = false                                     // 下一次是「沿用逐字稿再整理」
    @Published var jobLog: [String] = []                  // 這個項目自己的日誌
    @Published var startedAt: Date?
    @Published var finishedAt: Date?
    @Published var customTitle: String?                   // 自動命名產生的標題
    var title: String { customTitle ?? input.title }
    var output: PipelineOutput? { versions.indices.contains(viewing) ? versions[viewing] : versions.last }

    init(input: JobInput, cfg: PipelineConfig) {
        self.input = input
        self.cfg = cfg
        let o = BatchOptions(genre: input.genre, extra: cfg.extraPrompt, detail: cfg.detail, formats: cfg.formats)
        options = o
        box = OptionsBox(o)
    }

    var sourceIcon: String {
        switch input.source {
        case .remote: return "play.rectangle.fill"
        case .files, .remotes: return "rectangle.stack.fill"
        case .file: return "waveform"
        }
    }

    func note(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        if jobLog.last?.hasSuffix(line) == true { return }
        jobLog.append("\(stamp)  \(line)")
        if jobLog.count > 300 { jobLog.removeFirst(jobLog.count - 300) }
    }
}

@MainActor
final class JobQueue: ObservableObject {
    @Published var jobs: [Job] = [] { didSet { relink() } }
    private var bag: [AnyCancellable] = []
    /// 項目自己的進度變動也要通知觀察佇列的畫面（選單列圖示、選單內容、整體百分比）
    private func relink() {
        bag = jobs.map { j in j.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } }
    }
    @Published var logs: [String] = []
    @Published var message = ""          // 加入連結時的提示（展開中、錯誤）
    @Published var expanding = false
    @Published var selection: UUID?
    @Published var paused = false        // 全域暫停：不再開始新項目（進行中的做完）
    @Published var checked = Set<UUID>() // 清單左邊核取方塊勾選的項目（批量刪除用）
    @Published var lingering = false     // 做完後視窗已關、App 留在選單列待命

    var onFinished: ((_ done: Int, _ failed: Int) -> Void)?     // 佇列全部做完時（給選單列／通知用）
    private var runDone = 0, runFailed = 0
    private var saveWork: DispatchWorkItem?
    private var runner: Task<Void, Never>?
    private var current: (job: Job, task: Task<Void, Never>)?
    private let settings: SettingsStore

    init(settings: SettingsStore) { self.settings = settings }

    /// 整體進度（0…1）：未完成的項目加上已完成的，給選單列顯示
    var overallProgress: Double {
        let active = jobs.filter { [.queued, .awaiting, .done].contains($0.stage) || $0.stage.running }
        guard !active.isEmpty else { return 0 }
        return active.map { $0.stage == .done ? 1 : $0.progress }.reduce(0, +) / Double(active.count)
    }

    // MARK: 佇列保存（程式關掉再開會接續沒做完的）

    func persistSoon() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.persistNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func persistNow() {
        saveWork?.cancel(); saveWork = nil
        let saved: [SavedJob] = jobs.filter { $0.stage != .done && $0.stage != .cancelled }.map { j in
            var remote = false
            var value = ""
            var paths: [String]? = nil
            var partTitles: [String]? = nil
            switch j.input.source {
            case .file(let u): value = u.path
            case .files(let us): value = us.first?.path ?? ""; paths = us.map(\.path)
            case .remote(let l): remote = true; value = l
            case .remotes(let its): remote = true; value = its.first?.url ?? ""; paths = its.map(\.url); partTitles = its.map(\.title)
            }
            return SavedJob(title: j.input.title, remote: remote, value: value, genreID: j.options.genre.id, custom: j.input.custom,
                            folder: j.input.folder, extra: j.options.extra, detail: j.options.detail.rawValue,
                            formats: j.options.formats.map(\.rawValue), paths: paths, partTitles: partTitles)
        }
        QueueStore.save(saved)
    }

    /// 啟動時把上次沒做完的項目放回佇列並自動繼續（處理中斷的會從頭再做）
    func restore() {
        Pipeline.cleanStaleTemp()       // 此時還沒開始處理任何項目，暫存資料夾都是殘留的
        let saved = QueueStore.load()
        guard !saved.isEmpty else { return }
        for sj in saved {
            var cfg = settings.config(extraPrompt: sj.extra)
            cfg.detail = DetailLevel(rawValue: sj.detail) ?? cfg.detail
            cfg.formats = Set(sj.formats.compactMap(OutputFormat.init(rawValue:)))
            let src: JobSource = sj.remote
                ? (sj.paths.map { ps in .remotes(ps.enumerated().map { RemoteItem(id: "", title: sj.partTitles?[safe: $0.offset] ?? $0.element, url: $0.element, playlist: nil) }) } ?? .remote(sj.value))
                : (sj.paths.map { .files($0.map { URL(fileURLWithPath: $0) }) } ?? .file(URL(fileURLWithPath: sj.value)))
            jobs.append(Job(input: JobInput(title: sj.title, source: src, genre: Genre.find(sj.genreID), custom: sj.custom, folder: sj.folder), cfg: cfg))
        }
        log("接續上次未完成的 \(saved.count) 個項目")
        kick()
    }

    var isBusy: Bool { jobs.contains { $0.stage.running } }
    var pending: Int { jobs.filter { $0.stage.pending }.count }

    func log(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let l = "\(stamp)  \(line)"
        logs.append(l)
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }     // 記憶體環狀緩衝
        DiagnosticLog.write(line)
    }

    // MARK: 加入工作

    func options(extra: String) -> BatchOptions {
        BatchOptions(genre: settings.genre, extra: extra, detail: settings.detail, formats: settings.formats)
    }

    private func config(_ o: BatchOptions) -> PipelineConfig {
        var c = settings.config(extraPrompt: o.extra)
        c.detail = o.detail; c.formats = o.formats
        return c
    }

    /// 多段錄音合併成一份（順序＝傳入順序）
    func addMerged(_ urls: [URL], title: String, _ o: BatchOptions) {
        let files = MediaKinds.collect(urls)
        guard files.count > 1 else { addFiles(files, o); return }
        let input = JobInput(title: title, source: .files(files), genre: o.genre, custom: settings.customGenrePrompt, folder: nil)
        jobs.append(Job(input: input, cfg: config(o)))
        message = "已加入 1 個合併項目（\(files.count) 個檔案）"
        persistSoon()
        kick()
    }

    func addFiles(_ urls: [URL], _ o: BatchOptions, titles: [URL: String] = [:]) {
        let files = MediaKinds.collect(urls)
        guard !files.isEmpty else { message = "沒有找到可用的音訊或影片檔"; return }
        let cfg = config(o)
        let genre = o.genre
        for f in files {
            let input = JobInput(title: titles[f] ?? f.deletingPathExtension().lastPathComponent, source: .file(f), genre: genre,
                                 custom: settings.customGenrePrompt, folder: nil)
            jobs.append(Job(input: input, cfg: cfg))
        }
        message = "已加入 \(files.count) 個檔案"
        persistSoon()
        kick()
    }

    /// 多部影片接成一份（順序＝傳入順序）
    func addMergedRemote(_ items: [RemoteItem], title: String, _ o: BatchOptions) {
        let input = JobInput(title: title, source: .remotes(items), genre: o.genre, custom: settings.customGenrePrompt, folder: nil)
        jobs.append(Job(input: input, cfg: config(o)))
        message = "已加入 1 個合併項目（\(items.count) 部影片）"
        persistSoon()
        kick()
    }

    /// 文字框裡的連結（一行一個，影片或播放清單）
    static func parseLinks(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isNewline || $0 == " " || $0 == "," }).map(String.init).filter(YouTube.looksLikeURL)
    }

    /// 把連結展開成影片清單（每個連結一組；播放清單會有多筆）。失敗的連結回報在 errors
    func expandLinks(_ text: String) async -> (groups: [[RemoteItem]], errors: [String]) {
        var groups: [[RemoteItem]] = [], errors: [String] = []
        var seen = Set<String>()                            // 同一部影片貼了好幾次只留一個
        let cfg = settings.config(extraPrompt: "")
        var links: [String] = []
        for l in Self.parseLinks(text) where !links.contains(l) { links.append(l) }
        // 每次同時解析最多 4 個連結（逐個等很久），結果依原本順序排列
        for start in stride(from: 0, to: links.count, by: 4) {
            let batch = Array(links[start..<min(start + 4, links.count)])
            let results = await withTaskGroup(of: (Int, Result<[RemoteItem], Error>).self) { g -> [(Int, Result<[RemoteItem], Error>)] in
                for (i, l) in batch.enumerated() {
                    g.addTask {
                        do { return (i, .success(try await YouTube.expand(l, cfg: cfg))) }
                        catch { return (i, .failure(error)) }
                    }
                }
                var out: [(Int, Result<[RemoteItem], Error>)] = []
                for await r in g { out.append(r) }
                return out.sorted { $0.0 < $1.0 }
            }
            for (i, r) in results {
                switch r {
                case .success(let items):
                    let fresh = items.filter { seen.insert($0.url).inserted }
                    if !fresh.isEmpty { groups.append(fresh) }
                    log("連結展開：\(batch[i]) → \(items.count) 部")
                case .failure(let error):
                    errors.append(error.localizedDescription)
                    log("連結失敗：\(batch[i])：\(error.localizedDescription)")
                }
            }
        }
        return (groups, errors)
    }

    /// 加入已經展開好的影片（預覽確認後呼叫，不用再解析一次）
    func addRemote(_ groups: [[RemoteItem]], _ o: BatchOptions) {
        let cfg = config(o)
        let custom = settings.customGenrePrompt
        var added = 0
        for items in groups {
            for it in items {
                let input = JobInput(title: it.title, source: .remote(it.url), genre: o.genre, custom: custom,
                                     folder: items.count > 1 ? it.playlist : nil)
                jobs.append(Job(input: input, cfg: cfg))
                added += 1
            }
        }
        guard added > 0 else { return }
        message = "已加入 \(added) 部影片"
        persistSoon()
        kick()
    }

    /// 不經預覽直接加入：先解析連結再加入
    func addLinks(_ text: String, _ o: BatchOptions) {
        guard !Self.parseLinks(text).isEmpty else { message = "請貼上以 http(s):// 開頭的連結（一行一個）"; return }
        expanding = true
        message = "解析連結中…"
        Task {
            let r = await expandLinks(text)
            expanding = false
            if let e = r.errors.last { message = e }
            addRemote(r.groups, o)
        }
    }

    // MARK: 執行

    private func kick() {
        guard runner == nil else { return }
        runDone = 0; runFailed = 0
        runner = Task { [weak self] in
            // 先把排隊的處理完（分階段模式＝只轉文字），再回頭做「等待整理」的
            while let self {
                if self.paused { break }
                if let job = self.jobs.first(where: { $0.stage == .queued }) {
                    await self.process(job, phase: self.settings.batchMode == .sttFirst && !(job.regen && !job.versions.isEmpty) ? .transcribeOnly : .full)
                } else if let job = self.jobs.first(where: { $0.stage == .awaiting }) {
                    await self.process(job, phase: .finishOnly)
                } else { break }
            }
            guard let self else { return }
            self.runner = nil
            self.persistNow()
            if self.paused { return }       // 暫停不算做完，不觸發完成通知／自動結束
            self.onFinished?(self.runDone, self.runFailed)
        }
    }

    enum Phase { case full, transcribeOnly, finishOnly }

    private func process(_ job: Job, phase: Phase) async {
        let finishOnly = phase == .finishOnly
        job.stage = finishOnly ? .summarizing : .preparing
        job.progress = finishOnly ? 0.55 : 0
        job.error = ""
        if job.startedAt == nil || !finishOnly { job.startedAt = Date() }
        job.finishedAt = nil
        let regen = phase != .finishOnly && job.regen && !job.versions.isEmpty
        job.regen = false
        if !regen && !finishOnly { job.liveLines = [] }
        job.note(finishOnly ? "全部轉完了，開始整理重點" : regen ? "沿用逐字稿，用新設定再整理一份" : phase == .transcribeOnly ? "開始轉文字（整理等全部轉完再做）" : "開始處理")
        log("\(finishOnly ? "整理" : regen ? "再做一份" : "開始")：\(job.title)")
        let report: Report = { [weak job] stage, p, msg in
            Task { @MainActor in
                guard let job, job.stage.running || stage == .done else { return }
                job.stage = stage; job.progress = p; job.detail = msg
                if !msg.contains("%") { job.note("\(stage.label)：\(msg)") }
            }
        }
        let t = Task { [weak self] in
            do {
                let out: PipelineOutput
                if regen, let prior = job.versions.last {
                    out = try await Pipeline.regenerate(job.input, prior: prior, cfg: job.cfg, box: job.box, report: report)
                } else if finishOnly, let tr = job.transcript {
                    out = try await Pipeline.finish(job.input, cfg: job.cfg, box: job.box, lines: tr.lines, duration: tr.duration,
                                                    sourceLabel: tr.sourceLabel, base: 0.55, report: report)
                } else {
                    let log: @Sendable (String) -> Void = { line in Task { @MainActor in self?.log(line); job.note(line) } }
                    let onLines: @Sendable ([String]) -> Void = { new in
                        Task { @MainActor in
                            job.liveLines += new
                            if job.liveLines.count > 400 { job.liveLines.removeFirst(job.liveLines.count - 400) }
                        }
                    }
                    if phase == .transcribeOnly {
                        let tr = try await Pipeline.transcribe(job.input, cfg: job.cfg, box: job.box, report: report, log: log, onLines: onLines)
                        job.transcript = tr
                        job.stage = .awaiting; job.progress = 0.55
                        job.detail = "逐字稿完成（\(tr.lines.count) 段），等全部轉完再整理"
                        job.note("逐字稿完成，等待整理")
                        self?.log("逐字稿完成：\(job.title)（等全部轉完再整理）")
                        return
                    }
                    out = try await Pipeline.run(job.input, cfg: job.cfg, box: job.box, report: report, log: log, onLines: onLines)
                }
                job.transcript = nil
                if out.doc.title != job.input.title { job.customTitle = out.doc.title }
                job.versions.append(out)
                job.viewing = job.versions.count - 1
                job.stage = .done
                job.progress = 1
                job.finishedAt = Date()
                job.detail = "已輸出 \(out.files.count) 個檔案"
                job.note("完成：\(out.files.map(\.lastPathComponent).joined(separator: "、"))")
                self?.runDone += 1
                if let q = self, q.settings.notifyOnFinish {
                    Notifier.shared.post(title: "整理完成：\(job.title)", body: out.files.isEmpty ? "已顯示在視窗內" : "已輸出 \(out.files.map(\.pathExtension).joined(separator: "、").uppercased())，點一下在 Finder 顯示", files: out.files)
                }
                self?.log("完成：\(job.title) → \(out.files.map(\.lastPathComponent).joined(separator: "、"))")
                if self?.selection == nil { self?.selection = job.id }
            } catch is CancellationError {
                job.stage = .cancelled; job.detail = ""; job.finishedAt = Date(); job.transcript = nil
                job.note("已取消")
                self?.log("已取消：\(job.title)")
            } catch {
                job.stage = .failed; job.error = error.localizedDescription; job.finishedAt = Date()
                job.note("失敗：\(error.localizedDescription)")
                self?.runFailed += 1
                if let q = self, q.settings.notifyOnFinish {
                    Notifier.shared.post(title: "處理失敗：\(job.title)", body: error.localizedDescription)
                }
                self?.log("失敗：\(job.title)：\(error.localizedDescription)")
            }
        }
        current = (job, t)
        persistSoon()
        await t.value
        current = nil
        persistSoon()
    }

    /// 逐字稿不對：丟掉舊逐字稿，從頭重新轉文字再整理（結果加成新版本）
    func retranscribe(_ job: Job) {
        guard !job.stage.running, !job.stage.pending else { return }
        job.regen = false
        job.stage = .queued; job.progress = 0; job.error = ""; job.detail = "等待重新轉文字"
        persistSoon()
        kick()
    }

    /// 做完的項目：用目前（可能已改過的）設定再整理一份，沿用逐字稿不用重新轉文字
    func rerun(_ job: Job) {
        guard !job.stage.running, !job.stage.pending, !job.versions.isEmpty else { return }
        job.regen = true
        job.stage = .queued; job.progress = 0; job.error = ""; job.detail = "等待再整理一份"
        kick()
    }

    func pause() { paused = true; log("已暫停：進行中的項目做完後不再開始新的") }
    func resume() { paused = false; log("繼續處理"); kick() }

    /// 批量刪除勾選的項目（處理中的先取消）
    func removeChecked() {
        let ids = checked
        for j in jobs where ids.contains(j.id) { cancel(j) }
        jobs.removeAll { ids.contains($0.id) }
        if let s = selection, ids.contains(s) { selection = nil }
        checked = []
        persistSoon()
    }

    func cancel(_ job: Job) {
        if current?.job === job { current?.task.cancel() }
        else if job.stage.pending { job.stage = .cancelled }
    }

    func retry(_ job: Job) {
        guard !job.stage.running else { return }
        job.regen = !job.versions.isEmpty
        job.stage = .queued; job.progress = 0; job.error = ""; job.detail = ""
        persistSoon()
        kick()
    }

    /// 排在這個項目前面、還沒做完的個數
    func ahead(of job: Job) -> Int {
        guard let idx = jobs.firstIndex(where: { $0 === job }) else { return 0 }
        return jobs[..<idx].filter { $0.stage.running || $0.stage.pending }.count
    }

    var retryable: Int { jobs.filter { $0.stage == .failed || $0.stage == .cancelled }.count }

    func retryAll() {
        for j in jobs where j.stage == .failed || j.stage == .cancelled {
            j.regen = !j.versions.isEmpty
            j.stage = j.transcript != nil ? .awaiting : .queued
            j.progress = j.transcript != nil ? 0.55 : 0; j.error = ""; j.detail = ""
        }
        persistSoon()
        kick()
    }

    func remove(_ job: Job) {
        cancel(job)
        jobs.removeAll { $0 === job }
        checked.remove(job.id)
        if selection == job.id { selection = nil }
        persistSoon()
    }

    func clearFinished() {
        jobs.removeAll { [.done, .cancelled, .failed].contains($0.stage) }
        checked.formIntersection(jobs.map(\.id))
        if let s = selection, !jobs.contains(where: { $0.id == s }) { selection = nil }
        persistSoon()
    }

    func cancelAll() {
        for j in jobs where j.stage.pending { j.stage = .cancelled }
        current?.task.cancel()
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
