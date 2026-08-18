# wtf-layout.ps1 — tab layouts for WorkTree Flow
#
# A LAYOUT is a named snapshot of ONE Windows Terminal tab: its pane tree, the
# split sizes, each pane's directory, and each pane's command. It is top-level
# and free-standing: it may mix any projects, worktrees and main checkouts.
#
# Capture works by reading the terminal's accessibility tree. Windows Terminal
# only exposes the ACTIVE tab's panes, so a snapshot is tab-scoped by nature —
# other tabs and other windows can never leak in.
#
# Restore works by issuing SEPARATE wt.exe calls. Sub-commands inside one wt
# command line do not carry focus between them, so `focus-pane` is ignored there
# and nested trees come out wrong. One call per step is the only correct way.
#
# Written to run on BOTH Windows PowerShell 5.1 and PowerShell 7+:
#   - no `e escapes (5.1 does not know them) — [char]27 instead
#   - no ternary / null-coalescing operators
#   - this file MUST be saved as UTF-8 WITH BOM or 5.1 mangles the box glyphs

# ============================================================================
# THEME (falls back to its own if wtf.ps1 has not been loaded)
# ============================================================================

if (-not $script:T) {
    $E = [char]27
    $script:T = @{
        Prompt = "$E[38;5;81m";  Ok     = "$E[38;5;42m";  Warn  = "$E[38;5;215m"
        Fail   = "$E[38;5;203m"; Detail = "$E[38;5;245m"; Header= "$E[38;5;141m"
        Accent = "$E[38;5;111m"; Dim    = "$E[2m";        Bold  = "$E[1m"
        Italic = "$E[3m";        Reset  = "$E[0m";        SelBg = "$E[48;5;236m"
        Rail   = "$E[38;5;212m"; Faint  = "$E[38;5;240m"
        HideCur= "$E[?25l";      ShowCur= "$E[?25h"
        ClearLn= "$E[2K`r";      Up     = "$E[1A"
    }
}
if (-not $script:WtfRoot) { $script:WtfRoot = Join-Path $env:USERPROFILE '.wtf' }
$script:WtfLayoutDir = Join-Path $script:WtfRoot 'layouts'

# Colors cycled onto restored tabs so layouts are visually distinct.
$script:WtfLayoutColors = @(
    '#3B82F6','#10B981','#F59E0B','#A855F7','#14B8A6','#EF4444','#6366F1','#EC4899'
)

# ============================================================================
# NATIVE INTEROP — loaded once
# ============================================================================

function Initialize-WtfInterop {
    <#
    .SYNOPSIS
        Load UI Automation + the Win32/PEB helpers. Idempotent; safe to call often.
    .OUTPUTS
        $true if UI Automation is usable (capture needs it). The PEB reader is
        optional — without it we simply lose the directory FALLBACK, not capture.
    #>
    if ($script:WtfInteropReady) { return $true }

    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        Add-Type -AssemblyName UIAutomationTypes  -ErrorAction Stop
    } catch {
        Write-WtfLayoutFail "UI Automation is not available: $($_.Exception.Message)"
        return $false
    }

    if (-not ('WtfWin' -as [type])) {
        $winSrc = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class WtfWin {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern int  GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();

    // Every Windows Terminal top-level window uses this class name.
    const string WT_CLASS = "CASCADIA_HOSTING_WINDOW_CLASS";

    public static List<IntPtr> TerminalWindows() {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => {
            var sb = new StringBuilder(256);
            GetClassName(h, sb, 256);
            if (sb.ToString() == WT_CLASS && IsWindowVisible(h)) list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static bool IsTerminalWindow(IntPtr h) {
        if (h == IntPtr.Zero) return false;
        var sb = new StringBuilder(256);
        GetClassName(h, sb, 256);
        return sb.ToString() == WT_CLASS;
    }
}
'@
        try { Add-Type -TypeDefinition $winSrc -Language CSharp -ErrorAction Stop }
        catch { Write-WtfLayoutFail "Win32 helper failed to compile: $($_.Exception.Message)"; return $false }
    }

    # PEB reader — optional. Gives another process's real working directory.
    # PowerShell's Set-Location does NOT change the process directory, so a pane's
    # own shell is useless as a source; its CHILD process (claude, node, python)
    # carries the true directory. That is what this reads.
    if (-not ('WtfPeb' -as [type])) {
        $pebSrc = @'
using System;
using System.Runtime.InteropServices;

public static class WtfPeb {
    [DllImport("ntdll.dll")]
    static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PBI pbi, int len, out int ret);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out IntPtr read);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);

    [StructLayout(LayoutKind.Sequential)]
    struct PBI { public IntPtr R1, Peb, R2a, R2b, Pid, R3; }

    const int QUERY = 0x0400;
    const int VMREAD = 0x0010;

    static byte[] Read(IntPtr h, long addr, int size) {
        byte[] b = new byte[size];
        IntPtr got;
        if (!ReadProcessMemory(h, (IntPtr)addr, b, size, out got)) return null;
        return b;
    }

    public static string Cwd(int pid) {
        IntPtr h = OpenProcess(QUERY | VMREAD, false, pid);
        if (h == IntPtr.Zero) return null;
        try {
            var pbi = new PBI();
            int ret;
            if (NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(pbi), out ret) != 0) return null;
            // x64: PEB -> ProcessParameters at 0x20
            byte[] b = Read(h, (long)pbi.Peb + 0x20, 8);
            if (b == null) return null;
            long pp = BitConverter.ToInt64(b, 0);
            // x64: RTL_USER_PROCESS_PARAMETERS -> CurrentDirectory.DosPath at 0x38
            b = Read(h, pp + 0x38, 16);
            if (b == null) return null;
            ushort len = BitConverter.ToUInt16(b, 0);
            long buf = BitConverter.ToInt64(b, 8);
            if (len == 0 || buf == 0) return null;
            b = Read(h, buf, len);
            if (b == null) return null;
            return System.Text.Encoding.Unicode.GetString(b);
        } catch {
            return null;
        } finally {
            CloseHandle(h);
        }
    }
}
'@
        try { Add-Type -TypeDefinition $pebSrc -Language CSharp -ErrorAction Stop }
        catch { Write-WtfLayoutWarn "process-directory fallback unavailable: $($_.Exception.Message)" }
    }

    $script:WtfInteropReady = $true
    return $true
}

# ============================================================================
# SMALL OUTPUT HELPERS (kept local so this file works standalone)
# ============================================================================

function Write-WtfLayoutOk    { param([string]$M) Write-Host "  $([char]0x2713) $M" -ForegroundColor Green }
function Write-WtfLayoutWarn  { param([string]$M) Write-Host "  ! $M" -ForegroundColor Yellow }
function Write-WtfLayoutFail  { param([string]$M) Write-Host "  x $M" -ForegroundColor Red }
function Write-WtfLayoutStep  { param([string]$M) Write-Host "  -> $M" -ForegroundColor Cyan }
function Write-WtfLayoutInfo  { param([string]$M) Write-Host "  . $M" -ForegroundColor DarkGray }

function ConvertTo-WtfHashtable {
    <#
    .SYNOPSIS
        Recursively turn ConvertFrom-Json output (PSCustomObject) into hashtables
        and arrays. Windows PowerShell 5.1 has no -AsHashtable, so we do it here.
    #>
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in @($InputObject.Keys)) { $h[[string]$k] = ConvertTo-WtfHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-WtfHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [string]) { return $InputObject }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $out = @()
        foreach ($i in $InputObject) { $out += ,(ConvertTo-WtfHashtable $i) }
        return ,$out
    }
    return $InputObject
}

# ============================================================================
# READING THE TERMINAL
# ============================================================================

function Get-WtfTerminalWindows {
    <#
    .SYNOPSIS
        Handles of every visible Windows Terminal window.
    .NOTES
        Windows Terminal hosts SEVERAL windows in ONE process, so a process id
        cannot identify a window. Only the handle can.
    #>
    if (-not (Initialize-WtfInterop)) { return @() }
    # NOTE for callers: PowerShell unwraps a one-element array on return,
    # so with a single window open this comes back as a bare handle. Any
    # caller that reads .Count or indexes MUST wrap it: @(Get-...).
    return @([WtfWin]::TerminalWindows())
}

function Get-WtfWindowTabs {
    <#
    .SYNOPSIS
        Tab names of a terminal window, plus which one is selected.
    .OUTPUTS
        @{ Names = string[]; SelectedIndex = int; SelectedName = string }
    #>
    param([Parameter(Mandatory)][IntPtr]$Hwnd)
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
    if (-not $el) { return @{ Names = @(); SelectedIndex = -1; SelectedName = '' } }

    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::TabItem)
    $found = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)

    $names = @()
    $sel   = -1
    for ($i = 0; $i -lt $found.Count; $i++) {
        $t = $found.Item($i)
        $names += [string]$t.Current.Name
        try {
            $sp = $t.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            if ($sp.Current.IsSelected) { $sel = $i }
        } catch { }
    }
    $selName = ''
    if ($sel -ge 0 -and $sel -lt $names.Count) { $selName = $names[$sel] }
    return @{ Names = @($names); SelectedIndex = $sel; SelectedName = $selName }
}

function Get-WtfWindowPanes {
    <#
    .SYNOPSIS
        Every pane of a window's ACTIVE tab, with its on-screen rectangle and,
        optionally, its full scrollback text.
    .NOTES
        Windows Terminal drops inactive tabs from the accessibility tree, so this
        is inherently limited to the active tab. That is exactly what we want and
        needs no filtering of our own.
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$Hwnd,
        [switch]$WithText
    )
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
    if (-not $el) { return @() }

    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'TermControl')
    $found = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)

    $panes = @()
    for ($i = 0; $i -lt $found.Count; $i++) {
        $p = $found.Item($i)
        $r = $p.Current.BoundingRectangle
        if ([double]::IsInfinity($r.X)) { continue }   # offscreen / not laid out

        $text  = ''
        $focus = $false
        try { $focus = [bool]$p.Current.HasKeyboardFocus } catch { }
        if ($WithText) {
            try {
                $tp   = $p.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
                $text = $tp.DocumentRange.GetText(-1)
            } catch { }
        }
        $panes += [pscustomobject]@{
            Index    = $panes.Count
            X        = [int]$r.X
            Y        = [int]$r.Y
            W        = [int]$r.Width
            H        = [int]$r.Height
            HasFocus = $focus
            Text     = $text
            Dir      = ''
            DirSource= ''
        }
    }
    # NOTE for callers: a tab with ONE pane comes back as a bare object,
    # because PowerShell unwraps a one-element array on return. Wrap it:
    # @(Get-WtfWindowPanes ...) whenever you read .Count or index.
    return @($panes)
}

function Resolve-WtfTargetWindow {
    <#
    .SYNOPSIS
        Decide WHICH terminal window to capture.
    .DESCRIPTION
        Two ways, because there are two ways to trigger a snapshot:

        -Foreground : the hotkey path. The window in front is the one you mean.
                      Nothing is typed anywhere and no free pane is needed.

        default     : the typed-command path. We print a one-off marker into our
                      own pane, then look for that marker in every window's panes.
                      Whichever pane shows it is our pane, so its window is ours.
                      This is exact even though several windows share a process.
    .OUTPUTS
        @{ Hwnd; SelfPaneIndex } — SelfPaneIndex is -1 when unknown.
    #>
    param([switch]$Foreground)

    if (-not (Initialize-WtfInterop)) { return $null }

    if ($Foreground) {
        # If a terminal really is in front, use it.
        $h = [WtfWin]::GetForegroundWindow()
        if ([WtfWin]::IsTerminalWindow($h)) { return @{ Hwnd = $h; SelfPaneIndex = -1 } }

        # Otherwise fall back to the TOPMOST terminal window. This is the normal
        # case for the global hotkey: pressing it opens its own console window,
        # which takes the foreground before this code runs. EnumWindows returns
        # windows in Z-order with the topmost first, and that console is not a
        # terminal window, so the first terminal we see is the one that was in
        # front when you pressed the key.
        $wins = @(Get-WtfTerminalWindows)
        if ($wins.Count -eq 0) {
            Write-WtfLayoutFail "No Windows Terminal window is open - nothing captured."
            return $null
        }
        return @{ Hwnd = $wins[0]; SelfPaneIndex = -1 }
    }

    $token = 'WTFSNAP-' + ([Guid]::NewGuid().ToString('N').Substring(0, 10))
    # Print, then wipe the line, so the marker does not stay on your screen. It
    # lingers in the scrollback buffer for a moment, which is all we need.
    Write-Host $token -NoNewline
    Start-Sleep -Milliseconds 250

    $hit = $null
    foreach ($h in (Get-WtfTerminalWindows)) {
        $panes = Get-WtfWindowPanes -Hwnd $h -WithText
        for ($i = 0; $i -lt $panes.Count; $i++) {
            if ($panes[$i].Text -and $panes[$i].Text.Contains($token)) {
                $hit = @{ Hwnd = $h; SelfPaneIndex = $i }
                break
            }
        }
        if ($hit) { break }
    }
    Write-Host ("$([char]27)[2K`r") -NoNewline

    if (-not $hit) {
        Write-WtfLayoutWarn "Could not identify this pane's window; using the window in front instead."
        $h = [WtfWin]::GetForegroundWindow()
        if (-not [WtfWin]::IsTerminalWindow($h)) { return $null }
        return @{ Hwnd = $h; SelfPaneIndex = -1 }
    }
    return $hit
}

# ============================================================================
# DIRECTORY RESOLUTION
# ============================================================================

function Get-WtfPromptDir {
    <#
    .SYNOPSIS
        The directory a pane is sitting in, read from its own scrollback.
    .DESCRIPTION
        The LAST shell prompt in the buffer is the directory the current command
        was started from, which is the answer we want in both cases: for an idle
        shell it is where you are, and for a running command it is where you
        launched it. Handles PowerShell ("PS C:\x>") and cmd ("C:\x>").
        Returns '' when the prompt has scrolled out of the buffer, which happens
        on long-lived agent panes with very large scrollback.
    #>
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }

    $m = [regex]::Matches($Text, '(?m)^PS\s+([A-Za-z]:\\[^\r\n>]*?)>')
    if ($m.Count -gt 0) { return $m[$m.Count - 1].Groups[1].Value.TrimEnd('\') }

    $m = [regex]::Matches($Text, '(?m)^([A-Za-z]:\\[^\r\n>]*?)>')
    if ($m.Count -gt 0) { return $m[$m.Count - 1].Groups[1].Value.TrimEnd('\') }

    return ''
}

function Get-WtfProcessDirCandidates {
    <#
    .SYNOPSIS
        Directories of the programs currently running inside a terminal window's
        panes — claude, node, python, and so on.
    .DESCRIPTION
        Used only as a FALLBACK, for panes whose prompt line has scrolled away.
        The pane's own shell is skipped on purpose: PowerShell's Set-Location does
        not change the process directory, so a shell always reports your home
        folder no matter where you cd'd to. Its children report the truth.
    #>
    param([Parameter(Mandatory)][int]$WtProcessId)

    if (-not ('WtfPeb' -as [type])) { return @() }

    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
             Select-Object ProcessId, ParentProcessId, Name)
    if ($all.Count -eq 0) { return @() }

    $kids = @{}
    foreach ($p in $all) {
        $k = [int]$p.ParentProcessId
        if (-not $kids.ContainsKey($k)) { $kids[$k] = New-Object System.Collections.ArrayList }
        [void]$kids[$k].Add($p)
    }

    $skip = @('OpenConsole.exe','conhost.exe','powershell.exe','pwsh.exe','cmd.exe')
    $out  = New-Object System.Collections.ArrayList

    $stack = New-Object System.Collections.Stack
    $stack.Push(@{ Pid = $WtProcessId; Depth = 0 })
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        if ($cur.Depth -gt 4) { continue }
        if (-not $kids.ContainsKey([int]$cur.Pid)) { continue }
        foreach ($c in $kids[[int]$cur.Pid]) {
            $cpid = [int]$c.ProcessId
            $stack.Push(@{ Pid = $cpid; Depth = $cur.Depth + 1 })
            if ($skip -contains $c.Name) { continue }
            $cwd = [WtfPeb]::Cwd($cpid)
            if (-not $cwd) { continue }
            $cwd = $cwd.TrimEnd('\')
            if ($cwd -match '^[A-Za-z]:\\WINDOWS' -or $cwd -match '\\AppData\\Local\\Temp$') { continue }
            [void]$out.Add([pscustomobject]@{ Pid = $cpid; Name = $c.Name; Dir = $cwd })
        }
    }
    return @($out)
}

function Resolve-WtfPaneDirs {
    <#
    .SYNOPSIS
        Fill in each pane's directory, best source first.
    .DESCRIPTION
        1. the pane's own prompt line          -> exact       (DirSource = 'prompt')
        2. a running program's directory whose folder name appears in the pane
           text — an agent pane's status bar usually names its project
                                               -> inferred    (DirSource = 'process')
        3. nothing                             -> blank, you fill it in
    #>
    param(
        [Parameter(Mandatory)]$Panes,
        [int]$WtProcessId = 0
    )
    $panes = @($Panes)

    foreach ($p in $panes) {
        $d = Get-WtfPromptDir -Text $p.Text
        if ($d) { $p.Dir = $d; $p.DirSource = 'prompt' }
    }

    $unresolved = @($panes | Where-Object { -not $_.Dir })
    if ($unresolved.Count -eq 0 -or $WtProcessId -le 0) { return $panes }

    $cands = Get-WtfProcessDirCandidates -WtProcessId $WtProcessId
    if ($cands.Count -eq 0) { return $panes }

    # Directories already claimed by a resolved pane are still allowed here: you
    # can legitimately have several panes in the same folder.
    foreach ($p in $unresolved) {
        # Look only at the visible tail — the status bar an agent draws at the
        # bottom is where the project name shows up.
        $tail = $p.Text
        if ($tail.Length -gt 4000) { $tail = $tail.Substring($tail.Length - 4000) }

        $best = $null
        foreach ($c in $cands) {
            $leaf = Split-Path $c.Dir -Leaf
            if (-not $leaf) { continue }
            if ($tail -match [regex]::Escape($leaf)) {
                # Prefer the deepest path, so a worktree beats its parent folder.
                if (-not $best -or $c.Dir.Length -gt $best.Dir.Length) { $best = $c }
            }
        }
        if ($best) { $p.Dir = $best.Dir; $p.DirSource = 'process' }
    }
    return @($panes)
}

# ============================================================================
# GEOMETRY -> SPLIT TREE
# ============================================================================

function Build-WtfPaneTree {
    <#
    .SYNOPSIS
        Turn a flat set of pane rectangles back into the split tree that produced
        them.
    .DESCRIPTION
        Look for a straight line that divides the panes into two groups with no
        pane straddling it. A vertical line means a side-by-side split; a
        horizontal line means a stacked one. The cut is placed in the middle of
        the gap between the two groups, which is where the splitter bar sits, and
        the size is stored as the FIRST group's fraction of the region. Recurse
        into both halves.
    .OUTPUTS
        Leaf : @{ kind='leaf'; index=<pane index> }
        Split: @{ kind='split'; dir='V'|'H'; size=<fraction of first child>; a=..; b=.. }
    #>
    param(
        [Parameter(Mandatory)]$Items,
        [double]$BX, [double]$BY, [double]$BW, [double]$BH
    )
    $items = @($Items)
    if ($items.Count -eq 0) { return $null }
    if ($items.Count -eq 1) { return @{ kind = 'leaf'; index = $items[0].Index } }

    # side-by-side?
    foreach ($cand in ($items | ForEach-Object { $_.X + $_.W } | Sort-Object -Unique)) {
        $a = @($items | Where-Object { ($_.X + $_.W) -le $cand })
        $b = @($items | Where-Object { $_.X -ge $cand })
        if ($a.Count -gt 0 -and $b.Count -gt 0 -and ($a.Count + $b.Count) -eq $items.Count) {
            $g1  = ($a | ForEach-Object { $_.X + $_.W } | Measure-Object -Maximum).Maximum
            $g2  = ($b | Measure-Object -Property X -Minimum).Minimum
            $cut = ($g1 + $g2) / 2.0
            return @{
                kind = 'split'; dir = 'V'
                size = [Math]::Round((($cut - $BX) / $BW), 4)
                a = (Build-WtfPaneTree -Items $a -BX $BX  -BY $BY -BW ($cut - $BX)       -BH $BH)
                b = (Build-WtfPaneTree -Items $b -BX $cut -BY $BY -BW ($BX + $BW - $cut) -BH $BH)
            }
        }
    }
    # stacked?
    foreach ($cand in ($items | ForEach-Object { $_.Y + $_.H } | Sort-Object -Unique)) {
        $a = @($items | Where-Object { ($_.Y + $_.H) -le $cand })
        $b = @($items | Where-Object { $_.Y -ge $cand })
        if ($a.Count -gt 0 -and $b.Count -gt 0 -and ($a.Count + $b.Count) -eq $items.Count) {
            $g1  = ($a | ForEach-Object { $_.Y + $_.H } | Measure-Object -Maximum).Maximum
            $g2  = ($b | Measure-Object -Property Y -Minimum).Minimum
            $cut = ($g1 + $g2) / 2.0
            return @{
                kind = 'split'; dir = 'H'
                size = [Math]::Round((($cut - $BY) / $BH), 4)
                a = (Build-WtfPaneTree -Items $a -BX $BX -BY $BY  -BW $BW -BH ($cut - $BY))
                b = (Build-WtfPaneTree -Items $b -BX $BX -BY $cut -BW $BW -BH ($BY + $BH - $cut))
            }
        }
    }
    # Should not happen with real Windows Terminal layouts (they are always a
    # binary split tree), but never lose panes if it does.
    return @{ kind = 'unresolved'; indexes = @($items | ForEach-Object { $_.Index }) }
}

function Get-WtfTreeLeafOrder {
    <#
    .SYNOPSIS
        Pane indexes in tree order (first child before second, depth first).
        This is the order panes are numbered in and shown to you.
    #>
    param($Node)
    # Collected into an accumulator rather than joined from return values.
    # Returning arrays from a recursive PowerShell function is a trap: a
    # one-element array unwraps to a scalar, so '+' adds the numbers instead of
    # joining the lists (0 + 1 = 1, not 0,1), and wrapping to stop that just
    # nests the arrays instead. An accumulator has neither problem.
    $acc = New-Object System.Collections.ArrayList
    Add-WtfLeafOrder -Node $Node -Acc $acc
    return @($acc)
}

function Add-WtfLeafOrder {
    param($Node, $Acc)
    if (-not $Node) { return }
    if ($Node.kind -eq 'leaf') { [void]$Acc.Add($Node.index); return }
    if ($Node.kind -eq 'unresolved') {
        foreach ($i in @($Node.indexes)) { [void]$Acc.Add($i) }
        return
    }
    Add-WtfLeafOrder -Node $Node.a -Acc $Acc
    Add-WtfLeafOrder -Node $Node.b -Acc $Acc
}

function Get-WtfCaptureFromWindow {
    <#
    .SYNOPSIS
        Read one window's active tab into a capture object: pane list + tree.
    .OUTPUTS
        @{ TabName; Panes = @(@{ id; dir; dirSource }); Tree }
        Panes are numbered 1..n in tree order, so pane 1 is always the top-left.
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$Hwnd,
        [int]$ExcludePaneIndex = -1
    )
    # @() matters: a single-pane tab would otherwise arrive as a bare
    # object whose .Count is $null, and the emptiness test would pass.
    $raw = @(Get-WtfWindowPanes -Hwnd $Hwnd -WithText)
    if ($raw.Count -eq 0) { return $null }

    $wtPid = 0
    try {
        $el = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
        $wtPid = [int]$el.Current.ProcessId
    } catch { }

    $raw = Resolve-WtfPaneDirs -Panes $raw -WtProcessId $wtPid

    if ($ExcludePaneIndex -ge 0) {
        $raw = @($raw | Where-Object { $_.Index -ne $ExcludePaneIndex })
        if ($raw.Count -eq 0) {
            Write-WtfLayoutFail "Excluding this pane would leave the layout empty."
            return $null
        }
        # Re-index so the geometry pass sees a clean 0..n-1 sequence.
        for ($i = 0; $i -lt $raw.Count; $i++) { $raw[$i].Index = $i }
    }

    $bx = ($raw | Measure-Object -Property X -Minimum).Minimum
    $by = ($raw | Measure-Object -Property Y -Minimum).Minimum
    $bw = (($raw | ForEach-Object { $_.X + $_.W } | Measure-Object -Maximum).Maximum) - $bx
    $bh = (($raw | ForEach-Object { $_.Y + $_.H } | Measure-Object -Maximum).Maximum) - $by
    if ($bw -le 0 -or $bh -le 0) { return $null }

    $tree  = Build-WtfPaneTree -Items $raw -BX $bx -BY $by -BW $bw -BH $bh
    $order = @(Get-WtfTreeLeafOrder $tree)

    # Renumber to 1..n in tree order and rewrite the tree to use the new ids.
    $map = @{}
    for ($i = 0; $i -lt $order.Count; $i++) { $map[[string]$order[$i]] = $i + 1 }

    $panes = @()
    foreach ($idx in $order) {
        $src = $raw | Where-Object { $_.Index -eq $idx } | Select-Object -First 1
        $panes += @{
            id        = $map[[string]$idx]
            dir       = [string]$src.Dir
            dirSource = [string]$src.DirSource
            command   = ''
        }
    }

    $tabs = Get-WtfWindowTabs -Hwnd $Hwnd
    return @{
        TabName = $tabs.SelectedName
        Panes   = @($panes)
        Tree    = (Rename-WtfTreeIds -Node $tree -Map $map)
    }
}

function Rename-WtfTreeIds {
    param($Node, $Map)
    if (-not $Node) { return $null }
    if ($Node.kind -eq 'leaf') { return @{ kind = 'leaf'; index = $Map[[string]$Node.index] } }
    if ($Node.kind -eq 'unresolved') {
        return @{ kind = 'unresolved'; indexes = @($Node.indexes | ForEach-Object { $Map[[string]$_] }) }
    }
    return @{
        kind = 'split'; dir = $Node.dir; size = $Node.size
        a = (Rename-WtfTreeIds -Node $Node.a -Map $Map)
        b = (Rename-WtfTreeIds -Node $Node.b -Map $Map)
    }
}

# ============================================================================
# LAYOUT STORE
# ============================================================================

function Test-WtfLayoutName {
    <#
    .SYNOPSIS
        Is this usable as both a filename and a tab title?
    .DESCRIPTION
        Allowed : letters, digits, spaces, - _ . and emoji. Up to 60 characters.
        Rejected: \ / : * ? " < > | and the Windows reserved device names.
        Comparison ignores case, because Windows filenames do.
    .OUTPUTS
        @{ Ok = bool; Reason = string; Name = <trimmed name> }
    #>
    param([string]$Name)

    $n = ''
    if ($Name) { $n = $Name.Trim() }
    if (-not $n) { return @{ Ok = $false; Reason = 'the name is empty'; Name = '' } }
    if ($n.Length -gt 60) { return @{ Ok = $false; Reason = 'longer than 60 characters'; Name = $n } }

    $bad = [regex]::Match($n, '[\\/:\*\?"<>\|]')
    if ($bad.Success) {
        return @{ Ok = $false; Reason = "'$($bad.Value)' is not allowed in a name (\ / : * ? "" < > | are reserved)"; Name = $n }
    }
    if ($n.EndsWith('.')) { return @{ Ok = $false; Reason = 'a name cannot end with a dot'; Name = $n } }

    $reserved = @('CON','PRN','AUX','NUL')
    for ($i = 1; $i -le 9; $i++) { $reserved += "COM$i"; $reserved += "LPT$i" }
    $stem = $n.Split('.')[0]
    foreach ($r in $reserved) {
        if ($stem -and $stem.ToUpper() -eq $r) { return @{ Ok = $false; Reason = "'$r' is a reserved Windows name"; Name = $n } }
    }
    return @{ Ok = $true; Reason = ''; Name = $n }
}

function Get-WtfLayoutPath {
    param([Parameter(Mandatory)][string]$Name)
    return (Join-Path $script:WtfLayoutDir ($Name + '.json'))
}

function Get-WtfLayoutNames {
    if (-not (Test-Path $script:WtfLayoutDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $script:WtfLayoutDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending |
             ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) })
}

function Find-WtfLayoutName {
    # Case-insensitive lookup of an existing layout; returns its real name or ''.
    param([string]$Name)
    if (-not $Name) { return '' }
    foreach ($n in (Get-WtfLayoutNames)) {
        if ($n -and $n.ToLower() -eq $Name.ToLower()) { return $n }
    }
    return ''
}

function Read-WtfLayout {
    param([Parameter(Mandatory)][string]$Name)
    $p = Get-WtfLayoutPath -Name $Name
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $json = Get-Content -LiteralPath $p -Raw -Encoding UTF8
        return (ConvertTo-WtfHashtable (ConvertFrom-Json $json))
    } catch {
        Write-WtfLayoutFail "Could not read layout '$Name': $($_.Exception.Message)"
        return $null
    }
}

function Write-WtfLayout {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Layout)
    if (-not (Test-Path $script:WtfLayoutDir)) {
        New-Item -ItemType Directory -Path $script:WtfLayoutDir -Force | Out-Null
    }
    $p   = Get-WtfLayoutPath -Name $Name
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($p, ($Layout | ConvertTo-Json -Depth 30), $enc)
    return $p
}

function New-WtfLayoutObject {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Panes,
        [Parameter(Mandatory)]$Tree,
        [string]$Shell = 'powershell'
    )
    return @{
        version    = 1
        name       = $Name
        capturedAt = (Get-Date -Format o)
        shell      = $Shell
        panes      = @($Panes)
        tree       = $Tree
    }
}

# ============================================================================
# DIFF — what changed since the layout was last saved
# ============================================================================

function Compare-WtfLayout {
    <#
    .SYNOPSIS
        Compare a fresh capture against a saved layout, pane by pane.
    .DESCRIPTION
        A snapshot always re-reads the whole tab, so every change shows up on its
        own: a closed pane is simply absent, a new pane is simply present, and a
        changed directory reads as the new directory.

        Panes are matched by DIRECTORY first, in tree order, because that is what
        actually identifies a pane to you. Whatever is left over is matched by
        position. Each result is classified so the tool can tell you what it found
        instead of deciding quietly on your behalf.
    .OUTPUTS
        @{ Rows = @(@{ id; dir; command; status; oldDir; oldCommand }); NeedsAttention = bool }
        status is one of: same | moved | dirchanged | new
        plus separate 'removed' rows for panes that no longer exist.
    #>
    param(
        [Parameter(Mandatory)]$Capture,
        $Saved   # $null when this is a first capture
    )
    $newPanes = @($Capture.Panes)

    if (-not $Saved) {
        $rows = @()
        foreach ($p in $newPanes) {
            $rows += @{ id = $p.id; dir = $p.dir; dirSource = $p.dirSource; command = ''
                        status = 'new'; oldDir = ''; oldCommand = ''; mustAsk = $true }
        }
        return @{ Rows = @($rows); Removed = @(); NeedsAttention = $true; IsFirst = $true }
    }

    $oldPanes = @($Saved.panes)
    $usedOld  = @{}
    $rows     = @()

    # pass 1 — exact directory match, in tree order
    foreach ($p in $newPanes) {
        $match = $null
        foreach ($o in $oldPanes) {
            $key = [string]$o.id
            if ($usedOld.ContainsKey($key)) { continue }
            $od = ''
            if ($o.dir) { $od = ([string]$o.dir).TrimEnd('\') }
            $nd = ''
            if ($p.dir) { $nd = ([string]$p.dir).TrimEnd('\') }
            if ($od -and $nd -and $od.ToLower() -eq $nd.ToLower()) { $match = $o; break }
        }
        if ($match) {
            $usedOld[[string]$match.id] = $true
            $status = 'same'
            if ([int]$match.id -ne [int]$p.id) { $status = 'moved' }
            $rows += @{ id = $p.id; dir = $p.dir; dirSource = $p.dirSource
                        command = [string]$match.command; status = $status
                        oldDir = [string]$match.dir; oldCommand = [string]$match.command }
        } else {
            $rows += $null   # placeholder, filled in pass 2
        }
    }

    # pass 2 — leftovers matched by position, so a pane that only changed folder
    # keeps its identity and we can TELL you the directory moved.
    for ($i = 0; $i -lt $rows.Count; $i++) {
        if ($rows[$i]) { continue }
        $p = $newPanes[$i]
        $cand = $null
        foreach ($o in $oldPanes) {
            $key = [string]$o.id
            if ($usedOld.ContainsKey($key)) { continue }
            if ([int]$o.id -eq [int]$p.id) { $cand = $o; break }
        }
        if (-not $cand) {
            foreach ($o in $oldPanes) {
                $key = [string]$o.id
                if (-not $usedOld.ContainsKey($key)) { $cand = $o; break }
            }
        }
        if ($cand) {
            $usedOld[[string]$cand.id] = $true
            $rows[$i] = @{ id = $p.id; dir = $p.dir; dirSource = $p.dirSource
                           command = [string]$cand.command; status = 'dirchanged'
                           oldDir = [string]$cand.dir; oldCommand = [string]$cand.command }
        } else {
            $rows[$i] = @{ id = $p.id; dir = $p.dir; dirSource = $p.dirSource
                           command = ''; status = 'new'; oldDir = ''; oldCommand = '' }
        }
    }

    $removed = @()
    foreach ($o in $oldPanes) {
        if (-not $usedOld.ContainsKey([string]$o.id)) {
            $removed += @{ id = $o.id; dir = [string]$o.dir; command = [string]$o.command }
        }
    }

    # Mark the rows whose command can no longer be trusted. These are never saved
    # quietly: the tool stops and asks about each one, because a command that was
    # right for the old folder is probably wrong for the new one.
    #
    # A note on one honest limit: when a pane closes and another opens in the same
    # snapshot, the count is unchanged and nothing on screen says which happened.
    # We report it as 'dirchanged' and show you the old folder and old command, so
    # the decision stays yours instead of being guessed silently.
    $needs = $false
    foreach ($r in $rows) {
        $ask = $false
        if ($r.status -eq 'dirchanged' -or $r.status -eq 'new') { $ask = $true }
        if ($r.dirSource -eq 'process') { $ask = $true }   # directory was inferred
        if (-not $r.dir) { $ask = $true }                  # directory unknown
        $r.mustAsk = $ask
        if ($ask) { $needs = $true }
    }
    if ($removed.Count -gt 0) { $needs = $true }

    return @{ Rows = @($rows); Removed = @($removed); NeedsAttention = $needs; IsFirst = $false }
}

# ============================================================================
# RESTORE — build the tab again
# ============================================================================

function Get-WtfLeftmostLeafId {
    param($Node)
    if (-not $Node) { return $null }
    if ($Node.kind -eq 'leaf') { return $Node.index }
    if ($Node.kind -eq 'unresolved') { return @($Node.indexes)[0] }
    return (Get-WtfLeftmostLeafId $Node.a)
}

function Add-WtfRestoreSteps {
    <#
    .SYNOPSIS
        Recursive worker for Build-WtfRestorePlan. Emits the steps that build
        $Node, given that wt pane $WtPane currently covers $Node's whole region.
    .DESCRIPTION
        Splitting always acts on the FOCUSED pane, and after a split the focus
        moves to the NEW pane. So for a split node:
          1. make sure focus is on the pane holding this region
          2. split it — that creates the second half and focuses it
          3. build the second half (focus is already there)
          4. build the first half, steering focus back to the original pane
        Windows Terminal numbers panes in creation order from 0, and that is what
        `focus-pane --target` takes, so step 4 is always exact.
    .NOTES
        $State is a hashtable carried through the recursion:
          Steps (ArrayList) · NextWt (int) · Focused (int) · ById (hashtable)
    #>
    param(
        [Parameter(Mandatory)]$State,
        $Node,
        [Parameter(Mandatory)][int]$WtPane
    )
    if (-not $Node) { return }

    if ($Node.kind -eq 'leaf' -or $Node.kind -eq 'unresolved') { return }

    if ($State.Focused -ne $WtPane) {
        [void]$State.Steps.Add(@{ kind = 'focus'; target = $WtPane })
        $State.Focused = $WtPane
    }

    # The new pane starts out covering the whole SECOND half, so it is created
    # with the settings of that half's leftmost leaf — the pane it becomes.
    $bLeaf = Get-WtfLeftmostLeafId -Node $Node.b
    $bPane = $State.ById[[string]$bLeaf]

    # wt's -s sizes the NEW pane, and the new pane is the second half, so pass
    # 1 minus the first half's share. Clamp so a very lopsided split still opens.
    $newFrac = [Math]::Round((1.0 - [double]$Node.size), 4)
    if ($newFrac -lt 0.05) { $newFrac = 0.05 }
    if ($newFrac -gt 0.95) { $newFrac = 0.95 }

    $newId = [int]$State.NextWt
    $State.NextWt = $newId + 1

    $bDir = ''
    $bCmd = ''
    if ($bPane) { $bDir = [string]$bPane.dir; $bCmd = [string]$bPane.command }

    [void]$State.Steps.Add(@{
        kind = 'split'; split = $Node.dir; size = $newFrac
        paneId = $bLeaf; dir = $bDir; command = $bCmd
    })
    $State.Focused = $newId

    Add-WtfRestoreSteps -State $State -Node $Node.b -WtPane $newId
    Add-WtfRestoreSteps -State $State -Node $Node.a -WtPane $WtPane
}

function Build-WtfRestorePlan {
    <#
    .SYNOPSIS
        Turn a layout into an ordered list of wt.exe steps.
    .OUTPUTS
        Ordered array of steps:
          @{ kind='new-tab'; paneId; dir; command }
          @{ kind='split'; split='V'|'H'; size=<new pane fraction>; paneId; dir; command }
          @{ kind='focus'; target=<wt pane id> }
    #>
    param([Parameter(Mandatory)]$Layout)

    $byId = @{}
    foreach ($p in @($Layout.panes)) { $byId[[string]$p.id] = $p }

    $rootLeaf = Get-WtfLeftmostLeafId -Node $Layout.tree
    if ($null -eq $rootLeaf) { return @() }
    $rootPane = $byId[[string]$rootLeaf]

    $steps = New-Object System.Collections.ArrayList
    $rDir  = ''
    $rCmd  = ''
    if ($rootPane) { $rDir = [string]$rootPane.dir; $rCmd = [string]$rootPane.command }
    [void]$steps.Add(@{ kind = 'new-tab'; paneId = $rootLeaf; dir = $rDir; command = $rCmd })

    $state = @{ Steps = $steps; NextWt = 1; Focused = 0; ById = $byId }
    Add-WtfRestoreSteps -State $state -Node $Layout.tree -WtPane 0
    return @($state.Steps)
}

function Get-WtfPaneLaunchArgs {
    <#
    .SYNOPSIS
        The shell arguments that put a pane in its directory and run its command.
    .DESCRIPTION
        The directory is set INSIDE the launched script rather than relying on
        wt's -d alone, because a PowerShell profile can move you somewhere else
        after startup (yours does exactly that: it runs Set-Location ~).

        The whole script is base64 encoded, so a command may contain anything at
        all — quotes, and above all ';', which is wt's own separator.
    #>
    param([string]$Shell, [string]$Dir, [string]$Command)

    $sh = $Shell
    if (-not $sh) { $sh = 'powershell' }

    $lines = @()
    if ($Dir) {
        $safe = $Dir -replace "'", "''"
        $lines += "Set-Location -LiteralPath '$safe'"
    }
    if ($Command) { $lines += $Command }
    if ($lines.Count -eq 0) { return @($sh, '-NoExit') }

    $script = ($lines -join "`n")
    $enc    = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))
    return @($sh, '-NoExit', '-EncodedCommand', $enc)
}

function Wait-WtfPaneCount {
    <#
    .SYNOPSIS
        Wait until a window's active tab holds $Count panes AND the geometry has
        stopped moving.
    .DESCRIPTION
        Counting alone is not enough. Windows Terminal reports the new pane before
        it has finished laying the tab out, and measuring during that moment gives
        wrong rectangles. So we also require two identical reads in a row.
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$Hwnd,
        [Parameter(Mandatory)][int]$Count,
        [int]$TimeoutMs = 15000,
        [switch]$CountOnly,
        [int]$SettleMs = 250
    )
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    $last = ''
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        Start-Sleep -Milliseconds 100
        $p = @(Get-WtfWindowPanes -Hwnd $Hwnd)
        if ($p.Count -lt $Count) { $last = ''; continue }
        if ($CountOnly) {
            # Enough for a restore: the pane exists, so the next split will act
            # on it. A short settle lets focus finish moving.
            Start-Sleep -Milliseconds $SettleMs
            return $true
        }
        $sig = (@($p | ForEach-Object { "$($_.X),$($_.Y),$($_.W),$($_.H)" }) -join '|')
        if ($sig -eq $last) { return $true }
        $last = $sig
    }
    return $false
}

function Format-WtfLayoutDir {
    # Short form of a path for a progress line: the last two parts are enough
    # to tell panes apart, and a full path would wrap in a narrow pane.
    param([string]$Path)
    if (-not $Path) { return '(default folder)' }
    $parts = @($Path.TrimEnd('\') -split '\\' | Where-Object { $_ })
    if ($parts.Count -le 2) { return $Path }
    return '...\' + ($parts[-2..-1] -join '\')
}

function Invoke-WtfWtCall {
    param([Parameter(Mandatory)][string[]]$Argv)
    if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
        Write-WtfLayoutFail "Windows Terminal (wt.exe) was not found on PATH."
        return $false
    }
    Start-Process -FilePath 'wt.exe' -ArgumentList $Argv
    return $true
}

function Invoke-WtfLayoutRestore {
    <#
    .SYNOPSIS
        Rebuild a layout as a NEW TAB in the current terminal window.
    .DESCRIPTION
        Each step is its own wt.exe call, waiting for the previous one to land.
        Inside a single wt command line the sub-commands do not carry focus
        between them, so `focus-pane` is ignored and nested trees come out wrong.

        --title and --suppressApplicationTitle are passed to EVERY pane. The tab
        shows the focused pane's title, so unless all of them are pinned the tab
        name flips back to the shell's own title as soon as you move focus. The
        tab name is what lets a later snapshot know which layout this tab is.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Layout,
        [string]$WindowTarget = '0'
    )
    if (-not (Initialize-WtfInterop)) { return $false }

    $plan = @(Build-WtfRestorePlan -Layout $Layout)
    if ($plan.Count -eq 0) { Write-WtfLayoutFail "Layout '$Name' has no panes."; return $false }

    $shell = 'powershell'
    if ($Layout.shell) { $shell = [string]$Layout.shell }

    $before = @(Get-WtfTerminalWindows)
    # Tab count per window BEFORE we start. The window that gains a tab is the
    # one the new tab landed in - exact, immediate, and independent of titles.
    $tabsBefore = @{}
    foreach ($h in $before) { $tabsBefore[[string]$h] = @((Get-WtfWindowTabs -Hwnd $h).Names).Count }
    # The most likely landing spot: the topmost window.
    $preferred = [IntPtr]::Zero
    if ($before.Count -gt 0) { $preferred = $before[0] }
    # Stable colour per name. Built by hand rather than GetHashCode(), which is
    # not stable across processes and can return Int32.MinValue (Abs would throw).
    $sum = 0
    foreach ($ch in $Name.ToCharArray()) { $sum = ($sum * 31 + [int]$ch) % 100000 }
    $color = $script:WtfLayoutColors[$sum % $script:WtfLayoutColors.Count]
    $SUP   = '--suppressApplicationTitle'

    $paneNo = 0
    $hwnd   = [IntPtr]::Zero
    $total  = @($plan | Where-Object { $_.kind -ne 'focus' }).Count
    $clock  = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($step in $plan) {
        if ($step.kind -eq 'focus') {
            [void](Invoke-WtfWtCall -Argv @('-w', $WindowTarget, 'focus-pane', '--target', [string]$step.target))
            Start-Sleep -Milliseconds 300
            continue
        }

        if ($step.kind -eq 'new-tab') {
            $dir  = [string]$step.dir
            $run  = Get-WtfPaneLaunchArgs -Shell $shell -Dir $dir -Command ([string]$step.command)
            $argv = @('-w', $WindowTarget, 'new-tab', '--title', $Name, $SUP, '--tabColor', $color)
            if ($dir -and (Test-Path -LiteralPath $dir)) { $argv += @('-d', $dir) }
            elseif ($dir) { Write-WtfLayoutWarn "pane 1: '$dir' does not exist — opening in the default folder" }
            $argv += $run
            if (-not (Invoke-WtfWtCall -Argv $argv)) { return $false }
            $paneNo = 1

            # Find the window the new tab landed in. Restoring into the current
            # window is the normal case, and there we already know which window
            # that is: the topmost one, which Get-WtfTerminalWindows returns
            # first because EnumWindows walks in Z-order. Checking that single
            # window is one query; polling the tab name of every open window
            # took seconds once a few were open.
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($sw.ElapsedMilliseconds -lt 15000 -and $hwnd -eq [IntPtr]::Zero) {
                Start-Sleep -Milliseconds 120

                # A brand new window - the target name did not exist yet.
                $fresh = @(Get-WtfTerminalWindows | Where-Object { $before -notcontains $_ })
                if ($fresh.Count -gt 0) { $hwnd = $fresh[0]; break }

                # Otherwise: whichever existing window just gained a tab. Check
                # the topmost one first, since that is where -w 0 lands.
                $order = @()
                if ($preferred -ne [IntPtr]::Zero) { $order += $preferred }
                foreach ($h in (Get-WtfTerminalWindows)) { if ($h -ne $preferred) { $order += $h } }

                foreach ($h in $order) {
                    $tabs = Get-WtfWindowTabs -Hwnd $h
                    $now  = @($tabs.Names).Count
                    $was  = 0
                    if ($tabsBefore.ContainsKey([string]$h)) { $was = [int]$tabsBefore[[string]$h] }

                    # Two independent signals. The tab title is the strong one.
                    # Tab growth is only trusted when the earlier count was
                    # actually readable: an unreadable window reports 0 tabs and
                    # would otherwise look like it had just gained one.
                    $named = ($tabs.SelectedName -eq $Name)
                    $grew  = ($was -gt 0 -and $now -gt $was)
                    if (-not ($named -or $grew)) { continue }

                    # And it must really have a pane, so we never wait on a
                    # window whose panes are not on screen.
                    if (@(Get-WtfWindowPanes -Hwnd $h).Count -lt 1) { continue }

                    $hwnd = $h
                    break
                }
            }
            if ($hwnd -eq [IntPtr]::Zero) {
                Write-WtfLayoutFail "The tab was created but could not be located to continue."
                return $false
            }
            if (-not (Wait-WtfPaneCount -Hwnd $hwnd -Count 1 -CountOnly)) {
                Write-WtfLayoutWarn "the first pane was slow to appear; carrying on"
            }
            Write-WtfLayoutStep ("pane 1/$total  " + (Format-WtfLayoutDir $dir))
            continue
        }

        # split
        $dir  = [string]$step.dir
        $run  = Get-WtfPaneLaunchArgs -Shell $shell -Dir $dir -Command ([string]$step.command)
        $flag = '-H'
        if ($step.split -eq 'V') { $flag = '-V' }
        $argv = @('-w', $WindowTarget, 'split-pane', $flag, '-s', ([string]$step.size), '--title', $Name, $SUP)
        if ($dir -and (Test-Path -LiteralPath $dir)) { $argv += @('-d', $dir) }
        elseif ($dir) { Write-WtfLayoutWarn "pane $($step.paneId): '$dir' does not exist — opening in the default folder" }
        $argv += $run
        if (-not (Invoke-WtfWtCall -Argv $argv)) { return $false }

        $paneNo = $paneNo + 1
        if (-not (Wait-WtfPaneCount -Hwnd $hwnd -Count $paneNo -CountOnly)) {
            Write-WtfLayoutWarn "pane $paneNo was slow to appear; carrying on"
        }
        Write-WtfLayoutStep ("pane $paneNo/$total  " + (Format-WtfLayoutDir $dir))
    }
    $clock.Stop()
    Write-WtfLayoutInfo ("rebuilt $total panes in " + [Math]::Round($clock.Elapsed.TotalSeconds, 1) + "s")
    return $true
}
