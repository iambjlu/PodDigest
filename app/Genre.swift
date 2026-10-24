// app/Genre.swift
// 內容類型：每種類型有自己的「分段抽取重點」與「最終格式」，語音辨識也帶對應提示。
import Foundation

struct Genre: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let blurb: String
    let sttHint: String          // 給語音模型的提示（幫助用字與標點）
    let mapFocus: String         // 分段階段要抓什麼
    let template: String         // 最終 Markdown 結構

    static let all: [Genre] = [auto, podcast, lecture, chat, meeting, interview, talk, custom]
    static func find(_ id: String) -> Genre { all.first { $0.id == id } ?? podcast }

    /// 自動偵測：整理前先讓 LLM 讀一小段內容判斷屬於哪一類，再用那一類的格式整理
    static let auto = Genre(
        id: "auto", name: "自動偵測", icon: "wand.and.stars",
        blurb: "先讀一小段內容，自動判斷是 Podcast、上課、日常談話、會議、訪談還是演講，再套用對應格式（多一次 LLM 呼叫）",
        sttHint: "請使用正確的標點符號。",
        mapFocus: "重點放在：所有有資訊價值的內容（論點、事實、數字、決定、待辦）",
        template: """
        ## 摘要
        ## 重點整理
        （依主題分組條列）
        """)

    /// 自動偵測可以判斷成哪些類型（不含自訂與自動本身）
    static var detectable: [Genre] { [podcast, lecture, chat, meeting, interview, talk] }

    static let podcast = Genre(
        id: "podcast", name: "Podcast", icon: "mic.fill",
        blurb: "主持人與來賓的長談：抓論點、案例、金句與可執行建議",
        sttHint: "以下是一集 Podcast 節目的對話，請使用正確的標點符號。",
        mapFocus: "重點放在：主要論點與論證、舉出的案例與數字、名詞定義、說話者的立場轉折、值得記住的原話",
        template: """
        ## 本集一句話總結
        （2–4 句話）
        ## 核心重點
        （依主題分組的條列，保留論點、案例、數字、名詞定義，不要只寫空泛標題）
        ## 可執行建議
        （若內容有方法、步驟、建議才寫；沒有就省略此節）
        ## 金句與關鍵說法
        （用 > 引用格式，逐字稿中真的有的才列）
        ## 延伸思考
        （1–3 個值得追問或延伸閱讀的方向，可省略）
        """)

    static let lecture = Genre(
        id: "lecture", name: "上課重點", icon: "graduationcap.fill",
        blurb: "課堂錄音：整理概念、定義、公式、例題與老師強調的考點",
        sttHint: "以下是一堂課的錄音，內容包含專有名詞與術語，請使用正確的標點符號。",
        mapFocus: "重點放在：本段教的概念與定義、公式與推導步驟、舉例與例題解法、老師特別強調（「這會考」「很重要」「注意」）的地方、提到的作業與下次進度",
        template: """
        ## 課程概要
        （這堂課在講什麼、前後脈絡，2–4 句）
        ## 章節重點
        （依授課順序用 ### 分小節；每節列：概念與定義、公式／步驟、例子；有時間標記就保留）
        ## 老師強調與考點
        （老師明確強調、可能考的地方）
        ## 名詞與公式速查
        （表格或條列：名詞／符號 → 說明）
        ## 作業與待辦
        （提到的作業、閱讀、下次進度；沒有就省略此節）
        ## 複習問答
        （5–8 題自我測驗題，附簡答）
        """)

    static let chat = Genre(
        id: "chat", name: "日常談話", icon: "bubble.left.and.bubble.right.fill",
        blurb: "朋友、家人、同事間的對話：整理話題、各方想法、決定與待辦",
        sttHint: "以下是日常口語對話，可能有多人交談與口語贅詞，請使用正確的標點符號。",
        mapFocus: "重點放在：聊了哪些話題、各人的想法與立場、提出的問題與回答、達成的共識或決定、約定與待辦、情緒明顯的地方",
        template: """
        ## 這段對話在聊什麼
        （2–3 句話）
        ## 話題脈絡
        （依話題順序條列，每個話題寫出各方的想法或立場）
        ## 共識與決定
        （有達成的結論、約定；沒有就省略此節）
        ## 待辦與後續
        （誰要做什麼、何時；內容有提到才寫）
        ## 值得留意的地方
        （情緒、分歧、尚未解決的問題）
        """)

    static let meeting = Genre(
        id: "meeting", name: "會議紀錄", icon: "person.3.fill",
        blurb: "工作會議：議題、決議、待辦事項（含負責人與期限）",
        sttHint: "以下是一場工作會議的錄音，請使用正確的標點符號。",
        mapFocus: "重點放在：討論的議題、各方意見、決議、待辦事項（負責人與期限）、風險與未解問題",
        template: """
        ## 會議摘要
        （3–5 句話）
        ## 議題與討論
        （每個議題用 ### 分節：背景、各方意見、結論）
        ## 決議事項
        （條列）
        ## 待辦事項
        （用表格：事項｜負責人｜期限；沒提到的欄位寫「未指定」）
        ## 風險與未解問題
        """)

    static let interview = Genre(
        id: "interview", name: "訪談", icon: "person.2.wave.2.fill",
        blurb: "一問一答：依問題整理受訪者的回答與觀點",
        sttHint: "以下是一場訪談，包含提問者與受訪者的問答，請使用正確的標點符號。",
        mapFocus: "重點放在：提問與受訪者的回答、受訪者的背景與經歷、觀點與立場、具體故事與數據、值得引用的原話",
        template: """
        ## 受訪者與主題
        （受訪者是誰、談什麼，2–3 句）
        ## 問答整理
        （依問題用 ### 分節，下方整理回答重點）
        ## 主要觀點
        （跨問題的核心看法）
        ## 精選引言
        （用 > 引用格式）
        """)

    static let talk = Genre(
        id: "talk", name: "演講／影片", icon: "play.rectangle.fill",
        blurb: "演講、YouTube 影片、教學影片：重點章節與結論",
        sttHint: "以下是一場演講或影片的旁白，請使用正確的標點符號。",
        mapFocus: "重點放在：講者的主張、論證結構、示範的步驟、舉例與數據、結論與呼籲",
        template: """
        ## 一句話總結
        ## 內容大綱
        （依順序用 ### 分章節，附時間標記；每章 2–5 個重點）
        ## 關鍵結論
        ## 可以馬上做的事
        （內容有提到才寫）
        """)

    static let custom = Genre(
        id: "custom", name: "自訂", icon: "slider.horizontal.3",
        blurb: "用你自己的要求整理（在「額外要求」或設定頁填寫）",
        sttHint: "請使用正確的標點符號。",
        mapFocus: "重點放在：所有有資訊價值的內容（論點、事實、數字、決定、待辦）",
        template: """
        ## 摘要
        ## 重點整理
        （依主題分組條列）
        ## 待辦與後續
        （有才寫）
        """)
}
