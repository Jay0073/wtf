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
    Reset    = "`e[0m"
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
    $bar = "─" * [Math]::Max(0, 64 - $Text.Length - 4)
    [Console]::Out.WriteLine()
    _wtf_write "── $Text $bar" "$($T.Header)$($T.Bold)"
    Write-WtfLog "PHASE: $Text"
}

function Write-WtfOk     { param([string]$M) _wtf_write "  ✓ $M" $script:T.Ok;     Write-WtfLog "OK: $M" }
function Write-WtfWarn   { param([string]$M) _wtf_write "  ⚠ $M" $script:T.Warn;   Write-WtfLog "WARN: $M" }
function Write-WtfFail   { param([string]$M) _wtf_write "  ✗ $M" $script:T.Fail;   Write-WtfLog "FAIL: $M" }
function Write-WtfDetail { param([string]$M) _wtf_write "    $M" $script:T.Detail; Write-WtfLog "DETAIL: $M" }
function Write-WtfStep   { param([string]$M) _wtf_write "  → $M" $script:T.Accent; Write-WtfLog "STEP: $M" }
function Write-WtfInfo   { param([string]$M) _wtf_write "  · $M" $script:T.Prompt; Write-WtfLog "INFO: $M" }

function Write-WtfSummary {
    # Bordered summary block for end-of-command recap
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [string]$Color = ''
    )
    $T = $script:T
    if (-not $Color) { $Color = $T.Ok }
    $width = 66
    $top    = "╭" + ("─" * ($width - 2)) + "╮"
    $bot    = "╰" + ("─" * ($width - 2)) + "╯"
    [Console]::Out.WriteLine()
    _wtf_write $top $Color
    $titlePad = $width - 4 - $Title.Length
    _wtf_write ("│ " + $T.Bold + $Title + $T.Reset + $Color + (" " * $titlePad) + " │") $Color
    _wtf_write ("│" + (" " * ($width - 2)) + "│") $Color
    foreach ($l in $Lines) {
        # strip ANSI from length calc
        $clean = $l -replace "`e\[[\d;]*m", ''
        $pad = $width - 4 - $clean.Length
        if ($pad -lt 0) { $pad = 0 }
        _wtf_write ("│ " + $l + (" " * $pad) + " │") $Color
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
        _wtf_write "$($script:T.Prompt)?$($script:T.Reset) $Prompt $($script:T.Ok)$($Options[0])$($script:T.Reset) $($script:T.Detail)(only option)$($script:T.Reset)"
        return $Options[0]
    }

    $T = $script:T
    $sel = [Math]::Max(0, [Math]::Min($Default, $Options.Count - 1))
    $rendered = 0

    [Console]::Out.Write($T.HideCur)
    try {
        while ($true) {
            _wtf_render_clear $rendered
            [Console]::Out.WriteLine("$($T.Prompt)?$($T.Reset) $($T.Bold)$Prompt$($T.Reset) $($T.Detail)(↑↓ to move, enter to select)$($T.Reset)")
            for ($i = 0; $i -lt $Options.Count; $i++) {
                $desc = if ($Descriptions -and $i -lt $Descriptions.Count) { "  $($T.Detail)$($Descriptions[$i])$($T.Reset)" } else { '' }
                if ($i -eq $sel) {
                    [Console]::Out.WriteLine("$($T.Ok)▶ $($Options[$i])$($T.Reset)$desc")
                } else {
                    [Console]::Out.WriteLine("$($T.Detail)  $($Options[$i])$($T.Reset)$desc")
                }
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
                    _wtf_write "$($T.Prompt)?$($T.Reset) $Prompt $($T.Ok)$($Options[$sel])$($T.Reset)"
                    return $Options[$sel]
                }
                'Escape' {
                    _wtf_render_clear $rendered
                    _wtf_write "$($T.Prompt)?$($T.Reset) $Prompt $($T.Fail)cancelled$($T.Reset)"
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
            [Console]::Out.WriteLine("$($T.Prompt)?$($T.Reset) $($T.Bold)$Prompt$($T.Reset) $($T.Detail)(space toggle · a all · n none · enter confirm)$($T.Reset)")
            for ($i = 0; $i -lt $Options.Count; $i++) {
                $opt   = $Options[$i]
                $on    = $selected.Contains($opt)
                $mark  = if ($on) { "$($T.Ok)●$($T.Reset)" } else { "$($T.Detail)○$($T.Reset)" }
                $arrow = if ($i -eq $cursor) { "$($T.Accent)▶$($T.Reset)" } else { ' ' }
                $name  = if ($i -eq $cursor) { "$($T.Bold)$opt$($T.Reset)" } else { "$($T.Detail)$opt$($T.Reset)" }
                $desc  = if ($Descriptions -and $i -lt $Descriptions.Count) { "  $($T.Detail)$($Descriptions[$i])$($T.Reset)" } else { '' }
                [Console]::Out.WriteLine("$arrow $mark $name$desc")
            }
            if ($errorMsg) {
                [Console]::Out.WriteLine("$($T.Fail)  $errorMsg$($T.Reset)")
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
                    _wtf_write "$($T.Prompt)?$($T.Reset) $Prompt $($T.Ok)$shown$($T.Reset)"
                    return $result
                }
                'Escape' {
                    _wtf_render_clear $rendered
                    _wtf_write "$($T.Prompt)?$($T.Reset) $Prompt $($T.Fail)cancelled$($T.Reset)"
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
        [Console]::Out.Write("$($T.Prompt)?$($T.Reset) $($T.Bold)$Prompt$($T.Reset)$hintTxt$defTxt $($T.Accent)›$($T.Reset) ")
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
    [Console]::Out.Write("$($T.Prompt)?$($T.Reset) $($T.Bold)$Prompt$($T.Reset) $($T.Detail)$hint$($T.Reset) $($T.Accent)›$($T.Reset) ")
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
        [bool]$Panes = $false
    )
    @{
        version   = 2
        context   = $Context
        project   = $Project
        type      = $Type
        branch    = $Branch
        apps      = @($Apps)
        appPaths  = $AppPaths
        deps      = @($Deps)
        panes     = $Panes
        createdAt = (Get-Date -Format o)
    }
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
        [string]$Project = ''
    )
    $appList = ($Apps | ForEach-Object { "- ``$_``" }) -join "`n"
    # Literal here-string (no interpolation) so markdown backticks stay literal;
    # dynamic values are injected via token replacement below.
    $tpl = @'
# Feature: {{BRANCH}}

**Project:** {{PROJECT}}  ·  **Worktrees in scope:** {{APPS}}  ·  **Created:** {{DATE}}

> Single source of truth for this feature. A fresh agent session should read
> this file first to resume with full context.

---

<!-- ════════════════ PLANNING BRIEF — delete once the plan is written ════════════════
     Everything in this block is instructions FOR the planning agent, not the plan. -->

## ▶ Planning brief (delete this whole section once the plan below is done)

You are the planning agent for this feature. **Do not start coding yet.** Produce a
rigorous, researched plan in the sections that follow, then remove this brief.

**1. Understand before planning.**
- Read the Goal below. If it's empty or vague, ask the user — do not invent scope.
- Explore the repos in this workspace (the `🌿` worktree folders): stack, existing
  conventions, patterns to reuse, and exactly where this feature will touch.

**2. Research — don't rely on memory.**
- Web-search for: the CURRENT docs/API of the libraries involved, prior art and
  similar implementations (including open source), known pitfalls, and the
  recommended pattern for this kind of change.
- Prefer primary sources (official docs, RFCs, the library's own source) over blogs.
- Verify anything version-specific against the version actually in the repo.
- Log every source you used under **Research & References** with a one-line takeaway.

**3. Ideate, then choose.**
- Sketch 2–3 viable approaches. For each: how it works, pros, cons, risk, effort,
  and blast radius across the worktrees.
- Pick one and justify it under **Decisions**. Record the rejected options and why,
  so nobody re-litigates them later.

**4. De-risk.**
- List assumptions and open questions; resolve what you can now, flag the rest.
- Identify edge cases, failure modes, migration/rollback, and how you'll test.

**5. Write the plan.**
- Fill every section below with concrete, checkable steps — not vague verbs.
- Keep steps small enough to verify independently, ordered by dependency.
- Then **delete this entire brief** so the file reads as a clean plan.

**Quality bar:** a different engineer (or a fresh agent) should be able to execute
the plan below without asking what you meant.

<!-- ════════════════ END PLANNING BRIEF ════════════════ -->

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

### Steps (ordered, checkable)

- [ ]
- [ ]
- [ ]

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
        Replace('{{BRANCH}}',  $Branch).
        Replace('{{PROJECT}}', $Project).
        Replace('{{APPS}}',    ($Apps -join ', ')).
        Replace('{{DATE}}',    (Get-Date -Format 'yyyy-MM-dd HH:mm')).
        Replace('{{APPLIST}}', $appList)
    Write-WtfFile -Path $Path -Content $content
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

function Invoke-WtfLaunchAgents {
    <#
    .SYNOPSIS
        Open the Agent window. Multi: a top-level 🧠 planner tab at the feature
        root (sees every repo + _PLAN.md, for orchestration), then a tab (or
        pane) per worktree repo. Mono: just the single repo — the planner context
        IS the worktree, so one tab is enough.
    #>
    param(
        [Parameter(Mandatory)][string]$WindowName,
        [Parameter(Mandatory)]$Worktrees,        # array of @{ Name; Dir }
        [Parameter(Mandatory)][string]$FeatureDir,
        [bool]$Panes = $false,
        [bool]$Mono  = $false
    )
    $list = @($Worktrees)
    if ($list.Count -eq 0) { return }

    $color   = $script:TabColors.Agent
    $planClr = $script:TabColors.Planner
    $argv    = @('-w', $WindowName)
    $first   = $true

    if (-not $Mono) {
        $argv += @('new-tab','-d', $FeatureDir, '--title', "🧠 plan", '--tabColor', $planClr)
        $first = $false
    }

    for ($i = 0; $i -lt $list.Count; $i++) {
        $title = "🤖 $($list[$i].Name)"
        $dir   = $list[$i].Dir
        if ($first) {
            $argv += @('new-tab','-d', $dir, '--title', $title, '--tabColor', $color)
            $first = $false
        } elseif ($Panes) {
            $argv += @(';','split-pane','-d', $dir, '--title', $title)
        } else {
            $argv += @(';','new-tab','-d', $dir, '--title', $title, '--tabColor', $color)
        }
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
    Write-WtfInfo "Agent UI:   $(if ($Panes) { 'split panes' } else { 'tabs' })"
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

    # ── Artifacts ─────────────────────────────────────────────────────
    Write-WtfHeader "Artifacts"
    # Mono: _PLAN.md at the repo root (handy for the agent). Multi: in .plan/ so
    # the workspace's "plan" folder doesn't double up the worktree subfolders.
    if ($isMono) {
        $planFile = Join-Path $featureDir '_PLAN.md'
    } else {
        $planDir  = Join-Path $featureDir '.plan'
        New-Item -ItemType Directory -Path $planDir -Force | Out-Null
        $planFile = Join-Path $planDir '_PLAN.md'
    }
    Write-WtfPlan -Path $planFile -Branch $Branch -Apps $wtNames -Project $projectName
    Write-WtfOk "_PLAN.md scaffolded"

    # Mono: _PLAN.md lives INSIDE the repo (handy for agents). Exclude it locally
    # so it can never be staged/committed. (.wtf-meta.json is a sidecar OUTSIDE
    # the repo, so it needs no exclusion and survives any git clean/checkout.)
    if ($isMono) {
        Add-WtfGitExclude -WorktreeDir $featureDir -Patterns @('/_PLAN.md')
        Write-WtfOk "git-ignored _PLAN.md locally (won't be committed)"
    }

    Write-WtfWorkspace -WorkspacePath $workspaceFp -FeatureDir $featureDir -Worktrees @($wtList) -Deps @($depNorm) -IgnoreRepos @($ignoreRepos)
    Write-WtfOk "workspace written: $(Split-Path $workspaceFp -Leaf)"

    $appPaths = @{}
    foreach ($short in $wtNames) { $appPaths[$short] = $worktreeMap[$short] }
    $metaDeps = foreach ($d in $depList) { @{ name = $d.Name; path = $d.RelPath } }
    $metaApps = if ($isMono) { @() } else { @($wtNames) }
    $meta = New-WtfMeta -Context $Context -Project $projectName -Branch $Branch `
                        -Type $(if ($isMono) { 'mono' } else { 'multi' }) `
                        -Apps $metaApps -AppPaths $appPaths -Deps @($metaDeps) -Panes $Panes.IsPresent
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

    $newMeta = New-WtfMeta -Context $Context -Project $Project -Branch $Branch -Type 'multi' `
                           -Apps $newApps -AppPaths $appPaths -Deps @($deps) -Panes ([bool]$meta.panes)
    $newMeta.createdAt = $meta.createdAt
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

    $wsPath = Get-WtfWorkspacePath $config $Context $Project $Branch
    $layout = Resolve-WtfFeatureLayout -Config $config -Meta $meta -FeatureDir $featureDir
    $wt     = @($layout.Worktrees)
    $deps   = @($layout.Deps)

    Write-WtfHeader "Opening $Branch"
    # Refresh the workspace from current logic so existing features pick up the
    # latest folder markers + phantom-repo hiding on every open.
    $wtNorm = foreach ($w in $wt)   { @{ Name = $w.Name; Dir = $w.Dir } }
    $dpNorm = foreach ($d in $deps) { @{ Name = $d.Name; Dir = $d.Dir } }
    $ignoreRepos = foreach ($w in $wt) { Join-Path $layout.MainDir $w.RelPath }
    Write-WtfWorkspace -WorkspacePath $wsPath -FeatureDir $featureDir -Worktrees @($wtNorm) -Deps @($dpNorm) -IgnoreRepos @($ignoreRepos)

    Write-WtfStep "VS Code workspace"
    Start-Process -FilePath 'code' -ArgumentList @('--', $wsPath) -ErrorAction SilentlyContinue
    Write-WtfOk "code launched"

    $safeBranch = ConvertTo-WtfSafeName $Branch
    $agentWin   = "wtf-agents-$Project-$safeBranch"
    $runnerWin  = "wtf-runners-$Project-$safeBranch"

    if ($wt.Count -gt 0) {
        Write-WtfStep "agent window ($(if ($Panes) { 'panes' } else { 'tabs' }))"
        Invoke-WtfLaunchAgents -WindowName $agentWin -Worktrees $wt -FeatureDir $featureDir -Panes:$Panes -Mono:($layout.Type -eq 'mono')
        Write-WtfOk "agents → $agentWin"
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
        Write-WtfDetail "  wtf create  [ctx proj branch apps...] [--panes] [--dry-run]"
        Write-WtfDetail "  wtf open    [ctx proj branch] [--panes]"
        Write-WtfDetail "  wtf add     [ctx proj branch apps...] [--dry-run]"
        Write-WtfDetail "  wtf remove  [ctx proj branch] [--force] [--dry-run]"
        Write-WtfDetail "  wtf list"
        Write-WtfDetail "  wtf doctor  [-Fix]"
        Write-WtfDetail "  wtf config            (interactive menu)"
        Write-WtfDetail "  wtf config edit       (open config.json directly)"
        Write-WtfDetail ""
        Write-WtfDetail "All args are optional — omit any and you'll be prompted."
        Write-WtfDetail "Flags work in any position, e.g. ``wtf create --panes`` (agent repos as split"
        Write-WtfDetail "panes instead of tabs; remembered, so ``wtf open`` reuses it)."
        Write-WtfDetail "Single repos are auto-discovered; run ``wtf config`` to set up roots."
        return
    }

    switch ($Action.ToLower()) {
        'create' { Invoke-WtfCreate -Context $Context -Project $Project -Branch $Branch -Apps $apps -Panes:$panes -DryRun:$dryRun }
        'add'    { Invoke-WtfAdd    -Context $Context -Project $Project -Branch $Branch -Apps $apps -DryRun:$dryRun }
        'open'   { Invoke-WtfOpen   -Context $Context -Project $Project -Branch $Branch -Panes:$panes }
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