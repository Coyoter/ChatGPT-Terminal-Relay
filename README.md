# ChatGPT Terminal Relay

一個極簡的 macOS ChatGPT ↔ Terminal Relay。

你只需要在 ChatGPT 裡按下「複製 Command」：

**複製 → 自動執行 zsh → 收集 stdout / stderr / exit code → 自動貼回 ChatGPT → Enter 送出**

不需要瀏覽器外掛，也不需要反覆切換 Terminal。

## 支援

- ChatGPT 網頁版
- ChatGPT macOS App
- macOS 13 或更新版本
- 不需要 ChatGPT API Key
- 不需要瀏覽器擴充功能

## 使用方式

Relay 只會執行第一行為 `# CHATGPT_RUN` 的剪貼簿內容。

例如：

    # CHATGPT_RUN
    cd ~/Developer/MyProject && npm test

一般複製的文字不會被執行。

## 回傳格式

    EXIT_CODE: 0

    OUTPUT:
    ...

## 安裝

1. 從 GitHub Releases 下載最新版 ZIP。
2. 解壓縮後，把 ChatGPT Terminal Relay.app 放進 Applications。
3. 第一次開啟若 macOS 阻擋，請對 App 按右鍵 →「開啟」。
4. 到「系統設定 → 隱私權與安全性 → 輔助使用」允許 ChatGPT Terminal Relay。
5. 選單列出現 `⇄ Relay` 後即可使用。

目前 Release 使用 ad-hoc 簽章，尚未經 Apple Developer ID 公證。

## 更新

Relay 每次啟動時會自動查詢 GitHub Releases。

也可以從選單列選擇「檢查更新…」。

發現新版時，Relay 只會提示並開啟 GitHub Releases 頁面，不會自行下載或安裝。

## 安全設計

- 只有以 `# CHATGPT_RUN` 開頭的內容會執行。
- 相同 Command 在 3 秒內重複複製只會執行一次。
- 指令透過 `/bin/zsh -lc` 執行。
- stdout 與 stderr 會完整收集。
- 回傳包含 exit code。
- 不會自動下載或安裝更新。

## 從原始碼建置

    ./build.sh

產物會放在 `dist/`。

## GitHub

https://github.com/Coyoter/ChatGPT-Terminal-Relay

## License

MIT
