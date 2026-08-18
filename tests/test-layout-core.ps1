# Unit tests for the layout engine. Touches no terminals.
#
#   powershell -NoProfile -File tests\test-layout-core.ps1
#   pwsh       -NoProfile -File tests\test-layout-core.ps1
# Unit tests for wtf-layout.ps1 that touch NO terminals.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\wtf-layout.ps1"
. "$PSScriptRoot\..\wtf-map.ps1"
. "$PSScriptRoot\..\wtf-tab.ps1"

$fail = 0
function Check { param([string]$What, [bool]$Ok, [string]$Got = '')
    if ($Ok) { Write-Host "  PASS  $What" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $What   got: $Got" -ForegroundColor Red } }

Write-Host ""
Write-Host "=== 1. name validation ===" -ForegroundColor Cyan
$cases = @(
    @{ N='pigeon';                    Ok=$true  },
    @{ N='my long layout name here';  Ok=$true  },
    @{ N='api-v2_final.2';            Ok=$true  },
    @{ N='work/stuff';                Ok=$false },
    @{ N='a:b';                       Ok=$false },
    @{ N='what?';                     Ok=$false },
    @{ N='CON';                       Ok=$false },
    @{ N='com1.json';                 Ok=$false },
    @{ N='trailing.';                 Ok=$false },
    @{ N='';                          Ok=$false },
    @{ N=('x' * 61);                  Ok=$false }
)
foreach ($c in $cases) {
    $r = Test-WtfLayoutName -Name $c.N
    Check "name '$($c.N)' -> $($c.Ok)" ($r.Ok -eq $c.Ok) "$($r.Ok) ($($r.Reason))"
}

Write-Host ""
Write-Host "=== 2. geometry -> tree (your real screenshot-1 rectangles) ===" -ForegroundColor Cyan
$rects = @(
    [pscustomobject]@{ Index=0; X=0;   Y=39;  W=957; H=517 },
    [pscustomobject]@{ Index=1; X=0;   Y=562; W=957; H=516 },
    [pscustomobject]@{ Index=2; X=963; Y=39;  W=957; H=776 },
    [pscustomobject]@{ Index=3; X=963; Y=821; W=957; H=256 }
)
$tree = Build-WtfPaneTree -Items $rects -BX 0 -BY 39 -BW 1920 -BH 1039
Check "root is a V split"        ($tree.kind -eq 'split' -and $tree.dir -eq 'V') "$($tree.dir)"
Check "root size ~= 0.5"         ([Math]::Abs($tree.size - 0.5) -lt 0.01) "$($tree.size)"
Check "left is H split ~= 0.5"   ($tree.a.dir -eq 'H' -and [Math]::Abs($tree.a.size - 0.5) -lt 0.01) "$($tree.a.size)"
Check "right is H split ~= 0.75" ($tree.b.dir -eq 'H' -and [Math]::Abs($tree.b.size - 0.75) -lt 0.01) "$($tree.b.size)"
$order = Get-WtfTreeLeafOrder $tree
Check "leaf order is 0,1,2,3"    ((($order) -join ',') -eq '0,1,2,3') (($order) -join ',')

Write-Host ""
Write-Host "=== 3. restore plan (must match the sequence proven to work) ===" -ForegroundColor Cyan
$layout = @{
    version = 1; name = 'pigeon'; shell = 'powershell'
    panes = @(
        @{ id=1; dir='C:\A'; command='npm run dev' },
        @{ id=2; dir='C:\B'; command='claude --resume aaa' },
        @{ id=3; dir='C:\C'; command='claude --resume bbb' },
        @{ id=4; dir='C:\D'; command='uvicorn app:app' }
    )
    tree = @{ kind='split'; dir='V'; size=0.5
        a = @{ kind='split'; dir='H'; size=0.5;  a=@{kind='leaf';index=1}; b=@{kind='leaf';index=2} }
        b = @{ kind='split'; dir='H'; size=0.75; a=@{kind='leaf';index=3}; b=@{kind='leaf';index=4} } }
}
$plan = Build-WtfRestorePlan -Layout $layout
Write-Host "  plan:" -ForegroundColor DarkGray
foreach ($s in $plan) {
    if ($s.kind -eq 'focus') { Write-Host ("    focus  --target {0}" -f $s.target) -ForegroundColor DarkGray }
    elseif ($s.kind -eq 'new-tab') { Write-Host ("    new-tab            pane {0}  dir={1}  cmd='{2}'" -f $s.paneId,$s.dir,$s.command) -ForegroundColor DarkGray }
    else { Write-Host ("    split {0} -s {1,-6} pane {2}  dir={3}  cmd='{4}'" -f $s.split,$s.size,$s.paneId,$s.dir,$s.command) -ForegroundColor DarkGray }
}
Check "5 steps"                  (@($plan).Count -eq 5) "$(@($plan).Count)"
Check "step1 new-tab pane 1"     ($plan[0].kind -eq 'new-tab' -and $plan[0].paneId -eq 1) "$($plan[0].kind)/$($plan[0].paneId)"
Check "step2 split V 0.5 pane 3" ($plan[1].kind -eq 'split' -and $plan[1].split -eq 'V' -and [Math]::Abs($plan[1].size-0.5) -lt 0.001 -and $plan[1].paneId -eq 3) "$($plan[1].split)/$($plan[1].size)/$($plan[1].paneId)"
Check "step3 split H 0.25 pane 4"($plan[2].kind -eq 'split' -and $plan[2].split -eq 'H' -and [Math]::Abs($plan[2].size-0.25) -lt 0.001 -and $plan[2].paneId -eq 4) "$($plan[2].split)/$($plan[2].size)/$($plan[2].paneId)"
Check "step4 focus target 0"     ($plan[3].kind -eq 'focus' -and $plan[3].target -eq 0) "$($plan[3].kind)/$($plan[3].target)"
Check "step5 split H 0.5 pane 2" ($plan[4].kind -eq 'split' -and $plan[4].split -eq 'H' -and [Math]::Abs($plan[4].size-0.5) -lt 0.001 -and $plan[4].paneId -eq 2) "$($plan[4].split)/$($plan[4].size)/$($plan[4].paneId)"

Write-Host ""
Write-Host "=== 4. launch args encode the directory + command ===" -ForegroundColor Cyan
$a = Get-WtfPaneLaunchArgs -Shell 'powershell' -Dir 'C:\tmp\my proj' -Command "claude --resume x; echo 'hi'"
Check "shell + -NoExit + -EncodedCommand" ($a[0] -eq 'powershell' -and $a[1] -eq '-NoExit' -and $a[2] -eq '-EncodedCommand') ($a -join ' ')
$decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($a[3]))
Check "bakes Set-Location"       ($decoded -match "Set-Location -LiteralPath 'C:\\tmp\\my proj'") $decoded
Check "keeps the semicolon"      ($decoded -match "claude --resume x; echo 'hi'") $decoded

Write-Host ""
Write-Host "=== 5. diff: first capture ===" -ForegroundColor Cyan
$cap = @{ TabName=''; Panes=@(@{id=1;dir='C:\A';dirSource='prompt';command=''}, @{id=2;dir='C:\B';dirSource='prompt';command=''}); Tree=$null }
$d = Compare-WtfLayout -Capture $cap -Saved $null
Check "first capture flagged"    ($d.IsFirst -and $d.NeedsAttention) "$($d.IsFirst)/$($d.NeedsAttention)"
Check "both rows are new"        ((@($d.Rows | Where-Object { $_.status -eq 'new' }).Count) -eq 2) "$(@($d.Rows).Count)"

Write-Host ""
Write-Host "=== 6. diff: pane removed, pane added, directory changed ===" -ForegroundColor Cyan
$saved = @{ panes = @(
    @{ id=1; dir='C:\A'; command='npm run dev' },
    @{ id=2; dir='C:\B'; command='claude --resume aaa' },
    @{ id=3; dir='C:\C'; command='uvicorn app:app' }) }
# now: A unchanged, B's folder moved to a worktree, C gone, a brand new D appeared
$cap2 = @{ TabName='pigeon'; Tree=$null; Panes = @(
    @{ id=1; dir='C:\A';        dirSource='prompt'; command='' },
    @{ id=2; dir='C:\B-work';   dirSource='prompt'; command='' },
    @{ id=3; dir='C:\D';        dirSource='prompt'; command='' }) }
$d2 = Compare-WtfLayout -Capture $cap2 -Saved $saved
foreach ($r in $d2.Rows) { Write-Host ("    pane {0}  {1,-11} {2}   cmd='{3}'" -f $r.id,$r.status,$r.dir,$r.command) -ForegroundColor DarkGray }
foreach ($r in $d2.Removed) { Write-Host ("    pane {0}  removed     {1}   was='{2}'" -f $r.id,$r.dir,$r.command) -ForegroundColor DarkGray }
Check "pane 1 unchanged, command kept" ($d2.Rows[0].status -eq 'same' -and $d2.Rows[0].command -eq 'npm run dev') "$($d2.Rows[0].status)/$($d2.Rows[0].command)"
Check "pane 1 is not asked about"       (-not $d2.Rows[0].mustAsk) "$($d2.Rows[0].mustAsk)"
Check "directory changes are detected"  (@($d2.Rows | Where-Object { $_.status -eq 'dirchanged' }).Count -eq 2) ''
Check "every changed pane is asked"     ((@($d2.Rows | Where-Object { $_.mustAsk }).Count) -eq 2) ''
Check "old folder kept for display"     ($d2.Rows[1].oldDir -eq 'C:\B' -and $d2.Rows[2].oldDir -eq 'C:\C') "$($d2.Rows[1].oldDir)/$($d2.Rows[2].oldDir)"
Check "needs attention"                 ($d2.NeedsAttention) "$($d2.NeedsAttention)"

Write-Host ""
Write-Host "=== 6b. diff: a pane is closed (count drops) ===" -ForegroundColor Cyan
# Your finished-feature case: 3 panes become 2, the survivors keep their commands.
$cap3 = @{ TabName='pigeon'; Tree=$null; Panes = @(
    @{ id=1; dir='C:\A'; dirSource='prompt'; command='' },
    @{ id=2; dir='C:\C'; dirSource='prompt'; command='' }) }
$d3 = Compare-WtfLayout -Capture $cap3 -Saved $saved
foreach ($r in $d3.Rows)    { Write-Host ("    pane {0}  {1,-11} {2}   cmd='{3}'" -f $r.id,$r.status,$r.dir,$r.command) -ForegroundColor DarkGray }
foreach ($r in $d3.Removed) { Write-Host ("    ----     removed     {0}   was='{1}'" -f $r.dir,$r.command) -ForegroundColor DarkGray }
Check "2 rows remain"                   (@($d3.Rows).Count -eq 2) "$(@($d3.Rows).Count)"
Check "the closed pane is reported"     (@($d3.Removed).Count -eq 1 -and $d3.Removed[0].dir -eq 'C:\B') "$(@($d3.Removed).Count)"
Check "survivor A keeps its command"    ($d3.Rows[0].command -eq 'npm run dev') "$($d3.Rows[0].command)"
Check "survivor C keeps its command"    ($d3.Rows[1].command -eq 'uvicorn app:app') "$($d3.Rows[1].command)"
Check "C moved but is not re-asked"     ($d3.Rows[1].status -eq 'moved' -and -not $d3.Rows[1].mustAsk) "$($d3.Rows[1].status)/$($d3.Rows[1].mustAsk)"

Write-Host ""
Write-Host "=== 7. JSON round trip ===" -ForegroundColor Cyan
$obj = New-WtfLayoutObject -Name 'zz-selftest' -Panes $layout.panes -Tree $layout.tree
$p = Write-WtfLayout -Name 'zz-selftest' -Layout $obj
$back = Read-WtfLayout -Name 'zz-selftest'
Check "file written"             (Test-Path -LiteralPath $p) $p
Check "4 panes survive"          (@($back.panes).Count -eq 4) "$(@($back.panes).Count)"
Check "tree survives"            ($back.tree.dir -eq 'V' -and $back.tree.a.dir -eq 'H') "$($back.tree.dir)"
Check "plan from reloaded layout"(@(Build-WtfRestorePlan -Layout $back).Count -eq 5) "$(@(Build-WtfRestorePlan -Layout $back).Count)"
Check "lookup is case-insensitive" ((Find-WtfLayoutName -Name 'ZZ-SELFTEST') -eq 'zz-selftest') (Find-WtfLayoutName -Name 'ZZ-SELFTEST')
Remove-Item -LiteralPath $p -Force


Write-Host ""
Write-Host "=== 8. run flag: does the command execute, or just get typed? ===" -ForegroundColor Cyan
Check "a pane with no run field defaults to running" ((Get-WtfPaneRun @{ id=1; command='x' }) -eq $true) ''
Check "run=false is respected"                      ((Get-WtfPaneRun @{ id=1; command='x'; run=$false }) -eq $false) ''
Check "a missing pane defaults to running"          ((Get-WtfPaneRun $null) -eq $true) ''

$argRun = Get-WtfPaneLaunchArgs -Shell 'powershell' -Dir 'C:\tmp' -Command 'npm run dev' -Run $true
$decRun = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($argRun[3]))
Check "run=true puts the command in as-is"          ($decRun -match '(?m)^npm run dev$') $decRun

$argType = Get-WtfPaneLaunchArgs -Shell 'powershell' -Dir 'C:\tmp' -Command 'claude --resume x' -Run $false
$decType = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($argType[3]))
Check "run=false never runs the command"            ($decType -notmatch '(?m)^claude --resume x$') $decType
Check "run=false types it instead"                  ($decType -match 'Write-WtfPrefill -Command') $decType
Check "run=false still sets the folder"             ($decType -match "Set-Location -LiteralPath 'C:\\tmp'") $decType

$argQuote = Get-WtfPaneLaunchArgs -Shell 'powershell' -Dir 'C:\tmp' -Command "echo 'hi there'" -Run $false
$decQuote = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($argQuote[3]))
Check "quotes inside a typed command survive"       ($decQuote -match "echo ''hi there''") $decQuote

Write-Host ""
Write-Host "=== 9. description and version ===" -ForegroundColor Cyan
$objD = New-WtfLayoutObject -Name 'zz-desc' -Panes @(@{id=1;dir='C:\a';command='';run=$true}) `
                            -Tree @{kind='leaf';index=1} -Description 'what this is for'
Check "layout files are version 2"      ($objD.version -eq 2) "$($objD.version)"
Check "description is stored"           ($objD.description -eq 'what this is for') "$($objD.description)"
[void](Write-WtfLayout -Name 'zz-desc' -Layout $objD)
$backD = Read-WtfLayout -Name 'zz-desc'
Check "description survives a round trip" ($backD.description -eq 'what this is for') "$($backD.description)"
Check "run survives a round trip"         ((Get-WtfPaneRun $backD.panes[0]) -eq $true) ''
Remove-Item -LiteralPath (Get-WtfLayoutPath -Name 'zz-desc') -Force

Write-Host ""
Write-Host "=== 10. the drawing ===" -ForegroundColor Cyan
$drawLayout = @{
    name = 'draw'; description = ''
    panes = @(
        @{id=1;dir='C:\a\alpha';  command='npm run dev';    run=$true},
        @{id=2;dir='C:\a\beta';   command='claude --resume';run=$false},
        @{id=3;dir='C:\a\gamma';  command='';               run=$true}
    )
    tree = @{kind='split';dir='V';size=0.5
             a=@{kind='leaf';index=1}
             b=@{kind='split';dir='H';size=0.5;a=@{kind='leaf';index=2};b=@{kind='leaf';index=3}}}
}
$map = @(Get-WtfLayoutMap -Layout $drawLayout -Width 60)
$plain = (($map -join "`n") -replace "$([char]27)\[[0-9;]*m", '')
Check "the drawing has lines"            ($map.Count -ge 6) "$($map.Count)"
Check "every pane is labelled"           (($plain -match 'pane 1') -and ($plain -match 'pane 2') -and ($plain -match 'pane 3')) ''
Check "folders are shown"                (($plain -match 'alpha') -and ($plain -match 'beta') -and ($plain -match 'gamma')) ''
Check "a running command is marked >"    ($plain -match '> npm run dev') ''
Check "a typed command is marked ~"      ($plain -match '~ claude --resume') ''
Check "an empty pane says so"            ($plain -match '\(no command\)') ''
Check "boxes are drawn"                  ($plain -match [regex]::Escape([string][char]0x250C)) ''
Check "no colour variable leaked"        ($plain -notmatch 'System\.Collections') ''

$hot = (( @(Get-WtfLayoutMap -Layout $drawLayout -Width 60 -Highlight 2) -join "`n") -replace "$([char]27)\[[0-9;]*m", '')
Check "highlight marks the right pane"   ($hot -match '> pane 2 <') ''

Write-Host ""
Write-Host "=== 11. the layout picker frame ===" -ForegroundColor Cyan
$lays = @{ 'one' = $drawLayout; 'two' = $drawLayout }
$frame = @(Get-WtfLayoutPickFrame -Names @('one','two') -Layouts $lays -Selected 1 -LeftWidth 20 -MapWidth 54 -DrawMap)
$fplain = (($frame -join "`n") -replace "$([char]27)\[[0-9;]*m", '')
Check "both names appear"                (($fplain -match 'one') -and ($fplain -match 'two')) ''
Check "the selected one is marked"       ($fplain -match '>\s+two') ''
Check "the drawing sits beside the list" ($fplain -match 'pane 1') ''
Check "the pane count is shown"          ($fplain -match '3 panes') ''
Check "no description says so"           ($fplain -match '\(no description\)') ''

Write-Host ""
if ($fail -eq 0) { Write-Host "ALL TESTS PASSED" -ForegroundColor Green }
else { Write-Host "$fail TEST(S) FAILED" -ForegroundColor Red }
