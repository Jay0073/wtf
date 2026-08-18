# wtf-prefill.ps1 — put a command AT a pane's prompt without running it.
#
# This is dot-sourced by a restored pane, not by wtf itself.
#
# Why it exists: an agent resume line is not something you want fired the moment
# a tab opens. Four agents all starting at once is rarely what you meant. So a
# pane can be told to have its command TYPED and left sitting at the prompt,
# waiting for you to press Enter when you are ready for it.
#
# How: the characters are written into the pane's own console input buffer, so
# the shell reads them exactly as if you had typed them. No newline is sent, so
# nothing runs.
#
# Save as UTF-8 WITH BOM. Runs on Windows PowerShell 5.1 and PowerShell 7+.

function Initialize-WtfPrefill {
    if ('WtfConsoleInput' -as [type]) { return $true }
    $src = @'
using System;
using System.Runtime.InteropServices;

public static class WtfConsoleInput {
    [StructLayout(LayoutKind.Explicit)]
    struct INPUT_RECORD {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct KEY_EVENT_RECORD {
        public int    bKeyDown;
        public ushort wRepeatCount;
        public ushort wVirtualKeyCode;
        public ushort wVirtualScanCode;
        public char   UnicodeChar;
        public uint   dwControlKeyState;
    }

    const ushort KEY_EVENT = 1;
    const uint   GENERIC_READ  = 0x80000000;
    const uint   GENERIC_WRITE = 0x40000000;
    const uint   SHARE_RW      = 0x00000003;
    const uint   OPEN_EXISTING = 3;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec,
                                     uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteConsoleInputW(IntPtr handle, INPUT_RECORD[] buffer, uint count, out uint written);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);

    // Types the text into THIS console. No Enter is sent, so nothing executes.
    public static bool TypeText(string text) {
        if (string.IsNullOrEmpty(text)) return true;

        IntPtr h = CreateFileW("CONIN$", GENERIC_READ | GENERIC_WRITE, SHARE_RW,
                               IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (h == IntPtr.Zero || h == new IntPtr(-1)) return false;
        try {
            // One key-down and one key-up record per character, which is what a
            // real keystroke looks like to the console.
            var records = new INPUT_RECORD[text.Length * 2];
            int n = 0;
            foreach (char c in text) {
                var down = new INPUT_RECORD();
                down.EventType = KEY_EVENT;
                down.KeyEvent.bKeyDown = 1;
                down.KeyEvent.wRepeatCount = 1;
                down.KeyEvent.UnicodeChar = c;
                records[n++] = down;

                var up = down;
                up.KeyEvent.bKeyDown = 0;
                records[n++] = up;
            }
            uint written;
            return WriteConsoleInputW(h, records, (uint)n, out written);
        } finally {
            CloseHandle(h);
        }
    }
}
'@
    try { Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop; return $true }
    catch { return $false }
}

function Write-WtfPrefill {
    <#
    .SYNOPSIS
        Leave $Command typed at this pane's prompt, ready but not run.
    .DESCRIPTION
        Falls back to simply showing the command if the console cannot be
        written to, so you can still copy it rather than losing it.
    #>
    param([Parameter(Mandatory)][string]$Command)

    if (Initialize-WtfPrefill) {
        if ([WtfConsoleInput]::TypeText($Command)) { return }
    }
    Write-Host ""
    Write-Host "  ready to run (copy it):" -ForegroundColor DarkGray
    Write-Host "  $Command" -ForegroundColor Cyan
}
