# PodDigest 架構說明

原生 SwiftUI Mac App（macOS 14+），用 `swiftc` 直接編譯，沒有 Xcode 專案或第三方套件。把本地音訊／影片與 YouTube 連結轉成逐字稿，再交給外部 LLM 整理成 Markdown／HTML／PDF／TXT。語音模型與 LLM 都是外部的 OpenAI 相容服務，App 本身不含任何模型。

> 使用方式與功能介紹見 `README.md`；本文件只講程式結構與資料流，改動程式前先讀這份。

## 1. 目錄結構

```
PodDigest/
├── app/                    所有 Swift 原始碼（build_app.sh 以 app/*.swift 一次編譯）
│   ├── PodDigestApp.swift  入口、AppDelegate、通知、診斷日誌、選單列圖示
│   ├── Views.swift         全部 SwiftUI 介面
│   ├── Jobs.swift          工作佇列、佇列保存／還原、排程迴圈
│   ├── Pipeline.swift      單一項目的流程（取音訊→切段→轉文字→整理→輸出）
│   ├── Media.swift         檔案蒐集、外部程式執行、音訊切段、yt-dlp
│   ├── Net.swift           STT／LLM 的 OpenAI 相容客戶端
│   ├── Summarizer.swift    逐字稿 → 重點（分段、分層合併、自動偵測類型）
│   ├── Genre.swift         內容類型與各自的提示詞／輸出範本
│   ├── Markdown.swift      自製 Markdown → HTML 轉換
│   ├── Exporter.swift      輸出 md／html／pdf／txt／逐字稿，PDF 渲染
│   ├── Convert.swift       「轉換 Markdown」功能（既有 .md → HTML／PDF／TXT）
│   ├── VoiceMemos.swift    讀取 Mac 語音備忘錄清單
│   └── Settings.swift      設定、鑰匙圈、同步資料夾、PipelineConfig
├── tools/
│   ├── selftest.swift      不開 UI 的端對端測試
│   └── make_icon.swift     產生 App 圖示 PNG
├── vendor/yt-dlp           內建的 yt-dlp 執行檔（打包進 App）
├── build_app.sh            編譯並打包 build/PodDigest.app
├── install_app.sh          編譯 → 結束舊版 → 換掉 /Applications/PodDigest.app → 開啟
├── README.md               使用說明
└── CLAUDE.md               專案規則
```

## 2. 整體資料流

```
 來源                          Jobs.swift                Pipeline.swift                       外部服務
 ───────                      ────────────              ─────────────────                    ──────────
 拖入／選擇檔案或資料夾 ─┐
 語音備忘錄多選匯入     ─┼─▶ JobQueue.addFiles/addMerged ─▶ Job(stage=.queued)
 貼上 YouTube 連結      ─┘   JobQueue.addLinks（先 YouTube.expand）
                                      │
                                      ▼ kick() 逐一取出
                              JobQueue.process(job, phase)
                                      │
              ┌───────────────────────┼─────────────────────────────┐
              ▼                       ▼                             ▼
     Pipeline.transcribe      Pipeline.finish              Pipeline.regenerate
     1 取得音訊（yt-dlp）      4 自動偵測類型（可選）          沿用 prior 逐字稿
     2 AudioPrep.chunks        5 Summarizer.summarize  ─▶ LLM  /chat/completions
     3 STTClient.transcribe ─▶ 6 Exporter.write
        /audio/transcriptions     （md/html/pdf/txt/逐字稿）
```

## 3. 各檔案說明

### 3.1 `PodDigestApp.swift`：入口與常駐行為
- `PodDigestApp`（`@main`）建立 `SettingsStore` 與 `JobQueue`，場景為一個主 `Window` 加一個 `MenuBarExtra`。啟動時呼叫 `queue.restore()` 接續上次未完成的項目。
- `MenuBarExtra` 只在 `isBusy || pending > 0 || lingering` 時顯示；圖示 `MenuLabel` 處理中是波形加整體百分比，待命時是 App 圖示。
- `AppState`：全域旗標（主視窗是否開著、佇列參照、`quitWhenDone`）。
- `AppDelegate`：
  - 關掉主視窗 → 切成 `.accessory`（Dock 圖示消失，只留選單列）；若沒有工作且 `quitWhenDone` 則結束，否則 `lingering = true`。
  - `applicationShouldTerminate`：還有處理中或排隊的項目時跳確認視窗，確認結束前先 `persistNow()`。
  - 視窗回到前景時 `settings.reloadIfChanged()` 重新讀取同步設定。
- `Notifier`：系統通知（完成／失敗），點通知在 Finder 顯示輸出檔。
- `DiagnosticLog`：診斷日誌檔（`~/Library/Logs/PodDigest/diagnostic.log`，超過 5 MB 輪替成 `diagnostic.1.log`）。**只有 `AppPrefs.diagnosticKey` 打開時才寫檔**；平常日誌只留在 `JobQueue.logs` 的 500 行記憶體環狀緩衝。

### 3.2 `Views.swift`：介面
`MainWindow` 是三個分頁：
- **工作台** `WorkbenchView`：加入來源（拖放、檔案選擇、語音備忘錄、YouTube 連結）、內容類型／詳細程度／輸出格式選擇、佇列清單（`JobRow`，左邊有核取方塊；標題列有全選、刪除選取、暫停／繼續，清單按 Delete 鍵刪除勾選項，沒勾選則刪目前選取的）、右側 `JobDetail`（結果預覽、版本切換、即時逐字稿 `LiveView`、`OptionsEditor` 可在做完前改設定）。
- **設定** `SettingsView`：STT／LLM 位址模型金鑰、連線測試、輸出、處理方式、同步資料夾、yt-dlp 更新、診斷模式開關。
- **日誌** `LogView`：顯示 `queue.logs`。

其他視圖：`AskSheet`（每次加入前詢問類型與格式）、`MergeSheet`（多段錄音合併排序）、`VoiceMemosSheet`、`ConvertSheet`（轉換 Markdown）、`HTMLView`（WKWebView 預覽）、`ReadOnlyText`、`MenuContent`（選單列面板）。`AddRequest` 描述一次待確認的加入動作（files／links／merged）。

### 3.3 `Jobs.swift`：工作佇列
- `Job`（`@MainActor ObservableObject`）：一個項目的狀態——`stage`、`progress`、`detail`、`versions`（每「再做一份」多一版，逐字稿共用）、`liveLines`（即時逐字稿，上限 400 行）、`jobLog`（上限 300 行）、`transcript`（分階段模式暫存）。`options` 變動會同步寫入 `OptionsBox`。
- `JobQueue`：
  - 加入：`addFiles`（逐檔一項）、`addMerged`（多檔接成一項）、`addLinks`（先用 `YouTube.expand` 展開播放清單，再逐部加入）。
  - 排程：`kick()` 啟動單一 `runner` 迴圈，**一次只處理一個項目**。優先取 `.queued`，沒有才取 `.awaiting`（`phase = .finishOnly`）。
  - `process(_:phase:)`：依 `Phase` 呼叫 `Pipeline`——
    - `.full`：`Pipeline.run`（轉文字 + 整理 + 輸出）
    - `.transcribeOnly`（`BatchMode.sttFirst` 且非再做一份）：只轉文字，存入 `job.transcript`，stage 設為 `.awaiting`、進度 0.55
    - `.finishOnly`：對 `.awaiting` 的項目用暫存逐字稿呼叫 `Pipeline.finish`
    - 再做一份（`regen`）：`Pipeline.regenerate`
  - 全域暫停：`paused` 為真時排程迴圈不再取出新項目（進行中的做完為止）；暫停結束的迴圈不觸發 `onFinished`。`pause()`／`resume()` 切換。
  - 批量刪除：`checked` 是清單左邊核取方塊勾選的項目 ID，`removeChecked()` 取消並移除全部勾選項。
  - 控制：`cancel`、`retry`、`retryAll`、`rerun`（沿用逐字稿再整理）、`retranscribe`（丟掉逐字稿重來）、`remove`、`clearFinished`、`cancelAll`。
  - `overallProgress`：未完成與已完成項目進度平均，給選單列顯示。
- **佇列保存**：`SavedJob` 只含來源與選項（不含 API Key 與結果），`QueueStore` 存到 `~/Library/Application Support/PodDigest/queue.json`；全部做完（沒有待辦）就刪檔。`persistSoon()` 延遲 0.5 秒合併寫入，`persistNow()` 立即寫（結束 App 前呼叫）。`done`、`cancelled` 的項目不保存；處理中斷的會從頭再做。

### 3.4 `Pipeline.swift`：單項流程（UI 無關，可獨立測試）
型別：`JobSource`（`.file`／`.files`／`.remote`）、`Stage`（queued、awaiting、downloading、preparing、transcribing、summarizing、exporting、done、failed、cancelled；`pending`＝queued 或 awaiting，`running`＝中間五個）、`JobInput`、`BatchOptions`、`PipelineOutput`、`Transcript`、`Report`（進度回呼）。

`OptionsBox`：用鎖保護的 `BatchOptions` 容器。流程在**每個階段開始時才讀**，所以處理途中改類型、詳細程度、額外要求或輸出格式，還沒走到的階段會吃到新設定。

`Pipeline` 的函式：
- `run`：`transcribe` → `finish`。
- `transcribe`：
  1. 取得音訊：本地檔案直接用；`.files` 依序接成一份；`.remote` 用 `YouTube.download` 下載；`cfg.keepAudio` 開啟時把下載的音訊直接移到輸出子資料夾（`Pipeline.outputDir`）保留，否則用完即刪。
  2. 切段：每個檔案呼叫 `AudioPrep.chunks`，多檔的時間軸（offset）接在一起，並在逐字稿插入「【第 n／m 段：檔名】」分隔。
  3. 逐段呼叫 `STTClient.transcribe`；有分句時間用 `Summarizer.timestampedLines`（約 30 秒一行），沒有就用 `paragraphs`（約 300 字一段）。可選帶上類型的 `sttHint` 與上一段結尾 60 字當提示詞。
  4. 驗證：沒有任何內容或少於 20 字會丟出錯誤。
  - 暫存音訊放在 `temporaryDirectory/PodDigest-<UUID>`，`defer` 結束即刪；每段送出後也立刻刪。
- `finish`：此時才讀 `OptionsBox`；類型為 `auto` 時先 `Summarizer.detect`；`cfg.timestamps` 關閉則 `stripStamp` 去掉時間標記；呼叫 `Summarizer.summarize`；組成 `DigestDoc`（meta：類型、長度、來源、整理時間、語音模型、LLM）；輸出到 `outputDir[/播放清單]/<標題>/`，再 `Exporter.write`。`base` 參數讓進度條從 0.55（完整流程）或 0（再做一份）開始。
- `cleanStaleTemp`：啟動時（`JobQueue.restore` 一開始、尚未處理任何項目）刪除 `temporaryDirectory` 下殘留的 `PodDigest-*` 暫存資料夾（上次被強制結束時 `defer` 沒機會執行）。
- `regenerate`：取 `prior.transcript` 呼叫 `finish`，不重新轉文字。

### 3.5 `Media.swift`：音訊與外部程式
- `MediaKinds.collect`：展開檔案／資料夾（遞迴、略過隱藏檔），只留支援的音訊／影片副檔名，資料夾內依檔名自然排序。
- `Tool`：尋找與執行外部程式。`find` 的優先順序：設定頁指定路徑 → `~/Library/Application Support/PodDigest/bin`（更新版）→ App 內 `Contents/Resources/bin`（內建版）→ `/opt/homebrew/bin`、`/usr/local/bin`、`~/.local/bin`、`/usr/bin`。`run` 以 `Process` 執行，stdout／stderr 逐行回呼，任務取消時終止行程；輸出文字緩衝超過 20 萬字會截半，避免記憶體無限成長。
- `AudioPrep.chunks`：用 AVFoundation 讀取，切成 N 分鐘一段、16 kHz 單聲道 AAC（32 kbps）的 m4a；AVFoundation 讀不了的格式退回 `ffmpeg`／`ffprobe`（可選安裝，不內建）。每段獨立編碼，不會把整個檔案載入記憶體。
- `YouTube`：`expand`（`yt-dlp --flat-playlist --dump-json` 展開成 `RemoteItem`；網址帶 `v=`／`youtu.be/` 一律只處理該支影片，只有純 `playlist?list=` 才展開整份清單）、`download`（抓 `bestaudio[ext=m4a]`，解析 `[download] xx%` 回報進度）、`update`（從 GitHub releases 下載新版到 Application Support）、`version`。

### 3.6 `Net.swift`：外部服務客戶端
- `Net.session`：`ephemeral` 設定（不寫快取到硬碟），單次請求逾時 1800 秒、整體 7200 秒。
- `Net.endpoint`：整理使用者填的網址，缺 scheme 補 `http://`，只有 host 時補 `/v1`。
- `Net.send`：遇到 429、5xx 或連線中斷／逾時自動重試（最多 3 次，間隔 2、4 秒）；支援取消。
- `Net.listModels`：`GET /models`，給連線測試與取得模型清單。
- `STTClient`：`POST /audio/transcriptions`（multipart）。先要 `verbose_json`（含分句時間），伺服器回 400／422 就退回 `json`。Whisper 在靜音時會把提示詞回吐，`stripEcho`／`isEcho` 濾掉；濾完沒剩就不帶提示詞重試一次。
- `LLMClient.chat`：`POST /chat/completions`（非串流）。沒填模型時取 `/models` 第一個；`llmDisableThinking` 會帶 `chat_template_kwargs.enable_thinking=false`；`stripThink` 移除 `<think>` 區塊；空回應丟錯誤並提示。

### 3.7 `Summarizer.swift`：逐字稿 → 重點
- `split`：依 `chunkChars`（預設 8000 字，下限 2000）切逐字稿，不拆行；超長行在標點處硬切。
- `summarize`：
  - 只有一份 → 單次呼叫，直接套類型範本。
  - 多份 → ①逐段整理筆記（用類型的 `mapFocus`）→ ②筆記總長超過 `chunkChars × 1.6` 時分層合併（最多 4 層，無法再合併就停）→ ③依類型範本輸出最終版本。
  - 時間標記開啟時要求在重點後以「（mm:ss）」標註出處。
  - 「自訂」類型與「額外要求」都會被放進提示詞並標示優先遵守。
- `detect`：自動偵測。取開頭、中段、結尾各一小段（合計約 5000 字）交給 LLM（溫度 0）分類，只能回覆類型代號；失敗或看不出來當 Podcast。
- `systemPrompt`：固定規則（輸出語言、不編造、修正同音字、不要 H1）加上詳細程度說明。

### 3.8 `Genre.swift`：內容類型
每個 `Genre` 有 `sttHint`（給語音模型）、`mapFocus`（分段階段抓什麼）、`template`（最終 Markdown 結構）。現有類型：`auto`（自動偵測）、`podcast`、`lecture`（上課重點）、`chat`（日常談話）、`meeting`（會議紀錄）、`interview`（訪談）、`talk`（演講／影片）、`custom`（自訂）。`Genre.detectable` 是自動偵測可選的 6 種（不含 auto 與 custom）；`Genre.find` 找不到時回 Podcast。新增類型：加一個 `static let`，並放進 `Genre.all`（要被自動偵測的再加進 `detectable`）。

### 3.9 `Markdown.swift`：Markdown → HTML
自製的小型轉換器，支援標題、巢狀清單、表格、引用、程式碼區塊、粗斜體、刪除線、連結、自動連結，並把「（mm:ss）」包成 `ts` 樣式。`render` 回傳 HTML 與標題清單（供目錄使用）；`slug` 產生不重複的錨點 ID。

### 3.10 `Exporter.swift`：輸出
- `DigestDoc`：標題、meta 列、內文 Markdown、逐字稿行、是否附逐字稿。
- `markdown`（`# 標題` + `- **欄位**：值` + `---` + 內文，可附「附錄：逐字稿」）、`plainText`（去 Markdown 符號，標題用【】）、`transcriptText`、`html`（單檔 HTML，含樣式與 JS，`forPrint` 為 PDF 版，`toc` 時有目錄抽屜／搜尋／上下章）。
- `write`：依 `OutputFormat` 寫出檔案（`md`、`html`、`pdf`、`txt`、`transcript`），檔名衝突時在檔名加編號；`safeName` 清掉非法字元並限 80 字。
- `PDFRenderer`：離螢幕的 `WKWebView` 載入 HTML，用 `NSPrintOperation` 存成 A4 PDF。

### 3.11 `Convert.swift`：轉換 Markdown
`Converter.load` 讀取 .md，解析標題與 PodDigest 輸出的資訊列（`- **類型**：…` 後接 `---`）。`convertEach` 每個檔案各轉一份（各一個子資料夾）；`convertBook` 合併成一本，每個檔案一個章節。不需要 LLM 與語音服務。

### 3.12 `VoiceMemos.swift`
以 SQLite3 唯讀開啟 `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db`，列出已下載到本機的錄音（僅存在 iCloud 的略過並計入 `skipped`）；資料庫讀不到時退回掃資料夾內的 .m4a。沒有權限時提示授予「完整磁碟取用權限」。

### 3.13 `Settings.swift`：設定
- `Keychain`：API Key 存鑰匙圈（service `tw.iambjlu.PodDigest`）。
- `OutputFormat`、`BatchMode`（`perItem` 逐個完成／`sttFirst` 先全部轉文字再整理）、`DetailLevel`（精簡／標準／詳細）、`Presets`（常用服務的網址與模型預設）。
- `PipelineConfig`：一次處理需要的所有設定，為值型別，可安全丟進背景工作；`SettingsStore.config(extraPrompt:)` 產生。
- `SettingsStore`：
  - 儲存位置兩種：`local`（UserDefaults）／`folder`（同步資料夾的 `settings.json`，第一次執行有 iCloud Drive 就預設 `iCloud Drive/PodDigest`）。UserDefaults 永遠留一份本機副本。
  - `SettingsFile`：`values`（一般設定）與 `secrets`（只有「API Key 也存到資料夾」開啟才寫）。
  - 變動後延遲 0.8 秒存檔；`reloadIfChanged` 比對檔案修改時間，另一台電腦改過就重新讀取。
  - `keepAudio`（保留下載的音訊）在工作台選項列與設定頁都有核取方塊。
  - `ytdlpPath` 與儲存位置相關欄位每台電腦各自記住，不進同步檔。
  - 環境變數 `PD_STT_URL`、`PD_STT_MODEL`、`PD_LLM_URL`、`PD_LLM_MODEL`、`PD_OUT_DIR` 可覆蓋設定（測試用，不會存起來）。

## 4. 建置與測試

- `build_app.sh`：
  1. `swiftc -O -parse-as-library -target <arch>-apple-macos14.0 app/*.swift` 輸出到 `build/PodDigest.app/Contents/MacOS/PodDigest`，錯誤寫入 `build/.build.log`。
  2. 複製 `vendor/yt-dlp` 到 `Contents/Resources/bin/`。
  3. 以 `tools/make_icon.swift` 產生圖示並轉成 `build/AppIcon.icns`（有快取，圖示腳本更新才重做）。
  4. 寫入 `Info.plist`（Bundle ID `tw.iambjlu.PodDigest`、最低 macOS 14.0）。
  5. 以 ad-hoc 簽章簽 yt-dlp 與整個 App。
- `install_app.sh`：先呼叫 `build_app.sh`，結束執行中的 PodDigest（最多等 15 秒），取代 `/Applications/PodDigest.app` 後開啟，並確認行程在跑。
- `tools/selftest.swift`：不開 UI 的端對端測試，直接呼叫 `Pipeline.run` 與 `Pipeline.regenerate`。用法與編譯指令在檔頭；參數為 `<音檔> <輸出資料夾> <stt/llm 網址> [類型]`，環境變數 `LLM_MODEL`、`STT_MODEL`、`CHUNK_MIN`、`CHUNK` 等可調整。

## 5. 資源使用原則（改動時須遵守）

- **少寫硬碟**：圖片、檔案、暫存資料優先在記憶體處理。目前會落地的只有：切段後的暫存音訊（用完即刪）、`queue.json`（沒待辦就刪）、設定檔、使用者要的輸出檔。
- **日誌預設不寫檔**：只留在記憶體的 500 行環狀緩衝；要寫檔必須經過設定頁「診斷模式」，關閉時完全不寫。
- **記憶體上限**：目標機器可能只有 8 GB。大量資料要限制大小、分批或串流：逐字稿即時預覽 400 行、項目日誌 300 行、全域日誌 500 行、外部程式輸出緩衝 20 萬字、音訊每次只編碼一段、上傳用 `mappedIfSafe`。

## 6. 狀態與執行緒模型

- UI 狀態（`Job`、`JobQueue`、`SettingsStore` 的發佈屬性）都在 main actor；`Pipeline`、`Summarizer`、`Net` 是無狀態的 `enum` 靜態函式，透過 `async/await` 在背景執行，進度經 `Report` 回呼切回 main actor 更新。
- 取消：`Job` 的處理放在一個 `Task` 內，`JobQueue.cancel` 取消它；各階段用 `Task.checkCancellation()` 與 `Tool.run` 的取消處理器終止外部行程。
- 項目一次只跑一個（`runner` 單一迴圈）；佇列清空時呼叫 `onFinished`，由 `PodDigestApp` 決定是否結束 App 或留在選單列待命。
