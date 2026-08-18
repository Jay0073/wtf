# wtf-hotkey.ps1 — install, remove and inspect the global hotkeys.
#
# Two of them:
#   ALT+SHIFT+S   save the tab in front as a layout
#   ALT+SHIFT+O   pick a saved layout and rebuild it as a new tab
#
# Windows itself provides the mechanism: a shortcut (.lnk) in the Start Menu can
# carry a "shortcut key", and Windows then watches for it. No extra software and
# no background process to look after.
#
# A note on how global these really are. The focused application sees the key
# FIRST; Windows only acts on the shortcut key when the application does not
# handle it. That is what keeps these two safe here - neither is a Windows
# Terminal binding, so they reach us even while the terminal is focused, which
# is exactly what snapping the front tab needs. They also stay clear of the pane
# keys already in use: ALT+SHIFT+plus/minus to split, ALT+SHIFT+arrows to resize.
#
# Runs on Windows PowerShell 5.1 and PowerShell 7+. Save as UTF-8 WITH BOM.

# What a hotkey can be bound to: link name, runner script, default combination.
$script:WtfHotkeyActions = @{
    snap = @{
        Link    = 'wtf snap.lnk'
        Runner  = 'wtf-snap-hotkey.ps1'
        Default = 'ALT+SHIFT+S'
        Blurb   = 'Save the current Windows Terminal tab as a wtf layout'
    }
    open = @{
        Link    = 'wtf open.lnk'
        Runner  = 'wtf-open-hotkey.ps1'
        Default = 'ALT+SHIFT+O'
        Blurb   = 'Open a saved wtf layout as a new Windows Terminal tab'
    }
}

function Get-WtfHotkeyDir {
    # The Start Menu is one of the two places Windows honours a shortcut key
    # from (the Desktop is the other). Programs\ keeps it out of the way.
    return (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
}

function Get-WtfHotkeyLinkPath {
    param([Parameter(Mandatory)][string]$Action)
    return (Join-Path (Get-WtfHotkeyDir) $script:WtfHotkeyActions[$Action].Link)
}

function ConvertTo-WtfHotkeyString {
    <#
    .SYNOPSIS
        Normalise a combination like "alt+shift+s" into the form a shortcut
        wants, e.g. "ALT+SHIFT+S".
    .OUTPUTS
        @{ Ok = bool; Value = string; Reason = string }
    #>
    param([string]$Combo)

    if (-not $Combo) { return @{ Ok = $false; Value = ''; Reason = 'no combination given' } }
    $parts = @($Combo.ToUpper() -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($parts.Count -lt 2) {
        return @{ Ok = $false; Value = ''; Reason = 'a hotkey needs at least one modifier, for example ALT+SHIFT+S' }
    }

    $mods = @()
    $key  = ''
    foreach ($p in $parts) {
        if ($p -eq 'CTRL' -or $p -eq 'CONTROL') { $mods += 'CTRL';  continue }
        if ($p -eq 'ALT'  -or $p -eq 'MENU')    { $mods += 'ALT';   continue }
        if ($p -eq 'SHIFT')                     { $mods += 'SHIFT'; continue }
        if ($key) { return @{ Ok = $false; Value = ''; Reason = "only one non-modifier key is allowed (saw '$key' and '$p')" } }
        $key = $p
    }
    if (-not $key)         { return @{ Ok = $false; Value = ''; Reason = 'no key given, only modifiers' } }
    if ($mods.Count -eq 0) { return @{ Ok = $false; Value = ''; Reason = 'no modifier given' } }
    if ($key.Length -ne 1 -and $key -notmatch '^F([1-9]|1[0-2])$') {
        return @{ Ok = $false; Value = ''; Reason = "'$key' is not a single key or an F-key" }
    }

    # Windows wants the modifiers in this order.
    $ordered = @()
    foreach ($m in @('CTRL','ALT','SHIFT')) { if ($mods -contains $m) { $ordered += $m } }
    return @{ Ok = $true; Value = (($ordered + $key) -join '+'); Reason = '' }
}

function Initialize-WtfHotkeyProbe {
    <#
    .SYNOPSIS
        Load the helpers used to tell the shell about a shortcut and to check
        whether a key combination is actually registered. Idempotent.
    #>
    if ('WtfHotkeyNative' -as [type]) { return $true }
    $src = @'
using System;
using System.Runtime.InteropServices;

public static class WtfHotkeyNative {
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);

    const int  SHCNE_CREATE = 0x00000002;
    const int  SHCNE_DELETE = 0x00000004;
    const uint SHCNF_PATHW  = 0x0005;

    static void Notify(int ev, string path) {
        IntPtr p = Marshal.StringToHGlobalUni(path);
        try { SHChangeNotify(ev, SHCNF_PATHW, p, IntPtr.Zero); }
        finally { Marshal.FreeHGlobal(p); }
    }
    public static void NotifyCreate(string path) { Notify(SHCNE_CREATE, path); }
    public static void NotifyDelete(string path) { Notify(SHCNE_DELETE, path); }

    // true  = the combination is FREE, i.e. nobody has registered it
    // false = something holds it (which, after installing, is what we want)
    public static bool IsFree(uint mods, uint vk) {
        int id = 0x5754;
        if (RegisterHotKey(IntPtr.Zero, id, mods, vk)) {
            UnregisterHotKey(IntPtr.Zero, id);
            return true;
        }
        return false;
    }
}
'@
    try { Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop; return $true }
    catch { return $false }
}

function ConvertTo-WtfHotkeyCode {
    <#
    .SYNOPSIS
        Turn "ALT+SHIFT+S" into the modifier flags and virtual-key code that
        RegisterHotKey wants.
    .OUTPUTS
        @{ Ok = bool; Mods = uint; Vk = uint }
    #>
    param([string]$Combo)
    $mods = 0
    $vk   = 0
    foreach ($p in @($Combo.ToUpper() -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if ($p -eq 'ALT')   { $mods = $mods -bor 1; continue }
        if ($p -eq 'CTRL')  { $mods = $mods -bor 2; continue }
        if ($p -eq 'SHIFT') { $mods = $mods -bor 4; continue }
        if ($p -match '^F([1-9]|1[0-2])$') { $vk = 0x6F + [int]$p.Substring(1); continue }
        if ($p.Length -eq 1) { $vk = [int][byte][char]$p; continue }
        return @{ Ok = $false; Mods = 0; Vk = 0 }
    }
    if ($mods -eq 0 -or $vk -eq 0) { return @{ Ok = $false; Mods = 0; Vk = 0 } }
    return @{ Ok = $true; Mods = [uint32]$mods; Vk = [uint32]$vk }
}

function Test-WtfHotkeyLive {
    <#
    .SYNOPSIS
        Is this combination registered by anyone? After installing, the answer
        should be yes - that is Explorer holding it for our shortcut.
    #>
    param([Parameter(Mandatory)][string]$Combo)
    if (-not (Initialize-WtfHotkeyProbe)) { return $null }
    $code = ConvertTo-WtfHotkeyCode -Combo $Combo
    if (-not $code.Ok) { return $null }
    return (-not [WtfHotkeyNative]::IsFree($code.Mods, $code.Vk))
}

function Install-WtfHotkey {
    param(
        [Parameter(Mandatory)][ValidateSet('snap','open')][string]$Action,
        [string]$Combo
    )
    $spec = $script:WtfHotkeyActions[$Action]
    if (-not $Combo) { $Combo = $spec.Default }

    $chk = ConvertTo-WtfHotkeyString -Combo $Combo
    if (-not $chk.Ok) { Write-WtfLayoutFail "$Action - $($chk.Reason)"; return $false }
    $hk = $chk.Value

    $runner = Join-Path $script:WtfRoot $spec.Runner
    if (-not (Test-Path $runner)) { Write-WtfLayoutFail "missing $runner"; return $false }

    $dir = Get-WtfHotkeyDir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # Windows PowerShell on purpose: it is always present, and it is the shell
    # the terminal panes run, so behaviour is the same however you trigger this.
    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $psExe)) { $psExe = 'powershell.exe' }

    # Launch through conhost so this gets a CLASSIC console window. Windows 11
    # otherwise hosts console apps inside Windows Terminal, which would make our
    # own window a terminal window - and then a snapshot can capture itself, and
    # `wt -w 0` can target us instead of the window you were working in.
    $conhost = Join-Path $env:WINDIR 'System32\conhost.exe'
    $target  = $psExe
    $cmdArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $runner + '"'
    if (Test-Path $conhost) {
        $target  = $conhost
        $cmdArgs = '"' + $psExe + '" ' + $cmdArgs
    }

    $link = Get-WtfHotkeyLinkPath -Action $Action
    if (-not (Write-WtfHotkeyLink -Link $link -Target $target -Arguments $cmdArgs -Blurb $spec.Blurb -Hotkey $hk)) {
        return $false
    }

    # Verify, do not assume. Writing the .lnk does not register anything by
    # itself: Explorer has to read the file first, and if it never does the key
    # is simply dead with no error shown anywhere.
    $live = Wait-WtfHotkeyLive -Combo $hk -Seconds 6
    if ($live -eq $false) {
        # One retry: delete, tell the shell, write it again, tell the shell.
        Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        if ('WtfHotkeyNative' -as [type]) { [WtfHotkeyNative]::NotifyDelete($link) }
        Start-Sleep -Milliseconds 700
        [void](Write-WtfHotkeyLink -Link $link -Target $target -Arguments $cmdArgs -Blurb $spec.Blurb -Hotkey $hk)
        $live = Wait-WtfHotkeyLive -Combo $hk -Seconds 6
    }

    if ($live -eq $false) {
        Write-WtfLayoutWarn "$Action -> $hk written, but Windows has not registered the key"
        Write-WtfLayoutInfo '    the shortcut exists; Explorer just has not picked it up'
        Write-WtfLayoutInfo '    restarting Explorer usually fixes it, or try another combination'
        return $false
    }

    Write-WtfLayoutOk "$Action -> $hk"
    return $true
}

function Write-WtfHotkeyLink {
    # Create the shortcut AND tell the shell it appeared. Without the second
    # part Explorer may never read the file, and the shortcut key never works.
    param([string]$Link, [string]$Target, [string]$Arguments, [string]$Blurb, [string]$Hotkey)
    try {
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($Link)
        $sc.TargetPath       = $Target
        $sc.Arguments        = $Arguments
        $sc.WorkingDirectory = $script:WtfRoot
        $sc.Description      = $Blurb
        $sc.WindowStyle      = 1
        $sc.Hotkey           = $Hotkey
        $sc.Save()
    } catch {
        Write-WtfLayoutFail "could not write the shortcut: $($_.Exception.Message)"
        return $false
    }
    if (Initialize-WtfHotkeyProbe) { [WtfHotkeyNative]::NotifyCreate($Link) }
    return $true
}

function Wait-WtfHotkeyLive {
    # Poll until the combination shows as registered. $null when we cannot tell.
    param([string]$Combo, [int]$Seconds = 6)
    for ($i = 0; $i -lt $Seconds; $i++) {
        Start-Sleep -Milliseconds 900
        $r = Test-WtfHotkeyLive -Combo $Combo
        if ($null -eq $r) { return $null }
        if ($r) { return $true }
    }
    return $false
}

function Remove-WtfHotkey {
    param([string]$Action)
    $targets = @('snap','open')
    if ($Action) { $targets = @($Action.ToLower()) }

    $any = $false
    foreach ($a in $targets) {
        if (-not $script:WtfHotkeyActions.ContainsKey($a)) { Write-WtfLayoutFail "unknown action '$a'"; continue }
        $link = Get-WtfHotkeyLinkPath -Action $a
        if (Test-Path $link) {
            Remove-Item -LiteralPath $link -Force
            if (Initialize-WtfHotkeyProbe) { [WtfHotkeyNative]::NotifyDelete($link) }
            Write-WtfLayoutOk "removed the $a hotkey"
            $any = $true
        }
    }
    if (-not $any) { Write-WtfLayoutInfo 'nothing to remove' }
}

function Show-WtfHotkeyStatus {
    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell } catch { }

    $found = $false
    foreach ($a in @('snap','open')) {
        $link = Get-WtfHotkeyLinkPath -Action $a
        if (-not (Test-Path $link)) {
            Write-WtfLayoutInfo "$a  - not installed"
            continue
        }
        $found = $true
        $hk = '(no key set)'
        if ($shell) {
            try { $sc = $shell.CreateShortcut($link); if ($sc.Hotkey) { $hk = $sc.Hotkey } } catch { }
        }
        $live = Test-WtfHotkeyLive -Combo $hk
        if ($live -eq $false) {
            Write-WtfLayoutWarn "$a  -> $hk   NOT registered by Windows - the key will do nothing"
            Write-WtfLayoutInfo  '     re-run: wtf hotkey install'
        } else {
            Write-WtfLayoutOk "$a  -> $hk"
        }
        Write-WtfLayoutInfo "     $link"
    }
    if (-not $found) { Write-WtfLayoutInfo 'install them with: wtf hotkey install' }
}

function Invoke-WtfHotkey {
    <#
    .SYNOPSIS
        Dispatcher for `wtf hotkey <sub> [action] [combo]`.
    .EXAMPLE
        wtf hotkey install                    both, at their defaults
        wtf hotkey install snap ALT+SHIFT+S
        wtf hotkey install open ALT+SHIFT+O
        wtf hotkey status
        wtf hotkey remove [snap|open]
    #>
    param([string]$Sub, [string]$Action, [string]$Combo)

    if (-not $Sub) { $Sub = 'status' }

    # `wtf hotkey install ALT+SHIFT+S` naming no action: take it as snap's combo,
    # since that is the one people mean.
    if ($Action -and $Action -match '\+' -and -not $Combo) {
        $Combo  = $Action
        $Action = 'snap'
    }

    $s = $Sub.ToLower()
    if ($s -eq 'install' -or $s -eq 'add' -or $s -eq 'set') {
        if ($Action) {
            if (-not $script:WtfHotkeyActions.ContainsKey($Action.ToLower())) {
                Write-WtfLayoutFail "unknown action '$Action' - use snap or open"
                return
            }
            [void](Install-WtfHotkey -Action $Action.ToLower() -Combo $Combo)
        } else {
            [void](Install-WtfHotkey -Action 'snap')
            [void](Install-WtfHotkey -Action 'open')
        }
        Write-WtfLayoutInfo 'Windows can take a few seconds to notice a new shortcut key.'
        Write-WtfLayoutInfo 'The focused app sees the key first, so an app already using it wins there.'
        return
    }
    if ($s -eq 'remove' -or $s -eq 'rm' -or $s -eq 'delete') { Remove-WtfHotkey -Action $Action; return }
    if ($s -eq 'status') { Show-WtfHotkeyStatus; return }
    if ($Sub -match '\+') { [void](Install-WtfHotkey -Action 'snap' -Combo $Sub); return }

    Write-WtfLayoutFail "unknown: wtf hotkey $Sub"
    Write-WtfLayoutInfo 'try: wtf hotkey install [snap|open] [ALT+SHIFT+S] | status | remove'
}
