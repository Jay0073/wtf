# wtf.ps1 — WorkTree Flow orchestrator (Part 1: Foundation)
# Requires: Windows PowerShell 5.1 or PowerShell 7+, Windows Terminal, Git 2.5+
#
# Install:
#   1. Create folder: C:\Users\<you>\.wtf\
#   2. Put config.json inside it
#   3. Dot-source from your $PROFILE:
#        . "$env:USERPROFILE\.wtf\wtf.ps1"
#   4. Reload: . $PROFILE
#
# NOTE: this file MUST stay UTF-8 WITH BOM. Without it, Windows PowerShell
# 5.1 reads it in the ANSI codepage and every box glyph and emoji breaks.

# Runs on Windows PowerShell 5.1 and PowerShell 7+.

# ============================================================================
# GLOBAL STATE
# ============================================================================

$script:WtfRoot    = Join-Path $env:USERPROFILE ".wtf"
$script:WtfConfig  = Join-Path $script:WtfRoot "config.json"
$script:WtfLogDir  = Join-Path $script:WtfRoot "logs"
$script:WtfLogFile = $null

# Render Unicode (spinner ⠋, arrows →, box chars, ✓) correctly. Without this,
# a legacy-codepage console prints those glyphs as "?".
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding           = [System.Text.UTF8Encoding]::new($false)
} catch { }

# Theme — using ANSI/VT escapes directly for fine-grained control.
# PS7's $PSStyle is great but we want consistency across all output.
$script:T = @{
    # Foregrounds
    Prompt   = "$([char]27)[38;5;81m"     # cyan-ish
    Ok       = "$([char]27)[38;5;42m"     # green
    Warn     = "$([char]27)[38;5;215m"    # amber
    Fail     = "$([char]27)[38;5;203m"    # red
    Detail   = "$([char]27)[38;5;245m"    # muted gray
    Header   = "$([char]27)[38;5;141m"    # purple
    Accent   = "$([char]27)[38;5;111m"    # soft blue
    Dim      = "$([char]27)[2m"
    Bold     = "$([char]27)[1m"
    Italic   = "$([char]27)[3m"
    Underline= "$([char]27)[4m"
    Reset    = "$([char]27)[0m"
    # Premium-TUI extras: a faint selection backdrop + a bright rail for the
    # active row. Used by the upgraded pickers; nothing else depends on them.
    SelBg    = "$([char]27)[48;5;236m"    # subtle dark-gray row highlight
    Rail     = "$([char]27)[38;5;212m"    # pink-ish accent rail (▌) on the active row
    Faint    = "$([char]27)[38;5;240m"    # fainter than Detail, for glyph rails / hints
    # Cursor / line control
    HideCur  = "$([char]27)[?25l"
    ShowCur  = "$([char]27)[?25h"
    ClearLn  = "$([char]27)[2K`r"
    Up       = "$([char]27)[1A"
}

# A git worktree only checks out TRACKED files, so gitignored-but-useful things
# (.env, graphify-out/, local config, certs, data) don't come along. wtf copies
# them from main so the worktree behaves like main — EXCEPT these heavy /
# regenerable trees, which you rebuild (npm i, etc.) rather than copy.
# Override per machine by setting a top-level "copySkip" array in config.json.
$script:WtfCopySkipDefault = @(
    'node_modules','.git','.venv','venv','env','__pycache__','.mypy_cache',
    '.pytest_cache','.ruff_cache','dist','build','out','.next','.nuxt','.turbo',
    '.svelte-kit','.angular','.parcel-cache','coverage','.nyc_output','target',
    'vendor','bin','obj','.gradle','.dart_tool','Pods','DerivedData','.terraform'
)

# ============================================================================
# ENCODING: UTF-8 WITHOUT BOM
# ============================================================================
# PS7's Out-File defaults to UTF-8 no-BOM already, but [System.IO.File] is
# explicit and faster. We use these everywhere for consistency + speed.

function Write-WtfFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $enc = [System.Text.UTF8Encoding]::new($false)  # no BOM
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Write-WtfJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object,
        [int]$Depth = 10
    )
    Write-WtfFile -Path $Path -Content ($Object | ConvertTo-Json -Depth $Depth)
}

function Read-WtfJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

# ============================================================================
# PSCUSTOMOBJECT HELPERS
# ============================================================================
# ConvertFrom-Json returns PSCustomObject. Hashtable methods don't apply.
# Use -AsHashtable on PS7+ when you want a hashtable, but for nested config
# we keep it as PSCustomObject and use these helpers.

function Get-ObjectKeys {
    param([Parameter(Mandatory)]$Object)
    if ($null -eq $Object) { return @() }
    if ($Object -is [hashtable]) { return @($Object.Keys) }
    return @($Object.PSObject.Properties.Name)
}

function Test-ObjectHasKey {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Key
    )
    if ($null -eq $Object) { return $false }
    if ($Object -is [hashtable]) { return $Object.ContainsKey($Key) }
    return $null -ne $Object.PSObject.Properties[$Key]
}

function Get-ObjectValue {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Key
    )
    if ($null -eq $Object) { return $null }
    if ($Object -is [hashtable]) { return $Object[$Key] }
    return $Object.$Key
}

# ============================================================================
# LOGGING
# ============================================================================

function Start-WtfLog {
    param([Parameter(Mandatory)][string]$Command)
    if (-not (Test-Path $script:WtfLogDir)) {
        New-Item -ItemType Directory -Path $script:WtfLogDir -Force | Out-Null
    }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $script:WtfLogFile = Join-Path $script:WtfLogDir "$stamp-$Command.log"
    Write-WtfFile -Path $script:WtfLogFile -Content "[wtf $Command] started $(Get-Date -Format o)`n"
}

function Write-WtfLog {
    param([Parameter(Mandatory)][string]$Message)
    if ($null -eq $script:WtfLogFile) { return }
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $Message`n"
    [System.IO.File]::AppendAllText($script:WtfLogFile, $line, [System.Text.UTF8Encoding]::new($false))
}

# ============================================================================
# OUTPUT — RAW VT ESCAPES (faster, prettier, more control than Write-Host)
# ============================================================================

function _wtf_write {
    param([string]$Text, [string]$Color = '')
    $out = if ($Color) { "$Color$Text$($script:T.Reset)" } else { $Text }
    [Console]::Out.WriteLine($out)
}

function Write-WtfBanner {
    # Big startup banner used by interactive entry
    param([string]$Subtitle = '')
    $T = $script:T
    $line1 = "$($T.Header)$($T.Bold)"
    $line1 += @"
 _    _  _____________  _____ 
| |  | ||_____   _____||  ___|
| |/\| |      | |      | |
|  /\  |      | |      |  _|
 \/  \/       |_|      |_|
"@
    $line1 += $T.Reset
    [Console]::Out.WriteLine($line1)
    if ($Subtitle) {
        _wtf_write "  $Subtitle" "$($T.Detail)$($T.Italic)"
    }
    [Console]::Out.WriteLine()
}

function Write-WtfHeader {
    param([Parameter(Mandatory)][string]$Text)
    $T = $script:T
    $total = 66
    $used  = 3 + $Text.Length + 1            # "▌ " + glyph spacing + trailing space
    $bar = "─" * [Math]::Max(0, $total - $used)
    [Console]::Out.WriteLine()
    # A bright rail + bold title + a faint rule trailing off — reads as a clean
    # section divider consistent with the pickers/board.
    [Console]::Out.WriteLine("$($T.Rail)▌$($T.Reset) $($T.Header)$($T.Bold)$Text$($T.Reset) $($T.Faint)$bar$($T.Reset)")
    Write-WtfLog "PHASE: $Text"
}

function Write-WtfOk     { param([string]$M) _wtf_write "  ✓ $M" $script:T.Ok;     Write-WtfLog "OK: $M" }
function Write-WtfWarn   { param([string]$M) _wtf_write "  ⚠ $M" $script:T.Warn;   Write-WtfLog "WARN: $M" }
function Write-WtfFail   { param([string]$M) _wtf_write "  ✗ $M" $script:T.Fail;   Write-WtfLog "FAIL: $M" }
function Write-WtfDetail { param([string]$M) _wtf_write "    $M" $script:T.Detail; Write-WtfLog "DETAIL: $M" }
function Write-WtfStep   { param([string]$M) _wtf_write "  → $M" $script:T.Accent; Write-WtfLog "STEP: $M" }
function Write-WtfInfo   { param([string]$M) _wtf_write "  · $M" $script:T.Prompt; Write-WtfLog "INFO: $M" }

function _wtf_visible_len {
    # Character length of a string with ANSI escapes stripped.
    param([string]$S)
    return ($S -replace ([char]27 + '\[[\d;]*m'), '').Length
}

function _wtf_fit_ansi {
    <#
    .SYNOPSIS
        Truncate a (possibly ANSI-colored) string so its VISIBLE length is <= $Max,
        appending an ellipsis. ANSI escapes don't count toward the width and are
        preserved up to the cut. Prevents box borders from overflowing.
    #>
    param([string]$S, [int]$Max)
    if ((_wtf_visible_len $S) -le $Max) { return $S }
    if ($Max -le 1) { return '…' }
    $out = ''; $vis = 0; $i = 0
    while ($i -lt $S.Length -and $vis -lt ($Max - 1)) {
        if ($S[$i] -eq [char]27) {
            # copy the whole escape sequence (ESC [ ... m) without counting it
            $j = $i
            while ($j -lt $S.Length -and $S[$j] -ne 'm') { $out += $S[$j]; $j++ }
            if ($j -lt $S.Length) { $out += $S[$j] }   # the 'm'
            $i = $j + 1
        } else {
            $out += $S[$i]; $vis++; $i++
        }
    }
    return $out + "$($script:T.Reset)…"
}

function Write-WtfSummary {
    # Bordered summary block for end-of-command recap. Long lines are truncated
    # to fit so the rounded border never breaks.
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [string]$Color = ''
    )
    $T = $script:T
    if (-not $Color) { $Color = $T.Ok }
    $width = 66
    $inner = $width - 4                     # printable cells between "│ " and " │"
    $top    = "╭" + ("─" * ($width - 2)) + "╮"
    $bot    = "╰" + ("─" * ($width - 2)) + "╯"
    $blank  = "│" + (" " * ($width - 2)) + "│"
    [Console]::Out.WriteLine()
    _wtf_write $top $Color

    $tFit = _wtf_fit_ansi ($T.Bold + $Title + $T.Reset) $inner
    $tPad = $inner - (_wtf_visible_len $tFit)
    _wtf_write ("│ " + $tFit + $Color + (" " * [Math]::Max(0,$tPad)) + " │") $Color
    _wtf_write $blank $Color

    foreach ($l in $Lines) {
        $fit = _wtf_fit_ansi $l $inner
        $pad = $inner - (_wtf_visible_len $fit)
        _wtf_write ("│ " + $fit + $Color + (" " * [Math]::Max(0,$pad)) + " │") $Color
    }
    _wtf_write $bot $Color
    [Console]::Out.WriteLine()
}

# ============================================================================
# SPINNER — runs async work with live status, multi-line aware
# ============================================================================

function Invoke-WtfWithSpinner {
    <#
    .SYNOPSIS
        Run a scriptblock while showing a braille spinner. Returns the result.
    .OUTPUTS
        @{ Ok = bool; Output = any; Error = ErrorRecord }
    #>
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $T = $script:T
    $frames = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
    $job = Start-Job -ScriptBlock $Action
    $i = 0
    [Console]::Out.Write($T.HideCur)
    try {
        while ($job.State -eq 'Running') {
            $frame = $frames[$i % $frames.Length]
            [Console]::Out.Write("$($T.ClearLn)  $($T.Accent)$frame$($T.Reset) $Label")
            Start-Sleep -Milliseconds 75
            $i++
        }
        $output = Receive-Job -Job $job -Wait -ErrorAction SilentlyContinue
        $state  = $job.State
        $err    = if ($state -eq 'Failed') { $job.ChildJobs[0].JobStateInfo.Reason } else { $null }
        Remove-Job -Job $job -Force
        [Console]::Out.Write("$($T.ClearLn)")
        return @{ Ok = ($state -eq 'Completed'); Output = $output; Error = $err }
    }
    finally {
        [Console]::Out.Write($T.ShowCur)
    }
}

# ============================================================================
# INTERACTIVE PROMPTS
# ============================================================================
# All use raw [Console]::ReadKey, VT escapes, and live cursor positioning.
# No PSReadLine dependency — works in any terminal that handles VT.

function _wtf_render_clear {
    <#
    .SYNOPSIS
        Rewind over $Lines already-drawn rows so the next draw overwrites them.
    .DESCRIPTION
        Counting rows is not enough on its own: a row wider than the pane wraps
        onto a second PHYSICAL line, so moving up once per row leaves the extra
        line on screen and the list grows with every keypress. After rewinding we
        therefore clear everything from the cursor to the end of the screen
        (ESC[0J), which removes any such leftovers. Rows are also truncated to
        the pane width by _wtf_pick_row, so wrapping should not happen at all.
    #>
    param([int]$Lines)
    if ($Lines -le 0) { return }
    for ($i = 0; $i -lt $Lines; $i++) {
        [Console]::Out.Write("$($script:T.Up)$($script:T.ClearLn)")
    }
    [Console]::Out.Write("$([char]27)[0J")
}

function _wtf_term_width {
    # Usable width for one row. Falls back to 100 when there is no real console
    # (piped output, a hook), and always leaves one column spare so a full-width
    # row cannot trigger the terminal's own line wrap.
    try {
        $w = [Console]::WindowWidth
        if ($w -gt 20) { return $w - 1 }
    } catch { }
    return 100
}

# Premium picker primitives — a left accent rail + subtle row highlight give the
# menus a TUI feel (Gemini/antigravity-ish) without any new dependency. Every
# picker reuses these so the look stays consistent.
function _wtf_pick_header {
    param([string]$Prompt, [string]$Hint)
    $T = $script:T
    $hint = if ($Hint) { "  $($T.Faint)$Hint$($T.Reset)" } else { '' }
    $line = "$($T.Accent)❯$($T.Reset) $($T.Bold)$Prompt$($T.Reset)$hint"
    [Console]::Out.WriteLine((_wtf_fit_ansi $line (_wtf_term_width)))
}

function _wtf_pick_row {
    <#
    .SYNOPSIS
        Render one menu row. Active row gets a bright rail (▌), a faint
        background, and bold text; inactive rows are quiet. $Glyph is an
        optional leading marker (e.g. ● / ○ for multi-select).
    #>
    param(
        [string]$Text,
        [bool]$Active,
        [string]$Desc = '',
        [string]$Glyph = ''
    )
    $T = $script:T
    $g = if ($Glyph) { "$Glyph " } else { '' }
    $w = _wtf_term_width
    if ($Active) {
        $rail = "$($T.Rail)▌$($T.Reset)"
        $body = "$($T.SelBg)$($T.Bold)$g$Text$($T.Reset)"
        $d    = if ($Desc) { "$($T.SelBg)$($T.Detail)  $Desc$($T.Reset)" } else { '' }
        [Console]::Out.WriteLine((_wtf_fit_ansi "$rail $body$d" $w))
    } else {
        $body = "$($T.Detail)$g$Text$($T.Reset)"
        $d    = if ($Desc) { "$($T.Faint)  $Desc$($T.Reset)" } else { '' }
        [Console]::Out.WriteLine((_wtf_fit_ansi "  $body$d" $w))
    }
}

function _wtf_pick_confirm {
    # The single-line recap printed once a choice is committed.
    param([string]$Prompt, [string]$Value, [string]$Color = '')
    $T = $script:T
    if (-not $Color) { $Color = $T.Ok }
    _wtf_write "$($T.Accent)❯$($T.Reset) $Prompt  $Color$Value$($T.Reset)"
}

function Read-WtfChoice {
    <#
    .SYNOPSIS
        Arrow-key single-select picker. Returns selected option or $null on Escape.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$Options,
        [int]$Default = 0,
        [string[]]$Descriptions = $null
    )
    if ($Options.Count -eq 0) { return $null }
    if ($Options.Count -eq 1) {
        _wtf_pick_confirm $Prompt "$($Options[0])  $($script:T.Detail)(only option)$($script:T.Reset)"
        return $Options[0]
    }

    $T = $script:T
    $sel = [Math]::Max(0, [Math]::Min($Default, $Options.Count - 1))
    $rendered = 0

    [Console]::Out.Write($T.HideCur)
    try {
        while ($true) {
            _wtf_render_clear $rendered
            _wtf_pick_header $Prompt "↑↓ move · enter select"
            for ($i = 0; $i -lt $Options.Count; $i++) {
                $desc = if ($Descriptions -and $i -lt $Descriptions.Count) { $Descriptions[$i] } else { '' }
                _wtf_pick_row -Text $Options[$i] -Active ($i -eq $sel) -Desc $desc
            }
            $rendered = $Options.Count + 1

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { $sel = ($sel - 1 + $Options.Count) % $Options.Count }
                'DownArrow' { $sel = ($sel + 1) % $Options.Count }
                'Home'      { $sel = 0 }
                'End'       { $sel = $Options.Count - 1 }
                'Enter' {
                    _wtf_render_clear $rendered
                    _wtf_pick_confirm $Prompt $Options[$sel]
                    return $Options[$sel]
                }
                'Escape' {
                    _wtf_render_clear $rendered
                    _wtf_pick_confirm $Prompt 'cancelled' $T.Fail
                    return $null
                }
            }
        }
    }
    finally {
        [Console]::Out.Write($T.ShowCur)
    }
}

function Read-WtfMultiChoice {
    <#
    .SYNOPSIS
        Multi-select with space=toggle, a=all, n=none, enter=confirm, esc=cancel.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$Options,
        [string[]]$Preselected = @(),
        [string[]]$Descriptions = $null,
        [int]$Min = 1
    )
    if ($Options.Count -eq 0) { return @() }

    $T = $script:T
    $selected = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($p in $Preselected) { [void]$selected.Add($p) }
    $cursor = 0
    $rendered = 0
    $errorMsg = ''

    [Console]::Out.Write($T.HideCur)
    try {
        while ($true) {
            _wtf_render_clear $rendered
            _wtf_pick_header $Prompt "space toggle · a all · n none · enter confirm"
            for ($i = 0; $i -lt $Options.Count; $i++) {
                $opt   = $Options[$i]
                $on    = $selected.Contains($opt)
                $mark  = if ($on) { "$($T.Ok)●$($T.Reset)" } else { "$($T.Faint)○$($T.Reset)" }
                $desc  = if ($Descriptions -and $i -lt $Descriptions.Count) { $Descriptions[$i] } else { '' }
                _wtf_pick_row -Text $opt -Active ($i -eq $cursor) -Desc $desc -Glyph $mark
            }
            if ($errorMsg) {
                [Console]::Out.WriteLine("  $($T.Fail)$errorMsg$($T.Reset)")
                $rendered = $Options.Count + 2
                $errorMsg = ''
            } else {
                $rendered = $Options.Count + 1
            }

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { $cursor = ($cursor - 1 + $Options.Count) % $Options.Count }
                'DownArrow' { $cursor = ($cursor + 1) % $Options.Count }
                'Home'      { $cursor = 0 }
                'End'       { $cursor = $Options.Count - 1 }
                'Spacebar' {
                    if ($selected.Contains($Options[$cursor])) {
                        [void]$selected.Remove($Options[$cursor])
                    } else {
                        [void]$selected.Add($Options[$cursor])
                    }
                }
                'Enter' {
                    if ($selected.Count -lt $Min) {
                        $errorMsg = "Select at least $Min."
                        continue
                    }
                    _wtf_render_clear $rendered
                    # Preserve original order
                    $result = @($Options | Where-Object { $selected.Contains($_) })
                    $shown = if ($result.Count -gt 4) { ($result[0..3] -join ', ') + " (+$($result.Count - 4) more)" } else { $result -join ', ' }
                    _wtf_pick_confirm $Prompt $shown
                    return $result
                }
                'Escape' {
                    _wtf_render_clear $rendered
                    _wtf_pick_confirm $Prompt 'cancelled' $T.Fail
                    return @()
                }
            }
            switch ($key.KeyChar) {
                'a' { foreach ($o in $Options) { [void]$selected.Add($o) } }
                'A' { foreach ($o in $Options) { [void]$selected.Add($o) } }
                'n' { $selected.Clear() }
                'N' { $selected.Clear() }
            }
        }
    }
    finally {
        [Console]::Out.Write($T.ShowCur)
    }
}

function Read-WtfText {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default = '',
        [scriptblock]$Validator = $null,
        [string]$Hint = ''
    )
    $T = $script:T
    while ($true) {
        $hintTxt = if ($Hint) { " $($T.Detail)($Hint)$($T.Reset)" } else { '' }
        $defTxt  = if ($Default) { " $($T.Detail)[$Default]$($T.Reset)" } else { '' }
        [Console]::Out.Write("$($T.Accent)❯$($T.Reset) $($T.Bold)$Prompt$($T.Reset)$hintTxt$defTxt $($T.Accent)›$($T.Reset) ")
        $line = [Console]::ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) { $line = $Default }
        if ([string]::IsNullOrWhiteSpace($line)) {
            _wtf_write "  $($T.Fail)Value required.$($T.Reset)"
            continue
        }
        if ($Validator) {
            $err = & $Validator $line
            if ($err) {
                _wtf_write "  $($T.Fail)$err$($T.Reset)"
                continue
            }
        }
        return $line
    }
}

function Read-WtfConfirm {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$Default = $true
    )
    $T = $script:T
    $hint = if ($Default) { "[Y/n]" } else { "[y/N]" }
    [Console]::Out.Write("$($T.Accent)❯$($T.Reset) $($T.Bold)$Prompt$($T.Reset) $($T.Detail)$hint$($T.Reset) $($T.Accent)›$($T.Reset) ")
    $line = [Console]::ReadLine()
    if ([string]::IsNullOrWhiteSpace($line)) { return $Default }
    return $line.Trim().ToLower() -in @('y','yes')
}

# ============================================================================
# CONFIG
# ============================================================================

function Get-WtfConfig {
    if (-not (Test-Path $script:WtfConfig)) {
        Write-WtfFail "No config yet."
        Write-WtfDetail "Run ``wtf config`` to set up your first root folder."
        return $null
    }
    try {
        return Read-WtfJson -Path $script:WtfConfig
    } catch {
        Write-WtfFail "Config JSON is malformed: $_"
        return $null
    }
}

function New-WtfEmptyConfig {
    # In-memory skeleton used by `wtf config` before any config file exists.
    [pscustomobject]@{ version = 2; contexts = [pscustomobject]@{} }
}

function Get-WtfConfigOrEmpty {
    # Like Get-WtfConfig but never fails — returns an empty skeleton when the
    # file is absent. Used only by the interactive `wtf config` menu.
    if (-not (Test-Path $script:WtfConfig)) { return New-WtfEmptyConfig }
    try { return Read-WtfJson -Path $script:WtfConfig }
    catch {
        Write-WtfFail "Config JSON is malformed: $_"
        return $null
    }
}

function Save-WtfConfig {
    param([Parameter(Mandatory)]$Config)
    Write-WtfJson -Path $script:WtfConfig -Object $Config
    Write-WtfLog "CONFIG saved to $script:WtfConfig"
}

function Get-WtfContextNames { param($Config) Get-ObjectKeys $Config.contexts }

function Get-WtfProjectNames {
    param($Config, [string]$Context)
    $ctx = Get-ObjectValue $Config.contexts $Context
    if (-not $ctx) { return @() }
    Get-ObjectKeys $ctx.projects
}

function Get-WtfProjectConfig {
    param($Config, [string]$Context, [string]$Project)
    $ctx = Get-ObjectValue $Config.contexts $Context
    if (-not $ctx) { return $null }
    return Get-ObjectValue $ctx.projects $Project
}

function Get-WtfProjectApps {
    # Returns @{ shortName = relPath; ... } for multi, or @{} for mono.
    param($ProjectConfig)
    if (-not $ProjectConfig) { return @{} }
    if ($ProjectConfig.type -eq 'mono') { return @{} }
    $apps = @{}
    foreach ($name in Get-ObjectKeys $ProjectConfig.apps) {
        $apps[$name] = Get-ObjectValue $ProjectConfig.apps $name
    }
    return $apps
}

# ============================================================================
# REPO DISCOVERY
# ============================================================================
# Single repos are never stored in config — they are discovered live from each
# context's mainDir. Only multi-repo groups are persisted.

function Test-WtfIsGitRepo {
    param([Parameter(Mandatory)][string]$Dir)
    return (Test-Path (Join-Path $Dir '.git'))
}

function Get-WtfContextObj {
    param($Config, [string]$Context)
    Get-ObjectValue $Config.contexts $Context
}

function Get-WtfRepoCandidates {
    <#
    .SYNOPSIS
        Discover git repos within a root (depth <= 2), so both flat repos
        (projects\Pigeon-Feed) and grouped ones (ai-recruitment-platform\X) are found.
    .OUTPUTS
        Array of [pscustomobject]@{ Name; RelPath; Depth } sorted by RelPath.
        Name = leaf folder name. RelPath = path relative to $MainDir (uses '\').
    #>
    param(
        [Parameter(Mandatory)][string]$MainDir,
        [string]$WorktreeDir = ''
    )
    if (-not (Test-Path $MainDir)) { return @() }
    $out = @()
    $skip = @('node_modules','.git','worktree','worktrees','project-worktrees','dist','build','.vs','.idea')
    $top = Get-ChildItem $MainDir -Directory -Force -ErrorAction SilentlyContinue
    foreach ($d in $top) {
        if ($d.Name -in $skip) { continue }
        if ($WorktreeDir -and ($d.FullName -eq $WorktreeDir)) { continue }
        if (Test-WtfIsGitRepo $d.FullName) {
            $out += [pscustomobject]@{ Name = $d.Name; RelPath = $d.Name; Depth = 1 }
            continue
        }
        # Not a repo itself — peek one level deeper for grouped repos.
        $children = Get-ChildItem $d.FullName -Directory -Force -ErrorAction SilentlyContinue
        foreach ($c in $children) {
            if ($c.Name -in $skip) { continue }
            if (Test-WtfIsGitRepo $c.FullName) {
                $out += [pscustomobject]@{ Name = $c.Name; RelPath = (Join-Path $d.Name $c.Name); Depth = 2 }
            }
        }
    }
    return @($out | Sort-Object RelPath)
}

function Get-WtfGroupMemberPaths {
    <#
    .SYNOPSIS
        All repo relpaths claimed by multi-repo groups in a context (case-insensitive set).
    #>
    param($Config, [string]$Context)
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ctx = Get-WtfContextObj $Config $Context
    if (-not $ctx) { return ,$set }
    foreach ($pn in (Get-ObjectKeys $ctx.projects)) {
        $proj = Get-ObjectValue $ctx.projects $pn
        if ($proj.type -ne 'multi') { continue }
        foreach ($k in (Get-ObjectKeys $proj.apps)) {
            [void]$set.Add((Get-ObjectValue $proj.apps $k))
        }
    }
    # ,$set prevents PowerShell from enumerating the HashSet on return.
    return ,$set
}

function Get-WtfMonoProjects {
    <#
    .SYNOPSIS
        Top-level discovered repos that aren't members of any multi-group.
        Each is an auto-registered mono project (name == folder name == relpath).
    .OUTPUTS
        Array of repo names (strings), sorted.
    #>
    param($Config, [string]$Context)
    $ctx = Get-WtfContextObj $Config $Context
    if (-not $ctx) { return @() }
    $members = Get-WtfGroupMemberPaths $Config $Context
    $cands = Get-WtfRepoCandidates -MainDir $ctx.mainDir -WorktreeDir $ctx.worktreeDir
    $mono = foreach ($c in $cands) {
        if ($c.Depth -ne 1) { continue }       # only flat repos are mono projects
        if ($members.Contains($c.RelPath)) { continue }
        $c.Name
    }
    return @($mono | Sort-Object)
}

function Get-WtfMultiProjectNames {
    param($Config, [string]$Context)
    $ctx = Get-WtfContextObj $Config $Context
    if (-not $ctx) { return @() }
    $names = foreach ($pn in (Get-ObjectKeys $ctx.projects)) {
        if ((Get-ObjectValue $ctx.projects $pn).type -eq 'multi') { $pn }
    }
    return @($names | Sort-Object)
}

function Get-WtfShortName {
    <#
    .SYNOPSIS
        Derive a friendly short app name from a repo leaf folder name by trimming
        a shared prefix and common suffixes (-app / -service / -dev).
    #>
    param(
        [Parameter(Mandatory)][string]$Leaf,
        [string]$CommonPrefix = ''
    )
    $n = $Leaf.ToLower()
    if ($CommonPrefix -and $n.StartsWith($CommonPrefix.ToLower())) {
        $n = $n.Substring($CommonPrefix.Length)
    }
    $n = $n -replace '[-_](app|service|dev|api|frontend|backend)$',''
    $n = $n.Trim('-_ ')
    if ([string]::IsNullOrWhiteSpace($n)) { $n = $Leaf.ToLower() }
    return $n
}

function Get-WtfCommonPrefix {
    # Longest shared leading substring up to a '-' boundary, across names.
    param([string[]]$Names)
    if ($Names.Count -lt 2) { return '' }
    $parts = $Names[0].ToLower() -split '-'
    $prefix = ''
    foreach ($p in $parts) {
        $cand = if ($prefix) { "$prefix-$p" } else { $p }
        $all = $true
        foreach ($n in $Names) { if (-not $n.ToLower().StartsWith("$cand-")) { $all = $false; break } }
        if ($all) { $prefix = $cand } else { break }
    }
    if ($prefix) { return "$prefix-" }
    return ''
}

function New-WtfShortNameMap {
    <#
    .SYNOPSIS
        Given selected candidates, build a unique { shortName -> relPath } map.
    .OUTPUTS
        [ordered] hashtable preserving selection order.
    #>
    param([Parameter(Mandatory)]$Candidates)   # array of {Name; RelPath}
    $leaves = @($Candidates | ForEach-Object { $_.Name })
    $prefix = Get-WtfCommonPrefix $leaves
    $map = [ordered]@{}
    foreach ($c in $Candidates) {
        $short = Get-WtfShortName -Leaf $c.Name -CommonPrefix $prefix
        $base = $short; $i = 2
        while ($map.Contains($short)) { $short = "$base$i"; $i++ }
        $map[$short] = $c.RelPath
    }
    return $map
}

# ============================================================================
# PATH / BRANCH UTILITIES
# ============================================================================

function ConvertTo-WtfSafeName {
    param([Parameter(Mandatory)][string]$Name)
    return ($Name -replace '[\\/:*?"<>|]', '-').Trim('-')
}

function Get-WtfFeatureDir {
    param($Config, [string]$Context, [string]$Project, [string]$Branch)
    $ctx = Get-ObjectValue $Config.contexts $Context
    Join-Path $ctx.worktreeDir "$Project-$(ConvertTo-WtfSafeName $Branch)"
}

function Test-WtfBranchName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "Branch name cannot be empty." }
    if ($Name -match '\s')                   { return "Branch name cannot contain whitespace." }
    if ($Name.Length -gt 100)                { return "Branch name too long (max 100)." }
    if ($Name -match '\.\.')                 { return "Branch name cannot contain '..'." }
    if ($Name.StartsWith('-'))               { return "Branch name cannot start with '-'." }
    return $null
}

# ============================================================================
# GIT
# ============================================================================

function ConvertTo-WtfArgString {
    <#
    .SYNOPSIS
        Join arguments into one Windows command line, quoting as the C runtime
        expects. Needed on Windows PowerShell 5.1, which has no ArgumentList.
    .DESCRIPTION
        The rules are the awkward ones every Windows launcher has to follow: a
        backslash is literal unless it runs into a quote, in which case the run
        of backslashes is doubled; an embedded quote is escaped with a
        backslash; and an argument is only wrapped in quotes when it contains a
        space, a tab or a quote. Branch names and paths with spaces go through
        here, so getting this right matters.
    #>
    param([string[]]$Values)
    $out = @()
    foreach ($v in @($Values)) {
        $s = [string]$v
        if ($s -ne '' -and $s -notmatch '[ \t"]') { $out += $s; continue }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        $slashes = 0
        foreach ($ch in $s.ToCharArray()) {
            if ($ch -eq '\') { $slashes++; continue }
            if ($ch -eq '"') {
                [void]$sb.Append('\' * ($slashes * 2 + 1))
                [void]$sb.Append('"')
                $slashes = 0
                continue
            }
            if ($slashes -gt 0) { [void]$sb.Append('\' * $slashes); $slashes = 0 }
            [void]$sb.Append($ch)
        }
        if ($slashes -gt 0) { [void]$sb.Append('\' * ($slashes * 2)) }
        [void]$sb.Append('"')
        $out += $sb.ToString()
    }
    return ($out -join ' ')
}

function Invoke-WtfGit {
    <#
    .SYNOPSIS
        Run git in a working dir, capture output, log it.
    .OUTPUTS
        @{ Ok; Stdout; Stderr; ExitCode }
    #>
    param(
        [Parameter(Mandatory)][string]$WorkingDir,
        [Parameter(Mandatory)][string[]]$GitArgs
    )
    # core.longpaths=true lifts git's own 260-character path limit. Without it,
    # `git worktree remove` fails with "Filename too long" on any project with a
    # node_modules folder, and it fails AFTER unregistering the worktree, which
    # leaves a folder no later git command will touch. Passed per call with -c,
    # so nothing in the user's git config is changed.
    $GitArgs = @('-c','core.longpaths=true') + $GitArgs
    Write-WtfLog "GIT [$WorkingDir]: git $($GitArgs -join ' ')"
    if (-not (Test-Path $WorkingDir)) {
        $err = "Working dir does not exist: $WorkingDir"
        Write-WtfLog "GIT ERROR: $err"
        return @{ Ok = $false; Stdout = ''; Stderr = $err; ExitCode = -1 }
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName              = 'git'
    $psi.WorkingDirectory      = $WorkingDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    # Never block on an interactive prompt — fail fast instead of hanging.
    # Cached credentials (Git Credential Manager) still work silently.
    $psi.Environment['GIT_TERMINAL_PROMPT'] = '0'
    if (-not $psi.Environment.ContainsKey('GIT_SSH_COMMAND')) {
        $psi.Environment['GIT_SSH_COMMAND'] = 'ssh -o BatchMode=yes'
    }
    # ArgumentList exists only on .NET Core (PowerShell 7). Windows PowerShell
    # 5.1 runs on .NET Framework, where it is absent and reads as $null. Use it
    # when it is there, and otherwise build the quoted command line by hand.
    if ($null -ne $psi.ArgumentList) {
        foreach ($a in $GitArgs) { $psi.ArgumentList.Add($a) }
    } else {
        $psi.Arguments = (ConvertTo-WtfArgString -Values $GitArgs)
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    $result = @{
        Ok       = ($proc.ExitCode -eq 0)
        Stdout   = $stdout.Trim()
        Stderr   = $stderr.Trim()
        ExitCode = $proc.ExitCode
    }
    Write-WtfLog "GIT exit=$($result.ExitCode)"
    if ($result.Stdout) { Write-WtfLog "GIT stdout: $($result.Stdout)" }
    if ($result.Stderr) { Write-WtfLog "GIT stderr: $($result.Stderr)" }
    return $result
}

function Get-WtfDefaultBranch {
    <#
    .SYNOPSIS
        Detect the actual default branch (main/master/develop/...) for a repo.
    #>
    param([Parameter(Mandatory)][string]$RepoDir)
    $r = Invoke-WtfGit -WorkingDir $RepoDir -GitArgs @('symbolic-ref','refs/remotes/origin/HEAD')
    if ($r.Ok -and $r.Stdout) { return ($r.Stdout -split '/')[-1] }

    # Try to set it
    $r2 = Invoke-WtfGit -WorkingDir $RepoDir -GitArgs @('remote','set-head','origin','--auto')
    if ($r2.Ok) {
        $r3 = Invoke-WtfGit -WorkingDir $RepoDir -GitArgs @('symbolic-ref','refs/remotes/origin/HEAD')
        if ($r3.Ok -and $r3.Stdout) { return ($r3.Stdout -split '/')[-1] }
    }
    return 'main'
}

function Resolve-WtfBranchSource {
    <#
    .SYNOPSIS
        Decide how to create a worktree for $Branch.
    .OUTPUTS
        @{ Mode = 'local'|'remote'|'new'; BaseRef = string; Default = string }
    #>
    param(
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string]$Branch
    )
    $local = Invoke-WtfGit -WorkingDir $RepoDir -GitArgs @('show-ref','--verify','--quiet',"refs/heads/$Branch")
    if ($local.Ok) {
        return @{ Mode = 'local'; BaseRef = $Branch; Default = $null }
    }
    $remote = Invoke-WtfGit -WorkingDir $RepoDir -GitArgs @('show-ref','--verify','--quiet',"refs/remotes/origin/$Branch")
    if ($remote.Ok) {
        return @{ Mode = 'remote'; BaseRef = "origin/$Branch"; Default = $null }
    }
    $default = Get-WtfDefaultBranch -RepoDir $RepoDir
    return @{ Mode = 'new'; BaseRef = "origin/$default"; Default = $default }
}

function Invoke-WtfWorktreePrune {
    param([Parameter(Mandatory)][string]$RepoDir)
    Invoke-WtfGit -WorkingDir $RepoDir -GitArgs @('worktree','prune') | Out-Null
}

function Add-WtfGitExclude {
    <#
    .SYNOPSIS
        Add patterns to a repo's LOCAL exclude (.git/info/exclude) so wtf's own
        artifacts (.plan/, .wtf-meta.json) are git-ignored without ever editing
        — or committing — the project's tracked .gitignore.
    #>
    param(
        [Parameter(Mandatory)][string]$WorktreeDir,
        [Parameter(Mandatory)][string[]]$Patterns
    )
    $r = Invoke-WtfGit -WorkingDir $WorktreeDir -GitArgs @('rev-parse','--git-path','info/exclude')
    if (-not $r.Ok -or -not $r.Stdout) { return }
    $excludePath = $r.Stdout
    if (-not [System.IO.Path]::IsPathRooted($excludePath)) {
        $excludePath = Join-Path $WorktreeDir $excludePath
    }
    $dir = Split-Path $excludePath -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $existing = if (Test-Path $excludePath) { Get-Content $excludePath -Raw } else { '' }
    $lines = @($existing -split "`r?`n")
    $toAdd = foreach ($p in $Patterns) { if ($lines -notcontains $p) { $p } }
    if (@($toAdd).Count -gt 0) {
        $prefix = if ($existing -and -not $existing.EndsWith("`n")) { "`n" } else { '' }
        Add-Content -Path $excludePath -Value ($prefix + "# wtf artifacts`n" + (@($toAdd) -join "`n")) -NoNewline
        Write-WtfLog "EXCLUDE: added $(@($toAdd) -join ', ') to $excludePath"
    }
}

# ============================================================================
# MAIN → WORKTREE BRIDGE (gitignored-but-useful files)
# ============================================================================

function Get-WtfCopySkip {
    # Default skip list, optionally extended/replaced by config's top-level "copySkip".
    param($Config)
    if ($Config -and (Test-ObjectHasKey $Config 'copySkip')) {
        $custom = @(Get-ObjectValue $Config 'copySkip')
        if ($custom.Count -gt 0) { return $custom }
    }
    return $script:WtfCopySkipDefault
}

function Copy-WtfIgnoredFiles {
    <#
    .SYNOPSIS
        Mirror gitignored-but-useful files from a source repo into a fresh worktree
        (which only has TRACKED files). Brings .env, graphify-out/, local config,
        certs, data, etc. — but SKIPS heavy regenerable trees (node_modules, dist…)
        so worktrees stay small and you rebuild those instead.
    .OUTPUTS
        Array of top-level relative paths copied.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$Skip = @()
    )
    if (-not (Test-WtfIsGitRepo $Source)) { return @() }
    # --directory collapses a fully-ignored folder to one entry (e.g. graphify-out/),
    # so we decide skip/copy per top-level item instead of walking every file.
    $r = Invoke-WtfGit -WorkingDir $Source -GitArgs @('ls-files','--others','--ignored','--exclude-standard','--directory')
    if (-not $r.Ok -or -not $r.Stdout) { return @() }

    $skipSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $Skip) { [void]$skipSet.Add($s.Trim('/','\')) }

    $copied = @()
    foreach ($entry in ($r.Stdout -split "`n")) {
        $rel = $entry.Trim()
        if (-not $rel) { continue }
        $rel = $rel.TrimEnd('/')
        
        # Check if ANY component of the path (not just top-level) is in the skip list
        # This catches nested node_modules (e.g., dev/node_modules), build outputs, etc.
        $pathComponents = $rel -split '[\\/]'
        $shouldSkip = $false
        foreach ($component in $pathComponents) {
            if ($skipSet.Contains($component)) {
                $shouldSkip = $true
                break
            }
        }
        if ($shouldSkip) { continue }

        $src = Join-Path $Source $rel
        $dst = Join-Path $Destination $rel
        try {
            if (Test-Path $src -PathType Container) {
                Copy-Item -Path $src -Destination $dst -Recurse -Force -ErrorAction Stop
            } else {
                $dstDir = Split-Path $dst -Parent
                if ($dstDir -and -not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
                Copy-Item -Path $src -Destination $dst -Force -ErrorAction Stop
            }
            $copied += $rel
            Write-WtfLog "COPY-IGNORED: $rel → $Destination"
        } catch {
            Write-WtfLog "COPY-IGNORED FAILED: $rel — $_"
        }
    }
    return $copied
}

# ============================================================================
# DEPENDENCY JUNCTIONS (shared/read-along repos placed INSIDE the feature dir)
# ============================================================================
# A dependency repo isn't branched — but it needs to live INSIDE the feature
# folder so (a) shared imports across repos resolve by relative path, and (b) the
# agent sees it as part of the workspace tree. We do that with a Windows directory
# JUNCTION pointing at the dep's MAIN checkout. Junctions need no admin rights,
# read/write straight through to main (so it always reflects main's latest), and
# deleting the junction NEVER touches the target's contents.

function Test-WtfIsReparsePoint {
    # True if a path is a junction/symlink (a reparse point), not a real folder.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

# ----------------------------------------------------------------------------
# LONG PATHS
#
# Windows had a 260-character limit on a full path. A worktree folder is already
# long ("citedspy-feat(marketing)-feature-ribbon"), and node_modules adds another
# 150 characters on its own, so real projects cross the line easily.
#
# Two different programs hit this, and each needs its own fix:
#   git         — refuses with "Filename too long" unless core.longpaths=true
#   PowerShell  — Remove-Item gives up unless the path starts with \\?\
#
# Worse, `git worktree remove` unregisters the worktree BEFORE it deletes the
# files. When the delete fails you are left with a folder git no longer knows
# about, so running the same command again cannot help. That is why the fix has
# to be to stop the failure happening, not only to clean up after it.
# ----------------------------------------------------------------------------

function Get-WtfExtendedPath {
    <#
    .SYNOPSIS
        Turn a path into its \\?\ form, which switches off the 260-character limit.
    .DESCRIPTION
        The \\?\ prefix tells Windows to pass the path to the file system as-is.
        It only accepts a full, already-normalised path, and a UNC path needs a
        different prefix (\\?\UNC\server\share).
    #>
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.StartsWith('\\?\')) { return $Path }
    $full = $Path
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { }
    if ($full.StartsWith('\\')) { return '\\?\UNC\' + $full.Substring(2) }
    return '\\?\' + $full
}

function Remove-WtfTreeExtended {
    <#
    .SYNOPSIS
        Delete one \\?\ path, walking into folders and deleting bottom-up.
    .DESCRIPTION
        Junctions and symlinks are unlinked, never walked into. Walking into one
        would delete the real folder it points at — for us, a dependency's main
        checkout.
    #>
    param([Parameter(Mandatory)][string]$ExtPath)

    $attr = [System.IO.FileAttributes]0
    try { $attr = [System.IO.File]::GetAttributes($ExtPath) }
    catch { return }   # already gone

    if ($attr -band [System.IO.FileAttributes]::ReparsePoint) {
        try { [System.IO.Directory]::Delete($ExtPath, $false) }
        catch { try { [System.IO.File]::Delete($ExtPath) } catch { } }
        return
    }

    if ($attr -band [System.IO.FileAttributes]::Directory) {
        $children = @()
        try { $children = [System.IO.Directory]::GetFileSystemEntries($ExtPath) } catch { }
        foreach ($child in $children) { Remove-WtfTreeExtended -ExtPath $child }
        if ($attr -band [System.IO.FileAttributes]::ReadOnly) {
            try { [System.IO.File]::SetAttributes($ExtPath, [System.IO.FileAttributes]::Directory) } catch { }
        }
        try { [System.IO.Directory]::Delete($ExtPath, $false) } catch { }
        return
    }

    # A read-only file refuses to be deleted, so clear the flag first.
    if ($attr -band [System.IO.FileAttributes]::ReadOnly) {
        try { [System.IO.File]::SetAttributes($ExtPath, [System.IO.FileAttributes]::Normal) } catch { }
    }
    try { [System.IO.File]::Delete($ExtPath) } catch { }
}

function Remove-WtfPath {
    <#
    .SYNOPSIS
        Delete a file or folder, including one whose contents sit deeper than the
        old 260-character path limit.
    .DESCRIPTION
        Tries Remove-Item first, because it is fast and handles the ordinary case.
        If anything survives, walks the tree again through \\?\ paths, which the
        limit does not apply to.

        Junctions are unlinked, never followed, in both passes.
    .OUTPUTS
        $true if nothing is left at that path.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    # A junction on its own: unlink it and stop. Never recurse into the target.
    if (Test-WtfIsReparsePoint $Path) {
        try { [System.IO.Directory]::Delete($Path, $false) } catch { }
        return (-not (Test-Path -LiteralPath $Path))
    }

    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    Write-WtfLog "REMOVE fallback to \\?\ long-path delete: $Path"
    try { Remove-WtfTreeExtended -ExtPath (Get-WtfExtendedPath $Path) }
    catch { Write-WtfLog "REMOVE long-path delete threw: $_" }

    $gone = -not (Test-Path -LiteralPath $Path)
    if (-not $gone) { Write-WtfLog "REMOVE still present after long-path delete: $Path" }
    return $gone
}

function New-WtfDepJunction {
    <#
    .SYNOPSIS
        Create (or refresh) a directory junction at <FeatureDir>/<Name> pointing at
        the dependency's main checkout. Returns $true on success.
    #>
    param(
        [Parameter(Mandatory)][string]$FeatureDir,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Target   # the dep's main-checkout path
    )
    if (-not (Test-Path -LiteralPath $Target)) {
        Write-WtfLog "DEP-JUNCTION skip (target missing): $Target"
        return $false
    }
    $link = Join-Path $FeatureDir $Name
    if (Test-Path -LiteralPath $link) {
        # Already there. If it's a junction, leave it; if it's a real folder, don't
        # clobber it (safety — never delete real content).
        if (Test-WtfIsReparsePoint $link) { return $true }
        Write-WtfWarn "dep '$Name' already exists as a real folder — skipping junction"
        Write-WtfLog "DEP-JUNCTION skip (real folder in the way): $link"
        return $false
    }
    try {
        New-Item -ItemType Junction -Path $link -Target $Target -ErrorAction Stop | Out-Null
        Write-WtfLog "DEP-JUNCTION: $link → $Target"
        return $true
    } catch {
        Write-WtfWarn "could not junction dep '$Name': $_"
        Write-WtfLog "DEP-JUNCTION FAILED: $link → $Target — $_"
        return $false
    }
}

function Remove-WtfDepJunction {
    <#
    .SYNOPSIS
        Remove a dependency junction WITHOUT touching the target's contents.
        Refuses to delete a real (non-junction) folder — that would be the dep's
        actual files. Safe to call on a missing path.
    #>
    param([Parameter(Mandatory)][string]$Link)
    if (-not (Test-Path -LiteralPath $Link)) { return $true }
    if (-not (Test-WtfIsReparsePoint $Link)) {
        Write-WtfLog "DEP-JUNCTION remove SKIP (not a junction — real folder): $Link"
        return $false
    }
    # [System.IO.Directory]::Delete on a junction unlinks it without recursing into
    # the target. (Remove-Item -Recurse on a junction CAN delete target contents on
    # some PS versions, so we use the .NET API which only removes the reparse point.)
    try {
        [System.IO.Directory]::Delete($Link, $false)
        if (Test-Path -LiteralPath $Link) {
            Write-WtfLog "DEP-JUNCTION remove failed (still exists): $Link"
            return $false
        }
        return $true
    }
    catch {
        Write-WtfLog "DEP-JUNCTION remove failed: $Link — $_"
        return $false
    }
}

# ============================================================================
# End of Part 1 — Part 2 will add: create, open, add, remove, list, doctor, dispatcher
# ============================================================================
# wtf.ps1 — Part 2: Commands & Dispatcher
# Source this AFTER part 1 (or concat them).

# ============================================================================
# META FILE
# ============================================================================

function New-WtfMeta {
    param(
        [string]$Context,
        [string]$Project,
        [string]$Branch,
        [ValidateSet('mono','multi')][string]$Type = 'multi',
        # Default @() and filter nulls: when omitted, a bare [string[]]$Apps is
        # $null, and @($null) yields a one-element [null] array that corrupts the
        # meta (mono features showed "apps": [null]).
        [string[]]$Apps = @(),
        $AppPaths = @{},      # short -> relPath (multi only)
        $Deps = @(),          # array of @{ name; path }  (workspace-only repos, junctioned in)
        [bool]$Panes = $false,
        $Slots = @(),         # ACTIVE agent slots (each has a real command)
        $ArchivedSlots = @()  # sessions set aside but kept for review/reopen
    )
    @{
        version       = 2
        context       = $Context
        project       = $Project
        type          = $Type
        branch        = $Branch
        apps          = @(@($Apps) | Where-Object { $_ })
        appPaths      = $AppPaths
        deps          = @($Deps)
        panes         = $Panes
        slots         = @($Slots)          # empty for a fresh feature — born in `wtf edit`
        archivedSlots = @($ArchivedSlots)
        createdAt     = (Get-Date -Format o)
    }
}

# ── Slot helpers ────────────────────────────────────────────────────────────

function Resolve-WtfFeatureLayout {
    <#
    .SYNOPSIS
        Normalize a feature (from its meta) into concrete repo lists, regardless of
        whether config still describes it. Self-describing metas (v2) win; older
        metas fall back to the live project config.
    .OUTPUTS
        @{
          Type      = 'mono'|'multi'
          MainDir   = string
          Worktrees = @( @{ Name; RelPath; Dir } )   # branched repos
          Deps      = @( @{ Name; RelPath; Dir } )   # workspace-only repos
        }
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Meta,
        [Parameter(Mandatory)][string]$FeatureDir
    )
    $ctx = Get-WtfContextObj $Config $Meta.context
    $mainDir = if ($ctx) { $ctx.mainDir } else { '' }
    $type = if ($Meta.type) { $Meta.type } elseif (@($Meta.apps).Count -eq 0) { 'mono' } else { 'multi' }

    $worktrees = @()
    if ($type -eq 'mono') {
        # The feature dir itself is the single worktree.
        $rel = $Meta.project
        if ($ctx) {
            $pc = Get-WtfProjectConfig $Config $Meta.context $Meta.project
            if ($pc -and $pc.path) { $rel = $pc.path }
        }
        $worktrees += @{ Name = $Meta.project; RelPath = $rel; Dir = $FeatureDir }
    } else {
        # Filter nulls/blanks defensively — a legacy meta may carry "apps": [null].
        foreach ($app in @(@($Meta.apps) | Where-Object { $_ })) {
            $rel = $null
            if ($Meta.appPaths -and (Test-ObjectHasKey $Meta.appPaths $app)) {
                $rel = Get-ObjectValue $Meta.appPaths $app
            } else {
                # Fallback: old meta — look up in current project config.
                $pc = Get-WtfProjectConfig $Config $Meta.context $Meta.project
                if ($pc) { $rel = (Get-WtfProjectApps $pc)[$app] }
            }
            if (-not $rel) { $rel = $app }
            $worktrees += @{ Name = $app; RelPath = $rel; Dir = (Join-Path $FeatureDir $app) }
        }
    }

    $deps = @()
    foreach ($d in @($Meta.deps)) {
        if (-not $d) { continue }
        $dname = Get-ObjectValue $d 'name'
        $dpath = Get-ObjectValue $d 'path'
        # Dir = where the dep lives IN-TREE (the junction inside the feature dir).
        # Source = the dep's main checkout (the junction target). Consumers that
        # show/open the dep use Dir; junction create/repair uses Source.
        $deps += @{
            Name    = $dname
            RelPath = $dpath
            Dir     = (Join-Path $FeatureDir $dname)
            Source  = (Join-Path $mainDir $dpath)
        }
    }

    return @{ Type = $type; MainDir = $mainDir; Worktrees = $worktrees; Deps = $deps }
}

function Get-WtfMetaPath {
    # Sidecar beside the feature folder, e.g. worktrees\foo-x.wtf-meta.json.
    # Kept OUTSIDE the repo so a git clean/checkout inside a mono worktree can
    # never delete wtf's bookkeeping.
    param([Parameter(Mandatory)][string]$FeatureDir)
    return "$($FeatureDir.TrimEnd('\','/')).wtf-meta.json"
}

function Save-WtfMeta {
    param([string]$FeatureDir, $Meta)
    Write-WtfJson -Path (Get-WtfMetaPath $FeatureDir) -Object $Meta
}

function Read-WtfMeta {
    param([string]$FeatureDir)
    $sidecar = Get-WtfMetaPath $FeatureDir
    if (Test-Path $sidecar) { return Read-WtfJson -Path $sidecar }
    # Legacy fallback: meta used to live inside the feature folder.
    $legacy = Join-Path $FeatureDir '.wtf-meta.json'
    if (Test-Path $legacy) { return Read-WtfJson -Path $legacy }
    return $null
}

# ============================================================================
# .plan/ DOCS SCAFFOLD — PLAN.md (current map) + LOG.md (daily work log)
# ============================================================================

function Write-WtfPlanDocs {
    <#
    .SYNOPSIS
        Scaffold a feature's plan docs in its .plan/ folder:
          • RULES.md — the constitution. Read EVERY session, REWRITTEN NEVER. The
            operating rules + the agent's mandate to push back when you over-plan.
          • PLAN.md  — the one-screen CURRENT map. Rewritten each session:
            architecture (locked) · now building · built · deferred · unknowns.
            A fresh session reads RULES.md then PLAN.md to resume.
          • CHECK.md — your personal quick-reference card. Terse, point-wise; glance
            at it to instantly remember what to do (seam vs filling, etc.).
          • LOG.md   — the append-only daily work log. Four lines per session
            (built / learned / blocked / next), drafted at end of session.
        Never clobbers an existing file (so your real content is safe to re-run).
        RULES.md and CHECK.md are restored if missing, but never overwritten — so
        you can tweak them and a re-run keeps your edits.
    #>
    param(
        [Parameter(Mandatory)][string]$PlanDir,
        [Parameter(Mandatory)][string]$Branch,
        # NOT mandatory: a mono feature has no apps (@()), and a Mandatory typed
        # array rejects an empty collection. The body already falls back to
        # $Project for scope when Apps is empty.
        [AllowEmptyCollection()][string[]]$Apps = @(),
        [string]$Project = ''
    )
    if (-not (Test-Path $PlanDir)) { New-Item -ItemType Directory -Path $PlanDir -Force | Out-Null }
    $scope = if (@($Apps).Count -gt 0) { ($Apps -join ', ') } else { $Project }
    $date  = Get-Date -Format 'yyyy-MM-dd'

    # ── RULES.md (constitution — read every session, rewritten never) ──
    $rulesPath = Join-Path $PlanDir 'RULES.md'
    if (-not (Test-Path $rulesPath)) {
        # Fully literal — no token replacement. These rules are the same for every
        # feature; they never change per-feature, so nothing is injected.
        $rulesContent = @'
# Operating rules — READ FIRST, every session. Do NOT rewrite this file.

You are working with me in a wtf worktree. Your job is not only to build — it's
to hold these rules when I unconsciously break them. I fall into analysis
paralysis: I over-plan, I gold-plate, I ask "can it be better?" forever and ship
late. When you see me doing it, **stop me and point at the rule.** Push back. Do
not rubber-stamp my over-engineering just because I sound confident.

## The ceiling
- Time is the input, not the outcome. The appetite (how long I have) is decided
  BEFORE we start, usually from the PM/deadline — not estimated into existence.
- A plan is DONE — stop planning, start building — the moment these three exist:
  (1) architecture in one paragraph, (2) the first slice, (3) the deferred list.
  If I keep planning past that point, tell me I have all three and should build.

## Planning effort scales with novelty
- Known/done-before work → almost no planning, go straight to thin slices.
- Novel/risky work → plan the seams, spike the scary part, then build.
- Trivial (typo, flag, 10-min change) → just do it, no ceremony.

## Strong seams, dumb fillings
- Spend the architecture budget ONLY on decisions that are expensive to reverse:
  data model, API contracts, module boundaries. Get those roughly right.
- Behind a clean boundary, write the implementation DUMB — hardcode, one function,
  no patterns, no speculative flexibility. It's cheap to rewrite later with real
  information. If I start polishing internals before the slice works, stop me.

## The first slice must run THROUGH the risk
- The first slice isn't the smallest possible code — it's the smallest thing that
  proves the risky/uncertain part works AND a user can touch it. Make it go
  through the scary part (the AI call, the integration, the unknown), not around.

## Resolve unknowns by building, not by thinking
- We expect the plan to be partly wrong. That's fine — building reveals what
  planning can't. Don't try to plan away every unknown; ship the slice and learn.

## Mid-build changes — the three filters
When I want to change the plan mid-build, run it through these before agreeing:
1. **Building or imagining?** Did I LEARN this from the code (→ legitimate, may
   pivot), or did I just THINK of it / "wouldn't it be nice" (→ Deferred list,
   keep going)? Most shiny mid-build ideas are imagination. Be skeptical.
2. **Seam or filling?** Seam change (load-bearing, costly to retrofit) → worth
   stopping to replan. Filling change (behind an existing boundary) → just change
   it, no ceremony, keep moving.
3. **Fits the ceiling?** Yes → pivot, update the Architecture paragraph (allowed
   when EVIDENCE — not daydreams — shows it's wrong), keep building. No → I must
   surface it to my PM with the evidence BEFORE silently overrunning the deadline.
- "Architecture (locked)" means: don't reopen it because I IMAGINED something
  nicer. It DOES get updated when building proves it wrong. Lock against
  daydreams, not against discovery.

## Shipping
- A messy-but-working shipped slice beats a perfect unshipped system. Refinements
  happen AFTER it works, only if time permits, else we ship as-is.
- The discomfort I feel reaching for "but can it be better first?" is the skill
  I'm building. When you see it, name it, and tell me to ship anyway.
'@
        Write-WtfFile -Path $rulesPath -Content $rulesContent
    }

    # ── CHECK.md (my personal quick-glance card — point-wise) ─────────
    $checkPath = Join-Path $PlanDir 'CHECK.md'
    if (-not (Test-Path $checkPath)) {
        $checkContent = @'
# ⚡ Quick check — read this when my mind starts spiralling

**Before I start**
- [ ] What's my deadline? That's the ceiling. Write it down.
- [ ] Do I have: architecture (1 paragraph) + first slice + defer list? → then STOP planning, BUILD.

**While building**
- New idea pops up → ask: did I LEARN it (building) or THINK it (imagining)?
  - Learned it → maybe act on it (next check).
  - Imagined it → **Deferred list. Keep building.**
- Is the change a SEAM or a FILLING?
  - **Seam** (data model, API contract, boundary — costly to undo) → worth STOPPING to replan.
  - **Filling** (code behind a boundary) → just change it, no ceremony, keep going.
- Does the change still fit the ceiling?
  - Yes → pivot, update Architecture paragraph, build on.
  - No → tell my PM with evidence BEFORE I silently overrun. Don't absorb it quietly.

**Architecture budget**
- Strong SEAMS, dumb FILLINGS. Polish internals later, never before the slice works.
- "Locked" = don't reopen for daydreams. DO reopen when building proves it wrong.

**First slice**
- Must run THROUGH the risky part (AI call / integration / unknown), not around it.
- Smallest thing that proves the risk works AND a user can touch — not smallest code.

**When I catch myself asking "can it be better?"**
- That question has no bottom. Replace it with: "do I have architecture + slice + defer list?"
- If yes → I'm done. **SHIP.** A messy working thing beats a perfect unshipped one.
- The discomfort of shipping imperfect IS the skill. Ship anyway.

**End of session**
- [ ] Rewrite PLAN.md to NOW (delete stale lines).
- [ ] 4-line LOG.md entry (built / learned / blocked / next).
- [ ] Obsidian: over-built / surprised / next-time (by hand, 3 lines).
'@
        Write-WtfFile -Path $checkPath -Content $checkContent
    }

    # ── PLAN.md ───────────────────────────────────────────────────────
    $planPath = Join-Path $PlanDir 'PLAN.md'
    if (-not (Test-Path $planPath)) {
        # Literal here-string (no interpolation) so markdown backticks/brackets stay
        # literal; the few dynamic values are injected by token replacement below.
        $planTpl = @'
# {{BRANCH}}

**Project:** {{PROJECT}}  ·  **In scope:** {{SCOPE}}  ·  **Started:** {{DATE}}

> Operating rules live in `RULES.md` (read it first, every session). My personal
> quick-check is in `CHECK.md`. THIS file is the CURRENT map — nothing else.
> Keep it to one screen. REWRITE it to reflect NOW at the end of every session;
> delete stale lines, don't append history (history → Obsidian). A fresh agent
> session should resume from RULES.md + this file ALONE.
>
> Stop planning the moment these three exist: the architecture paragraph, the
> first slice, and the deferred list. Then build.

## 🏛️ Architecture (locked)

_One paragraph: the decided shape. Don't reopen it for daydreams; DO update it
when building proves it wrong. Strong seams, dumb fillings._

## 🔨 Now building

_The current slice — the smallest real thing this round ships. Must run THROUGH
the risky part, not around it. Concrete, fits the time you have._

- [ ]
- [ ]

## ✅ Built

_Done + verified slices. One line each._

## 🧊 Deferred (not now)

_Real ideas you are deliberately NOT building yet, each with the trigger that
would pull it back in. Imagined "wouldn't it be nice" ideas go HERE, not into the
slice. This list is what keeps the slice small._

- _example_ — build when _<condition>_

## ❓ Open unknowns

_Things you resolve by BUILDING, not by planning. Delete each once answered._

-
'@
        $planContent = $planTpl.
            Replace('{{BRANCH}}',  $Branch).
            Replace('{{PROJECT}}', $Project).
            Replace('{{SCOPE}}',   $scope).
            Replace('{{DATE}}',    $date)
        Write-WtfFile -Path $planPath -Content $planContent
    }

    # ── LOG.md ────────────────────────────────────────────────────────
    $logPath = Join-Path $PlanDir 'LOG.md'
    if (-not (Test-Path $logPath)) {
        $logTpl = @'
# Work log — {{BRANCH}}

> Append-only. One entry per work session (4 lines): what you built, what you
> learned, what's blocked, what's next. Ask your session to draft it at the end:
> "summarize today in 4 lines for my log: built, learned, blocked, next."
> This is project FACTS only — your personal growth/reflection goes in Obsidian.

---

## {{DATE}}
- **Built:**
- **Learned:**
- **Blocked:** nothing
- **Next:**
'@
        $logContent = $logTpl.
            Replace('{{BRANCH}}', $Branch).
            Replace('{{DATE}}',   $date)
        Write-WtfFile -Path $logPath -Content $logContent
    }
}

# ============================================================================
# INTERACTIVE SELECTION HELPERS
# ============================================================================

function Select-WtfContext {
    param($Config, [string]$Provided = '')
    $names = Get-WtfContextNames $Config
    if ($Provided) {
        if ($names -contains $Provided) { return $Provided }
        Write-WtfFail "Context '$Provided' not in config. Available: $($names -join ', ')"
        return $null
    }
    return Read-WtfChoice -Prompt "Context" -Options $names
}

function Select-WtfProject {
    param($Config, [string]$Context, [string]$Provided = '')
    $names = Get-WtfProjectNames $Config $Context
    if ($Provided) {
        if ($names -contains $Provided) { return $Provided }
        Write-WtfFail "Project '$Provided' not in $Context. Available: $($names -join ', ')"
        return $null
    }
    if ($names.Count -eq 0) {
        Write-WtfFail "No projects under context '$Context'."
        return $null
    }
    return Read-WtfChoice -Prompt "Project" -Options $names
}

function Get-WtfExistingBranches {
    <#
    .SYNOPSIS
        Union of local + remote branch names across the given repos (remote names
        stripped of their remote prefix). Used to offer existing branches —
        a peer's, or one you worked on before — when creating a worktree.
    #>
    param([string[]]$Repos)
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($repo in @($Repos)) {
        if (-not (Test-WtfIsGitRepo $repo)) { continue }
        $loc = Invoke-WtfGit -WorkingDir $repo -GitArgs @('branch','--format=%(refname:short)')
        if ($loc.Ok) { foreach ($b in ($loc.Stdout -split "`n")) { if ($b.Trim()) { [void]$set.Add($b.Trim()) } } }
        $rem = Invoke-WtfGit -WorkingDir $repo -GitArgs @('branch','-r','--format=%(refname:short)')
        if ($rem.Ok) {
            foreach ($b in ($rem.Stdout -split "`n")) {
                $b = $b.Trim()
                if (-not $b -or $b -match '/HEAD$') { continue }
                [void]$set.Add(($b -replace '^[^/]+/',''))   # origin/feat/x -> feat/x
            }
        }
    }
    return @($set | Sort-Object)
}

function Select-WtfBranch {
    param(
        [string]$Provided = '',
        [string[]]$SourceRepos = @()
    )
    if ($Provided) {
        $err = Test-WtfBranchName $Provided
        if ($err) { Write-WtfFail $err; return $null }
        return $Provided
    }

    # Offer a picker only when the branch list is small enough to scroll. For big
    # repos (hundreds of branches) that's unusable, so fall back to typing — an
    # existing/peer/remote name still works (Resolve-WtfBranchSource checks it out).
    $existing = @(Get-WtfExistingBranches -Repos $SourceRepos)
    if ($existing.Count -ge 1 -and $existing.Count -le 30) {
        $NEWB = '＋ New branch…'
        $pick = Read-WtfChoice -Prompt "Branch (new, or an existing one to work on)" -Options (@($NEWB) + $existing)
        if (-not $pick) { return $null }
        if ($pick -ne $NEWB) { return $pick }
        return Read-WtfText -Prompt "New branch name" -Hint "e.g. feature/auth-refactor" -Validator { param($v) Test-WtfBranchName $v }
    }
    if ($existing.Count -gt 30) {
        Write-WtfDetail "$($existing.Count) branches exist here — type a name below."
        Write-WtfDetail "A new name starts a fresh branch; an existing/peer/remote name checks that out."
    }
    return Read-WtfText -Prompt "Branch name (new or existing)" -Hint "e.g. feature/auth-refactor" -Validator { param($v) Test-WtfBranchName $v }
}

function Select-WtfApps {
    <#
    .SYNOPSIS
        Resolve / prompt for the list of apps for a multi-repo project.
        For mono projects, returns @() (empty = mono).
    #>
    param(
        [Parameter(Mandatory)]$ProjectConfig,
        [string[]]$Provided = $null,
        [string]$Prompt = "Apps to include",
        [string[]]$Preselected = @()
    )
    if ($ProjectConfig.type -eq 'mono') { return @() }

    $appMap   = Get-WtfProjectApps $ProjectConfig
    $allNames = @($appMap.Keys | Sort-Object)

    if ($Provided -and $Provided.Count -gt 0) {
        $valid = @()
        $invalid = @()
        foreach ($a in $Provided) {
            if ($allNames -contains $a) { $valid += $a } else { $invalid += $a }
        }
        if ($invalid.Count -gt 0) {
            Write-WtfFail "Unknown apps: $($invalid -join ', '). Valid: $($allNames -join ', ')"
            return $null
        }
        return $valid
    }

    return Read-WtfMultiChoice -Prompt $Prompt -Options $allNames -Preselected $Preselected -Min 1
}

function Select-WtfDepRepos {
    <#
    .SYNOPSIS
        Pick optional dependency repos for a multi feature: added to the workspace
        and terminals pointing at MAIN (never branched/worktreed).
    .OUTPUTS
        Array of [pscustomobject]@{ Name; RelPath }.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Context,
        [string[]]$ExcludePaths = @()
    )
    $ctx = Get-WtfContextObj $Config $Context
    $cands = Get-WtfRepoCandidates -MainDir $ctx.mainDir -WorktreeDir $ctx.worktreeDir
    $excl = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $ExcludePaths) { [void]$excl.Add($p) }
    $avail = @($cands | Where-Object { -not $excl.Contains($_.RelPath) })
    if ($avail.Count -eq 0) { return @() }

    $byLabel = @{}
    $labels  = foreach ($c in $avail) { $byLabel[$c.RelPath] = $c; $c.RelPath }
    $picked  = Read-WtfMultiChoice -Prompt "Dependency repos (workspace only, optional)" -Options @($labels) -Min 0
    $result  = foreach ($l in @($picked)) { [pscustomobject]@{ Name = $byLabel[$l].Name; RelPath = $l } }
    return @($result)
}

function Set-WtfMultiProjectOn {
    <#
    .SYNOPSIS
        Add/replace a multi-repo group on an in-memory config object (no save).
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$AppMap      # ordered/hashtable short -> relPath
    )
    $ctx = Get-WtfContextObj $Config $Context
    if (-not $ctx) { return $false }
    if (-not (Test-ObjectHasKey $ctx 'projects') -or -not $ctx.projects) {
        $ctx | Add-Member -NotePropertyName projects -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $appsObj = [pscustomobject]@{}
    foreach ($k in $AppMap.Keys) { $appsObj | Add-Member -NotePropertyName $k -NotePropertyValue $AppMap[$k] -Force }
    $ctx.projects | Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]@{ type = 'multi'; apps = $appsObj }) -Force
    return $true
}

function Save-WtfMultiProject {
    <#
    .SYNOPSIS
        Persist a multi-repo group to config (approach A: created groups become reusable).
        Reloads from disk to avoid clobbering concurrent edits.
    #>
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$AppMap
    )
    $config = Get-WtfConfigOrEmpty
    if (-not $config) { return $false }
    if (-not (Set-WtfMultiProjectOn -Config $config -Context $Context -Name $Name -AppMap $AppMap)) {
        Write-WtfFail "Context '$Context' not found."; return $false
    }
    Save-WtfConfig $config
    return $true
}

# ============================================================================
# COMMAND: wtf create
# ============================================================================

function Invoke-WtfCreate {
    param(
        [string]$Context,
        [string]$Project,
        [string]$Branch,
        [string[]]$Apps,
        [switch]$Panes,
        [switch]$DryRun
    )
    Start-WtfLog 'create'
    Write-WtfBanner "create — start a new feature"

    $config = Get-WtfConfig
    if (-not $config) { return }

    # ── Context ───────────────────────────────────────────────────────
    Write-WtfHeader "Inputs"
    $Context = Select-WtfContext $config $Context
    if (-not $Context) { return }
    $ctxConfig = Get-WtfContextObj $config $Context
    $mainDir   = $ctxConfig.mainDir

    # ── Project picker: discovered mono repos + saved multi groups + new ──
    $monoNames  = @(Get-WtfMonoProjects $config $Context)
    $multiNames = @(Get-WtfMultiProjectNames $config $Context)
    $NEW = '＋ New multi-repo project…'
    $options = @(); $descs = @()
    foreach ($m in $multiNames) { $options += $m; $descs += 'multi-repo' }
    foreach ($m in $monoNames)  { $options += $m; $descs += 'repo' }
    $options += $NEW; $descs += 'pick repos ad-hoc'

    $pick = $null
    if ($Project) {
        if ($Project -in $options) { $pick = $Project }
        else { Write-WtfFail "Project '$Project' not found in '$Context'. Available: $((@($multiNames)+@($monoNames)) -join ', ')"; return }
    } else {
        if ($options.Count -eq 1) {
            Write-WtfWarn "No repos discovered in $mainDir."
            Write-WtfDetail "Drop a git repo there, or pick ‘New multi-repo project’."
        }
        $pick = Read-WtfChoice -Prompt "Project" -Options $options -Descriptions $descs
    }
    if (-not $pick) { return }
    $kind = if ($pick -eq $NEW) { 'new' } elseif ($pick -in $multiNames) { 'multi' } else { 'mono' }

    # ── Resolve worktree repos + dependency repos ─────────────────────
    $projectName = $pick
    $worktreeMap = [ordered]@{}   # short -> relPath (branched)
    $depList     = @()            # @{ Name; RelPath } (workspace-only)
    $saveAsName  = $null

    switch ($kind) {
        'mono' {
            $worktreeMap[$pick] = $pick   # flat repo: relpath == name
        }
        'multi' {
            $pc = Get-WtfProjectConfig $config $Context $pick
            $members = Get-WtfProjectApps $pc
            $chosen = Select-WtfApps $pc $Apps "Repos to branch (worktree)"
            if ($null -eq $chosen) { return }
            $chosen = @($chosen)
            if ($chosen.Count -eq 0) { Write-WtfFail "No repos selected."; return }
            foreach ($s in $chosen) { $worktreeMap[$s] = $members[$s] }
            $depList = Select-WtfDepRepos -Config $config -Context $Context -ExcludePaths @($worktreeMap.Values)
        }
        'new' {
            $cands = Get-WtfRepoCandidates -MainDir $mainDir -WorktreeDir $ctxConfig.worktreeDir
            if ($cands.Count -eq 0) { Write-WtfFail "No git repos found under $mainDir."; return }
            $byLabel = @{}
            $labels  = foreach ($c in $cands) { $byLabel[$c.RelPath] = $c; $c.RelPath }
            $picked  = Read-WtfMultiChoice -Prompt "Repos to branch (worktree)" -Options @($labels) -Min 1
            if (@($picked).Count -eq 0) { Write-WtfWarn "Cancelled."; return }
            $map = New-WtfShortNameMap -Candidates @(foreach ($l in $picked) { $byLabel[$l] })
            foreach ($k in $map.Keys) { $worktreeMap[$k] = $map[$k] }
            $depList = Select-WtfDepRepos -Config $config -Context $Context -ExcludePaths @($worktreeMap.Values)
            $projectName = Read-WtfText -Prompt "Name this project (folder + future reuse)" -Hint "e.g. pigeon"
            if (-not $projectName) { return }
            $projectName = ConvertTo-WtfSafeName $projectName
            $saveAsName  = $projectName
        }
    }

    $isMono  = ($kind -eq 'mono')
    $wtNames = @($worktreeMap.Keys)

    # ── Branch (new, or pick an existing one — yours, a peer's, or remote) ──
    $srcRepos = foreach ($rel in $worktreeMap.Values) { Join-Path $mainDir $rel }
    $Branch = Select-WtfBranch -Provided $Branch -SourceRepos @($srcRepos)
    if (-not $Branch) { return }

    $featureDir = Get-WtfFeatureDir $config $Context $projectName $Branch

    if (Test-Path $featureDir) {
        Write-WtfFail "Feature directory already exists: $featureDir"
        Write-WtfDetail "Use ``wtf delete`` to clean it up first."
        return
    }

    # ── Plan / confirm ────────────────────────────────────────────────
    Write-WtfHeader "Plan"
    Write-WtfInfo "Context:    $Context"
    Write-WtfInfo "Project:    $projectName  ($(if ($isMono) { 'mono' } else { 'multi' }))"
    Write-WtfInfo "Branch:     $Branch"
    Write-WtfInfo "Worktree:   $($wtNames -join ', ')"
    if ($depList.Count -gt 0) { Write-WtfInfo "Deps (ws):  $((@($depList | ForEach-Object { $_.Name })) -join ', ')" }
    Write-WtfInfo "Path:       $featureDir"
    Write-WtfInfo "Agents:     1 terminal (alpha) — add more in ``wtf edit``"
    if ($DryRun) { Write-WtfWarn "DRY RUN — nothing will be written."; return }
    if (-not (Read-WtfConfirm "Proceed?" $true)) { Write-WtfWarn "Cancelled."; return }

    # ── Create worktrees (with rollback) ──────────────────────────────
    Write-WtfHeader "Worktrees"
    # Multi/new pre-create the parent; mono lets git create the worktree dir.
    if (-not $isMono) { New-Item -ItemType Directory -Path $featureDir -Force | Out-Null }

    $created = [System.Collections.ArrayList]::new()
    $envSummary = @()
    $copySkip = Get-WtfCopySkip $config
    $idx = 0
    foreach ($short in $wtNames) {
        $idx++
        $appSrc = Join-Path $mainDir $worktreeMap[$short]
        $appDst = if ($isMono) { $featureDir } else { Join-Path $featureDir $short }
        Write-WtfStep "[$idx/$($wtNames.Count)] $short"

        if (-not (Test-WtfIsGitRepo $appSrc)) {
            Write-WtfFail "Not a git repo: $appSrc"
            Invoke-WtfRollback -FeatureDir $featureDir -Created $created
            return
        }
        Invoke-WtfWorktreePrune -RepoDir $appSrc
        $src = Resolve-WtfBranchSource -RepoDir $appSrc -Branch $Branch
        Write-WtfDetail "branch source: $($src.Mode) ($($src.BaseRef))"
        $ok = New-WtfWorktree -RepoDir $appSrc -TargetDir $appDst -Branch $Branch -Source $src
        if (-not $ok) {
            Write-WtfFail "Worktree creation failed for $short"
            Invoke-WtfRollback -FeatureDir $featureDir -Created $created
            return
        }
        [void]$created.Add(@{ App = $short; Src = $appSrc; Dst = $appDst })

        $copied = Copy-WtfIgnoredFiles -Source $appSrc -Destination $appDst -Skip $copySkip
        if ($copied.Count -gt 0) {
            $shown = if ($copied.Count -gt 6) { ($copied[0..5] -join ', ') + " (+$($copied.Count - 6) more)" } else { $copied -join ', ' }
            Write-WtfOk "$short — copied from main: $shown"
            $envSummary += "$short ($($copied.Count))"
        }
    }

    # ── Collision warning (first time per project) ────────────────────
    $envWarnFlag = Join-Path $script:WtfRoot ".envwarn-$projectName"
    if ($envSummary.Count -gt 0 -and -not (Test-Path $envWarnFlag)) {
        Write-WtfWarn "Heads up: this worktree got a COPY of main's gitignored files (.env, etc.)."
        Write-WtfDetail "If you run feature + main at once, watch for PORT/DB collisions (override PORT here)."
        Write-WtfDetail "Heavy regenerable dirs (node_modules, dist…) were skipped — rebuild them (e.g. npm i)."
        Write-WtfFile -Path $envWarnFlag -Content (Get-Date -Format o)
    }

    # ── Dependency junctions ──────────────────────────────────────────
    # Deps are read-along repos. We JUNCTION each into the feature dir so they sit
    # beside the worktrees — shared imports resolve and the agent sees them as part
    # of the tree. They are NOT branched (the junction points straight at main).
    if ($depList.Count -gt 0) {
        Write-WtfHeader "Dependencies"
        foreach ($d in $depList) {
            $depTarget = Join-Path $mainDir $d.RelPath
            if (New-WtfDepJunction -FeatureDir $featureDir -Name $d.Name -Target $depTarget) {
                Write-WtfOk "$($d.Name) — linked (junction → main)"
            }
        }
    }

    # ── Normalized lists for workspace + terminals ────────────────────
    $wtList  = foreach ($short in $wtNames) {
        @{ Name = $short; Dir = $(if ($isMono) { $featureDir } else { Join-Path $featureDir $short }) }
    }
    # Deps now point at their JUNCTION inside the feature dir (not the external
    # main path), so the workspace shows them in-tree.
    $depNorm = foreach ($d in $depList) { @{ Name = $d.Name; Dir = (Join-Path $featureDir $d.Name) } }
    # SCM phantoms to hide: the branched repos' source main-checkouts, AND each
    # dep's own git repo (it's read-along — you commit to it via main, not here).
    $ignoreRepos = @()
    foreach ($short in $wtNames) { $ignoreRepos += Join-Path $mainDir $worktreeMap[$short] }
    foreach ($d in $depList)     { $ignoreRepos += Join-Path $featureDir $d.Name }

    # ── Artifacts ─────────────────────────────────────────────────────
    Write-WtfHeader "Artifacts"
    # Both mono and multi use a .plan/ FOLDER holding: RULES.md (constitution,
    # never rewritten), CHECK.md (my quick-glance card), PLAN.md (the one-screen
    # current map, rewritten each session), and LOG.md (the append-only daily work
    # log). For MONO the .plan/ lives INSIDE the repo worktree (agent opens the
    # repo root and sees plan+code together) and is git-excluded locally
    # so it's never committed. For MULTI it lives at the feature root (the
    # workspace surfaces it as the 📋 plan folder).
    $planDir = Join-Path $featureDir '.plan'
    New-Item -ItemType Directory -Path $planDir -Force | Out-Null
    Write-WtfPlanDocs -PlanDir $planDir -Branch $Branch -Apps $wtNames -Project $projectName
    Write-WtfOk "RULES.md · CHECK.md · PLAN.md · LOG.md scaffolded in .plan/"

    # Mono: the .plan/ folder lives inside the repo. Exclude it locally so nothing
    # in it can ever be staged/committed.
    # (.wtf-meta.json is a sidecar OUTSIDE the repo, so it needs no exclusion and
    # survives any git clean/checkout.)
    if ($isMono) {
        Add-WtfGitExclude -WorktreeDir $featureDir -Patterns @('/.plan/')
        Write-WtfOk "git-ignored .plan/ locally (won't be committed)"
    }

    $appPaths = @{}
    foreach ($short in $wtNames) { $appPaths[$short] = $worktreeMap[$short] }
    $metaDeps = foreach ($d in $depList) { @{ name = $d.Name; path = $d.RelPath } }
    $metaApps = if ($isMono) { @() } else { @($wtNames) }
    $meta = New-WtfMeta -Context $Context -Project $projectName -Branch $Branch `
                        -Type $(if ($isMono) { 'mono' } else { 'multi' }) `
                        -Apps $metaApps -AppPaths $appPaths -Deps @($metaDeps)
    Save-WtfMeta -FeatureDir $featureDir -Meta $meta
    Write-WtfOk ".wtf-meta.json saved"

    # ── Approach A: offer to save an ad-hoc group as a reusable project ─
    if ($kind -eq 'new') {
        if (Read-WtfConfirm "Save '$saveAsName' as a reusable multi-repo project?" $true) {
            if (Save-WtfMultiProject -Context $Context -Name $saveAsName -AppMap $worktreeMap) {
                Write-WtfOk "saved project '$saveAsName' — it'll be a one-click choice next time"
            }
        }
    }

    # ── Summary + handoff ─────────────────────────────────────────────
    $sumLines = @(
        "$($script:T.Bold)Worktree:$($script:T.Reset) $($wtNames -join ', ')"
    )
    if ($depList.Count -gt 0) { $sumLines += "$($script:T.Bold)Deps:$($script:T.Reset)     $((@($depList | ForEach-Object { $_.Name })) -join ', ')" }
    $sumLines += "$($script:T.Bold)Path:$($script:T.Reset)     $featureDir"
    Write-WtfSummary -Title "Feature ready: $Branch" -Lines $sumLines

    # Nothing is opened. You arrange your own panes, cd into whichever path you
    # want, and `wtf snap` saves that arrangement as a layout.
    Write-WtfHeader "Paths"
    foreach ($w in $wtList) {
        _wtf_write "  $($script:T.Ok)$($w.Name)$($script:T.Reset)"
        _wtf_write "    $($w.Dir)"
    }
    foreach ($d in $depNorm) {
        _wtf_write "  $($script:T.Faint)$($d.Name)  (dependency)$($script:T.Reset)"
        _wtf_write "    $($d.Dir)"
    }
    Write-WtfDetail ""
    Write-WtfDetail "Copy a path into whichever pane you want, then run ``wtf snap`` to save the tab."
}

function New-WtfWorktree {
    <#
    .SYNOPSIS
        Create a single worktree using resolved branch source. Spinner included.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string]$TargetDir,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][hashtable]$Source
    )
    # Fetch first so origin/<default> is current. Synchronous + non-interactive:
    # GIT_TERMINAL_PROMPT=0 (set in Invoke-WtfGit) means this fails fast on a
    # missing credential instead of hanging forever waiting for input.
    Write-WtfDetail "fetching origin..."
    $fetch = Invoke-WtfGit -WorkingDir $RepoDir -GitArgs @('fetch','--prune','origin')
    if (-not $fetch.Ok) {
        Write-WtfWarn "fetch failed (continuing): $($fetch.Stderr)"
    }

    # --no-track on a NEW branch is critical. Creating a branch FROM a
    # remote-tracking ref (origin/main) makes git's default branch.autoSetupMerge
    # silently set the new branch's upstream to origin/main — so a later push goes
    # to main, not to a branch of the same name. --no-track leaves the branch with
    # NO upstream; the first `git push -u` (or VS Code "Publish Branch") then
    # creates origin/<branch> correctly. The 'remote' case keeps --track on purpose:
    # there BaseRef IS origin/<samename>, so inherited tracking is what we want.
    $gitArgs = switch ($Source.Mode) {
        'local'  { @('worktree','add', $TargetDir, $Branch) }
        'remote' { @('worktree','add','--track','-b', $Branch, $TargetDir, $Source.BaseRef) }
        'new'    { @('worktree','add','--no-track','-b', $Branch, $TargetDir, $Source.BaseRef) }
    }
    $r = Invoke-WtfGit -WorkingDir $RepoDir -GitArgs $gitArgs
    if (-not $r.Ok) {
        Write-WtfFail "git worktree add failed"
        Write-WtfDetail $r.Stderr
        return $false
    }
    return $true
}

function Invoke-WtfRollback {
    param(
        [string]$FeatureDir,
        [System.Collections.ArrayList]$Created
    )
    Write-WtfHeader "Rollback"
    foreach ($c in $Created) {
        Write-WtfStep "removing worktree $($c.App)"
        $r = Invoke-WtfGit -WorkingDir $c.Src -GitArgs @('worktree','remove','--force', $c.Dst)
        if (-not $r.Ok) {
            Write-WtfWarn "git worktree remove failed for $($c.App); removing folder directly"
            [void](Remove-WtfPath -Path $c.Dst)
        }
        Invoke-WtfWorktreePrune -RepoDir $c.Src
    }
    if (Test-Path $FeatureDir) {
        [void](Remove-WtfPath -Path $FeatureDir)
    }
    Write-WtfOk "rolled back cleanly"
}

# ============================================================================
# COMMAND: wtf add (mid-flight expansion)
# ============================================================================

function Invoke-WtfAdd {
    param(
        [string]$Context,
        [string]$Project,
        [string]$Branch,
        [string[]]$Apps,
        [switch]$DryRun
    )
    Start-WtfLog 'add'
    Write-WtfBanner "add — expand an existing feature"

    $config = Get-WtfConfig
    if (-not $config) { return }

    $Context = Select-WtfContext $config $Context
    if (-not $Context) { return }

    # Pick the feature to expand (across the context).
    if (-not $Branch) {
        $features = @(Get-WtfActiveFeatures -Config $config -Context $Context)
        if ($Project) { $features = @($features | Where-Object { $_.Project -eq $Project }) }
        if ($features.Count -eq 0) { Write-WtfFail "No active features for $Context."; return }
        $labels = $features | ForEach-Object { "$($_.Project) · $($_.Branch)  $($script:T.Detail)($($_.Apps -join ', '))$($script:T.Reset)" }
        $pick = Read-WtfChoice -Prompt "Which feature to expand" -Options $labels
        if (-not $pick) { return }
        $idx = [Array]::IndexOf($labels, $pick)
        $Project = $features[$idx].Project; $Branch = $features[$idx].Branch
    }

    $featureDir = Get-WtfFeatureDir $config $Context $Project $Branch
    if (-not (Test-Path $featureDir)) { Write-WtfFail "Feature not found: $featureDir"; return }
    $meta = Read-WtfMeta -FeatureDir $featureDir
    if (-not $meta) { Write-WtfFail "Meta file missing/corrupt in $featureDir"; return }

    $type = if ($meta.type) { $meta.type } elseif (@($meta.apps).Count -eq 0) { 'mono' } else { 'multi' }
    if ($type -eq 'mono') { Write-WtfFail "'$Project' is a mono feature — nothing to add."; return }

    $ctxConfig = Get-WtfContextObj $config $Context
    $mainDir   = $ctxConfig.mainDir

    # Repos already worktreed (by relpath) are excluded from candidates.
    $existingPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($a in @($meta.apps)) {
        $rel = if ($meta.appPaths -and (Test-ObjectHasKey $meta.appPaths $a)) { Get-ObjectValue $meta.appPaths $a } else { $a }
        [void]$existingPaths.Add($rel)
    }
    $cands = @(Get-WtfRepoCandidates -MainDir $mainDir -WorktreeDir $ctxConfig.worktreeDir |
               Where-Object { -not $existingPaths.Contains($_.RelPath) })
    if ($cands.Count -eq 0) { Write-WtfWarn "No more repos available to add."; return }

    $byLabel = @{}
    $labels  = foreach ($c in $cands) { $byLabel[$c.RelPath] = $c; $c.RelPath }
    
    # Pick repos to add as worktrees (feature branch)
    $pickedWorktrees = Read-WtfMultiChoice -Prompt "Repos to add as worktrees (feature branch)" -Options @($labels) -Min 0
    
    # Identify existing dependencies by path to avoid duplicates
    $existingDepPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($d in @($meta.deps)) { 
        if ($d -and (Test-ObjectHasKey $d 'path')) { 
            [void]$existingDepPaths.Add((Get-ObjectValue $d 'path'))
        }
    }
    
    # Pick remaining repos to add as dependencies (from those not picked as worktrees)
    $remainingForDeps = @($cands | Where-Object { -not ($pickedWorktrees -contains $_.RelPath) })
    $remainingForDeps = @($remainingForDeps | Where-Object { -not $existingDepPaths.Contains($_.RelPath) })
    
    $pickedDeps = @()
    if ($remainingForDeps.Count -gt 0) {
        $byLabelDeps = @{}
        $labelsDeps  = foreach ($c in $remainingForDeps) { $byLabelDeps[$c.RelPath] = $c; $c.RelPath }
        $pickedDeps  = Read-WtfMultiChoice -Prompt "Repos to add as dependencies (workspace only, main branch)" -Options @($labelsDeps) -Min 0
    }
    
    if (@($pickedWorktrees).Count -eq 0 -and @($pickedDeps).Count -eq 0) { 
        Write-WtfWarn "No repos selected."; return 
    }

    # Build short names for worktree additions, avoiding collisions with existing apps.
    $addMap = if (@($pickedWorktrees).Count -gt 0) {
        New-WtfShortNameMap -Candidates @(foreach ($l in $pickedWorktrees) { $byLabel[$l] })
    } else {
        @{}
    }
    $finalAdd = [ordered]@{}
    foreach ($k in $addMap.Keys) {
        $short = $k; $i = 2
        while (($short -in @($meta.apps)) -or $finalAdd.Contains($short)) { $short = "$k$i"; $i++ }
        $finalAdd[$short] = $addMap[$k]
    }
    
    # Build dependency additions
    $finalAddDeps = @()
    foreach ($depPath in $pickedDeps) {
        $depCand = $byLabelDeps[$depPath]
        if ($depCand) {
            $finalAddDeps += @{ name = $depCand.Name; path = $depPath }
        }
    }

    Write-WtfHeader "Plan"
    Write-WtfInfo "Feature:  $Project · $Branch"
    if ($finalAdd.Count -gt 0) { Write-WtfInfo "Adding as worktrees: $(@($finalAdd.Keys) -join ', ')" }
    if ($finalAddDeps.Count -gt 0) { Write-WtfInfo "Adding as dependencies: $($(@($finalAddDeps | ForEach-Object { $_.name }) | Sort-Object -Unique) -join ', ')" }
    if ($DryRun) { Write-WtfWarn "DRY RUN."; return }
    if (-not (Read-WtfConfirm "Proceed?" $true)) { Write-WtfWarn "Cancelled."; return }

    if ($finalAdd.Count -gt 0) {
        Write-WtfHeader "Worktrees"
        $created = [System.Collections.ArrayList]::new()
        $idx = 0
        foreach ($short in $finalAdd.Keys) {
            $idx++
            $appSrc = Join-Path $mainDir $finalAdd[$short]
            $appDst = Join-Path $featureDir $short
            Write-WtfStep "[$idx/$($finalAdd.Count)] $short"

            if (-not (Test-WtfIsGitRepo $appSrc)) {
                Write-WtfFail "Not a git repo: $appSrc"
                Invoke-WtfAddRollback -Created $created
                return
            }
            Invoke-WtfWorktreePrune -RepoDir $appSrc
            $src = Resolve-WtfBranchSource -RepoDir $appSrc -Branch $Branch
            $ok = New-WtfWorktree -RepoDir $appSrc -TargetDir $appDst -Branch $Branch -Source $src
            if (-not $ok) { Invoke-WtfAddRollback -Created $created; return }
            [void]$created.Add(@{ App = $short; Src = $appSrc; Dst = $appDst })
            $copied = Copy-WtfIgnoredFiles -Source $appSrc -Destination $appDst -Skip (Get-WtfCopySkip $config)
            if ($copied.Count -gt 0) {
                $shown = if ($copied.Count -gt 6) { ($copied[0..5] -join ', ') + " (+$($copied.Count - 6) more)" } else { $copied -join ', ' }
                Write-WtfOk "$short — copied from main: $shown"
            }
        }
    } else {
        $created = [System.Collections.ArrayList]::new()
    }

    # Update meta (preserve appPaths + deps) and rebuild the workspace.
    $newApps  = @($meta.apps) + @($finalAdd.Keys)
    $appPaths = @{}
    foreach ($a in @($meta.apps)) {
        $appPaths[$a] = if ($meta.appPaths -and (Test-ObjectHasKey $meta.appPaths $a)) { Get-ObjectValue $meta.appPaths $a } else { $a }
    }
    foreach ($k in $finalAdd.Keys) { $appPaths[$k] = $finalAdd[$k] }
    
    # Preserve existing deps and add new ones
    $deps = @()
    foreach ($d in @($meta.deps)) { if ($d) { $deps += @{ name = (Get-ObjectValue $d 'name'); path = (Get-ObjectValue $d 'path') } } }
    foreach ($newDep in $finalAddDeps) { $deps += $newDep }

    $newMeta = New-WtfMeta -Context $Context -Project $Project -Branch $Branch -Type 'multi' `
                           -Apps $newApps -AppPaths $appPaths -Deps @($deps)
    $newMeta.createdAt = $meta.createdAt
    Save-WtfMeta -FeatureDir $featureDir -Meta $newMeta

    $layout = Resolve-WtfFeatureLayout -Config $config -Meta $newMeta -FeatureDir $featureDir

    # Junction any newly-added deps into the feature dir (idempotent — existing
    # junctions are left as-is).
    if (@($finalAddDeps).Count -gt 0) {
        Write-WtfHeader "Dependencies"
        foreach ($d in @($layout.Deps)) {
            if (New-WtfDepJunction -FeatureDir $featureDir -Name $d.Name -Target $d.Source) {
                Write-WtfOk "$($d.Name) — linked (junction → main)"
            }
        }
    }

    $summaryLines = @()
    if ($newApps.Count -gt 0) {
        $summaryLines += "$($script:T.Bold)Worktrees in feature:$($script:T.Reset) $($newApps -join ', ')"
    }
    if ($deps.Count -gt 0) {
        $depNames = @($deps | ForEach-Object { $_.name } | Sort-Object -Unique)
        $summaryLines += "$($script:T.Bold)Dependencies in workspace:$($script:T.Reset) $($depNames -join ', ')"
    }
    $summaryLines += "$($script:T.Detail)Run ``wtf open`` to refresh terminals with new tabs.$($script:T.Reset)"
    
    Write-WtfSummary -Title "Repos added" -Lines @($summaryLines)
}

function Invoke-WtfAddRollback {
    param([System.Collections.ArrayList]$Created)
    Write-WtfHeader "Rollback"
    foreach ($c in $Created) {
        Write-WtfStep "removing $($c.App)"
        $r = Invoke-WtfGit -WorkingDir $c.Src -GitArgs @('worktree','remove','--force', $c.Dst)
        if (-not $r.Ok) {
            [void](Remove-WtfPath -Path $c.Dst)
        }
        Invoke-WtfWorktreePrune -RepoDir $c.Src
    }
    Write-WtfOk "rolled back"
}

# ============================================================================
# COMMAND: wtf remove (drop individual repos/deps from a feature)
# ============================================================================
# The inverse of `wtf add`: pull one or more worktree repos or dependency repos
# OUT of a feature without tearing the whole feature down. Worktree repos get
# `git worktree remove`d (with the same dirty/unpushed safety as `wtf delete`);
# deps get their junction unlinked (the dep's main checkout is NEVER touched).
# Meta is rebuilt afterward so the feature description stays accurate.

function Invoke-WtfRemove {
    param(
        [string]$Context,
        [string]$Project,
        [string]$Branch,
        [string[]]$Apps,
        [switch]$Force,
        [switch]$DryRun
    )
    Start-WtfLog 'remove'
    Write-WtfBanner "remove — drop repos from a feature"

    $config = Get-WtfConfig
    if (-not $config) { return }

    $Context = Select-WtfContext $config $Context
    if (-not $Context) { return }

    # Pick the feature to shrink (across the context).
    if (-not $Branch) {
        $features = @(Get-WtfActiveFeatures -Config $config -Context $Context)
        if ($Project) { $features = @($features | Where-Object { $_.Project -eq $Project }) }
        if ($features.Count -eq 0) { Write-WtfFail "No active features for $Context."; return }
        $labels = $features | ForEach-Object { "$($_.Project) · $($_.Branch)  $($script:T.Detail)($($_.Apps -join ', '))$($script:T.Reset)" }
        $pick = Read-WtfChoice -Prompt "Which feature to shrink" -Options $labels
        if (-not $pick) { return }
        $idx = [Array]::IndexOf($labels, $pick)
        $Project = $features[$idx].Project; $Branch = $features[$idx].Branch
    }

    $featureDir = Get-WtfFeatureDir $config $Context $Project $Branch
    if (-not (Test-Path $featureDir)) { Write-WtfFail "Feature not found: $featureDir"; return }
    $meta = Read-WtfMeta -FeatureDir $featureDir
    if (-not $meta) { Write-WtfFail "Meta file missing/corrupt in $featureDir"; return }

    $type = if ($meta.type) { $meta.type } elseif (@($meta.apps).Count -eq 0) { 'mono' } else { 'multi' }
    if ($type -eq 'mono') { Write-WtfFail "'$Project' is a mono feature — use ``wtf delete`` to tear it down."; return }

    $layout = Resolve-WtfFeatureLayout -Config $config -Meta $meta -FeatureDir $featureDir

    # Build a combined pick list: worktree repos (branched) + dep repos (junctioned).
    # Label carries the kind so we know how to tear each one down.
    $items    = [ordered]@{}   # label -> @{ Kind='worktree'|'dep'; Name; RelPath; Dir; Src }
    foreach ($w in @($layout.Worktrees)) {
        $lbl = "$($w.Name)  $($script:T.Detail)(worktree)$($script:T.Reset)"
        $items[$lbl] = @{ Kind = 'worktree'; Name = $w.Name; RelPath = $w.RelPath; Dir = $w.Dir; Src = (Join-Path $layout.MainDir $w.RelPath) }
    }
    foreach ($d in @($layout.Deps)) {
        $lbl = "$($d.Name)  $($script:T.Detail)(dependency)$($script:T.Reset)"
        $items[$lbl] = @{ Kind = 'dep'; Name = $d.Name; RelPath = $d.RelPath; Dir = $d.Dir; Src = $d.Source }
    }
    if ($items.Count -eq 0) { Write-WtfWarn "Nothing in this feature to remove."; return }

    # Selection: honor -Apps (by repo name or relpath) when given non-interactively.
    # If none match, fall back to the picker so a typo doesn't end the command early.
    $picked = @()
    $requested = @(
        $Apps |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() }
    )
    if ($requested.Count -gt 0) {
        $itemByName = @{}
        foreach ($lbl in $items.Keys) {
            $item = $items[$lbl]
            $itemByName[$item.Name]    = $lbl
            $itemByName[$item.RelPath] = $lbl
        }
        foreach ($req in $requested) {
            if ($itemByName.ContainsKey($req)) { $picked += $itemByName[$req] }
        }
        $picked = @($picked | Select-Object -Unique)
        $unknown = @($requested | Where-Object { -not $itemByName.ContainsKey($_) })
        if ($unknown.Count -gt 0) { Write-WtfWarn "Not in this feature (ignored): $($unknown -join ', ')" }
    }
    if ($picked.Count -eq 0) {
        if ($requested.Count -gt 0) { Write-WtfDetail "No valid repos matched; choose from the picker below." }
        $picked = Read-WtfMultiChoice -Prompt "Repos to remove from '$Branch'" -Options @($items.Keys) -Min 0
    }
    if (@($picked).Count -eq 0) { Write-WtfWarn "Nothing selected."; return }

    $chosen = @($picked | ForEach-Object { $items[$_] })
    $wtChosen  = @($chosen | Where-Object { $_.Kind -eq 'worktree' })
    $depChosen = @($chosen | Where-Object { $_.Kind -eq 'dep' })

    # Guard: a multi feature must keep at least one worktree. Removing every
    # branched repo would leave an empty shell — that's a `wtf delete`.
    $remainingWt = @($layout.Worktrees).Count - $wtChosen.Count
    if ($remainingWt -le 0) {
        Write-WtfFail "That would remove every worktree repo, leaving an empty feature."
        Write-WtfDetail "Use ``wtf delete`` to tear the whole feature down instead."
        return
    }

    # ── Safety checks on worktree repos (dirty / unpushed) ────────────
    if ($wtChosen.Count -gt 0) {
        Write-WtfHeader "Safety checks"
        $issues = @()
        foreach ($w in $wtChosen) {
            if (-not (Test-Path $w.Dir)) { Write-WtfWarn "$($w.Name) — worktree folder missing, will git-prune"; continue }
            Write-WtfStep "$($w.Name)"
            $status = Invoke-WtfGit -WorkingDir $w.Dir -GitArgs @('status','--porcelain')
            if ($status.Stdout) {
                $lines = ($status.Stdout -split "`n").Count
                Write-WtfFail "  uncommitted changes ($lines files)"
                $issues += "$($w.Name): dirty"
            }
            $unpushed = Invoke-WtfGit -WorkingDir $w.Dir -GitArgs @('log','--oneline','@{u}..HEAD')
            if ($unpushed.Ok -and $unpushed.Stdout) {
                $count = ($unpushed.Stdout -split "`n").Count
                Write-WtfFail "  $count unpushed commit(s)"
                $issues += "$($w.Name): unpushed"
            } elseif (-not $unpushed.Ok -and $unpushed.Stderr -match 'no upstream') {
                Write-WtfWarn "  no upstream — branch never pushed"
            }
            if (-not $issues -or $issues[-1] -notlike "$($w.Name):*") { Write-WtfOk "  clean & pushed" }
        }
        if ($issues.Count -gt 0 -and -not $Force) {
            Write-WtfFail "Aborting due to: $($issues -join '; ')"
            Write-WtfDetail "Pass --force to override (you will lose unpushed/uncommitted work)."
            return
        }
        if ($issues.Count -gt 0) { Write-WtfWarn "Forcing despite: $($issues -join '; ')" }
    }

    # ── Plan / confirm ────────────────────────────────────────────────
    Write-WtfHeader "Plan"
    Write-WtfInfo "Feature:  $Project · $Branch"
    if ($wtChosen.Count -gt 0)  { Write-WtfInfo "Removing worktrees:    $(@($wtChosen  | ForEach-Object { $_.Name }) -join ', ')" }
    if ($depChosen.Count -gt 0) { Write-WtfInfo "Unlinking dependencies: $(@($depChosen | ForEach-Object { $_.Name }) -join ', ')" }
    if ($DryRun) { Write-WtfWarn "DRY RUN — nothing changed."; return }
    if (-not (Read-WtfConfirm "Proceed?" $true)) { Write-WtfWarn "Cancelled."; return }

    # ── Tear down worktree repos ──────────────────────────────────────
    $stuck = @()
    $removedWt = @()
    if ($wtChosen.Count -gt 0) {
        Write-WtfHeader "Worktrees"
        Write-WtfDetail "If removal stalls, close any pane sitting inside these repos."
        foreach ($w in $wtChosen) {
            Write-WtfStep "$($w.Name)"
            if (Test-WtfIsGitRepo $w.Src) {
                $r = Invoke-WtfGit -WorkingDir $w.Src -GitArgs @('worktree','remove','--force', $w.Dir)
                if (-not $r.Ok) {
                    if ($r.Stderr -match 'Permission denied|being used|access') {
                        Write-WtfWarn "  files locked - close any pane sitting in this repo"
                    } else {
                        Write-WtfWarn "  git worktree remove failed: $($r.Stderr)"
                    }
                    if (Test-Path $w.Dir) { [void](Remove-WtfPath -Path $w.Dir) }
                }
                Invoke-WtfWorktreePrune -RepoDir $w.Src
            } else {
                Write-WtfWarn "  source repo missing; cleaning files only"
                if (Test-Path $w.Dir) { [void](Remove-WtfPath -Path $w.Dir) }
            }
            if (Test-Path $w.Dir) {
                $stuck += $w.Name
                Write-WtfFail "  still present (locked): $($w.Dir)"
            } else {
                $removedWt += $w.Name
                Write-WtfOk "  removed"
            }
        }
    }

    # ── Unlink dependency junctions (target's main checkout untouched) ─
    $removedDeps = @()
    if ($depChosen.Count -gt 0) {
        Write-WtfHeader "Dependencies"
        foreach ($d in $depChosen) {
            Write-WtfStep "$($d.Name)"
            $removed = $false
            if (Test-Path -LiteralPath $d.Dir) {
                if (Test-WtfIsReparsePoint $d.Dir) {
                    $ok = Remove-WtfDepJunction -Link $d.Dir
                    if ($ok) {
                        Write-WtfOk "  unlinked (main checkout untouched)"
                        $removed = $true
                    } else {
                        Write-WtfWarn "  couldn't unlink junction — leaving it in feature"
                    }
                } else {
                    Write-WtfWarn "  real folder, not a junction — leaving it on disk"
                }
            } else {
                Write-WtfOk "  already gone"
                $removed = $true
            }
            if ($removed) { $removedDeps += $d.Name }
        }
    }

    # A worktree that stayed locked keeps its meta entry so a retry can finish it;
    # everything actually removed is dropped from apps/appPaths/deps.
    $removedWtSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $removedWt) { [void]$removedWtSet.Add($n) }
    $removedDepSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $removedDeps) { [void]$removedDepSet.Add($n) }

    # ── Rebuild meta (preserve slots + surviving apps/deps) ───────────
    $newApps  = @(@($meta.apps) | Where-Object { $_ -and -not $removedWtSet.Contains($_) })
    $appPaths = @{}
    foreach ($a in $newApps) {
        $appPaths[$a] = if ($meta.appPaths -and (Test-ObjectHasKey $meta.appPaths $a)) { Get-ObjectValue $meta.appPaths $a } else { $a }
    }
    $deps = @()
    foreach ($d in @($meta.deps)) {
        if (-not $d) { continue }
        $dn = Get-ObjectValue $d 'name'
        if ($removedDepSet.Contains($dn)) { continue }
        $deps += @{ name = $dn; path = (Get-ObjectValue $d 'path') }
    }

    $newMeta = New-WtfMeta -Context $Context -Project $Project -Branch $Branch -Type 'multi' `
                           -Apps $newApps -AppPaths $appPaths -Deps @($deps)
    $newMeta.createdAt = $meta.createdAt
    Save-WtfMeta -FeatureDir $featureDir -Meta $newMeta

    # ── Offer to delete the local branch for removed worktree repos ───
    if ($removedWt.Count -gt 0) {
        $branchRepos = @()
        foreach ($w in $wtChosen) {
            if (-not $removedWtSet.Contains($w.Name)) { continue }
            if (Test-WtfIsGitRepo $w.Src) {
                $has = Invoke-WtfGit -WorkingDir $w.Src -GitArgs @('show-ref','--verify','--quiet',"refs/heads/$Branch")
                if ($has.Ok) { $branchRepos += @{ Name = $w.Name; Src = $w.Src } }
            }
        }
        if ($branchRepos.Count -gt 0) {
            if (Read-WtfConfirm "Also delete the local branch '$Branch' from $($branchRepos.Count) removed repo(s)?" $false) {
                foreach ($b in $branchRepos) {
                    $d = Invoke-WtfGit -WorkingDir $b.Src -GitArgs @('branch','-D', $Branch)
                    if ($d.Ok) { Write-WtfOk "  deleted $Branch in $($b.Name)" }
                    else        { Write-WtfWarn "  couldn't delete in $($b.Name): $($d.Stderr)" }
                }
            }
        }
    }

    # ── Summary ───────────────────────────────────────────────────────
    if ($stuck.Count -gt 0) {
        Write-WtfSummary -Title "Partially removed from: $Branch" -Color $script:T.Warn -Lines @(
            "$($script:T.Warn)Locked (still on disk):$($script:T.Reset) $($stuck -join ', ')",
            "$($script:T.Detail)Close any pane sitting in those repos, then run ``wtf remove`` again.$($script:T.Reset)"
        )
        return
    }
    $sum = @()
    if ($removedWt.Count -gt 0)   { $sum += "$($script:T.Bold)Worktrees removed:$($script:T.Reset) $($removedWt -join ', ')" }
    if ($removedDeps.Count -gt 0) { $sum += "$($script:T.Bold)Dependencies unlinked:$($script:T.Reset) $($removedDeps -join ', ')" }
    if ($newApps.Count -gt 0)     { $sum += "$($script:T.Detail)Still in feature: $($newApps -join ', ')$($script:T.Reset)" }
    $sum += "$($script:T.Detail)Run ``wtf open`` to refresh terminals.$($script:T.Reset)"
    Write-WtfSummary -Title "Removed from: $Branch" -Lines @($sum)
}

# ============================================================================
# AGENTIC TERMINAL SLOTS — walk-through + preview
# ============================================================================

function _wtf_now_iso { return (Get-Date -Format o) }

function _wtf_truncate {
    param([string]$Text, [int]$Max)
    if (-not $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    if ($Max -le 1) { return $Text.Substring(0, [Math]::Max(0,$Max)) }
    return $Text.Substring(0, $Max - 1) + '…'
}

function Resolve-WtfFeatureSelection {
    <#
    .SYNOPSIS
        Shared feature picker. Returns @{ Context; Project; Branch; Dir; Meta }
        or $null. If ctx/proj/branch are all supplied, resolves directly.
    #>
    param($Config, [string]$Context, [string]$Project, [string]$Branch, [string]$Prompt = 'Which feature')
    if (-not $Context -or -not $Project -or -not $Branch) {
        $features = Get-WtfActiveFeatures -Config $Config
        if ($Context) { $features = @($features | Where-Object { $_.Context -eq $Context }) }
        if ($features.Count -eq 0) { Write-WtfFail "No active features."; return $null }
        $labels = $features | ForEach-Object {
            "$($_.Context)/$($_.Project) · $($_.Branch)  $($script:T.Detail)($($_.Apps -join ', '))$($script:T.Reset)"
        }
        $pick = Read-WtfChoice -Prompt $Prompt -Options $labels
        if (-not $pick) { return $null }
        $f = $features[[Array]::IndexOf($labels, $pick)]
        $Context = $f.Context; $Project = $f.Project; $Branch = $f.Branch
    }
    $dir  = Get-WtfFeatureDir $Config $Context $Project $Branch
    $meta = Read-WtfMeta -FeatureDir $dir
    if (-not $meta) { Write-WtfFail "Feature not found: $dir"; return $null }
    return @{ Context = $Context; Project = $Project; Branch = $Branch; Dir = $dir; Meta = $meta }
}

# ============================================================================
# COMMAND: wtf status  (per-feature dashboard)
# ============================================================================

function Get-WtfPlanProgress {
    <#
    .SYNOPSIS
        Count ticked vs total markdown checkboxes ([ ] / [x]) in a file.
    .OUTPUTS
        @{ Done; Total } (0/0 if the file is missing).
    #>
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @{ Done = 0; Total = 0 } }
    $text = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if (-not $text) { return @{ Done = 0; Total = 0 } }
    $done  = ([regex]::Matches($text, '(?im)^\s*[-*]\s*\[x\]')).Count
    $open  = ([regex]::Matches($text, '(?im)^\s*[-*]\s*\[ \]')).Count
    return @{ Done = $done; Total = ($done + $open) }
}

function Invoke-WtfStatus {
    param(
        [string]$Context,
        [string]$Project,
        [string]$Branch
    )
    Start-WtfLog 'status'
    Write-WtfBanner "status — feature dashboard"

    $config = Get-WtfConfig
    if (-not $config) { return }

    $sel = Resolve-WtfFeatureSelection -Config $config -Context $Context -Project $Project -Branch $Branch -Prompt "Status for which feature"
    if (-not $sel) { return }
    $meta   = $sel.Meta
    $layout = Resolve-WtfFeatureLayout -Config $config -Meta $meta -FeatureDir $sel.Dir
    $T = $script:T

    Write-WtfHeader "$($sel.Context) / $($sel.Project) — $($sel.Branch)"

    # ── Worktrees: git status (reuses list's tag logic) ───────────────
    Write-WtfInfo "Worktrees:"
    foreach ($w in @($layout.Worktrees)) {
        if (-not (Test-Path $w.Dir)) { Write-WtfWarn "  $($w.Name) — folder missing"; continue }
        $st = Invoke-WtfGit -WorkingDir $w.Dir -GitArgs @('status','--porcelain')
        $ah = Invoke-WtfGit -WorkingDir $w.Dir -GitArgs @('rev-list','--count','@{u}..HEAD')
        $bh = Invoke-WtfGit -WorkingDir $w.Dir -GitArgs @('rev-list','--count','HEAD..@{u}')
        $tags = @()
        if ($st.Stdout) { $tags += "$($T.Warn)dirty$($T.Reset)" }
        if ($ah.Ok -and [int]$ah.Stdout -gt 0) { $tags += "$($T.Accent)↑$($ah.Stdout)$($T.Reset)" }
        if ($bh.Ok -and [int]$bh.Stdout -gt 0) { $tags += "$($T.Warn)↓$($bh.Stdout)$($T.Reset)" }
        if ($tags.Count -eq 0) { $tags = @("$($T.Ok)clean$($T.Reset)") }
        _wtf_write "    · $($T.Bold)$($w.Name)$($T.Reset)  $($tags -join ' ')"
    }

    # ── Plan progress (checkbox counts in PLAN.md) ────────────────────
    $planDir = Join-Path $sel.Dir '.plan'
    if (Test-Path $planDir) {
        Write-WtfInfo "Plan:"
        $planMd = Join-Path $planDir 'PLAN.md'
        if (Test-Path $planMd) {
            $p = Get-WtfPlanProgress $planMd
            $bar = if ($p.Total -gt 0) { "$($p.Done)/$($p.Total) steps in 'Now building'" } else { "$($T.Faint)no open steps$($T.Reset)" }
            _wtf_write "    · $($T.Bold)PLAN.md$($T.Reset)  $bar"
        } else {
            Write-WtfDetail "  PLAN.md missing"
        }
        $logMd = Join-Path $planDir 'LOG.md'
        if (Test-Path $logMd) { _wtf_write "    · $($T.Bold)LOG.md$($T.Reset)  $($T.Faint)present$($T.Reset)" }
    }
}

# ============================================================================
# COMMAND: wtf delete
# ============================================================================

function Invoke-WtfDelete {
    param(
        [string]$Context,
        [string]$Project,
        [string]$Branch,
        [switch]$Force,
        [switch]$DryRun
    )
    Start-WtfLog 'delete'
    Write-WtfBanner "delete — tear down a whole feature"

    $config = Get-WtfConfig
    if (-not $config) { return }

    if (-not $Context -or -not $Project -or -not $Branch) {
        $features = Get-WtfActiveFeatures -Config $config
        if ($features.Count -eq 0) { Write-WtfFail "Nothing to delete."; return }
        $labels = $features | ForEach-Object {
            "$($_.Context)/$($_.Project) · $($_.Branch)"
        }
        $pick = Read-WtfChoice -Prompt "Delete which feature" -Options $labels
        if (-not $pick) { return }
        $idx = [Array]::IndexOf($labels, $pick)
        $f = $features[$idx]
        $Context = $f.Context; $Project = $f.Project; $Branch = $f.Branch
    }

    $featureDir = Get-WtfFeatureDir $config $Context $Project $Branch
    $meta = Read-WtfMeta -FeatureDir $featureDir
    if (-not $meta) { Write-WtfFail "Feature not found: $featureDir"; return }

    $layout = Resolve-WtfFeatureLayout -Config $config -Meta $meta -FeatureDir $featureDir
    $worktrees = @($layout.Worktrees)   # only branched repos — deps are never touched

    # ── Safety checks ─────────────────────────────────────────────────
    Write-WtfHeader "Safety checks"
    $issues = @()
    foreach ($w in $worktrees) {
        $app   = $w.Name
        $wtDir = $w.Dir
        if (-not (Test-Path $wtDir)) {
            Write-WtfWarn "$app — worktree folder missing, will git-prune"
            continue
        }
        Write-WtfStep "$app"

        $status = Invoke-WtfGit -WorkingDir $wtDir -GitArgs @('status','--porcelain')
        if ($status.Stdout) {
            $lines = ($status.Stdout -split "`n").Count
            Write-WtfFail "  uncommitted changes ($lines files)"
            $issues += "${app}: dirty"
        }

        $unpushed = Invoke-WtfGit -WorkingDir $wtDir -GitArgs @('log','--oneline','@{u}..HEAD')
        if ($unpushed.Ok -and $unpushed.Stdout) {
            $count = ($unpushed.Stdout -split "`n").Count
            Write-WtfFail "  $count unpushed commit(s)"
            $issues += "${app}: unpushed"
        } elseif (-not $unpushed.Ok -and $unpushed.Stderr -match 'no upstream') {
            Write-WtfWarn "  no upstream — branch never pushed"
        }

        if (-not $issues -or $issues[-1] -notlike "${app}:*") {
            Write-WtfOk "  clean & pushed"
        }
    }

    if ($issues.Count -gt 0 -and -not $Force) {
        Write-WtfFail "Aborting due to: $($issues -join '; ')"
        Write-WtfDetail "Pass -Force to override (you will lose unpushed/uncommitted work)."
        return
    }
    if ($issues.Count -gt 0) {
        Write-WtfWarn "Forcing despite: $($issues -join '; ')"
    }

    # ── Confirm ───────────────────────────────────────────────────────
    if ($DryRun) {
        Write-WtfWarn "DRY RUN — would remove $featureDir and all worktrees."
        return
    }
    Write-WtfDetail "Committed+pushed work is safe in git. Local-only files (copied .env, graphify-out,"
    Write-WtfDetail "and anything gitignored you changed here) are NOT tracked and will be gone."
    if (-not (Read-WtfConfirm "Permanently remove feature '$Branch'?" $false)) {
        Write-WtfWarn "Cancelled."
        return
    }

    # ── Teardown ──────────────────────────────────────────────────────
    Write-WtfHeader "Teardown"
    Write-WtfDetail "If removal stalls, close any pane sitting inside this feature -"
    Write-WtfDetail "an open handle locks the files and Windows refuses the delete."
    $stuck = @()
    foreach ($w in $worktrees) {
        $app    = $w.Name
        $wtDir  = $w.Dir
        $appSrc = Join-Path $layout.MainDir $w.RelPath

        Write-WtfStep "$app"
        if (Test-WtfIsGitRepo $appSrc) {
            $r = Invoke-WtfGit -WorkingDir $appSrc -GitArgs @('worktree','remove','--force', $wtDir)
            if (-not $r.Ok) {
                # Usually a lock (VS Code / a terminal cwd'd into the worktree). git
                # may have already unlinked it, so finish by deleting the folder, then
                # prune the dangling registration.
                if ($r.Stderr -match 'Permission denied|being used|access') {
                    Write-WtfWarn "  files locked - close any pane sitting in this feature"
                } elseif ($r.Stderr -match 'too long') {
                    Write-WtfWarn "  git hit the 260-character path limit; deleting the folder here instead"
                } else {
                    Write-WtfWarn "  git worktree remove failed: $($r.Stderr)"
                }
                if (Test-Path $wtDir) { [void](Remove-WtfPath -Path $wtDir) }
            }
            Invoke-WtfWorktreePrune -RepoDir $appSrc
        } else {
            Write-WtfWarn "  source repo missing; cleaning files only"
            if (Test-Path $wtDir) { [void](Remove-WtfPath -Path $wtDir) }
        }

        if (Test-Path $wtDir) {
            $stuck += $app
            Write-WtfFail "  still present (locked): $wtDir"
        } else {
            Write-WtfOk "  removed"
        }
    }

    # ── Unlink dependency junctions FIRST (critical safety) ───────────
    # A recursive delete of the feature dir would otherwise follow a dep junction
    # and wipe the dep's MAIN checkout. Unlink each junction (target untouched)
    # before we ever recurse-delete the feature folder.
    foreach ($d in @($layout.Deps)) {
        if (Test-Path -LiteralPath $d.Dir) {
            if (Test-WtfIsReparsePoint $d.Dir) {
                $ok = Remove-WtfDepJunction -Link $d.Dir
                if ($ok) {
                    Write-WtfOk "  unlinked dep $($d.Name) (main checkout untouched)"
                } else {
                    Write-WtfWarn "  couldn't unlink dep $($d.Name); leaving it for final cleanup"
                }
            } else {
                # Defensive: a real folder where a junction was expected — do NOT
                # auto-delete it; leave it and warn so nothing real is lost.
                Write-WtfWarn "  dep $($d.Name) is a real folder, not a junction — leaving it"
            }
        }
    }

    # Final cleanup: feature folder, sidecar meta, and workspace file.
    # Belt-and-suspenders: never recurse THROUGH a leftover reparse point.
    if (Test-Path $featureDir) {
        Get-ChildItem -LiteralPath $featureDir -Force -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
            ForEach-Object { try { [System.IO.Directory]::Delete($_.FullName, $false) } catch { } }
        [void](Remove-WtfPath -Path $featureDir)
    }
    $metaPath = Get-WtfMetaPath $featureDir
    if (Test-Path $metaPath) { Remove-Item $metaPath -Force -ErrorAction SilentlyContinue }
    $legacyMeta = Join-Path $featureDir '.wtf-meta.json'
    if (Test-Path $legacyMeta) { Remove-Item $legacyMeta -Force -ErrorAction SilentlyContinue }
    # Clean up any .code-workspace left behind by the old VS Code flow.
    $legacyWs = Join-Path (Split-Path $featureDir -Parent) ((Split-Path $featureDir -Leaf) + '.code-workspace')
    if (Test-Path $legacyWs) { Remove-Item $legacyWs -Force -ErrorAction SilentlyContinue }

    if ($stuck.Count -gt 0) {
        Write-WtfSummary -Title "Partially removed: $Branch" -Color $script:T.Warn -Lines @(
            "$($script:T.Warn)Locked (still on disk):$($script:T.Reset) $($stuck -join ', ')",
            "$($script:T.Detail)Close any terminal pane sitting in those folders, then run ``wtf delete`` again$($script:T.Reset)",
            "$($script:T.Detail)(or ``wtf doctor -Fix`` to clean leftovers).$($script:T.Reset)"
        )
        return
    }

    # ── Optionally delete the local branch from each source repo ──────
    # The worktrees are gone but the branch refs remain. Offer to delete them.
    $branchRepos = @()
    foreach ($w in $worktrees) {
        $src = Join-Path $layout.MainDir $w.RelPath
        if (Test-WtfIsGitRepo $src) {
            $has = Invoke-WtfGit -WorkingDir $src -GitArgs @('show-ref','--verify','--quiet',"refs/heads/$Branch")
            if ($has.Ok) { $branchRepos += @{ Name = $w.Name; Src = $src } }
        }
    }
    if ($branchRepos.Count -gt 0) {
        if (Read-WtfConfirm "Also delete the local branch '$Branch' from $($branchRepos.Count) repo(s)?" $false) {
            foreach ($b in $branchRepos) {
                $d = Invoke-WtfGit -WorkingDir $b.Src -GitArgs @('branch','-D', $Branch)
                if ($d.Ok) { Write-WtfOk "  deleted $Branch in $($b.Name)" }
                else        { Write-WtfWarn "  couldn't delete in $($b.Name): $($d.Stderr)" }
            }
        }
    }

    Write-WtfSummary -Title "Deleted: $Branch" -Lines @(
        "$($script:T.Detail)All worktrees and the workspace file are gone.$($script:T.Reset)",
        "$($script:T.Detail)Remote branches (if pushed) are untouched — delete on the host if needed.$($script:T.Reset)"
    )
}

# ============================================================================
# COMMAND: wtf list
# ============================================================================

function Get-WtfActiveFeatures {
    <#
    .SYNOPSIS
        Scan worktree dirs across (optionally filtered) contexts/projects, return meta objects.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Context = '',
        [string]$Project = ''
    )
    $results = @()
    $ctxNames = if ($Context) { @($Context) } else { Get-WtfContextNames $Config }
    foreach ($cn in $ctxNames) {
        $ctx = Get-ObjectValue $Config.contexts $cn
        if (-not $ctx -or -not (Test-Path $ctx.worktreeDir)) { continue }

        # Each feature is identified by its sidecar <feature>.wtf-meta.json file.
        # featureDir = the file path minus the .wtf-meta.json suffix.
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $featureDirs = @()
        foreach ($mf in (Get-ChildItem $ctx.worktreeDir -Filter '*.wtf-meta.json' -File -ErrorAction SilentlyContinue)) {
            $fd = $mf.FullName.Substring(0, $mf.FullName.Length - '.wtf-meta.json'.Length)
            if ($seen.Add($fd)) { $featureDirs += $fd }
        }
        # Legacy: features whose meta still lives inside the folder.
        foreach ($d in (Get-ChildItem $ctx.worktreeDir -Directory -ErrorAction SilentlyContinue)) {
            if ((Test-Path (Join-Path $d.FullName '.wtf-meta.json')) -and $seen.Add($d.FullName)) {
                $featureDirs += $d.FullName
            }
        }

        foreach ($fd in $featureDirs) {
            $meta = Read-WtfMeta -FeatureDir $fd
            if (-not $meta) { continue }
            if ($Project -and $meta.project -ne $Project) { continue }
            $ftype = if ($meta.type) { $meta.type } elseif (@($meta.apps).Count -eq 0) { 'mono' } else { 'multi' }
            $results += [pscustomobject]@{
                Context    = $meta.context
                Project    = $meta.project
                Type       = $ftype
                Branch     = $meta.branch
                Apps       = @($meta.apps)
                Dir        = $fd
                CreatedAt  = $meta.createdAt
            }
        }
    }
    return $results
}

function Invoke-WtfList {
    Start-WtfLog 'list'
    Write-WtfBanner "list — active features"
    $config = Get-WtfConfig
    if (-not $config) { return }

    $features = Get-WtfActiveFeatures -Config $config
    if ($features.Count -eq 0) {
        Write-WtfDetail "No active features."
        return
    }

    # Collision detection: app appearing in multiple features
    $appUsage = @{}
    foreach ($f in $features) {
        foreach ($a in $f.Apps) {
            $key = "$($f.Context)/$($f.Project)/$a"
            if (-not $appUsage.ContainsKey($key)) { $appUsage[$key] = @() }
            $appUsage[$key] += $f.Branch
        }
    }
    $collisions = $appUsage.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 }

    foreach ($f in $features | Sort-Object Context, Project, Branch) {
        Write-WtfHeader "$($f.Context) / $($f.Project) — $($f.Branch)"

        # Status per worktree
        $apps = if ($f.Type -eq 'mono' -or $f.Apps.Count -eq 0) { @($f.Project) } else { $f.Apps }
        foreach ($a in $apps) {
            $wtDir = if ($f.Type -eq 'mono' -or $f.Apps.Count -eq 0) { $f.Dir } else { Join-Path $f.Dir $a }
            if (-not (Test-Path $wtDir)) {
                Write-WtfWarn "$a — folder missing"
                continue
            }
            $status   = Invoke-WtfGit -WorkingDir $wtDir -GitArgs @('status','--porcelain')
            $ahead    = Invoke-WtfGit -WorkingDir $wtDir -GitArgs @('rev-list','--count','@{u}..HEAD') 2>$null
            $behind   = Invoke-WtfGit -WorkingDir $wtDir -GitArgs @('rev-list','--count','HEAD..@{u}') 2>$null
            $tags = @()
            if ($status.Stdout) { $tags += "$($script:T.Warn)dirty$($script:T.Reset)" }
            if ($ahead.Ok -and [int]$ahead.Stdout -gt 0) { $tags += "$($script:T.Accent)↑$($ahead.Stdout)$($script:T.Reset)" }
            if ($behind.Ok -and [int]$behind.Stdout -gt 0) { $tags += "$($script:T.Warn)↓$($behind.Stdout)$($script:T.Reset)" }
            if ($tags.Count -eq 0) { $tags = @("$($script:T.Ok)clean$($script:T.Reset)") }
            _wtf_write "  · $($script:T.Bold)$a$($script:T.Reset)  $($tags -join ' ')"
        }

        Write-WtfDetail "$($f.Dir)"
    }

    if ($collisions.Count -gt 0) {
        Write-WtfHeader "Concurrent checkouts"
        foreach ($c in $collisions) {
            Write-WtfWarn "$($c.Key) is in: $($c.Value -join ', ')"
        }
    }
}

# ============================================================================
# COMMAND: wtf doctor
# ============================================================================

function Remove-WtfWorktreeFolder {
    <#
    .SYNOPSIS
        Delete a feature folder. If it's a linked git worktree (mono), remove it
        via its source repo so no dangling worktree ref is left behind.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path (Join-Path $Path '.git')) {
        $r = Invoke-WtfGit -WorkingDir $Path -GitArgs @('rev-parse','--path-format=absolute','--git-common-dir')
        if ($r.Ok -and $r.Stdout) {
            $srcRepo = Split-Path $r.Stdout -Parent   # <repo>/.git → <repo>
            $rr = Invoke-WtfGit -WorkingDir $srcRepo -GitArgs @('worktree','remove','--force', $Path)
            if ($rr.Ok) { Invoke-WtfWorktreePrune -RepoDir $srcRepo; return }
        }
    }
    if (Test-Path $Path) { [void](Remove-WtfPath -Path $Path) }
}

function Invoke-WtfDoctor {
    param([switch]$Fix)
    Start-WtfLog 'doctor'
    Write-WtfBanner "doctor — health check"
    $config = Get-WtfConfig
    if (-not $config) { return }

    $problems = @()

    foreach ($cn in Get-WtfContextNames $config) {
        $ctx = Get-ObjectValue $config.contexts $cn
        if (-not (Test-Path $ctx.worktreeDir)) { continue }
        Write-WtfHeader "Context: $cn"

        $features = @(Get-WtfActiveFeatures -Config $config -Context $cn)
        $validDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($f in $features) { [void]$validDirs.Add($f.Dir) }

        # Folders in worktreeDir with no backing meta = orphans (e.g. meta lost).
        foreach ($d in (Get-ChildItem $ctx.worktreeDir -Directory -ErrorAction SilentlyContinue)) {
            if (-not $validDirs.Contains($d.FullName)) {
                Write-WtfWarn "orphan folder (no meta): $($d.Name)"
                $problems += @{ Kind = 'orphan-folder'; Path = $d.FullName }
            }
        }

        # For each known feature, check its worktrees still exist; flag sidecars
        # whose folder is gone (leftover meta after a manual delete).
        foreach ($f in $features) {
            if (-not (Test-Path $f.Dir)) {
                Write-WtfWarn "orphan meta (folder gone): $(Split-Path $f.Dir -Leaf)"
                $problems += @{ Kind = 'orphan-meta'; Dir = $f.Dir }
                continue
            }
            $meta = Read-WtfMeta -FeatureDir $f.Dir
            $layout = Resolve-WtfFeatureLayout -Config $config -Meta $meta -FeatureDir $f.Dir
            foreach ($w in @($layout.Worktrees)) {
                if (-not (Test-Path $w.Dir)) {
                    Write-WtfWarn "missing worktree: $cn/$($f.Branch)/$($w.Name)"
                    $problems += @{ Kind = 'missing-worktree'; Branch = $f.Branch; App = $w.Name }
                }
            }
        }

        # Prune ghost worktrees across every discovered repo in this root.
        foreach ($cand in (Get-WtfRepoCandidates -MainDir $ctx.mainDir -WorktreeDir $ctx.worktreeDir)) {
            $r = Join-Path $ctx.mainDir $cand.RelPath
            if (Test-WtfIsGitRepo $r) { Invoke-WtfWorktreePrune -RepoDir $r }
        }
        Write-WtfOk "pruned ghost worktree records"

        # Orphan workspace files (no matching feature folder).
        foreach ($w in (Get-ChildItem $ctx.workspaceDir -Filter '*.code-workspace' -ErrorAction SilentlyContinue)) {
            $expectDir = Join-Path $ctx.worktreeDir $w.BaseName
            if (-not (Test-Path $expectDir)) {
                Write-WtfWarn "orphan workspace file: $($w.Name)"
                $problems += @{ Kind = 'orphan-workspace'; Path = $w.FullName }
            }
        }
    }

    if ($problems.Count -eq 0) {
        Write-WtfSummary -Title "All clear" -Lines @("$($script:T.Detail)No issues found.$($script:T.Reset)")
        return
    }

    if (-not $Fix) {
        Write-WtfDetail "Run ``wtf doctor -Fix`` to clean up the issues above."
        return
    }

    Write-WtfHeader "Repairs"
    foreach ($p in $problems) {
        switch ($p.Kind) {
            'orphan-folder' {
                if (Read-WtfConfirm "Delete orphan folder $($p.Path)? (git worktree removed cleanly)" $false) {
                    Remove-WtfWorktreeFolder -Path $p.Path
                    # Also drop a stale sidecar/workspace if they linger.
                    $mp = Get-WtfMetaPath $p.Path
                    if (Test-Path $mp) { Remove-Item $mp -Force -ErrorAction SilentlyContinue }
                    Write-WtfOk "removed"
                }
            }
            'orphan-meta' {
                if (Read-WtfConfirm "Delete leftover meta $(Get-WtfMetaPath $p.Dir)?" $false) {
                    $mp = Get-WtfMetaPath $p.Dir
                    if (Test-Path $mp) { Remove-Item $mp -Force -ErrorAction SilentlyContinue }
                    Write-WtfOk "removed"
                }
            }
            'orphan-workspace' {
                if (Read-WtfConfirm "Delete orphan workspace $($p.Path)?" $false) {
                    Remove-Item $p.Path -Force
                    Write-WtfOk "removed"
                }
            }
            'missing-worktree' {
                Write-WtfDetail "missing-worktree requires manual repair (re-run create/add)"
            }
        }
    }
}

# ============================================================================
# COMMAND: wtf config
# ============================================================================

function Invoke-WtfConfigOpen {
    if (-not (Test-Path $script:WtfConfig)) {
        Write-WtfFail "No config file yet — use the menu to create one."
        return
    }
    $editor = $env:EDITOR
    if (-not $editor) {
        if (Get-Command code -ErrorAction SilentlyContinue) { $editor = 'code' } else { $editor = 'notepad' }
    }
    Start-Process -FilePath $editor -ArgumentList @($script:WtfConfig) -ErrorAction SilentlyContinue
    Write-WtfOk "opened $script:WtfConfig in $editor"
}

# ── Sub-flow: add a context (root folder) ─────────────────────────────────
function Invoke-WtfConfigAddContext {
    $config = Get-WtfConfigOrEmpty
    if (-not $config) { return }
    Write-WtfHeader "Add a root folder"
    Write-WtfDetail "A root is a CATEGORY of work, not a single project. Repos inside it are auto-found."

    $name = Read-WtfText -Prompt "Root name" -Hint "e.g. personal, work — NOT a project name"
    if (-not $name) { return }
    if ((Test-ObjectHasKey $config 'contexts') -and (Test-ObjectHasKey $config.contexts $name)) {
        if (-not (Read-WtfConfirm "Context '$name' exists — overwrite its paths?" $false)) { return }
    }

    $mainDir = Read-WtfText -Prompt "Main folder (where your repos live)" `
                 -Validator { param($v) if (Test-Path $v) { $null } else { "Path not found: $v" } }
    if (-not $mainDir) { return }
    $mainDir = (Resolve-Path $mainDir).Path

    $leaf    = Split-Path $mainDir -Leaf
    $suggest = if ($leaf -ieq 'main') { Join-Path (Split-Path $mainDir -Parent) 'worktrees' } else { Join-Path $mainDir 'worktrees' }
    $wt = Read-WtfText -Prompt "Worktree folder (features live here)" -Default $suggest
    if (-not $wt) { return }
    if (-not (Test-Path $wt)) { New-Item -ItemType Directory -Path $wt -Force | Out-Null; Write-WtfOk "created $wt" }
    $wt = (Resolve-Path $wt).Path

    $ctxObj = [pscustomobject]@{
        mainDir      = $mainDir
        worktreeDir  = $wt
        workspaceDir = $wt
        projects     = [pscustomobject]@{}
    }
    if (-not (Test-ObjectHasKey $config 'contexts') -or -not $config.contexts) {
        $config | Add-Member -NotePropertyName contexts -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $config.contexts | Add-Member -NotePropertyName $name -NotePropertyValue $ctxObj -Force
    Save-WtfConfig $config
    Write-WtfOk "context '$name' added"

    $mono = @(Get-WtfMonoProjects $config $name)
    Write-WtfDetail "Discovered $($mono.Count) single repo(s): $($mono -join ', ')"
    Write-WtfDetail "Use ‘Define a multi-repo project’ to group repos like pigeon."
}

# ── Sub-flow: define a new multi-repo project ─────────────────────────────
function Invoke-WtfConfigDefineMulti {
    $config = Get-WtfConfigOrEmpty
    Write-WtfHeader "Add a multi-repo group"
    Write-WtfDetail "Bundle several repos under one name so they branch together (e.g. pigeon)."
    $ctxNames = @(Get-WtfContextNames $config)
    if ($ctxNames.Count -eq 0) { Write-WtfFail "No root folders yet — add one first."; return }
    $ctxName = if ($ctxNames.Count -eq 1) { $ctxNames[0] } else { Read-WtfChoice -Prompt "In which root" -Options $ctxNames }
    if (-not $ctxName) { return }
    $ctx = Get-WtfContextObj $config $ctxName

    $members = Get-WtfGroupMemberPaths $config $ctxName
    $cands = @(Get-WtfRepoCandidates -MainDir $ctx.mainDir -WorktreeDir $ctx.worktreeDir |
               Where-Object { -not $members.Contains($_.RelPath) })
    if ($cands.Count -eq 0) { Write-WtfFail "No unused repos found under $($ctx.mainDir)."; return }

    $name = Read-WtfText -Prompt "Group name" -Hint "e.g. pigeon"
    if (-not $name) { return }
    $name = ConvertTo-WtfSafeName $name

    $byLabel = @{}
    $labels  = foreach ($c in $cands) { $byLabel[$c.RelPath] = $c; $c.RelPath }
    $picked  = Read-WtfMultiChoice -Prompt "Repos in '$name'" -Options @($labels) -Min 1
    if (@($picked).Count -eq 0) { Write-WtfWarn "Cancelled."; return }

    $map = New-WtfShortNameMap -Candidates @(foreach ($l in $picked) { $byLabel[$l] })
    Write-WtfHeader "Preview"
    foreach ($k in $map.Keys) { Write-WtfInfo "$k → $($map[$k])" }
    if (-not (Read-WtfConfirm "Save project '$name'?" $true)) { return }
    if (Save-WtfMultiProject -Context $ctxName -Name $name -AppMap $map) {
        Write-WtfOk "saved '$name'"
    }
}

# ── Sub-flow: edit / rename a multi-repo project ──────────────────────────
function Get-WtfAllMultiItems {
    param($Config)
    $items = @()
    foreach ($cn in (Get-WtfContextNames $Config)) {
        foreach ($pn in (Get-WtfMultiProjectNames $Config $cn)) {
            $items += [pscustomobject]@{ Ctx = $cn; Name = $pn }
        }
    }
    return @($items)
}

function Invoke-WtfConfigEditMulti {
    $config = Get-WtfConfigOrEmpty
    $items = Get-WtfAllMultiItems $config
    if ($items.Count -eq 0) { Write-WtfWarn "No multi-repo projects to edit."; return }
    $labels = $items | ForEach-Object { "$($_.Ctx) / $($_.Name)" }
    $pick = Read-WtfChoice -Prompt "Edit which project" -Options @($labels)
    if (-not $pick) { return }
    $it = $items[[Array]::IndexOf($labels, $pick)]
    $ctx  = Get-WtfContextObj $config $it.Ctx
    $proj = Get-ObjectValue $ctx.projects $it.Name
    $curMap = Get-WtfProjectApps $proj
    $curPaths = @($curMap.Values)

    $newName = Read-WtfText -Prompt "Name" -Default $it.Name
    $newName = ConvertTo-WtfSafeName $newName

    # Candidates = all repos except those claimed by OTHER groups; current ones preselected.
    $otherMembers = Get-WtfGroupMemberPaths $config $it.Ctx
    foreach ($p in $curPaths) { [void]$otherMembers.Remove($p) }
    $cands = @(Get-WtfRepoCandidates -MainDir $ctx.mainDir -WorktreeDir $ctx.worktreeDir |
               Where-Object { -not $otherMembers.Contains($_.RelPath) })
    $byLabel = @{}
    $labels2 = foreach ($c in $cands) { $byLabel[$c.RelPath] = $c; $c.RelPath }
    $picked  = Read-WtfMultiChoice -Prompt "Repos in '$newName'" -Options @($labels2) -Preselected @($curPaths) -Min 1
    if (@($picked).Count -eq 0) { Write-WtfWarn "Cancelled."; return }
    $map = New-WtfShortNameMap -Candidates @(foreach ($l in $picked) { $byLabel[$l] })

    # Apply in-memory then save once (avoids stale-reload double-write).
    $ctx.projects.PSObject.Properties.Remove($it.Name)
    Set-WtfMultiProjectOn -Config $config -Context $it.Ctx -Name $newName -AppMap $map | Out-Null
    Save-WtfConfig $config
    Write-WtfOk "updated → '$newName'"
}

# ── Sub-flow: remove a multi-repo project (worktrees untouched) ───────────
function Invoke-WtfConfigRemoveMulti {
    $config = Get-WtfConfigOrEmpty
    $items = Get-WtfAllMultiItems $config
    if ($items.Count -eq 0) { Write-WtfWarn "No multi-repo projects to remove."; return }
    $labels = $items | ForEach-Object { "$($_.Ctx) / $($_.Name)" }
    $pick = Read-WtfChoice -Prompt "Remove which project" -Options @($labels)
    if (-not $pick) { return }
    $it = $items[[Array]::IndexOf($labels, $pick)]
    if (-not (Read-WtfConfirm "Remove group '$($it.Name)' from '$($it.Ctx)'? (repos/worktrees untouched)" $false)) { return }
    $ctx = Get-WtfContextObj $config $it.Ctx
    $ctx.projects.PSObject.Properties.Remove($it.Name)
    Save-WtfConfig $config
    Write-WtfOk "removed group '$($it.Name)' — its repos now show as single projects again"
}

# ── Sub-flow: show discovered + configured layout ─────────────────────────
function Invoke-WtfConfigShow {
    $config = Get-WtfConfigOrEmpty
    $ctxNames = @(Get-WtfContextNames $config)
    if ($ctxNames.Count -eq 0) { Write-WtfDetail "No contexts yet. Choose ‘Add a context’."; return }
    foreach ($cn in $ctxNames) {
        $ctx = Get-WtfContextObj $config $cn
        Write-WtfHeader "$cn"
        Write-WtfDetail "main:      $($ctx.mainDir)"
        Write-WtfDetail "worktrees: $($ctx.worktreeDir)"
        $multi = @(Get-WtfMultiProjectNames $config $cn)
        $mono  = @(Get-WtfMonoProjects $config $cn)
        if ($multi.Count -gt 0) {
            Write-WtfInfo "Multi-repo projects:"
            foreach ($pn in $multi) {
                $apps = Get-WtfProjectApps (Get-WtfProjectConfig $config $cn $pn)
                _wtf_write "    · $($script:T.Bold)$pn$($script:T.Reset)  $($script:T.Detail)($(@($apps.Keys) -join ', '))$($script:T.Reset)"
            }
        }
        Write-WtfInfo "Single repos (auto): $(if ($mono.Count) { $mono -join ', ' } else { '(none)' })"
    }
}

# ── Sub-flow: rename a root folder (context) ──────────────────────────────
function Invoke-WtfConfigRenameContext {
    $config = Get-WtfConfigOrEmpty
    $names = @(Get-WtfContextNames $config)
    if ($names.Count -eq 0) { Write-WtfWarn "No root folders to rename."; return }
    $old = if ($names.Count -eq 1) { $names[0] } else { Read-WtfChoice -Prompt "Rename which root" -Options $names }
    if (-not $old) { return }
    $new = Read-WtfText -Prompt "New name" -Default $old
    if (-not $new -or $new -eq $old) { Write-WtfWarn "Unchanged."; return }
    if (Test-ObjectHasKey $config.contexts $new) { Write-WtfFail "Root '$new' already exists."; return }

    $obj = Get-ObjectValue $config.contexts $old
    $config.contexts | Add-Member -NotePropertyName $new -NotePropertyValue $obj -Force
    $config.contexts.PSObject.Properties.Remove($old)
    Save-WtfConfig $config

    # Keep existing features consistent: their meta records the old root name.
    if ($obj -and (Test-Path $obj.worktreeDir)) {
        foreach ($d in (Get-ChildItem $obj.worktreeDir -Directory -ErrorAction SilentlyContinue)) {
            $m = Read-WtfMeta -FeatureDir $d.FullName
            if ($m -and $m.context -eq $old) {
                $m.context = $new
                Save-WtfMeta -FeatureDir $d.FullName -Meta $m
            }
        }
    }
    Write-WtfOk "renamed root '$old' → '$new'"
}

# ── Sub-flow: remove a root folder (config only; nothing on disk touched) ──
function Invoke-WtfConfigRemoveContext {
    $config = Get-WtfConfigOrEmpty
    $names = @(Get-WtfContextNames $config)
    if ($names.Count -eq 0) { Write-WtfWarn "No root folders to remove."; return }
    $pick = if ($names.Count -eq 1) { $names[0] } else { Read-WtfChoice -Prompt "Remove which root" -Options $names }
    if (-not $pick) { return }
    if (-not (Read-WtfConfirm "Forget root '$pick'? (config only — your folders & repos are untouched)" $false)) { return }
    $config.contexts.PSObject.Properties.Remove($pick)
    Save-WtfConfig $config
    Write-WtfOk "removed root '$pick' from config"
}

# ── Interactive config menu ───────────────────────────────────────────────
function Invoke-WtfConfig {
    param([string]$Sub = '')
    Start-WtfLog 'config'
    if ($Sub -in @('edit','open','json')) { Invoke-WtfConfigOpen; return }

    Write-WtfBanner "config"
    if (-not (Test-Path $script:WtfConfig)) {
        Write-WtfDetail "No config yet — start with ‘Add a root folder’."
    }
    Write-WtfDetail "A root = a folder full of repos (personal, work). Repos inside it are found automatically."
    Write-WtfDetail "A multi-repo group = repos you bundle under one name (e.g. pigeon)."

    $ADDR='Add a root folder            (e.g. personal, work)'
    $DEF ='Add a multi-repo group       (e.g. pigeon)'
    $EDT ='Edit a multi-repo group'
    $RMV ='Remove a multi-repo group'
    $RNR ='Rename a root folder'
    $RMR ='Remove a root folder'
    $SHW ='Show everything'
    $OPN ='Open config.json (advanced)'
    $EXT ='Exit'
    while ($true) {
        $pick = Read-WtfChoice -Prompt "What do you want to do?" -Options @($ADDR,$DEF,$EDT,$RMV,$RNR,$RMR,$SHW,$OPN,$EXT)
        switch ($pick) {
            $ADDR   { Invoke-WtfConfigAddContext }
            $DEF    { Invoke-WtfConfigDefineMulti }
            $EDT    { Invoke-WtfConfigEditMulti }
            $RMV    { Invoke-WtfConfigRemoveMulti }
            $RNR    { Invoke-WtfConfigRenameContext }
            $RMR    { Invoke-WtfConfigRemoveContext }
            $SHW    { Invoke-WtfConfigShow }
            $OPN    { Invoke-WtfConfigOpen }
            default { return }   # Exit or Escape
        }
        [Console]::Out.WriteLine()
    }
}

# ============================================================================
# DISPATCHER — `wtf <subcommand> ...args`
# ============================================================================

function Show-WtfHelp {
    Write-WtfBanner "WorkTree Flow"
    Write-WtfInfo "Worktrees"
    Write-WtfDetail "  wtf create  [ctx proj branch apps...] [--dry-run]   make worktrees, then print the paths"
    Write-WtfDetail "  wtf add     [ctx proj branch apps...] [--dry-run]   add repos/deps to a feature"
    Write-WtfDetail "  wtf remove  [ctx proj branch apps...] [--force]     drop repos/deps from a feature"
    Write-WtfDetail "  wtf delete  [ctx proj branch] [--force] [--dry-run] tear a whole feature down"
    Write-WtfDetail "  wtf list                                            every active feature"
    Write-WtfDetail "  wtf status  [ctx proj branch]                       git state + plan progress"
    Write-WtfDetail "  wtf doctor  [--fix]                                 find and repair leftovers"
    Write-WtfDetail "  wtf config                                          set up roots and repo groups"
    Write-WtfDetail ""
    Write-WtfInfo "Tab layouts"
    Write-WtfDetail "  wtf snap    [name]                                  save THIS tab's panes as a layout"
    Write-WtfDetail "  wtf tab ls                                          list saved layouts"
    Write-WtfDetail "  wtf tab open [name]                                 rebuild a layout in a new tab"
    Write-WtfDetail "  wtf tab edit [name]                                 edit a layout's commands"
    Write-WtfDetail "  wtf tab rm  [name]                                  delete a layout"
    Write-WtfDetail "  wtf hotkey install                                  ALT+SHIFT+S snap, ALT+SHIFT+O open"
    Write-WtfDetail "  wtf hotkey status | remove [snap|open]              inspect or drop the hotkeys"
    Write-WtfDetail ""
    Write-WtfDetail "Leave a name out and you get a picker that DRAWS each layout."
    Write-WtfDetail "A pane command can run on open, or just be typed at the prompt ready to go."
    Write-WtfDetail "wtf create only prints paths - you arrange your own panes, then wtf snap saves them."
}

function wtf {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments=$true)][string[]]$Words
    )

    # Flags may appear in ANY position. Pull them out first, then read what is
    # left positionally: action arg1 arg2 arg3 ...
    $pos    = @()
    $force  = $false
    $dryRun = $false
    $fix    = $false
    $fg     = $false
    $noMe   = $false
    foreach ($w in @($Words)) {
        switch -Regex ($w) {
            '^--force$'      { $force  = $true }
            '^-Force$'       { $force  = $true }
            '^--dry-run$'    { $dryRun = $true }
            '^-DryRun$'      { $dryRun = $true }
            '^--fix$'        { $fix    = $true }
            '^-Fix$'         { $fix    = $true }
            '^--foreground$' { $fg     = $true }
            '^--without-me$' { $noMe   = $true }
            default          { $pos   += $w }
        }
    }
    $Action  = $pos[0]
    $Context = $pos[1]
    $Project = $pos[2]
    $Branch  = $pos[3]
    $apps    = if ($pos.Count -gt 4) { @($pos[4..($pos.Count - 1)]) } else { @() }

    if (-not $Action) { Show-WtfHelp; return }

    switch ($Action.ToLower()) {
        # -- worktrees ------------------------------------------------------
        'create' { Invoke-WtfCreate -Context $Context -Project $Project -Branch $Branch -Apps $apps -DryRun:$dryRun }
        'add'    { Invoke-WtfAdd    -Context $Context -Project $Project -Branch $Branch -Apps $apps -DryRun:$dryRun }
        'remove' { Invoke-WtfRemove -Context $Context -Project $Project -Branch $Branch -Apps $apps -Force:$force -DryRun:$dryRun }
        'rm'     { Invoke-WtfRemove -Context $Context -Project $Project -Branch $Branch -Apps $apps -Force:$force -DryRun:$dryRun }
        'delete' { Invoke-WtfDelete -Context $Context -Project $Project -Branch $Branch -Force:$force -DryRun:$dryRun }
        'del'    { Invoke-WtfDelete -Context $Context -Project $Project -Branch $Branch -Force:$force -DryRun:$dryRun }
        'list'   { Invoke-WtfList }
        'ls'     { Invoke-WtfList }
        'status' { Invoke-WtfStatus -Context $Context -Project $Project -Branch $Branch }
        'doctor' { Invoke-WtfDoctor -Fix:$fix }
        'config' { Invoke-WtfConfig -Sub $Context }

        # -- tab layouts ----------------------------------------------------
        'snap'   { Invoke-WtfSnap    -Name $Context -Foreground:$fg -WithoutMe:$noMe }
        'tab'    { Invoke-WtfTab     -Sub  $Context -Name $Project }
        'tabs'   { Invoke-WtfTab     -Sub  'ls' }
        'hotkey' { Invoke-WtfHotkey  -Sub  $Context -Action $Project -Combo $Branch }
        'open'   { Invoke-WtfTabOpen -Name $Context }
        'edit'   { Invoke-WtfTabEdit -Name $Context }

        'help'   { Show-WtfHelp }
        default  { Write-WtfFail "Unknown command: $Action"; Show-WtfHelp }
    }
}

# ============================================================================
# TAB LAYOUTS
# ============================================================================
# Capture and restore of Windows Terminal tab layouts lives in its own files so
# the worktree engine above stays independent of it.

$script:WtfHere = Split-Path -Parent $PSCommandPath
foreach ($mod in @('wtf-layout.ps1', 'wtf-map.ps1', 'wtf-tab.ps1', 'wtf-hotkey.ps1')) {
    $modPath = Join-Path $script:WtfHere $mod
    if (Test-Path $modPath) { . $modPath }
    else { Write-Warning "wtf: missing module $mod" }
}

# Done. Source this file from $PROFILE.