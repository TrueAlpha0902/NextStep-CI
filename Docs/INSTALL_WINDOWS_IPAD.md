# 從 Windows 建置並安裝到 iPad

本專案的 Windows 路徑不需要本機 Mac：

```text
Windows 的乾淨 TrueAlpha0902/Notes private worktree
    → 同一 HEAD tree 的 parentless root snapshot
    → TrueAlpha0902/NextStep-CI public mirror／main
    → 公開 GitHub Actions（macos-26／Xcode 26）
    → Notes-unsigned-ipa artifact（IPA + install manifest）
    → Windows Sideloadly 以個人 Apple Account 簽署
    → iPad
```

unsigned IPA 不能直接安裝。GitHub Actions 只負責編譯與封裝，不保存 Apple 帳密、簽署憑證或 provisioning profile；簽署發生在使用者自己的 Windows 電腦。

`TrueAlpha0902/Notes` 是權威 private repository。`TrueAlpha0902/NextStep-CI` 只保存目前檔案樹的單一根提交，不包含 private commit history；但該 snapshot 的所有檔案仍是公開的。發布方式、安全邊界與秘密掃描請見 `Docs/CI_MIRROR.md`。

## 先確認目前驗證狀態

Repository 已包含 Xcode 26 workflow 與單元／UI test targets，但**設定檔存在不代表 build 已通過**。請以 public mirror 上、與目前 private `HEAD^{tree}` 完全相同的 root snapshot 所執行之最新 `iOS CI` run 為準：只有 `Build, test, and package` 全部綠燈，而且 run 底部確實有 `Notes-unsigned-ipa` artifact，才表示該份 source tree 產生了可供 Sideloadly 重新簽署的檔案。

本文件不是 CI 通過證明；若還沒有綠燈 run，就先修正 build／test 問題，不能跳到安裝步驟。

## 1. 準備

- 可執行 Git 與瀏覽器的 Windows 10／11 電腦。
- 支援 iPadOS 18、可開啟 Developer Mode 的 iPad。
- 可讀取 `TrueAlpha0902/Notes` 的 GitHub CLI 登入狀態；CI artifact 來自設定中的公開 `TrueAlpha0902/NextStep-CI`。
- 從 [Sideloadly 官方網站](https://sideloadly.io/) 安裝 Windows 版。
- 一個 Apple Account（原 Apple ID）；免費側載不要求加入付費 Apple Developer Program。
- 穩定 USB 連線；第一次配對與疑難排解時建議先使用有線連線。

建議建立專門用於側載的 Apple Account，並為它開啟雙重驗證。不要把 Apple 密碼、兩步驗證碼、app-specific password、憑證、token 或 provisioning profile 放進 GitHub repository、Actions Secrets、issue 或 log。

依 Sideloadly 目前的 Windows 說明，必須使用 Apple 網站下載的傳統桌面版 iTunes 與 iCloud；Microsoft Store 版 iTunes／iCloud 及 Apple Devices App 不能取代這組相依元件。若官方之後調整需求，應以 [Sideloadly 官方網站](https://sideloadly.io/)與 [FAQ](https://sideloadly.io/faq.html) 為準。本專案的檢查腳本只會診斷，不會安裝、移除或啟動這些軟體。

## 2. 發布不含 private history 的 CI snapshot

本機 `origin` 必須是 `TrueAlpha0902/Notes`，且目前 branch 的精確 HEAD 已推到它的 `origin` upstream。提交前執行：

```powershell
.\scripts\validate-project.ps1
git status
git diff --cached
```

確認沒有 Apple 帳密、token、使用者筆記、模型檔、IPA、build 目錄或產生出的 `Notes.xcodeproj`。這個 PowerShell script 只做不需要 Xcode 的結構、資源及 localization 檢查，不能代替 Swift 編譯與測試。

先做只讀預檢，再明確發布：

```powershell
.\scripts\Publish-CIMirror.ps1
.\scripts\Publish-CIMirror.ps1 -Publish
```

發布器只把 `HEAD^{tree}` 包成一個無 parent 的新 commit，更新設定中的 `TrueAlpha0902/NextStep-CI` `main`。它不會推送 private branch、tag 或 history。每次 mirror commit SHA 可能不同；安裝器以 **Git tree SHA** 證明它與 private HEAD 的內容完全相同。

### 控制 Actions 費用

本方案把 Xcode CI 放在 public mirror，使用 GitHub 對公開 repository 提供的標準 hosted runner 路徑，避免消耗 private-repository macOS runner 分鐘。不要改用 larger runner 或額外付費服務；仍建議在 **Settings → Billing and licensing → Budgets and alerts** 設定 Actions **US$0** 預算與 **Stop usage when budget limit is reached** 作為帳號層 hard stop。GitHub 計費政策與介面可能更新，請以 [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions) 與 [budgets and alerts](https://docs.github.com/en/billing/concepts/budgets-and-alerts) 為準。

## 3. 執行 Xcode 26 workflow

Workflow 位於 `.github/workflows/ios-ci.yml`。正常發布是由 snapshot push 到 public mirror 的 `main` 後執行；也可在 public mirror 上手動 dispatch。

手動執行：

1. 開啟 `TrueAlpha0902/NextStep-CI` 的 **Actions**。
2. 選擇 **iOS CI**。
3. 選擇 **Run workflow** 與要驗證的 branch。
4. 等待 `Build, test, and package` 完成。

目前 workflow 的預定步驟是：

1. 在 `macos-26` runner 確認 Xcode 26。
2. 安裝 XcodeGen，執行 `scripts/validate-project.sh`，產生 `Notes.xcodeproj`。
3. 選擇可用的 iPad 與 iPhone simulator。
4. 執行 project 所列的 NextStep domain、planning、sync、design、app、services、academic 與 UI 測試，並驗證兩種尺寸的核心畫面。
5. 以 `CODE_SIGNING_ALLOWED=NO` 建置 generic iOS device app。
6. 封裝 `Notes-unsigned.ipa`，產生綁定 repository／commit／run／workflow／IPA hash／NextStep identity 的 `install-manifest.json`，把兩個檔案放在同一個 artifact 中並保留 7 天。

`Bind build to source commit` 會以 event payload 與 `git rev-parse HEAD` 交叉確認。manifest 中的 repository、repository ID 與 commit SHA 必須是 public mirror 本身及該 root snapshot；Windows 安裝器再把這個 snapshot 的 tree 反向綁定至 private HEAD。來自其他 repository、其他 branch、其他 commit 或舊 run 的 artifact 都不會被接受。

任何一步失敗都不應下載舊 artifact 當作本次結果。先確認 run 的 commit SHA、branch 與修正後的新 run 全綠。

## 4. 下載 unsigned IPA

1. 開啟 `TrueAlpha0902/NextStep-CI` 上已成功完成的 workflow run。
2. 在 run 頁面底部的 **Artifacts** 選擇 `Notes-unsigned-ipa`。
3. 下載 ZIP 並解壓縮；根目錄必須恰好有 `Notes-unsigned.ipa` 與 `install-manifest.json`。舊 run 若缺少 manifest，必須重跑目前 workflow，不可相容回退。
4. 核對它來自要安裝的 mirror snapshot；artifact 逾期或 run 已刪除時，對目前 snapshot 重新執行 workflow。

GitHub artifact 下載介面可參考 [GitHub 官方文件](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts?tool=webui)。不要從設定以外的 mirror、release、聊天附件或第三方連結下載 IPA。

## 5. 使用 Sideloadly 簽署與安裝

1. 以 USB 將 iPad 連到 Windows，解鎖 iPad。
2. iPad 出現提示時選擇信任電腦，並輸入裝置密碼。
3. 確認 iTunes／Apple 裝置元件能看到 iPad。
4. 開啟 Sideloadly，把 `Notes-unsigned.ipa` 拖入視窗。
5. 在 Device 選擇正確 iPad。
6. 輸入用於個人簽署的 Apple Account；若帳號要求額外驗證，依 Sideloadly 顯示與 Apple 官方流程完成。
7. 保留 bundle ID `com.speci.localnotes`，並使用與先前安裝相同的 Apple Account。
8. 開始簽署與安裝，等候完成訊息。

同一部 iPad 更新 NextStep 時，維持**相同 Apple Account 與 bundle ID**，才最有機會覆蓋既有 App container。不要為了更新而先刪除 NextStep；刪除 App 可能同時刪除它在本機 container 內的 library。

Sideloadly 的設定名稱與行為可能更新，請以 [Sideloadly FAQ](https://sideloadly.io/faq.html) 為準。

## 6. 在 iPad 啟用 Developer Mode 與信任

安裝後若系統要求 Developer Mode：

1. 開啟 **設定 → 隱私權與安全性 → 開發者模式**。
2. 重新啟動 iPad。
3. 開機後確認啟用。

若 Developer Mode 尚未出現，先完成一次側載、保持 iPad 與 Windows 配對，再重新檢查設定。Apple 步驟可參考 [Enabling Developer Mode on a device](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。

若開啟 NextStep 時顯示未信任開發者，依 iPadOS 當前介面到 **設定 → 一般 → VPN 與裝置管理**，選擇對應 Apple Account 並信任，再重新開啟 NextStep。

## 7. 免費帳號的 7 天重簽

免費 Apple Account 的個人簽署通常只有約 7 天效期；Apple 規則與 Sideloadly 自動 refresh 支援可能變動。可選擇：

- 使用 Sideloadly 支援的自動 refresh，讓 Windows 服務在條件允許時重新簽署。
- 在到期前，把同一個 `Notes-unsigned.ipa` 或較新的綠燈 build 再放入 Sideloadly，使用相同 Apple Account 與 bundle ID 覆蓋安裝。

重簽通常不應清除 App container，但它不是備份機制。不要等到唯一資料副本出問題才測試恢復流程。

## 8. 備份與還原 `.notepkg`

完整 notebook snapshot 備份可直接從 Settings 操作：

1. 開啟 **Settings → Backup and restore → Choose backup folder**。
2. 選擇與目前 library 不同的 Files／iCloud Drive／外接儲存資料夾。
3. 點 **Back up now**；NextStep 會先等待未完成筆跡保存，再逐本建立 Core 驗證快照，最後提交整批 backup。
4. 歷史清單會顯示時間與 notebook 數量；點一筆後確認即可 restore。

Restore 採全有或全無：只要目前 library 已有任何相同 notebook ID，就不覆寫、不改名，也不提交其他筆記。要做完整災難復原，先在 Settings 把 library location 切到一個空資料夾，再執行 restore。現行整批 backup 保存所有 `.notepkg`，但尚未包含 library sidecar 中的 trash／kind／cover 外觀，因此還原後這些 UI 狀態可能被重新推斷。

也可對重要筆記做手動單本備份：

1. 在 NextStep 的 grid／list 對筆記開啟 context menu。
2. 選擇 **Share notebook**。
3. 把產生的 `.notepkg` 存到使用者控制的 Files／iCloud Drive／外接儲存位置。
4. 確認目的檔存在，並定期在另一位置保留第二份副本。

此分享流程使用 Core `exportSnapshot` 產生並驗證 snapshot，不會直接分享正在變動的 live package；但它只備份一個 notebook。

還原時，可在 NextStep 選擇 **Add → Import file** 後選 `.notepkg`，或從 Files 用 NextStep 開啟。匯入會拒絕損毀 package、symbolic link 及 library 中已存在的相同 notebook ID；目前沒有自動重新編號或 merge UI。若是同 ID 衝突，先確認既有版本與備份內容，不要直接刪除唯一可用副本。

## 9. 更新 NextStep

1. 把要發布的 private source commit 推到它的 `origin` upstream，並發布新的 parentless CI snapshot。
2. 等 public mirror 的 `iOS CI` 對該 snapshot 全綠，再由安裝助手取得新的 `Notes-unsigned.ipa`。
3. 先分享重要 `.notepkg` 到 Files 作備份。
4. 使用相同 Apple Account 與 `com.speci.localnotes` 在 Sideloadly 覆蓋安裝。
5. 開啟 App，檢查 library、筆跡、匯入背景、內容搜尋與重要筆記。

如果新版涉及 `.notepkg` schema 變更，先做完整備份；不要以「刪除再安裝」作為一般更新方式。

## 10. Windows 免費安裝助手

Repository 內的 PowerShell 助手把容易選錯 artifact 的步驟自動化，但刻意不繞過 Apple 的安全提示。所有腳本相容 Windows PowerShell 5.1；不會安裝第三方軟體、不讀取 Sideloadly cache、不要求或保存 Apple Account、密碼、2FA 驗證碼、GitHub token、裝置名稱或 UDID，也不使用 SendKeys 或猜測未公開的 Sideloadly CLI。

先在 repository 根目錄執行唯讀檢查：

```powershell
.\scripts\install-ipad.ps1 -Check
# 若要給程式讀取，使用不含帳密與裝置識別碼的 JSON：
.\scripts\install-ipad.ps1 -Check -Json
```

檢查結果分成 `Pass`、`Warn`、`Block` 與 `Manual`。`Block` 必須先處理；`Warn` 通常不阻擋 USB 安裝；`Manual` 是 Apple 或 iPad 要求使用者親自確認的步驟。

取得可安裝檔時執行：

```powershell
.\scripts\install-ipad.ps1 -Prepare
```

`-Prepare` 預設要求乾淨的 private worktree。助手從目前 private HEAD 讀取已提交的 `Config/CIMirror.json`，且只支援 `TrueAlpha0902/Notes` → `TrueAlpha0902/NextStep-CI`／`main`／`single-root-snapshot` 這條信任路徑。它先驗證本機 `origin` 與 GitHub 上的 authoritative source 確實是設定中的 private standalone repository，再讀取 public mirror 的精確 `main` ref 與 Git commit object；mirror commit 必須沒有 parent、具有發布器的識別 message，且 Git tree SHA 必須與本機 `HEAD^{tree}` 完全相同。

通過 source-to-mirror tree 綁定後，助手才把每一個 GitHub CLI API request 明確固定到 `github.com`（不採用 `GH_HOST` 或 enterprise token 的 host routing），並確認 public mirror 的 canonical repository／visibility／default branch、`.github/workflows/ios-ci.yml` workflow ID／path、精確 run database ID／attempt／`main`／mirror HEAD SHA、`push` 或 `workflow_dispatch` event，以及唯一且未過期的 `Notes-unsigned-ipa` artifact ID、repository ID、outer ZIP 大小與 GitHub SHA-256 digest。下載時依 artifact ID 以 2 GiB hard cap、30 分鐘總期限與 60 秒無進度期限串流保存原始 `artifact.zip`，不按 artifact 名稱猜測下載；逾時或失敗會終止 child process 並清除未完成檔案。

接著助手要求 outer ZIP 恰好包含 `Notes-unsigned.ipa` 與 canonical `install-manifest.json`，交叉核對 mirror repository／mirror commit／run／workflow、IPA SHA-256／大小、`Notes.app`、bundle ID `com.speci.localnotes` 與顯示名稱 **NextStep**，並以 8 GiB inner cap 完整讀取 IPA、拒絕 traversal、Windows reserved name、trailing dot／space、reparse point 與非 regular ZIP type。驗證後用 directory atomic move 發布到 `.local\ipad-install\<mirror SHA>-run<run ID>-attempt<attempt>-artifact<artifact ID>`，保留 `artifact.zip` 供每次 cache reuse 對照最新 API digest，發布後再做一次完整驗證。完整 provenance cache key 可避免同一 snapshot 的不同 run／attempt／artifact 互相覆蓋。它不會退回其他 source tree 或 mirror commit 的「最近成功版本」、不會信任本機自證 metadata，也不會觸發 workflow。

要先做完全不寫檔、不啟動 GUI 的稽核，可執行：

```powershell
.\scripts\Get-VerifiedUnsignedIPA.ps1 -DryRun
# working tree 有刻意保留的變更時，必須同時釘選 private HEAD、mirror snapshot 與 run：
.\scripts\Get-VerifiedUnsignedIPA.ps1 -AllowDirty -Commit <private HEAD 40字元SHA> -MirrorCommit <public root snapshot 40字元SHA> -RunId <run id> -DryRun
.\scripts\install-ipad.ps1 -Prepare -AllowDirty -Commit <private HEAD 40字元SHA> -MirrorCommit <public root snapshot 40字元SHA> -RunId <run id>
```

`-Repository` 是選用的額外 assertion，只接受 `TrueAlpha0902/NextStep-CI`；不能用它把下載器改指其他 repository。`-Commit` 表示 private source HEAD，`-MirrorCommit` 表示 public root snapshot，兩者不是同一個 object ID；它們靠完全相同的 Git tree SHA 建立內容等價關係。

這組助手不要求安裝 Pester。若維護電腦沒有 Pester，可先用 PowerShell 內建 parser 做不執行腳本的語法檢查，再跑上面的唯讀 `-DryRun`：

```powershell
$files = @(
    Get-Item .\scripts\Test-IPadInstallPrerequisites.ps1
    Get-Item .\scripts\Get-VerifiedUnsignedIPA.ps1
    Get-Item .\scripts\Open-IPadInstaller.ps1
    Get-Item .\scripts\install-ipad.ps1
)
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$errors
    )
    if ($errors.Count -gt 0) { throw "PowerShell syntax error: $($file.Name)" }
}
```

下載器的離線安全回歸不需要 Pester，也不會連線或保留測試檔；它會在系統暫存目錄建立合成 mirror metadata、IPA 與 artifact，測試 config redirect／duplicate key、parentless root、source-tree equality、branch／commit pin、repository visibility、hash tamper、manifest provenance、ZIP path／type／size cap 與 atomic publish race，完成後刪除：

```powershell
.\scripts\test-ipad-artifact-verifier.ps1
.\scripts\test-ipad-explorer-environment.ps1
```

這些 fallback 不會下載 artifact、啟動 GUI 或改變系統設定。第一支覆蓋 source-to-mirror、artifact provenance、hash、ZIP 邊界、timeout 與 atomic publish；第二支驗證 Explorer child 只取得最小環境 allowlist，且父程序環境完全不變。`-DryRun` 只做本機 Git tree 與 GitHub mirror／workflow／run／artifact metadata 的讀取驗證，仍會拒絕非 root snapshot、tree 不同、錯 branch、錯 workflow path、run ID、mirror commit、artifact digest 或大小。

環境與 artifact 都通過後，可讓助手把檔案安全交給 Sideloadly：

```powershell
.\scripts\install-ipad.ps1 -Open
```

`-Open` 會重新檢查環境與 artifact，接著只用已驗證的 Windows Explorer 精確選取 IPA；它不會執行 `.ipa` file association，也不會從目前的 GitHub shell 啟動第三方程式。Explorer child 不經 shell，會先清空繼承環境，再只加入 Windows shell 所需且經路徑驗證的最小 allowlist，因此不會收到 GitHub、Apple、cloud、cookie、connection string 或 SSH agent 等 developer-shell secrets。請從你安裝時建立且信任的 Start menu／桌面捷徑開啟 Sideloadly，再把 Explorer 已選取的 IPA 拖入。這個刻意保留的一次人工動作，可避免受竄改的 association、額外啟動參數或 shell token 被交給第三方程式。助手不會代填帳密或自動按下簽署／安裝按鈕。

### 第一次仍須人工完成

1. 從官方來源安裝 Sideloadly、傳統桌面版 iTunes 與 iCloud，依安裝程式要求重開 Windows；不要讓助手代裝軟體。
2. 準備 Apple Account、2FA，以及 Apple 要求的 developer agreement；只在官方 Apple／Sideloadly UI 輸入。
3. 用可傳資料的 USB 線連接並解鎖 iPad，在 Windows 與 iPad 接受 **Trust／信任此電腦**。
4. 在 Sideloadly 選對 iPad，完成第一次登入與 2FA；更新時固定使用相同 Apple Account 與 `com.speci.localnotes`，並視需要啟用 automatic refresh。
5. 第一次啟動側載 App 時，依 iPadOS 提示開啟 **Settings → Privacy & Security → Developer Mode**，重新啟動並輸入 iPad 密碼確認。
6. 若 iPadOS 要求，再到 **Settings → General → VPN & Device Management** 信任該 developer profile。

Apple 的 USB trust 與 Developer Mode 都是裝置端安全界線，不能由 Windows 腳本安全代按；參考 Apple 的 [Trust This Computer](https://support.apple.com/en-us/109054)、[USB 連線說明](https://support.apple.com/en-us/108643) 與 [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。

### 之後最接近「只插 USB」的流程

第一次設定完成後，讓 Windows 開機且 Sideloadly／自動 refresh daemon 正常執行，再把已配對的 iPad 接上 USB 並解鎖；在登入 session、profile 與信任狀態仍有效時，Sideloadly 可執行例行 refresh。若要安裝新的 NextStep build，仍先執行 `-Prepare` 或 `-Open`，並在 Sideloadly 確認裝置與安裝。登入過期、2FA、重新信任、Developer Mode 或 iPadOS 的提示永遠可能需要人工處理，因此無法誠實保證每一次都零點擊。不要為了更新刪除 NextStep，應以相同 Apple Account 與 bundle ID 覆蓋安裝。

免費 Personal Team 簽署的 App 與 provisioning profile 有效期是 **7 天**，並受 Apple 的裝置與 App ID 數量限制；到期前必須 refresh／重新簽署。這是 Apple 免費簽署的限制，不是本助手能解除的限制。詳見 Apple 的 [免費開發帳號說明](https://developer.apple.com/help/account/basics/about-your-developer-account/) 與 [Sideloadly FAQ](https://sideloadly.io/faq.html)。Sideloadly 與 Apple 免費簽署可以不付費使用；Xcode CI 固定在 public mirror 的標準 GitHub-hosted runner，並以 US$0 budget hard stop 防止未來設定變更意外產生付費用量。

## 疑難排解

### Workflow 沒有 artifact

先確認 public mirror job 是否全綠、是否正在看目前 `main` root snapshot，以及 `Package unsigned IPA`／`Generate unsigned IPA install manifest`／`Upload unsigned IPA` 是否執行。若 private `HEAD^{tree}` 已不同，先發布新 snapshot；不要使用舊 tree 的成功 artifact。artifact ZIP 少了 IPA 或 manifest、包含第三個檔案、來自舊 workflow、已過期或 API 沒有 SHA-256 digest 時都不可使用，必須以目前 mirror snapshot 產生新的成功 run。

### Sideloadly 看不到 iPad

- 解鎖 iPad、重新確認信任提示，並更換 USB 線或 port。
- 確認 Windows 的 Apple 裝置驅動與 iTunes／iCloud 元件可辨識 iPad。
- 重新啟動 Windows、iPad 與 Sideloadly。

### NextStep 顯示無法驗證或到期

通常是免費簽署過期、裝置信任或網路驗證問題。以相同 Apple Account 與 bundle ID 重新簽署覆蓋，並依 Apple／Sideloadly 當前提示完成信任。

### 安裝後看不到舊筆記

先不要反覆刪除／安裝。到 Files 檢查先前選擇的資料夾與其中 `Notes` 目錄，並確認是否改了 bundle ID、Apple Account 或 library location。若舊 App 已被刪除，本機 container 可能已不可恢復；從先前分享的 `.notepkg` 逐本匯入。

## 安全檢查清單

- `TrueAlpha0902/Notes` 保持 Private，定期檢查 collaborator 權限。
- `TrueAlpha0902/NextStep-CI` 只接受經發布器建立的 parentless root snapshot；它的檔案內容是公開的，因此發布前必須人工審查與秘密掃描。
- 安裝助手只接受設定中的 source／mirror／branch，且 mirror tree 必須精確等於 private HEAD tree。
- GitHub 不保存 Apple 密碼、驗證碼、token、憑證、provisioning profile 或使用者筆記。
- 只從官方來源取得 Sideloadly 與 Apple 元件。
- 只安裝對應到已驗證 commit、全綠 run 的 artifact。
- 使用專門側載帳號、雙重驗證及相同 bundle ID 覆蓋更新。
- 定期將重要 `.notepkg` 複製到第二個儲存位置；不要把重簽視為備份。
