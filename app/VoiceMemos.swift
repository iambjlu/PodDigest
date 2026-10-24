// app/VoiceMemos.swift
// 讀取 Mac「語音備忘錄」的錄音清單（CloudRecordings.db），讓使用者多選匯入。
import Foundation
import SQLite3

struct VoiceMemo: Identifiable, Hashable {
    let id: String
    let title: String
    let date: Date
    let duration: Double
    let url: URL
}

enum VoiceMemos {
    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings")
    }

    static let accessHint = "沒有權限讀取語音備忘錄。請到「系統設定 › 隱私權與安全性 › 完整磁碟取用權限」加入 PodDigest 後重開，或改用「加入音訊／影片檔…」手動選擇。"

    /// 只列出已下載到這台 Mac 的錄音（只存在 iCloud 的沒有檔案，略過），新的在前
    static func load() throws -> (memos: [VoiceMemo], skipped: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { throw AppError("找不到語音備忘錄的資料夾（這台 Mac 可能沒有使用語音備忘錄）") }
        guard (try? fm.contentsOfDirectory(atPath: dir.path)) != nil else { throw AppError(accessHint) }

        var memos: [VoiceMemo] = []
        var skipped = 0
        var db: OpaquePointer?
        let dbPath = dir.appendingPathComponent("CloudRecordings.db").path
        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            defer { sqlite3_close(db) }
            var st: OpaquePointer?
            // 標題在 ZENCRYPTEDTITLE（純文字）；ZCUSTOMLABEL 常是 ISO 時間字串，不能當標題
            let sql = "SELECT ZENCRYPTEDTITLE, ZCUSTOMLABELFORSORTING, ZCUSTOMLABEL, ZDATE, ZDURATION, ZPATH FROM ZCLOUDRECORDING ORDER BY ZDATE DESC"
            if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK {
                defer { sqlite3_finalize(st) }
                while sqlite3_step(st) == SQLITE_ROW {
                    func text(_ i: Int32) -> String? {
                        guard sqlite3_column_type(st, i) == SQLITE_TEXT, let c = sqlite3_column_text(st, i) else { return nil }
                        let t = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.isEmpty ? nil : t
                    }
                    guard let path = text(5) else { continue }
                    let file = dir.appendingPathComponent((path as NSString).lastPathComponent)
                    guard fm.fileExists(atPath: file.path) else { skipped += 1; continue }
                    let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(st, 3))
                    let title = [text(0), text(1), text(2)].compactMap { $0 }
                        .first { $0.range(of: #"^\d{4}-\d{2}-\d{2}T"#, options: .regularExpression) == nil }
                        ?? file.deletingPathExtension().lastPathComponent
                    memos.append(VoiceMemo(id: file.path, title: title, date: date,
                                           duration: sqlite3_column_double(st, 4), url: file))
                }
            }
        }
        // 資料庫沒列到、但資料夾裡有的 .m4a 也補上（資料庫讀不到時就全靠這個）
        let known = Set(memos.map(\.id))
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for f in files where f.pathExtension.lowercased() == "m4a" && !known.contains(f.path) {
            let d = (try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            memos.append(VoiceMemo(id: f.path, title: f.deletingPathExtension().lastPathComponent, date: d, duration: 0, url: f))
        }
        memos.sort { $0.date > $1.date }
        return (memos, skipped)
    }
}
