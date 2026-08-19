# wtf — WorkTree Flow: implementation notes

Living record of the tool. Rewritten 2026-08-18 when the workflow changed.

## What changed, and why

The old design assumed a window per feature: VS Code opened automatically, one
window held a tab per agent session ("slots"), and a second window held a tab per
repo for running things. That workflow is gone. Work now happens in **one
Windows Terminal tab split into panes**, mixing agent CLIs and running servers,
across several projects and worktrees at once, with panes created and closed as
work finishes.

So the tool was split in two:

| Part | What it does |
|---|---|
| **Worktrees** | unchanged engine; `wtf create` now just prints the paths |
| **Tab layouts** | new; capture and rebuild a tab's pane arrangement |

Removed entirely: VS Code launching, `.code-workspace` files, the runner window,
the agent window, agent slots, `wtf open` (feature), `wtf edit` (slots),
`wtf sessions`.

## Files

| File | Contents |
|---|---|
| `wtf.ps1` | worktree engine, shared UI, dispatcher; loads the others |
| `wtf-layout.ps1` | capture, directory resolution, geometry to tree, diff, restore |
| `wtf-tab.ps1` | `snap`, `tab ls/open/edit/rm`, pane editor, picker |
| `tab-bindings.json` | which open tab is which layout (local, gitignored) |
| `wtf-map.ps1` | draws a layout as boxes |
| `wtf-prefill.ps1` | dot-sourced BY a restored pane, to type a command unrun |
| `wtf-hotkey.ps1` | install/remove the global hotkeys |
| `wtf-snap-hotkey.ps1` | what ALT+SHIFT+S runs |
| `wtf-open-hotkey.ps1` | what ALT+SHIFT+O runs |
| `layouts/<name>.json` | one saved layout (git-ignored) |
| `config.json` | your roots and repo groups (git-ignored) |

All are UTF-8 **with BOM**. This is not optional: without it Windows PowerShell
5.1 reads them in the ANSI codepage and every box glyph and emoji breaks.

## Commands

```
wtf create / add / remove / delete / list / status / doctor / config
wtf snap [name]                 save THIS tab as a layout
wtf tab ls | open | edit | rm   manage layouts (a picker appears with no name)
wtf hotkey install [snap|open] [COMBO]   defaults ALT+SHIFT+S and ALT+SHIFT+O
wtf hotkey status | remove [snap|open]
```

## Hotkeys

Start Menu shortcuts carrying a Windows "shortcut key" - no extra software and no
background process. The focused application sees the key FIRST; Windows acts on
the shortcut key only when the application does not handle it.

`ALT+SHIFT+S` and `ALT+SHIFT+O` were chosen because they are not Windows Terminal
bindings, so they arrive even while the terminal is focused - which snapping the
front tab requires - and they stay clear of `ALT+SHIFT+plus/minus` (split) and
`ALT+SHIFT+arrows` (resize).

The snap runner must not use `GetForegroundWindow` alone: pressing the hotkey
opens its own console, which takes the foreground before any code runs. It falls
back to the topmost terminal window, which `EnumWindows` returns first because it
walks in Z-order.

**The hotkey's own window is a terminal window.** Windows 11 hosts console
applications inside Windows Terminal by default, so the window a hotkey opens
for itself shows up in the terminal window list like any other. `GetForegroundWindow`
returns it, an "is this a terminal?" test says yes, and the snapshot captures
ITSELF - one pane, no directory, a leaf tree - instead of the tab that was in
front. That is what happened on the first real use.

Two guards, because either alone is thin:

1. The shortcuts launch through `conhost.exe`, which forces a classic console
   window, so our window is not in the terminal list at all. This also keeps
   `wt -w 0` ("the most recently used terminal window") pointing at the user's
   window rather than ours.
2. `Find-WtfSelfWindow` identifies our own window by printing a marker and
   looking for it in every terminal window's panes, and the foreground path
   rules that window out before choosing a target.

**Writing the .lnk does not register anything.** Windows registers the key with
`RegisterHotKey` only once Explorer has read the file, and nothing tells Explorer
to read it. When it does not, the key is completely dead and no error appears
anywhere - not in the shortcut, not in an event log.

This is observable: `RegisterHotKey` fails with 1409 when a combination is
already held. So trying to register it yourself is a reliable test. A working
hotkey probes as *taken* (Explorer holds it); a dead one probes as *free*. That
is precisely how the ALT+SHIFT+S failure was identified — ALT+SHIFT+O probed as
taken while ALT+SHIFT+S probed as free, which ruled out any theory about another
app stealing the key.

Installing therefore: writes the shortcut, calls `SHChangeNotify(SHCNE_CREATE)`,
polls until the combination shows as registered, retries once by deleting and
rewriting, and only then reports success. `wtf hotkey status` runs the same
check, so a key that has gone dead is visible rather than mysterious.

## How capture works

Windows Terminal has no API to report its panes, so the accessibility tree is
read instead. Each pane is a `TermControl` element with an exact rectangle.

- **Tab scoping is free.** Windows Terminal drops inactive tabs from the tree, so
  only the active tab's panes are ever visible. No filtering of our own.
- **Geometry to tree.** Find a straight line that divides the panes with none
  straddling it; that is a split. The cut sits in the middle of the gap, and the
  size is stored as the first child's fraction. Recurse.
- **Directories, best source first:** the last `PS <path>>` line in the pane's own
  scrollback; failing that, the working directory of a program running in the
  window whose folder name appears in the pane text; failing that, blank for you
  to fill in. The second case is marked `dirGuessed` and always asked about.
- The pane's own shell is never used as the source: PowerShell's `Set-Location`
  does not change the process working directory, so a shell always reports your
  home folder. Its child process carries the truth.

## How restore works

One `wt.exe` call per step, never one big command line: inside a single command
line the sub-commands do not carry focus between them, so `focus-pane` is ignored
and nested trees come out wrong.

Semantics, established by experiment:

| | |
|---|---|
| `-V` | side by side, new pane on the **right** |
| `-H` | stacked, new pane at the **bottom** |
| `-s <f>` | sizes the **new** pane |
| after a split | focus follows the **new** pane |
| `focus-pane --target n` | works; ids are creation order from 0 |

For a split node: focus the pane holding the region, split it (which creates and
focuses the second half), build the second half, then steer focus back and build
the first. Each pane is created with the directory and command of the leaf it
will become.

`--title` and `--suppressApplicationTitle` go on **every** pane. The tab shows the
focused pane's title, so unless all of them are pinned the tab name reverts as
soon as focus moves — and the tab name is what tells a later snapshot which
layout this tab is.

## Drawing the layout

A pane number tells you nothing about where the pane is, and nesting makes it
worse. So every place that lists panes also draws them.

`Add-WtfMapRects` walks the same tree the restore uses and gives each leaf a
rectangle in character coordinates, splitting in the stored proportions. Borders
are recorded as direction bits per cell (up/down/left/right) and only then
turned into box-drawing glyphs, which is what makes junctions come out as `┬`
`┤` `┼` rather than a mess of crossing lines. Each box carries its number, its
folder, and its command.

Boxes are clamped to a minimum size, because a pane with a 10% share would
otherwise be too small to show its command, and the point of the picture is to
be read.

One trap worth recording: PowerShell variable names ignore case, so a colour
held in `$R` is the same variable as the rectangle `$r`, and `$CMD` the same as
`$cmd`. The first version of the drawing printed `System.Collections.Hashtable`
across every border for exactly that reason.

## Run, or just type

A pane's command carries a `run` flag. `run: true` executes it on open;
`run: false` types it at the prompt and stops, waiting for Enter. Agent resume
lines want the second: four agents starting themselves the moment a tab opens is
rarely what was meant.

Typing without running is done by writing the characters into the pane's OWN
console input buffer (`WriteConsoleInput` on `CONIN$`), so the shell reads them
as if they had been typed. No newline is sent, so nothing executes. Verified in
a real pane: the text sits at the prompt and produces no output.

Version 1 layouts have no `run` field, and everything in them was written
expecting to run, so a missing value reads as true.

## Zoom

Three things had to be established before any of this could be written, and two
of them came out the opposite way to the obvious guess.

**Zoom belongs to a pane, not a tab.** Sending CTRL+MINUS four times to a
two-pane tab changed the focused pane from 31 rows to 47 and left its neighbour
at 31. So the layout stores a zoom per pane.

**It can be measured.** A pane's `TextPattern.GetVisibleRanges()` covers exactly
the viewport, blank lines included, so its line count is the number of text rows
on screen. Divide the pane's pixel height by that and you have the height of one
text row: 22.9 px at the default, 15.11 px after four presses. The ratio, 0.66,
is 8/12 — the font size really did go from 12 to 8. The row height is the right
thing to store because it does not change when the pane is resized.

**It cannot be set through wt.exe.** `--fontSize` is accepted by the command line
parser and then ignored. Three tabs in one window launched at sizes 8, 14 and 22
all came out with 31 rows in the same 710 pixels. So the restore sends the same
CTRL+MINUS the user would press.

`Set-WtfPaneZoom` is a closed loop rather than arithmetic: measure, press once in
the direction that helps, measure again. Font sizes step by whole points and row
heights land on whole pixels, so a calculated number of presses would be wrong as
often as right.

**Panes are identified by keyboard focus, never by an index.** Three different
orderings are in play and they all disagree as soon as a split is nested:

| ordering | who uses it |
|---|---|
| creation order | the restore plan, and `focus-pane --target` |
| layout order (the tree, top-left first) | pane numbers in a layout file |
| accessibility tree order | whatever `FindAll` hands back |

The first version focused pane *n* by creation order and then measured
`cells[n]` in accessibility-tree order. With two panes those agree, which is
exactly what the first test had, so it passed. With a nested split they do not,
and the loop measured one pane while pressing keys into another. It then either
exited straight away, because the pane it was reading happened to be right —
looking like zoom that did nothing — or pressed until the budget ran out,
because the pane it was reading never moved, leaving the other pane unreadably
small. Both were reported from real use.

Focus removes all three orderings from the question: after `focus-pane --target
n`, the pane holding the keyboard IS pane n, so `Get-WtfFocusedPaneCell` is
measuring the pane the keys are going to. `Wait-WtfPaneFocus` waits for that to
be true before any key is sent, because `focus-pane` is a separate process and
lands after the call returns.

Two more things the loop needs:

- **A step back on overshoot.** If no font size hits the target exactly, the
  loop would cross back and forth over it and stop wherever the budget ran out.
  Now a press that increases the distance is undone and the closest height is
  kept.
- **A settled reading.** A font change takes a moment to reach the screen, and
  reading too early returns the old height, which looks exactly like a press
  that did nothing. `Read-WtfSettledCell` reads until two reads agree.

It stops within half a pixel, on overshoot, when a press changes nothing (the
font is at its limit), or after 20 presses.

`Send-WtfZoomKey` refuses to press anything unless the terminal is still the
window in front. Without that check a keystroke could land in whatever the user
switched to. The zoom pass is skipped entirely when no pane has a zoom recorded,
which is every layout saved before this existed.

Panes are addressed by creation order, which is what `focus-pane --target` takes
and the order the restore built them in, so the mapping is exact. The first pane
is focused again at the end, the way a fresh tab starts.

## Knowing which layout a tab is

Update-not-overwrite is only useful if the tool can tell which layout a tab is.

The tab title was the answer, and it is not good enough. A restore pins the
layout name on every pane with `--suppressApplicationTitle`, which holds until
the user adds a pane by hand. That pane is not suppressed, its program renames
itself, and the tab title goes with it. Measured: a tab built as `ZZQ-LAYOUT`
read back as `powershell` after one hand-added pane. `--title` on its own, with
no suppression, never held at all — the shell overwrote it within seconds.

Windows Terminal has nowhere to store an id of our own. No per-tab field, nothing
the CLI can set. But a tab already has one: its UIA RuntimeId. Verified in
`tests/test-tabid.ps1`, on a real tab, it is the same:

- read twice in one process
- read from a separate process
- after a pane is added by hand
- after a program renames the tab
- after a second tab is opened
- after switching away and back
- after a neighbouring tab is closed

and different for every tab.

So `tab-bindings.json` maps a tab id to a layout name. `Get-WtfBoundLayout` reads
it, `Set-WtfTabBinding` writes it — from `wtf snap` after a save, and from the
restore once the new tab exists.

Two things make it safe rather than merely convenient:

**Stale ids cannot mislead.** Ids come from a counter, so after Windows Terminal
restarts a fresh tab can be handed a number an old note still claims. Each note
records the terminal's process id AND when that process started, and a note is
only trusted when both still match. `Remove-WtfDeadBindings` sweeps out notes
whose terminal is gone, and notes for layouts that were deleted.

**One layout is never bound to two tabs.** Writing a note drops any older note
for the same layout, so reopening a layout moves the note rather than leaving a
second one behind.

The start time is stored as **ticks, not a date string**. PowerShell 7's
`ConvertFrom-Json` turns anything that looks like a date back into a `DateTime`,
so a string written on 5.1 read back on 7 in a different format and never
compared equal. Four tests failed on 7 and passed on 5.1 until this was changed;
`test-tabid.ps1` now writes a note on one host and reads it on the other.

Below the note, the older routes remain: the tab title, then folder matching.

## Recognising a tab by its folders

The fallback when there is no note — a tab arranged by hand after a restart, for
instance. Over a working day panes are added and closed and the shape moves, but
the folders stay, which makes them the part worth matching on. Split direction,
sizes and pane order are ignored.

Folders are compared as a multiset, so a layout with two panes in one folder
needs two panes in that folder to score both. The score is
`matched / max(tabPanes, layoutPanes)` — dividing by the larger side means
neither extra panes in the tab nor extra panes in the layout can reach a perfect
score. The threshold is 0.5, which rejects "one folder in common"; a home folder
appears in almost every layout and would otherwise match everything.

Measured against the real saved layouts:

| tab | score | offered? |
|---|---|---|
| exactly as saved | 1.00 | yes |
| one pane added | 0.75 | yes |
| two panes added | 0.60 | yes |
| one pane closed | 0.67 | yes |
| one closed and one added | 0.67 | yes |
| an unrelated tab | — | no |
| a single home-folder pane | 0.25 | no |

It always asks. A wrong guess costs one keypress; a wrong silent save costs a
layout.

## Update, not overwrite

A snapshot re-reads the whole tab, so changes are noticed by construction. The
diff classifies each pane and never saves quietly:

| Result | Behaviour |
|---|---|
| unchanged / moved | command carried over, no question |
| folder changed | **always asked**, old folder and old command shown |
| new pane | **always asked** |
| folder inferred | **always asked** to confirm |
| pane closed | reported, old command shown before it goes |
| nothing to flag | still asks "Any pane commands to change? [y/N]" |

Honest limit: when one pane closes and another opens between snapshots, the pane
count is unchanged and nothing on screen says which happened. It is reported as
a folder change, with the old folder and command shown, so the call stays yours.

## The 260-character path limit

Two different programs hit this, and each needs its own fix.

**git** refuses with `Filename too long` unless `core.longpaths=true`. wtf now
passes `-c core.longpaths=true` on every call, in `Invoke-WtfGit`, so nothing in
the user's git config is changed.

**PowerShell** `Remove-Item` gives up too. The fix is the `\\?\` prefix, which
tells Windows to hand the path to the file system as-is. `Remove-WtfPath` tries
`Remove-Item` first, because it is fast and covers the ordinary case, and only
walks the tree itself through `\\?\` paths when something is left over.
Deletion is bottom-up, read-only flags are cleared, and a reparse point is
unlinked rather than walked into — walking into one would delete a dependency's
real checkout.

The order git works in is what makes this a trap rather than an inconvenience:
`git worktree remove` unregisters the worktree first and deletes the files
second. When the delete failed, the folder was left behind and `git worktree
remove` would answer `is not a working tree` from then on. So the fix has to
stop the failure happening, not only clean up after it.

## Bugs found and fixed along the way

- **One-element arrays.** `return @($x)` still unwraps to a scalar on return, so
  `.Count` became `$null` and `$null -lt 1` was true. Waiting for the first pane
  therefore ran the full 15s timeout on **every** restore — 17.1s for four panes,
  now 2.4s. Callers wrap with `@()`; the same trap had already bitten the tree
  leaf-order walk.
- **Wrong window.** The restore located its window by tab growth, but a window
  that is briefly unreadable reports 0 tabs and then 1, which looks like growth.
  A candidate must now match by title or by growth from a count actually read,
  and must really have a pane.
- **ANSI helpers on 5.1.** `_wtf_visible_len` and `_wtf_fit_ansi` used `` `e ``
  inside a regex and a comparison. On 5.1 that is the letter `e`, so escapes were
  never stripped and every width was wrong.
- **The picker grew.** It rewound by logical line count, but a row wider than the
  pane wraps onto two physical lines, leaving one behind on every keypress. Now
  it clears to the end of the screen and truncates rows to the pane width.
- **git on 5.1.** `ProcessStartInfo.ArgumentList` is .NET Core only; on .NET
  Framework it is `$null`, so every git call threw. There is now a fallback that
  builds a correctly quoted command line.
- **Zoom that landed on the wrong pane.** The restore focused a pane by its
  creation number and then measured a pane by its position in the accessibility
  tree. Those two agree only while a tab has two panes, which is what the test
  had. With a nested split, zoom either did nothing or shrank a pane until the
  press budget ran out — both seen in real use. Panes are now identified by
  which one holds the keyboard.
- **Identity that an agent could erase.** A restored tab was recognised by its
  title, and one pane added by hand was enough to lose it: the program in that
  pane renamed itself and the tab followed. The tab's own runtime id replaced it.
- **A date that changed shape between hosts.** The terminal start time was stored
  as an ISO string. PowerShell 7 parses those back into `DateTime` on read, so a
  note written on 5.1 never compared equal on 7 and every binding silently failed
  there. Ticks are a number and survive both.
- **A tab that could not be recognised.** Snapping a hand-built tab saved the
  layout but wrote nothing onto the tab, so the next snap of that same tab found
  no identity and started a second layout. Adding a pane and re-snapping — the
  normal working cycle — created a duplicate every time.
- **Colour variables overwritten by loop variables.** PowerShell ignores case in
  variable names, so `$R` (reset) and `$r` (rectangle) were one variable. The
  drawing came out full of `System.Collections.Hashtable`.
- **Filename too long.** `wtf delete` on a worktree with a `node_modules` folder
  failed at `git worktree remove`, and the fallback `Remove-Item` could not
  finish the job either. Both were the 260-character path limit, from two
  different directions.
- **A snapshot that captured itself.** The hotkey's own console window is a
  Windows Terminal window on Windows 11, so the capture targeted it: one pane,
  no directory. The saved layout had a leaf tree and a single pane, and the
  "folder unknown" prompt then asked the user to type a directory for it.
- **A hotkey that installed but never fired.** The shortcut file was written
  correctly, with the right key on it, and did nothing — because Explorer had
  never read the file, so Windows had registered no key at all. Nothing reported
  a problem. Install now notifies the shell and verifies the registration.

## Testing

- `test-layout-core.ps1` — 40 unit tests: name rules, geometry to tree, restore
  plan, launch-argument encoding, all four diff cases, JSON round trip. Passes on
  both hosts.
- `test-zoom.ps1` — 18 tests on real tabs: zooming one pane leaves its neighbour
  alone, the capture records both, it survives the JSON round trip and the
  restore plan, a rebuilt tab lands on the same row heights, and a layout with no
  zoom saved asks for none. Section 6 is the case the two-pane tests could not
  see: four panes with a nested split and a different zoom in each, checked to
  come back exactly and checked that no pane was shrunk past its target.
- `test-tabid.ps1` — 23 tests on a real terminal tab: the id is stable across
  processes, across a hand-added pane, across a program renaming the tab, across
  tab switches; a second tab differs; a note survives all of it; a stale or dead
  terminal voids a note; a note written on one host reads on the other. Passes on
  both.
- `test-layout-core.ps1` section 12 — 20 tests for recognising a tab: unchanged,
  a pane added, a pane closed, both at once, an unrelated tab, the closer of two
  layouts, duplicate folders as a multiset, and the threshold itself.
- `test-longpath.ps1` — 14 tests: `\\?\` path building including UNC, deleting a
  tree 479 characters deep, read-only files, a junction whose target must
  survive, a missing path, and that git really receives `core.longpaths`.
- `test-e2e.ps1` — builds a real tab, captures it, saves it, rebuilds it in
  another window, re-captures and compares tree and directories, then diffs a
  changed tab against the saved layout.
