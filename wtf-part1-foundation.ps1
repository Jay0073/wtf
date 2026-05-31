# wtf.ps1 — WorkTree Flow orchestrator
# PowerShell 5.1 compatible
#
# Install:
#   1. Create folder: C:\Users\<you>\.wtf\
#   2. Put config.json inside it
#   3. Dot-source this file from your $PROFILE:
#        . "$env:USERPROFILE\.wtf\wtf.ps1"
#   4. Reload: . $PROFILE
#
# Usage:
#   wtf create                          # fully interactive
#   wtf create company workelate feature/x backend hub
#   wtf open / add / remove / list / doctor / config

# ============================================================================
# GLOBAL STATE
# ============================================================================

$script:WtfRoot     = Join-Path $env:USERPROFILE ".wtf"
$script:WtfConfig   = Join-Path $script:WtfRoot "config.json"
$script:WtfLogDir   = Join-Path $script:WtfRoot "logs"
$script:WtfLogFile  = $null    # set per-command in Start-WtfLog

# Color discipline — exactly five colors, no more.
$script:Colors = @{
    Prompt  = 'Cyan'
    Ok      = 'Green'
    Warn    = 'Yellow'
    Fail    = 'Red'
    Detail  = 'DarkGray'
    Header  = 'Magenta'
}

# Tab colors for Windows Terminal (#RRGGBB)
$script:TabColors = @{
    Agent       = '#7C3AED'   # purple
    RunnerFeat  = '#10B981'   # green
    RunnerMain  = '#6B7280'   # gray
}

# ============================================================================
# ENCODING: UTF-8 WITHOUT BOM (the PS 5.1 dance)
# ============================================================================
# Out-File and Set-Content on PS 5.1 default to UTF-16 LE with BOM, which
# breaks .env consumers, .code-workspace JSON parsers, and git hooks.
# Always use these helpers for file writes.

function Write-WtfFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )
    $enc = New-Object System.Text.UTF8Encoding $false   # $false = no BOM
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Write-WtfJson {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Object,
        [int]$Depth = 10
    )
    $json = $Object | ConvertTo-Json -Depth $Depth
    Write-WtfFile -Path $Path -Content $json
}

function Read-WtfJson {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

# ============================================================================
# PSCUSTOMOBJECT HELPERS
# ============================================================================
# ConvertFrom-Json returns PSCustomObject (not hashtable) on PS 5.1, so
# .Contains() and .Keys don't work directly. These helpers paper over it.

function Get-ObjectKeys {
    param([Parameter(Mandatory=$true)]$Object)
    if ($null -eq $Object) { return @() }
    if ($Object -is [hashtable]) { return @($Object.Keys) }
    return @($Object.PSObject.Properties.Name)
}

function Test-ObjectHasKey {
    param(
        [Parameter(Mandatory=$true)]$Object,
        [Parameter(Mandatory=$true)][string]$Key
    )
    if ($null -eq $Object) { return $false }
    if ($Object -is [hashtable]) { return $Object.ContainsKey($Key) }
    return $null -ne $Object.PSObject.Properties[$Key]
}

function Get-ObjectValue {
    param(
        [Parameter(Mandatory=$true)]$Object,
        [Parameter(Mandatory=$true)][string]$Key
    )
    if ($Object -is [hashtable]) { return $Object[$Key] }
    return $Object.$Key
}

# ============================================================================
# LOGGING
# ============================================================================

function Start-WtfLog {
    param([Parameter(Mandatory=$true)][string]$Command)
    if (-not (Test-Path $script:WtfLogDir)) {
        New-Item -ItemType Directory -Path $script:WtfLogDir -Force | Out-Null
    }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $script:WtfLogFile = Join-Path $script:WtfLogDir "$stamp-$Command.log"
    Write-WtfFile -Path $script:WtfLogFile -Content "[wtf $Command] started $(Get-Date -Format o)`n"
}

function Write-WtfLog {
    param([Parameter(Mandatory=$true)][string]$Message)
    if ($null -eq $script:WtfLogFile) { return }
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $Message`n"
    [System.IO.File]::AppendAllText($script:WtfLogFile, $line, [System.Text.UTF8Encoding]::new($false))
}

# ============================================================================
# OUTPUT HELPERS
# ============================================================================

function Write-WtfHeader {
    param([Parameter(Mandatory=$true)][string]$Text)
    $line = "── $Text " + ("─" * [Math]::Max(0, 60 - $Text.Length))
    Write-Host ""
    Write-Host $line -ForegroundColor $script:Colors.Header
    Write-WtfLog "PHASE: $Text"
}

function Write-WtfOk     { param([string]$Msg) Write-Host "  ✓ $Msg" -ForegroundColor $script:Colors.Ok;     Write-WtfLog "OK: $Msg" }
function Write-WtfWarn   { param([string]$Msg) Write-Host "  ⚠ $Msg" -ForegroundColor $script:Colors.Warn;   Write-WtfLog "WARN: $Msg" }
function Write-WtfFail   { param([string]$Msg) Write-Host "  ✗ $Msg" -ForegroundColor $script:Colors.Fail;   Write-WtfLog "FAIL: $Msg" }
function Write-WtfDetail { param([string]$Msg) Write-Host "    $Msg"  -ForegroundColor $script:Colors.Detail; Write-WtfLog "DETAIL: $Msg" }
function Write-WtfStep   { param([string]$Msg) Write-Host "  → $Msg" -ForegroundColor $script:Colors.Prompt; Write-WtfLog "STEP: $Msg" }

# ============================================================================
# SPINNER (for genuine waits, not fake ones)
# ============================================================================

function Invoke-WtfWithSpinner {
    param(
        [Parameter(Mandatory=$true)][string]$Label,
        [Parameter(Mandatory=$true)][scriptblock]$Action
    )
    $frames = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
    $i = 0
    $job = Start-Job -ScriptBlock $Action

    try {
        while ($job.State -eq 'Running') {
            $frame = $frames[$i % $frames.Length]
            Write-Host "`r  $frame $Label" -ForegroundColor $script:Colors.Detail -NoNewline
            Start-Sleep -Milliseconds 80
            $i++
        }
        $result = Receive-Job -Job $job -Wait
        $finalState = $job.State
        Remove-Job -Job $job -Force

        # Clear the spinner line
        Write-Host "`r$(' ' * ($Label.Length + 6))`r" -NoNewline

        if ($finalState -eq 'Failed') {
            return @{ Ok = $false; Output = $result; Error = $job.ChildJobs[0].JobStateInfo.Reason }
        }
        return @{ Ok = $true; Output = $result }
    }
    catch {
        Write-Host ""
        return @{ Ok = $false; Error = $_ }
    }
}

# ============================================================================
# INTERACTIVE PROMPTS (PSReadLine-based, PS 5.1 compatible)
# ============================================================================

function Read-WtfChoice {
    <#
    .SYNOPSIS
        Arrow-key single-select picker.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [Parameter(Mandatory=$true)][string[]]$Options,
        [int]$Default = 0
    )
    if ($Options.Count -eq 0) { return $null }
    if ($Options.Count -eq 1) {
        Write-Host "? $Prompt " -ForegroundColor $script:Colors.Prompt -NoNewline
        Write-Host "$($Options[0]) (only option)" -ForegroundColor $script:Colors.Detail
        return $Options[0]
    }

    $selected = $Default
    $rendered = $false

    function Render {
        param($sel)
        if ($script:_renderedLines) {
            for ($i = 0; $i -lt $script:_renderedLines; $i++) {
                [Console]::SetCursorPosition(0, [Console]::CursorTop - 1)
                Write-Host (' ' * [Console]::WindowWidth) -NoNewline
                [Console]::SetCursorPosition(0, [Console]::CursorTop)
            }
        }
        Write-Host "? $Prompt" -ForegroundColor $script:Colors.Prompt
        for ($i = 0; $i -lt $Options.Count; $i++) {
            if ($i -eq $sel) {
                Write-Host "  ▶ $($Options[$i])" -ForegroundColor $script:Colors.Ok
            } else {
                Write-Host "    $($Options[$i])" -ForegroundColor $script:Colors.Detail
            }
        }
        $script:_renderedLines = $Options.Count + 1
    }

    $script:_renderedLines = 0
    Render $selected

    while ($true) {
        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow'   { $selected = ($selected - 1 + $Options.Count) % $Options.Count; Render $selected }
            'DownArrow' { $selected = ($selected + 1) % $Options.Count; Render $selected }
            'Enter'     {
                # Final render showing only the selection
                for ($i = 0; $i -lt $script:_renderedLines; $i++) {
                    [Console]::SetCursorPosition(0, [Console]::CursorTop - 1)
                    Write-Host (' ' * [Console]::WindowWidth) -NoNewline
                    [Console]::SetCursorPosition(0, [Console]::CursorTop)
                }
                Write-Host "? $Prompt " -ForegroundColor $script:Colors.Prompt -NoNewline
                Write-Host $Options[$selected] -ForegroundColor $script:Colors.Ok
                return $Options[$selected]
            }
            'Escape'    { return $null }
        }
    }
}

function Read-WtfMultiChoice {
    <#
    .SYNOPSIS
        Space-to-toggle multi-select with arrow-key navigation.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [Parameter(Mandatory=$true)][string[]]$Options,
        [string[]]$Preselected = @()
    )
    if ($Options.Count -eq 0) { return @() }

    $selected = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($p in $Preselected) { [void]$selected.Add($p) }
    $cursor = 0
    $script:_renderedLines = 0

    function RenderMulti {
        param($cur, $sel)
        if ($script:_renderedLines) {
            for ($i = 0; $i -lt $script:_renderedLines; $i++) {
                [Console]::SetCursorPosition(0, [Console]::CursorTop - 1)
                Write-Host (' ' * [Console]::WindowWidth) -NoNewline
                [Console]::SetCursorPosition(0, [Console]::CursorTop)
            }
        }
        Write-Host "? $Prompt " -ForegroundColor $script:Colors.Prompt -NoNewline
        Write-Host "(space=toggle, enter=confirm)" -ForegroundColor $script:Colors.Detail
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $mark = if ($sel.Contains($Options[$i])) { "[x]" } else { "[ ]" }
            $arrow = if ($i -eq $cur) { "▶" } else { " " }
            $color = if ($i -eq $cur) { $script:Colors.Ok } else { $script:Colors.Detail }
            Write-Host "  $arrow $mark $($Options[$i])" -ForegroundColor $color
        }
        $script:_renderedLines = $Options.Count + 1
    }

    RenderMulti $cursor $selected

    while ($true) {
        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow'   { $cursor = ($cursor - 1 + $Options.Count) % $Options.Count; RenderMulti $cursor $selected }
            'DownArrow' { $cursor = ($cursor + 1) % $Options.Count; RenderMulti $cursor $selected }
            'Spacebar'  {
                if ($selected.Contains($Options[$cursor])) {
                    [void]$selected.Remove($Options[$cursor])
                } else {
                    [void]$selected.Add($Options[$cursor])
                }
                RenderMulti $cursor $selected
            }
            'Enter'     {
                for ($i = 0; $i -lt $script:_renderedLines; $i++) {
                    [Console]::SetCursorPosition(0, [Console]::CursorTop - 1)
                    Write-Host (' ' * [Console]::WindowWidth) -NoNewline
                    [Console]::SetCursorPosition(0, [Console]::CursorTop)
                }
                $result = @($selected)
                Write-Host "? $Prompt " -ForegroundColor $script:Colors.Prompt -NoNewline
                Write-Host ($result -join ', ') -ForegroundColor $script:Colors.Ok
                return $result
            }
            'Escape'    { return @() }
        }
    }
}

function Read-WtfText {
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [string]$Default = '',
        [scriptblock]$Validator = $null
    )
    while ($true) {
        Write-Host "? $Prompt" -ForegroundColor $script:Colors.Prompt -NoNewline
        if ($Default) { Write-Host " [$Default]" -ForegroundColor $script:Colors.Detail -NoNewline }
        Write-Host " " -NoNewline
        $input = [Console]::ReadLine()
        if ([string]::IsNullOrWhiteSpace($input)) { $input = $Default }
        if ([string]::IsNullOrWhiteSpace($input)) {
            Write-WtfFail "Value required."
            continue
        }
        if ($Validator) {
            $err = & $Validator $input
            if ($err) {
                Write-WtfFail $err
                continue
            }
        }
        return $input
    }
}

function Read-WtfConfirm {
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [bool]$Default = $true
    )
    $suffix = if ($Default) { "[Y/n]" } else { "[y/N]" }
    Write-Host "? $Prompt $suffix " -ForegroundColor $script:Colors.Prompt -NoNewline
    $input = [Console]::ReadLine()
    if ([string]::IsNullOrWhiteSpace($input)) { return $Default }
    return $input.Trim().ToLower() -in @('y','yes')
}

# ============================================================================
# CONFIG LOADING
# ============================================================================

function Get-WtfConfig {
    if (-not (Test-Path $script:WtfConfig)) {
        Write-WtfFail "Config not found at $script:WtfConfig"
        Write-WtfDetail "Create the folder ~/.wtf/ and drop your config.json there."
        return $null
    }
    try {
        return Read-WtfJson -Path $script:WtfConfig
    } catch {
        Write-WtfFail "Config JSON is malformed: $_"
        return $null
    }
}

# ============================================================================
# PATH / BRANCH UTILITIES
# ============================================================================

function ConvertTo-WtfSafeName {
    param([Parameter(Mandatory=$true)][string]$Name)
    # Sanitize branch name into a folder-safe slug.
    # feature/auth-refactor → feature-auth-refactor
    # release/v2.1.0       → release-v2.1.0   (dots preserved, they're folder-legal)
    return ($Name -replace '[\\/:*?"<>|]', '-').Trim('-')
}

function Get-WtfFeatureDir {
    param(
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$true)][string]$Context,
        [Parameter(Mandatory=$true)][string]$Project,
        [Parameter(Mandatory=$true)][string]$Branch
    )
    $ctxConfig = Get-ObjectValue $Config.contexts $Context
    $wtRoot    = $ctxConfig.worktreeDir
    $safe      = ConvertTo-WtfSafeName $Branch
    return Join-Path $wtRoot "$Project-$safe"
}

function Get-WtfWorkspacePath {
    param(
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$true)][string]$Context,
        [Parameter(Mandatory=$true)][string]$Project,
        [Parameter(Mandatory=$true)][string]$Branch
    )
    $ctxConfig = Get-ObjectValue $Config.contexts $Context
    $wsDir     = $ctxConfig.workspaceDir
    $safe      = ConvertTo-WtfSafeName $Branch
    return Join-Path $wsDir "$Project-$safe.code-workspace"
}

function Test-WtfBranchName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "Branch name cannot be empty." }
    if ($Name -match '\s') { return "Branch name cannot contain whitespace." }
    if ($Name.Length -gt 100) { return "Branch name too long (max 100 chars)." }
    return $null  # null = valid
}

# ============================================================================
# GIT UTILITIES
# ============================================================================

function Invoke-WtfGit {
    <#
    .SYNOPSIS
        Run git in a specific directory, capture output, log it.
    .OUTPUTS
        Hashtable: @{ Ok = bool; Stdout = string; Stderr = string; ExitCode = int }
    #>
    param(
        [Parameter(Mandatory=$true)][string]$WorkingDir,
        [Parameter(Mandatory=$true)][string[]]$Args
    )
    Write-WtfLog "GIT [$WorkingDir]: git $($Args -join ' ')"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = "git"
    $psi.WorkingDirectory = $WorkingDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    foreach ($a in $Args) { [void]$psi.ArgumentList.Add($a) } 2>$null
    # PS 5.1 doesn't have ArgumentList on ProcessStartInfo — fall back to Arguments string
    if (-not $psi.ArgumentList -or $psi.ArgumentList.Count -eq 0) {
        $quoted = $Args | ForEach-Object {
            if ($_ -match '\s') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
        }
        $psi.Arguments = $quoted -join ' '
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    Write-WtfLog "GIT exit=$($proc.ExitCode) stdout=$($stdout.Trim()) stderr=$($stderr.Trim())"
    return @{
        Ok       = ($proc.ExitCode -eq 0)
        Stdout   = $stdout.Trim()
        Stderr   = $stderr.Trim()
        ExitCode = $proc.ExitCode
    }
}

function Get-WtfDefaultBranch {
    <#
    .SYNOPSIS
        Resolve the actual default branch for a repo (main, master, develop, …).
        Falls back to 'main' if origin/HEAD isn't set.
    #>
    param([Parameter(Mandatory=$true)][string]$RepoDir)
    $r = Invoke-WtfGit -WorkingDir $RepoDir -Args @('symbolic-ref','refs/remotes/origin/HEAD')
    if ($r.Ok -and $r.Stdout) {
        # Output looks like: refs/remotes/origin/main
        return ($r.Stdout -split '/')[-1]
    }
    # Fallback: try to set it
    $r2 = Invoke-WtfGit -WorkingDir $RepoDir -Args @('remote','set-head','origin','--auto')
    if ($r2.Ok) {
        $r3 = Invoke-WtfGit -WorkingDir $RepoDir -Args @('symbolic-ref','refs/remotes/origin/HEAD')
        if ($r3.Ok -and $r3.Stdout) { return ($r3.Stdout -split '/')[-1] }
    }
    return 'main'
}

function Resolve-WtfBranchSource {
    <#
    .SYNOPSIS
        Determine how to create a worktree for $Branch in $RepoDir.
    .OUTPUTS
        Hashtable: @{ Mode = 'local'|'remote'|'new'; BaseRef = string }
        - local:  branch exists locally, just check it out
        - remote: branch exists only on origin, track it
        - new:    create fresh from origin/<default>
    #>
    param(
        [Parameter(Mandatory=$true)][string]$RepoDir,
        [Parameter(Mandatory=$true)][string]$Branch
    )
    # Local branch?
    $local = Invoke-WtfGit -WorkingDir $RepoDir -Args @('show-ref','--verify','--quiet',"refs/heads/$Branch")
    if ($local.Ok) {
        return @{ Mode = 'local'; BaseRef = $Branch }
    }
    # Remote branch?
    $remote = Invoke-WtfGit -WorkingDir $RepoDir -Args @('show-ref','--verify','--quiet',"refs/remotes/origin/$Branch")
    if ($remote.Ok) {
        return @{ Mode = 'remote'; BaseRef = "origin/$Branch" }
    }
    # Doesn't exist — create from default
    $default = Get-WtfDefaultBranch -RepoDir $RepoDir
    return @{ Mode = 'new'; BaseRef = "origin/$default" }
}

# ============================================================================
# ENV BRIDGE
# ============================================================================

function Copy-WtfEnvFiles {
    <#
    .SYNOPSIS
        Copy all .env* files from source repo to the new worktree.
    .OUTPUTS
        Array of copied file names.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Destination
    )
    $copied = @()
    $envFiles = Get-ChildItem -Path $Source -Filter ".env*" -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer }
    foreach ($f in $envFiles) {
        $dest = Join-Path $Destination $f.Name
        Copy-Item -Path $f.FullName -Destination $dest -Force
        $copied += $f.Name
    }
    return $copied
}

# ============================================================================
# (Continued in part 2: create, open, add, remove, list, doctor, dispatcher)
# ============================================================================