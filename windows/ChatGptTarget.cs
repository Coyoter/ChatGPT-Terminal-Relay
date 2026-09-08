using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;

namespace ChatGPTTerminalRelay;

internal static class Native
{
    [DllImport("user32.dll")] internal static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] internal static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")] internal static extern bool ShowWindow(nint window, int command);
    [DllImport("user32.dll")] internal static extern bool IsWindow(nint window);
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint window, out uint pid);
    [DllImport("user32.dll")] internal static extern uint GetClipboardSequenceNumber();
}

internal sealed class ChatGptTarget : IReturnTarget
{
    private readonly nint window;
    private readonly int pid;
    private readonly string title;
    private readonly AutomationElement root;
    private readonly AutomationElement editor;
    private readonly ValuePattern value;
    private AutomationElement? sendButton;

    private ChatGptTarget(nint window, int pid, AutomationElement root, AutomationElement editor, ValuePattern value)
    {
        this.window = window; this.pid = pid; this.root = root;
        this.editor = editor; this.value = value; title = root.Current.Name;
    }

    internal static nint FindWindow()
    {
        using Process? front = ForegroundChatGpt();
        if (front != null) return front.MainWindowHandle;
        var windows = new List<nint>();
        foreach (Process p in Process.GetProcessesByName("ChatGPT"))
        {
            using (p) { if (p.MainWindowHandle != 0) windows.Add(p.MainWindowHandle); }
        }
        // Several conversations/windows require the user to foreground their intended target.
        return windows.Count == 1 ? windows[0] : 0;
    }
    private static Process? ForegroundChatGpt()
    {
        Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out uint id);
        try
        {
            Process p = Process.GetProcessById((int)id);
            if (string.Equals(p.ProcessName, "ChatGPT", StringComparison.OrdinalIgnoreCase)) return p;
            p.Dispose();
        }
        catch (ArgumentException) { }
        return null;
    }

    internal static async Task<ChatGptTarget?> Open(nint preferred, CancellationToken cancellation)
    {
        nint window = preferred != 0 ? preferred : FindWindow();
        if (window == 0 || !Native.IsWindow(window)) return null;
        Native.GetWindowThreadProcessId(window, out uint id);
        using Process p = Process.GetProcessById((int)id);
        if (!string.Equals(p.ProcessName, "ChatGPT", StringComparison.OrdinalIgnoreCase)) return null;
        Native.ShowWindow(window, 9); // Restore if minimized; never type into the current arbitrary app.
        if (!Native.SetForegroundWindow(window)) return null;
        await Task.Delay(400, cancellation);
        if (Native.GetForegroundWindow() != window) return null;
        return Create(window, (int)id);
    }

    // Also used by the isolated Windows UI fixture; production calls Open, which checks process identity.
    internal static ChatGptTarget? Create(nint window, int pid)
    {
        AutomationElement root = AutomationElement.FromHandle(window);
        var candidates = new List<(AutomationElement editor, ValuePattern value)>();
        var identified = new List<(AutomationElement editor, ValuePattern value)>();
        var controls = root.FindAll(TreeScope.Descendants,
            new AndCondition(new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit),
                             new PropertyCondition(AutomationElement.IsEnabledProperty, true),
                             new PropertyCondition(AutomationElement.IsOffscreenProperty, false)));
        foreach (AutomationElement e in controls)
        {
            if (e.Current.IsPassword || !e.TryGetCurrentPattern(ValuePattern.Pattern, out object pattern)) continue;
            var value = (ValuePattern)pattern;
            if (value.Current.IsReadOnly) continue;
            candidates.Add((e, value));
            if (e.Current.AutomationId == "prompt-textarea") identified.Add((e, value));
        }
        var composerNames = new HashSet<string>(new[] { "Message ChatGPT", "Ask anything", "Send a message", "Message", "傳送訊息給 ChatGPT", "向 ChatGPT 傳送訊息", "詢問任何問題", "訊息", "向 ChatGPT 发送消息" }, StringComparer.OrdinalIgnoreCase);
        var named = candidates.Where(c => composerNames.Contains(c.editor.Current.Name)).ToList();
        var selected = identified.Count == 1 ? identified : named;
        if (selected.Count != 1) return null;
        return new ChatGptTarget(window, pid, root, selected[0].editor, selected[0].value);
    }
    public bool IsValid()
    {
        if (!Native.IsWindow(window) || Native.GetForegroundWindow() != window) return false;
        Native.GetWindowThreadProcessId(window, out uint actual);
        if (actual != pid || root.Current.Name != title || !editor.Current.IsEnabled || editor.Current.IsOffscreen) return false;
        // A replaced composer/navigation must not silently retarget a different conversation.
        for (AutomationElement? node = editor; node != null; node = TreeWalker.ControlViewWalker.GetParent(node))
            if (Automation.Compare(node, root)) return true;
        return false;
    }
    public string? ReadText() => value.Current.Value;
    public bool WriteText(string text)
    {
        if (!IsValid() || ReadText()?.Length != 0) return false;
        value.SetValue(text); // Targeted UI Automation: does not read/write the clipboard.
        return true;
    }
    public bool CanSend()
    {
        if (!IsValid()) return false;
        var labels = new HashSet<string>(new[] { "Send", "Send message", "Send prompt", "傳送", "傳送訊息", "傳送提示", "送出", "发送", "发送消息", "发送提示" }, StringComparer.OrdinalIgnoreCase);
        var controls = root.FindAll(TreeScope.Descendants,
            new AndCondition(new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
                             new PropertyCondition(AutomationElement.IsEnabledProperty, true),
                             new PropertyCondition(AutomationElement.IsOffscreenProperty, false)));
        var matches = new List<AutomationElement>();
        foreach (AutomationElement e in controls)
            if (labels.Contains(e.Current.Name) && e.TryGetCurrentPattern(InvokePattern.Pattern, out _)) matches.Add(e);
        sendButton = matches.Count == 1 ? matches[0] : null;
        return sendButton != null;
    }
    public bool Send(string expectedText)
    {
        if (!IsValid() || sendButton == null || Protocol.Normalize(ReadText() ?? "") != Protocol.Normalize(expectedText)) return false;
        ((InvokePattern)sendButton.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
        return true;
    }
}
