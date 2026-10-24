# PodDigest

把音訊與 YouTube 影片整理成重點的原生 SwiftUI Mac App（macOS 14+）。語音模型與 LLM 都是**外部**的 OpenAI 相容服務（本機或雲端皆可）。

## 使用
1. `./build_app.sh` 編譯（產生 `build/PodDigest.app`），或 `./install_app.sh` 編譯並安裝到 /Applications。
2. 「設定」頁填語音轉文字與 LLM 的網址／模型／API Key，按「測試連線並取得模型清單」。
3. 「工作台」選內容類型（自動偵測、Podcast、上課重點、日常談話、會議紀錄、訪談、演講／影片、自訂）與詳細程度，然後：
   - 拖入或選擇音訊／影片檔或資料夾，或
   - 按「語音備忘錄…」從 Mac 語音備忘錄多選匯入（第一次可能需要在系統設定給 PodDigest「完整磁碟取用權限」），或
   - 貼上 YouTube 影片／播放清單連結（一行一個）。
   設定頁打開「每次加入時詢問內容類型與輸出格式」，每次加入前會跳出視窗讓你選類型、詳細程度與輸出格式。
4. 自動依序處理；結果在視窗內預覽，並輸出 Markdown／單檔 HTML／PDF 到輸出資料夾（預設 `~/Documents/PodDigest`，播放清單會建子資料夾）。

## 處理方式（多個音檔時）
設定頁「處理方式」或工作台佇列標題旁的選單可切換：
- **逐個完成**（預設）：一個音檔轉完文字就接著整理，再換下一個，最快看到第一份成果。
- **先全部轉文字，再整理**：所有音檔都轉完文字，才一次交給 LLM。語音模型與 LLM 各只載入一次，適合要來回載入卸載模型的本機環境。轉好的項目顯示「等待整理」；中途新加入的音檔也會先轉文字。

## 轉換 Markdown
工作台「轉換 Markdown…」：把已經整理好的 .md（PodDigest 輸出的或自己寫的）轉成 HTML／PDF／TXT。可「各自轉成一份」（各一個子資料夾），或「合併成一本」：每個檔案一個章節，單檔 HTML 有目錄抽屜與搜尋、上一章／下一章，PDF 有目錄頁且每章從新頁開始。不需要 LLM 與語音服務。

## 佇列與選單列
- 沒做完（排隊、處理中、失敗）的項目存在 `~/Library/Application Support/PodDigest/queue.json`（只有來源與選項，不含 API Key；全部做完就刪檔）。關掉再開會自動接續，處理中斷的那個會從頭再做。
- 有項目處理或排隊時選單列會出現進度圖示；處理中關掉主視窗，App 會收進選單列繼續跑，全部做完後跳通知並自動結束。處理中按 ⌘Q 會先確認。
- 點佇列裡的項目，右側會顯示目前做到哪（步驟、進度、已進行時間、即時逐字稿、這個項目的紀錄），並可在做完前改內容類型、詳細程度、額外要求與輸出格式：還沒走到的階段會吃到新設定，已經開始整理就只剩輸出格式能改。
- 做完的項目可按「調整並再做一份」：沿用逐字稿用新設定再整理一份（不重新轉文字），新檔案另存（檔名加編號），可用版本選單切換。
- 設定頁可選「關掉視窗後全部做完就自動結束」，預設關閉＝做完留在選單列待命。
- 「全部重試」會把失敗與已取消的項目全部重新排隊。

## 外部服務
- 語音：`POST {base}/audio/transcriptions`（OpenAI、Groq、whisper.cpp server、mlx 類本機伺服器等）。音訊先切成每 N 分鐘一段、16 kHz 單聲道 AAC 再上傳，所以不受 25 MB 上限影響。
- LLM：`POST {base}/chat/completions`。逐字稿太長時先分段做筆記，再分層合併，最後依類型格式輸出。
- YouTube：yt-dlp 已內建在 App 裡（`vendor/yt-dlp` 打包進 `Contents/Resources/bin`），不用另外安裝。YouTube 改版導致失敗時，到設定頁按「更新 yt-dlp」，新版存在 `~/Library/Application Support/PodDigest/bin`，優先於內建版。
- ffmpeg 不內建、可選：有裝（`brew install ffmpeg`）才能處理 macOS 不支援的格式（webm、ogg、mkv…）。YouTube 預設抓 m4a，通常用不到。

## 換電腦
設定存在同步資料夾的 `settings.json`（第一次執行有 iCloud Drive 就預設 `iCloud Drive/PodDigest`），API Key 預設也一起存。把 `PodDigest.app` 搬到另一台、打開，會自動讀到同一份設定；兩台之間修改後，回到 App 前景時會重新讀取。可在設定頁關掉「API Key 也存到資料夾」。

## 結構（app/）
`PodDigestApp` 入口與診斷日誌｜`Views` 介面｜`Jobs` 佇列｜`Pipeline` 單項流程｜`Media` 音訊切段與 yt-dlp｜`Net` STT／LLM 客戶端｜`Summarizer` 分段與合併邏輯｜`Genre` 各類型提示詞｜`Markdown`／`Exporter` 輸出與 PDF｜`Settings` 設定（Key 在鑰匙圈）

## 測試
`tools/selftest.swift` 是不開 UI 的端對端測試（說明在檔頭）。
