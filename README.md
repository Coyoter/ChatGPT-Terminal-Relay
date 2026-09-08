# ChatGPT Terminal Relay

把 ChatGPT 給你的指令交給電腦執行，再將結果送回 ChatGPT。你只需要複製一次指令，不必反覆切換終端機。

**複製指令 → 自動執行 → 收集輸出與錯誤碼 → 填入 ChatGPT → 傳送**

支援 macOS 與 Windows，不需要 ChatGPT API Key。

## macOS 0.5.2 輸入框辨識修正與診斷

根據實際診斷紀錄，修正「ChatGPT 只有一個可寫入的輸入框，但名稱不在預設清單就被排除」的問題。優先比對已知名稱／識別碼；無法比對時，僅在符合條件的輸入框只有一個時採用它，有多個時仍停止回傳。另保留 0.5.1 新增的權限與回傳診斷。

- 自動記錄啟動版本及位置、目前輔助使用權限、指令是否收到與執行完成、ChatGPT 尋找結果、輸入框辨識數量、回傳中止原因及輔助使用 API 錯誤碼。
- 選單新增「檢查輔助使用權限…」及「開啟診斷紀錄」。沒有權限時，選單列顯示 `⇄ 權限`。
- 診斷檔位於 `~/Library/Application Support/ChatGPT Terminal Relay/diagnostics.jsonl`，超過 1 MiB 時保留一份前次紀錄。診斷檔不記錄指令、剪貼簿文字、輸出內容、草稿或對話標題；原本的完整指令輸出檔仍保留於 `Logs/`。
- 更新採用 ad-hoc 簽章的 App 後，設定中既有的開關可能仍對應舊版。若 Relay 回報沒有權限，請移除舊項目，重新加入**目前正在執行的 App 路徑**，再開啟權限。

Windows 維持 0.5.0，本次新增的診斷功能限 macOS。

## 0.5.0 的改變

- 回傳直接指定 ChatGPT 的輸入框及傳送按鈕，移除全域 Cmd+V／Enter。
- 回傳不再讀寫剪貼簿，等待期間複製其他文字不會把它當成結果傳送。
- 保護既有草稿；視窗、內容或輸入框狀態變更時停止回傳並保留結果。
- 新增「重試回傳上次結果」與「複製上次結果」。失敗後不會重新執行原指令。
- 大量輸出只回傳前段摘要，完整輸出保留在本機紀錄檔，避免一次塞滿 ChatGPT。
- macOS 執行檔的最低部署版本修正為 13.0。
- 新增 Windows x64 與 ARM64 可攜版，使用 PowerShell 執行指令。

**目前 0.5.0 是測試版。** 已包含自動化回歸測試；Windows 的實際 ChatGPT App 相容性仍需在使用者電腦驗證。若 ChatGPT 沒有提供可寫入的輔助使用／UI Automation 輸入框，Relay 會保留結果，讓你手動複製，不會改用全域鍵盤事件。不同版本或介面語言的 ChatGPT 可能需要調整控制項辨識。目前傳送按鈕辨識包含繁體中文、簡體中文及英文。

## 安裝

從 [GitHub Releases](https://github.com/Coyoter/ChatGPT-Terminal-Relay/releases) 下載對應 ZIP。

### macOS

1. 下載 `ChatGPT-Terminal-Relay-v0.5.2-macOS.zip`。
2. 解壓縮，把 `ChatGPT Terminal Relay.app` 放到 Applications。
3. 啟動 App，至「系統設定 → 隱私權與安全性 → 輔助使用」允許 Relay。
4. 開啟 ChatGPT macOS App，切到要使用的對話。選單列出現 `⇄ Relay` 即可使用。

Relay 的最低系統版本為 macOS 13，套件為 Apple Silicon；ChatGPT App 本身的系統需求另計。採 ad-hoc 簽章，未經 Apple Developer ID 公證。更新後 macOS 可能要求重新啟用輔助使用權限。舊版可正常使用時，建議先保留舊 App 作為回復備份。

### Windows

1. 一般 Intel／AMD 電腦下載 `Windows-x64.zip`；Windows ARM 電腦可下載 `Windows-arm64.zip`。
2. 解壓縮至你要保留的資料夾，執行 `ChatGPTTerminalRelay.exe`。
3. 開啟已安裝的 ChatGPT Windows App，選擇對話。Relay 會出現在右下角系統匣，可能收在「隱藏的圖示」裡。
4. 首次使用前，把下面「給 ChatGPT 的專案提示」中的 Windows 提示貼到對話，讓它產生 PowerShell 指令。

Windows 版包含 .NET 執行環境，不必自行安裝 .NET、Python、WSL 或額外終端機。使用一般權限執行；ChatGPT 也應以一般權限執行。套件尚未經 Windows 程式碼簽章，系統可能顯示不明發行者提示。適用 Windows 10／11；ChatGPT App 本身的系統需求另計。

優先使用 `Program Files/PowerShell/7/pwsh.exe`，未安裝時使用 Windows 內建 Windows PowerShell 5.1。Shell 在背景執行，不會每次跳出終端機視窗。CMD、Git Bash 與 WSL 不會自動互相切換，請讓 ChatGPT 產生 PowerShell 指令。

## 指令格式

只有**第一行完全等於** `# CHATGPT_RUN` 的內容會執行，支援 LF 與 Windows CRLF 換行。一般複製文字不會執行。相同指令在 3 秒內重複複製只執行一次。

macOS 範例：

```zsh
# CHATGPT_RUN
printf 'Hello from macOS\n'
sw_vers
```

Windows 範例：

```powershell
# CHATGPT_RUN
Write-Output 'Hello from Windows'
$PSVersionTable.PSVersion
```

每次執行都是新的 Shell；上一個指令的 `cd` 與變數不會保留。要處理某個專案時，請讓每段指令自行切換到專案資料夾。Windows 預設工作資料夾是使用者家目錄；macOS 請在指令中明確指定路徑。

同一時間處理一個指令。請等上一次完成再複製下一個；Relay 不提供指令佇列。標記代表允許執行，並不是沙盒，請只複製你打算執行的指令。

## 回傳與恢復

```text
EXIT_CODE: 0

OUTPUT:
Hello from Windows
```

回傳時會喚醒 ChatGPT、尋找可編輯輸入框、確認內容，再操作該視窗的傳送按鈕。不會覆寫既有草稿，也不會向其他軟體送出鍵盤事件。若切換視窗、輸入內容被更動、ChatGPT 尚未就緒或權限不足，結果會保留。

- **重試回傳上次結果**：先開啟 ChatGPT，選擇對話並清空自己的草稿，再使用此選項。若輸入框已經是相同結果，不會重複插入文字。
- **複製上次結果**：由你手動貼回；只有這個明確操作會將結果寫入剪貼簿。
- **停止監聽**：不再接收新指令，並中止等待中的自動回傳；不會撤回已傳送的訊息，也不會終止已在執行的 Shell。
- **取消執行中的指令**：Windows 版可從系統匣終止 PowerShell 與它的子程序。

「已交付傳送」表示已呼叫 ChatGPT 的傳送按鈕，不代表伺服器已成功接收。網路或 ChatGPT 出現問題時，請先查看對話，再決定是否重試，避免重複傳送。

## 本機紀錄

回傳只保留約前 64 KiB／64K 字元的預覽；較長的完整輸出另存紀錄檔，路徑會列在結果中。

- macOS：`~/Library/Application Support/ChatGPT Terminal Relay/`
- Windows：`%LOCALAPPDATA%/ChatGPTTerminalRelay/`

`last-result.txt` 保留上次結果，`Logs/` 保留完整輸出。紀錄可能包含你的指令輸出，請按需求自行清理。Relay 不會自行上傳這些檔案。正常回傳會把結果預覽交給 ChatGPT；檢查更新會連線 GitHub。

## 給 ChatGPT 的專案提示

見 [PROJECT_PROMPT.md](PROJECT_PROMPT.md)，分別提供 macOS 與 Windows 可直接貼上的完整提示。

## 更新

每次啟動時檢查 GitHub 的最新正式 Release，也可手動選擇「檢查更新…」。只提供通知或開啟下載頁，不會自行下載或安裝。測試版需自行前往 Releases 下載。

## 從原始碼建置

macOS 需 Apple Command Line Tools：

```sh
./tests/run-macos.sh
./build.sh
```

Windows 需 .NET 10 SDK：

```powershell
dotnet build windows/ChatGPTTerminalRelay.csproj -c Release
dotnet windows/bin/Release/net10.0-windows/ChatGPTTerminalRelay.dll --self-test
./build-windows.ps1 -Runtime win-x64
./build-windows.ps1 -Runtime win-arm64
```

產物位於 `dist/`。GitHub Actions 會在 macOS 與 Windows 執行測試、打包；Windows 另測試打包後的 x64 EXE。`--ui-fixture` 是獨立測試視窗，驗證 UI Automation 填字及按鈕呼叫，不會控制真實 ChatGPT。

## License

MIT
