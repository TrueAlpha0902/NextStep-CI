# NextStep 功能矩陣

本矩陣描述目前 repository 的實際程式碼狀態，不是 Goodnotes 的功能清單、交付日期承諾或完整功能對等聲明。「底層型別存在」不等於功能完成；只有已有 iPad UI 與主要資料流的項目才列為「已接 UI」。

## 狀態定義

- **✅ 已接 UI**：目前程式碼已有使用者入口，主要結果會保存或匯出；仍可能有早期版本限制。
- **🧩 服務層**：已有 Core／Services 實作或測試，但沒有完整使用者流程。
- **🧪 待 Xcode 驗證**：專案或 CI 設定已存在，但目前尚無 macOS／Xcode 26 綠燈結果可佐證。
- **🗓️ 後續版本**：只有概念、局部模型或尚未開始的功能。

「✅」只表示接線狀態，不表示整個 App 已在 Xcode 26 編譯通過，也不表示已完成實機、效能、無障礙或長時間可靠性驗證。

## 筆記庫與檔案

| 功能 | 狀態 | 目前實際範圍 |
| --- | --- | --- |
| iPad 三欄筆記庫 | ✅ 已接 UI | `NavigationSplitView` 提供 Documents、Favorites、Trash、Settings、內容欄與編輯器。 |
| 建立 Notebook／Quick Note | ✅ 已接 UI | 新筆記建立一頁，空標題使用 Untitled；Quick Note 有獨立類型。 |
| 紙張模板 | ✅ 已接 UI | 建立時可選空白、橫線、方格、點陣；編輯器新增頁目前使用空白模板。 |
| 格狀／列表、排序、重新命名 | ✅ 已接 UI | 可依修改、建立、標題排序，並從 context menu 重新命名。 |
| 最愛與垃圾桶 | ✅ 已接 UI | 可加入／移除最愛、移到垃圾桶、還原及永久刪除。 |
| 自選 Files／iCloud Drive library folder | ✅ 已接 UI | 使用 security-scoped bookmark；iCloud Drive 只提供 Files 層級傳輸，不是 NextStep CloudKit 同步。 |
| PDF、JPEG、PNG 匯入 | ✅ 已接 UI | PDF 每頁建立一個可書寫背景；圖片建立單頁背景；Files picker 可多選。 |
| `.notepkg` 匯入 | ✅ 已接 UI | Info.plist 註冊 UTI；Files picker 與 open-in URL 都可匯入 package。匯入會拒絕 symbolic link、無效 package 及重複 notebook ID。 |
| `.notepkg` 匯出／分享 | ✅ 已接 UI | 筆記 context menu 的 Share notebook 會呼叫 Core `exportSnapshot` 產生經驗證快照；尚無批次匯出、改 ID 複製或衝突合併 UI。 |
| DOCX／PPTX 匯入 | 🗓️ 後續版本 | 尚未提供系統轉換或錯誤引導。 |
| 相機掃描／相簿選取 | 🗓️ 後續版本 | 權限字串已配置，但目前匯入入口是 Files。 |
| URL template／GIF 匯入 | 🗓️ 後續版本 | 2026 研究基準已列入 backlog；尚無 URL template、Photos GIF 或動態 GIF 畫布流程。 |
| 完整多視窗與 scene restoration | 🗓️ 後續版本 | WindowGroup 與 multiple-scenes flag 已存在；尚無每個視窗獨立 notebook state、開新視窗入口與復原測試。 |

## 手寫、頁面與 PDF

| 功能 | 狀態 | 目前實際範圍 |
| --- | --- | --- |
| Apple Pencil／PencilKit 書寫 | ✅ 已接 UI | 可使用 Pencil-only；也可開啟手指與相容觸控筆輸入。Apple Pencil 的手掌誤觸由 PencilKit 處理，第三方電容筆不等同 Apple Pencil。 |
| 筆、螢光筆、橡皮擦、套索 | ✅ 已接 UI | Custom toolbar 對應 pen、marker、vector eraser、`PKLassoTool`，也可顯示系統 PencilKit picker。 |
| 顏色與粗細 | ✅ 已接 UI | 黑、藍、紅、綠；細、中、粗三檔。 |
| 平移、縮放、復原、重做 | ✅ 已接 UI | 外層 `UIScrollView` 負責 fit-to-page、平移與縮放；undo manager 提供復原／重做並有鍵盤快捷鍵。 |
| PKDrawing 載入與自動保存 | ✅ 已接 UI | 切頁會載入對應 drawing，未完成前禁止輸入；每次變更立即 stage 到 AppModel，再依頁 debounce／序列寫入。切頁、刪頁、package export、backup 與 App 進背景會 drain；失敗保留最新 payload 供重試。 |
| 頁面縮圖與新增頁 | ✅ 已接 UI | 左側縮圖可切頁；可新增空白頁，縮圖會顯示已保存或目前筆跡。 |
| 頁面複製、刪除與重排 | ✅ 已接 UI | 縮圖 context menu 可複製、刪除、上移或下移；至少保留一頁。尚無拖放重排。 |
| 分享目前頁面 PDF | ✅ 已接 UI | 將紙張／指定 PDF 頁／圖片背景、PencilKit ink、八種 canvas element 與安全 HTTP／HTTPS link 合成**單頁 PDF**後分享；所有來源綁定同一 identity-validated export session，離開頁面會取消並禁止晚到發布。不是可編輯 PDF annotation object。 |
| 頁面書籤與自訂平面大綱 | ✅ 已接 UI | Editor 可切換目前頁面的書籤；Navigator 可依全部／書籤／大綱篩選並按原頁碼跳頁，也可新增、修改或清除目前頁面的大綱名稱。Core `PageDescriptor` schema v4 以單行、120 Character／1,024 UTF-8 bytes 上限驗證，並用 journal transaction 原子同步 `manifest.json` 與 `page.json`；兩者也會進入 Library／Editor 搜尋並保留原頁面目標。duplicate 預設不複製個人導覽 metadata。巢狀大綱與 PDF 原生 outline 仍未完成。 |
| 頁面旋轉 | 🧩 服務層 | `PageDescriptor` 有 rotation 欄位，但目前 App adapter／UI 沒有完整編輯入口。 |
| Text、Image、Shape、Connector、Sticky、Tape、Sticker、Link elements | ✅ 已接 UI | 八種結構化元素可在畫布新增、選取、移動、縮放、旋轉、調整層級、編輯內容與刪除；資料耐久保存，並納入頁面 PDF／圖片渲染。進階吸附、裁切與群組仍待補。 |
| Draw-and-Hold、Circle-to-Lasso、Scribble-to-Erase | 🗓️ 後續版本 | 尚無自製 gesture recognizer、Smart Ink reflow 或完整 undo 行為。 |
| Ruler、Laser、Presentation Mode | 🗓️ 後續版本 | 尚無專用操作介面或外接螢幕流程。 |
| PDF 原生文字選取、outline、links | 🗓️ 後續版本 | PDF 是可書寫背景；文字可透過 Page Tools 擷取，但畫布不是互動式 PDF view。 |
| 整本 PDF 扁平化匯出 | ✅ 已接 UI | Editor 可分享整本筆記；逐頁以權威持久化快照合成背景、ink、八種元素與安全連結，保留不同 media box，並使用有身分 fence 的 export session、累積來源預算、取消、原子發布及失敗清理。來源 PDF 原生 annotations／outline 尚未保留。 |

## 搜尋、OCR 與 Page Tools

| 功能 | 狀態 | 目前實際範圍 |
| --- | --- | --- |
| Notebook 標題搜尋 | ✅ 已接 UI | Library 即時、大小寫不敏感篩選標題。 |
| 已擷取與畫布內容搜尋 | ✅ 已接 UI | `LocalSearchIndex` 持久化 title／segments，支援繁中 bigram 與 revision；頁面大綱、書籤、typed content、canvas text／sticky／link title、PDF／圖片擷取結果、人工接受的手寫辨識文字與逐字稿都可命中，Library 可跳到首個命中頁。完整的 `bookmark`／`bookmarked`／`bookmarked page`／`書籤`／`已加書籤` 會精確尋找書籤，`book`／`mark`／`favorite` 等片段不會把 boolean metadata 當文字命中。Link 只索引顯示標題，不把目的 URL 放進 snippet。 |
| 文件內統一搜尋導覽 | ✅ 已接 UI | Editor 以 `⌘F` 開啟；一般寬度使用 300–340pt 側欄，compact／Stage Manager 使用 large sheet。結果依筆記頁序聚合同頁 outline、bookmark、typed text、canvas text、PDF text、Vision OCR、已接受手寫文字與逐字稿命中，支援 `⌘G`／`⇧⌘G`、取消與 generation／notebook／page fencing；切頁沿用先保存再提交的安全路徑。目前只導到頁面，尚未提供命中範圍反白或逐字稿精準時間 seek。 |
| 搜尋索引生命週期 | ✅ 已接 UI | Canvas、handwriting 與 page navigation 各使用 notebook＋page 命名空間的 UUID-v8 衍生文件；導覽 metadata 與元素成功耐久保存後才索引，手寫只發布人工接受且 ink SHA-256 仍相符的文字。啟動、匯入、複製、重新命名、刪頁與失敗回滾會重建或清除對應文件；導覽／筆跡一變就先 fail-closed 抑制舊結果，並以 per-page generation、title＋fingerprint＋segment payload authority、commit verification 與取消後的獨立 repair 防止反序或 orphan 發布。整本筆記的 durable save 使用可跨取消／failed-root rollback 交棒的 recovery token，同步修復 summary 與所有帶筆記標題的本機搜尋文件並刷新目前 Library query；所有帶 notebook title 的 page-derived payload 也會在 index actor 內套用帶 serial generation 的 notebook title authority，避免晚回 OCR／canvas／handwriting 寫回舊標題。刪頁會用精確 page-owned document IDs 原子清除並在持久化前留下 process-lifetime tombstone，阻止晚回 OCR 復活 orphan，且不會誤刪跨頁 transcript；若 app 在清理前中止，bootstrap 會依 durable page IDs 清除 raw typed／PDF／OCR orphan。authority 更新失敗時 token 會保留重試，個別非導覽內容重建失敗則由後續保存或 bootstrap 重試；即使索引更新失敗也不顯示 stale navigation snippet。背景內容仍不會在匯入時自動 OCR，必須先在 Page Tools 擷取。 |
| PDF selectable text 擷取 | ✅ 已接 UI | Page Tools 可對指定 PDF page 使用 PDFKit 擷取文字並存入搜尋索引。 |
| 掃描 PDF fallback OCR | ✅ 已接 UI | PDF 沒有 selectable text 時會渲染目前頁面，再交給 Vision OCR。 |
| 圖片 OCR | ✅ 已接 UI | Page Tools 可用 Vision accurate OCR 擷取圖片背景文字，預設涵蓋繁中與英文。 |
| 手寫全文搜尋／手寫轉文字 | ✅ 已接 UI | Page Tools 將有界的 ink-only PencilKit raster 交給裝置端 Vision，保留不可變 machine candidates，並提供逐項修正、Accept、Reject 與 Reset。review 以 revision CAS 交易保存；只有人工接受且 ink fingerprint 仍相符的文字進入搜尋。這是 fallback，不保證任意字跡可靠；尚無套索轉 editable text 或 bounds 反白。 |
| 摘要、文字整理、outline、meeting notes、quiz | ✅ 已接 UI | Page Tools 可處理擷取或貼上的文字，結果留在當前 sheet，可選取複製。 |
| 問答與解釋 | ✅ 已接 UI | Page Tools 有 Ask this page 與 Explain；來源片段可展開。這是本機擷取式／規則式輸出，不是真正語言模型。 |
| 確定性計算 | ✅ 已接 UI | Calculator 入口使用 `MathExpressionEvaluator`；支援文字算式，不含手寫數學辨識或逐步解題。 |
| 真正本機 LLM／RAG／來源驗證 | 🗓️ 後續版本 | 尚未整合 MLX、Qwen、embedding pipeline 或生成式模型；目前工具不應稱為 AI 模型生成。 |

## 音訊、轉錄與學習

| 功能 | 狀態 | 目前實際範圍 |
| --- | --- | --- |
| M4A 錄音與播放 | ✅ 已接 UI | Editor 可建立耐久 AAC 錄音、列出 sessions、播放／暫停／seek；音訊以串流方式匯入 content-addressed asset。單段匯出使用 identity-bound session、bounded chunks、完整 byte count 與 SHA-256／M4A header 驗證，通過 final fence 後才原子發布暫存成品。 |
| 筆跡時間標記／Note Replay | ✅ 已接 UI | 錄音切頁會保存跨頁時間標記；schema v3 另以錄音機精確時鐘建立 baseline／change／terminal 不可變 scene index，每個事件引用內容定址的完整 ink 與 canvas elements。Editor 已接真實音訊 transport、唯讀 surface、Whole Stroke／Spotlight／Static、依 `(time, sequence)` 選 scene、scene-level LRU、scrubber、縮圖 seek、安全停止及生命週期 fencing，可還原操作檢查點間的擦除、移動與元素編輯。刪頁會原子抹除該頁的 Replay 事件並回收無引用 payload；若歷史全空，音訊仍可播放但 Replay 停用。舊錄音維持 final-stroke 相容；目前不是筆尖 sample 等級的逐點重建，錄音中也不允許頁面結構變更。 |
| 裝置端語音轉錄 | ✅ 已接 UI | Editor 可選繁中、英文、日文或韓文，以 Apple Speech 要求 on-device recognition；結果與 audio descriptor 在同一筆 transaction 原子保存，重新開啟仍可載入。 |
| 逐字稿搜尋與點擊跳時間 | ✅ 已接 UI | 已保存逐字稿會建立本機搜尋文件；Library 內容搜尋可命中錄音逐字稿。Audio panel 可切換逐字稿、在有界的大小寫／重音不敏感結果中前後導覽、點擊 segment 從對應時間播放，並從 durable transcript 匯出 TXT 或 SRT。 |
| Study Set／到期複習 | ✅ 已接 UI | 可建立、編輯、刪除卡片，執行到期複習並顯示進度；尚未達到獨立全卡 Practice Mode，也沒有 CSV／TSV 匯入與 Time Keeper。 |
| 間隔重複排程 | ✅ 已接 UI | `StudyScheduler` 的 again／hard／good／easy 與 lapse 已接到複習 UI，變更隨 Study Set 保存。 |
| Study 顏色、進度與 Time Keeper | 🗓️ 後續版本 | 2026 研究基準已列入 backlog；目前沒有學習 session UI。 |

## 文件模式、本機模型與備份

| 功能 | 狀態 | 目前實際範圍 |
| --- | --- | --- |
| Whiteboard | ✅ 初版 UI | 可從 Library 建立並在固定 3200×2400 PencilKit 畫布書寫；尚不是可擴張 world coordinates 的無限白板，也沒有 minimap、fit-content 或 connector attachment。 |
| Block-based Text Document | ✅ 初版 UI | 已有 pageless block editor、標題、清單、quote、code、checklist、縮排與按鈕重排；資料仍是 plain-text block，尚無 inline rich text、table、media block、slash menu、拖放與 PDF export。 |
| Model download／SHA-256／路徑防護 | 🧩 服務層 | `ModelDownloadManager` 可下載 data artifact、容量檢查、staging install、驗證雜湊、列出及移除；沒有 catalog 或 runtime UI。 |
| WhisperKit／其他本機模型 | 🗓️ 後續版本 | 尚未內建、下載或執行 Whisper、LLM、embedding 或圖片生成模型。 |
| Files folder backup／restore | ✅ 已接 UI | Settings 可保存 backup folder bookmark、先由 Core 匯出各 notebook 的一致快照、建立／列出驗證 backup，並在確認後還原。整批 restore 遇同 ID 時完全不提交；目前不含 trash／kind／cover sidecar，也沒有排程。 |
| 手動單本 `.notepkg` 備份 | ✅ 已接 UI | 可從筆記 context menu 分享 Core 驗證快照到 Files；需逐本操作，與完整 library backup 不同。 |
| 個別筆記鎖、Touch ID、加密恢復金鑰 | 🗓️ 後續版本 | 尚無 LocalAuthentication／Keychain／CryptoKit notebook encryption flow。 |

## 儲存與一致性

| 功能 | 狀態 | 目前實際範圍 |
| --- | --- | --- |
| 本機 `.notepkg` 保存 | ✅ 已接 UI | App adapter 使用 Core manifest／pages／PKDrawing／content-addressed assets；每頁手寫 machine candidates 與獨立 reviews 保存於 `handwriting-recognition.json` sidecar，trash、kind 與 cover hue 另存 atomic library sidecar。 |
| Write-ahead transaction journal | ✅ 已接 UI | 每個 Core mutation 先在 `ops/transactions` 寫入 journal、staged files 與 originals backup，再套用狀態；`manifest.json` 最後寫入並以 revision 作 commit marker。 |
| Operation log | ✅ 已接 UI | 狀態提交後才把 command 寫入 `ops/local`。若 phase／operation log／cleanup 失敗，保留 journal，由下一次解析或 recovery 補完；operation log 不是完整 event-sourcing。 |
| Package validate／recover | 🧩 服務層 | 可檢查／處理待完成 transaction、temp、manifest backup／reconstruct、orphan pages、corrupt operations、asset digest、手寫 sidecar bounds／revision／ink staleness 與 schema migration；損毀 current sidecar 會隔離，未來 schema 保留且拒絕覆寫。尚無使用者診斷／確認 UI。 |
| 一致的 `exportSnapshot` | ✅ 已接 UI | actor 先解析 pending transactions，複製 live package 至 staging，驗證快照，再原子替換目的；避免直接分享正在變動的 live directory。 |
| Content-addressed asset 去重／完整性 | ✅ 已接 UI | PDF／圖片 importer 使用 Core `importAsset`，以 SHA-256 作 asset ID；validate 可檢查 byte count 與 digest。 |
| App 啟動序列化 | ✅ 已接 UI | create／import 等 mutation 會等待同一個 bootstrap task 與搜尋索引 reconciliation，避免慢速啟動 snapshot 覆蓋新資料。 |
| Library 位置交易切換 | ✅ 已接 UI | 有開啟中或尚在 final flush 的 Editor 時拒絕切換，lease 綁定 root generation；既有 writes／Editor reads／OCR／exports／handwriting operations 以 deadline drain。即使舊 bookmark bootstrap 失敗或 provider 卡住仍可選替代位置；bookmark／repository／metadata 工作不占住 store actor，每次 scan 以 root inspection lease 延後 scope 釋放。候選準備可硬逾時；bookmark 同步落盤後才 commit，失敗可 rollback。成功後搜尋由持久 authority marker 跨重啟 fail closed，強制清空 primary＋backup 後才重建與開放。 |
| iCloud Drive file-level transport | ✅ 已接 UI | 可選 iCloud Drive folder；同步、版本與容量由 Apple Files 管理。多裝置衝突合併尚未完成。 |
| CloudKit／NextStep 帳號／跨平台同步 | 🗓️ 後續版本 | 零後端版本刻意不包含。 |

## 工程與驗證

| 功能 | 狀態 | 目前實際範圍 |
| --- | --- | --- |
| XcodeGen iPadOS 18／Swift 6 project | 🧪 待 Xcode 驗證 | `project.yml` 定義 NotesCore、NotesServices、NotesApp；App 僅支援 iPad，開啟 strict concurrency。 |
| 四個測試 targets | 🧪 待 Xcode 驗證 | `NotesCoreTests`、`NotesServicesTests`、`NotesAppTests`、`NotesAppUITests` 都已納入 scheme。Core／App tests 另覆蓋手寫 schema bounds、CAS、stale／future schema、recovery quarantine、ink-only raster、review／搜尋生命週期、頁面導覽 metadata migration／Unicode bounds／原子 rollback／stale publication／mutation interlock、書籤 exact-query／大綱索引／fingerprint authority／反序更新／清除與刪頁，以及 durable rename 在一般取消或 failed-root rollback 後的全來源標題恢復、root preparation／bookmark durability／失效或阻塞 provider recovery、Editor read／structural lease、OCR、export acquisition、audio、查詢與跨啟動 search authority fencing；仍須 Xcode 執行。 |
| Xcode 26 CI 與 unsigned IPA | 🧪 待 Xcode 驗證 | workflow 已配置 `macos-26`、Xcode 26、四個 test targets、generic-device build 及 7 天 IPA artifact；尚未有實際綠燈 run，因此目前不能宣稱 IPA 已產出。 |
| Windows Sideloadly 流程 | 🧪 待 IPA 驗證 | 文件與預定流程已存在；仍須先取得成功 CI 產出的 IPA，再以個人 Apple Account 簽署並完成 iPad 實機驗證。 |
| 繁中／英文 localization | ✅ 已接 UI | 使用 `en`／`zh-Hant` string catalog 與靜態檢查；仍需 Xcode build、裝置語言、Dynamic Type 與 VoiceOver QA。 |
| App Store／TestFlight 發布 | 🗓️ 後續版本 | 免費 Personal Team 不能作 App Store distribution；目前規劃為私人側載。 |

## 依 2026 Goodnotes 研究整理的後續優先序

下列是從 [`GOODNOTES_RESEARCH.md`](GOODNOTES_RESEARCH.md) 整理的差距清單，不是 NextStep 已完成項目，也不是承諾完全複製 Goodnotes：

1. 將文件內搜尋擴充為可靠的命中範圍反白，並提供套索選取筆跡轉成 editable text element；手寫 OCR review／修正與 accepted-only 搜尋已建立初版。
2. 補 PDF 互動閱讀層、outline／原生 links、頁面範圍與 OCR text layer 匯出。
3. 補 Smart Ink 類型的 reflow，以及 Draw-and-Hold、Circle-to-Lasso、Scribble-to-Erase 和可靠 undo／redo。
4. 將有限 Whiteboard 升級為持久 world coordinates、minimap、fit-content 與 connector attachment；將初版 Text Document 升級為 rich inline／table／media schema。
5. 將 Study Set 補成全卡 Practice、CSV／TSV 匯入、顏色、TTS、提醒與 Time Keeper。
6. 補自訂模板庫、相機掃描、GIF、presentation／laser、完整多視窗復原與自動備份衝突 review。
7. 將 Note Replay 從已完成的操作檢查點 scene history 擴充為可選的筆尖 sample 級漸進動畫，並另行設計頁面背景與結構變更事件；舊錄音繼續保留 final-stroke 相容路徑。
8. 多人協作、presence、留言與分享連結需要後端或明確的附近裝置／Files patch 替代方案；完成身份、加密與衝突策略前維持未實作。

## 明確不包含的零後端能力

目前 NextStep 沒有伺服器，因此不包含即時多人協作、presence、留言、公開／私人網頁分享連結、NextStep 帳號跨平台同步、Marketplace、Classroom／企業後台或 Email-to-note。若未來要加入，必須先另行決定後端、身份、加密、衝突處理、營運成本與隱私政策。

## 品牌與原始碼聲明

NextStep 是獨立專案，不是 Goodnotes 的 fork、clone client 或重新包裝版本。本 repository 不使用 Goodnotes 原始碼、反編譯結果、商標、圖示、專有介面、模板或 Marketplace 素材，也與 Goodnotes／Goodnotes Limited 無隸屬或背書關係。未完成項目不應對外宣稱與 Goodnotes 等價。
