# NextStep Windows Contract Preview

這是一個免費、完全在本機執行的互動介面合約預覽。它用來讓 Windows 電腦先驗證 NextStep 的資訊架構、iPhone／iPad 排版與核心操作流程。

> **Contract preview — not the iOS app.** 這不是 Apple Simulator，也不是將 SwiftUI App 移植到瀏覽器。

## 啟動

在 repository 根目錄開啟 PowerShell，執行：

```powershell
powershell -ExecutionPolicy Bypass -File .\PreviewWeb\Start-Preview.ps1
```

預設會開啟 `http://127.0.0.1:4173/`。保持 PowerShell 視窗開啟；要停止時按 `Ctrl+C`。

若 4173 已被使用，可改用其他本機連接埠：

```powershell
powershell -ExecutionPolicy Bypass -File .\PreviewWeb\Start-Preview.ps1 -Port 4180
```

## 建議操作路徑

1. 用頂部切換器比較 `iPhone compact` 與 `iPad regular`。iPhone 使用底部分頁與單欄內容；iPad 使用側邊欄、寬版工作區與來源 Inspector。
2. 在 Today 點「開始引導任務」，依序操作先備概念、指定閱讀、理解檢核與完成產出。
3. 回 Today 查看完成後的進度更新。
4. 點「我今天時間不足」，選擇剩餘時間並檢查重新排程提案。
5. 從導覽查看來源閱讀器、Goals 時間軸，以及論文／作品／求職 Workspace。
6. 切換 Light／Dark，確認長時間閱讀時的層級與對比。

示範進度與偏好只保存在瀏覽器的 `localStorage`，不會上傳或連接任何外部服務。「重設示範」會清除流程狀態，但保留裝置與明暗偏好。

## 驗證

```powershell
powershell -ExecutionPolicy Bypass -File .\PreviewWeb\Test-Preview.ps1
```

驗證會檢查：

- 所有資產皆為本機檔案，CSP 禁止網路連線。
- iPhone 與 iPad 裝置合約存在。
- Today → Guided Learning → 完成 → Replan → Sources／Goals／Workspace 狀態轉換。
- PowerShell 本機伺服器能正確回應入口頁。

若電腦有 Node.js，還會執行 JavaScript 語法與狀態機 smoke tests；沒有 Node.js 時仍可啟動預覽，該項檢查會清楚標示為跳過。

## 明確限制

- Windows 無法執行 Apple 官方 iOS／iPadOS Simulator；真正 SwiftUI 畫面仍需 macOS CI、Mac 或 iPhone／iPad 實機驗證。
- 這裡不會模擬 Apple Pencil、第三方觸控筆、PencilKit、Apple Intelligence、相機、Files 文件選擇器或背景同步。
- 來源內容是明確標示的自有 fixture，不是真實論文，也不會捏造 DOI、作者或研究結論。
- 此預覽不測量原生動畫、觸控延遲、VoiceOver 或 Dynamic Type 的實機行為；它只呈現預定的響應式與無障礙合約。
- 正式 V1 的 iPhone／iPad 同步實作與衝突處理不在這個 browser twin 中執行。

## 技術界線

此資料夾沒有 npm 套件、付費服務、遠端字型、分析工具或外部 CDN。入口由小型 PowerShell `TcpListener` 靜態伺服器提供，避免額外安裝依賴。`core.mjs` 保持純狀態轉換，讓介面流程能以 Node.js 做可重複的 smoke test。
