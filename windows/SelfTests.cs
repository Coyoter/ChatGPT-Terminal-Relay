using System;
using System.Drawing;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace ChatGPTTerminalRelay;

internal static class SelfTests
{
    private static int passed;
    private static void Check(bool value, string name)
    {
        if (!value) throw new Exception("FAIL: " + name);
        Console.WriteLine("PASS: " + name); passed++;
    }
    private sealed class Fake : IReturnTarget
    {
        internal bool Valid = true, Writable = true, Ready = true, Blur, Change;
        internal string Text = "";
        internal int Sends, Writes;
        public bool IsValid() => Valid;
        public string ReadText() => Text;
        public bool WriteText(string text) { Writes++; if (!Writable) return false; Text = Change ? "private draft" : text; if (Blur) Valid = false; return true; }
        public bool CanSend() => Ready;
        public bool Send(string expectedText) { if (!Valid || Text != expectedText) return false; Sends++; return true; }
    }
    internal static async Task<int> Run()
    {
        string temp = Path.Combine(Path.GetTempPath(), "relay-tests-" + Guid.NewGuid().ToString("N"));
        try
        {
            Check(Protocol.Parse("# CHATGPT_RUN\nprintf ok") == "printf ok", "LF marker");
            Check(Protocol.Parse("# CHATGPT_RUN\r\nprintf ok") == "printf ok", "CRLF marker");
            Check(Protocol.Parse("# CHATGPT_RUN echo wrong") == null, "reject inline marker");
            Check(Protocol.Parse("# CHATGPT_RUNNING\necho wrong") == null, "reject marker prefix");
            Check(Protocol.Parse("# CHATGPT_RUN\n ") == null, "reject empty command");
            var t = new Fake();
            Check(await Delivery.Return(t, "result", default) == null && t.Sends == 1, "deliver exact result once");
            t = new Fake { Valid = false };
            Check(await Delivery.Return(t, "result", default) != null && t.Writes == 0 && t.Sends == 0, "wrong foreground prevents every write");
            t = new Fake { Text = "user draft" };
            Check(await Delivery.Return(t, "result", default) != null && t.Writes == 0, "preserve user draft");
            t = new Fake { Blur = true };
            Check(await Delivery.Return(t, "result", default) != null && t.Sends == 0, "focus change after write never sent");
            t = new Fake { Change = true };
            Check(await Delivery.Return(t, "result", default) != null && t.Sends == 0, "changed contents never sent");
            t = new Fake { Writable = false };
            Check(await Delivery.Return(t, "result", default) != null && t.Sends == 0, "unsupported editor fails safely");
            t = new Fake { Text = "result" };
            Check(await Delivery.Return(t, "result", default) == null && t.Writes == 0, "explicit retry preserves existing result");
            t = new Fake { Ready = false };
            using (var stop = new CancellationTokenSource(150))
            {
                try { await Delivery.Return(t, "result", stop.Token); throw new Exception("cancel ignored"); }
                catch (OperationCanceledException) { Check(t.Sends == 0, "cancel pending return"); }
            }
            t = new Fake { Ready = false };
            Task<string?> pending = Delivery.Return(t, "result", default);
            t.Ready = true;
            Check(await pending == null && t.Sends == 1, "wait for ready button");
            ShellResult r = await ShellRunner.Run("[Console]::WriteLine('out'); [Console]::Error.WriteLine('err'); exit 7", temp, default);
            Check(r.ExitCode == 7 && r.Output.Contains("out") && r.Output.Contains("err"), "real PowerShell stdout stderr exit 7");
            r = await ShellRunner.Run("[Console]::WriteLine('繁體中文 😀')", temp, default);
            Check(r.ExitCode == 0 && r.Output.Contains("繁體中文 😀"), "real PowerShell Unicode");
            r = await ShellRunner.Run("& $env:ComSpec /d /c 'exit 9'", temp, default);
            Check(r.ExitCode == 9, "native command failure exit 9");
            r = await ShellRunner.Run("throw 'expected failure'", temp, default);
            Check(r.ExitCode != 0 && r.Output.Contains("expected failure"), "PowerShell exception nonzero");
            r = await ShellRunner.Run("[Console]::Write('A' * 2097152)", temp, default);
            Check(r.Output.Length < 66000 && new FileInfo(r.LogPath).Length == 2097152, "bounded preview and complete 2MiB log");
            r = await ShellRunner.Run("#" + new string('x', 50000) + "\n[Console]::Write('long command ok')", temp, default);
            Check(r.ExitCode == 0 && r.Output == "long command ok", "command exceeds Windows argument length");
            using (var stop = new CancellationTokenSource(2000))
            {
                r = await ShellRunner.Run("Start-Sleep -Seconds 60", temp, stop.Token);
                Check(r.ExitCode == 130, "cancel running PowerShell");
            }
            Console.WriteLine($"{passed} tests passed");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        finally { if (Directory.Exists(temp)) Directory.Delete(temp, true); }
    }
    internal static int RunUiFixture()
    {
        int exit = 1;
        using var form = new Form { Text = "Relay isolated UI fixture", Width = 600, Height = 300 };
        var input = new TextBox { Name = "prompt-textarea", AccessibleName = "Message", Dock = DockStyle.Top };
        var send = new Button { Text = "Send message", AccessibleName = "Send message", Dock = DockStyle.Bottom };
        int sends = 0;
        send.Click += (_, _) => sends++;
        form.Controls.Add(input); form.Controls.Add(send);
        form.Shown += async (_, _) => {
            try
            {
                Native.SetForegroundWindow(form.Handle);
                nint handle = form.Handle;
                string? failure = await Task.Run(async () => {
                    ChatGptTarget? target = ChatGptTarget.Create(handle, Environment.ProcessId);
                    if (target == null) return "fixture editor not found";
                    return await Delivery.Return(target, "fixture result 繁體中文", default);
                });
                await Task.Delay(200);
                Check(failure == null && sends == 1 && input.Text == "fixture result 繁體中文", "real Windows UI Automation editor and send button");
                exit = 0;
            }
            catch (Exception error) { Console.Error.WriteLine(error); }
            finally { form.Close(); }
        };
        Application.Run(form);
        return exit;
    }
}
