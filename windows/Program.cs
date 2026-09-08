using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace ChatGPTTerminalRelay;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--self-test") return SelfTests.Run().GetAwaiter().GetResult();
        ApplicationConfiguration.Initialize();
        if (args.Length > 0 && args[0] == "--ui-fixture") return SelfTests.RunUiFixture();
        using var mutex = new Mutex(true, @"Local\Coyoter.ChatGPTTerminalRelay", out bool first);
        if (!first) return 0;
        Application.Run(new RelayContext());
        return 0;
    }
}

internal sealed class RelayContext : ApplicationContext
{
    private readonly string data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ChatGPTTerminalRelay");
    private readonly NotifyIcon tray;
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 350 };
    private readonly ToolStripMenuItem status = new("狀態：監聽中") { Enabled = false };
    private readonly ToolStripMenuItem start = new("啟動監聽");
    private readonly ToolStripMenuItem stop = new("停止監聽");
    private readonly ToolStripMenuItem cancel = new("取消執行中的指令");
    private readonly ToolStripMenuItem retry = new("重試回傳上次結果");
    private readonly ToolStripMenuItem copy = new("複製上次結果");
    private readonly ToolStripMenuItem logs = new("開啟輸出紀錄資料夾");
    private bool monitoring = true, busy, checkingUpdate, exiting;
    private uint clipboardSequence;
    private string? lastCommand, lastResult;
    private long lastExecuted;
    private nint targetWindow;
    private CancellationTokenSource? commandCancel, returnCancel;

    internal RelayContext()
    {
        Directory.CreateDirectory(data);
        try { lastResult = File.ReadAllText(Path.Combine(data, "last-result.txt")); } catch (IOException) { }
        clipboardSequence = Native.GetClipboardSequenceNumber();
        var menu = new ContextMenuStrip();
        menu.Items.Add(status); menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("檢查更新…", null, async (_, _) => await CheckUpdates(true));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(start); menu.Items.Add(stop); menu.Items.Add(cancel);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(retry); menu.Items.Add(copy); menu.Items.Add(logs);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("結束 Relay", null, (_, _) => Quit());
        tray = new NotifyIcon { Icon = SystemIcons.Application, Text = "ChatGPT Terminal Relay", ContextMenuStrip = menu, Visible = true };
        start.Click += (_, _) => { monitoring = true; clipboardSequence = Native.GetClipboardSequenceNumber(); Update("監聽中"); };
        stop.Click += (_, _) => { monitoring = false; returnCancel?.Cancel(); Update("已停止"); };
        cancel.Click += (_, _) => { commandCancel?.Cancel(); Update("正在取消指令"); };
        retry.Click += async (_, _) => { if (!busy && monitoring && lastResult != null) { busy = true; targetWindow = ChatGptTarget.FindWindow(); await ReturnResult(); } };
        copy.Click += (_, _) => {
            try { if (lastResult != null) { Clipboard.SetText(lastResult); clipboardSequence = Native.GetClipboardSequenceNumber(); Update("結果已複製"); } }
            catch (ExternalException) { Update("剪貼簿忙碌，請稍後重試"); }
        };
        logs.Click += (_, _) => { string path = Path.Combine(data, "Logs"); Directory.CreateDirectory(path); Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); };
        timer.Tick += async (_, _) => {
            try { await Tick(); }
            catch (Exception) { busy = false; Update("暫時無法處理指令，請重新複製"); }
        };
        timer.Start(); Update("監聽中");
        _ = CheckUpdates(false);
    }
    private void Update(string text)
    {
        if (exiting) return;
        status.Text = "狀態：" + text;
        start.Enabled = !monitoring; stop.Enabled = monitoring;
        retry.Enabled = monitoring && !busy && lastResult != null;
        copy.Enabled = !busy && lastResult != null;
        cancel.Enabled = commandCancel != null;
        tray.Text = busy ? "ChatGPT Terminal Relay — 處理中" : "ChatGPT Terminal Relay";
    }
    private async Task Tick()
    {
        if (!monitoring || busy || exiting) return;
        uint sequence = Native.GetClipboardSequenceNumber();
        if (sequence == clipboardSequence) return;
        string? text;
        try { text = Clipboard.ContainsText() ? Clipboard.GetText() : null; }
        catch (ExternalException) { return; } // Retry this same change when the clipboard lock clears.
        clipboardSequence = sequence;
        string? command = Protocol.Parse(text);
        if (command == null) return;
        long now = Environment.TickCount64;
        if (command == lastCommand && now - lastExecuted < 3000) return;
        lastCommand = command; lastExecuted = now;
        busy = true; targetWindow = ChatGptTarget.FindWindow();
        commandCancel = new CancellationTokenSource(); Update("執行中（PowerShell）");
        try
        {
            ShellResult result = await ShellRunner.Run(command, Path.Combine(data, "Logs"), commandCancel.Token);
            lastResult = result.Format();
        }
        catch (Exception error) { lastResult = $"EXIT_CODE: 127\n\nOUTPUT:\nRelay：{error.Message}"; }
        finally { commandCancel.Dispose(); commandCancel = null; }
        try { File.WriteAllText(Path.Combine(data, "last-result.txt"), lastResult); }
        catch (IOException) { Update("無法儲存結果，暫存於記憶體"); }
        if (!exiting) await ReturnResult();
    }
    private async Task ReturnResult()
    {
        returnCancel = new CancellationTokenSource();
        try
        {
            if (!monitoring || lastResult == null) { Update("已停止，結果已保留"); return; }
            Update("確認 ChatGPT 輸入框");
            string result = lastResult;
            CancellationToken token = returnCancel.Token;
            // UI Automation uses an MTA background thread, never blocking the tray's STA loop.
            string? failure = await Task.Run(async () => {
                ChatGptTarget? target = await ChatGptTarget.Open(targetWindow, token);
                return target == null ? "請開啟 ChatGPT 並選擇對話後重試" : await Delivery.Return(target, result, token);
            }, token);
            Update(failure == null ? "已交付傳送，監聽中" : failure + "；結果已保留");
        }
        catch (OperationCanceledException) { Update("已停止回傳，結果已保留"); }
        catch (Exception error) { Update("回傳失敗，結果已保留"); tray.ShowBalloonTip(5000, "ChatGPT Terminal Relay", error.Message, ToolTipIcon.Info); }
        finally { returnCancel?.Dispose(); returnCancel = null; busy = false; Update(monitoring ? (status.Text ?? "").Replace("狀態：", "") : "已停止，結果已保留"); }
    }
    private async Task CheckUpdates(bool manual)
    {
        if (checkingUpdate) return;
        checkingUpdate = true;
        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
            client.DefaultRequestHeaders.UserAgent.ParseAdd("ChatGPT-Terminal-Relay/0.5.0");
            using JsonDocument document = JsonDocument.Parse(await client.GetStringAsync("https://api.github.com/repos/Coyoter/ChatGPT-Terminal-Relay/releases/latest"));
            string? tag = document.RootElement.GetProperty("tag_name").GetString();
            if (Version.TryParse(tag?.TrimStart('v'), out Version? latest) && latest > new Version(0, 5, 0))
            {
                if (manual && MessageBox.Show($"最新版本：{tag}\n前往 GitHub 下載？", "ChatGPT Terminal Relay", MessageBoxButtons.YesNo) == DialogResult.Yes)
                    Process.Start(new ProcessStartInfo("https://github.com/Coyoter/ChatGPT-Terminal-Relay/releases") { UseShellExecute = true });
                else if (!manual) tray.ShowBalloonTip(5000, "有新版 ChatGPT Terminal Relay", $"{tag} 已發行，可從選單檢查更新。", ToolTipIcon.Info);
            }
            else if (manual) MessageBox.Show("目前已是最新版本。", "ChatGPT Terminal Relay");
        }
        catch (Exception error) { if (manual) MessageBox.Show("無法檢查更新：" + error.Message, "ChatGPT Terminal Relay"); }
        finally { checkingUpdate = false; }
    }
    private void Quit()
    {
        exiting = true; timer.Stop(); returnCancel?.Cancel(); commandCancel?.Cancel();
        tray.Visible = false; tray.Dispose(); timer.Dispose(); ExitThread();
    }
}
