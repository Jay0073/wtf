# Does a tab carry an id we can trust, and does the binding notebook work?
#
# The tab title used to be how a snapshot knew which layout a tab was. It is not
# good enough: a pane you add by hand runs a program that renames itself, and the
# title is gone. Windows gives every tab a runtime id instead. This checks that
# the id really is stable in all the ways the binding depends on.
#
# Uses a throwaway window only. Your own windows are not touched.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-tabid.ps1
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\..\wtf.ps1"
[void](Initialize-WtfInterop)

$pass = 0; $fail = 0
function Check([string]$what, [bool]$ok, [string]$got = '') {
    if ($ok) { $script:pass++; Write-Host "  OK   $what" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  FAIL $what   got: $got" -ForegroundColor Red }
}

$W    = 'zztabid'
$SUP  = '--suppressApplicationTitle'
$MARK = 'ZZTABID'
$LAY  = 'zz-tabid-layout'
$script:hw = [IntPtr]::Zero

function Probe {
    # The throwaway window is the one that is not any window open before we began.
    foreach ($h in (Get-WtfTerminalWindows)) {
        if ($script:before -contains $h) { continue }
        return $h
    }
    return [IntPtr]::Zero
}
function Wait-Panes { param([int]$N, [int]$Ms = 30000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Ms) {
        Start-Sleep -Milliseconds 400
        $h = Probe
        if ($h -ne [IntPtr]::Zero) {
            $p = @(Get-WtfWindowPanes -Hwnd $h)
            if ($p.Count -ge $N) { Start-Sleep -Milliseconds 900; return $h }
        }
    }
    return [IntPtr]::Zero
}

$script:before = @(Get-WtfTerminalWindows)
$bindBackup = $null
if (Test-Path -LiteralPath $script:WtfBindFile) {
    $bindBackup = Get-Content -LiteralPath $script:WtfBindFile -Raw -Encoding UTF8
}

Write-Host "=== 1. build a 2-pane tab the way `wtf tab open` does ===" -ForegroundColor Cyan
Start-Process wt.exe -ArgumentList @('-w',$W,'new-tab','--title',$MARK,$SUP,'-d','C:\Users','powershell','-NoExit')
Start-Sleep -Seconds 7
Start-Process wt.exe -ArgumentList @('-w',$W,'split-pane','-V','-s','0.4','--title',$MARK,$SUP,'-d','C:\Windows','powershell','-NoExit')
$h = Wait-Panes 2
if ($h -eq [IntPtr]::Zero) { Write-Host "  the probe tab never appeared - cannot run" -ForegroundColor Red; return }
$script:hw = $h
Write-Host "  window $h"

$id1 = Get-WtfActiveTabId -Hwnd $h
Check "a tab has an id"                       ([bool]$id1) "$id1"
Write-Host "    id: $id1"

$stamp = Get-WtfTerminalStamp -Hwnd $h
Check "the terminal can be stamped"           (($stamp.Pid -gt 0) -and ($stamp.Start -gt 0)) "$($stamp.Pid) $($stamp.Start)"

Write-Host ""
Write-Host "=== 2. the id is the same read again, and from another process ===" -ForegroundColor Cyan
Check "same when read twice"                  ((Get-WtfActiveTabId -Hwnd $h) -eq $id1) "$(Get-WtfActiveTabId -Hwnd $h)"

$other = & powershell -NoProfile -ExecutionPolicy Bypass -Command ". '$PSScriptRoot\..\wtf.ps1'; [void](Initialize-WtfInterop); Get-WtfActiveTabId -Hwnd ([IntPtr]$([int]$h))"
Check "same from a separate process"          (("$other".Trim()) -eq $id1) "$other"

Write-Host ""
Write-Host "=== 3. write a binding and read it back ===" -ForegroundColor Cyan
$panes = @(@{ id = 1; dir = 'C:\Users'; command = ''; run = $true },
           @{ id = 2; dir = 'C:\Windows'; command = ''; run = $true })
$obj = New-WtfLayoutObject -Name $LAY -Panes $panes `
        -Tree @{kind='split';dir='V';size=0.4;a=@{kind='leaf';index=1};b=@{kind='leaf';index=2}} `
        -Description 'tab id test'
[void](Write-WtfLayout -Name $LAY -Layout $obj)

Check "the binding is written"                (Set-WtfTabBinding -Hwnd $h -Name $LAY) ''
Check "and read back"                         ((Get-WtfBoundLayout -Hwnd $h) -eq $LAY) "$(Get-WtfBoundLayout -Hwnd $h)"

Write-Host ""
Write-Host "=== 4. the binding survives a pane added BY HAND ===" -ForegroundColor Cyan
Write-Host "    (the pane renames itself, the way an agent CLI does)"
Start-Process wt.exe -ArgumentList @('-w',$W,'split-pane','-H','-s','0.5','-d','C:\Users\jay','powershell','-NoExit','-Command','$host.ui.RawUI.WindowTitle = "AGENT-something"')
$h = Wait-Panes 3
Check "a third pane is there"                 ($h -ne [IntPtr]::Zero) ''

$cap = Get-WtfCaptureFromWindow -Hwnd $h
Write-Host "    tab title now: '$($cap.TabName)'"
Check "the TITLE no longer names the layout"  ((Find-WtfLayoutName -Name $cap.TabName) -ne $LAY) "$($cap.TabName)"
Check "the id is unchanged"                   ((Get-WtfActiveTabId -Hwnd $h) -eq $id1) "$(Get-WtfActiveTabId -Hwnd $h)"
Check "the binding still answers"             ((Get-WtfBoundLayout -Hwnd $h) -eq $LAY) "$(Get-WtfBoundLayout -Hwnd $h)"
Check "the capture carries the id"            ($cap.TabId -eq $id1) "$($cap.TabId)"

Write-Host ""
Write-Host "=== 5. a second tab is a different tab ===" -ForegroundColor Cyan
Start-Process wt.exe -ArgumentList @('-w',$W,'new-tab','--title',"$MARK-2",$SUP,'-d','C:\Windows','powershell','-NoExit')
Start-Sleep -Seconds 7
$id2 = Get-WtfActiveTabId -Hwnd $h
Check "the new tab has its own id"            ($id2 -and $id2 -ne $id1) "$id2"
Check "and no binding of its own"             ((Get-WtfBoundLayout -Hwnd $h) -eq '') "$(Get-WtfBoundLayout -Hwnd $h)"

Start-Process wt.exe -ArgumentList @('-w',$W,'focus-tab','--target','0')
Start-Sleep -Seconds 4
Check "back on tab 1, the id returns"         ((Get-WtfActiveTabId -Hwnd $h) -eq $id1) "$(Get-WtfActiveTabId -Hwnd $h)"
Check "and the binding returns with it"       ((Get-WtfBoundLayout -Hwnd $h) -eq $LAY) "$(Get-WtfBoundLayout -Hwnd $h)"

Write-Host ""
Write-Host "=== 6. stale notes are never trusted ===" -ForegroundColor Cyan
$all = Read-WtfTabBindings
Check "the note is on disk"                   ($all.ContainsKey($id1)) ''

# same id, but claimed to come from a terminal that started at a different time
$all[$id1] = @{ layout = $LAY; wtPid = $all[$id1].wtPid; wtStart = 12345678 }
Write-WtfTabBindings -Bindings $all
Check "a restarted terminal voids the note"   ((Get-WtfBoundLayout -Hwnd $h) -eq '') "$(Get-WtfBoundLayout -Hwnd $h)"

# a process that is not running at all
$all[$id1] = @{ layout = $LAY; wtPid = 999999; wtStart = 12345678 }
Write-WtfTabBindings -Bindings $all
Check "a dead terminal voids the note"        ((Get-WtfBoundLayout -Hwnd $h) -eq '') ''
Check "and the dead note is swept up"         (-not (Remove-WtfDeadBindings -Bindings (Read-WtfTabBindings)).ContainsKey($id1)) ''

[void](Set-WtfTabBinding -Hwnd $h -Name $LAY)
Check "re-binding repairs it"                 ((Get-WtfBoundLayout -Hwnd $h) -eq $LAY) ''

Write-Host ""
Write-Host ""
Write-Host "=== 6b. a note written on one host reads on the other ===" -ForegroundColor Cyan
$otherHost = 'powershell'
if ($PSVersionTable.PSVersion.Major -lt 6) { $otherHost = 'pwsh' }
$readBack = & $otherHost -NoProfile -ExecutionPolicy Bypass -Command ". '$PSScriptRoot\..\wtf.ps1'; [void](Initialize-WtfInterop); Get-WtfBoundLayout -Hwnd ([IntPtr]$([int]$h))"
Check "$otherHost reads the same note"          (("$readBack".Trim()) -eq $LAY) "$readBack"

Write-Host "=== 7. a deleted layout takes its note with it ===" -ForegroundColor Cyan
Remove-Item -LiteralPath (Get-WtfLayoutPath -Name $LAY) -Force
Remove-WtfTabBinding -Name $LAY
Check "the note is gone"                      (-not (Read-WtfTabBindings).ContainsKey($id1)) ''
Check "and nothing is bound"                  ((Get-WtfBoundLayout -Hwnd $h) -eq '') ''

# ---- put things back --------------------------------------------------------
if ($null -ne $bindBackup) {
    Set-Content -LiteralPath $script:WtfBindFile -Value $bindBackup -Encoding UTF8
} elseif (Test-Path -LiteralPath $script:WtfBindFile) {
    Remove-Item -LiteralPath $script:WtfBindFile -Force
}

Write-Host ""
Write-Host "  closing the throwaway window..."
$el = [System.Windows.Automation.AutomationElement]::FromHandle($h)
$tc = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::TabItem)
for ($round = 0; $round -lt 8; $round++) {
    if ((Probe) -eq [IntPtr]::Zero) { break }
    $el = [System.Windows.Automation.AutomationElement]::FromHandle((Probe))
    $tabs = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tc)
    if ($tabs.Count -eq 0) { break }
    $bc = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
    $btns = $tabs.Item(0).FindAll([System.Windows.Automation.TreeScope]::Descendants, $bc)
    $ok = $false
    for ($i = 0; $i -lt $btns.Count; $i++) {
        try { $btns.Item($i).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); $ok = $true; break } catch { }
    }
    if (-not $ok) { break }
    Start-Sleep -Milliseconds 1300
}

Write-Host ""
if ($fail -eq 0) { Write-Host "ALL TESTS PASSED ($pass)" -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED, $pass passed" -ForegroundColor Red; exit 1 }
