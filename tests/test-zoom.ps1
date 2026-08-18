# Zoom: is it measured when a tab is saved, and put back when it is rebuilt?
#
# Zoom in Windows Terminal is the font size of ONE pane, not of the tab. It
# cannot be set through wt.exe - `--fontSize` is accepted by the command line
# parser and then ignored - so the restore sends the same CTRL+MINUS the user
# would press, after checking the terminal is still the window in front.
#
# Uses throwaway windows only, and it does send keystrokes, so do not type while
# it runs.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-zoom.ps1
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\..\wtf.ps1"
[void](Initialize-WtfInterop)
Add-Type -AssemblyName System.Windows.Forms

$pass = 0; $fail = 0
function Check([string]$what, [bool]$ok, [string]$got = '') {
    if ($ok) { $script:pass++; Write-Host "  OK   $what" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  FAIL $what   got: $got" -ForegroundColor Red }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WtfZoomTest {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
}
'@ -ErrorAction SilentlyContinue

$LAY  = 'zz-zoom-test'
$SUP  = '--suppressApplicationTitle'
$before = @(Get-WtfTerminalWindows)
$bindBackup = $null
if (Test-Path -LiteralPath $script:WtfBindFile) {
    $bindBackup = Get-Content -LiteralPath $script:WtfBindFile -Raw -Encoding UTF8
}
function NewWindow { foreach ($h in (Get-WtfTerminalWindows)) { if ($before -notcontains $h) { return $h } }; return [IntPtr]::Zero }

Write-Host "=== 1. build a 2-pane tab and zoom ONE of them out by hand ===" -ForegroundColor Cyan
Start-Process wt.exe -ArgumentList @('-w','zzz','new-tab','--title','ZZZOOMSRC',$SUP,'-d','C:\Users','powershell','-NoExit')
Start-Sleep -Seconds 8
Start-Process wt.exe -ArgumentList @('-w','zzz','split-pane','-V','-s','0.5','--title','ZZZOOMSRC',$SUP,'-d','C:\Windows','powershell','-NoExit')
Start-Sleep -Seconds 6

$src = NewWindow
if ($src -eq [IntPtr]::Zero) { Write-Host "  no window - cannot run" -ForegroundColor Red; return }

$base = @(Get-WtfPaneCells -Hwnd $src)
Check "both panes measure the same to start" ($base.Count -eq 2 -and $base[0] -eq $base[1]) "$($base -join ', ')"
Write-Host "    row height before: $($base -join ', ') px"

[void][WtfZoomTest]::ShowWindow($src, 9)
[void][WtfZoomTest]::SetForegroundWindow($src)
Start-Sleep -Milliseconds 900
for ($i = 0; $i -lt 4; $i++) { [System.Windows.Forms.SendKeys]::SendWait('^{SUBTRACT}'); Start-Sleep -Milliseconds 350 }
Start-Sleep -Seconds 2

$zoomed = @(Get-WtfPaneCells -Hwnd $src)
Write-Host "    row height after 4x CTRL+MINUS: $($zoomed -join ', ') px"
Check "one pane got smaller"                 ($zoomed[1] -lt $base[1] - 1) "$($zoomed[1])"
Check "the other pane was left alone"        ([Math]::Abs($zoomed[0] - $base[0]) -le 0.5) "$($zoomed[0])"

Write-Host ""
Write-Host "=== 2. capture it - is the zoom recorded? ===" -ForegroundColor Cyan
$cap = Get-WtfCaptureFromWindow -Hwnd $src
Check "every pane has a row height"          ((@($cap.Panes | Where-Object { $_.cell -gt 0 }).Count) -eq @($cap.Panes).Count) ''
$cells = @($cap.Panes | ForEach-Object { $_.cell })
Write-Host "    captured: $($cells -join ', ') px"
Check "the two panes differ in the capture"  ([Math]::Abs($cells[0] - $cells[1]) -gt 1) "$($cells -join ', ')"

$panes = @()
foreach ($p in $cap.Panes) { $panes += @{ id = $p.id; dir = $p.dir; command = ''; run = $true; cell = $p.cell } }
$obj = New-WtfLayoutObject -Name $LAY -Panes $panes -Tree $cap.Tree -Description 'zoom test'
[void](Write-WtfLayout -Name $LAY -Layout $obj)

$back = Read-WtfLayout -Name $LAY
Check "the zoom survives a JSON round trip"  ([Math]::Abs([double]$back.panes[1].cell - $cells[1]) -le 0.01) "$($back.panes[1].cell)"

Write-Host ""
Write-Host "=== 3. the restore plan carries it ===" -ForegroundColor Cyan
$plan = @(Build-WtfRestorePlan -Layout $back)
$planCells = @($plan | Where-Object { $_.kind -ne 'focus' } | ForEach-Object { $_.cell })
Check "every build step has a row height"    ((@($planCells | Where-Object { $_ -gt 0 }).Count) -eq $planCells.Count) "$($planCells -join ', ')"

Write-Host ""
Write-Host "=== 4. rebuild it - does the zoom come back? ===" -ForegroundColor Cyan
Write-Host "    (this sends keystrokes; do not type)"
$ok = Invoke-WtfLayoutRestore -Name $LAY -Layout $back -WindowTarget 'zzz2'
Check "the restore reported success"         ([bool]$ok) ''

$dst = [IntPtr]::Zero
foreach ($h in (Get-WtfTerminalWindows)) { if (($before -notcontains $h) -and ($h -ne $src)) { $dst = $h; break } }
Check "a second window appeared"             ($dst -ne [IntPtr]::Zero) ''
if ($dst -ne [IntPtr]::Zero) {
    Start-Sleep -Seconds 2
    $got = @(Get-WtfPaneCells -Hwnd $dst)
    Write-Host "    rebuilt: $($got -join ', ') px   wanted: $($cells -join ', ') px"
    Check "pane 1 is at the saved zoom"      ([Math]::Abs($got[0] - $cells[0]) -le 1.0) "$($got[0])"
    Check "pane 2 is at the saved zoom"      ([Math]::Abs($got[1] - $cells[1]) -le 1.0) "$($got[1])"
}

Write-Host ""
Write-Host "=== 5. a layout with no zoom saved is left alone ===" -ForegroundColor Cyan
$plain = @()
foreach ($p in $cap.Panes) { $plain += @{ id = $p.id; dir = $p.dir; command = ''; run = $true } }
$objP = New-WtfLayoutObject -Name $LAY -Panes $plain -Tree $cap.Tree -Description ''
$planP = @(Build-WtfRestorePlan -Layout $objP)
$sum = 0.0
foreach ($s in $planP) { if ($s.kind -ne 'focus') { $sum += [double]$s.cell } }
Check "an old layout asks for no zoom"       ($sum -eq 0) "$sum"

# ---- clean up ---------------------------------------------------------------
Remove-Item -LiteralPath (Get-WtfLayoutPath -Name $LAY) -Force -ErrorAction SilentlyContinue
if ($null -ne $bindBackup) { Set-Content -LiteralPath $script:WtfBindFile -Value $bindBackup -Encoding UTF8 }
elseif (Test-Path -LiteralPath $script:WtfBindFile) { Remove-Item -LiteralPath $script:WtfBindFile -Force }

Write-Host ""
Write-Host "  closing the throwaway windows..."
$tc = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::TabItem)
$bc = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Button)
for ($r = 0; $r -lt 10; $r++) {
    $t = NewWindow
    if ($t -eq [IntPtr]::Zero) { break }
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($t)
    $tabs = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tc)
    if ($tabs.Count -eq 0) { break }
    $btns = $tabs.Item(0).FindAll([System.Windows.Automation.TreeScope]::Descendants, $bc)
    $done = $false
    for ($i = 0; $i -lt $btns.Count; $i++) {
        try { $btns.Item($i).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); $done = $true; break } catch { }
    }
    if (-not $done) { break }
    Start-Sleep -Milliseconds 1300
}

Write-Host ""
if ($fail -eq 0) { Write-Host "ALL TESTS PASSED ($pass)" -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED, $pass passed" -ForegroundColor Red; exit 1 }
