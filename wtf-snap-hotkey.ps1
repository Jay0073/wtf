# wtf-snap-hotkey.ps1 — what the global hotkey runs.
#
# Pressing the hotkey opens THIS window and captures the terminal tab that was
# in front. That is the whole point of the hotkey: your panes are usually all
# busy (an agent here, a dev server there), so there is often no free shell to
# type `wtf snap` into. Nothing is typed into any of your panes.
#
# This window is where the snapshot asks its questions, so it stays open until
# you press a key.

$ErrorActionPreference = 'Continue'

try {
    $Host.UI.RawUI.WindowTitle = 'wtf snap'
} catch { }

$wtf = Join-Path $env:USERPROFILE '.wtf\wtf.ps1'
if (-not (Test-Path $wtf)) {
    Write-Host "wtf is not installed at $wtf" -ForegroundColor Red
    Start-Sleep -Seconds 4
    exit 1
}
. $wtf

try {
    Invoke-WtfSnap -Foreground
} catch {
    Write-Host ""
    Write-Host "  snap failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  press any key to close" -ForegroundColor DarkGray
try { [void][Console]::ReadKey($true) } catch { Start-Sleep -Seconds 3 }
