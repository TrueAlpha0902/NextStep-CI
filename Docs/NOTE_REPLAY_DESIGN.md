# NextStep Note Replay 設計

更新日期：2026-07-13

## 產品基準

Goodnotes 的 Note Replay 會在播放錄音時同步顯示手寫，並提供三種模式：

- **Spotlight**：播放位置之後的手寫淡化，已播放部分維持完整顯示。
- **Real-time reveal**：Goodnotes 會在播放時逐步顯示手寫。NextStep v1 的對應模式命名為 **Whole Stroke**，只在第一個有效時間點顯示完整原始 stroke，不宣稱逐點重建。
- **Static**：播放時始終顯示目前完整手寫。

官方目前將 replay mode 限定在 iOS／macOS 的 notebook 文件，不套用到 Whiteboard 或 Text Document。參考：[Goodnotes Audio Recording](https://support.goodnotes.com/hc/en-us/articles/7352688559631-Add-Audio-Recordings-to-your-documents)。

NextStep 的實作必須完全離線，不使用 Goodnotes 資產、私有格式或雲端 API。

## 兩條相容資料路徑

### Schema v3：不可變 scene history

PencilKit 在 iPadOS 18 沒有可供永久格式依賴的穩定 stroke identity；擦除、分割或套索 transform 後，也不能安全地把最終 stroke 倒推成完整歷史。因此新錄音不保存私有 stroke ID，而是保存有界、不可變的完整頁面 scene：

1. `AudioSessionDescriptor` v3 以 `replayFilename`、byte count、SHA-256 與 event count 鎖定一份 sealed replay index。
2. index 依 append-only `sequence` 保存 `baseline`、`change`、`terminal` 事件；每筆都有 session／event／operation／page identity、錄音相對秒數，以及完整 ink／elements payload reference。
3. payload 以 SHA-256 content address 去重。`nil` ink 明確代表空白筆跡；elements snapshot 永遠存在，即使內容是空陣列。
4. M4A、timeline、index、payload assets 與 descriptor 在同一 repository transaction 驗證並提交；缺一、超限、digest 不符或來源不安全就整筆失敗。

### 舊錄音：final-stroke compatibility

沒有 Replay 欄位的舊 descriptor 不會被猜測或破壞性改寫。它仍以 `recordingStartedAt`、`durationSeconds`、`PKStrokePath.creationDate`、point `timeOffset` 與 page marks 對最後仍存在的 `PKDrawing` 分類。Apple 文件：[creationDate](https://developer.apple.com/documentation/pencilkit/pkstrokepathreference/creationdate)、[PKStrokePath](https://developer.apple.com/documentation/pencilkit/pkstrokepath-swift.struct)。這條路徑無法還原已被刪除或 transform 前的內容。

## 錄製規則

- 開始錄音前先排空 notebook pending writes；錄音機真正啟動後，使用它的相對時鐘保存目前 drawable page 的完整 baseline。
- 第一次造訪另一個 drawable page 時保存 baseline；PencilKit tool commit、undo／redo／clear及 canvas element edit 產生 change checkpoint。Ink／element scene 只由 Editor 的序列化語意操作來源送出；較晚完成的 durable-save acknowledgement 不得再送一筆舊 scene，避免 append-only history 出現假的狀態回退。內容相同的 scene 以 digest 去重，不製造重複事件。
- page marks 與 Replay capture 都使用有界、保序 queue。停止時先排空 notebook writes，再排空兩條 queue，最後在錄音 duration 為每個已捕捉頁面追加 terminal scene。
- 任一 capture、容量或一致性檢查失敗時取消錄音且不保存部分 history。只在 Text Document／Study Set 錄音而沒有 drawable scene 時，保存普通 audio session，不偽造空 Replay index。
- v1 history 尚未描述頁面新增、複製、刪除、重排或背景變更；錄音期間因此禁止頁面結構操作。
- 錄音完成後若永久刪除頁面，repository 會在同一 transaction 從所有受影響的 v3 index 移除該頁事件、重新編排連續 sequence、更新 descriptor 的 digest／byte count／event count，並只回收已無任何 session 引用的 Replay payload。若最後一筆事件也被移除，保留合法的 sealed empty v3 history：音訊仍可播放，但 Replay 明確停用，不退回目前頁面內容。

## 顯示規則

- `AudioTimelineDocument.marks` 先決定播放位置所屬頁面；同時間 marks 使用確定性排序。
- v3 history 只允許導向 index 內實際出現的頁面；0 秒時優先使用到期 baseline／最早有效 mark，不得用錄音後目前正在編輯、但未被錄到的頁面補位。
- Whole Stroke／Spotlight 對該頁選擇不晚於 playback time 的最後一筆 `(timeSeconds, sequence)` scene；如果播放位置早於第一個 change，就使用 baseline。
- Static 對 schema v3 顯示錄音封存時的 terminal scene，不讀取 Editor 目前較新的最終狀態。
- 選定 scene 後，Whole Stroke 與 Spotlight 仍以 snapshot 內公開的 PencilKit 時間資訊呈現完整原始 strokes；不裁切或重新合成可能改變語意的子路徑。
- 歷史 ink 與 elements 必須來自同一 event。v3 descriptor 若聲稱有 history，但 index 或任一 payload 無法驗證，Replay 必須 fail closed；不得偷偷退回目前 Editor scene。只有真正沒有 history 欄位的舊錄音可走 final-stroke compatibility。
- 播放期間畫布唯讀。停止 replay 後直接恢復 authoritative `drawingData` 與 elements，絕不把篩選後 frame 寫回 repository。

## 頁面與播放控制

- 播放位置使用 `marks` 中不晚於目前時間的最後一筆有效 page mark。
- marks 必須先依 `timeSeconds`、`createdAt`、ID 做確定性排序。
- seek、跨頁與快速切換 session 都要有 generation 檢查；舊 timer 或舊載入結果不得切換目前頁面。
- 使用者手動切頁時不新增 mark，除非當下真的正在錄音。
- Skip back／forward 以 10 秒為預設，並 clamp 至 `0...durationSeconds`。

## 完整度邊界

Schema v3 已能在已提交操作的檢查點間還原 stroke insert／erase／transform，以及 element insert／update／delete。這是 operation-boundary accurate 的 scene replay，不是正在落筆時每一個 sample 的連續動畫，也不保存套索拖曳中的中間 frame。Whole Stroke 刻意保留完整原始 stroke，不以重新取樣曲線冒充 PencilKit 原筆跡。

頁面結構、背景變更、無限畫布 viewport、跨裝置合併及錄音外的完整 undo history 仍未納入 v1 index。舊錄音則仍是 final-stroke replay；兩者都不應宣稱與 Goodnotes 的所有 replay 細節完全等價。

## 目前接線狀態

Editor 已接真實錄音 transport、獨立唯讀 PencilKit surface、Whole Stroke／Spotlight／Static、播放／暫停、scrubber、前後跳轉、跨頁縮圖 seek、安全停止及 scene／memory lifecycle。啟動前會先建立同步寫入 fence、取消並等待整本 PDF 工作、排空該 notebook 的 pending writes，再開啟 identity-validated replay read session。Controller 以 scene key 隔離 legacy page 與歷史 event，縮圖、倒轉 seek、模式切換及 terminal fallback 都有 page／mode／playback-time fencing，Replay frame 不會寫回 repository。

Windows 工作環境已通過靜態專案、localization 與差異檢查；真正的 Swift typecheck、XCTest、VoiceOver／Dynamic Type 與 iPad 實機驗證仍必須在 Xcode 26 runner 完成。

## 資源與安全上限

- index、事件數、每頁事件數、unique payload 數與 aggregate bytes 都有 hard ceiling；呼叫者只能要求更嚴格的讀取限制。
- ink 與 elements payload 分別有 byte／element count 上限，讀取綁定同一 point-in-time session、manifest descriptor、reference byte count 與 SHA-256。
- 單頁解析前先沿用現有 `PKDrawing` 檔案上限，不接受無界資料。
- 每 frame 最多處理有界 stroke／point 數；超限時退回 Static，而不是無界處理。
- frame 計算在 detached bounded worker 執行、可取消並以播放位置節流；舊 frame 不得覆寫新 session。PencilKit 的單次同步 decode 仍只能靠 1 MiB 輸入上限約束，不能在呼叫內搶先中斷。
- scene cache 以 event key 做 LRU 並計入歷史 elements；不建立每 frame 暫存檔，也不把使用者筆跡送出裝置。
- 低透明度 stroke 要保留原 ink type、寬度、transform 與 mask；不可只轉成低解析 raster 後冒充可縮放筆跡。

## 驗證清單

- baseline → ink change → erase／transform → element update → terminal 的事件、時間與 sequence 選擇。
- 相同 payload 去重、同秒事件排序、跨頁 baseline、停止前 queue drain，以及無 drawable scene 的 audio-only session。
- index／payload 缺失、digest／byte count／element count 不符、過期 read session 與 v3 fail-closed；舊 descriptor final-stroke compatibility。
- 刪除單頁後跨 session redaction、全域 sequence 重排、descriptor 重封存、共享 payload 保留、孤立 payload GC，以及刪除最後一個歷史頁面後 audio-only／empty-v3 行為。
- 錄音前、錄音中、錄音後 strokes 的三模式分類。
- 單 stroke 內第一個有效 point time offset、空路徑與不合法 metadata fallback。
- 非有限時間、零長度錄音、seek clamp、同時間 marks 的確定性排序。
- A→B→A 快速切頁、切換 session、背景／離開 editor 時取消。
- replay 期間不觸發 `onDrawingChanged`，停止後完整 byte-equivalent drawing 恢復。
- 大型 drawing 的工作量上限、取消延遲、記憶體峰值與長時間播放。
- Dynamic Type、VoiceOver mode／播放位置描述及 Reduce Motion 行為。
