# wtf-tab.ps1 — the commands you actually type, for tab layouts.
#
#   wtf snap [name]        capture the tab you are in (or the one in front)
#   wtf tab ls             list saved layouts
#   wtf tab open [name]    rebuild a layout as a new tab in this window
#   wtf tab edit [name]    open a layout file to change commands by hand
#   wtf tab rm [name]      delete a layout
#
# Wherever panes are involved the layout is DRAWN, because a pane number on its
# own does not tell you which pane it is - and that only gets worse as splits
# nest. See wtf-map.ps1.
#
# Requires wtf-layout.ps1 (capture/restore) and wtf-map.ps1 (drawing).
#
# Runs on Windows PowerShell 5.1 and PowerShell 7+ alike: no `e escapes, no
# ternary or null-coalescing operators. Save as UTF-8 WITH BOM.

if (-not $script:WtfRoot) { $script:WtfRoot = Join-Path $env:USERPROFILE '.wtf' }

$script:WtfEsc = [char]27

# ============================================================================
# TERMINAL UI PRIMITIVES
# ============================================================================

function Write-WtfRaw { param([string]$S) [Console]::Out.Write($S) }

function Get-WtfConsoleWidth {
    try {
        $w = [Console]::WindowWidth
        if ($w -gt 30) { return $w }
    } catch { }
    return 100
}

function Write-WtfTitle {
    param([string]$Text)
    $E = $script:WtfEsc
    Write-WtfRaw "`n$E[38;5;141m$E[1m  $Text$E[0m`n"
    $rule = [string][char]0x2500
    Write-WtfRaw "$E[38;5;240m  $($rule * [Math]::Min(64, $Text.Length + 12))$E[0m`n"
}

function Read-WtfPick {
    <#
    .SYNOPSIS
        Arrow-key picker. Returns the chosen index, or -1 if cancelled.
    .DESCRIPTION
        Redraw works by moving the cursor UP over the rows already on screen and
        rewriting each one in place, then clearing to the end of the screen. A
        row wider than the pane would otherwise wrap onto a second physical line
        and be left behind, which is why rows are also truncated to the width.
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
    Write-WtfRaw "$E[?25l"

    $drawn = $false
    try {
        while ($true) {
            if ($drawn) { Write-WtfRaw "$E[${n}A" }

            for ($i = 0; $i -lt $n; $i++) {
                $hint = ''
                if ($i -lt $Hints.Count -and $Hints[$i]) { $hint = "  $E[38;5;240m$($Hints[$i])$E[0m" }
                if ($i -eq $sel) {
                    Write-WtfRaw "$E[2K`r$E[38;5;212m  > $E[0m$E[48;5;236m$E[1m$($Options[$i])$E[0m$hint`n"
                } else {
                    Write-WtfRaw "$E[2K`r    $E[38;5;250m$($Options[$i])$E[0m$hint`n"
                }
            }
            Write-WtfRaw "$E[0J"
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
        Read one line of text. Enter on its own keeps $Current.
    .PARAMETER EmptyHint
        What pressing Enter means here, shown so that leaving something blank is
        an obvious choice rather than a thing you have to guess at.
    #>
    param([string]$Label, [string]$Current = '', [string]$EmptyHint = '')
    $E = $script:WtfEsc
    if ($Current) {
        Write-WtfRaw "  $E[38;5;240mcurrent:$E[0m $E[38;5;250m$Current$E[0m`n"
        Write-WtfRaw "  $E[38;5;240m(Enter keeps it, '-' clears it)$E[0m`n"
    } elseif ($EmptyHint) {
        Write-WtfRaw "  $E[38;5;240m($EmptyHint)$E[0m`n"
    }
    Write-WtfRaw "  $E[38;5;81m$Label$E[0m "
    $v = [Console]::ReadLine()
    if ($null -eq $v) { return $Current }
    if ($v -eq '')    { return $Current }
    if ($v -eq '-')   { return '' }
    return $v
}

function Format-WtfPath {
    param([string]$Path, [int]$Max = 52)
    if (-not $Path) { return '(not known)' }
    if ($Path.Length -le $Max) { return $Path }
    return '...' + $Path.Substring($Path.Length - ($Max - 3))
}

# ============================================================================
# SHOWING A LAYOUT
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
            $mark = '>'
            $col  = '38;5;42'
            if ($null -ne $r.run -and -not $r.run) { $mark = '~'; $col = '38;5;215' }
            Write-WtfRaw "           $E[${col}m$mark $E[0m$E[38;5;250m$($r.command)$E[0m`n"
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

function Show-WtfCommandKey {
    $E = $script:WtfEsc
    Write-WtfRaw "  $E[38;5;42m>$E[0m$E[38;5;240m runs on open    $E[0m$E[38;5;215m~$E[0m$E[38;5;240m typed at the prompt, waiting for Enter$E[0m`n"
}

# ============================================================================
# EDITING PANE COMMANDS
# ============================================================================

function Set-WtfPaneCommand {
    <#
    .SYNOPSIS
        Ask for one pane's command, and whether it should run by itself.
    .DESCRIPTION
        The layout is redrawn with this pane marked, so there is never any doubt
        about which pane is being set.

        Leaving a command blank is a first-class answer: plenty of panes want to
        be nothing more than a shell already sitting in the right folder.

        A command that IS given can either run on open, or be typed at the prompt
        and left there. The second is what you want for an agent resume line -
        having four agents start themselves the moment a tab opens is rarely the
        intention.
    #>
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)]$Layout)

    $E = $script:WtfEsc
    Show-WtfLayoutMap -Layout $Layout -Width (Get-WtfMapWidth) -Highlight ([int]$Row.id)

    $why = ''
    if ($Row.status -eq 'dirchanged') { $why = "this pane's folder changed from $(Format-WtfPath $Row.oldDir 40)" }
    if ($Row.dirSource -eq 'process') { $why = 'the folder was inferred, please confirm it' }
    if (-not $Row.dir)                { $why = 'the folder could not be read' }
    if ($why) { Write-WtfRaw "  $E[38;5;215m$why$E[0m`n" }

    Write-WtfRaw "`n  $E[1mpane $($Row.id)$E[0m  $E[38;5;250m$(Format-WtfPath $Row.dir 60)$E[0m`n"

    if (-not $Row.dir) {
        $Row.dir = Read-WtfValue -Label 'folder:' -Current '' -EmptyHint 'Enter to leave it unset'
    }

    $Row.command = Read-WtfValue -Label 'command:' -Current ([string]$Row.command) `
                                 -EmptyHint 'Enter for none - the pane just opens in that folder'

    if ($Row.command) {
        $Row.run = Read-WtfYesNo -Question 'run it automatically when the tab opens?' -Default $true
        if (-not $Row.run) {
            Write-WtfRaw "  $E[38;5;240mit will be typed at the prompt, waiting for you to press Enter$E[0m`n"
        }
    } else {
        $Row.run = $true
    }
    return $Row
}

function Invoke-WtfPaneBoard {
    <#
    .SYNOPSIS
        Walk the panes so you can set each one's command.
    .DESCRIPTION
        -OnlyAttention steps through just the panes whose command can no longer
        be trusted (a new pane, or one whose folder moved). Otherwise you pick
        any pane from the drawing, as often as you like, until you choose Done.
    #>
    param(
        [Parameter(Mandatory)]$Rows,
        [Parameter(Mandatory)]$Layout,
        [switch]$OnlyAttention
    )
    $rows = @($Rows)

    if ($OnlyAttention) {
        $todo = @($rows | Where-Object { $_.mustAsk })
        if ($todo.Count -eq 0) { return $rows }
        Write-WtfTitle "$($todo.Count) pane(s) need a command"
        Show-WtfCommandKey
        foreach ($r in $todo) { [void](Set-WtfPaneCommand -Row $r -Layout $Layout) }
        return $rows
    }

    while ($true) {
        $labels = @()
        $hints  = @()
        foreach ($r in $rows) {
            $labels += ("pane {0}  {1}" -f $r.id, (Format-WtfPath $r.dir 40))
            if ($r.command) {
                $mark = '>'
                if ($null -ne $r.run -and -not $r.run) { $mark = '~' }
                $hints += "$mark $($r.command)"
            } else {
                $hints += '(no command)'
            }
        }
        $labels += 'Done'
        $hints  += ''

        Show-WtfLayoutMap -Layout $Layout -Width (Get-WtfMapWidth)
        Show-WtfCommandKey
        $pick = Read-WtfPick -Title 'Which pane do you want to change?' -Options $labels -Hints $hints
        if ($pick -lt 0 -or $pick -ge $rows.Count) { return $rows }

        [void](Set-WtfPaneCommand -Row $rows[$pick] -Layout $Layout)
    }
}

function Get-WtfMapWidth {
    $w = (Get-WtfConsoleWidth) - 6
    if ($w -gt 96) { $w = 96 }
    if ($w -lt 30) { $w = 30 }
    return $w
}

function New-WtfPreviewLayout {
    # A layout-shaped object built from the rows being edited, so the drawing
    # always shows what you have typed so far rather than what was on disk.
    param($Rows, $Tree, [string]$Name = '', [string]$Description = '')
    $panes = @()
    foreach ($r in @($Rows)) {
        $run = $true
        if ($null -ne $r.run) { $run = [bool]$r.run }
        $panes += @{ id = $r.id; dir = [string]$r.dir; command = [string]$r.command; run = $run }
    }
    return @{ name = $Name; description = $Description; panes = @($panes); tree = $Tree }
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
        change is noticed on its own. Nothing is ever saved without showing you.

        Which tab? The ACTIVE tab of the window this runs in. With -Foreground
        (how the hotkey calls it) it is the window in front, which needs no free
        pane in the tab at all - and your panes are usually all busy.
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
        # Show it before asking anything: the shape is the best reminder of what
        # this tab actually is.
        Write-WtfTitle "This tab - $(@($cap.Panes).Count) panes"
        Show-WtfLayoutMap -Layout (New-WtfPreviewLayout -Rows $cap.Panes -Tree $cap.Tree) -Width (Get-WtfMapWidth)

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

    $rows = @($diff.Rows)

    # Panes whose command can no longer be trusted are always asked about.
    if ($diff.NeedsAttention) {
        $preview = New-WtfPreviewLayout -Rows $rows -Tree $cap.Tree -Name $layoutName
        $rows = @(Invoke-WtfPaneBoard -Rows $rows -Layout $preview -OnlyAttention)
    }

    # And you are always given the chance to change anything else.
    $more = 'Any pane commands to change?'
    if ($diff.NeedsAttention) { $more = 'Any OTHER pane commands to change?' }
    if (Read-WtfYesNo -Question $more -Default $false) {
        $preview = New-WtfPreviewLayout -Rows $rows -Tree $cap.Tree -Name $layoutName
        $rows = @(Invoke-WtfPaneBoard -Rows $rows -Layout $preview)
    }

    # A short name plus a sentence beats a long name you still cannot decode
    # after three weeks away from the feature.
    $description = ''
    if ($saved -and $saved.description) { $description = [string]$saved.description }
    if (-not $description) {
        $description = Read-WtfValue -Label 'description:' -Current '' `
                                     -EmptyHint 'Enter to skip - what is this layout for?'
    } elseif (Read-WtfYesNo -Question "Change the description? ($description)" -Default $false) {
        $description = Read-WtfValue -Label 'description:' -Current $description
    }

    $panes = @()
    foreach ($r in $rows) {
        $run = $true
        if ($null -ne $r.run) { $run = [bool]$r.run }
        $panes += @{ id = $r.id; dir = [string]$r.dir; command = [string]$r.command; run = $run }
    }

    $shell = 'powershell'
    if ($saved -and $saved.shell) { $shell = [string]$saved.shell }

    $obj  = New-WtfLayoutObject -Name $layoutName -Panes $panes -Tree $cap.Tree `
                                -Shell $shell -Description $description
    $path = Write-WtfLayout -Name $layoutName -Layout $obj

    $verb = 'saved'
    if ($saved) { $verb = 'updated' }
    Write-WtfTitle "$verb '$layoutName'"
    Show-WtfLayoutMap -Layout $obj -Width (Get-WtfMapWidth)
    Show-WtfCommandKey
    Write-WtfLayoutOk "$verb - $(@($panes).Count) panes"
    Write-WtfLayoutInfo $path
    if (-not $saved) {
        Write-WtfLayoutInfo "open it later with: wtf tab open $layoutName"
    }
}

# ============================================================================
# CHOOSING A LAYOUT
# ============================================================================

function Get-WtfLayoutPickFrame {
    <#
    .SYNOPSIS
        One frame of the layout picker: names down the left, the highlighted
        layout drawn beside them, its description underneath.
    .DESCRIPTION
        Kept separate from the key handling so the drawing can be checked
        without a console attached.
    .OUTPUTS
        An array of strings, ready to print.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)]$Layouts,
        [int]$Selected = 0,
        [int]$LeftWidth = 22,
        [int]$MapWidth = 60,
        [switch]$DrawMap
    )
    $E = $script:WtfEsc
    $n = $Names.Count
    $lay = $null
    if ($Selected -ge 0 -and $Selected -lt $n) { $lay = $Layouts[$Names[$Selected]] }

    $mapLines = @()
    if ($DrawMap -and $lay) { $mapLines = @(Get-WtfLayoutMap -Layout $lay -Width $MapWidth) }

    $rowCount = [Math]::Max($n, $mapLines.Count)
    $lines = @()
    for ($i = 0; $i -lt $rowCount; $i++) {
        $left = ' ' * $LeftWidth
        if ($i -lt $n) {
            $nm = $Names[$i]
            if ($nm.Length -gt ($LeftWidth - 5)) { $nm = $nm.Substring(0, $LeftWidth - 6) + [char]0x2026 }
            $pad = ' ' * [Math]::Max(0, $LeftWidth - 4 - $nm.Length)
            if ($i -eq $Selected) {
                $left = "$E[38;5;212m  > $E[0m$E[1m$nm$E[0m$pad"
            } else {
                $left = "$E[38;5;250m    $nm$E[0m$pad"
            }
        }
        $right = ''
        if ($i -lt $mapLines.Count) { $right = $mapLines[$i] }
        $lines += ($left + $right)
    }

    $lines += ''
    if ($lay) {
        $cnt = @($lay.panes).Count
        $desc = ''
        if ($lay.description) { $desc = [string]$lay.description }
        if ($desc) {
            $lines += "  $E[38;5;240m$cnt panes  " + [char]0x00B7 + "  $E[0m$E[3m$E[38;5;250m$desc$E[0m"
        } else {
            $lines += "  $E[38;5;240m$cnt panes  " + [char]0x00B7 + "  (no description)$E[0m"
        }
    } else {
        $lines += "  $E[38;5;203m(could not read this layout)$E[0m"
    }
    $lines += "  $E[38;5;240mup/down to move " + [char]0x00B7 + " enter to open " + [char]0x00B7 + " esc to cancel$E[0m"
    return $lines
}

function Read-WtfLayoutPick {
    <#
    .SYNOPSIS
        Pick a layout, with its shape drawn beside the list.
    .DESCRIPTION
        Names on the left, the highlighted layout DRAWN on the right, and its
        description underneath. Remembering what a name meant is exactly the
        thing that fails after a few weeks, so the picture and the description
        do that work instead.
    .OUTPUTS
        The chosen name, or '' when cancelled.
    #>
    param([Parameter(Mandatory)][string[]]$Names, [string]$Title = 'Which layout?')

    $E = $script:WtfEsc
    $n = $Names.Count
    if ($n -eq 0) { return '' }

    # Read them once; drawing on every keypress should not re-read the disk.
    $layouts = @{}
    foreach ($nm in $Names) { $layouts[$nm] = Read-WtfLayout -Name $nm }

    $leftW = 0
    foreach ($nm in $Names) { if ($nm.Length -gt $leftW) { $leftW = $nm.Length } }
    $leftW = $leftW + 6
    if ($leftW -lt 18) { $leftW = 18 }
    if ($leftW -gt 34) { $leftW = 34 }

    $mapW = (Get-WtfConsoleWidth) - $leftW - 6
    if ($mapW -gt 84) { $mapW = 84 }
    $drawMap = ($mapW -ge 30)

    $sel = 0
    Write-WtfTitle $Title
    Write-WtfRaw "$E[?25l"
    $drawn = 0
    try {
        while ($true) {
            if ($drawn -gt 0) { Write-WtfRaw "$E[${drawn}A" }

            $lines = @(Get-WtfLayoutPickFrame -Names $Names -Layouts $layouts `
                                              -Selected $sel -LeftWidth $leftW `
                                              -MapWidth $mapW -DrawMap:$drawMap)
            foreach ($l in $lines) { Write-WtfRaw "$E[2K`r$l`n" }
            Write-WtfRaw "$E[0J"
            $drawn = $lines.Count

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { $sel = ($sel - 1 + $n) % $n }
                'DownArrow' { $sel = ($sel + 1) % $n }
                'K'         { $sel = ($sel - 1 + $n) % $n }
                'J'         { $sel = ($sel + 1) % $n }
                'Home'      { $sel = 0 }
                'End'       { $sel = $n - 1 }
                'Enter'     { return $Names[$sel] }
                'Escape'    { return '' }
                default {
                    $c = $key.KeyChar
                    if ($c -ge '1' -and $c -le '9') {
                        $idx = [int]::Parse($c) - 1
                        if ($idx -lt $n) { return $Names[$idx] }
                    }
                }
            }
        }
    }
    finally {
        Write-WtfRaw "$E[?25h"
    }
}

function Select-WtfLayoutName {
    param([string]$Name, [string]$Purpose = 'Which layout?')

    if ($Name) {
        $found = Find-WtfLayoutName -Name $Name
        if ($found) { return $found }
        Write-WtfLayoutWarn "no layout called '$Name'"
    }

    $names = @(Get-WtfLayoutNames)
    if ($names.Count -eq 0) {
        Write-WtfLayoutFail "No layouts saved yet. Arrange a tab the way you like, then press ALT+SHIFT+S."
        return ''
    }
    return (Read-WtfLayoutPick -Names $names -Title $Purpose)
}

# ============================================================================
# COMMAND: wtf tab ...
# ============================================================================

function Invoke-WtfTabList {
    $names = @(Get-WtfLayoutNames)
    if ($names.Count -eq 0) {
        Write-WtfTitle 'Saved layouts'
        Write-WtfLayoutInfo "none yet - arrange a tab, then press ALT+SHIFT+S"
        return
    }
    $E = $script:WtfEsc
    Write-WtfTitle "Saved layouts ($($names.Count))"
    Show-WtfCommandKey

    foreach ($n in $names) {
        $l = Read-WtfLayout -Name $n
        if (-not $l) { continue }
        $when = ''
        if ($l.capturedAt) { try { $when = ([datetime]$l.capturedAt).ToString('dd MMM yyyy HH:mm') } catch { } }

        Write-WtfRaw "`n  $E[1m$E[38;5;81m$n$E[0m  $E[38;5;240m$(@($l.panes).Count) panes · $when$E[0m`n"
        if ($l.description) {
            Write-WtfRaw "  $E[3m$E[38;5;250m$([string]$l.description)$E[0m`n"
        }
        Show-WtfLayoutMap -Layout $l -Width (Get-WtfMapWidth)
    }
    Write-WtfRaw "`n"
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
    Write-WtfLayoutInfo "each pane has 'command' and 'run'; set run to false to have it typed, not executed"

    $editor = $env:EDITOR
    if (-not $editor) {
        if (Get-Command code -ErrorAction SilentlyContinue) { $editor = 'code' } else { $editor = 'notepad' }
    }
    Start-Process -FilePath $editor -ArgumentList @($p)
    Write-WtfLayoutOk "opened in $editor"
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
            $found = Find-WtfLayoutName -Name $Sub
            if ($found) { Invoke-WtfTabOpen -Name $found }
            else {
                Write-WtfLayoutFail "unknown: wtf tab $Sub"
                Write-WtfLayoutInfo 'try: wtf tab ls | open | edit | rm'
            }
        }
    }
}
