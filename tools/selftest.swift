// tools/selftest.swift — 不開 UI 的端對端測試：swiftc app/{Settings,Genre,Net,Media,Summarizer,Markdown,Exporter,Pipeline}.swift tools/selftest.swift
// 用法：selftest <音檔> <輸出資料夾> <stt/llm 網址>
import AppKit
import Foundation

@main
struct SelfTest {
    static func main() {
        let a = CommandLine.arguments
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            var cfg = PipelineConfig()
            let env = ProcessInfo.processInfo.environment
            cfg.sttBaseURL = a[3]; cfg.llmBaseURL = a[3]; cfg.llmModel = env["LLM_MODEL"] ?? "mock-llm"; cfg.sttModel = env["STT_MODEL"] ?? "mock-whisper"
            cfg.sttAPIKey = env["STT_KEY"] ?? ""; cfg.llmAPIKey = env["LLM_KEY"] ?? ""; cfg.llmDisableThinking = env["NOTHINK"] != nil
            cfg.outputDir = a[2]; cfg.sttUsePrompt = ProcessInfo.processInfo.environment["PROMPT"] != nil; cfg.formats = Set(OutputFormat.allCases); cfg.includeTranscript = true
            cfg.audioChunkMinutes = Int(env["CHUNK_MIN"] ?? "1")!; cfg.chunkChars = Int(ProcessInfo.processInfo.environment["CHUNK"] ?? "2000")!; 
            let input = JobInput(title: "測試：時間管理/Podcast", source: a[1].contains(",") ? .files(a[1].split(separator: ",").map { URL(fileURLWithPath: String($0)) }) : .file(URL(fileURLWithPath: a[1])), genre: Genre.find(a.count > 4 ? a[4] : "podcast"), custom: "", folder: nil)
            do {
                let out = try await Pipeline.run(input, cfg: cfg, report: { s, p, m in print(String(format: "[%@ %.2f] %@", s.rawValue, p, m)) }, log: { print("log:", $0) })
                print("OK duration", out.duration, "files", out.files.map(\.lastPathComponent))
                if env["NOAGAIN"] != nil { exit(0) }
                // 再做一份：沿用逐字稿、換類型與格式
                let box = OptionsBox(BatchOptions(genre: Genre.find("lecture"), extra: "多用表格", detail: .detailed, formats: [.md, .transcript]))
                let again = try await Pipeline.regenerate(input, prior: out, cfg: cfg, box: box, report: { s, p, m in print(String(format: "[again %@ %.2f] %@", s.rawValue, p, m)) })
                print("AGAIN files", again.files.map(\.lastPathComponent), again.doc.meta.first?.1 ?? "")
            } catch { print("FAIL", error.localizedDescription) }
            exit(0)
        }
        app.run()
    }
}
