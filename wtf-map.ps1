# wtf-map.ps1 — draw a layout as a picture.
#
# Pane numbers alone do not tell you which pane is which, and they get harder to
# follow as splits nest. So wherever panes are listed, the layout is also drawn:
# boxes in the same arrangement as the real tab, each showing its number, its
# folder, and its command.
#
# Save as UTF-8 WITH BOM. Runs on Windows PowerShell 5.1 and PowerShell 7+.

# Box-drawing glyphs, chosen by which sides a border cell connects to.
# Index = up(1) + down(2) + left(4) + right(8).
$script:WtfBoxGlyphs = @(
    ' ',        # 0  nothing
    [char]0x2502, # 1  up
    [char]0x2502, # 2  down
    [char]0x2502, # 3  up+down
    [char]0x2500, # 4  left
    [char]0x2518, # 5  up+left
    [char]0x2510, # 6  down+left
    [char]0x2524, # 7  up+down+left
    [char]0x2500, # 8  right
    [char]0x2514, # 9  up+right
    [char]0x250C, # 10 down+right
    [char]0x251C, # 11 up+down+right
    [char]0x2500, # 12 left+right
    [char]0x2534, # 13 up+left+right
    [char]0x252C, # 14 down+left+right
    [char]0x253C  # 15 all four
)

function Get-WtfTreeSpan {
    <#
    .SYNOPSIS
        How many boxes the layout is wide and tall, in boxes not characters.
        Used to pick a drawing size that gives every pane room to be readable.
    #>
    param($Node)
    if (-not $Node) { return @{ Cols = 1; Rows = 1 } }
    if ($Node.kind -ne 'split') { return @{ Cols = 1; Rows = 1 } }
    $a = Get-WtfTreeSpan $Node.a
    $b = Get-WtfTreeSpan $Node.b
    if ($Node.dir -eq 'V') {
        return @{ Cols = ($a.Cols + $b.Cols); Rows = [Math]::Max($a.Rows, $b.Rows) }
    }
    return @{ Cols = [Math]::Max($a.Cols, $b.Cols); Rows = ($a.Rows + $b.Rows) }
}

function Add-WtfMapRects {
    <#
    .SYNOPSIS
        Give every leaf a rectangle in character coordinates, splitting the
        space in the same proportions the real tab uses.
    #>
    param($Node, [int]$X, [int]$Y, [int]$W, [int]$H, $Acc)
    if (-not $Node) { return }

    if ($Node.kind -ne 'split') {
        $id = $Node.index
        if ($Node.kind -eq 'unresolved') { $id = @($Node.indexes)[0] }
        [void]$Acc.Add(@{ Id = $id; X = $X; Y = $Y; W = $W; H = $H })
        return
    }

    $size = 0.5
    if ($null -ne $Node.size) { $size = [double]$Node.size }

    if ($Node.dir -eq 'V') {
        # Share a border column between the halves, so the picture stays tight.
        # Likewise a box narrower than this cannot show a folder name.
        $aw = [int][Math]::Round(($W - 1) * $size)
        if ($aw -lt 14) { $aw = 14 }
        if ($aw -gt $W - 15) { $aw = $W - 15 }
        Add-WtfMapRects -Node $Node.a -X $X -Y $Y -W ($aw + 1) -H $H -Acc $Acc
        Add-WtfMapRects -Node $Node.b -X ($X + $aw) -Y $Y -W ($W - $aw) -H $H -Acc $Acc
    } else {
        # A box needs five rows to show its number, folder and command, so
        # clamp the share rather than let a small pane lose its command line.
        $ah = [int][Math]::Round(($H - 1) * $size)
        if ($ah -lt 4) { $ah = 4 }
        if ($ah -gt $H - 5) { $ah = $H - 5 }
        Add-WtfMapRects -Node $Node.a -X $X -Y $Y -W $W -H ($ah + 1) -Acc $Acc
        Add-WtfMapRects -Node $Node.b -X $X -Y ($Y + $ah) -W $W -H ($H - $ah) -Acc $Acc
    }
}

function Get-WtfLayoutMap {
    <#
    .SYNOPSIS
        Draw a layout as lines of text: boxes arranged like the real tab.
    .PARAMETER Highlight
        Pane id to mark as the one being talked about right now.
    .OUTPUTS
        An array of strings, one per line, with ANSI colour already applied.
    #>
    param(
        [Parameter(Mandatory)]$Layout,
        [int]$Width = 62,
        [int]$Highlight = 0
    )
    # These names are deliberately unlike any loop variable used below.
    # PowerShell variable names ignore case, so a colour called $R would be the
    # same variable as the rectangle $r, and $cRun the same as $cmd - which
    # silently overwrites the colour with a hashtable or a command string.
    $esc   = [char]27
    $cDim  = "$esc[38;5;240m"
    $cTxt  = "$esc[38;5;250m"
    $cNum  = "$esc[1m$esc[38;5;81m"
    $cHot  = "$esc[1m$esc[38;5;212m"
    $cRun  = "$esc[38;5;42m"
    $cWait = "$esc[38;5;215m"
    $cOff  = "$esc[0m"

    $tree = $Layout.tree
    if (-not $tree) { return @('  (no layout)') }

    $span = Get-WtfTreeSpan $tree
    $W = $Width
    if ($W -lt 24) { $W = 24 }
    # Four rows per stacked box: two borders, a number line and a folder line,
    # plus a command line where there is room.
    $H = ($span.Rows * 6) + 1
    if ($H -lt 6)  { $H = 6 }
    if ($H -gt 34) { $H = 34 }

    $rects = New-Object System.Collections.ArrayList
    Add-WtfMapRects -Node $tree -X 0 -Y 0 -W $W -H $H -Acc $rects
    if ($rects.Count -eq 0) { return @('  (no panes)') }

    # Border direction bits per cell, then content laid on top.
    $bits = @()
    $chars = @()
    for ($y = 0; $y -lt $H; $y++) {
        $bits  += ,(New-Object 'int[]' $W)
        $chars += ,(New-Object 'string[]' $W)
    }

    function Set-Edge {
        param([int]$Y, [int]$X, [int]$Bit)
        if ($Y -lt 0 -or $Y -ge $script:_mapH -or $X -lt 0 -or $X -ge $script:_mapW) { return }
        $script:_mapBits[$Y][$X] = $script:_mapBits[$Y][$X] -bor $Bit
    }
    $script:_mapBits = $bits
    $script:_mapW = $W
    $script:_mapH = $H

    foreach ($r in $rects) {
        $x1 = $r.X; $y1 = $r.Y; $x2 = $r.X + $r.W - 1; $y2 = $r.Y + $r.H - 1
        for ($x = $x1; $x -le $x2; $x++) {
            if ($x -gt $x1) { Set-Edge $y1 $x 4; Set-Edge $y2 $x 4 }
            if ($x -lt $x2) { Set-Edge $y1 $x 8; Set-Edge $y2 $x 8 }
        }
        for ($y = $y1; $y -le $y2; $y++) {
            if ($y -gt $y1) { Set-Edge $y $x1 1; Set-Edge $y $x2 1 }
            if ($y -lt $y2) { Set-Edge $y $x1 2; Set-Edge $y $x2 2 }
        }
    }

    # panes by id, for the text inside each box
    $byId = @{}
    foreach ($p in @($Layout.panes)) { $byId[[string]$p.id] = $p }

    foreach ($r in $rects) {
        $p = $byId[[string]$r.Id]
        $innerX = $r.X + 2
        $innerW = $r.W - 4
        if ($innerW -lt 3) { continue }

        $isHot = ($Highlight -gt 0 -and [int]$r.Id -eq $Highlight)

        $folder = '(folder unknown)'
        $cmd    = ''
        $runs   = $true
        if ($p) {
            if ($p.dir) { $folder = Split-Path ([string]$p.dir) -Leaf }
            if (-not $folder) { $folder = [string]$p.dir }
            $cmd = [string]$p.command
            if ($null -ne $p.run) { $runs = [bool]$p.run }
        }

        $numTxt = "pane $($r.Id)"
        if ($isHot) { $numTxt = "> pane $($r.Id) <" }

        $lines = @()
        $lines += @{ Text = $numTxt; Color = $(if ($isHot) { $cHot } else { $cNum }) }
        $lines += @{ Text = $folder; Color = $cTxt }
        if ($r.H -ge 4) {
            if ($cmd) {
                $mark = '> '
                $col  = $cRun
                if (-not $runs) { $mark = '~ '; $col = $cWait }
                $lines += @{ Text = ($mark + $cmd); Color = $col }
            } else {
                $lines += @{ Text = '(no command)'; Color = $cDim }
            }
        }

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $ly = $r.Y + 1 + $i
            if ($ly -ge $r.Y + $r.H - 1) { break }
            $s = [string]$lines[$i].Text
            if ($s.Length -gt $innerW) { $s = $s.Substring(0, [Math]::Max(1, $innerW - 1)) + [char]0x2026 }
            $chars[$ly][$innerX] = $lines[$i].Color + $s + $cOff
            # blank out the rest of the run so nothing shows through
            for ($k = 1; $k -lt $s.Length; $k++) {
                if (($innerX + $k) -lt $W) { $chars[$ly][$innerX + $k] = '' }
            }
        }
    }

    # compose
    $out = @()
    for ($y = 0; $y -lt $H; $y++) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('  ')
        for ($x = 0; $x -lt $W; $x++) {
            $c = $chars[$y][$x]
            if ($null -ne $c) { [void]$sb.Append($c); continue }
            $b = $bits[$y][$x]
            if ($b -eq 0) { [void]$sb.Append(' ') }
            else { [void]$sb.Append($cDim + $script:WtfBoxGlyphs[$b] + $cOff) }
        }
        $out += $sb.ToString()
    }

    Remove-Variable -Name _mapBits, _mapW, _mapH -Scope Script -ErrorAction SilentlyContinue
    # Plain return; callers wrap with @(). ',@(...)' would nest an array inside
    # an array as soon as the caller wraps it too.
    return $out
}

function Show-WtfLayoutMap {
    param([Parameter(Mandatory)]$Layout, [int]$Width = 62, [int]$Highlight = 0)
    foreach ($l in @(Get-WtfLayoutMap -Layout $Layout -Width $Width -Highlight $Highlight)) {
        [Console]::Out.WriteLine($l)
    }
}
