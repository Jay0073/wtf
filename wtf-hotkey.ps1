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

    try {
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut((Get-WtfHotkeyLinkPath -Action $Action))
        $sc.TargetPath       = $psExe
        $sc.Arguments        = '-NoProfile -ExecutionPolicy Bypass -File "' + $runner + '"'
        $sc.WorkingDirectory = $script:WtfRoot
        $sc.Description      = $spec.Blurb
        $sc.WindowStyle      = 1
        $sc.Hotkey           = $hk
        $sc.Save()
    } catch {
        Write-WtfLayoutFail "could not create the $Action shortcut: $($_.Exception.Message)"
        return $false
    }

    Write-WtfLayoutOk "$Action -> $hk"
    return $true
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
        Write-WtfLayoutOk "$a  -> $hk"
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
