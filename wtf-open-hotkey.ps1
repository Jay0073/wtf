# wtf-open-hotkey.ps1 — what the "open a layout" hotkey runs.
#
# Pressing the hotkey opens THIS window, shows the list of saved layouts, and
# rebuilds the one you pick as a new tab in your terminal. Picking from a list
# is the point: after a few weeks away from a feature you will not remember what
# you called its layout.
#
# This window is only the chooser. It closes itself once the tab is on screen.

$ErrorActionPreference = 'Continue'

try {
    $Host.UI.RawUI.WindowTitle = 'wtf tab open'
} catch { }

$wtf = Join-Path $env:USERPROFILE '.wtf\wtf.ps1'
if (-not (Test-Path $wtf)) {
    Write-Host "wtf is not installed at $wtf" -ForegroundColor Red
    Start-Sleep -Seconds 4
    exit 1
}
. $wtf

try {
    Invoke-WtfTabOpen
} catch {
    Write-Host ""
    Write-Host "  open failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  press any key to close" -ForegroundColor DarkGray
    try { [void][Console]::ReadKey($true) } catch { Start-Sleep -Seconds 3 }
    exit 1
}

# Nothing to read here once the tab exists, so get out of the way.
Start-Sleep -Milliseconds 900
