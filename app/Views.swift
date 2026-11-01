// app/Views.swift
// 主視窗：工作台（加入來源、類型、佇列、結果預覽）／設定／日誌。風格沿用 InboxRelay。
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.16), in: Capsule())
    }
}

extension Stage {
    var color: Color {
        switch self {
        case .queued: return .gray
        case .awaiting: return .indigo
        case .downloading, .preparing: return .blue
        case .transcribing: return .teal
        case .summarizing: return .purple
        case .exporting: return .indigo
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}

struct MainWindow: View {
    @ObservedObject var queue: JobQueue
    @ObservedObject var settings: SettingsStore

    var body: some View {
        TabView {
            WorkbenchView(queue: queue, settings: settings)
                .tabItem { Label("工作台", systemImage: "square.and.arrow.down.on.square") }
            SettingsView(queue: queue, settings: settings)
                .tabItem { Label("設定", systemImage: "gearshape") }
            LogView(queue: queue)
                .tabItem { Label("日誌", systemImage: "text.alignleft") }
        }
        .padding()
    }
}

// MARK: - 工作台

struct WorkbenchView: View {
    @ObservedObject var queue: JobQueue
    @ObservedObject var settings: SettingsStore
    @State private var links = ""
    @State private var linksExpanded = false
    @State private var extra = ""
    @State private var targeted = false
    @State private var pending: AddRequest?
    @State private var showMemos = false
    @State private var showConvert = false
    @State private var mergeOn = false
    @State private var pendingMerge: MergeDraft?
    @State private var remoteMergeMap: [String: RemoteItem] = [:]     // 合併影片視窗用：網址 → 影片

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            inputCard
            HStack(spacing: 0) {       // 固定寬度、分隔線不能拖動
                jobList.frame(width: 340)
                Divider().padding(.horizontal, 8)
                if let job = queue.jobs.first(where: { $0.id == queue.selection }) {
                    JobDetail(job: job, queue: queue).frame(minWidth: 380)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 34)).foregroundStyle(.tertiary)
                        Text("選一個項目查看重點").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let item = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                       let data = item as? Data, let u = URL(dataRepresentation: data, relativeTo: nil) { urls.append(u) }
                }
                request(.files(urls, [:]))
            }
            return true
        }
        .sheet(item: $pending) { req in
            AskSheet(request: req, settings: settings, queue: queue, extra: extra) { opts, groups in
                perform(req, opts, groups)
            }
        }
        .sheet(item: $pendingMerge) { d in
            MergeSheet(draft: d) { urls, title in
                if d.isRemote {
                    let items = urls.compactMap { remoteMergeMap[$0.absoluteString] }
                    DispatchQueue.main.async { request(.mergedRemote(items, title)) }
                } else {
                    DispatchQueue.main.async { request(.merged(urls, title)) }
                }
            }
        }
        .sheet(isPresented: $showConvert) { ConvertSheet(settings: settings) }
        .sheet(isPresented: $showMemos) {
            VoiceMemosSheet { urls, titles in request(.files(urls, titles)) }
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Color.accentColor.opacity(0.08)).allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.badge.checkmark")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(LinearGradient(colors: [.indigo, .purple], startPoint: .bottom, endPoint: .top),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("PodDigest").font(.headline)
                Text("音訊／YouTube → 重點整理（Markdown、HTML、PDF）").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if queue.isBusy {
                StatusPill(text: "處理中 · 還有 \(queue.pending) 個排隊", color: .purple)
            } else if queue.pending > 0 {
                StatusPill(text: "排隊 \(queue.pending)", color: .gray)
            } else {
                StatusPill(text: "待命", color: .green)
            }
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("內容類型").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Genre.all) { g in
                        let on = settings.genreID == g.id
                        Button { settings.genreID = g.id } label: {
                            Label(g.name, systemImage: g.icon).font(.callout)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
                                .overlay(Capsule().strokeBorder(on ? Color.accentColor : .clear))
                                .foregroundStyle(on ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text(settings.genre.blurb).font(.caption).foregroundStyle(.secondary)
            if settings.genreID == "custom" {
                TextField("自訂整理要求（例如：用表格列出每個人的發言重點）", text: $settings.customGenrePrompt)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Picker("詳細程度", selection: $settings.detail) {
                    ForEach(DetailLevel.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 220)
                TextField("額外要求（選填，套用到這次加入的項目）", text: $extra).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 6) {
                Text("輸出").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(OutputFormat.allCases) { f in
                    let on = settings.formats.contains(f)
                    Button { if on { settings.formats.remove(f) } else { settings.formats.insert(f) } } label: {
                        Text(f.shortLabel).font(.caption.weight(.medium))
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? Color.accentColor : .clear))
                            .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Divider().frame(height: 14)
                Toggle("重點後附逐字稿", isOn: $settings.includeTranscript).toggleStyle(.checkbox).font(.caption)
                Toggle("自動命名標題", isOn: $settings.autoTitle).toggleStyle(.checkbox).font(.caption)
                    .help("整理完後請 LLM 依內容取標題，輸出資料夾與檔名用「新標題（原標題）」；檔案、語音備忘錄、YouTube（含合併）都適用")
                Toggle("保留下載的音訊", isOn: $settings.keepAudio).toggleStyle(.checkbox).font(.caption)
                    .help("YouTube 連結下載的音訊，處理完後保留在輸出資料夾（與整理結果同一個子資料夾）；不勾選就用完即刪")
                Toggle("每次都詢問", isOn: $settings.askEachTime).toggleStyle(.checkbox).font(.caption)
                    .help("每次加入檔案或連結前，先跳出視窗確認內容類型、詳細程度與輸出格式")
                if settings.formats.isEmpty { Text("未勾選＝只在視窗顯示").font(.caption).foregroundStyle(.orange) }
            }
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary).font(.caption)
                Text((settings.outputDir as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(settings.outputDir).textSelection(.enabled)
                Button("變更…") { chooseOutputFolder() }.buttonStyle(.borderless).font(.caption)
                Button("在 Finder 顯示") {
                    let u = URL(fileURLWithPath: (settings.outputDir as NSString).expandingTildeInPath)
                    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(u)
                }
                .buttonStyle(.borderless).font(.caption)
                Spacer()
            }
            Divider()
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button { chooseFiles() } label: { Label("加入音訊／影片檔…", systemImage: "folder.badge.plus") }
                        Button { showMemos = true } label: { Label("語音備忘錄…", systemImage: "waveform.badge.mic") }
                        Button { showConvert = true } label: { Label("轉換 Markdown…", systemImage: "doc.richtext") }
                            .help("把整理好的 .md 轉成 HTML／PDF／TXT，或合併成一本含目錄的單檔 HTML")
                    }
                    Toggle("多個檔案合併成一份（錄音被切成多段）", isOn: $mergeOn).toggleStyle(.checkbox).font(.caption)
                    Text("也可以把檔案或資料夾直接拖進視窗").font(.caption).foregroundStyle(.secondary)
                }
                Divider().frame(height: 52)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        if linksExpanded {
                            // 展開：大輸入框，Return 換行（一行一個連結），按「加入」送出
                            TextEditor(text: $links)
                                .font(.body).scrollContentBackground(.hidden)
                                .padding(4).frame(height: 150)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                                .overlay(alignment: .topLeading) {
                                    if links.isEmpty {
                                        Text("貼上 YouTube 影片或播放清單連結（一行一個）").foregroundStyle(.tertiary)
                                            .padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                                    }
                                }
                        } else {
                            TextField("貼上 YouTube 影片或播放清單連結（多個用空白或換行分開）", text: $links, axis: .vertical)
                                .lineLimit(1...3).textFieldStyle(.roundedBorder)
                                .onSubmit { addLinks() }
                        }
                        Button { linksExpanded.toggle() } label: {
                            Image(systemName: linksExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.borderless).help(linksExpanded ? "收合輸入框" : "展開輸入框（貼上很多連結時比較好看）")
                        Button { addLinks() } label: { Label("加入", systemImage: "plus.circle.fill") }
                            .disabled(links.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || queue.expanding)
                    }
                    if queue.expanding { ProgressView().controlSize(.small) }
                    else if !queue.message.isEmpty { Text(queue.message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var jobList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("佇列（\(queue.jobs.count)）").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Menu {
                    Picker("處理方式", selection: $settings.batchMode) {
                        ForEach(BatchMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Text(settings.batchMode.detail)
                } label: {
                    Label(settings.batchMode.label, systemImage: settings.batchMode == .perItem ? "arrow.right.circle" : "square.stack.3d.down.right")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("多個音檔時的處理方式：\n" + settings.batchMode.detail)
                Spacer()
                if !queue.checked.isEmpty {
                    Button("刪除選取（\(queue.checked.count)）", role: .destructive) { queue.removeChecked() }
                        .buttonStyle(.borderless).font(.caption)
                }
                Button(queue.checked.count == queue.jobs.count && !queue.jobs.isEmpty ? "取消全選" : "全選") {
                    queue.checked = queue.checked.count == queue.jobs.count ? [] : Set(queue.jobs.map(\.id))
                }
                .buttonStyle(.borderless).font(.caption).disabled(queue.jobs.isEmpty)
                if queue.isBusy || queue.pending > 0 || queue.paused {
                    Button { queue.paused ? queue.resume() : queue.pause() } label: {
                        Label(queue.paused ? "繼續" : "暫停", systemImage: queue.paused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.borderless).font(.caption)
                    .help(queue.paused ? "繼續處理排隊中的項目" : "暫停：進行中的項目做完後，不再開始新的項目")
                }
                if queue.isBusy || queue.pending > 0 {
                    Button("全部停止") { queue.cancelAll() }.buttonStyle(.borderless).font(.caption)
                }
                if queue.retryable > 0 {
                    Button("全部重試（\(queue.retryable)）") { queue.retryAll() }.buttonStyle(.borderless).font(.caption)
                }
                Button("清除已結束") { queue.clearFinished() }.buttonStyle(.borderless).font(.caption)
                    .disabled(!queue.jobs.contains { !$0.stage.running && !$0.stage.pending })
            }
            if queue.jobs.isEmpty {
                Text("還沒有項目。加入檔案或貼上連結後會自動開始。").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(queue.jobs) { job in
                            JobRow(job: job, queue: queue, selected: queue.selection == job.id)
                                .onTapGesture { queue.selection = job.id }
                        }
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .onDeleteCommand {      // 按 Delete：刪除勾選的項目（沒勾選就刪目前選取的）
                    if !queue.checked.isEmpty { queue.removeChecked() }
                    else if let j = queue.jobs.first(where: { $0.id == queue.selection }) { queue.remove(j) }
                }
            }
        }
    }

    private func addLinks() {
        request(.links(links))
        links = ""
    }

    /// 要不要先問內容類型與輸出格式：看設定的「每次加入時詢問」
    private func request(_ r: AddRequest) {
        // 勾了「合併成一份」且有 2 個以上檔案：先讓使用者排順序、取名字
        if mergeOn, case .files(let urls, let titles) = r.kind {
            let files = MediaKinds.collect(urls)
            if files.count > 1 {
                // 語音備忘錄已依時間排好；一般檔案依檔名排（錄音被切成多段通常檔名有序號）
                let ordered = titles.isEmpty
                    ? files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    : files
                let first = titles[ordered[0]] ?? ordered[0].deletingPathExtension().lastPathComponent
                pendingMerge = MergeDraft(urls: ordered, names: titles, title: "\(first)（合併 \(files.count) 段）")
                return
            }
        }
        // 勾了「合併成一份」且貼了連結：先解析成影片清單，2 部以上就讓使用者排順序、取名字
        if mergeOn, case .links(let text) = r.kind {
            Task { await mergeLinks(text, r) }
            return
        }
        if settings.askEachTime { pending = r } else { perform(r, queue.options(extra: extra)) }
    }

    private func mergeLinks(_ text: String, _ r: AddRequest) async {
        queue.expanding = true
        queue.message = "解析連結中…"
        let res = await queue.expandLinks(text)
        queue.expanding = false
        let items = res.groups.flatMap { $0 }
        if let e = res.errors.last { queue.message = e }
        if items.count > 1 {
            remoteMergeMap = Dictionary(items.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
            let urls = items.compactMap { URL(string: $0.url) }
            queue.message = "已解析 \(items.count) 部影片，請確認合併順序"
            pendingMerge = MergeDraft(urls: urls, names: Dictionary(urls.map { ($0, remoteMergeMap[$0.absoluteString]?.title ?? $0.absoluteString) }, uniquingKeysWith: { a, _ in a }),
                                      title: "\(items[0].title)（合併 \(items.count) 部）", isRemote: true)
        } else if !items.isEmpty {         // 只有一部：不用合併，照一般流程
            queue.message = "只有 1 部影片，不需要合併"
            if settings.askEachTime { pending = r } else { queue.addRemote(res.groups, queue.options(extra: extra)) }
        }
    }

    private func perform(_ r: AddRequest, _ o: BatchOptions, _ groups: [[RemoteItem]]? = nil) {
        switch r.kind {
        case .files(let urls, let titles): queue.addFiles(urls, o, titles: titles)
        case .links(let text):
            if let groups { queue.addRemote(groups, o) } else { queue.addLinks(text, o) }
        case .merged(let urls, let title): queue.addMerged(urls, title: title, o)
        case .mergedRemote(let items, let title): queue.addMergedRemote(items, title: title, o)
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: (settings.outputDir as NSString).expandingTildeInPath)
        panel.message = "選擇整理結果要存到哪個資料夾"
        panel.prompt = "選擇"
        if panel.runModal() == .OK, let u = panel.url { settings.outputDir = u.path }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "選擇音訊／影片檔，或包含它們的資料夾"
        if panel.runModal() == .OK { request(.files(panel.urls, [:])) }
    }
}

struct AddRequest: Identifiable {
    enum Kind { case files([URL], [URL: String]), links(String), merged([URL], String), mergedRemote([RemoteItem], String) }
    let id = UUID()
    let kind: Kind
    static func files(_ u: [URL], _ t: [URL: String]) -> AddRequest { AddRequest(kind: .files(u, t)) }
    static func links(_ s: String) -> AddRequest { AddRequest(kind: .links(s)) }
    static func merged(_ u: [URL], _ t: String) -> AddRequest { AddRequest(kind: .merged(u, t)) }
    static func mergedRemote(_ i: [RemoteItem], _ t: String) -> AddRequest { AddRequest(kind: .mergedRemote(i, t)) }
    var summary: String {
        switch kind {
        case .files(let u, _): return "\(u.count) 個項目"
        case .links(let s): return "\(s.split(whereSeparator: { $0.isWhitespace }).count) 個連結"
        case .merged(let u, _): return "合併 \(u.count) 個檔案為 1 份"
        case .mergedRemote(let i, _): return "合併 \(i.count) 部影片為 1 份"
        }
    }
}

/// 已經整理好的 Markdown → HTML／PDF／TXT（各自一份，或合併成含目錄的一本）
struct ConvertSheet: View {
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [MDItem] = []
    @State private var book = false
    @State private var bookToc = true
    @State private var title = "合併文件"
    @State private var formats: Set<OutputFormat> = [.md, .html]
    @State private var running = false
    @State private var status = ""
    @State private var results: [URL] = []
    @State private var targeted = false

    private static let kinds: [OutputFormat] = [.md, .html, .pdf, .txt]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("轉換 Markdown").font(.headline)
            Text("選擇或拖入整理好的 .md（PodDigest 輸出的或自己寫的都可以）。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { choose() } label: { Label("加入 .md 檔…", systemImage: "plus") }
                if !items.isEmpty { Button("清空") { items = [] }.buttonStyle(.borderless) }
                Spacer()
            }
            List {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                    HStack(spacing: 8) {
                        Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(it.title).lineLimit(1)
                            Text(it.url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if book {
                            Button { items.swapAt(i, i - 1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                            Button { items.swapAt(i, i + 1) } label: { Image(systemName: "chevron.down") }.disabled(i == items.count - 1)
                        }
                        Button { items.remove(at: i) } label: { Image(systemName: "xmark") }
                    }
                    .buttonStyle(.borderless)
                }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 150)
            .overlay { if items.isEmpty { Text("把 .md 檔拖到這裡").foregroundStyle(.tertiary) } }
            .overlay { if targeted { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6])) } }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                Task {
                    var urls: [URL] = []
                    for p in providers {
                        if let item = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                           let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { urls.append(u) }
                    }
                    add(urls)
                }
                return true
            }
            Picker("方式", selection: $book) {
                Text("各自轉成一份").tag(false)
                Text("合併成一本（含目錄）").tag(true)
            }
            .pickerStyle(.segmented)
            if book {
                TextField("書名", text: $title).textFieldStyle(.roundedBorder)
                Toggle("含目錄", isOn: $bookToc).toggleStyle(.checkbox)
                Text(bookToc ? "每個檔案成為一個章節。HTML 有目錄抽屜與搜尋、上一章／下一章；PDF 有目錄頁，每章從新頁開始；Markdown／TXT 合成一個檔。"
                             : "每個檔案接成一份連續的文件（不加目錄抽屜與目錄頁），Markdown／HTML／PDF／TXT 都是單一檔案。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Text("輸出").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Self.kinds) { f in
                    Toggle(f.label, isOn: Binding(get: { formats.contains(f) }, set: { if $0 { formats.insert(f) } else { formats.remove(f) } }))
                        .toggleStyle(.checkbox)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.secondary).font(.caption)
                Text((settings.outputDir as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(book ? "／\(Exporter.safeName(title))／" : "／各檔名稱／").font(.caption).foregroundStyle(.secondary)
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(status.hasPrefix("失敗") ? .red : .secondary).textSelection(.enabled) }
            HStack {
                if !results.isEmpty {
                    Button { NSWorkspace.shared.activateFileViewerSelecting(results) } label: { Label("在 Finder 顯示", systemImage: "folder") }
                }
                Spacer()
                Button("關閉") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { run() } label: { Label(running ? "轉換中…" : "轉換", systemImage: "arrow.right.circle.fill") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.isEmpty || formats.isEmpty || running || (book && items.count < 2))
            }
        }
        .padding(20).frame(width: 580, height: 560)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func add(_ urls: [URL]) {
        var files: [URL] = []
        for u in urls {
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) else { continue }
            if dir.boolValue {
                let all = (FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?.allObjects as? [URL]) ?? []
                files += all.filter { ["md", "markdown"].contains($0.pathExtension.lowercased()) }
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if ["md", "markdown", "txt"].contains(u.pathExtension.lowercased()) { files.append(u) }
        }
        var failed: [String] = []
        for f in files where !items.contains(where: { $0.url == f }) {
            do { items.append(try Converter.load(f)) } catch { failed.append(f.lastPathComponent) }
        }
        if !failed.isEmpty { status = "失敗：無法讀取 " + failed.joined(separator: "、") }
        else if files.isEmpty { status = "沒有找到 .md 檔" }
        else { status = ""; if items.count > 1 && !book && title == "合併文件" { title = items[0].title + " 等 \(items.count) 份" } }
    }

    private func run() {
        running = true; status = "轉換中…"; results = []
        let out = URL(fileURLWithPath: (settings.outputDir as NSString).expandingTildeInPath)
        Task {
            do {
                if book {
                    results = try await Converter.convertBook(items, title: title.isEmpty ? "合併文件" : title, formats: formats, outDir: out, toc: bookToc)
                } else {
                    results = try await Converter.convertEach(items, formats: formats, outDir: out) { i, name in status = "轉換中 \(i + 1)/\(items.count)：\(name)" }
                }
                status = "完成：輸出 \(results.count) 個檔案"
            } catch { status = "失敗：\(error.localizedDescription)" }
            running = false
        }
    }
}

struct MergeDraft: Identifiable {
    let id = UUID()
    var urls: [URL]
    var names: [URL: String]      // 語音備忘錄的標題
    var title: String
    var isRemote = false          // 合併的是影片連結（不是本地檔案）
}

/// 合併多段錄音：調整順序、取名字
struct MergeSheet: View {
    let draft: MergeDraft
    let onConfirm: ([URL], String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var urls: [URL] = []
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("合併成一份（\(urls.count) \(draft.isRemote ? "部影片" : "個檔案")）").font(.headline)
            Text("依下面的順序接成一段長錄音，只會轉一次文字、整理一份重點。拖曳或用箭頭調整順序。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("標題", text: $title).textFieldStyle(.roundedBorder)
            List {
                ForEach(Array(urls.enumerated()), id: \.element) { i, u in
                    HStack(spacing: 8) {
                        Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                        Text(draft.names[u] ?? u.lastPathComponent).lineLimit(1)
                        Spacer()
                        Button { move(i, -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                        Button { move(i, 1) } label: { Image(systemName: "chevron.down") }.disabled(i == urls.count - 1)
                        Button { urls.remove(at: i) } label: { Image(systemName: "xmark") }.disabled(urls.count <= 2)
                    }
                    .buttonStyle(.borderless)
                }
                .onMove { urls.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("合併並繼續") { onConfirm(urls, title.isEmpty ? "合併錄音" : title); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 560, height: 440)
        .onAppear { urls = draft.urls; title = draft.title }
    }

    private func move(_ i: Int, _ d: Int) { urls.swapAt(i, i + d) }
}

/// 每次加入前詢問：內容類型、詳細程度、輸出格式
struct AskSheet: View {
    let request: AddRequest
    @ObservedObject var settings: SettingsStore
    @ObservedObject var queue: JobQueue
    let extra: String
    let onConfirm: (BatchOptions, [[RemoteItem]]?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var previewTitles: [String] = []     // 預覽：即將加入的標題
    @State private var groups: [[RemoteItem]]?          // 連結已展開的結果（確認時直接使用）
    @State private var loading = true
    @State private var previewErrors: [String] = []
    @State private var genreID = ""
    @State private var detail = DetailLevel.standard
    @State private var formats: Set<OutputFormat> = []
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("加入 \(request.summary)").font(.headline)
            previewList
            Text("內容類型").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Genre.all) { g in
                    let on = genreID == g.id
                    Button { genreID = g.id } label: {
                        Label(g.name, systemImage: g.icon).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Color.accentColor : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(Genre.find(genreID).blurb).font(.caption).foregroundStyle(.secondary)
            Picker("詳細程度", selection: $detail) { ForEach(DetailLevel.allCases) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented)
            Text("輸出格式").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(OutputFormat.allCases) { f in
                    Toggle(f.label, isOn: Binding(get: { formats.contains(f) },
                                                  set: { if $0 { formats.insert(f) } else { formats.remove(f) } }))
                }
            }
            if formats.isEmpty { Text("沒有勾選格式時只會顯示在視窗內，不存檔。").font(.caption).foregroundStyle(.orange) }
            HStack {
                if loading, case .links = request.kind {
                    Button("略過預覽直接開始") {       // 不等解析：背景解析連結後直接加入
                        settings.genreID = genreID
                        onConfirm(BatchOptions(genre: Genre.find(genreID), extra: extra, detail: detail, formats: formats), nil)
                        dismiss()
                    }
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("加入並開始") {
                    settings.genreID = genreID
                    onConfirm(BatchOptions(genre: Genre.find(genreID), extra: extra, detail: detail, formats: formats), groups)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(loading || (groups != nil && previewTitles.isEmpty))
            }
        }
        .padding(20).frame(width: 520)
        .onAppear { genreID = settings.genreID; detail = settings.detail; formats = settings.formats }
        .task { await loadPreview() }
    }

    /// 預覽即將加入的項目（檔案顯示檔名，連結先展開成影片標題；最多列 200 筆）
    private var previewList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("將加入的項目").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if loading { ProgressView().controlSize(.small); Text("解析連結中…").font(.caption).foregroundStyle(.secondary) }
                else { Text("共 \(previewTitles.count) 項").font(.caption).foregroundStyle(.secondary) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(previewTitles.prefix(200).enumerated()), id: \.offset) { _, t in
                        Text("• " + t).font(.callout).lineLimit(1).truncationMode(.middle)
                    }
                    if previewTitles.count > 200 { Text("…還有 \(previewTitles.count - 200) 項").font(.caption).foregroundStyle(.secondary) }
                    ForEach(previewErrors, id: \.self) { Text("⚠️ " + $0).font(.caption).foregroundStyle(.red).lineLimit(2) }
                    if !loading && previewTitles.isEmpty && previewErrors.isEmpty { Text("沒有可加入的項目").font(.caption).foregroundStyle(.orange) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 130)
            .padding(8).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func loadPreview() async {
        switch request.kind {
        case .files(let urls, let titles):
            let files = await Task.detached { MediaKinds.collect(urls) }.value
            previewTitles = files.map { titles[$0] ?? $0.deletingPathExtension().lastPathComponent }
        case .merged(let urls, let title):
            previewTitles = ["合併為「\(title)」"] + urls.map { "　" + $0.lastPathComponent }
        case .mergedRemote(let items, let title):
            previewTitles = ["合併為「\(title)」"] + items.map { "　" + $0.title }
        case .links(let text):
            let r = await queue.expandLinks(text)
            groups = r.groups
            previewTitles = r.groups.flatMap { $0.map(\.title) }
            previewErrors = r.errors
        }
        loading = false
    }
}

/// 語音備忘錄多選匯入
struct VoiceMemosSheet: View {
    let onAdd: ([URL], [URL: String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var memos: [VoiceMemo] = []
    @State private var selection = Set<String>()
    @State private var query = ""
    @State private var error = ""
    @State private var skipped = 0
    @State private var loaded = false

    private var shown: [VoiceMemo] {
        query.isEmpty ? memos : memos.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("語音備忘錄").font(.headline)
                Spacer()
                TextField("搜尋標題", text: $query).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            if !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                HStack {
                    Button("開啟完整磁碟取用權限設定") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    Button("重新讀取") { reload() }
                }
            } else if loaded && memos.isEmpty {
                Text("沒有找到錄音").foregroundStyle(.secondary)
            } else {
                Table(shown, selection: $selection) {
                    TableColumn("標題") { Text($0.title).lineLimit(1) }
                    TableColumn("日期") { Text($0.date.formatted(date: .abbreviated, time: .shortened)) }.width(150)
                    TableColumn("長度") { Text($0.duration > 0 ? Summarizer.mmss($0.duration) : "—").monospacedDigit() }.width(70)
                }
                .frame(minHeight: 280)
                if skipped > 0 {
                    Text("另有 \(skipped) 則只存在 iCloud、尚未下載到這台 Mac，請先在語音備忘錄 App 裡下載。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("全選") { selection = Set(shown.map(\.id)) }.disabled(shown.isEmpty)
                Button("取消選取") { selection = [] }.disabled(selection.isEmpty)
                Text("已選 \(selection.count) 則").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("匯入 \(selection.count) 則") {
                    let chosen = memos.filter { selection.contains($0.id) }.sorted { $0.date < $1.date }
                    onAdd(chosen.map(\.url), Dictionary(chosen.map { ($0.url, $0.title) }, uniquingKeysWith: { a, _ in a }))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(selection.isEmpty)
            }
        }
        .padding(20).frame(width: 640, height: 460)
        .onAppear { reload() }
    }

    private func reload() {
        do { let r = try VoiceMemos.load(); memos = r.memos; skipped = r.skipped; error = "" }
        catch { self.error = error.localizedDescription }
        loaded = true
    }
}

struct JobRow: View {
    @ObservedObject var job: Job
    @ObservedObject var queue: JobQueue
    let selected: Bool

    var body: some View {
        let tint = job.stage.color
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { queue.checked.contains(job.id) },
                                     set: { if $0 { queue.checked.insert(job.id) } else { queue.checked.remove(job.id) } }))
                .toggleStyle(.checkbox).labelsHidden().help("勾選後可批量刪除（按 Delete 鍵或「刪除選取」）")
            Image(systemName: job.sourceIcon)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.title).font(.callout.weight(.semibold)).lineLimit(1)
                    StatusPill(text: job.stage.label, color: tint)
                }
                if job.stage.running {
                    ProgressView(value: min(max(job.progress, 0), 1))
                    Text(job.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if job.stage == .failed {
                    Text(job.error).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text("\(job.options.genre.name)" + (job.detail.isEmpty ? "" : " · \(job.detail)"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                if job.stage.running || job.stage.pending {
                    Button { queue.cancel(job) } label: { Image(systemName: "stop.fill").frame(width: 22, height: 22) }.help("取消")
                } else if job.stage == .failed || job.stage == .cancelled {
                    Button { queue.retry(job) } label: { Image(systemName: "arrow.clockwise").frame(width: 22, height: 22) }.help("重試")
                }
                if !job.stage.running {
                    Button { queue.remove(job) } label: { Image(systemName: "xmark").frame(width: 22, height: 22) }.help("移除")
                }
            }
            .buttonStyle(.borderless).font(.system(size: 12))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct JobDetail: View {
    @ObservedObject var job: Job
    @ObservedObject var queue: JobQueue
    @State private var tab = 0
    @State private var showTune = false

    /// 做完（或做過至少一版）而且現在沒在跑／排隊 → 顯示結果；否則顯示進行中的畫面
    private var showResult: Bool { job.output != nil && !job.stage.running && !job.stage.pending }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showResult, let out = job.output { resultView(out) } else { LiveView(job: job, queue: queue) }
        }
        .padding(.leading, 8)
    }

    @ViewBuilder
    private func resultView(_ out: PipelineOutput) -> some View {
        HStack {
            Picker("", selection: $tab) {
                Text("重點").tag(0)
                Text("逐字稿").tag(1)
            }
            .pickerStyle(.segmented).frame(width: 160).labelsHidden()
            if job.versions.count > 1 {
                Picker("版本", selection: Binding(get: { job.viewing }, set: { job.viewing = $0 })) {
                    ForEach(job.versions.indices, id: \.self) { i in
                        Text("版本 \(i + 1)・\(job.versions[i].doc.meta.first { $0.0 == "類型" }?.1 ?? "")").tag(i)
                    }
                }
                .frame(width: 190)
            }
            Spacer()
            Button { showTune.toggle() } label: { Label("調整並再做一份", systemImage: "slider.horizontal.3") }
            Button { queue.retranscribe(job) } label: { Label("重新轉文字", systemImage: "waveform.badge.magnifyingglass") }
                .help("逐字稿不對時，從頭重新轉文字再整理（新結果會變成新版本）")
            Button { copy(Exporter.markdown(out.doc)) } label: { Label("複製 Markdown", systemImage: "doc.on.doc") }
            Menu {
                ForEach(OutputFormat.allCases) { f in Button("另存為 \(f.label)…") { saveAs(f, out) } }
            } label: { Label("另存", systemImage: "square.and.arrow.down") }
            Button { NSWorkspace.shared.activateFileViewerSelecting(out.files) } label: { Label("在 Finder 顯示", systemImage: "folder") }
                .disabled(out.files.isEmpty)
        }
        .buttonStyle(.borderless).font(.callout)
        if job.stage == .failed, !job.error.isEmpty {
            Label("再整理失敗：\(job.error)", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
        }
        if showTune {
            VStack(alignment: .leading, spacing: 8) {
                OptionsEditor(job: job, queue: queue, locked: false)
                HStack {
                    Text("沿用這份逐字稿，用上面的設定再整理一份（不用重新轉文字），新檔案會另存，舊的不會被覆蓋。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { queue.rerun(job); showTune = false } label: { Label("再做一份", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(10).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        if tab == 0 {
            HTMLView(html: Exporter.html(out.doc)).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            ReadOnlyText(text: out.transcript.joined(separator: "\n\n")).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func saveAs(_ f: OutputFormat, _ out: PipelineOutput) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Exporter.safeName(job.title) + f.suffix + "." + f.ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                switch f {
                case .md: try Exporter.markdown(out.doc).write(to: url, atomically: true, encoding: .utf8)
                case .html: try Exporter.html(out.doc).write(to: url, atomically: true, encoding: .utf8)
                case .pdf: try await PDFRenderer.render(html: Exporter.html(out.doc, forPrint: true), to: url)
                case .txt: try Exporter.plainText(out.doc).write(to: url, atomically: true, encoding: .utf8)
                case .transcript: try Exporter.transcriptText(out.doc).write(to: url, atomically: true, encoding: .utf8)
                }
            } catch { queue.log("另存失敗：\(error.localizedDescription)") }
        }
    }
}

/// 進行中／排隊中／失敗的畫面：目前做到哪、設定（做完前可改）、即時逐字稿、這個項目的日誌
struct LiveView: View {
    @ObservedObject var job: Job
    @ObservedObject var queue: JobQueue

    private static let steps: [(Stage, String)] = [(.downloading, "下載"), (.preparing, "處理音訊"), (.transcribing, "轉文字"),
                                                   (.summarizing, "整理重點"), (.exporting, "輸出")]
    private var isRemote: Bool { job.input.source.isRemote }
    private func stepIndex(_ s: Stage) -> Int { Self.steps.firstIndex { $0.0 == s } ?? -1 }

    /// 已經走過的階段不會再吃到新設定
    private var lockNote: String? {
        switch job.stage {
        case .summarizing: return "已經開始整理重點：類型、詳細程度、額外要求這次不會變，輸出格式還可以改。要用新的類型再整理，做完後按「調整並再做一份」。"
        case .exporting: return "正在輸出檔案，這次的設定已經定了。做完後可按「調整並再做一份」。"
        default: return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: job.sourceIcon).foregroundStyle(job.stage.color)
                    Text(job.title).font(.headline).lineLimit(2)
                    StatusPill(text: job.stage.label, color: job.stage.color)
                    Spacer()
                    if job.stage.running || job.stage.pending {
                        Button(role: .destructive) { queue.cancel(job) } label: { Label("取消", systemImage: "stop.fill") }
                    } else if job.stage == .failed || job.stage == .cancelled {
                        Button { queue.retry(job) } label: { Label("重試", systemImage: "arrow.clockwise") }
                    }
                }
                // 步驟
                HStack(spacing: 4) {
                    let summIdx = Self.steps.firstIndex { $0.0 == .summarizing } ?? 3
                    let cur = job.stage == .awaiting ? summIdx : stepIndex(job.stage)
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, st in
                        if !(st.0 == .downloading && !isRemote) {
                            let state = job.stage == .done || i < cur ? 2 : (i == cur && job.stage != .awaiting ? 1 : 0)
                            HStack(spacing: 4) {
                                Image(systemName: state == 2 ? "checkmark.circle.fill" : state == 1 ? "circle.dotted.circle" : "circle")
                                    .foregroundStyle(state == 2 ? .green : state == 1 ? job.stage.color : .secondary)
                                Text(st.1).font(.caption).foregroundStyle(state == 0 ? .secondary : .primary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(state == 1 ? job.stage.color.opacity(0.14) : Color.primary.opacity(0.05), in: Capsule())
                        }
                    }
                }
                if job.stage.running {
                    ProgressView(value: min(max(job.progress, 0), 1))
                    HStack {
                        Text(job.detail).font(.callout)
                        Spacer()
                        if let t0 = job.startedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                let sec = Int(ctx.date.timeIntervalSince(t0))
                                Text("已進行 \(Summarizer.mmss(Double(sec)))　\(Int(job.progress * 100))%")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                } else if job.stage.pending {
                    Text(job.stage == .awaiting ? "逐字稿已完成，等其他音檔都轉完文字後，再一起交給 LLM 整理。" + (job.detail.isEmpty ? "" : "\n\(job.detail)")
                         : (job.detail.isEmpty ? "排隊中，前面還有 \(queue.ahead(of: job)) 個" : job.detail))
                        .font(.callout).foregroundStyle(.secondary)
                } else if job.stage == .failed {
                    Label(job.error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }

                GroupBox("設定（做完前都可以改）") {
                    VStack(alignment: .leading, spacing: 8) {
                        OptionsEditor(job: job, queue: queue, locked: job.stage == .summarizing || job.stage == .exporting)
                        if let n = lockNote { Text(n).font(.caption).foregroundStyle(.orange) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !job.liveLines.isEmpty {
                    GroupBox("即時逐字稿（最後 \(min(job.liveLines.count, 60)) 段）") {
                        ReadOnlyText(text: job.liveLines.suffix(60).joined(separator: "\n\n")).frame(height: 170)
                    }
                }
                GroupBox("這個項目的紀錄") {
                    ReadOnlyText(text: job.jobLog.suffix(80).joined(separator: "\n")).frame(height: 110)
                }
            }
            .padding(.trailing, 6)
        }
    }
}

/// 內容類型、詳細程度、輸出格式、額外要求（直接改這個項目）
struct OptionsEditor: View {
    @ObservedObject var job: Job
    @ObservedObject var queue: JobQueue
    let locked: Bool       // 整理已開始：類型／詳細程度／額外要求鎖住，只剩輸出格式

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Genre.all) { g in
                        let on = job.options.genre.id == g.id
                        Button { job.options.genre = g; queue.persistSoon() } label: {
                            Label(g.name, systemImage: g.icon).font(.caption)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
                                .overlay(Capsule().strokeBorder(on ? Color.accentColor : .clear))
                                .foregroundStyle(on ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .disabled(locked).opacity(locked ? 0.5 : 1)
            HStack {
                Picker("詳細程度", selection: Binding(get: { job.options.detail }, set: { job.options.detail = $0; queue.persistSoon() })) {
                    ForEach(DetailLevel.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 240).disabled(locked)
                TextField("額外要求（選填）", text: Binding(get: { job.options.extra }, set: { job.options.extra = $0; queue.persistSoon() }))
                    .textFieldStyle(.roundedBorder).disabled(locked)
            }
            HStack(spacing: 6) {
                Text("輸出").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(OutputFormat.allCases) { f in
                    let on = job.options.formats.contains(f)
                    Button {
                        if on { job.options.formats.remove(f) } else { job.options.formats.insert(f) }
                        queue.persistSoon()
                    } label: {
                        Text(f.shortLabel).font(.caption.weight(.medium))
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? Color.accentColor : .clear))
                            .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct HTMLView: NSViewRepresentable {
    let html: String
    func makeNSView(context: Context) -> WKWebView { WKWebView(frame: .zero) }
    func updateNSView(_ v: WKWebView, context: Context) {
        if context.coordinator.last != html { context.coordinator.last = html; v.loadHTMLString(html, baseURL: nil) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var last = "" }
}

struct ReadOnlyText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        if let tv = sv.documentView as? NSTextView {
            tv.isEditable = false
            tv.font = .systemFont(ofSize: 13)
            tv.textContainerInset = NSSize(width: 10, height: 10)
        }
        return sv
    }
    func updateNSView(_ sv: NSScrollView, context: Context) {
        if let tv = sv.documentView as? NSTextView, tv.string != text { tv.string = text }
    }
}

// MARK: - 設定

struct SettingsView: View {
    @ObservedObject var queue: JobQueue
    @ObservedObject var settings: SettingsStore
    @AppStorage(AppPrefs.diagnosticKey) private var diagnostic = false
    @State private var sttModels: [String] = []
    @State private var llmModels: [String] = []
    @State private var sttResult: (ok: Bool, msg: String)?
    @State private var llmResult: (ok: Bool, msg: String)?
    @State private var testing = ""
    @State private var revealStt = false
    @State private var revealLlm = false
    @State private var ytdlpVersion: String?
    @State private var ytdlpUpdating = false
    @State private var ytdlpNote = ""

    var body: some View {
        Form {
            Section("設定儲存位置") {
                Picker("儲存在", selection: $settings.storage) {
                    ForEach(SettingsStore.Storage.allCases) { Text($0.label).tag($0) }
                }
                if settings.storage == .folder {
                    HStack {
                        TextField("資料夾", text: $settings.folderPath)
                        Button("選擇…") { chooseSyncFolder() }
                    }
                    Toggle("API Key 也存到這個資料夾", isOn: $settings.keysInFolder)
                    Text(settings.keysInFolder
                         ? "⚠️ API Key 會以明碼寫在 settings.json，並由 iCloud 同步到登入同一個 Apple ID 的電腦；換電腦只要帶著 App 就能直接用。"
                         : "API Key 只存在這台 Mac 的鑰匙圈；換電腦時要重新貼一次。")
                        .font(.caption).foregroundStyle(settings.keysInFolder ? .orange : .secondary)
                    Button("重新讀取資料夾裡的設定") { settings.load() }
                }
                if !settings.syncNote.isEmpty { Text(settings.syncNote).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Section("語音轉文字（外部，OpenAI 相容 /audio/transcriptions）") {
                Picker("服務預設", selection: Binding<String>(get: { "" }, set: { name in
                    if let p = Presets.stt.first(where: { $0.name == name }) { settings.sttBaseURL = p.baseURL; settings.sttModel = p.model }
                })) {
                    Text("選擇後自動填入網址與模型…").tag("")
                    ForEach(Presets.stt) { Text($0.name).tag($0.name) }
                }
                TextField("服務網址（Base URL）", text: $settings.sttBaseURL)
                modelField("模型名稱", text: $settings.sttModel, models: sttModels)
                keyField("API Key（本機服務可留空）", text: $settings.sttAPIKey, revealed: $revealStt)
                TextField("語言代碼（zh、en、ja…；留空＝自動偵測）", text: $settings.sttLanguage)
                Toggle("送出提示詞幫助辨識（類型相關的提示；有些模型會把提示詞當成內容吐回來，預設關閉）", isOn: $settings.sttUsePrompt)
                Stepper("每段音訊長度 \(settings.audioChunkMinutes) 分鐘", value: $settings.audioChunkMinutes, in: 1...30)
                testRow(kind: "stt", result: sttResult)
            }
            Section("大型語言模型（外部，OpenAI 相容 /chat/completions）") {
                Picker("服務預設", selection: Binding<String>(get: { "" }, set: { name in
                    if let p = Presets.llm.first(where: { $0.name == name }) { settings.llmBaseURL = p.baseURL; if !p.model.isEmpty { settings.llmModel = p.model } }
                })) {
                    Text("選擇後自動填入網址與模型…").tag("")
                    ForEach(Presets.llm) { Text($0.name).tag($0.name) }
                }
                TextField("服務網址（Base URL）", text: $settings.llmBaseURL)
                modelField("模型名稱（留空＝伺服器第一個模型）", text: $settings.llmModel, models: llmModels)
                keyField("API Key（本機服務可留空）", text: $settings.llmAPIKey, revealed: $revealLlm)
                LabeledContent("溫度 \(settings.llmTemperature, specifier: "%.1f")") {
                    Slider(value: $settings.llmTemperature, in: 0...1, step: 0.1).frame(maxWidth: 200)
                }
                Picker("每次送給模型的字數上限", selection: $settings.chunkChars) {
                    Text("4,000 字（小模型）").tag(4000)
                    Text("8,000 字").tag(8000)
                    Text("16,000 字").tag(16000)
                    Text("32,000 字（大 context 模型）").tag(32000)
                    Text("64,000 字").tag(64000)
                }
                Toggle("關閉模型思考（送出 enable_thinking=false，適用本機 Qwen 等）", isOn: $settings.llmDisableThinking)
                testRow(kind: "llm", result: llmResult)
            }
            Section("處理方式") {
                Picker("多個音檔時", selection: $settings.batchMode) {
                    ForEach(BatchMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(settings.batchMode.detail).font(.caption).foregroundStyle(.secondary)
            }
            Section("整理偏好") {
                Picker("預設內容類型", selection: $settings.genreID) {
                    ForEach(Genre.all) { Label($0.name, systemImage: $0.icon).tag($0.id) }
                }
                Picker("詳細程度", selection: $settings.detail) { ForEach(DetailLevel.allCases) { Text($0.label).tag($0) } }
                Picker("輸出語言", selection: $settings.outputLanguage) {
                    ForEach(["繁體中文", "簡體中文", "English", "日本語"], id: \.self) { Text($0).tag($0) }
                }
                Toggle("在重點後標註時間（mm:ss）", isOn: $settings.timestamps)
                Toggle("完成時通知（每個項目一則，點通知在 Finder 顯示輸出檔）", isOn: $settings.notifyOnFinish)
                Toggle("關掉視窗後，全部做完就自動結束 App", isOn: $settings.quitWhenDone)
                    .help("預設關閉：做完後 App 留在選單列待命，從選單列的「主視窗」可以再打開；打開後才會結束。")
                VStack(alignment: .leading, spacing: 4) {
                    Text("「自訂」類型的整理要求").font(.callout)
                    TextEditor(text: $settings.customGenrePrompt).font(.callout).frame(height: 60)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                }
            }
            Section("輸出") {
                HStack {
                    TextField("輸出資料夾", text: $settings.outputDir)
                    Button("選擇…") { chooseFolder() }
                    Button("打開") {
                        try? FileManager.default.createDirectory(atPath: settings.outputDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(URL(fileURLWithPath: settings.outputDir))
                    }
                }
                ForEach(OutputFormat.allCases) { f in
                    Toggle(f.label, isOn: Binding(get: { settings.formats.contains(f) },
                                                  set: { on in if on { settings.formats.insert(f) } else { settings.formats.remove(f) } }))
                }
                if settings.formats.isEmpty {
                    Text("⚠️ 沒有勾選任何格式，處理完只會顯示在視窗內，不會存檔。").font(.caption).foregroundStyle(.orange)
                }
                Toggle("在重點後面附上逐字稿（Markdown／HTML／PDF／重點 TXT）", isOn: $settings.includeTranscript)
                Toggle("保留下載的音訊（YouTube 連結，存在輸出子資料夾內）", isOn: $settings.keepAudio)
                Toggle("自動命名標題（整理完後由 LLM 依內容取標題，後面保留原標題；檔案、語音備忘錄、YouTube 都適用）", isOn: $settings.autoTitle)
            }
            Section("YouTube") {
                let found = Tool.find("yt-dlp", custom: settings.ytdlpPath)
                HStack {
                    TextField("yt-dlp 路徑（留空＝用 App 內建版本）", text: $settings.ytdlpPath)
                    StatusPill(text: found != nil ? "v\(ytdlpVersion ?? "…")" : "找不到", color: found != nil ? .green : .red)
                }
                HStack {
                    Button { updateYtdlp() } label: { Label(ytdlpUpdating ? "更新中…" : "更新 yt-dlp", systemImage: "arrow.down.circle") }
                        .disabled(ytdlpUpdating)
                    Text(ytdlpNote.isEmpty ? "YouTube 常改版，影片下載失敗時先更新。新版存在 ~/Library/Application Support/PodDigest，不會改動 App。" : ytdlpNote)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                TextField("額外的 yt-dlp 參數（例如 --cookies-from-browser safari）", text: $settings.ytdlpExtraArgs)
                HStack(spacing: 6) {
                    Text("ffmpeg").font(.callout)
                    StatusPill(text: Tool.find("ffmpeg") != nil ? "已找到" : "未安裝（webm／ogg 等格式需要）",
                               color: Tool.find("ffmpeg") != nil ? .green : .orange)
                }
            }
            Section("一般") {
                Toggle("診斷模式（把日誌寫入檔案）", isOn: $diagnostic)
                    .onChange(of: diagnostic) { _, on in if !on { DiagnosticLog.close() } }
                    .help("預設關閉：日誌只顯示在「日誌」分頁、不寫任何檔案。")
                if diagnostic {
                    Text("日誌檔：\(DiagnosticLog.file.path)（最多約 10 MB）").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("音訊暫存檔在每個項目處理完就刪除；API Key 存在 macOS 鑰匙圈。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: settings.ytdlpPath) { ytdlpVersion = await YouTube.version(settings.config()) }
    }

    private func updateYtdlp() {
        ytdlpUpdating = true
        Task {
            do { ytdlpNote = "已更新到 \(try await YouTube.update())" } catch { ytdlpNote = "更新失敗：\(error.localizedDescription)" }
            ytdlpVersion = await YouTube.version(settings.config())
            ytdlpUpdating = false
        }
    }

    private func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = SyncFolder.iCloudDrive
        panel.message = "選擇存放 PodDigest 設定的資料夾（放在 iCloud Drive 裡就能在多台電腦同步）"
        if panel.runModal() == .OK, let u = panel.url { settings.folderPath = u.path }
    }

    @ViewBuilder
    private func modelField(_ label: String, text: Binding<String>, models: [String]) -> some View {
        HStack {
            TextField(label, text: text)
            if !models.isEmpty {
                Menu("選擇") { ForEach(models, id: \.self) { m in Button(m) { text.wrappedValue = m } } }.fixedSize()
            }
        }
    }

    @ViewBuilder
    private func keyField(_ label: String, text: Binding<String>, revealed: Binding<Bool>) -> some View {
        HStack {
            if revealed.wrappedValue { TextField(label, text: text) } else { SecureField(label, text: text) }
            Button { revealed.wrappedValue.toggle() } label: { Image(systemName: revealed.wrappedValue ? "eye.slash" : "eye") }
                .buttonStyle(.borderless)
        }
    }

    private func testRow(kind: String, result: (ok: Bool, msg: String)?) -> some View {
        HStack(spacing: 8) {
            Button { test(kind) } label: { Label(testing == kind ? "測試中…" : "測試連線並取得模型清單", systemImage: "bolt.horizontal") }
                .disabled(testing == kind)
            if let r = result {
                Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(r.ok ? .green : .red)
                Text(r.msg).font(.caption).foregroundStyle(r.ok ? Color.secondary : Color.red).textSelection(.enabled).lineLimit(3)
            }
            Spacer()
        }
    }

    private func test(_ kind: String) {
        testing = kind
        let base = kind == "stt" ? settings.sttBaseURL : settings.llmBaseURL
        let key = kind == "stt" ? settings.sttAPIKey : settings.llmAPIKey
        Task {
            var res: (Bool, String)
            do {
                let models = try await Net.listModels(base: base, key: key)
                if kind == "stt" { sttModels = models } else { llmModels = models }
                res = (true, "連線成功，共 \(models.count) 個模型")
                if kind == "llm" {
                    var c = settings.config()
                    c.chunkChars = 2000
                    let reply = try await LLMClient.chat(system: "只回答一個字。", user: "請回覆「好」。", cfg: c)
                    res = (true, "連線成功，模型回覆：\(reply.prefix(30))")
                }
            } catch { res = (false, error.localizedDescription) }
            if kind == "stt" { sttResult = res } else { llmResult = res }
            testing = ""
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let u = panel.url { settings.outputDir = u.path }
    }
}

struct LogView: View {
    @ObservedObject var queue: JobQueue
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(queue.logs.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: queue.logs.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
        }
    }
}


/// 選單列內容：處理中的進度、顯示主視窗、全部停止、結束
struct MenuContent: View {
    @ObservedObject var queue: JobQueue
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.badge.checkmark").foregroundStyle(.purple)
                Text("PodDigest").font(.headline)
                Spacer()
                if queue.isBusy || queue.pending > 0 {
                    // 只有一個項目時整體＝它自己；多個時標明「整體」與完成數，避免和下面每個項目的進度條搞混
                    let n = queue.jobs.filter { [.queued, .awaiting, .done].contains($0.stage) || $0.stage.running }.count
                    let d = queue.jobs.filter { $0.stage == .done }.count
                    StatusPill(text: n > 1 ? "整體 \(Int(queue.overallProgress * 100))%・已完成 \(d)/\(n)" : "\(Int(queue.overallProgress * 100))%", color: .purple)
                } else {
                    StatusPill(text: "待命", color: .green)
                }
            }
            ForEach(queue.jobs.filter { $0.stage.running }) { job in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(job.title).font(.callout).lineLimit(1)
                        Spacer()
                        Text("\(Int(min(max(job.progress, 0), 1) * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: min(max(job.progress, 0), 1))
                    Text(job.detail.isEmpty ? job.stage.label : "\(job.stage.label)・\(job.detail)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if queue.pending > 0 { Text("還有 \(queue.pending) 個排隊中").font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack(spacing: 14) {
                Button {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                } label: { Label("主視窗", systemImage: "macwindow") }
                if queue.isBusy || queue.pending > 0 || queue.paused {
                    Button { queue.paused ? queue.resume() : queue.pause() } label: {
                        Label(queue.paused ? "繼續" : "暫停", systemImage: queue.paused ? "play.circle" : "pause.circle")
                    }
                }
                Button { queue.cancelAll() } label: { Label("全部停止", systemImage: "stop.circle") }
                Spacer()
                Button { NSApp.terminate(nil) } label: { Label("結束", systemImage: "power") }
            }
            .buttonStyle(.borderless).font(.callout)
        }
        .padding(14).frame(width: 340)
    }
}
