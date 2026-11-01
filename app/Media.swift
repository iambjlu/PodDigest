// app/Media.swift
// 音訊前處理（AVFoundation，必要時退回 ffmpeg）與 YouTube 下載（yt-dlp）。
import AVFoundation
import Foundation

enum MediaKinds {
    static let exts: Set<String> = ["mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "caf", "mp4", "mov", "m4v",
                                    "webm", "mkv", "ogg", "opus", "wma", "amr", "3gp", "mpeg", "mpg", "mpga", "m4b"]

    /// 展開檔案／資料夾（資料夾遞迴），只留音訊與影片
    static func collect(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let all = (fm.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?.allObjects as? [URL]) ?? []
                let sub = all.filter { exts.contains($0.pathExtension.lowercased()) }
                out += sub.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if exts.contains(u.pathExtension.lowercased()) {
                out.append(u)
            }
        }
        return out
    }
}

// MARK: - 外部程式

enum Tool {
    static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", "/usr/bin"]

    /// App 內建的外部程式（Contents/Resources/bin）
    static var bundled: URL? { Bundle.main.resourceURL?.appendingPathComponent("bin") }
    /// 「更新 yt-dlp」下載的新版（App 本體不動，簽章不會壞）
    static var updated: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PodDigest/bin")
    }

    static func find(_ name: String, custom: String = "") -> String? {
        let c = custom.trimmingCharacters(in: .whitespaces)
        if !c.isEmpty, FileManager.default.isExecutableFile(atPath: c) { return c }
        for dir in [updated, bundled].compactMap({ $0 }) {
            let p = dir.appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        for d in searchDirs {
            let p = d + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchDirs + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        env["LANG"] = "en_US.UTF-8"
        env["PYTHONIOENCODING"] = "utf-8"
        return env
    }

    /// 執行外部程式。onLine 會逐行收到 stdout／stderr；工作被取消時會終止行程。
    @discardableResult
    static func run(_ exe: String, _ args: [String], onLine: (@Sendable (String) -> Void)? = nil) async throws -> (status: Int32, out: String) {
        // 全域暫停時終止行程，繼續後重新執行（yt-dlp 會從已下載的部分續傳）
        try await PauseGate.interruptible { try await runOnce(exe, args, onLine: onLine) }
    }

    private static func runOnce(_ exe: String, _ args: [String], onLine: (@Sendable (String) -> Void)?) async throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let box = LineBox(onLine)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { return }
            box.feed(d)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                p.terminationHandler = { proc in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty { box.feed(rest) }
                    cont.resume(returning: (proc.terminationStatus, box.all()))
                }
                do { try p.run() } catch { cont.resume(throwing: AppError("無法執行 \(exe)：\(error.localizedDescription)")) }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
    }

    private final class LineBox: @unchecked Sendable {
        private var buf = Data()
        private var text = ""
        private let lock = NSLock()
        private let cb: (@Sendable (String) -> Void)?
        init(_ cb: (@Sendable (String) -> Void)?) { self.cb = cb }
        func feed(_ d: Data) {
            lock.lock(); defer { lock.unlock() }
            buf.append(d)
            while let i = buf.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: buf[buf.startIndex..<i], as: UTF8.self)
                buf.removeSubrange(buf.startIndex...i)
                if !line.isEmpty { text += line + "\n"; if text.count > 200_000 { text = String(text.suffix(100_000)) }; cb?(line) }
            }
        }
        func all() -> String {
            lock.lock(); defer { lock.unlock() }
            if !buf.isEmpty { text += String(decoding: buf, as: UTF8.self) }
            return text
        }
    }
}

// MARK: - 音訊切段

struct AudioChunk {
    let url: URL
    let offset: Double       // 這一段在原音檔的起始秒數
}

enum AudioPrep {
    /// 把任意音訊／影片切成 N 分鐘一段、16kHz 單聲道 AAC（約 3–4 MB／10 分鐘），放在 tmp 資料夾。
    static func chunks(of src: URL, minutes: Int, tmp: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> (chunks: [AudioChunk], duration: Double) {
        let len = Double(max(1, minutes) * 60)
        let asset = AVURLAsset(url: src)
        var native = false
        var duration = 0.0
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let d = try await asset.load(.duration).seconds
            native = !tracks.isEmpty && d.isFinite && d > 0
            duration = d
        } catch { native = false }

        if !native {
            guard let ffmpeg = Tool.find("ffmpeg") else {
                throw AppError("無法讀取這個檔案的音訊（\(src.pathExtension) 格式 macOS 不支援）。安裝 ffmpeg 後可支援更多格式：brew install ffmpeg")
            }
            duration = try await ffmpegDuration(src)
            return (try await ffmpegChunks(ffmpeg, src, duration, len, tmp, progress), duration)
        }

        var out: [AudioChunk] = []
        var start = 0.0
        var idx = 0
        while start < duration - 0.5 {
            try Task.checkCancellation()
            let l = min(len, duration - start)
            let dst = tmp.appendingPathComponent(String(format: "chunk_%04d.m4a", idx))
            try await encode(asset: asset, start: start, length: l, to: dst)
            out.append(AudioChunk(url: dst, offset: start))
            start += l
            idx += 1
            progress(min(1, start / duration))
        }
        if out.isEmpty { throw AppError("這個檔案沒有可用的音訊") }
        return (out, duration)
    }

    private static func encode(asset: AVURLAsset, start: Double, length: Double, to dst: URL) async throws {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: length, preferredTimescale: 600))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(output) else { throw AppError("無法讀取音訊軌") }
        reader.add(output)

        try? FileManager.default.removeItem(at: dst)
        let writer = try AVAssetWriter(outputURL: dst, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000])
        guard writer.canAdd(input) else { throw AppError("無法建立音訊編碼器") }
        writer.add(input)
        guard reader.startReading() else { throw AppError("讀取音訊失敗：\(reader.error?.localizedDescription ?? "")") }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let q = DispatchQueue(label: "tw.iambjlu.PodDigest.encode")
        final class Gate: @unchecked Sendable { var done = false }
        let gate = Gate()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: q) {
                while input.isReadyForMoreMediaData {
                    if gate.done { return }
                    if let buf = output.copyNextSampleBuffer() {
                        if !input.append(buf) { gate.done = true; reader.cancelReading(); input.markAsFinished(); cont.resume(); return }
                    } else {
                        gate.done = true
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }
        await writer.finishWriting()
        if reader.status == .failed { throw AppError("讀取音訊失敗：\(reader.error?.localizedDescription ?? "")") }
        if writer.status != .completed { throw AppError("音訊編碼失敗：\(writer.error?.localizedDescription ?? "")") }
    }

    private static func ffmpegDuration(_ src: URL) async throws -> Double {
        guard let probe = Tool.find("ffprobe") else { throw AppError("找不到 ffprobe（請安裝 ffmpeg）") }
        let r = try await Tool.run(probe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", src.path])
        guard let d = Double(r.out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last ?? ""), d > 0 else {
            throw AppError("無法取得音訊長度")
        }
        return d
    }

    private static func ffmpegChunks(_ ffmpeg: String, _ src: URL, _ duration: Double, _ len: Double, _ tmp: URL,
                                     _ progress: @escaping @Sendable (Double) -> Void) async throws -> [AudioChunk] {
        var out: [AudioChunk] = []
        var start = 0.0
        var idx = 0
        while start < duration - 0.5 {
            try Task.checkCancellation()
            let dst = tmp.appendingPathComponent(String(format: "chunk_%04d.m4a", idx))
            let r = try await Tool.run(ffmpeg, ["-v", "error", "-y", "-ss", String(start), "-t", String(len), "-i", src.path,
                                                "-vn", "-ac", "1", "-ar", "16000", "-c:a", "aac", "-b:a", "32k", dst.path])
            guard r.status == 0, FileManager.default.fileExists(atPath: dst.path) else {
                throw AppError("ffmpeg 轉檔失敗：\(r.out.suffix(300))")
            }
            out.append(AudioChunk(url: dst, offset: start))
            start += len
            idx += 1
            progress(min(1, start / duration))
        }
        return out
    }
}

// MARK: - YouTube

struct RemoteItem {
    let id: String
    let title: String
    let url: String
    let playlist: String?
}

enum YouTube {
    static func looksLikeURL(_ s: String) -> Bool {
        let t = s.lowercased()
        return t.hasPrefix("http://") || t.hasPrefix("https://")
    }

    static func ytdlp(_ cfg: PipelineConfig) throws -> String {
        guard let p = Tool.find("yt-dlp", custom: cfg.ytdlpPath) else {
            throw AppError("找不到 yt-dlp（App 內建版本遺失）。可在設定頁按「更新 yt-dlp」重新下載，或指定路徑")
        }
        return p
    }

    /// 下載最新版 yt-dlp 到 Application Support（YouTube 常改版，舊版會失效）
    static func update() async throws -> String {
        let url = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
        let (tmp, resp) = try await Net.session.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw AppError("下載失敗") }
        let dir = Tool.updated
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("yt-dlp")
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        _ = try? await Tool.run("/usr/bin/xattr", ["-c", dst.path])
        let v = try await Tool.run(dst.path, ["--version"])
        guard v.status == 0 else { try? FileManager.default.removeItem(at: dst); throw AppError("新版無法執行：\(v.out.suffix(200))") }
        return v.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func version(_ cfg: PipelineConfig) async -> String? {
        guard let exe = Tool.find("yt-dlp", custom: cfg.ytdlpPath),
              let r = try? await Tool.run(exe, ["--version"]), r.status == 0 else { return nil }
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extraArgs(_ cfg: PipelineConfig) -> [String] {
        cfg.ytdlpExtraArgs.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }

    /// 把一個連結展開成影片清單（播放清單會展開成多筆，單支影片就一筆）
    static func expand(_ url: String, cfg: PipelineConfig) async throws -> [RemoteItem] {
        let exe = try ytdlp(cfg)
        // 網址帶有影片（v= 或 youtu.be/）就只處理那支影片；只有純播放清單網址（playlist?list=）才展開整份
        let hasList = url.contains("list="), hasVideo = url.contains("v=") || url.contains("youtu.be/")
        let wantPlaylist = hasList && !hasVideo
        // 只印需要的欄位：單支影片的 --dump-json 含全部格式與字幕網址，常超過 60 萬字，會被輸出緩衝上限截斷而解析失敗
        var args = ["--flat-playlist", "--print", "%(.{id,title,webpage_url,url,playlist_title})j", "--no-warnings",
                    wantPlaylist ? "--yes-playlist" : "--no-playlist"]
        args += extraArgs(cfg)
        args.append(url)
        let r = try await Tool.run(exe, args)
        var items: [RemoteItem] = []
        for line in r.out.split(separator: "\n") where line.hasPrefix("{") {
            guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let id = j["id"] as? String ?? UUID().uuidString
            var link = (j["webpage_url"] as? String) ?? (j["url"] as? String) ?? ""
            if !looksLikeURL(link) { link = "https://www.youtube.com/watch?v=\(id)" }
            let title = (j["title"] as? String) ?? id
            items.append(RemoteItem(id: id, title: title, url: link, playlist: j["playlist_title"] as? String))
        }
        if items.isEmpty {
            let tail = r.out.split(separator: "\n").suffix(3).joined(separator: " ")
            throw AppError("解析連結失敗：\(tail.isEmpty ? "沒有找到影片" : tail)")
        }
        return items
    }

    /// 下載音訊到 dir，回傳檔案路徑。progress 為 0…1
    static func download(_ url: String, to dir: URL, cfg: PipelineConfig, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let exe = try ytdlp(cfg)
        var args = ["--no-playlist", "--no-warnings", "--newline", "--continue",
                    "-f", "bestaudio[ext=m4a]/bestaudio/best", "-o", dir.path + "/yt.%(ext)s"]
        if let ffmpeg = Tool.find("ffmpeg") {
            args += ["--ffmpeg-location", (ffmpeg as NSString).deletingLastPathComponent]
        }
        args += extraArgs(cfg)
        args.append(url)
        let r = try await Tool.run(exe, args) { line in
            // [download]  42.3% of 12.3MiB at ...
            guard line.hasPrefix("[download]"), let pct = line.range(of: #"(\d+(\.\d+)?)%"#, options: .regularExpression) else { return }
            if let v = Double(line[pct].dropLast()) { progress(v / 100) }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard r.status == 0, let f = files.first(where: { $0.lastPathComponent.hasPrefix("yt.") && !$0.lastPathComponent.hasSuffix(".part") }) else {
            let tail = r.out.split(separator: "\n").suffix(3).joined(separator: " ")
            throw AppError("YouTube 下載失敗：\(tail)")
        }
        return f
    }
}
