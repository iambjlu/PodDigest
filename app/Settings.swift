// app/Settings.swift
// 設定保存：API Key 存「鑰匙圈」，其他存 UserDefaults。外部語音模型與外部 LLM 都走 OpenAI 相容 API。
import Foundation
import Security

enum Keychain {
    static let service = "tw.iambjlu.PodDigest"

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        if value.isEmpty { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum OutputFormat: String, CaseIterable, Identifiable {
    case md, html, pdf, txt, transcript
    var id: String { rawValue }
    var label: String {
        switch self {
        case .md: return "Markdown"
        case .html: return "單檔 HTML"
        case .pdf: return "PDF"
        case .txt: return "重點 TXT（純文字）"
        case .transcript: return "逐字稿 TXT"
        }
    }
    var shortLabel: String {
        switch self {
        case .md: return "MD"
        case .html: return "HTML"
        case .pdf: return "PDF"
        case .txt: return "TXT"
        case .transcript: return "逐字稿 TXT"
        }
    }
    var ext: String { self == .transcript ? "txt" : rawValue }
    var suffix: String { self == .transcript ? " 逐字稿" : "" }       // 檔名後綴
}

/// 批次處理方式
enum BatchMode: String, CaseIterable, Identifiable {
    case perItem      // 一個音檔轉完就整理，再換下一個（先看到第一份成果）
    case sttFirst     // 全部音檔都轉完文字，再一次交給 LLM（語音模型與 LLM 不用來回載入卸載）
    var id: String { rawValue }
    var label: String { self == .perItem ? "逐個完成" : "先全部轉文字，再整理" }
    var detail: String {
        self == .perItem ? "一個音檔轉完文字就接著整理，再換下一個。最快看到第一份成果，適合趕時間。"
                         : "先把所有音檔都轉成文字，再一次全部交給 LLM。語音模型與 LLM 各只載入一次，不用反覆載入卸載，適合本機記憶體有限、模型要切換的人。"
    }
}

enum DetailLevel: String, CaseIterable, Identifiable {
    case brief, standard, detailed
    var id: String { rawValue }
    var label: String { self == .brief ? "精簡" : self == .standard ? "標準" : "詳細" }
    var instruction: String {
        switch self {
        case .brief: return "精簡：只留最重要的內容，總長度約為原文的 3% 以內，每個條列一句話講完。"
        case .standard: return "標準：涵蓋所有主要論點與重要細節，條列清楚，不需逐句複述。"
        case .detailed: return "詳細：盡量完整保留論點、案例、數字、名詞定義與推論過程，寧可長一點也不要漏掉有價值的資訊。"
        }
    }
}

struct ServicePreset: Hashable, Identifiable {
    let name: String
    let baseURL: String
    let model: String
    var id: String { name }
}

enum Presets {
    static let stt: [ServicePreset] = [
        ServicePreset(name: "本機伺服器（127.0.0.1:8000）", baseURL: "http://127.0.0.1:8000/v1", model: "whisper-large-v3"),
        ServicePreset(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "whisper-1"),
        ServicePreset(name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo"),
        ServicePreset(name: "whisper.cpp server", baseURL: "http://127.0.0.1:8080/v1", model: "whisper-1"),
    ]
    static let llm: [ServicePreset] = [
        ServicePreset(name: "本機伺服器（127.0.0.1:8000）", baseURL: "http://127.0.0.1:8000/v1", model: ""),
        ServicePreset(name: "LM Studio", baseURL: "http://127.0.0.1:1234/v1", model: ""),
        ServicePreset(name: "Ollama", baseURL: "http://127.0.0.1:11434/v1", model: ""),
        ServicePreset(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4.1-mini"),
        ServicePreset(name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile"),
        ServicePreset(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: ""),
    ]
}

/// 一次處理流程需要的所有設定（值型別，可以安全丟到背景工作）
struct PipelineConfig {
    var sttBaseURL = "http://127.0.0.1:8000/v1"
    var sttModel = "whisper-large-v3"
    var sttAPIKey = ""
    var sttLanguage = "zh"
    var sttUsePrompt = false
    var llmBaseURL = "http://127.0.0.1:8000/v1"
    var llmModel = ""
    var llmAPIKey = ""
    var llmTemperature = 0.3
    var llmDisableThinking = false
    var chunkChars = 8000
    var audioChunkMinutes = 10
    var detail = DetailLevel.standard
    var outputLanguage = "繁體中文"
    var timestamps = true
    var extraPrompt = ""
    var outputDir = NSHomeDirectory() + "/Documents/PodDigest"
    var formats: Set<OutputFormat> = [.md, .html]
    var includeTranscript = false
    var keepAudio = false
    var autoTitle = false
    var ytdlpPath = ""
    var ytdlpExtraArgs = ""
    var keepVideoFolder = true
}

/// 設定檔（同步資料夾模式）：settings.json
struct SettingsFile: Codable {
    var version = 1
    var updated = ""
    var updatedBy = ""
    var values: [String: String] = [:]
    var secrets: [String: String]? = nil      // 只有「API Key 也存到資料夾」打開時才有
}

enum SyncFolder {
    /// iCloud Drive 在本機的位置（沒開 iCloud Drive 就是 nil）
    static var iCloudDrive: URL? {
        let u = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    static var defaultFolder: String { (iCloudDrive?.path ?? NSHomeDirectory() + "/Documents") + "/PodDigest" }
}

final class SettingsStore: ObservableObject {
    enum Storage: String, CaseIterable, Identifiable {
        case local, folder
        var id: String { rawValue }
        var label: String { self == .local ? "只存在這台 Mac" : "同步資料夾（建議放 iCloud Drive）" }
    }

    private let d = UserDefaults.standard
    private var loading = false
    private var pendingSave: DispatchWorkItem?
    private var lastFileStamp: Date?

    // 儲存位置（每台電腦各自記住，不進同步檔）
    @Published var storage: Storage { didSet { d.set(storage.rawValue, forKey: "storage"); if !loading { load() ; changed() } } }
    @Published var folderPath: String { didSet { d.set(folderPath, forKey: "folderPath"); if !loading, storage == .folder { load(); changed() } } }
    @Published var keysInFolder: Bool { didSet { d.set(keysInFolder, forKey: "keysInFolder"); changed() } }
    @Published var syncNote = ""
    @Published var ytdlpPath: String { didSet { d.set(ytdlpPath, forKey: "ytdlpPath") } }      // 路徑每台不同，不同步

    // 語音轉文字
    @Published var sttBaseURL = "http://127.0.0.1:8000/v1" { didSet { changed() } }
    @Published var sttModel = "whisper-large-v3" { didSet { changed() } }
    @Published var sttAPIKey = "" { didSet { changed() } }
    @Published var sttLanguage = "zh" { didSet { changed() } }
    @Published var audioChunkMinutes = 10 { didSet { changed() } }
    @Published var sttUsePrompt = false { didSet { changed() } }
    // LLM
    @Published var llmBaseURL = "http://127.0.0.1:8000/v1" { didSet { changed() } }
    @Published var llmModel = "" { didSet { changed() } }
    @Published var llmAPIKey = "" { didSet { changed() } }
    @Published var llmTemperature = 0.3 { didSet { changed() } }
    @Published var llmDisableThinking = false { didSet { changed() } }
    @Published var chunkChars = 8000 { didSet { changed() } }
    // 整理偏好
    @Published var genreID = "podcast" { didSet { changed() } }
    @Published var detail = DetailLevel.standard { didSet { changed() } }
    @Published var outputLanguage = "繁體中文" { didSet { changed() } }
    @Published var timestamps = true { didSet { changed() } }
    @Published var customGenrePrompt = "" { didSet { changed() } }
    @Published var askEachTime = false { didSet { changed() } }
    @Published var batchMode = BatchMode.perItem { didSet { changed() } }
    @Published var notifyOnFinish = true { didSet { changed() } }
    @Published var quitWhenDone = false { didSet { changed() } }
    // 輸出
    @Published var outputDir = "~/Documents/PodDigest" { didSet { changed() } }
    @Published var formats: Set<OutputFormat> = [.md, .html] { didSet { changed() } }
    @Published var includeTranscript = false { didSet { changed() } }
    @Published var keepAudio = false { didSet { changed() } }
    @Published var autoTitle = false { didSet { changed() } }
    // YouTube
    @Published var ytdlpExtraArgs = "" { didSet { changed() } }

    init() {
        loading = true
        // 第一次執行：有 iCloud Drive 就直接用它存設定，換電腦只要帶著 App
        let savedStorage = d.string(forKey: "storage").flatMap(Storage.init(rawValue:))
        storage = savedStorage ?? (SyncFolder.iCloudDrive != nil ? .folder : .local)
        folderPath = d.string(forKey: "folderPath") ?? SyncFolder.defaultFolder
        keysInFolder = d.object(forKey: "keysInFolder") as? Bool ?? true
        ytdlpPath = d.string(forKey: "ytdlpPath") ?? ""
        loading = false
        load()
        applyEnvOverrides()
    }

    private func applyEnvOverrides() {            // 測試用：環境變數覆蓋（不會存起來）
        let env = ProcessInfo.processInfo.environment
        loading = true; defer { loading = false }
        if let v = env["PD_STT_URL"] { sttBaseURL = v }
        if let v = env["PD_STT_MODEL"] { sttModel = v }
        if let v = env["PD_LLM_URL"] { llmBaseURL = v }
        if let v = env["PD_LLM_MODEL"] { llmModel = v }
        if let v = env["PD_OUT_DIR"] { outputDir = v }
    }

    // MARK: 讀取與儲存

    private var fileURL: URL { URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath).appendingPathComponent("settings.json") }

    private func snapshot() -> [String: String] {
        ["sttBaseURL": sttBaseURL, "sttModel": sttModel, "sttLanguage": sttLanguage,
         "audioChunkMinutes": String(audioChunkMinutes), "sttUsePrompt": String(sttUsePrompt), "llmBaseURL": llmBaseURL, "llmModel": llmModel,
         "llmTemperature": String(llmTemperature), "llmDisableThinking": String(llmDisableThinking),
         "chunkChars": String(chunkChars), "genreID": genreID, "detail": detail.rawValue,
         "outputLanguage": outputLanguage, "timestamps": String(timestamps), "customGenrePrompt": customGenrePrompt,
         "outputDir": outputDir.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
         "formats": formats.map(\.rawValue).sorted().joined(separator: ","),
         "includeTranscript": String(includeTranscript), "keepAudio": String(keepAudio), "autoTitle": String(autoTitle), "askEachTime": String(askEachTime), "batchMode": batchMode.rawValue, "notifyOnFinish": String(notifyOnFinish), "quitWhenDone": String(quitWhenDone), "ytdlpExtraArgs": ytdlpExtraArgs]
    }

    private func apply(_ v: [String: String]) {
        func s(_ k: String, _ cur: String) -> String { v[k] ?? cur }
        func b(_ k: String, _ cur: Bool) -> Bool { v[k].map { $0 == "true" } ?? cur }
        sttBaseURL = s("sttBaseURL", sttBaseURL); sttModel = s("sttModel", sttModel); sttLanguage = s("sttLanguage", sttLanguage)
        audioChunkMinutes = v["audioChunkMinutes"].flatMap(Int.init) ?? audioChunkMinutes
        sttUsePrompt = b("sttUsePrompt", sttUsePrompt)
        llmBaseURL = s("llmBaseURL", llmBaseURL); llmModel = s("llmModel", llmModel)
        llmTemperature = v["llmTemperature"].flatMap(Double.init) ?? llmTemperature
        llmDisableThinking = b("llmDisableThinking", llmDisableThinking)
        chunkChars = v["chunkChars"].flatMap(Int.init) ?? chunkChars
        genreID = s("genreID", genreID)
        detail = v["detail"].flatMap(DetailLevel.init(rawValue:)) ?? detail
        outputLanguage = s("outputLanguage", outputLanguage); timestamps = b("timestamps", timestamps)
        customGenrePrompt = s("customGenrePrompt", customGenrePrompt)
        outputDir = s("outputDir", outputDir)
        if let f = v["formats"] { formats = Set(f.split(separator: ",").compactMap { OutputFormat(rawValue: String($0)) }) }
        includeTranscript = b("includeTranscript", includeTranscript)
        keepAudio = b("keepAudio", keepAudio)
        autoTitle = b("autoTitle", autoTitle)
        askEachTime = b("askEachTime", askEachTime)
        batchMode = v["batchMode"].flatMap(BatchMode.init(rawValue:)) ?? batchMode
        notifyOnFinish = b("notifyOnFinish", notifyOnFinish)
        quitWhenDone = b("quitWhenDone", quitWhenDone)
        ytdlpExtraArgs = s("ytdlpExtraArgs", ytdlpExtraArgs)
    }

    /// 依儲存位置載入：同步資料夾有 settings.json 就用它，否則用本機的
    func load() {
        loading = true; defer { loading = false }
        var values: [String: String]? = nil
        var file: SettingsFile? = nil
        if storage == .folder {
            if let data = try? Data(contentsOf: fileURL), let f = try? JSONDecoder().decode(SettingsFile.self, from: data) {
                file = f; values = f.values
                lastFileStamp = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
                syncNote = "已讀取 \(fileURL.path)（\(f.updated)，來自 \(f.updatedBy)）"
            } else {
                syncNote = "資料夾裡還沒有 settings.json，之後修改設定時會自動建立：\(fileURL.path)"
            }
        }
        if values == nil, let local = d.dictionary(forKey: "values") as? [String: String] { values = local }
        if let values { apply(values) }
        sttAPIKey = file?.secrets?["sttAPIKey"] ?? Keychain.get("sttAPIKey") ?? sttAPIKey
        llmAPIKey = file?.secrets?["llmAPIKey"] ?? Keychain.get("llmAPIKey") ?? llmAPIKey
    }

    /// 另一台電腦改了同步檔，這台回到前景時重新讀取
    func reloadIfChanged() {
        guard storage == .folder, pendingSave == nil,
              let m = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date,
              m != lastFileStamp else { return }
        load()
    }

    private func changed() {
        guard !loading else { return }
        pendingSave?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    func save() {
        pendingSave?.cancel(); pendingSave = nil
        let snap = snapshot()
        d.set(snap, forKey: "values")                         // 本機永遠留一份
        Keychain.set("sttAPIKey", sttAPIKey)
        Keychain.set("llmAPIKey", llmAPIKey)
        guard storage == .folder else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var f = SettingsFile()
            f.updated = ISO8601DateFormatter().string(from: Date())
            f.updatedBy = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            f.values = snap
            if keysInFolder { f.secrets = ["sttAPIKey": sttAPIKey, "llmAPIKey": llmAPIKey] }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(f).write(to: fileURL, options: .atomic)
            lastFileStamp = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
            syncNote = "已儲存到 \(fileURL.path)"
        } catch {
            syncNote = "寫入設定檔失敗：\(error.localizedDescription)"
        }
    }

    var genre: Genre { Genre.find(genreID) }

    func config(extraPrompt: String = "") -> PipelineConfig {
        var c = PipelineConfig()
        c.sttBaseURL = sttBaseURL; c.sttModel = sttModel; c.sttAPIKey = sttAPIKey; c.sttLanguage = sttLanguage; c.sttUsePrompt = sttUsePrompt
        c.llmBaseURL = llmBaseURL; c.llmModel = llmModel; c.llmAPIKey = llmAPIKey
        c.llmTemperature = llmTemperature; c.llmDisableThinking = llmDisableThinking
        c.chunkChars = max(2000, chunkChars); c.audioChunkMinutes = max(1, audioChunkMinutes)
        c.detail = detail; c.outputLanguage = outputLanguage; c.timestamps = timestamps
        c.extraPrompt = extraPrompt
        c.outputDir = (outputDir as NSString).expandingTildeInPath; c.formats = formats; c.includeTranscript = includeTranscript; c.keepAudio = keepAudio; c.autoTitle = autoTitle
        c.ytdlpPath = ytdlpPath; c.ytdlpExtraArgs = ytdlpExtraArgs
        return c
    }
}
