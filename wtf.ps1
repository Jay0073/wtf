# wtf.ps1 — WorkTree Flow orchestrator (Part 1: Foundation)
# Requires: PowerShell 7+, Windows Terminal, Git 2.5+, VS Code on PATH
#
# Install:
#   1. Create folder: C:\Users\<you>\.wtf\
#   2. Put config.json inside it
#   3. Dot-source from your $PROFILE:
#        . "$env:USERPROFILE\.wtf\wtf.ps1"
#   4. Reload: . $PROFILE

#Requires -Version 7.0

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
    Prompt   = "`e[38;5;81m"     # cyan-ish
    Ok       = "`e[38;5;42m"     # green
    Warn     = "`e[38;5;215m"    # amber
    Fail     = "`e[38;5;203m"    # red
    Detail   = "`e[38;5;245m"    # muted gray
    Header   = "`e[38;5;141m"    # purple
    Accent   = "`e[38;5;111m"    # soft blue
    Dim      = "`e[2m"
    Bold     = "`e[1m"
    Italic   = "`e[3m"
    Underline= "`e[4m"
    Reset    = "`e[0m"
    # Premium-TUI extras: a faint selection backdrop + a bright rail for the
    # active row. Used by the upgraded pickers; nothing else depends on them.
    SelBg    = "`e[48;5;236m"    # subtle dark-gray row highlight
    Rail     = "`e[38;5;212m"    # pink-ish accent rail (▌) on the active row
    Faint    = "`e[38;5;240m"    # fainter than Detail, for glyph rails / hints
    # Cursor / line control
    HideCur  = "`e[?25l"
    ShowCur  = "`e[?25h"
    ClearLn  = "`e[2K`r"
    Up       = "`e[1A"
}

# Tab colors for Windows Terminal
$script:TabColors = @{
    Agent      = '#7C3AED'
    Planner    = '#F59E0B'
    RunnerFeat = '#10B981'
    RunnerMain = '#6B7280'
}

# ── Agentic terminal "slots" ────────────────────────────────────────────────
# A slot = one agentic terminal tab/pane tied to one CLI session. Slots are
# stored per-feature in .wtf-meta.json and are CLI-agnostic: each slot carries
# the FULL launch/resume command (session id included) that you paste in. wtf's
# only job is to spawn the tab/pane and run that command verbatim — it never
# touches whatever the CLI prompts next.
#
# Each role has: a glyph (tab title), a tab color, and a layout rule that the
# launcher hardcodes. The two default executors share ONE tab as side-by-side
# panes (exec-1 left, exec-2 right); the planner and any other role get their
# own tab.
$script:WtfRoles = [ordered]@{
    planner    = @{ Label = 'planner';          Glyph = '🧠'; Color = '#F59E0B'; Layout = 'tab' }       # orange
    'root-exec'= @{ Label = 'root executor';    Glyph = '🤖'; Color = '#3B82F6'; Layout = 'pane-exec' } # blue
    freeform   = @{ Label = 'freeform executor';Glyph = '🦾'; Color = '#A855F7'; Layout = 'tab' }       # purple
    researcher = @{ Label = 'researcher';        Glyph = '🔬'; Color = '#14B8A6'; Layout = 'tab' }       # teal
    custom     = @{ Label = 'custom';            Glyph = '⌨'; Color = '#6B7280'; Layout = 'tab' }       # gray
}

# Only this layout shares ONE tab as side-by-side panes; every other layout is
# its own tab. Centralized so the launcher + previews agree on what "an executor
# pane" is.
$script:WtfPaneLayout = 'pane-exec'

# The fresh-feature default executor count (a planner is always added on top).
# `wtf create` lets you raise/lower this per feature based on task size.
$script:WtfDefaultExecCount = 2

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
    return ($S -replace "`e\[[\d;]*m", '').Length
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
        if ($S[$i] -eq "`e") {
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
    param([int]$Lines)
    if ($Lines -le 0) { return }
    for ($i = 0; $i -lt $Lines; $i++) {
        [Console]::Out.Write("$($script:T.Up)$($script:T.ClearLn)")
    }
}

# Premium picker primitives — a left accent rail + subtle row highlight give the
# menus a TUI feel (Gemini/antigravity-ish) without any new dependency. Every
# picker reuses these so the look stays consistent.
function _wtf_pick_header {
    param([string]$Prompt, [string]$Hint)
    $T = $script:T
    $hint = if ($Hint) { "  $($T.Faint)$Hint$($T.Reset)" } else { '' }
    [Console]::Out.WriteLine("$($T.Accent)❯$($T.Reset) $($T.Bold)$Prompt$($T.Reset)$hint")
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
    if ($Active) {
        $rail = "$($T.Rail)▌$($T.Reset)"
        $body = "$($T.SelBg)$($T.Bold)$g$Text$($T.Reset)"
        $d    = if ($Desc) { "$($T.SelBg)$($T.Detail)  $Desc$($T.Reset)" } else { '' }
        [Console]::Out.WriteLine("$rail $body$d")
    } else {
        $body = "$($T.Detail)$g$Text$($T.Reset)"
        $d    = if ($Desc) { "$($T.Faint)  $Desc$($T.Reset)" } else { '' }
        [Console]::Out.WriteLine("  $body$d")
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

function Get-WtfWorkspacePath {
    param($Config, [string]$Context, [string]$Project, [string]$Branch)
    $ctx = Get-ObjectValue $Config.contexts $Context
    Join-Path $ctx.workspaceDir "$Project-$(ConvertTo-WtfSafeName $Branch).code-workspace"
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
    # PS7's ArgumentList works correctly
    foreach ($a in $GitArgs) { $psi.ArgumentList.Add($a) }

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
        artifacts (_PLAN.md, .wtf-meta.json) are git-ignored without ever editing
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
        $top = ($rel -split '[\\/]')[0]
        if ($skipSet.Contains($top)) { continue }

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
        [string[]]$Apps,
        $AppPaths = @{},      # short -> relPath (multi only)
        $Deps = @(),          # array of @{ name; path }  (workspace-only repos)
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
        apps          = @($Apps)
        appPaths      = $AppPaths
        deps          = @($Deps)
        panes         = $Panes
        slots         = @($Slots)          # empty for a fresh feature — born in `wtf edit`
        archivedSlots = @($ArchivedSlots)
        createdAt     = (Get-Date -Format o)
    }
}

# ── Slot helpers ────────────────────────────────────────────────────────────

function New-WtfSlot {
    <#
    .SYNOPSIS
        Build one slot object. $Command is the FULL launch/resume command (with
        the session id baked in) that wtf runs verbatim; empty = "open the tab
        but don't auto-run anything" (you start it yourself).
    #>
    param(
        [Parameter(Mandatory)][string]$Role,   # key of $script:WtfRoles
        [Parameter(Mandatory)][string]$Name,   # short label -> tab title
        [string]$Command = ''
    )
    @{ role = $Role; name = $Name; command = $Command }
}

function New-WtfSuggestedSlots {
    <#
    .SYNOPSIS
        The SUGGESTED roster for a fresh feature: one planner + N root executors
        (exec-1..exec-N). These are only suggestions the first-time `wtf edit`
        walk-through pre-fills — they are NOT saved until you give each a real
        resume command. We never persist empty slots.
    #>
    param([int]$Executors = -1)
    if ($Executors -lt 0) { $Executors = $script:WtfDefaultExecCount }
    if ($Executors -lt 0) { $Executors = 0 }
    $out = @( @{ role = 'planner'; name = 'plan' } )
    for ($i = 1; $i -le $Executors; $i++) {
        $out += @{ role = 'root-exec'; name = "exec-$i" }
    }
    return $out
}

function Get-WtfRoleInfo {
    # Role descriptor, falling back to 'custom' for anything unknown so a
    # hand-edited meta or a future role never crashes the launcher.
    param([string]$Role)
    if ($Role -and $script:WtfRoles.Contains($Role)) { return $script:WtfRoles[$Role] }
    return $script:WtfRoles['custom']
}

function _wtf_normalize_slots {
    # Shared parser for both active + archived slot arrays from a meta property.
    param($Raw)
    $out = @()
    foreach ($s in @($Raw)) {
        if (-not $s) { continue }
        $cmd = if (Test-ObjectHasKey $s 'command') { [string](Get-ObjectValue $s 'command') } else { '' }
        # Invariant: only real sessions are stored. Skip any empty stragglers
        # (e.g. from an older meta) so they never spawn or show up.
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
        $rec = @{
            role    = [string](Get-ObjectValue $s 'role')
            name    = [string](Get-ObjectValue $s 'name')
            command = $cmd
        }
        if (Test-ObjectHasKey $s 'archivedAt') { $rec.archivedAt = [string](Get-ObjectValue $s 'archivedAt') }
        $out += $rec
    }
    return $out
}

function Get-WtfSlots {
    <#
    .SYNOPSIS
        The feature's ACTIVE agent slots (every one has a real command). A fresh
        feature has none — slots are only born in `wtf edit`. No default seeding.
    #>
    param($Meta)
    $raw = if ($Meta -and (Test-ObjectHasKey $Meta 'slots')) { Get-ObjectValue $Meta 'slots' } else { $null }
    return @(_wtf_normalize_slots $raw)
}

function Get-WtfArchivedSlots {
    <#
    .SYNOPSIS
        The feature's ARCHIVED sessions — real sessions you set aside ("not
        using") but kept so you can review / reopen them later via `wtf sessions`.
    #>
    param($Meta)
    $raw = if ($Meta -and (Test-ObjectHasKey $Meta 'archivedSlots')) { Get-ObjectValue $Meta 'archivedSlots' } else { $null }
    return @(_wtf_normalize_slots $raw)
}

function Get-WtfSlotTitle {
    # The tab/pane title for a slot: "<glyph> <name>".
    param($Slot)
    $info = Get-WtfRoleInfo $Slot.role
    return "$($info.Glyph) $($Slot.name)"
}

function Get-WtfExecutorNames {
    # Names of the executor slots (the pane-exec roles) in declared order. This
    # is the live executor roster — drives the per-executor .plan/ folders and
    # the plan's assignment table.
    param($Slots)
    return @(foreach ($s in @($Slots)) { if ((Get-WtfRoleInfo $s.role).Layout -eq $script:WtfPaneLayout) { $s.name } })
}

function Set-WtfMetaSlots {
    <#
    .SYNOPSIS
        Write the active + archived slot arrays onto a meta object (in place),
        coping with both hashtable (freshly built) and PSCustomObject (from disk).
    #>
    param(
        [Parameter(Mandatory)]$Meta,
        [Parameter(Mandatory)][AllowEmptyCollection()]$Active,
        [AllowEmptyCollection()]$Archived = @()
    )
    if ($Meta -is [hashtable]) {
        $Meta.slots = @($Active)
        $Meta.archivedSlots = @($Archived)
    } else {
        $Meta | Add-Member -NotePropertyName slots -NotePropertyValue (@($Active)) -Force
        $Meta | Add-Member -NotePropertyName archivedSlots -NotePropertyValue (@($Archived)) -Force
    }
    return $Meta
}

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
        foreach ($app in @($Meta.apps)) {
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
        $deps += @{ Name = $dname; RelPath = $dpath; Dir = (Join-Path $mainDir $dpath) }
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
# WORKSPACE FILE
# ============================================================================

function Write-WtfWorkspace {
    <#
    .SYNOPSIS
        Write a .code-workspace spanning the feature's worktrees plus any
        dependency repos (which point at their main checkout, not a worktree).
    #>
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$FeatureDir,
        [Parameter(Mandatory)]$Worktrees,        # array of @{ Name; Dir }
        $Deps = @(),                             # array of @{ Name; Dir }
        [string[]]$IgnoreRepos = @(),            # source main-checkouts to hide as phantoms
        [string]$PlanRelative = '_PLAN.md'
    )
    # Folders are addressed relative to the workspace file's location.
    $wsParent = Split-Path $WorkspacePath -Parent
    $rel = { param($abs) [System.IO.Path]::GetRelativePath($wsParent, $abs) -replace '\\','/' }

    $list = @($Worktrees)
    # Mono = the single worktree IS the feature dir. Its repo root already holds
    # _PLAN.md, so one folder (the repo) is enough — no separate "plan" folder.
    $isMono = ($list.Count -eq 1 -and $list[0].Dir -eq $FeatureDir)

    $allFolders = @()
    if (-not $isMono) {
        # Multi: point the plan folder at .plan/ specifically. Pointing it at the
        # feature root would make VS Code also render the worktree subfolders as
        # children of "plan" (duplicating them). .plan/ holds only _PLAN.md.
        $planDir = Join-Path $FeatureDir '.plan'
        if (-not (Test-Path $planDir)) { New-Item -ItemType Directory -Path $planDir -Force | Out-Null }
        $allFolders += @{ name = "📋 plan"; path = (& $rel $planDir) }
    }
    # 🌿 = a branched worktree (you develop + commit here, on the feature branch).
    # 📦 = a dependency repo shown at its MAIN checkout (read-along, not branched).
    foreach ($w in $list)  { $allFolders += @{ name = "🌿 $($w.Name)"; path = (& $rel $w.Dir) } }
    foreach ($d in $Deps)  { $allFolders += @{ name = "📦 $($d.Name)"; path = (& $rel $d.Dir) } }

    # Each worktree is its own repo — VS Code shows them all (good: commit/push
    # per repo). But it ALSO follows a worktree's .git link and surfaces its
    # SOURCE main-checkout as a phantom repo. Ignoring those source paths hides
    # the phantoms while keeping the worktree repos AND the dep repos visible.
    $settings = @{ 'window.title' = '${rootName} — wtf' }
    $ignore = @($IgnoreRepos | Where-Object { $_ } | ForEach-Object { $_ -replace '\\','/' } | Select-Object -Unique)
    if ($ignore.Count -gt 0) { $settings['git.ignoredRepositories'] = $ignore }

    $ws = @{ folders = $allFolders; settings = $settings }
    Write-WtfJson -Path $WorkspacePath -Object $ws
}

# ============================================================================
# _PLAN.md SCAFFOLD
# ============================================================================

function Write-WtfPlan {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string[]]$Apps,
        [string]$Project = '',
        [string[]]$Executors = @('exec-1','exec-2')   # executor slot names the planner assigns to
    )
    $appList = ($Apps | ForEach-Object { "- ``$_``" }) -join "`n"
    # Per-executor assignment table the planner fills in. Each executor has its
    # own folder under .plan/ for detailed task breakdowns.
    $execLines = ($Executors | ForEach-Object { "- **``$_``** — _assigned: (planner fills in)_  ·  details: ``.plan/$_/tasks.md``" }) -join "`n"
    $execCount = @($Executors).Count
    # Literal here-string (no interpolation) so markdown backticks stay literal;
    # dynamic values are injected via token replacement below.
    $tpl = @'
# Feature: {{BRANCH}}

**Project:** {{PROJECT}}  ·  **Worktrees in scope:** {{APPS}}  ·  **Created:** {{DATE}}

> Single source of truth for this feature. A fresh agent session should read
> this file first to resume with full context.

---

<!-- ════════════════ CO-PLANNER BRIEF — your operating rules, KEEP THIS ════════════════
     This block tells the planning agent how to behave. Unlike a throwaway brief,
     KEEP it: a fresh planner session must read it to know the rules. Below it is
     the living plan you maintain. -->

## ▶ Co-planner operating rules (read this first, every session — do NOT delete)

You are my **co-planner** for this feature, working in a wtf multi-repo workspace.
You are not a passive plan-writer and you are **not** an implementer. Think of
yourself as a sharp thinking partner sitting beside me:

- I bring ideas, constraints, and scenarios. You **pressure-test** them: argue the
  opposite side, surface failure modes, name the trade-offs I'm not seeing, and
  tell me when an idea is worse than it looks. When I'm wrong, say so and why.
- When you propose something, also give the strongest case **against** it. Hold
  both sides until we decide together. Don't rubber-stamp.
- Plan against MY stated constraints and scenarios — not a generic ideal. If a
  constraint makes the clean approach impossible, say that explicitly and offer
  the least-bad alternative.

**What you may touch — hard rule.** You **READ anything** in this workspace (every
`🌿` worktree, dependency repos, docs, configs) to understand the system. You
**WRITE only** to `_PLAN.md` and the `.plan/` folder. You do **not** edit feature
code, run migrations, or change anything in the repos. Implementation is the
executors' job. If you catch yourself about to edit a repo file, stop and write
the instruction into a plan instead.

**Your executors.** This feature was created with {{EXECCOUNT}} executor(s):
{{EXECNAMES}}. Each executor is a **root-level** agent — it sees every worktree in
the workspace (frontend + backend at once), so it implements a whole vertical
slice across repos coherently. **You split work by sub-feature, never by repo**,
and give each sub-feature to one executor so two executors never edit the same
area simultaneously.

> ⚠️ The executor set can CHANGE. I may add a third executor, a researcher, or
> drop one between sessions — and a past planner session won't know. So **never
> assume the list above is current**: at the start of each session, list the
> `.plan/` directory and treat **every `.plan/<name>/` subfolder as one executor
> you must plan for**. Create a `.plan/<name>/tasks.md` for any executor folder
> that lacks one, and update the assignment table below to match what actually
> exists.

**How you hand off work.**
- Keep THIS file (`_PLAN.md`) as the shared source of truth: goal, research,
  decisions, the overall plan, and the **Executor Assignments** table.
- Put each executor's detailed, ordered tasks in `.plan/<executor>/tasks.md`. Keep
  it self-contained so a fresh executor session can resume from that file alone.
- Whenever you (re)assign, update the assignment table so who-owns-what is obvious.

**Your working loop each session:**

1. **Re-read context.** This file, then `ls .plan/` to learn the CURRENT executor
   set, then the relevant `🌿` worktrees. Reconcile the assignment table with the
   folders that actually exist.
2. **Understand the goal.** If the Goal below is empty or vague, ask me — don't
   invent scope. Explore the repos for stack, conventions, and where this touches.
3. **Research, don't trust memory.** Web-search current docs/APIs, prior art, and
   pitfalls; prefer primary sources; verify versions against the repo. Log sources
   under **Research & References**.
4. **Ideate ↔ critique with me.** Offer 2–3 approaches with pros/cons/risk/blast
   radius, and your honest recommendation plus its weakest point. Decide together;
   record the call and the rejected options under **Decisions**.
5. **Decompose for parallelism.** Size sub-features so each executor owns one
   without stepping on another; note ordering deps (e.g. backend contract before
   frontend wiring).
6. **Write it down.** Fill the sections below with concrete, checkable steps, and
   write each executor's `.plan/<executor>/tasks.md`.

**Quality bar:** a fresh executor session should execute its
`.plan/<executor>/tasks.md` without asking what you meant.

<!-- ════════════════ END CO-PLANNER BRIEF ════════════════ -->

---

## 🎯 Goal

_What problem does this solve? What does "done" look like? What's in / out of scope?_

## 🔎 Research & References

_Sources consulted (docs, prior art, issues) — one-line takeaway each._

-

## 🧠 Decisions

_The chosen approach and WHY, plus the alternatives you rejected (and why)._

-

## 📋 Execution Plan

**Worktrees in scope:**
{{APPLIST}}

### Overall steps (ordered, checkable)

- [ ]
- [ ]
- [ ]

### 👥 Executor Assignments

_Who owns which sub-feature. Detailed tasks live in each executor's folder._

{{EXECLINES}}

## 🚧 Open Questions / Assumptions

_Unresolved items. Leave a breadcrumb whenever you defer something._

## 📝 Files Touched

_Update as you go — helps a fresh session grasp scope fast._

## 🧪 Testing & Verification

_How to prove it works: manual steps, edge cases, what to check before a PR._

---

## 🗒️ Agent Session Log

_Short notes when you compact or restart a session, so context isn't lost._
'@
    $content = $tpl.
        Replace('{{BRANCH}}',    $Branch).
        Replace('{{PROJECT}}',   $Project).
        Replace('{{APPS}}',      ($Apps -join ', ')).
        Replace('{{DATE}}',      (Get-Date -Format 'yyyy-MM-dd HH:mm')).
        Replace('{{APPLIST}}',   $appList).
        Replace('{{EXECLINES}}', $execLines).
        Replace('{{EXECNAMES}}', ($Executors -join ', ')).
        Replace('{{EXECCOUNT}}', "$execCount")
    Write-WtfFile -Path $Path -Content $content
}

function Write-WtfExecutorFolders {
    <#
    .SYNOPSIS
        Under the feature's .plan/ folder, give each executor its own subfolder
        with a tasks.md the planner fills in and the executor works from. Keeps
        each executor's work cleanly separated and easy for the planner to track.
    #>
    param(
        [Parameter(Mandatory)][string]$PlanDir,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string[]]$Executors
    )
    foreach ($name in $Executors) {
        $safe = ConvertTo-WtfSafeName $name
        $dir  = Join-Path $PlanDir $safe
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $taskFile = Join-Path $dir 'tasks.md'
        if (Test-Path $taskFile) { continue }   # never clobber existing work
        $body = @"
# $name — task list

**Feature:** $Branch  ·  **Owner:** ``$name`` executor

> The planner writes your ordered tasks here. You are a **root-level** executor:
> you see every worktree in this workspace, so implement your sub-feature fully
> across repos. Read ``../_PLAN.md`` for the overall goal and decisions; this file
> is your detailed worklist. Tick boxes as you go and leave notes so a fresh
> session can resume from this file alone.

## Assigned sub-feature

_(planner fills in: what slice of the feature you own, and why it's independent)_

## Tasks (ordered, checkable)

- [ ]
- [ ]
- [ ]

## Notes / handoff

_Decisions, blockers, and breadcrumbs for the next session._
"@
        Write-WtfFile -Path $taskFile -Content $body
    }
}

# ============================================================================
# WINDOWS TERMINAL LAUNCH
# ============================================================================

function _wtf_wt_quote {
    # Quote a single wt token. ';' (sub-command separator) stays bare; tokens
    # with spaces/quotes (titles like "🤖 citysense [F]", paths) get quoted.
    param([string]$Token)
    if ($Token -eq ';') { return ';' }
    if ($Token -match '[\s"]') { return '"' + ($Token -replace '"','\"') + '"' }
    return $Token
}

function Invoke-WtfWt {
    <#
    .SYNOPSIS
        Launch Windows Terminal with a hand-quoted command line. Passing a token
        ARRAY to Start-Process leaves titles-with-spaces unquoted, so wt parses
        e.g. "citysense" as a command — hence we build the string ourselves.
    #>
    param([Parameter(Mandatory)][string[]]$Argv)
    if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
        Write-WtfWarn "Windows Terminal (wt.exe) not found — skipping terminal launch."
        Write-WtfDetail "Install it from the Microsoft Store to get agent/runner tabs."
        return
    }
    $cmd = (@($Argv) | ForEach-Object { _wtf_wt_quote $_ }) -join ' '
    Write-WtfLog "WT: wt $cmd"
    Start-Process -FilePath 'wt.exe' -ArgumentList $cmd
}

function _wtf_slot_launch_cmd {
    <#
    .SYNOPSIS
        Build the shell command a slot's tab/pane runs. If the slot has a saved
        command (a CLI resume line with the session id baked in), we hand it to
        pwsh with -NoExit so the tab stays open and YOU answer whatever the CLI
        prompts next — wtf never scripts past launching it. Empty command =>
        $null (open the tab, run nothing).

        We BAKE a `Set-Location` to $WorkingDir into the script before the user's
        command. `wt -d` alone is unreliable: pwsh's own profile ($PROFILE) often
        runs `Set-Location ~` (or similar) at startup, which would drop the agent
        in the home dir instead of the worktree. Setting the location *inside* the
        launched script, after the profile has run, guarantees the agent starts in
        the right folder.

        The whole thing is base64 (UTF-16LE) and run via pwsh -EncodedCommand, so
        the user's command can contain ANYTHING — spaces, quotes, and crucially
        ';' (wt's own sub-command separator) — without wt or the shell choking.
    #>
    param($Slot, [string]$WorkingDir = '')
    $cmd = [string]$Slot.command
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $null }
    $script = if ($WorkingDir) {
        # Single-quote the path and double any embedded quotes for a safe literal.
        $safeDir = $WorkingDir -replace "'", "''"
        "Set-Location -LiteralPath '$safeDir'`n$cmd"
    } else { $cmd }
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($script)
    $enc   = [Convert]::ToBase64String($bytes)
    return @('pwsh','-NoExit','-EncodedCommand', $enc)
}

function Invoke-WtfLaunchAgents {
    <#
    .SYNOPSIS
        Open the Agent window from the feature's SLOTS. Every agentic terminal
        roots at the feature dir (root-level agents see all worktrees at once).
        Hardcoded layout:
          • executor slots (root-exec / freeform) → ONE shared tab, side-by-side
            panes (slot 1 left, slot 2 right, …).
          • every other role (planner / researcher / custom) → its own tab.
        Each slot auto-runs its saved command (resume line w/ session id) verbatim;
        a slot with no command just opens its tab/pane at root for you to start.
    #>
    param(
        [Parameter(Mandatory)][string]$WindowName,
        [Parameter(Mandatory)]$Slots,            # array of slot hashtables
        [Parameter(Mandatory)][string]$FeatureDir
    )
    $list = @($Slots)
    if ($list.Count -eq 0) { return }

    # Order: planners/other roles in declared order, but keep executor panes
    # contiguous so they land in one tab. We emit non-pane slots as tabs and the
    # whole executor group as a single tab of panes, preserving overall order by
    # walking the list and grouping consecutive pane-exec slots.
    $argv  = @('-w', $WindowName)
    $first = $true
    $i = 0
    while ($i -lt $list.Count) {
        $slot = $list[$i]
        $info = Get-WtfRoleInfo $slot.role
        $title = Get-WtfSlotTitle $slot
        $runv  = _wtf_slot_launch_cmd $slot -WorkingDir $FeatureDir

        if ($info.Layout -eq $script:WtfPaneLayout) {
            # Collect this run of consecutive executor slots into one tab of panes.
            $group = @()
            while ($i -lt $list.Count -and (Get-WtfRoleInfo $list[$i].role).Layout -eq $script:WtfPaneLayout) {
                $group += $list[$i]; $i++
            }
            for ($g = 0; $g -lt $group.Count; $g++) {
                $gs    = $group[$g]
                $gt    = Get-WtfSlotTitle $gs
                $grun  = _wtf_slot_launch_cmd $gs -WorkingDir $FeatureDir
                # NOTE: build $seg as [array]@(...) — a bare @('new-tab') returned
                # from `if` unwraps to a scalar string, and a later `$seg += @(...)`
                # would then STRING-concat instead of array-append, fusing tokens.
                $seg = [array]@()
                if ($g -eq 0) {
                    if (-not $first) { $seg += ';' }
                    $seg += @('new-tab','-d', $FeatureDir, '--title', $gt, '--tabColor', (Get-WtfRoleInfo $gs.role).Color)
                    $first = $false
                } else {
                    # wt's -V splits VERTICALLY into a left/right pair (side by
                    # side); -H would stack them top/bottom. We want exec-1 left,
                    # exec-2 right, so use -V.
                    $seg += @(';','split-pane','-V','-d', $FeatureDir, '--title', $gt, '--tabColor', (Get-WtfRoleInfo $gs.role).Color)
                }
                if ($grun) { $seg += $grun }
                $argv += $seg
            }
            continue
        }

        # Own tab for planner / researcher / custom.
        $seg = [array]@()
        if (-not $first) { $seg += ';' }
        $seg += @('new-tab','-d', $FeatureDir, '--title', $title, '--tabColor', $info.Color)
        if ($runv) { $seg += $runv }
        $argv += $seg
        $first = $false
        $i++
    }
    Invoke-WtfWt -Argv $argv
}

function Invoke-WtfLaunchRunners {
    <#
    .SYNOPSIS
        Open the Runner window: green tabs for worktree repos (pointing at the
        worktree), gray tabs for dependency repos (pointing at main).
    #>
    param(
        [Parameter(Mandatory)][string]$WindowName,
        [Parameter(Mandatory)]$Worktrees,        # array of @{ Name; Dir }
        $Deps = @()                              # array of @{ Name; Dir }
    )
    $tabs = @()
    foreach ($w in @($Worktrees)) { $tabs += @{ Title = "🚀 $($w.Name) [F]"; Dir = $w.Dir; Color = $script:TabColors.RunnerFeat } }
    foreach ($d in @($Deps))      { $tabs += @{ Title = "📦 $($d.Name) [M]"; Dir = $d.Dir; Color = $script:TabColors.RunnerMain } }
    if ($tabs.Count -eq 0) { return }

    $argv = @('-w', $WindowName)
    for ($i = 0; $i -lt $tabs.Count; $i++) {
        if ($i -eq 0) { $argv += @('new-tab') } else { $argv += @(';','new-tab') }
        $argv += @('-d', $tabs[$i].Dir, '--title', $tabs[$i].Title, '--tabColor', $tabs[$i].Color)
    }
    Invoke-WtfWt -Argv $argv
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

    # ── How many executors? (dynamic — scale to the task size) ─────────
    # One co-planner is always added on top. Bigger feature → more executors.
    $execCount = $script:WtfDefaultExecCount
    if (-not $DryRun) {
        $ec = Read-WtfText -Prompt "How many executors for this feature?" -Default "$($script:WtfDefaultExecCount)" `
                -Hint "scale to task size; a planner is added on top" `
                -Validator { param($v) if ($v -match '^\d+$' -and [int]$v -ge 0 -and [int]$v -le 8) { $null } else { "Enter a number 0–8." } }
        if ($null -ne $ec) { $execCount = [int]$ec }
    }

    $featureDir  = Get-WtfFeatureDir    $config $Context $projectName $Branch
    $workspaceFp = Get-WtfWorkspacePath $config $Context $projectName $Branch

    if (Test-Path $featureDir) {
        Write-WtfFail "Feature directory already exists: $featureDir"
        Write-WtfDetail "Use ``wtf open`` to reopen, or ``wtf remove`` to clean up."
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
    Write-WtfInfo "Agents:     1 planner + $execCount executor$(if ($execCount -ne 1){'s'})"
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

    # ── Normalized lists for workspace + terminals ────────────────────
    $wtList  = foreach ($short in $wtNames) {
        @{ Name = $short; Dir = $(if ($isMono) { $featureDir } else { Join-Path $featureDir $short }) }
    }
    $depNorm = foreach ($d in $depList) { @{ Name = $d.Name; Dir = (Join-Path $mainDir $d.RelPath) } }
    # Source main-checkouts of the branched repos — hidden as SCM phantoms.
    $ignoreRepos = foreach ($short in $wtNames) { Join-Path $mainDir $worktreeMap[$short] }

    # ── Executor roster for the plan (NOT slots) ─────────────────────
    # create does NOT create agent slots (we never store empty ones). It only
    # uses the chosen executor count to scaffold the plan's assignment table and
    # the per-executor .plan/ folders, so the planner knows how many executors it
    # has. Real slots are born later in `wtf edit` when you paste resume commands.
    $execNames = @(for ($n = 1; $n -le $execCount; $n++) { "exec-$n" })

    # ── Artifacts ─────────────────────────────────────────────────────
    Write-WtfHeader "Artifacts"
    # Both mono and multi use a .plan/ FOLDER (so the co-planner + per-executor
    # subfolders model works the same everywhere). For MONO the .plan/ lives
    # INSIDE the repo worktree (agent opens the repo root and sees plan+code
    # together) and is git-excluded locally so it's never committed. For MULTI it
    # lives at the feature root (the workspace surfaces it as the 📋 plan folder).
    if ($isMono) {
        $planDir = Join-Path $featureDir '.plan'   # inside the single repo
    } else {
        $planDir = Join-Path $featureDir '.plan'   # at the feature root
    }
    New-Item -ItemType Directory -Path $planDir -Force | Out-Null
    $planFile = Join-Path $planDir '_PLAN.md'
    Write-WtfPlan -Path $planFile -Branch $Branch -Apps $wtNames -Project $projectName -Executors $execNames
    if ($execNames.Count -gt 0) {
        Write-WtfExecutorFolders -PlanDir $planDir -Branch $Branch -Executors $execNames
        Write-WtfOk "executor folders: $($execNames -join ', ')"
    }
    Write-WtfOk "_PLAN.md scaffolded in .plan/"

    # Mono: the .plan/ folder lives inside the repo. Exclude it locally so nothing
    # in it can ever be staged/committed (same idea we used for _PLAN.md before).
    # (.wtf-meta.json is a sidecar OUTSIDE the repo, so it needs no exclusion and
    # survives any git clean/checkout.)
    if ($isMono) {
        Add-WtfGitExclude -WorktreeDir $featureDir -Patterns @('/.plan/')
        Write-WtfOk "git-ignored .plan/ locally (won't be committed)"
    }

    # A workspace only earns its keep when it spans MULTIPLE folders. A single
    # repo doesn't need one (it just nests the repo as a child folder), so for
    # mono we skip the workspace entirely and `wtf open` opens the repo directly.
    if (-not $isMono) {
        Write-WtfWorkspace -WorkspacePath $workspaceFp -FeatureDir $featureDir -Worktrees @($wtList) -Deps @($depNorm) -IgnoreRepos @($ignoreRepos)
        Write-WtfOk "workspace written: $(Split-Path $workspaceFp -Leaf)"
    }

    $appPaths = @{}
    foreach ($short in $wtNames) { $appPaths[$short] = $worktreeMap[$short] }
    $metaDeps = foreach ($d in $depList) { @{ name = $d.Name; path = $d.RelPath } }
    $metaApps = if ($isMono) { @() } else { @($wtNames) }
    # Fresh feature → NO agent slots yet (born in `wtf edit`). We do remember the
    # chosen executor count so `wtf edit`'s first-time walk-through can suggest
    # exactly that many executors.
    $meta = New-WtfMeta -Context $Context -Project $projectName -Branch $Branch `
                        -Type $(if ($isMono) { 'mono' } else { 'multi' }) `
                        -Apps $metaApps -AppPaths $appPaths -Deps @($metaDeps) -Panes $Panes.IsPresent
    $meta.execCount = $execCount
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
    $sumLines += ""
    $sumLines += "$($script:T.Detail)Opening VS Code + terminal windows...$($script:T.Reset)"
    Write-WtfSummary -Title "Feature ready: $Branch" -Lines $sumLines

    Invoke-WtfOpen -Context $Context -Project $projectName -Branch $Branch -Panes:$Panes
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

    $gitArgs = switch ($Source.Mode) {
        'local'  { @('worktree','add', $TargetDir, $Branch) }
        'remote' { @('worktree','add','--track','-b', $Branch, $TargetDir, $Source.BaseRef) }
        'new'    { @('worktree','add','-b', $Branch, $TargetDir, $Source.BaseRef) }
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
            Remove-Item $c.Dst -Recurse -Force -ErrorAction SilentlyContinue
        }
        Invoke-WtfWorktreePrune -RepoDir $c.Src
    }
    if (Test-Path $FeatureDir) {
        Remove-Item $FeatureDir -Recurse -Force -ErrorAction SilentlyContinue
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
    $picked  = Read-WtfMultiChoice -Prompt "Repos to add (worktree)" -Options @($labels) -Min 1
    if (@($picked).Count -eq 0) { Write-WtfWarn "Cancelled."; return }

    # Build short names for the additions, avoiding collisions with existing apps.
    $addMap = New-WtfShortNameMap -Candidates @(foreach ($l in $picked) { $byLabel[$l] })
    $finalAdd = [ordered]@{}
    foreach ($k in $addMap.Keys) {
        $short = $k; $i = 2
        while (($short -in @($meta.apps)) -or $finalAdd.Contains($short)) { $short = "$k$i"; $i++ }
        $finalAdd[$short] = $addMap[$k]
    }

    Write-WtfHeader "Plan"
    Write-WtfInfo "Feature:  $Project · $Branch"
    Write-WtfInfo "Adding:   $(@($finalAdd.Keys) -join ', ')"
    if ($DryRun) { Write-WtfWarn "DRY RUN."; return }
    if (-not (Read-WtfConfirm "Proceed?" $true)) { Write-WtfWarn "Cancelled."; return }

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

    # Update meta (preserve appPaths + deps) and rebuild the workspace.
    $newApps  = @($meta.apps) + @($finalAdd.Keys)
    $appPaths = @{}
    foreach ($a in @($meta.apps)) {
        $appPaths[$a] = if ($meta.appPaths -and (Test-ObjectHasKey $meta.appPaths $a)) { Get-ObjectValue $meta.appPaths $a } else { $a }
    }
    foreach ($k in $finalAdd.Keys) { $appPaths[$k] = $finalAdd[$k] }
    $deps = @()
    foreach ($d in @($meta.deps)) { if ($d) { $deps += @{ name = (Get-ObjectValue $d 'name'); path = (Get-ObjectValue $d 'path') } } }

    # Preserve the feature's agentic slots (active + archived) and exec count —
    # adding a repo must not reset any of them.
    $keepSlots    = @(Get-WtfSlots $meta)
    $keepArchived = @(Get-WtfArchivedSlots $meta)
    $newMeta = New-WtfMeta -Context $Context -Project $Project -Branch $Branch -Type 'multi' `
                           -Apps $newApps -AppPaths $appPaths -Deps @($deps) -Panes ([bool]$meta.panes) `
                           -Slots $keepSlots -ArchivedSlots $keepArchived
    $newMeta.createdAt = $meta.createdAt
    if (Test-ObjectHasKey $meta 'execCount') { $newMeta.execCount = $meta.execCount }
    Save-WtfMeta -FeatureDir $featureDir -Meta $newMeta

    $wsPath = Get-WtfWorkspacePath $config $Context $Project $Branch
    $layout = Resolve-WtfFeatureLayout -Config $config -Meta $newMeta -FeatureDir $featureDir
    $ignoreRepos = foreach ($w in @($layout.Worktrees)) { Join-Path $layout.MainDir $w.RelPath }
    Write-WtfWorkspace -WorkspacePath $wsPath -FeatureDir $featureDir -Worktrees @($layout.Worktrees) -Deps @($layout.Deps) -IgnoreRepos @($ignoreRepos)
    Write-WtfOk "workspace updated (VS Code will hot-reload)"

    Write-WtfSummary -Title "Repos added" -Lines @(
        "$($script:T.Bold)Now in feature:$($script:T.Reset) $($newApps -join ', ')",
        "$($script:T.Detail)Run ``wtf open`` to refresh terminals with new tabs.$($script:T.Reset)"
    )
}

function Invoke-WtfAddRollback {
    param([System.Collections.ArrayList]$Created)
    Write-WtfHeader "Rollback"
    foreach ($c in $Created) {
        Write-WtfStep "removing $($c.App)"
        $r = Invoke-WtfGit -WorkingDir $c.Src -GitArgs @('worktree','remove','--force', $c.Dst)
        if (-not $r.Ok) {
            Remove-Item $c.Dst -Recurse -Force -ErrorAction SilentlyContinue
        }
        Invoke-WtfWorktreePrune -RepoDir $c.Src
    }
    Write-WtfOk "rolled back"
}

# ============================================================================
# AGENTIC TERMINAL SLOTS — walk-through + preview
# ============================================================================

function Show-WtfSlotPreview {
    <#
    .SYNOPSIS
        One-glance summary of what `wtf open` will spawn. Each standalone role is
        shown on its own; a run of consecutive pane-executors is bracketed as one
        tab of panes, e.g.  🧠 plan  ·  [ 🤖 exec-1 │ 🤖 exec-2 ]  ·  🦾 free
    #>
    param([Parameter(Mandatory)]$Slots)
    $list = @($Slots)
    if ($list.Count -eq 0) { Write-WtfDetail "(no agent terminals configured yet — run ``wtf edit``)"; return }
    $T = $script:T
    $parts = @()
    $i = 0
    while ($i -lt $list.Count) {
        if ((Get-WtfRoleInfo $list[$i].role).Layout -eq $script:WtfPaneLayout) {
            $grp = @()
            while ($i -lt $list.Count -and (Get-WtfRoleInfo $list[$i].role).Layout -eq $script:WtfPaneLayout) {
                $grp += (Get-WtfSlotTitle $list[$i]); $i++
            }
            # Bracket the pane group so it reads as one tab split into panes.
            $inner = $grp -join " $($T.Faint)│$($T.Reset) "
            $parts += "$($T.Faint)[$($T.Reset) $inner $($T.Faint)]$($T.Reset)"
        } else {
            $parts += (Get-WtfSlotTitle $list[$i]); $i++
        }
    }
    _wtf_write "  $($parts -join "   $($T.Faint)·$($T.Reset)   ")"
}

function Read-WtfSlotCommand {
    <#
    .SYNOPSIS
        Prompt for a slot's FULL launch/resume command (session id baked in).
        Returns the typed command, or $Current (possibly '') if left blank. The
        caller decides what a blank means (skip-this-slot when creating, keep-as-
        is when editing) — this function never invents one.
    #>
    param([string]$Current = '', [string]$BlankHint = 'leave blank to skip')
    $T = $script:T
    if ($Current) { Write-WtfDetail "current: $Current" }
    Write-WtfDetail "Paste the full resume command for this CLI (session id included)."
    Write-WtfDetail $BlankHint
    [Console]::Out.Write("$($T.Accent)❯$($T.Reset) $($T.Bold)Command$($T.Reset) $($T.Accent)›$($T.Reset) ")
    $line = [Console]::ReadLine()
    if ($null -eq $line) { return $Current }
    $line = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($line)) { return $Current }
    return $line
}

function Select-WtfRole {
    <#
    .SYNOPSIS
        Pick a role for a slot. Offers the known roles plus "type your own"
        (stored as the generic 'custom' role with a name you choose).
    .OUTPUTS
        @{ Role; Name } or $null on cancel.
    #>
    param([string]$DefaultName = '')
    $TYPE = '⌨  type my own…'
    $opts  = @()
    $descs = @()
    $keys  = @()
    foreach ($k in $script:WtfRoles.Keys) {
        if ($k -eq 'custom') { continue }    # custom is the "type your own" path
        $info = $script:WtfRoles[$k]
        $opts  += "$($info.Glyph)  $($info.Label)"
        $descs += $(switch ($k) {
            'planner'    { 'plans the feature, assigns work to executors' }
            'root-exec'  { 'root-level executor — shares the pane tab' }
            'freeform'   { 'free-scope executor — own tab' }
            'researcher' { 'research / critic — own tab' }
            default      { '' }
        })
        $keys += $k
    }
    $opts += $TYPE; $descs += 'any other role — own tab'; $keys += 'custom'

    $pick = Read-WtfChoice -Prompt "What is this terminal?" -Options $opts -Descriptions $descs
    if (-not $pick) { return $null }
    $idx = [Array]::IndexOf($opts, $pick)
    $role = $keys[$idx]

    # Default name per role (so the common path is mostly Enter).
    $suggest = switch ($role) {
        'planner'    { 'plan' }
        'root-exec'  { if ($DefaultName) { $DefaultName } else { 'exec' } }
        'freeform'   { if ($DefaultName) { $DefaultName } else { 'exec' } }
        'researcher' { 'research' }
        default      { if ($DefaultName) { $DefaultName } else { 'agent' } }
    }
    $name = Read-WtfText -Prompt "Name for this terminal" -Default $suggest -Hint "short label shown on the tab"
    if (-not $name) { return $null }
    return @{ Role = $role; Name = $name }
}

function _wtf_now_iso { return (Get-Date -Format o) }

function _wtf_truncate {
    param([string]$Text, [int]$Max)
    if (-not $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    if ($Max -le 1) { return $Text.Substring(0, [Math]::Max(0,$Max)) }
    return $Text.Substring(0, $Max - 1) + '…'
}

function Invoke-WtfSlotBoard {
    <#
    .SYNOPSIS
        Live, navigable "slot board" for a feature's agent terminals. One screen
        that redraws in place: a list of terminals you operate with the keyboard.

          ↑↓  move cursor        enter  edit the row
          a   add a terminal     x      archive the row (kept for `wtf sessions`)
          r   restore archived   s      save & exit       esc  cancel

        Rows whose role shares the pane tab are bracketed so it's clear they live
        together as side-by-side panes. A brand-new feature pre-seeds suggested
        rows (planner + N executors) as "needs command" placeholders; saving drops
        any placeholder you never gave a command. Only real sessions are stored.

        Returns @{ Active = <slots>; Archived = <slots> } or $null on cancel.
    #>
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)]$ExistingSlots,
        $ArchivedSlots = @(),
        [int]$SuggestExecutors = -1
    )
    $T = $script:T

    # Working rows: each @{ role; name; command }. Empty command = placeholder.
    $rows = @()
    foreach ($s in @($ExistingSlots)) { $rows += @{ role = $s.role; name = $s.name; command = [string]$s.command } }
    $archived = @()
    foreach ($s in @($ArchivedSlots)) { $archived += @{ role = $s.role; name = $s.name; command = [string]$s.command; archivedAt = [string]$s.archivedAt } }

    # Fresh feature → pre-seed suggested placeholders so you just fill commands.
    $firstTime = ($rows.Count -eq 0)
    if ($firstTime) {
        foreach ($s in @(New-WtfSuggestedSlots -Executors $SuggestExecutors)) {
            $rows += @{ role = $s.role; name = $s.name; command = '' }
        }
    }

    $cursor = 0
    $rendered = 0
    $msg = if ($firstTime) { "First-time setup — press enter on a row to paste its resume command." } else { '' }

    $title = "Agent terminals — $Context/$Project · $Branch"
    $width = 72
    $bar   = '─' * $width

    [Console]::Out.Write($T.HideCur)
    try {
        while ($true) {
            if ($rows.Count -eq 0) { $cursor = 0 } else { $cursor = [Math]::Max(0, [Math]::Min($cursor, $rows.Count - 1)) }
            _wtf_render_clear $rendered
            $lines = 0
            [Console]::Out.WriteLine("$($T.Header)$($T.Bold)  $title$($T.Reset)"); $lines++
            [Console]::Out.WriteLine("$($T.Faint)  $bar$($T.Reset)"); $lines++

            if ($rows.Count -eq 0) {
                [Console]::Out.WriteLine("$($T.Detail)    (no terminals — press $($T.Bold)a$($T.Reset)$($T.Detail) to add one)$($T.Reset)"); $lines++
            }
            for ($i = 0; $i -lt $rows.Count; $i++) {
                $r    = $rows[$i]
                $info = Get-WtfRoleInfo $r.role
                $isPane = ($info.Layout -eq $script:WtfPaneLayout)
                # Bracket markers tie consecutive pane rows together visually.
                $prevPane = ($i -gt 0) -and ((Get-WtfRoleInfo $rows[$i-1].role).Layout -eq $script:WtfPaneLayout)
                $nextPane = ($i -lt $rows.Count-1) -and ((Get-WtfRoleInfo $rows[$i+1].role).Layout -eq $script:WtfPaneLayout)
                $brace = if ($isPane) {
                    if (-not $prevPane -and $nextPane) { '┌' } elseif ($prevPane -and $nextPane) { '│' } elseif ($prevPane -and -not $nextPane) { '└' } else { ' ' }
                } else { ' ' }

                $title2 = Get-WtfSlotTitle $r
                $cmdTxt = if ([string]::IsNullOrWhiteSpace($r.command)) { "$($T.Warn)needs command$($T.Reset)" } else { "$($T.Detail)$(_wtf_truncate $r.command 40)$($T.Reset)" }
                $active = ($i -eq $cursor)
                if ($active) {
                    $rail = "$($T.Rail)▌$($T.Reset)"
                    [Console]::Out.WriteLine("$rail $($T.Faint)$brace$($T.Reset) $($T.SelBg)$($T.Bold)$($title2.PadRight(16))$($T.Reset)$($T.SelBg) $cmdTxt$($T.Reset)")
                } else {
                    [Console]::Out.WriteLine("  $($T.Faint)$brace$($T.Reset) $($title2.PadRight(16)) $cmdTxt")
                }
                $lines++
            }

            [Console]::Out.WriteLine("$($T.Faint)  $bar$($T.Reset)"); $lines++
            $archNote = if ($archived.Count -gt 0) { "   $($T.Faint)·  r restore ($($archived.Count) archived)$($T.Reset)" } else { '' }
            [Console]::Out.WriteLine("$($T.Detail)  ↑↓ move · enter edit · a add · x archive$archNote$($T.Reset)"); $lines++
            [Console]::Out.WriteLine("$($T.Detail)  s save · esc cancel$($T.Reset)"); $lines++
            if ($msg) { [Console]::Out.WriteLine("$($T.Accent)  $msg$($T.Reset)"); $lines++; $msg = '' }
            $rendered = $lines

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { if ($rows.Count) { $cursor = ($cursor - 1 + $rows.Count) % $rows.Count } }
                'DownArrow' { if ($rows.Count) { $cursor = ($cursor + 1) % $rows.Count } }
                'Home'      { $cursor = 0 }
                'End'       { if ($rows.Count) { $cursor = $rows.Count - 1 } }
                'Enter' {
                    if ($rows.Count -eq 0) { continue }
                    [Console]::Out.Write($T.ShowCur)
                    $res = _wtf_board_edit_row $rows[$cursor]
                    [Console]::Out.Write($T.HideCur)
                    if ($res) { $rows[$cursor] = $res }
                }
                'Escape' {
                    _wtf_render_clear $rendered
                    _wtf_write "  $($T.Fail)cancelled — no changes saved$($T.Reset)"
                    return $null
                }
                default {
                    switch ("$($key.KeyChar)".ToLower()) {
                        'a' {
                            [Console]::Out.Write($T.ShowCur)
                            $new = _wtf_board_edit_row @{ role=''; name=''; command='' }
                            [Console]::Out.Write($T.HideCur)
                            if ($new) {
                                # Insert just after the cursor. Guard the slice ends
                                # so a boundary insert never produces a reversed range.
                                $insert = if ($rows.Count) { $cursor + 1 } else { 0 }
                                $before = if ($insert -gt 0)            { @($rows[0..($insert-1)]) } else { @() }
                                $after  = if ($insert -le $rows.Count-1) { @($rows[$insert..($rows.Count-1)]) } else { @() }
                                $rows = @($before) + @($new) + @($after)
                                $cursor = $insert
                            }
                        }
                        'x' {
                            if ($rows.Count -eq 0) { continue }
                            $r = $rows[$cursor]
                            if (-not [string]::IsNullOrWhiteSpace($r.command)) {
                                $archived = @($archived) + @{ role=$r.role; name=$r.name; command=$r.command; archivedAt=(_wtf_now_iso) }
                                $msg = "archived $(Get-WtfSlotTitle $r) — reopen later via ``wtf sessions``"
                            } else {
                                $msg = "removed $(Get-WtfSlotTitle $r) (no session to archive)"
                            }
                            $rows = @($rows | Where-Object { $_ -ne $r })
                        }
                        'r' {
                            if ($archived.Count -eq 0) { $msg = "nothing archived"; continue }
                            [Console]::Out.Write($T.ShowCur)
                            $labels = @($archived | ForEach-Object { "$(Get-WtfSlotTitle $_)   $($T.Detail)$(_wtf_truncate $_.command 40)$($T.Reset)" })
                            $pick = Read-WtfChoice -Prompt "Restore which archived session" -Options $labels
                            [Console]::Out.Write($T.HideCur)
                            if ($pick) {
                                $ri = [Array]::IndexOf($labels, $pick)
                                $rs = $archived[$ri]
                                $rows = @($rows) + @{ role=$rs.role; name=$rs.name; command=$rs.command }
                                $archived = @($archived | Where-Object { $_ -ne $rs })
                                $cursor = $rows.Count - 1
                                $msg = "restored $(Get-WtfSlotTitle $rs)"
                            }
                        }
                        's' {
                            # Save: keep only rows that have a real command.
                            $final = @($rows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.command) } |
                                       ForEach-Object { New-WtfSlot -Role $_.role -Name $_.name -Command $_.command })
                            $dropped = @($rows | Where-Object { [string]::IsNullOrWhiteSpace($_.command) }).Count
                            _wtf_render_clear $rendered
                            if ($dropped -gt 0) { Write-WtfDetail "$dropped placeholder(s) without a command were not saved." }
                            return @{ Active = @($final); Archived = @($archived) }
                        }
                    }
                }
            }
        }
    }
    finally {
        [Console]::Out.Write($T.ShowCur)
    }
}

function _wtf_board_edit_row {
    <#
    .SYNOPSIS
        Inline overlay used by the board to create/edit ONE row: pick role+name,
        then paste the command. Returns the row hashtable, or $null if cancelled
        (and nothing should change).
    #>
    param($Row)
    $T = $script:T
    [Console]::Out.WriteLine()
    $hasRole = -not [string]::IsNullOrWhiteSpace($Row.role)
    if ($hasRole) {
        Write-WtfDetail "Editing $(Get-WtfSlotTitle $Row) — change role/name, or keep and just update the command."
        if (-not (Read-WtfConfirm "Change role / name?" $false)) {
            $role = $Row.role; $name = $Row.name
        } else {
            $r = Select-WtfRole -DefaultName $Row.name
            if (-not $r) { return $null }
            $role = $r.Role; $name = $r.Name
        }
    } else {
        $r = Select-WtfRole
        if (-not $r) { return $null }
        $role = $r.Role; $name = $r.Name
    }
    $blank = if ([string]::IsNullOrWhiteSpace($Row.command)) { "leave blank to skip (won't be saved)" } else { "leave blank to keep the current command" }
    $cmd = Read-WtfSlotCommand -Current $Row.command -BlankHint $blank
    return @{ role = $role; name = $name; command = $cmd }
}

function Invoke-WtfSlotWalkthrough {
    # Thin wrapper kept for callers — delegates to the live board.
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)]$ExistingSlots,
        $ArchivedSlots = @(),
        [int]$SuggestExecutors = -1
    )
    return Invoke-WtfSlotBoard -Context $Context -Project $Project -Branch $Branch `
        -ExistingSlots $ExistingSlots -ArchivedSlots $ArchivedSlots -SuggestExecutors $SuggestExecutors
}

# ============================================================================
# COMMAND: wtf edit  (configure a feature's agentic terminals)
# ============================================================================

function Invoke-WtfEdit {
    param(
        [string]$Context,
        [string]$Project,
        [string]$Branch
    )
    Start-WtfLog 'edit'
    Write-WtfBanner "edit — set up this feature's agent terminals"

    $config = Get-WtfConfig
    if (-not $config) { return }

    # Always make the feature explicit (so you know which one you're editing).
    if (-not $Context -or -not $Project -or -not $Branch) {
        $features = Get-WtfActiveFeatures -Config $config
        if ($Context) { $features = @($features | Where-Object { $_.Context -eq $Context }) }
        if ($features.Count -eq 0) { Write-WtfFail "No active features to edit."; return }
        $labels = $features | ForEach-Object {
            "$($_.Context)/$($_.Project) · $($_.Branch)  $($script:T.Detail)($($_.Apps -join ', '))$($script:T.Reset)"
        }
        $pick = Read-WtfChoice -Prompt "Edit terminals for which feature" -Options $labels
        if (-not $pick) { return }
        $f = $features[[Array]::IndexOf($labels, $pick)]
        $Context = $f.Context; $Project = $f.Project; $Branch = $f.Branch
    }

    $featureDir = Get-WtfFeatureDir $config $Context $Project $Branch
    $meta = Read-WtfMeta -FeatureDir $featureDir
    if (-not $meta) { Write-WtfFail "Feature not found: $featureDir"; return }

    $existing   = @(Get-WtfSlots $meta)
    $archived   = @(Get-WtfArchivedSlots $meta)
    $suggestN   = if (Test-ObjectHasKey $meta 'execCount') { [int](Get-ObjectValue $meta 'execCount') } else { -1 }
    $res = Invoke-WtfSlotWalkthrough -Context $Context -Project $Project -Branch $Branch `
              -ExistingSlots $existing -ArchivedSlots $archived -SuggestExecutors $suggestN
    if ($null -eq $res) { Write-WtfWarn "No changes saved."; return }
    $newSlots    = @($res.Active)
    $newArchived = @($res.Archived)

    Set-WtfMetaSlots -Meta $meta -Active $newSlots -Archived $newArchived | Out-Null
    Save-WtfMeta -FeatureDir $featureDir -Meta $meta

    # Keep executor plan-folders in sync with the (possibly changed) executor set.
    # Both mono and multi keep .plan/ at the feature dir (for mono that's inside
    # the repo). New executors get a folder; removed ones are left in place so no
    # work is ever clobbered.
    $type = if ($meta.type) { $meta.type } elseif (@($meta.apps).Count -eq 0) { 'mono' } else { 'multi' }
    $execNames = @(Get-WtfExecutorNames $newSlots)
    if ($execNames.Count -gt 0) {
        $planDir = Join-Path $featureDir '.plan'
        if (-not (Test-Path $planDir)) { New-Item -ItemType Directory -Path $planDir -Force | Out-Null }
        Write-WtfExecutorFolders -PlanDir $planDir -Branch $Branch -Executors $execNames
        # Mono: make sure the in-repo .plan/ stays git-excluded.
        if ($type -eq 'mono') { Add-WtfGitExclude -WorktreeDir $featureDir -Patterns @('/.plan/') }
    }

    # Save and STOP — `wtf edit` never opens. Use `wtf open` to launch.
    Write-WtfHeader "Saved"
    if ($newSlots.Count -gt 0) {
        Write-WtfDetail "``wtf open`` (this feature) will launch:"
        Show-WtfSlotPreview $newSlots
    } else {
        Write-WtfDetail "No active agent terminals — nothing will launch on ``wtf open``."
    }
    if ($newArchived.Count -gt 0) {
        Write-WtfDetail "Archived: $(@($newArchived | ForEach-Object { Get-WtfSlotTitle $_ }) -join ', ')  ·  reopen via ``wtf sessions``"
    }
}

# ============================================================================
# COMMAND: wtf sessions  (list active + archived; reopen one)
# ============================================================================

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

function Invoke-WtfLaunchOneSlot {
    <#
    .SYNOPSIS
        Open ONE slot as a new tab inside the feature's EXISTING agents window
        (wt -w <name> reuses a window if it's already open, else creates it).
        Always a tab (not a pane) so a reopened session is clearly its own thing.
    #>
    param(
        [Parameter(Mandatory)][string]$WindowName,
        [Parameter(Mandatory)]$Slot,
        [Parameter(Mandatory)][string]$FeatureDir
    )
    $info  = Get-WtfRoleInfo $Slot.role
    $title = Get-WtfSlotTitle $Slot
    $argv  = @('-w', $WindowName, 'new-tab','-d', $FeatureDir, '--title', $title, '--tabColor', $info.Color)
    $run   = _wtf_slot_launch_cmd $Slot -WorkingDir $FeatureDir
    if ($run) { $argv += $run }
    Invoke-WtfWt -Argv $argv
}

function Invoke-WtfSessions {
    param(
        [string]$Context,
        [string]$Project,
        [string]$Branch
    )
    Start-WtfLog 'sessions'
    Write-WtfBanner "sessions — agent sessions for a feature"

    $config = Get-WtfConfig
    if (-not $config) { return }

    $sel = Resolve-WtfFeatureSelection -Config $config -Context $Context -Project $Project -Branch $Branch -Prompt "Sessions for which feature"
    if (-not $sel) { return }
    $meta = $sel.Meta

    $active   = @(Get-WtfSlots $meta)
    $archived = @(Get-WtfArchivedSlots $meta)

    Write-WtfHeader "$($sel.Context) / $($sel.Project) — $($sel.Branch)"
    $T = $script:T
    if ($active.Count -gt 0) {
        Write-WtfInfo "Active:"
        foreach ($s in $active) { _wtf_write "    $($T.Ok)●$($T.Reset) $(Get-WtfSlotTitle $s)   $($T.Detail)$([string]$s.command)$($T.Reset)" }
    }
    if ($archived.Count -gt 0) {
        Write-WtfInfo "Archived:"
        foreach ($s in $archived) {
            $when = if ($s.archivedAt) { " $($T.Faint)($([string]$s.archivedAt).Substring(0,10))$($T.Reset)" } else { '' }
            _wtf_write "    $($T.Faint)○$($T.Reset) $(Get-WtfSlotTitle $s)$when   $($T.Detail)$([string]$s.command)$($T.Reset)"
        }
    }
    if ($active.Count -eq 0 -and $archived.Count -eq 0) {
        Write-WtfDetail "No sessions yet. Run ``wtf edit`` to set up agent terminals."
        return
    }

    # Build a reopen picker over BOTH sets.
    $pickItems = @()
    foreach ($s in $active)   { $pickItems += @{ Slot = $s; Tag = 'active' } }
    foreach ($s in $archived) { $pickItems += @{ Slot = $s; Tag = 'archived' } }
    $labels = @($pickItems | ForEach-Object {
        $tag = if ($_.Tag -eq 'archived') { " $($T.Faint)[archived]$($T.Reset)" } else { '' }
        "$(Get-WtfSlotTitle $_.Slot)$tag"
    })
    $NONE = '— don''t reopen anything —'
    [Console]::Out.WriteLine()
    $pick = Read-WtfChoice -Prompt "Reopen a session (in the agents window)" -Options (@($NONE) + $labels)
    if (-not $pick -or $pick -eq $NONE) { return }
    $chosen = $pickItems[([Array]::IndexOf($labels, $pick))]

    $safeBranch = ConvertTo-WtfSafeName $sel.Branch
    $agentWin   = "wtf-agents-$($sel.Project)-$safeBranch"
    Write-WtfStep "reopening $(Get-WtfSlotTitle $chosen.Slot) → $agentWin"
    Invoke-WtfLaunchOneSlot -WindowName $agentWin -Slot $chosen.Slot -FeatureDir $sel.Dir
    Write-WtfOk "reopened in the agents window"
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

    # ── Agent sessions ────────────────────────────────────────────────
    $active   = @(Get-WtfSlots $meta)
    $archived = @(Get-WtfArchivedSlots $meta)
    Write-WtfInfo "Agent sessions:"
    if ($active.Count -gt 0) {
        _wtf_write "    active:   $(@($active | ForEach-Object { Get-WtfSlotTitle $_ }) -join '   ')"
    } else {
        Write-WtfDetail "  active:   none — run ``wtf edit``"
    }
    if ($archived.Count -gt 0) {
        _wtf_write "    archived: $(@($archived | ForEach-Object { Get-WtfSlotTitle $_ }) -join '   ')"
    }

    # ── Plan progress (checkbox counts across the plan tree) ───────────
    $planDir = Join-Path $sel.Dir '.plan'
    if (Test-Path $planDir) {
        Write-WtfInfo "Plan progress:"
        $planMd = Join-Path $planDir '_PLAN.md'
        if (Test-Path $planMd) {
            $p = Get-WtfPlanProgress $planMd
            if ($p.Total -gt 0) { _wtf_write "    · $($T.Bold)_PLAN.md$($T.Reset)  $($p.Done)/$($p.Total) steps" }
        }
        foreach ($d in (Get-ChildItem $planDir -Directory -ErrorAction SilentlyContinue)) {
            $tasks = Join-Path $d.FullName 'tasks.md'
            $p = Get-WtfPlanProgress $tasks
            $bar = if ($p.Total -gt 0) { "$($p.Done)/$($p.Total) tasks" } else { "$($T.Faint)no tasks yet$($T.Reset)" }
            _wtf_write "    · $($T.Bold)$($d.Name)$($T.Reset)  $bar"
        }
    }
}

# ============================================================================
# COMMAND: wtf open
# ============================================================================

function Invoke-WtfOpen {
    param(
        [string]$Context,
        [string]$Project,
        [string]$Branch,
        [switch]$Panes
    )
    if (-not $script:WtfLogFile) { Start-WtfLog 'open' }

    $config = Get-WtfConfig
    if (-not $config) { return }

    if (-not $Context -or -not $Project -or -not $Branch) {
        $features = Get-WtfActiveFeatures -Config $config
        if ($features.Count -eq 0) {
            Write-WtfFail "No active features anywhere."
            return
        }
        $labels = $features | ForEach-Object {
            "$($_.Context)/$($_.Project) · $($_.Branch)  $($script:T.Detail)($($_.Apps -join ', '))$($script:T.Reset)"
        }
        $pick = Read-WtfChoice -Prompt "Open which feature" -Options $labels
        if (-not $pick) { return }
        $idx = [Array]::IndexOf($labels, $pick)
        $f = $features[$idx]
        $Context = $f.Context; $Project = $f.Project; $Branch = $f.Branch
    }

    $featureDir = Get-WtfFeatureDir $config $Context $Project $Branch
    $meta = Read-WtfMeta -FeatureDir $featureDir
    if (-not $meta) { Write-WtfFail "Feature not found: $featureDir"; return }

    if (-not $PSBoundParameters.ContainsKey('Panes')) {
        $Panes = [switch]([bool]$meta.panes)
    }

    $layout = Resolve-WtfFeatureLayout -Config $config -Meta $meta -FeatureDir $featureDir
    $wt     = @($layout.Worktrees)
    $deps   = @($layout.Deps)
    $isMono = ($layout.Type -eq 'mono')

    Write-WtfHeader "Opening $Branch"

    # ── Editor ────────────────────────────────────────────────────────
    # Mono: open the single repo worktree DIRECTLY — no .code-workspace, so VS
    # Code shows the repo at the root (no nested folder-in-folder). The repo's own
    # .plan/ folder rides along, so the agent sees plan + code together.
    # Multi: a workspace genuinely helps (it spans every worktree + deps), so we
    # (re)write and open it as before.
    if ($isMono) {
        $repoDir = if ($wt.Count -gt 0) { $wt[0].Dir } else { $featureDir }
        Write-WtfStep "VS Code (repo folder)"
        Start-Process -FilePath 'code' -ArgumentList @('--', $repoDir) -ErrorAction SilentlyContinue
        Write-WtfOk "code launched → $(Split-Path $repoDir -Leaf)"
    } else {
        $wsPath = Get-WtfWorkspacePath $config $Context $Project $Branch
        # Refresh the workspace so existing features pick up the latest folder
        # markers + phantom-repo hiding on every open.
        $wtNorm = foreach ($w in $wt)   { @{ Name = $w.Name; Dir = $w.Dir } }
        $dpNorm = foreach ($d in $deps) { @{ Name = $d.Name; Dir = $d.Dir } }
        $ignoreRepos = foreach ($w in $wt) { Join-Path $layout.MainDir $w.RelPath }
        Write-WtfWorkspace -WorkspacePath $wsPath -FeatureDir $featureDir -Worktrees @($wtNorm) -Deps @($dpNorm) -IgnoreRepos @($ignoreRepos)
        Write-WtfStep "VS Code workspace"
        Start-Process -FilePath 'code' -ArgumentList @('--', $wsPath) -ErrorAction SilentlyContinue
        Write-WtfOk "code launched"
    }

    $safeBranch = ConvertTo-WtfSafeName $Branch
    $agentWin   = "wtf-agents-$Project-$safeBranch"
    $runnerWin  = "wtf-runners-$Project-$safeBranch"

    # ── Agentic terminals from this feature's slots ───────────────────
    # `open` is DUMB on purpose: it spawns exactly the saved slots (each a real
    # session) and never prompts. A fresh feature has NO slots yet — we don't
    # open empty tabs; we just point you at `wtf edit` to set them up.
    $slots = @(Get-WtfSlots $meta)
    if (@($slots).Count -gt 0) {
        Write-WtfStep "agent window"
        Show-WtfSlotPreview $slots
        Invoke-WtfLaunchAgents -WindowName $agentWin -Slots $slots -FeatureDir $featureDir
        Write-WtfOk "agents → $agentWin"
    } else {
        Write-WtfDetail "No agent sessions saved yet — start your sessions, then run ``wtf edit`` to save them so the next ``wtf open`` resumes as-is."
    }

    if ($wt.Count -gt 0 -or $deps.Count -gt 0) {
        Write-WtfStep "runner window"
        Invoke-WtfLaunchRunners -WindowName $runnerWin -Worktrees $wt -Deps $deps
        Write-WtfOk "runners → $runnerWin"
    }
}

# ============================================================================
# COMMAND: wtf remove
# ============================================================================

function Invoke-WtfRemove {
    param(
        [string]$Context,
        [string]$Project,
        [string]$Branch,
        [switch]$Force,
        [switch]$DryRun
    )
    Start-WtfLog 'remove'
    Write-WtfBanner "remove — tear down a feature"

    $config = Get-WtfConfig
    if (-not $config) { return }

    if (-not $Context -or -not $Project -or -not $Branch) {
        $features = Get-WtfActiveFeatures -Config $config
        if ($features.Count -eq 0) { Write-WtfFail "Nothing to remove."; return }
        $labels = $features | ForEach-Object {
            "$($_.Context)/$($_.Project) · $($_.Branch)"
        }
        $pick = Read-WtfChoice -Prompt "Remove which feature" -Options $labels
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
    Write-WtfDetail "If removal stalls, close this feature's VS Code window and agent/runner"
    Write-WtfDetail "terminals first — open handles lock the files (Windows ‘Permission denied’)."
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
                    Write-WtfWarn "  files locked — close VS Code/terminals on this feature"
                } else {
                    Write-WtfWarn "  git worktree remove failed: $($r.Stderr)"
                }
                if (Test-Path $wtDir) { Remove-Item $wtDir -Recurse -Force -ErrorAction SilentlyContinue }
            }
            Invoke-WtfWorktreePrune -RepoDir $appSrc
        } else {
            Write-WtfWarn "  source repo missing; cleaning files only"
            if (Test-Path $wtDir) { Remove-Item $wtDir -Recurse -Force -ErrorAction SilentlyContinue }
        }

        if (Test-Path $wtDir) {
            $stuck += $app
            Write-WtfFail "  still present (locked): $wtDir"
        } else {
            Write-WtfOk "  removed"
        }
    }

    # Final cleanup: feature folder, sidecar meta, and workspace file.
    if (Test-Path $featureDir) {
        Remove-Item $featureDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $metaPath = Get-WtfMetaPath $featureDir
    if (Test-Path $metaPath) { Remove-Item $metaPath -Force -ErrorAction SilentlyContinue }
    $legacyMeta = Join-Path $featureDir '.wtf-meta.json'
    if (Test-Path $legacyMeta) { Remove-Item $legacyMeta -Force -ErrorAction SilentlyContinue }
    $wsPath = Get-WtfWorkspacePath $config $Context $Project $Branch
    if (Test-Path $wsPath) { Remove-Item $wsPath -Force }

    if ($stuck.Count -gt 0) {
        Write-WtfSummary -Title "Partially removed: $Branch" -Color $script:T.Warn -Lines @(
            "$($script:T.Warn)Locked (still on disk):$($script:T.Reset) $($stuck -join ', ')",
            "$($script:T.Detail)Close the feature's VS Code + terminal windows, then run ``wtf remove`` again$($script:T.Reset)",
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

    Write-WtfSummary -Title "Removed: $Branch" -Lines @(
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

        # Agentic terminals (slots): show each with a ✓ if it has a saved resume
        # command, or an amber "no cmd" if it's open-only / not set up yet.
        $fMeta  = Read-WtfMeta -FeatureDir $f.Dir
        $fSlots = @(Get-WtfSlots $fMeta)
        if ($fSlots.Count -gt 0) {
            $cells = foreach ($s in $fSlots) {
                $t = Get-WtfSlotTitle $s
                if ([string]::IsNullOrWhiteSpace([string]$s.command)) {
                    "$t $($script:T.Warn)·no cmd$($script:T.Reset)"
                } else {
                    "$t $($script:T.Ok)✓$($script:T.Reset)"
                }
            }
            _wtf_write "  $($script:T.Faint)agents:$($script:T.Reset) $($cells -join "   ")"
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
    if (Test-Path $Path) { Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue }
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
    Start-Process -FilePath 'code' -ArgumentList @('--', $script:WtfConfig) -ErrorAction SilentlyContinue
    Write-WtfOk "opened $script:WtfConfig in VS Code"
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

function wtf {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments=$true)][string[]]$Words
    )

    # Flags may appear in ANY position (e.g. `wtf create --panes`). Pull them out
    # first, then treat the remaining tokens positionally: action ctx proj branch apps…
    $pos    = @()
    $panes  = $false
    $force  = $false
    $dryRun = $false
    $fix    = $false
    foreach ($w in @($Words)) {
        switch -Regex ($w) {
            '^--panes$'   { $panes  = $true }
            '^--force$'   { $force  = $true }
            '^-Force$'    { $force  = $true }
            '^--dry-run$' { $dryRun = $true }
            '^-DryRun$'   { $dryRun = $true }
            '^--fix$'     { $fix    = $true }
            '^-Fix$'      { $fix    = $true }
            default       { $pos   += $w }
        }
    }
    $Action  = $pos[0]
    $Context = $pos[1]
    $Project = $pos[2]
    $Branch  = $pos[3]
    $apps    = if ($pos.Count -gt 4) { @($pos[4..($pos.Count - 1)]) } else { @() }

    if (-not $Action) {
        Write-WtfBanner "WorkTree Flow"
        Write-WtfInfo "Commands:"
        Write-WtfDetail "  wtf create  [ctx proj branch apps...] [--dry-run]"
        Write-WtfDetail "  wtf open    [ctx proj branch]          resume the feature's VS Code + agent terminals"
        Write-WtfDetail "  wtf edit    [ctx proj branch]          set up / change this feature's agent terminals"
        Write-WtfDetail "  wtf sessions[ctx proj branch]          list active + archived sessions; reopen one"
        Write-WtfDetail "  wtf status  [ctx proj branch]          feature dashboard: git, sessions, plan progress"
        Write-WtfDetail "  wtf add     [ctx proj branch apps...] [--dry-run]"
        Write-WtfDetail "  wtf remove  [ctx proj branch] [--force] [--dry-run]"
        Write-WtfDetail "  wtf list"
        Write-WtfDetail "  wtf doctor  [-Fix]"
        Write-WtfDetail "  wtf config            (interactive menu)"
        Write-WtfDetail "  wtf config edit       (open config.json directly)"
        Write-WtfDetail ""
        Write-WtfDetail "All args are optional — omit any and you'll be prompted."
        Write-WtfDetail "Each feature has agent terminals (a co-planner + executors). ``wtf edit`` walks you"
        Write-WtfDetail "through them; paste each CLI's full resume command (session id included) and ``wtf open``"
        Write-WtfDetail "re-spawns them as-is. Executors share one tab as panes; planner/researcher get own tabs."
        Write-WtfDetail "Single repos are auto-discovered; run ``wtf config`` to set up roots."
        return
    }

    switch ($Action.ToLower()) {
        'create' { Invoke-WtfCreate -Context $Context -Project $Project -Branch $Branch -Apps $apps -Panes:$panes -DryRun:$dryRun }
        'add'    { Invoke-WtfAdd    -Context $Context -Project $Project -Branch $Branch -Apps $apps -DryRun:$dryRun }
        'open'   { Invoke-WtfOpen   -Context $Context -Project $Project -Branch $Branch -Panes:$panes }
        'edit'   { Invoke-WtfEdit   -Context $Context -Project $Project -Branch $Branch }
        'sessions' { Invoke-WtfSessions -Context $Context -Project $Project -Branch $Branch }
        'session'  { Invoke-WtfSessions -Context $Context -Project $Project -Branch $Branch }
        'status'   { Invoke-WtfStatus   -Context $Context -Project $Project -Branch $Branch }
        'remove' { Invoke-WtfRemove -Context $Context -Project $Project -Branch $Branch -Force:$force -DryRun:$dryRun }
        'rm'     { Invoke-WtfRemove -Context $Context -Project $Project -Branch $Branch -Force:$force -DryRun:$dryRun }
        'list'   { Invoke-WtfList }
        'ls'     { Invoke-WtfList }
        'doctor' { Invoke-WtfDoctor -Fix:$fix }
        'config' { Invoke-WtfConfig -Sub $Context }
        default  { Write-WtfFail "Unknown command: $Action"; wtf }
    }
}

# Done. Source this file from $PROFILE.