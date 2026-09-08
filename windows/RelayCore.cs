using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace ChatGPTTerminalRelay;

internal static class Protocol
{
    public static string? Parse(string? text)
    {
        if (text == null) return null;
        int line = text.IndexOf('\n');
        if (line < 0) return null;
        string first = text[..line];
        if (first.EndsWith('\r')) first = first[..^1];
        if (first != "# CHATGPT_RUN") return null;
        string command = text[(line + 1)..].Trim();
        return command.Length == 0 ? null : command;
    }
    public static string Normalize(string text) => text.Replace("\r\n", "\n");
}

internal record ShellResult(int ExitCode, string Output, string LogPath)
{
    public string Format() => $"EXIT_CODE: {ExitCode}\n\nOUTPUT:\n{(Output.Length == 0 ? "(no output)" : Output)}";
}

internal static class ShellRunner
{
    public static string FindPowerShell()
    {
        string core = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe");
        if (File.Exists(core)) return core;
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
    }

    public static async Task<ShellResult> Run(string command, string logs, CancellationToken cancellation)
    {
        Directory.CreateDirectory(logs);
        string log = Path.Combine(logs, $"relay-{DateTime.UtcNow:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}.log");
        // EncodedCommand transports Unicode without shell quoting or a temporary executable script.
        string script = "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)\n" +
            "$OutputEncoding = [Console]::OutputEncoding\n$ErrorActionPreference = 'Stop'\n$global:LASTEXITCODE = 0\ntry {\n& {\n" +
            command + "\n}\n$relaySuccess = $?\nif (-not $relaySuccess) { if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }; exit 1 }\nexit $LASTEXITCODE\n} catch { [Console]::Error.WriteLine($_.ToString()); exit 1 }";
        var start = new ProcessStartInfo(FindPowerShell()) {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8, StandardInputEncoding = new UTF8Encoding(false),
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
        };
        foreach (string arg in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes("[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false); & ([scriptblock]::Create([Console]::In.ReadToEnd()))")) })
            start.ArgumentList.Add(arg);
        using var process = new Process { StartInfo = start };
        using var writer = new StreamWriter(log, false, new UTF8Encoding(false));
        var buffer = new StringBuilder();
        object sync = new();
        bool truncated = false;
        async Task Drain(StreamReader reader)
        {
            char[] chunk = new char[4096];
            int count;
            while ((count = await reader.ReadAsync(chunk)) > 0)
            {
                lock (sync)
                {
                    writer.Write(chunk, 0, count);
                    int keep = Math.Min(count, 65536 - buffer.Length);
                    if (keep > 0) buffer.Append(chunk, 0, keep);
                    truncated |= keep < count;
                }
            }
        }
        cancellation.ThrowIfCancellationRequested();
        if (!process.Start()) throw new IOException("無法啟動 PowerShell。");
        using var registration = cancellation.Register(() => {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
        });
        Task stdout = Drain(process.StandardOutput), stderr = Drain(process.StandardError);
        await process.StandardInput.WriteAsync(script);
        process.StandardInput.Close(); // No Windows command-line size limit; interactive input receives EOF.
        try
        {
            await process.WaitForExitAsync();
            // A detached child may inherit output handles. Do not let it hold Relay forever.
            await Task.WhenAll(stdout, stderr).WaitAsync(TimeSpan.FromSeconds(5));
        }
        catch (TimeoutException)
        {
            process.StandardOutput.Close(); process.StandardError.Close();
            try { await Task.WhenAll(stdout, stderr); } catch (Exception) { }
            lock (sync) buffer.Append("\n[背景程序仍持有輸出，已停止等待。]");
        }
        await writer.FlushAsync();
        string output = buffer.ToString();
        if (truncated) output += $"\n\n[輸出較長，完整紀錄保留於：{log}]";
        if (cancellation.IsCancellationRequested) output += "\n[使用者已取消執行。]";
        return new ShellResult(cancellation.IsCancellationRequested ? 130 : process.ExitCode, output, log);
    }
}

internal interface IReturnTarget
{
    bool IsValid();
    string? ReadText();
    bool WriteText(string text);
    bool CanSend();
    bool Send(string expectedText);
}

internal static class Delivery
{
    public static async Task<string?> Return(IReturnTarget target, string text, CancellationToken cancellation)
    {
        cancellation.ThrowIfCancellationRequested();
        if (!target.IsValid()) return "無法確認 ChatGPT 目標視窗";
        string? current = target.ReadText();
        if (current == null || (current.Length > 0 && Protocol.Normalize(current) != Protocol.Normalize(text)))
            return "輸入框已有草稿或無法讀取";
        if (current.Length == 0 && !target.WriteText(text)) return "無法填入 ChatGPT 輸入框";
        for (int i = 0; i <= 24; i++)
        {
            cancellation.ThrowIfCancellationRequested();
            if (!target.IsValid()) return "目標視窗已變更，已暫停回傳";
            current = target.ReadText();
            bool matches = current != null && Protocol.Normalize(current) == Protocol.Normalize(text);
            if (current == null || (current.Length > 0 && !matches)) return "輸入內容已變更，已暫停回傳";
            if (matches && target.CanSend())
                return target.Send(text) ? null : "無法確認傳送，請先查看 ChatGPT";
            await Task.Delay(100, cancellation);
        }
        return "ChatGPT 尚未就緒，請稍後重試";
    }
}
