# NextStep

NextStep 是一套以 **Today** 為入口的 AI 個人目標執行與引導式學習系統：把畢業、課程、論文、作品與求職等長期目標，連結到可驗證來源、每週成果及今天可以直接開始的最小行動。筆記、PDF、手寫、課綱與職缺是規劃引擎的輸入與證據，不是產品中心；AI 衍生內容必須保留來源定位、信心與使用者確認狀態。

第一版同時以 **iPhone 與 iPad** 為正式目標，最低需求為 iOS／iPadOS 18。iPhone 採五分頁與逐層導覽，iPad 採 sidebar、內容區與 inspector 的寬版工作區，不把平板畫面縮擠到手機。eip pencil 等產品視為一般觸控筆；Apple Pencil pressure、tilt、hover、double tap 或 squeeze 皆依裝置與筆型做 availability gating。Apple Intelligence 只會作為 iOS／iPadOS 26+ 的可選增強，不是核心功能依賴。

App 顯示名稱為 **NextStep**；為了保留既有建置與資料相容性，Xcode project／target／scheme／module 的技術名稱暫時維持 `Notes`，bundle identifier 維持 `com.speci.localnotes`。

目前 repository 保留了成熟的筆記、PencilKit、PDF／圖片匯入與註記、OCR、搜尋、錄音、Replay、匯出及備份基礎，並新增 NextStep 正式領域模型、deterministic planning／replanning、可追溯來源模型、同 Apple ID 檔案同步核心、iPhone／iPad 響應式 Design System 與第一個可操作的 Beta 原型閉環。這仍是開發中版本，不代表 Phase 1 已完成，也不代表所有產品願景或 Goodnotes 等級的筆記能力都已完成；現況、差距與階段驗收以 [Product handoff](Docs/Product/README.md)、[即時實作狀態](Docs/Product/IMPLEMENTATION_STATUS.md)、[Design system](Docs/Design/README.md)、[功能矩陣](Docs/FEATURE_MATRIX.md)與 [2026 Roadmap](Docs/ROADMAP_2026.md)為準。

## 目前已接到 App 介面

- 建立一般筆記與 Quick Note，選擇空白、橫線、方格或點陣紙張。
- 以 PencilKit 使用筆、螢光筆、橡皮擦、套索、顏色、粗細、復原與重做；可切換 Apple Pencil-only 或手指／相容觸控筆輸入。
- 從 Files 匯入 PDF、JPEG、PNG 或 `.notepkg`；PDF 每頁與圖片會成為可書寫背景。
- 透過縮圖新增、複製、刪除頁面，並以上移／下移調整順序。
- 從 Editor 切換目前頁面的書籤，並在 Navigator 依全部／書籤／自訂大綱篩選、按原頁碼跳頁；大綱名稱可新增、修改或清除，並以原子 transaction 同步保存至 manifest 與頁面 descriptor。書籤與大綱也會進入本機 Library／Editor 搜尋並保留原頁面目標。
- 分享完整 `.notepkg` 驗證快照，或把目前頁面／整本筆記的紙張、PDF／圖片背景、筆跡、文字、圖片、形狀、connector、sticky、tape、sticker 與安全連結合成 PDF 分享。單頁與整本來源都綁定同一 export session；整本流程逐頁串流到受保護暫存檔，兩者都支援取消、晚到發布防護與過期輸出清理。
- 使用格狀／列表筆記庫、排序、重新命名、最愛、垃圾桶，以及標題、頁面書籤／自訂大綱、結構化頁面、canvas text／sticky／link title、已擷取內容、人工接受的手寫辨識文字與逐字稿搜尋；完整的 `bookmark`／`bookmarked`／`bookmarked page`／`書籤`／`已加書籤` 關鍵詞會精確尋找已加書籤頁面，片段不會把 boolean 書籤 metadata 當文字誤命中。Library 結果可開啟首個命中頁，Editor 內可用 `⌘F` 開啟跨頁結果導覽，以 `⌘G`／`⇧⌘G` 前後切換。
- 在 Page Tools 擷取 PDF selectable text；沒有 selectable text 的 PDF 頁面會先渲染再做 Vision OCR，圖片頁面也可做 OCR。結果會寫入本機搜尋索引。
- 在 Page Tools 將目前頁面的 PencilKit 筆跡以有界、ink-only 影像交給裝置端 Vision，逐項修正、接受、拒絕或重設建議；只有人工接受且仍對應目前筆跡雜湊的文字會進入本機搜尋。
- 在 Page Tools 對擷取或貼上的文字執行摘要、文字整理、outline、meeting notes、quiz、問答、解釋與確定性計算。
- 在筆記內耐久錄音、跨頁加入時間標記、播放／暫停／seek，並以 Apple Speech 在支援語言下建立裝置端逐字稿；新錄音也會以錄音機的精確時鐘擷取完整 ink／element 操作檢查點。音訊、時間線、不可變 Replay 索引與內容定址 payload 會原子保存；逐字稿可在重新開啟後載入並納入本機內容搜尋。Audio panel 可搜尋個別逐字稿、前後導覽命中時間，並分別匯出完整性驗證過的 M4A、TXT 或 SRT。
- 從既有錄音啟動唯讀 Note Replay，以 Whole Stroke、Spotlight 或 Static 呈現跨頁內容；schema v3 錄音會依 `(time, sequence)` 還原每個檢查點當時的筆跡與 canvas elements，包括擦除、移動及元素編輯後狀態，舊錄音則維持 final-stroke 相容路徑。刪除頁面時也會從所有 v3 歷史原子抹除該頁內容並回收無引用 payload；全空歷史保留音訊但停用 Replay。支援播放／暫停、前後跳轉、scrubber、縮圖 seek、安全停止與背景生命週期處理。
- 將資料庫放在「我的 iPad」或使用者選擇的 Files／iCloud Drive 資料夾；切換前需關閉所有筆記，App 會在 deadline 內 drain 保存、讀取、OCR／辨識與匯出，以可回滾 transaction 避免混用位置。即使原 bookmark 已失效或 provider 卡住，仍可改選替代位置；晚回 scan 的 security scope 由 root lease 延後清理。搜尋另以跨啟動 authority marker 保持關閉，直到舊位置的 primary／backup cache 都確實清除並完成重建。
- 在 Settings 選擇備份資料夾，建立經驗證的完整 notebook snapshot、查看歷史並安全還原；同 ID 衝突不會覆寫。

Page Tools 目前是離線、規則式／擷取式工具，不是真正的 LLM。手寫辨識是 Vision fallback，必須人工審核，不保證能可靠辨識任意字跡；目前也沒有套索轉 editable text 或在縮放畫布上精準反白辨識範圍。Note Replay v3 能在已提交的操作邊界切換完整 scene，但不是筆尖 sample 等級的逐點動畫，也不記錄錄音中的頁面結構或背景變更；因此錄音期間會禁止新增、複製、刪除及重排頁面。舊錄音仍只依 final strokes 重建。間隔重複已有編輯及到期複習 UI，本機模型管理可驗證與安裝模型套件，但推論 runtime 尚未連接。備份已接 UI，但尚未包含 trash／kind／cover sidecar，也沒有自動排程。

## 免費的實際邊界

NextStep 第一版不需要訂閱、廣告、NextStep 帳號、自建雲端後端或付費 AI API。權威原始碼保留在私人 `TrueAlpha0902/Notes`；經過秘密掃描後，只有當前檔案樹會以不含私人歷史的單一根提交發布至公開 `TrueAlpha0902/NextStep-CI`，由公開 macOS Actions 建置 unsigned IPA。Windows 再以免費 Apple Account 和 Sideloadly 完成本機簽署安裝。

但「免費」仍受外部服務規則限制：

- 公開 mirror 讓現行標準 GitHub-hosted runner 不依賴私人 repository 的付費 macOS 分鐘；GitHub 規則日後仍可能調整，因此 CI 不被視為永久的外部免費承諾。
- 免費 Apple Account 的 provisioning profile 通常只有 7 天效期，必須定期以同一帳號及 bundle ID 重新簽署。
- iPhone／iPad 第一版同步由使用者在兩台裝置選擇同一個 iCloud Drive 資料夾，使用既有 iCloud 容量；它是 eventual sync，不承諾即時背景同步。
- Sideloadly 是第三方工具，其支援範圍與條款可能變更。

完整流程見 [Windows → iPad 安裝指南](Docs/INSTALL_WINDOWS_IPAD.md)。

## 專案結構

- `NotesApp`：SwiftUI／UIKit iPad 介面、PencilKit 畫布、PDF／圖片背景、Page Tools、手寫辨識 review workflow，以及把 UI models 對接 NotesCore 的儲存 adapter。
- `NotesCore`：領域模型與完整 `.notepkg` repository，包括手寫辨識 sidecar、write-ahead transaction journal、operation log、快照匯出、驗證及復原。
- `NotesServices`：本機搜尋、Vision OCR、PDF 文字擷取與掃描頁 fallback、手寫搜尋文件建構、錄音時間軸、裝置端語音辨識、備份、學習排程、模型管理及非生成式文字工具。
- `NextStepAcademic`：Course／CourseSession、七種 Capture、Note 來源錨點、候選狀態與原子課後 Wrap-up 的獨立領域及持久化邊界。
- `NextStepDomain`：目標階層、每日行動、Guided Learning Package、Paper／Citation／Anchor／Highlight、規劃事件與可信度資料模型。
- `NextStepPlanning`：不讓模型任意修改 deadline 的 deterministic 排程、Today projection、完成進度與 replanning diff。
- `NextStepSync`：以 immutable operation、content-addressed blob、checkpoint 與 protected-fact conflict review 實作的 Files／iCloud folder 同步核心。
- `NextStepDesignSystem`：日系極簡、細線條、編輯草稿感的 token、元件與 iPhone／iPad 響應式核心畫面。
- `PreviewWeb`：Windows 可直接操作的產品契約預覽；它不是 Apple Simulator，也不假裝執行 SwiftUI。

`LocalNotebookStore` 是 `NotesCore.FileNotebookRepository` 的薄 adapter；日常建立、匯入、頁面、筆跡、手寫辨識 review sidecar、資產與 package export 都走 Core。`exportSnapshot` 會在 actor 邊界解析待處理 transaction、複製至 staging、驗證，再提交目的 `.notepkg`。validate／recover API 已存在，但尚未提供使用者可操作的診斷與復原介面。詳情見[架構說明](Docs/ARCHITECTURE.md)。

## 建置與驗證

本專案以 XcodeGen 產生 `.xcodeproj`，產生物不提交版本控制。Mac 開發環境需使用 Xcode 26：

```bash
brew install xcodegen
bash scripts/validate-project.sh
bash scripts/generate-project.sh
open Notes.xcodeproj
```

Windows 可執行不需 Xcode 的設定與資源檢查：

```powershell
.\scripts\validate-project.ps1
```

Scheme 目前包含九個測試 target：既有 Core／Services／Academic／App／UI tests，加上 `NextStepDomainTests`、`NextStepPlanningTests`、`NextStepSyncTests` 與 `NextStepDesignSystemTests`。GitHub workflow 會在 `macos-26`／Xcode 26 上產生專案、執行單元／整合測試、分別以 iPhone 與 iPad simulator 驗證響應式核心流程、建置 generic iOS app，並封裝附有來源 manifest 的 `Notes-unsigned.ipa`；CI 不需要 Apple 帳密、憑證或 provisioning profile。

歷史基線 [GitHub Actions run 29320014938](https://github.com/TrueAlpha0902/Notes/actions/runs/29320014938) 曾通過 713 項單元／整合測試與 4 項 iPad UI 測試；它只證明遷移前版本。這次 iPhone／iPad 響應式與 Beta 垂直切片必須以公開 mirror 的新 commit 全綠後，才可視為目前可安裝基線。

## 隱私與資料

- 筆記內容預設只寫入本機 App Documents；使用者也可自行選擇 Files 資料夾。
- 目前沒有 NextStep 帳號、分析 SDK、廣告 SDK 或自有伺服器。
- 選擇 iCloud Drive 資料夾時，檔案同步由 Apple Files／iCloud Drive 負責，不是 NextStep 自建同步服務。
- Settings 可建立／列出／還原整批 notebook snapshots；另外仍可從筆記 context menu 分享單本 `.notepkg`。完整 library 備份目前不含 trash／kind／cover sidecar。
- 安裝新版 IPA 時應使用相同 Apple Account 與 bundle ID 覆蓋安裝，且仍應定期備份 `.notepkg`。

## 獨立專案聲明

NextStep 參考一般數位筆記軟體的使用情境，但為完全獨立實作。本 repository **不包含、反編譯、改作或散布 Goodnotes 的原始碼、商標、圖示、介面版面、模板或其他專有素材**；NextStep 與 Goodnotes 或 Goodnotes Limited 沒有關係，也不宣稱已達到完整功能對等。

## 文件

- [Windows → iPad 安裝指南](Docs/INSTALL_WINDOWS_IPAD.md)
- [公開 CI mirror 邊界與發布流程](Docs/CI_MIRROR.md)
- [NextStep product handoff](Docs/Product/README.md)
- [Design system 與核心畫面規格](Docs/Design/README.md)
- [架構與資料安全](Docs/ARCHITECTURE.md)
- [功能矩陣與產品邊界](Docs/FEATURE_MATRIX.md)
- [Goodnotes 官方功能研究基準](Docs/GOODNOTES_RESEARCH.md)
