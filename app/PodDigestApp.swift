// app/PodDigestApp.swift
// PodDigest：把本地音訊、YouTube 影片／播放清單整理成重點（Markdown／HTML／PDF）。
import AppKit
import SwiftUI
import UserNotifications

/// 主視窗是否開著、佇列是否在忙：給 AppDelegate 決定要不要結束
@MainActor
enum AppState {
    static var windowOpen = false
    static weak var queue: JobQueue?
    static var quitWhenDone = false
}

/// 系統通知：每個項目完成／失敗各一則；App 在前景也顯示橫幅；點通知在 Finder 顯示輸出檔
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, files: [URL] = []) {
        let n = UNMutableNotificationContent()
        n.title = title
        n.body = body
        n.sound = .default
        n.userInfo = ["files": files.map(\.path)]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let paths = response.notification.request.content.userInfo["files"] as? [String] ?? []
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        DispatchQueue.main.async {
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            else { NSApp.activate(ignoringOtherApps: true) }
            completionHandler()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        super.init()
        Notifier.shared.setup()      // 越早設定 delegate 越好：點通知把 App 叫起來時才接得到
        // 關掉主視窗 → Dock 圖示消失、只留選單列（不管有沒有在處理）
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow, !(w is NSPanel), w.canBecomeMain else { return }
            MainActor.assumeIsolated {
                AppState.windowOpen = false
                NSApp.setActivationPolicy(.accessory)
                guard let q = AppState.queue else { return }
                if !(q.isBusy || q.pending > 0) && AppState.quitWhenDone { NSApp.terminate(nil) } else { q.lingering = true }
            }
        }
    }

    // 關掉視窗不結束，App 留在選單列（要結束用選單列的「結束」或 ⌘Q）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let q = AppState.queue, q.isBusy || q.pending > 0 else { AppState.queue?.persistNow(); return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "還有項目處理中，確定要結束嗎？"
            alert.informativeText = "沒做完的項目會保留，下次開啟 PodDigest 時自動從頭繼續。"
            alert.addButton(withTitle: "繼續處理")
            alert.addButton(withTitle: "結束")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn { q.persistNow(); return .terminateNow }
            return .terminateCancel
        }
    }
}

@main
struct PodDigestApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var queue: JobQueue
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        let s = SettingsStore()
        let q = JobQueue(settings: s)
        _settings = StateObject(wrappedValue: s)
        _queue = StateObject(wrappedValue: q)
        AppState.queue = q
        AppState.quitWhenDone = s.quitWhenDone
        q.onFinished = { done, failed in
            // 視窗已經關掉、只剩選單列：依設定決定做完要不要結束（預設不結束，留在選單列待命）
            guard !AppState.windowOpen, done + failed > 0 else { return }
            if s.quitWhenDone {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { NSApp.terminate(nil) }   // 多等一下讓最後一則通知送出
            } else {
                q.lingering = true
            }
        }
        Task { @MainActor in q.restore() }
    }

    var body: some Scene {
        Window("PodDigest", id: "main") {
            MainWindow(queue: queue, settings: settings)
                .frame(minWidth: 820, minHeight: 600)
                .onAppear {
                    AppState.windowOpen = true
                    queue.lingering = false
                    NSApp.setActivationPolicy(.regular)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    settings.reloadIfChanged()
                }
                .onReceive(settings.$quitWhenDone) { AppState.quitWhenDone = $0 }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    settings.save()
                }
        }
        .defaultSize(width: 1000, height: 720)

        // 有項目處理或排隊時才出現在選單列，全部做完就消失
        MenuBarExtra(isInserted: .constant(queue.isBusy || queue.pending > 0 || queue.lingering)) {
            MenuContent(queue: queue)
        } label: {
            MenuLabel(queue: queue)
        }
        .menuBarExtraStyle(.window)
    }
}

enum AppPrefs {
    static let diagnosticKey = "diagnosticLogging"          // 診斷模式：預設關閉＝日誌只顯示、不寫檔
}

/// 診斷日誌檔（只有「診斷模式」打開時才寫；平常日誌只留在記憶體的 500 行環狀緩衝）。
enum DiagnosticLog {
    static let maxBytes = 5 * 1024 * 1024
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PodDigest")
    }
    static var file: URL { directory.appendingPathComponent("diagnostic.log") }
    private static let queue = DispatchQueue(label: "tw.iambjlu.PodDigest.diaglog", qos: .utility)
    nonisolated(unsafe) private static var handle: FileHandle?

    static var enabled: Bool { UserDefaults.standard.bool(forKey: AppPrefs.diagnosticKey) }

    static func write(_ line: String) {
        guard enabled else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if handle == nil {
                    if !FileManager.default.fileExists(atPath: file.path) {
                        FileManager.default.createFile(atPath: file.path, contents: nil)
                    }
                    handle = try FileHandle(forWritingTo: file)
                }
                if let size = try handle?.seekToEnd(), size > UInt64(maxBytes) {
                    try handle?.close()
                    handle = nil
                    let old = directory.appendingPathComponent("diagnostic.1.log")
                    try? FileManager.default.removeItem(at: old)
                    try FileManager.default.moveItem(at: file, to: old)
                    FileManager.default.createFile(atPath: file.path, contents: nil)
                    handle = try FileHandle(forWritingTo: file)
                }
                try handle?.write(contentsOf: Data("\(stamp) \(line)\n".utf8))
            } catch { handle = nil }
        }
    }

    static func close() { queue.async { try? handle?.close(); handle = nil } }
}


/// 選單列圖示：處理中是波形加整體百分比，待命時是 App 的圖示。
/// 直接觀察佇列（佇列會轉發各項目的進度變動），不用計時器強制重畫，所以圖示不會一直閃動
struct MenuLabel: View {
    @ObservedObject var queue: JobQueue

    var body: some View {
        if queue.isBusy || queue.pending > 0 {
            HStack(spacing: 4) {
                Image(systemName: queue.held ? "pause.fill" : "waveform")
                Text("\(Int(queue.overallProgress * 100))%").monospacedDigit()
            }
        } else {
            Image(systemName: "text.badge.checkmark")
        }
    }
}
