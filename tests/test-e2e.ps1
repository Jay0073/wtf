# End-to-end test: build a real tab, capture it, save it, rebuild it in
# another window, compare tree and directories, then diff a changed tab
# against the saved layout.
#
# Uses throwaway terminal windows only - your own windows are not touched.
# It leaves those windows open at the end; close them yourself.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-e2e.ps1
# End-to-end test of the reworked tool, using throwaway windows only.
#   1. build a 4-pane tab (stands in for a real working tab)
#   2. capture it, save it as a layout with commands
#   3. wtf tab ls
#   4. restore it into another window, re-capture, compare
#   5. build a 3-pane tab (a pane was "closed") and diff it against the layout
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\..\wtf.ps1"

function Shape { param($N)
    if (-not $N) { return '' }
    if ($N.kind -eq 'leaf') { return 'L' }
    if ($N.kind -eq 'unresolved') { return 'U' }
    return "($($N.dir):$([Math]::Round([double]$N.size,2)) $(Shape $N.a) $(Shape $N.b))" }

function Wait-Window { param([string]$Title, [int]$Panes, [int]$TimeoutMs = 25000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        Start-Sleep -Milliseconds 300
        foreach ($h in (Get-WtfTerminalWindows)) {
            $t = Get-WtfWindowTabs -Hwnd $h
            if ($t.SelectedName -eq $Title) {
                $p = Get-WtfWindowPanes -Hwnd $h
                if ($p.Count -ge $Panes) { Start-Sleep -Milliseconds 800; return $h }
            }
        }
    }
    return [IntPtr]::Zero }

[void](Initialize-WtfInterop)
$SUP = '--suppressApplicationTitle'
$A=(Join-Path $env:USERPROFILE 'Documents'); $B=(Join-Path $env:USERPROFILE 'Documents'); $C='C:\Users'; $D='C:\Windows'

Write-Host "=== 1. build a 4-pane tab (E2E-SRC) ===" -ForegroundColor Cyan
Start-Process wt.exe -ArgumentList @('-w','e2e1','new-tab','--title','E2E-SRC',$SUP,'-d',$A,'powershell','-NoExit'); Start-Sleep -Seconds 5
Start-Process wt.exe -ArgumentList @('-w','e2e1','split-pane','-V','-s','0.45','--title','E2E-SRC',$SUP,'-d',$C,'powershell','-NoExit'); Start-Sleep -Seconds 4
Start-Process wt.exe -ArgumentList @('-w','e2e1','split-pane','-H','-s','0.3','--title','E2E-SRC',$SUP,'-d',$D,'powershell','-NoExit'); Start-Sleep -Seconds 4
Start-Process wt.exe -ArgumentList @('-w','e2e1','focus-pane','--target','0'); Start-Sleep -Seconds 2
Start-Process wt.exe -ArgumentList @('-w','e2e1','split-pane','-H','-s','0.6','--title','E2E-SRC',$SUP,'-d',$B,'powershell','-NoExit'); Start-Sleep -Seconds 5

$src = Wait-Window -Title 'E2E-SRC' -Panes 4
if ($src -eq [IntPtr]::Zero) { Write-Host "  source tab never appeared" -ForegroundColor Red; return }
Write-Host "  built, hwnd=$src" -ForegroundColor Green

Write-Host ""
Write-Host "=== 2. capture + save as layout 'zz-e2e' ===" -ForegroundColor Cyan
$cap = Get-WtfCaptureFromWindow -Hwnd $src
foreach ($p in $cap.Panes) { Write-Host ("    pane {0}  {1,-34} ({2})" -f $p.id,$p.dir,$p.dirSource) }
$shapeA = Shape $cap.Tree
Write-Host "    shape: $shapeA"
Write-Host "    tab name read back: '$($cap.TabName)'"

$diff = Compare-WtfLayout -Capture $cap -Saved $null
Write-Host "    first capture -> IsFirst=$($diff.IsFirst) NeedsAttention=$($diff.NeedsAttention)"
$panes = @()
foreach ($r in $diff.Rows) { $panes += @{ id=$r.id; dir=$r.dir; command="Write-Host 'pane $($r.id) here'" } }
$obj = New-WtfLayoutObject -Name 'zz-e2e' -Panes $panes -Tree $cap.Tree -Shell 'powershell'
[void](Write-WtfLayout -Name 'zz-e2e' -Layout $obj)
Write-Host "    saved" -ForegroundColor Green

Write-Host ""
Write-Host "=== 3. wtf tab ls ===" -ForegroundColor Cyan
Invoke-WtfTabList

Write-Host ""
Write-Host "=== 4. restore into a second window, re-capture, compare ===" -ForegroundColor Cyan
$layout = Read-WtfLayout -Name 'zz-e2e'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$ok = Invoke-WtfLayoutRestore -Name 'zz-e2e' -Layout $layout -WindowTarget 'e2e2'
$sw.Stop()
Write-Host "    restore=$ok in $($sw.ElapsedMilliseconds) ms"
Start-Sleep -Seconds 3
$dst = Wait-Window -Title 'zz-e2e' -Panes 4
if ($dst -eq [IntPtr]::Zero) { Write-Host "  restored tab not found" -ForegroundColor Red }
else {
    $cap2 = Get-WtfCaptureFromWindow -Hwnd $dst
    foreach ($p in $cap2.Panes) { Write-Host ("    pane {0}  {1,-34} ({2})" -f $p.id,$p.dir,$p.dirSource) }
    $shapeB = Shape $cap2.Tree
    Write-Host "    shape: $shapeB"
    if ($shapeA -eq $shapeB) { Write-Host "    TREE MATCHES" -ForegroundColor Green } else { Write-Host "    TREE DIFFERS" -ForegroundColor Red }
    $d1 = (@($cap.Panes  | ForEach-Object { $_.dir }) -join '|')
    $d2 = (@($cap2.Panes | ForEach-Object { $_.dir }) -join '|')
    if ($d1 -eq $d2) { Write-Host "    DIRECTORIES MATCH" -ForegroundColor Green } else { Write-Host "    DIRECTORIES DIFFER`n      $d1`n      $d2" -ForegroundColor Red }
    Write-Host "    tab kept its name: '$((Get-WtfWindowTabs -Hwnd $dst).SelectedName)'" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== 5. the update case: a pane was closed, another folder changed ===" -ForegroundColor Cyan
# A 3-pane tab stands in for "you closed the finished feature's pane".
Start-Process wt.exe -ArgumentList @('-w','e2e3','new-tab','--title','zz-e2e',$SUP,'-d',$A,'powershell','-NoExit'); Start-Sleep -Seconds 5
Start-Process wt.exe -ArgumentList @('-w','e2e3','split-pane','-V','-s','0.5','--title','zz-e2e',$SUP,'-d',$C,'powershell','-NoExit'); Start-Sleep -Seconds 4
Start-Process wt.exe -ArgumentList @('-w','e2e3','split-pane','-H','-s','0.4','--title','zz-e2e',$SUP,'-d','C:\Windows\System32','powershell','-NoExit'); Start-Sleep -Seconds 5

$upd = $null
foreach ($h in (Get-WtfTerminalWindows)) {
    $t = Get-WtfWindowTabs -Hwnd $h
    $p = Get-WtfWindowPanes -Hwnd $h
    if ($t.SelectedName -eq 'zz-e2e' -and $p.Count -eq 3) { $upd = $h }
}
if (-not $upd) { Write-Host "  3-pane tab not found" -ForegroundColor Red }
else {
    $cap3 = Get-WtfCaptureFromWindow -Hwnd $upd
    Write-Host "    tab name says this is layout: '$($cap3.TabName)'  -> update, not a new layout" -ForegroundColor Green
    $saved = Read-WtfLayout -Name 'zz-e2e'
    $d3 = Compare-WtfLayout -Capture $cap3 -Saved $saved
    Show-WtfLayoutDiff -Diff $d3 -Name 'zz-e2e'
    Write-Host "    NeedsAttention = $($d3.NeedsAttention)  (must be True: a folder changed)"
    Write-Host "    rows asked about = $(@($d3.Rows | Where-Object { $_.mustAsk }).Count)"
    Write-Host "    panes reported closed = $(@($d3.Removed).Count)"
    foreach ($r in $d3.Rows) {
        Write-Host ("      pane {0}  {1,-11} keeps command: '{2}'" -f $r.id, $r.status, $r.command)
    }
}

Remove-Item -LiteralPath (Get-WtfLayoutPath -Name 'zz-e2e') -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "test layout file removed." -ForegroundColor DarkGray
