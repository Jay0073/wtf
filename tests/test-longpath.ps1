# Long paths: git's core.longpaths flag, and the \\?\ delete fallback.
#
# A worktree folder plus node_modules crosses the old 260-character path limit
# easily. git then refuses `worktree remove` with "Filename too long" AFTER it
# has already unregistered the worktree, so the folder is left behind and no
# later git command will touch it.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\wtf.ps1"

$base = Join-Path $env:TEMP ('wtf-lp-' + [System.Diagnostics.Process]::GetCurrentProcess().Id)
if (Test-Path -LiteralPath $base) { [void](Remove-WtfPath -Path $base) }
[void](New-Item -ItemType Directory -Path $base -Force)

$pass = 0; $fail = 0
function Check([string]$what, [bool]$ok) {
    if ($ok) { $script:pass++; Write-Host "  OK   $what" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  FAIL $what" -ForegroundColor Red }
}

Write-Host "=== 1. \\?\ path building ===" -ForegroundColor Cyan
Check "a drive path gets the prefix"  ((Get-WtfExtendedPath 'C:\a\b') -eq '\\?\C:\a\b')
Check "an existing prefix is kept"    ((Get-WtfExtendedPath '\\?\C:\a\b') -eq '\\?\C:\a\b')
Check "a UNC path gets the UNC form"  ((Get-WtfExtendedPath '\\srv\share\x') -eq '\\?\UNC\srv\share\x')

Write-Host "=== 2. deleting a tree past 260 characters ===" -ForegroundColor Cyan
$deep = Join-Path $base 'tree'
$seg  = 'd' * 60
$ext  = '\\?\' + $deep
[void][System.IO.Directory]::CreateDirectory($ext)
for ($i = 0; $i -lt 6; $i++) {
    $ext = $ext + '\' + $seg
    [void][System.IO.Directory]::CreateDirectory($ext)
}
$leaf = $ext + '\' + ('f' * 60) + '.js'
[System.IO.File]::WriteAllText($leaf, 'x')
Write-Host "    deepest path: $($leaf.Length - 4) characters"
Check "the deep file exists"          ([System.IO.File]::Exists($leaf))
Check "it is past the old limit"      (($leaf.Length - 4) -gt 260)

Check "Remove-WtfPath clears it"      (Remove-WtfPath -Path $deep)
Check "nothing is left"               (-not (Test-Path -LiteralPath $deep))

Write-Host "=== 3. read-only files ===" -ForegroundColor Cyan
$ro = Join-Path $base 'ro'
[void](New-Item -ItemType Directory -Path $ro -Force)
$rof = Join-Path $ro 'locked.txt'
[System.IO.File]::WriteAllText($rof, 'x')
[System.IO.File]::SetAttributes($rof, [System.IO.FileAttributes]::ReadOnly)
Check "a read-only file is removed"   (Remove-WtfPath -Path $ro)

Write-Host "=== 4. junctions are unlinked, not followed ===" -ForegroundColor Cyan
$target = Join-Path $base 'real-target'
[void](New-Item -ItemType Directory -Path $target -Force)
[System.IO.File]::WriteAllText((Join-Path $target 'keep.txt'), 'precious')
$holder = Join-Path $base 'holder'
[void](New-Item -ItemType Directory -Path $holder -Force)
$link = Join-Path $holder 'dep'
& cmd /c mklink /J "$link" "$target" | Out-Null
Check "the junction was made"         (Test-WtfIsReparsePoint $link)
Check "the holder is removed"         (Remove-WtfPath -Path $holder)
Check "the junction is gone"          (-not (Test-Path -LiteralPath $link))
Check "the TARGET survived"           (Test-Path -LiteralPath (Join-Path $target 'keep.txt'))

Write-Host "=== 5. safe on a missing path ===" -ForegroundColor Cyan
Check "a missing path reports true"   (Remove-WtfPath -Path (Join-Path $base 'never-existed'))

Write-Host "=== 6. git gets core.longpaths ===" -ForegroundColor Cyan
$src = Join-Path $base 'src'
[void](New-Item -ItemType Directory -Path $src -Force)
[void](Invoke-WtfGit -WorkingDir $src -GitArgs @('init','-q'))
$r = Invoke-WtfGit -WorkingDir $src -GitArgs @('config','--get','core.longpaths')
Check "git sees longpaths turned on"  ($r.Ok -and $r.Stdout -eq 'true')

[void](Remove-WtfPath -Path $base)

Write-Host ""
if ($fail -eq 0) { Write-Host "ALL TESTS PASSED ($pass)" -ForegroundColor Green; exit 0 }
else { Write-Host "$fail FAILED, $pass passed" -ForegroundColor Red; exit 1 }
