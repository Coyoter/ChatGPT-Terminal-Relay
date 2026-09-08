# ChatGPT Terminal Relay

當 Codex 額度用完、專案還沒做完時，讓 ChatGPT 的 **Chat 模式**接手本機工作。

把原任務、專案路徑與目前進度交給 ChatGPT，Relay 負責接續：

**取得指令 → 本機執行 → 收集輸出、錯誤與結束碼 → 回傳 ChatGPT → 等待下一步。**

Relay 是獨立的本機程式，不使用 Codex 的工具服務，也不需要 OpenAI API Key。ChatGPT Chat 模式本身仍需要可用的帳號與用量。

## macOS 0.6.1

0.6.1 修正「輔助使用的複製動作回報成功，但剪貼簿未更新」：先確認結果，必要時對同一個已驗證、可見的複製按鈕做滑鼠點擊；若仍未複製成功，就停止並在選單列顯示 `⇄ 查看`。

### 只按複製

啟動後預設使用這個模式。ChatGPT 給出指令時，你只需按程式碼區塊的「複製」，Relay 就會執行並回傳。

### 全自動接續

1. 開啟要接手工作的 ChatGPT Chat 對話。
2. 在 Relay 選單選「選擇專案並複製接手提示…」，選擇專案資料夾。
3. 把提示貼到 ChatGPT，補上原任務與 Codex 最後的進度摘要。
4. 在 Relay 選單選「啟動全自動接續」，再送出任務。
5. 保持這個 ChatGPT 視窗在前景。Relay 會等待回答完成、自動複製下一段指令、執行，再將結果送回。

如果已經拿到第一段指令，也可以先啟動全自動模式，再手動複製第一段；後續回答由 Relay 接續。

全自動模式以 ChatGPT 的輔助使用介面判斷生成、待命與複製控制項，並等待連續穩定的狀態；不會在觀察到生成中時執行。收到沒有單一可執行區塊的回答、`RELAY_DONE:` 或 `RELAY_PAUSE:` 時停止。切換對話、失去權限或回傳失敗時，也會停止或等待恢復。

這個模式不會在啟動 App 時自行開啟，不會重播啟用前的舊回答。可隨時從選單停止全自動接續；正在執行的 Shell 不會因此取消。

**0.6.1 已在目前 Codex 聊天視窗完成 10 輪實際全自動接續，逐輪核對自動來源、輸出與結束碼；另通過 1000 輪狀態模擬。詳見 [驗證紀錄](VALIDATION.md)。**

**0.6.1 為測試版。** macOS 的只按複製流程已在使用者電腦完成實際回傳。全自動接續已加入，但仍須確認目前 ChatGPT App 版本的控制項相容性；介面變動可能使它停止等待。未辨識成功時可使用只按複製模式，診斷紀錄會保留停止原因。

## 安裝與權限

從 [GitHub Releases](https://github.com/Coyoter/ChatGPT-Terminal-Relay/releases) 下載。

### macOS

下載對應 macOS ZIP，先結束舊 Relay，再將 App 替換到相同安裝位置。macOS 包為 Apple Silicon，最低部署版本 13.0；ChatGPT App 本身的系統需求另計。

新版會辨識**版本、執行檔內容與安裝路徑**。第一次執行或偵測到更新時，先以系統 `tccutil` 清除 **ChatGPT Terminal Relay 自己**的舊輔助使用授權，再要求使用者重新授權。相同版本與內容的一般重新啟動不會反覆清除。它不會替使用者授予權限，也不會重設其他 App 的權限。

請依系統提示重新開啟 Relay 權限。macOS 27 的頁面名稱可能是「裝置控制和資料取用」。Relay 每兩秒確認程式實際取得的權限；沒有權限時顯示 `⇄ 權限`。可用選單的「檢查輔助使用權限…」查看目前版本與安裝位置。

目前採 ad-hoc 簽章，未經 Apple Developer ID 公證。

### Windows

目前提供的是 [0.5.0 Windows 預覽版](https://github.com/Coyoter/ChatGPT-Terminal-Relay/releases/tag/v0.5.0)，包含 x64 與 ARM64。此版使用 PowerShell，尚未包含 macOS 0.6.0 的全自動接續功能，真實 ChatGPT 對接仍待 Windows 實機驗證。

解壓縮後執行 `ChatGPTTerminalRelay.exe`。執行環境已包含在包內，不需要另裝 .NET。優先使用 PowerShell 7，未安裝時使用 Windows PowerShell 5.1。兩種 Shell 的執行測試均已通過。Windows 包尚未程式碼簽章。

## 指令協議

可執行內容第一行必須完全等於 `# CHATGPT_RUN`，例如：

```zsh
# CHATGPT_RUN
printf '%s\n' 'RELAY_CONNECTED'
```

macOS 透過 `/bin/zsh -lc` 執行。每次都是新的 Shell，涉及專案的每段指令都必須自行 `cd` 到絕對路徑。相同指令在 3 秒內重複複製只執行一次；同一時間只處理一段指令。

全自動模式可以從完整回答中取出唯一、完整的 Markdown 程式碼區塊；沒有標記、圍欄未結束或包含多個區塊時，不會自動執行。

回傳格式：

```text
EXIT_CODE: 0

OUTPUT:
RELAY_CONNECTED
```

標記只是啟動條件，不驗證來源，也不是沙盒。指令以目前帳號的權限執行。請在接手提示中明確描述任務與限制，避免讓指令輸出密碼、API Key、權杖或其他不適合交給 ChatGPT 的資料。

## 回傳方式

macOS 恢復以貼上及送出按鍵完成回傳，不再強制要求輸入框名稱符合清單，或以草稿讀回來阻擋操作。按鍵指定送到 ChatGPT 程序；送出前會再確認 ChatGPT 仍在前景、輔助使用權限有效，以及剪貼簿仍然是本次結果。

回傳時請不要操作 ChatGPT 的其他輸入位置。按鍵已送出不代表伺服器已接收；若網路或 ChatGPT 異常，先查看對話，再決定是否使用「重試回傳上次結果」，避免重複傳送。也可選「複製上次結果」手動處理。重試不會重新執行原指令。

## 接手提示

- App 內「選擇專案並複製接手提示…」會把專案絕對路徑填入提示；不會自行讀取專案檔案。
- [完整 macOS 接手提示](HANDOFF_PROMPT.txt)
- [macOS／Windows 基本操作提示](PROJECT_PROMPT.md)

Codex 停下前若能留下原目標、已完成項目、剩餘工作、驗證結果與不可改動的限制，ChatGPT 就不必從零猜測。提示會要求它先確認專案實況及 AGENTS.md，保留既有未提交修改，再從未完成處接手。

## 本機紀錄

macOS：`~/Library/Application Support/ChatGPT Terminal Relay/`

- `diagnostics.jsonl`：啟動位置、實際權限、指令階段、自動接續狀態與錯誤碼。不記錄指令、剪貼簿文字、草稿或對話標題。超過 1 MiB 會保留一份前次紀錄。
- `authorization-build.json`：記住已處理過授權重設的程式指紋。
- `last-result.txt`：上次結果。
- `Logs/`：完整指令輸出。長輸出只回傳前段預覽，完整檔案路徑會附在結果中。

Windows 的結果與輸出位於 `%LOCALAPPDATA%/ChatGPTTerminalRelay/`。輸出檔可能包含專案資料，請按需要自行清理。

## 開發與驗證

macOS：

```sh
./tests/run-macos.sh
./build.sh
```

Windows：

```powershell
dotnet build windows/ChatGPTTerminalRelay.csproj -c Release
dotnet windows/bin/Release/net10.0-windows/ChatGPTTerminalRelay.dll --self-test
./build-windows.ps1 -Runtime win-x64
./build-windows.ps1 -Runtime win-arm64
```

GitHub Actions 包含 Shell、回傳、權限重設與自動接續狀態的測試。模擬測試通過不等於已驗證真實 ChatGPT 介面，發行紀錄會分別列出。

## 已知歷史問題

macOS 0.5.0–0.5.2 的直接輸入框方案在使用者實際環境失敗，並已標記為不建議使用。0.5.3 恢復貼上回傳及更新後授權重設，使用者已回傳 `RELAY_CONNECTED` 並確認可執行。0.6.0 在此流程上加入全自動接續。

## License

MIT
