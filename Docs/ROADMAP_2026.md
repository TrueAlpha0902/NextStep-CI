# NextStep 2026 功能 Roadmap

更新日期：2026-07-13

NextStep 的產品方向是免費、local-first、iPad 原生。功能可以與成熟筆記產品處理相同需求，但不複製 Goodnotes 的名稱、圖示、版面、Marketplace 資產或其他受保護內容。實作與完成狀態仍以 [`FEATURE_MATRIX.md`](FEATURE_MATRIX.md) 及通過的 Xcode CI 為準。

## 原則

- 核心筆記、搜尋、OCR、錄音、轉錄、學習與智慧工具不要求訂閱或付費 API。
- 使用者資料預設留在 `.notepkg`、App 沙盒或使用者自行選擇的 Files／iCloud Drive 資料夾。
- 網路不是開啟筆記、搜尋、播放錄音或復原備份的必要條件。
- 所有大型媒體、模型與匯入資料都必須有容量、路徑、digest、交易與取消邊界。
- 「App 免費」不代表公開發佈零成本；App Store／TestFlight 仍受 [Apple Developer Program](https://developer.apple.com/programs/whats-included/) 的會員規則約束。

## 已建立的基礎

- Notebook、Quick Note、有限尺寸 Whiteboard、Text Document、Study Set。
- PencilKit 手寫、PDF／圖片／`.notepkg` 匯入、PDF 文字擷取、圖片與掃描 PDF OCR，以及有界的裝置端手寫辨識與人工 review。
- 本機 Library 搜尋、Editor 跨頁結果導覽、accepted-only 手寫搜尋、非生成式摘要／outline／quiz／meeting notes 與數學工具。
- 八種可編輯 canvas element：text、image、shape、connector、sticky、tape、sticker、link。
- 結構化元素的有界 PDF／圖片渲染與目前頁面分享。
- 耐久 audio session、串流匯入、跨頁時間標記、播放／seek、具操作檢查點 scene history 的 Note Replay，以及可原子保存並於重開後載入的 Apple Speech 裝置端逐字稿；舊錄音維持 final-stroke 相容。
- 原子 `.notepkg` transaction、驗證、復原、安全 snapshot、Files 備份與 restore。
- 經 SHA-256 驗證的本機模型套件管理；推論 runtime 尚未接線。

## P0：先關閉既有流程的缺口

1. 永久逐字稿
   - ✅ 同一筆 transaction 寫入 content-addressed transcript asset 並更新 audio descriptor。
   - ✅ 重新開啟筆記可載入並切換已保存的逐字稿。
   - ✅ 已保存逐字稿納入本機搜尋；Library 可命中逐字稿內容。
   - ✅ 可由同一個 identity-bound export session 分塊驗證並匯出單段 M4A，從已保存逐字稿產生有界 TXT／SRT；panel 內搜尋保留時間順序、支援前後導覽與命中截斷提示。

2. 整本扁平化 PDF
   - ✅ exporter 依頁序輸出不同 media box 的多頁 PDF。
   - ✅ 每頁包含背景、PencilKit ink、八種 canvas element 與安全 HTTP／HTTPS link。
   - ✅ Editor 整本分享入口、檔案式逐頁輸出、identity-validated export session、頁數及累積解碼工作量上限、取消與失敗清理。

3. Note Replay
   - ✅ renderer 支援 Whole Stroke、Spotlight、Static，並有有界工作量、最新 frame 勝出與安全 fallback；舊錄音使用 final-stroke 路徑。
   - ✅ playback controller 已處理跨頁時間線、seek、LRU、錯誤負向快取、生命週期與反序 async completion。
   - ✅ 真實音訊 transport、Editor 唯讀畫布、模式／scrubber／縮圖 seek、權威 drawing restore、寫入 fencing 與背景／離開生命週期已接線。
   - ✅ schema v3 以錄音機精確時鐘保存 baseline／change／terminal scene 事件；每個事件引用內容定址、去重且有界的完整 ink／element snapshots，因此 erase、transform、insert、update 與 delete 可在已提交操作邊界還原。
   - ✅ M4A、timeline、不可變 replay index 與 payloads 在同一 transaction 原子匯入；讀取綁定 point-in-time session、descriptor、byte count 與 SHA-256，損壞的 v3 history fail closed。
   - ✅ controller 依 `(time, sequence)` 選 scene 並使用 scene-level LRU；錄音期間禁止尚未建模的頁面新增、複製、刪除及重排。
   - ✅ 錄音後刪頁會在 transaction 內抹除受影響 v3 events、重封存 descriptor、保留仍被引用的共享 payload 並 GC orphan；空 history 保留音訊但停用 Replay。
   - ⏳ 如需超越 Whole Stroke，後續另設計筆尖 sample 級動畫及頁面背景／結構事件；既有 v1／v2 descriptor 不被破壞性改寫。
   - Goodnotes 的錄音與 replay 行為參考：[Audio Recording](https://support.goodnotes.com/hc/en-us/articles/7352688559631-Add-Audio-Recordings-to-your-documents)。

## P1：高價值、本機可完成

1. 搜尋完整性
   - ✅ Editor 已提供自適應跨頁結果 navigator、同頁聚合、`⌘F`／`⌘G`／`⇧⌘G`，並以保存與 generation fence 保護切頁。
   - ✅ Canvas text／sticky／link title 與耐久逐字稿已自動索引，並涵蓋啟動重建、複製、刪除及重新命名生命週期。
   - ✅ 頁面書籤／自訂大綱 metadata 已納入 Library 與 Editor 搜尋索引；完整中英文書籤關鍵詞使用精確 semantic query，大綱維持一般全文搜尋，兩者都保留原頁面目標。
   - ✅ 將 PKDrawing 有界、ink-only 渲染後交給裝置端 Vision，提供修正／Accept／Reject／Reset；machine candidates 與 review 分離交易保存，只有 ink fingerprint 仍相符的已接受文字進入搜尋。
   - 在 zooming page surface 內提供 OCR bounds／結構化 block 的精準命中反白；目前 navigator 只承諾頁級導覽。
   - 參考：[Goodnotes Search](https://support.goodnotes.com/hc/en-us/articles/7353743594127-How-to-Search-Your-Notes)。

2. 真正無限 Whiteboard
   - 可擴張 world coordinates、viewport persistence、minimap、fit content 與多 board。
   - connector edge snapping、持久 attachment ID 與 shape 移動後重新路由。
   - 參考：[Goodnotes Whiteboard](https://support.goodnotes.com/hc/en-us/articles/13693350308751-Whiteboard)。

3. Text Document schema v2
   - rich inline formatting、table、image／diagram block、slash command、drag reorder、link 與 PDF export。
   - 以明確 schema migration 保留舊文件。
   - 參考：[Goodnotes Text Documents](https://support.goodnotes.com/hc/en-us/articles/13692184123279-Text-Document)。

4. 導覽與 Library
   - ✅ Editor 已提供 page bookmark，以及可新增／修改／清除的平面自訂 outline；Navigator 可依全部／書籤／大綱保留原頁序導覽，metadata 以 schema v4 原子保存。
   - 巢狀 outline、批次 page 操作、rotate／crop、PDF 原有 link 與 outline。
   - nested folders、move transaction、drag／drop、folder color／icon 與 folder export。
   - 參考：[Outlines](https://support.goodnotes.com/hc/en-us/articles/7353757101071-Create-an-outline)、[Folders](https://support.goodnotes.com/hc/en-us/articles/15303674514191-Organizing-Folders-and-Documents)。

## P2：書寫、學習與日常工具

- 保存 pen／eraser／tool picker 設定，加入 ruler、laser、read-only、zoom window 與 toolbar customization。
- 強化 shape library、stroke style、arrow head、connector waypoint、image crop／flip、bullets、tape pattern 及 reusable collections。
- Study Set 加入 Practice Mode、CSV／TSV 匯入、語音朗讀及 Time Keeper。
- 透過 VisionKit 加入相機文件掃描；加入自訂 cover／paper template library。
- scene restoration、document tabs、multi-window、presentation mode 與外接顯示器體驗。
- 使用 LocalAuthentication／Keychain 做清楚標示的 access lock；真正的 per-notebook encryption 另列第二階段。

Goodnotes 2026 年近期功能基準可參考 [April–June 2026 round-up](https://www.goodnotes.com/blog/whats-new-in-goodnotes-april-june-2026)。Apple 公開的 iPad 工具基礎包括 [PencilKit tool picker](https://developer.apple.com/documentation/pencilkit/pktoolpicker)、[VisionKit document scanner](https://developer.apple.com/documentation/visionkit/vndocumentcameraviewcontroller) 與 [LocalAuthentication](https://developer.apple.com/documentation/localauthentication)。

## 需要後端的功能與免費等價方案

Goodnotes 的跨網路即時協作、hosted share link、Goodnotes Cloud、99 語言雲端轉錄、雲端 AI、GIPHY browse、Marketplace 及 SaaS connectors 不能同時滿足「永遠零後端成本」。官方即時協作行為參考：[Real-time Collaboration](https://support.goodnotes.com/hc/en-us/articles/13922131401615-Real-time-Collaboration-with-Live-Cursor-in-shared-documents)。

NextStep 採用下列替代方向：

- 近距離即時協作：Apple [Multipeer Connectivity](https://developer.apple.com/documentation/multipeerconnectivity)。
- 非同步協作：immutable snapshot + operation patch，經 AirDrop／Files 交換並顯示 conflict review。
- 多裝置傳輸：使用者選擇 iCloud Drive folder，配合 package locking、conflict copy 與 merge UI。
- Calendar：裝置端 [EventKit](https://developer.apple.com/documentation/eventkit)。
- AI：使用者匯入並驗證的本機模型；支援平台時條件採用 Apple 裝置端模型。
- GIF、template、sticker：由使用者從 Photos／Files 匯入，不複製第三方 Marketplace catalog。

## 法律與商店界線

- 維持 NextStep 自己的 app icon、interaction、color system、template 與 `.notepkg` 格式。
- 不使用 Goodnotes 商標、logo、screenshots、toolbar artwork、Marketplace asset 或 proprietary model。
- 上架前依 [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) 4.1 與 5.2 檢查仿冒、商標、著作權及 metadata。
- App 內 display name 為「NextStep」；正式商店名稱仍需確認可用性與識別性。
