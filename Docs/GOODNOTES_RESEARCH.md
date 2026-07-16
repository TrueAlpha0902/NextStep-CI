# Goodnotes 功能研究基準

更新日期：2026-07-12

這份文件是 NextStep 的產品研究與驗收基準。目標是做出相同類型的使用能力，不是複製 Goodnotes 的原始碼、檔案格式、商標、圖示、模板、Marketplace 內容或專有介面。功能是否已可用，仍以 [`FEATURE_MATRIX.md`](FEATURE_MATRIX.md) 與實際測試為準。

## 官方資料範圍

研究以 Goodnotes 官方產品頁、支援中心與更新公告為主：

- [Goodnotes 產品與功能總覽](https://www.goodnotes.com/)
- [2025 年新一代 Goodnotes：Whiteboards、Text Documents、AI 與協作](https://www.goodnotes.com/blog/the-new-goodnotes)
- [2025 年 10–12 月更新](https://www.goodnotes.com/blog/features-fixes-updates-december-2025)
- [2026 年 4–6 月更新](https://www.goodnotes.com/blog/whats-new-in-goodnotes-april-june-2026)
- [Goodnotes AI 官方指南](https://support.goodnotes.com/hc/en-us/articles/10779112528399-A-guide-to-Goodnotes-AI)
- [錄音轉錄官方 FAQ](https://support.goodnotes.com/hc/en-us/articles/10234247292303-Audio-Transcription-FAQs)

官方功能會持續變動，因此這是一個有日期的基準，而不是永久不變的清單。

## 功能域清單

### 1. 筆記庫與檔案工作流

- Notebook、Quick Note、資料夾與多層資料夾、最愛、垃圾桶、排序、搜尋、自訂封面與模板。
- 匯入 PDF、圖片與常見文件；匯出 PDF、影像與可再次編輯的原生 package。
- 多分頁／多視窗、最近位置復原、outline、書籤、頁面管理與跨文件工作流。
- 跨裝置同步、備份、分享連結及離線使用。

### 2. 手寫與畫布工具

- 筆、螢光筆、橡皮擦、套索、顏色與粗細、壓力／傾斜、筆跡平滑及穩定度。
- 復原／重做、縮放、平移、尺、雷射筆、簡報模式及可自訂工具列。
- 圈選、移動、縮放、旋轉、重新著色、對齊、複製貼上與跨頁移動。
- Scribble to Erase、Circle to Lasso、Draw and Hold、形狀辨識、Smart Ink、手寫 reflow、插入空間與拼字檢查。
- 文字方塊、圖片、形狀、connector、sticky note、tape、sticker、link、GIF 與其他可編輯物件。

### 3. PDF 與頁面

- PDF 原生文字選取、連結、搜尋、outline、頁面旋轉／裁切／重排及標註。
- 紙張或 PDF 背景與筆跡／物件的合成預覽與扁平化 PDF 匯出。
- 依內容類型清除、透明 PNG 保留、可點擊 URL 與可重用 template。

### 4. 新文件類型

- Whiteboard：無限畫布、縮放導覽、圖表、mind map、形狀與 connector 吸附。
- Text Document：富文字、清單與縮排、表格、圖片、影片、可搬移區塊與可靠的格式化複製貼上。
- Study Set：flashcard、間隔重複、練習模式、自訂顏色、學習進度及 Time Keeper。

### 5. 搜尋、OCR 與轉換

- 筆記標題、輸入文字、PDF 文字、掃描影像及手寫內容的全文搜尋。
- 手寫轉文字、拼字檢查、數學式轉換、選取內容轉換與跨頁結果跳轉。
- 索引生命週期需涵蓋新增、修改、刪除、匯入、還原、備份與損毀重建。

### 6. 錄音、轉錄與 Note Replay

- 背景錄音、播放、快轉、倍速、音訊匯出與裝置端轉錄。
- 錄音時間軸與筆跡／頁面事件同步；播放時可選即時顯示、跳到時間點或維持完整筆跡。
- 逐字稿搜尋、點擊跳轉、會議摘要、行動項目及 live summary。

### 7. 智慧工具

- 對筆記、白板、文字文件與選取物件進行問答、摘要、重寫、解釋、outline、quiz、meeting notes 與 template 建立。
- 數學式辨識、求解、逐步教學、圖形／diagram／mind map 產生及圖片生成。
- 內容插入前預覽、修改、捨棄；浮動、側欄與獨立視窗呈現；來源引用與可追溯變更。
- NextStep 的核心智慧功能必須能完全在裝置上運作，不以付費 API、訂閱或雲端額度作為必要條件。

### 8. 協作與整合

- 公開／私人分享、即時共同編輯、留言、presence、權限與衝突處理。
- Calendar、Email-to-note、外部 AI／聊天工具、GIF／素材來源與跨平台連接器。
- Marketplace 類能力只能提供原創、開放授權或使用者自行匯入的素材，不散布 Goodnotes 的專有內容。

## 2026 年新增或容易漏掉的驗收點

Goodnotes 2026 年 4–6 月官方更新列出數個舊清單沒有的細節，NextStep 的後續矩陣必須追蹤：

- 可選擇筆跡 replay 呈現方式。
- connector 吸附形狀邊緣、形狀預設圓角、形狀與 sticky note 自由旋轉。
- Text Document 表格改善，以及 textbox／sticky note 的項目符號、編號與縮排。
- 依內容類型一次刪除、貼上 URL 自動成為連結、透明 PNG 匯入不失去透明度。
- Smart Ink 寬度調整與 reflow、直線化、對齊、剪貼、行間插入。
- Scribble to Erase 可復原／重做、Study Set 顏色、浮動 Time Keeper、深色模式與工具列細節。
- GIF 搜尋／插入屬外部服務整合；免費核心可先提供 Files／Photos GIF 匯入，第三方 catalog 不得成為必要依賴。

## 「完全免費」的工程界線

NextStep 不收費、沒有文件數量限制、沒有浮水印，核心筆記、搜尋、OCR、錄音、轉錄、學習與智慧功能不需要帳號或付費 API。Apple 系統能力、使用者自己的 iCloud／Files 空間與可自由散布的本機模型可用於實作。

第三方服務的帳號、網路、API key、內容授權或未來收費政策不由 NextStep 控制，因此 Calendar、外部聊天工具、GIF catalog、公開分享網址與跨網路即時協作只能是可選 integration；App 的本機主要流程不得依賴它們。若提供替代方案，必須清楚標示與原服務的差異。

## 完成判準

每項功能只有在下列條件全部成立時，才能從「後續版本」或「已有服務」升為「已可用」：

1. iPad UI 有可發現且可操作的完整入口。
2. App 重啟後資料與結果仍正確，失敗有回滾或可理解的復原路徑。
3. Swift 6 strict concurrency、單元／整合／UI 測試與 Xcode 26 CI 通過。
4. 繁體中文與英文皆完整，Dynamic Type、VoiceOver、鍵盤與觸控操作可用。
5. 不依賴未揭露的付費服務，不侵犯第三方商標、素材或私有格式。
6. `FEATURE_MATRIX.md`、架構與安裝文件已同步更新，限制沒有被隱藏。
