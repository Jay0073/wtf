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

## Testing

- `test-layout-core.ps1` — 40 unit tests: name rules, geometry to tree, restore
  plan, launch-argument encoding, all four diff cases, JSON round trip. Passes on
  both hosts.
- `test-e2e.ps1` — builds a real tab, captures it, saves it, rebuilds it in
  another window, re-captures and compares tree and directories, then diffs a
  changed tab against the saved layout.
