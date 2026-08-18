# wtf-tab.ps1 — the commands you actually type, for tab layouts.
#
#   wtf snap [name]        capture the tab you are in (or the one in front)
#   wtf tab ls             list saved layouts
#   wtf tab open [name]    rebuild a layout as a new tab in this window
#   wtf tab edit [name]    open a layout file to change commands by hand
#   wtf tab rm [name]      delete a layout
#
# Requires wtf-layout.ps1 (the capture/restore engine) to be loaded first.
#
# Runs on Windows PowerShell 5.1 and PowerShell 7+ alike: no `e escapes, no
# ternary or null-coalescing operators. Save as UTF-8 WITH BOM.

if (-not $script:WtfRoot) { $script:WtfRoot = Join-Path $env:USERPROFILE '.wtf' }

$script:WtfEsc = [char]27

# ============================================================================
# TERMINAL UI PRIMITIVES
# ============================================================================

function Write-WtfRaw { param([string]$S) [Console]::Out.Write($S) }

function Write-WtfTitle {
    param([string]$Text)
    $E = $script:WtfEsc
    Write-WtfRaw "`n$E[38;5;141m$E[1m  $Text$E[0m`n"
    Write-WtfRaw "$E[38;5;240m  $('-' * [Math]::Min(60, $Text.Length + 12))$E[0m`n"
}

function Read-WtfPick {
    <#
    .SYNOPSIS
        Arrow-key picker. Returns the chosen index, or -1 if cancelled.
    .DESCRIPTION
        Redraw works by moving the cursor UP over the rows already on screen and
        rewriting each one in place. The list is drawn exactly once and then
        overwritten; it never grows as you move up and down.

        Each line is cleared with ESC[2K before writing, so a shorter line can
        never leave the tail of a longer one behind it.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Options,
        [string[]]$Hints = @(),
        [int]$Start = 0
    )
    $E = $script:WtfEsc
    $n = $Options.Count
    if ($n -eq 0) { return -1 }

    $sel = $Start
    if ($sel -lt 0 -or $sel -ge $n) { $sel = 0 }

    Write-WtfTitle $Title
    Write-WtfRaw "$E[?25l"          # hide the cursor while we redraw

    $drawn = $false
    try {
        while ($true) {
            if ($drawn) { Write-WtfRaw "$E[${n}A" }   # jump back over the rows

            for ($i = 0; $i -lt $n; $i++) {
                $hint = ''
                if ($i -lt $Hints.Count -and $Hints[$i]) { $hint = "  $E[38;5;240m$($Hints[$i])$E[0m" }
                if ($i -eq $sel) {
                    Write-WtfRaw "$E[2K`r$E[38;5;212m  > $E[0m$E[48;5;236m$E[1m$($Options[$i])$E[0m$hint`n"
                } else {
                    Write-WtfRaw "$E[2K`r    $E[38;5;250m$($Options[$i])$E[0m$hint`n"
                }
            }
            $drawn = $true

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { $sel = ($sel - 1 + $n) % $n }
                'DownArrow' { $sel = ($sel + 1) % $n }
                'K'         { $sel = ($sel - 1 + $n) % $n }
                'J'         { $sel = ($sel + 1) % $n }
                'Home'      { $sel = 0 }
                'End'       { $sel = $n - 1 }
                'Enter'     { return $sel }
                'Escape'    { return -1 }
                default {
                    # 1..9 jump straight to a row
                    $c = $key.KeyChar
                    if ($c -ge '1' -and $c -le '9') {
                        $idx = [int]::Parse($c) - 1
                        if ($idx -lt $n) { return $idx }
                    }
                }
            }
        }
    }
    finally {
        Write-WtfRaw "$E[?25h"
    }
}

function Read-WtfYesNo {
    <#
    .SYNOPSIS
        A single y/n question. $Default is what Enter means.
    #>
    param([Parameter(Mandatory)][string]$Question, [bool]$Default = $false)
    $E = $script:WtfEsc
    $hint = '[y/N]'
    if ($Default) { $hint = '[Y/n]' }
    while ($true) {
        Write-WtfRaw "$E[2K`r  $E[38;5;81m?$E[0m $Question $E[38;5;240m$hint$E[0m "
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Enter')  { Write-WtfRaw "`n"; return $Default }
        if ($key.Key -eq 'Escape') { Write-WtfRaw "`n"; return $false }
        $c = "$($key.KeyChar)".ToLower()
        if ($c -eq 'y') { Write-WtfRaw "y`n"; return $true }
        if ($c -eq 'n') { Write-WtfRaw "n`n"; return $false }
    }
}

function Read-WtfValue {
    <#
    .SYNOPSIS
        Read one line of text. Pressing Enter on its own keeps $Current.
    .NOTES
        The current value is shown rather than pre-typed into the line. The
        console gives no way to seed the input buffer that also survives paste,
        and pasting a fresh resume command is the common case here.
    #>
    param([string]$Label, [string]$Current = '')
    $E = $script:WtfEsc
    if ($Current) {
        Write-WtfRaw "  $E[38;5;240mcurrent:$E[0m $E[38;5;250m$Current$E[0m`n"
        Write-WtfRaw "  $E[38;5;240m(Enter keeps it, '-' clears it)$E[0m`n"
    }
    Write-WtfRaw "  $E[38;5;81m$Label$E[0m "
    $v = [Console]::ReadLine()
    if ($null -eq $v) { return $Current }
    if ($v -eq '')    { return $Current }
    if ($v -eq '-')   { return '' }
    return $v
}

function Format-WtfPath {
    # Shorten a long path for display, keeping the meaningful tail.
    param([string]$Path, [int]$Max = 52)
    if (-not $Path) { return '(not known)' }
    if ($Path.Length -le $Max) { return $Path }
    return '...' + $Path.Substring($Path.Length - ($Max - 3))
}

# ============================================================================
# SHOWING THE DIFF
# ============================================================================

function Show-WtfLayoutDiff {
    <#
    .SYNOPSIS
        Print what the snapshot found, pane by pane, before anything is saved.
    #>
    param([Parameter(Mandatory)]$Diff, [string]$Name)
    $E = $script:WtfEsc

    if ($Diff.IsFirst) { Write-WtfTitle "New layout '$Name' - $(@($Diff.Rows).Count) panes" }
    else               { Write-WtfTitle "Changes to '$Name' since it was saved" }

    foreach ($r in $Diff.Rows) {
        $tag   = '  same     '
        $color = '38;5;240'
        if ($r.status -eq 'moved')      { $tag = '  moved    '; $color = '38;5;111' }
        if ($r.status -eq 'dirchanged') { $tag = '  FOLDER   '; $color = '38;5;215' }
        if ($r.status -eq 'new')        { $tag = '  NEW      '; $color = '38;5;42'  }

        Write-WtfRaw "  $E[1mpane $($r.id)$E[0m $E[${color}m$tag$E[0m $(Format-WtfPath $r.dir)`n"

        if ($r.status -eq 'dirchanged' -and $r.oldDir) {
            Write-WtfRaw "           $E[38;5;240mwas:$E[0m $(Format-WtfPath $r.oldDir)`n"
        }
        if ($r.dirSource -eq 'process') {
            Write-WtfRaw "           $E[38;5;215mfolder was inferred, not read from the pane - please check$E[0m`n"
        }
        if (-not $r.dir) {
            Write-WtfRaw "           $E[38;5;215mfolder could not be read - type it in$E[0m`n"
        }
        if ($r.command) {
            Write-WtfRaw "           $E[38;5;42m$ $E[0m$E[38;5;250m$($r.command)$E[0m`n"
        } else {
            Write-WtfRaw "           $E[38;5;240m(no command)$E[0m`n"
        }
    }

    foreach ($r in @($Diff.Removed)) {
        Write-WtfRaw "  $E[38;5;203mclosed$E[0m   $E[38;5;240m$(Format-WtfPath $r.dir)$E[0m`n"
        if ($r.command) { Write-WtfRaw "           $E[38;5;240mits command was: $($r.command)$E[0m`n" }
    }
    Write-WtfRaw "`n"
}

# ============================================================================
# EDITING PANE COMMANDS
# ============================================================================

function Invoke-WtfPaneBoard {
    <#
    .SYNOPSIS
        Walk the panes so you can set each one's command.
    .DESCRIPTION
        Two modes:
          -OnlyAttention : step through just the panes whose command can no
                           longer be trusted (new pane, or the folder moved).
                           This runs on its own, because a command that was right
                           for the old folder is probably wrong for the new one.
          otherwise      : pick any pane from a list and edit it, as often as
                           you like, until you choose Done.
    #>
    param(
        [Parameter(Mandatory)]$Rows,
        [switch]$OnlyAttention
    )
    $rows = @($Rows)

    if ($OnlyAttention) {
        $todo = @($rows | Where-Object { $_.mustAsk })
        if ($todo.Count -eq 0) { return $rows }
        Write-WtfTitle "$($todo.Count) pane(s) need a command"
        foreach ($r in $todo) {
            $why = 'new pane'
            if ($r.status -eq 'dirchanged') { $why = "folder changed from $(Format-WtfPath $r.oldDir 40)" }
            if ($r.dirSource -eq 'process')  { $why = 'folder was inferred, please confirm' }
            if (-not $r.dir)                 { $why = 'folder unknown' }

            Write-WtfRaw "`n  $($script:WtfEsc)[1mpane $($r.id)$($script:WtfEsc)[0m  $(Format-WtfPath $r.dir)`n"
            Write-WtfRaw "  $($script:WtfEsc)[38;5;215m$why$($script:WtfEsc)[0m`n"

            if (-not $r.dir) {
                $r.dir = Read-WtfValue -Label 'folder:' -Current ''
            }
            $r.command = Read-WtfValue -Label 'command:' -Current $r.command
        }
        return $rows
    }

    while ($true) {
        $labels = @()
        $hints  = @()
        foreach ($r in $rows) {
            $labels += ("pane {0}  {1}" -f $r.id, (Format-WtfPath $r.dir 44))
            if ($r.command) { $hints += $r.command } else { $hints += '(no command)' }
        }
        $labels += 'Done'
        $hints  += ''

        $pick = Read-WtfPick -Title 'Which pane do you want to change?' -Options $labels -Hints $hints
        if ($pick -lt 0 -or $pick -ge $rows.Count) { return $rows }

        $r = $rows[$pick]
        Write-WtfRaw "`n  $($script:WtfEsc)[1mpane $($r.id)$($script:WtfEsc)[0m  $($r.dir)`n"
        $r.command = Read-WtfValue -Label 'command:' -Current $r.command
    }
}

# ============================================================================
# COMMAND: wtf snap
# ============================================================================

function Invoke-WtfSnap {
    <#
    .SYNOPSIS
        Save the current tab as a layout, or update the layout it came from.
    .DESCRIPTION
        A snapshot re-reads the whole tab from the screen every time, so every
        change is noticed on its own: a closed pane is simply absent, a new pane
        is simply present, and a changed folder reads as the new folder. Nothing
        is ever saved without showing you first.

        Which tab? The ACTIVE tab of the window this runs in. With -Foreground
        (how the hotkey calls it) it is the window in front, which needs no free
        pane in the tab at all - and your panes are usually all busy.

        Which layout? An explicit name wins. Otherwise, if the tab carries the
        name of a saved layout - which it does whenever `wtf tab open` built it -
        that layout is UPDATED. Otherwise you are asked for a name.
    #>
    param(
        [string]$Name,
        [switch]$Foreground,
        [switch]$WithoutMe
    )
    if (-not (Initialize-WtfInterop)) { return }

    $target = Resolve-WtfTargetWindow -Foreground:$Foreground
    if (-not $target) { return }

    $exclude = -1
    if ($WithoutMe) { $exclude = [int]$target.SelfPaneIndex }

    $cap = Get-WtfCaptureFromWindow -Hwnd $target.Hwnd -ExcludePaneIndex $exclude
    if (-not $cap) { Write-WtfLayoutFail "Nothing to capture in this tab."; return }

    # Decide which layout this is.
    $layoutName = ''
    if ($Name) {
        $existing = Find-WtfLayoutName -Name $Name
        if ($existing) { $layoutName = $existing } else { $layoutName = $Name.Trim() }
    } else {
        $fromTab = Find-WtfLayoutName -Name $cap.TabName
        if ($fromTab) {
            $layoutName = $fromTab
            Write-WtfLayoutInfo "this tab is layout '$fromTab' - updating it"
        }
    }

    if (-not $layoutName) {
        Write-WtfTitle "Name this layout"
        Write-WtfRaw "  $($script:WtfEsc)[38;5;240mletters, digits, spaces, - _ . and emoji; up to 60 characters$($script:WtfEsc)[0m`n"
        while ($true) {
            $entered = Read-WtfValue -Label 'name:' -Current ''
            if (-not $entered) { Write-WtfLayoutWarn "cancelled - nothing was saved"; return }
            $chk = Test-WtfLayoutName -Name $entered
            if ($chk.Ok) { $layoutName = $chk.Name; break }
            Write-WtfLayoutFail $chk.Reason
        }
    }

    $chk = Test-WtfLayoutName -Name $layoutName
    if (-not $chk.Ok) { Write-WtfLayoutFail "'$layoutName' cannot be used: $($chk.Reason)"; return }
    $layoutName = $chk.Name

    $saved = Read-WtfLayout -Name $layoutName
    $diff  = Compare-WtfLayout -Capture $cap -Saved $saved

    Show-WtfLayoutDiff -Diff $diff -Name $layoutName

    # Panes whose command can no longer be trusted are always asked about.
    $rows = @($diff.Rows)
    if ($diff.NeedsAttention) {
        $rows = @(Invoke-WtfPaneBoard -Rows $rows -OnlyAttention)
    }

    # And you are always given the chance to change anything else.
    $more = 'Any pane commands to change?'
    if ($diff.NeedsAttention) { $more = 'Any OTHER pane commands to change?' }
    if (Read-WtfYesNo -Question $more -Default $false) {
        $rows = @(Invoke-WtfPaneBoard -Rows $rows)
    }

    $panes = @()
    foreach ($r in $rows) {
        $panes += @{ id = $r.id; dir = [string]$r.dir; command = [string]$r.command }
    }

    $shell = 'powershell'
    if ($saved -and $saved.shell) { $shell = [string]$saved.shell }

    $obj  = New-WtfLayoutObject -Name $layoutName -Panes $panes -Tree $cap.Tree -Shell $shell
    $path = Write-WtfLayout -Name $layoutName -Layout $obj

    $verb = 'saved'
    if ($saved) { $verb = 'updated' }
    Write-WtfLayoutOk "$verb '$layoutName' - $(@($panes).Count) panes"
    Write-WtfLayoutInfo $path
    if (-not $saved) {
        Write-WtfLayoutInfo "open it later with: wtf tab open $layoutName"
    }
}

# ============================================================================
# COMMAND: wtf tab ...
# ============================================================================

function Select-WtfLayoutName {
    <#
    .SYNOPSIS
        Pick a layout from a list. Saves you remembering the names, which is the
        whole point after a few weeks away from a feature.
    #>
    param([string]$Name, [string]$Purpose = 'Which layout?')

    if ($Name) {
        $found = Find-WtfLayoutName -Name $Name
        if ($found) { return $found }
        Write-WtfLayoutWarn "no layout called '$Name'"
    }

    $names = @(Get-WtfLayoutNames)
    if ($names.Count -eq 0) {
        Write-WtfLayoutFail "No layouts saved yet. Arrange a tab the way you like, then run: wtf snap"
        return ''
    }

    $hints = @()
    foreach ($n in $names) {
        $l = Read-WtfLayout -Name $n
        if ($l) {
            $when = ''
            if ($l.capturedAt) {
                try { $when = ([datetime]$l.capturedAt).ToString('dd MMM HH:mm') } catch { $when = '' }
            }
            $hints += ("{0} panes   {1}" -f @($l.panes).Count, $when)
        } else { $hints += '' }
    }

    $pick = Read-WtfPick -Title $Purpose -Options $names -Hints $hints
    if ($pick -lt 0) { return '' }
    return $names[$pick]
}

function Invoke-WtfTabList {
    $names = @(Get-WtfLayoutNames)
    if ($names.Count -eq 0) {
        Write-WtfTitle 'Saved layouts'
        Write-WtfLayoutInfo "none yet - arrange a tab, then run: wtf snap"
        return
    }
    Write-WtfTitle "Saved layouts ($($names.Count))"
    $E = $script:WtfEsc
    foreach ($n in $names) {
        $l = Read-WtfLayout -Name $n
        if (-not $l) { continue }
        $when = ''
        if ($l.capturedAt) { try { $when = ([datetime]$l.capturedAt).ToString('dd MMM yyyy HH:mm') } catch { } }
        Write-WtfRaw "  $E[1m$n$E[0m  $E[38;5;240m$(@($l.panes).Count) panes - $when$E[0m`n"
        foreach ($p in @($l.panes)) {
            $cmd = '(no command)'
            if ($p.command) { $cmd = [string]$p.command }
            if ($cmd.Length -gt 46) { $cmd = $cmd.Substring(0, 46) + '...' }
            Write-WtfRaw "      $E[38;5;240m$($p.id).$E[0m $(Format-WtfPath ([string]$p.dir) 46)  $E[38;5;42m$cmd$E[0m`n"
        }
        Write-WtfRaw "`n"
    }
}

function Invoke-WtfTabOpen {
    param([string]$Name)
    $n = Select-WtfLayoutName -Name $Name -Purpose 'Open which layout?'
    if (-not $n) { return }

    $layout = Read-WtfLayout -Name $n
    if (-not $layout) { Write-WtfLayoutFail "could not read layout '$n'"; return }

    Write-WtfTitle "Opening '$n' - $(@($layout.panes).Count) panes"
    foreach ($p in @($layout.panes)) {
        $d = [string]$p.dir
        if ($d -and -not (Test-Path -LiteralPath $d)) {
            Write-WtfLayoutWarn "pane $($p.id): $d no longer exists"
        }
    }

    if (Invoke-WtfLayoutRestore -Name $n -Layout $layout) {
        Write-WtfLayoutOk "'$n' opened in a new tab"
    } else {
        Write-WtfLayoutFail "'$n' could not be opened in full"
    }
}

function Invoke-WtfTabEdit {
    param([string]$Name)
    $n = Select-WtfLayoutName -Name $Name -Purpose 'Edit which layout?'
    if (-not $n) { return }
    $p = Get-WtfLayoutPath -Name $n
    Write-WtfLayoutInfo $p

    $editor = $env:EDITOR
    if (-not $editor) {
        if (Get-Command code -ErrorAction SilentlyContinue) { $editor = 'code' } else { $editor = 'notepad' }
    }
    Start-Process -FilePath $editor -ArgumentList @($p)
    Write-WtfLayoutOk "opened in $editor - edit the 'command' of any pane, then save"
}

function Invoke-WtfTabRemove {
    param([string]$Name)
    $n = Select-WtfLayoutName -Name $Name -Purpose 'Delete which layout?'
    if (-not $n) { return }

    $l = Read-WtfLayout -Name $n
    $count = 0
    if ($l) { $count = @($l.panes).Count }
    if (-not (Read-WtfYesNo -Question "Delete layout '$n' ($count panes)? This cannot be undone." -Default $false)) {
        Write-WtfLayoutInfo 'left alone'
        return
    }
    Remove-Item -LiteralPath (Get-WtfLayoutPath -Name $n) -Force
    Write-WtfLayoutOk "deleted '$n'"
}

function Invoke-WtfTab {
    <#
    .SYNOPSIS
        Dispatcher for `wtf tab <sub> [name]`.
    #>
    param([string]$Sub, [string]$Name)

    if (-not $Sub) { $Sub = 'ls' }
    switch ($Sub.ToLower()) {
        'ls'     { Invoke-WtfTabList }
        'list'   { Invoke-WtfTabList }
        'open'   { Invoke-WtfTabOpen   -Name $Name }
        'edit'   { Invoke-WtfTabEdit   -Name $Name }
        'rm'     { Invoke-WtfTabRemove -Name $Name }
        'remove' { Invoke-WtfTabRemove -Name $Name }
        'delete' { Invoke-WtfTabRemove -Name $Name }
        'save'   { Invoke-WtfSnap      -Name $Name }
        default  {
            # `wtf tab pigeon` is a natural way to say "open pigeon"
            $found = Find-WtfLayoutName -Name $Sub
            if ($found) { Invoke-WtfTabOpen -Name $found }
            else {
                Write-WtfLayoutFail "unknown: wtf tab $Sub"
                Write-WtfLayoutInfo 'try: wtf tab ls | open | edit | rm'
            }
        }
    }
}
