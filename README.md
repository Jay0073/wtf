# wtf — WorkTree Flow

A Windows terminal workflow tool with two jobs:

1. **Worktrees.** Make a git worktree (or several, across several repos) for a
   feature, with the ignored files carried over, and hand you the paths.
2. **Tab layouts.** Save the pane arrangement of a Windows Terminal tab, and
   rebuild it later — same splits, same sizes, same folders, same commands.

It does not open an editor, does not open windows for you, and does not manage
your panes. You arrange your tab however you like; `wtf` remembers it.

```
ALT+SHIFT+S     save the tab in front as a layout
ALT+SHIFT+O     pick a saved layout and rebuild it as a new tab
```

## Why it exists

Working on several projects and several branches at once used to mean a window
per feature: an editor here, a window of agent terminals there, another window
of terminals for running things. That falls apart quickly.

What actually works is one terminal tab, split into panes, each pane sitting in
the folder it belongs to — an agent CLI in one, a dev server in another, a
worktree of the same repo in a third. The problem is that this arrangement is
expensive to rebuild by hand, and you lose it every restart.

`wtf snap` reads the arrangement off the screen and writes it down. `wtf tab
open` builds it again.

## Requirements

- Windows 10 or 11 with **Windows Terminal**
- **Windows PowerShell 5.1** (built in) or **PowerShell 7+** — both work
- **git** 2.5 or newer, on PATH

## Install

```powershell
git clone https://github.com/Jay0073/wtf.git "$env:USERPROFILE\.wtf"
Copy-Item "$env:USERPROFILE\.wtf\config.example.json" "$env:USERPROFILE\.wtf\config.json"
```

Load it from your profile:

```powershell
notepad $PROFILE
```

```powershell
$wtfScript = Join-Path $env:USERPROFILE '.wtf\wtf.ps1'
if (Test-Path $wtfScript) { . $wtfScript }
```

Reload with `. $PROFILE`, then set up your root folders:

```powershell
wtf config          # interactive: add root folders and repo groups
wtf hotkey install  # ALT+SHIFT+S and ALT+SHIFT+O
```

> All `.ps1` files here are UTF-8 **with BOM**. That is not cosmetic: without
> the BOM, Windows PowerShell 5.1 reads them in the ANSI codepage and every box
> character and emoji breaks. Keep the BOM if you edit them.

## Tab layouts

### Saving

Arrange your tab: split panes, `cd` each one where it belongs, start whatever
runs there. Then press **ALT+SHIFT+S**.

The hotkey matters more than it looks. Your panes are usually all busy — an
agent in one, a server in another — so there is often no free shell to type a
command into. The hotkey needs no free pane and types nothing into yours.

It reads the tab, shows you what it found, and asks for a command per pane:

```
New layout 'pigeon' - 4 panes
--------------------------------------------------
  pane 1   NEW       ...\worktrees\pigeon-feat-feed\feed
           (no command)
  pane 2   NEW       ...\projects\pigeon-resume
           (no command)
```

Before it asks anything it **draws the tab**, and it redraws it with the current
pane marked as it walks through them, so there is never any doubt which pane you
are setting:

```
  ┌─────────────────────────────┬──────────────────────────────┐
  │ > pane 1 <                  │ pane 3                       │
  │ pigeon-resume               │ citedspy-feat-activepieces   │
  │ > npm run dev               │ ~ claude --resume 2c22edf3…  │
  │                             ├──────────────────────────────┤
  │                             │ pane 4                       │
  ├─────────────────────────────┤ citedspy                     │
  │ pane 2                      │ (no command)                 │
  │ citedspy                    │                              │
  └─────────────────────────────┴──────────────────────────────┘
  > runs on open    ~ typed at the prompt, waiting for Enter
```

**Leaving a pane blank is a normal answer.** Press Enter and that pane just opens
as a shell in the right folder. Plenty of panes want nothing more than that.

**A command does not have to run.** After you type one you are asked whether it
should run when the tab opens:

- **yes** — it executes, which is what you want for `npm run dev` or a server.
- **no** — it is **typed at the prompt and left there**, waiting for you to press
  Enter. This is what you want for an agent resume line. Four agents launching
  themselves the moment a tab opens is rarely the intention.

Finally it asks for a **description** — one sentence about what the layout is
for. Names get cryptic after a few weeks; the description is what you actually
read when you come back to it.

You can also type `wtf snap [name]` inside the tab. Add `--without-me` if you
opened a scratch pane purely to run the command and do not want it saved.

### Opening

Press **ALT+SHIFT+O**. The list shows every layout's **name on the left and its
shape drawn beside it**, with the pane count and description underneath, so you
choose by looking rather than by remembering:

```
  > pigeon            ┌──────────────┬──────────────┐
    citedspy work     │ pane 1       │ pane 3       │
    api sweep         │ feed         │ citedspy     │
                      │ > npm run dev│ ~ claude …   │
                      └──────────────┴──────────────┘

  4 panes  ·  activepieces app plus the jumpseller billing check
```

Enter rebuilds it in your current window: same tree, same sizes, same folders,
each pane's command either running or waiting at the prompt. About 2.5 seconds
for four panes.

`wtf tab open [name]` does the same, and `wtf tab ls` prints every layout drawn
out in full.

### Changing one

Layouts are not frozen. Close the pane for a feature you finished, split a new
one, `cd` somewhere else — then press **ALT+SHIFT+S** again. Because the tab
carries its layout's name, that is an **update**, not a new layout.

Nothing is ever saved quietly:

| What changed | What happens |
|---|---|
| pane untouched, or just moved | keeps its command, no question asked |
| **pane's folder changed** | **always asked**, with the old folder and command shown |
| **new pane** | **always asked** for a command |
| folder had to be inferred | **always asked** to confirm |
| pane closed | reported, with its old command, before it goes |
| run or type | carried over as you set it |
| nothing to flag | still asks *"Any pane commands to change? [y/N]"* |

One honest limit: if you close one pane and open another between snapshots, the
pane count is unchanged and nothing on screen says which happened. It is
reported as a folder change, with the old folder and command shown, so the
decision stays yours.

### Layout names

Letters, digits, spaces, `-`, `_`, `.` and emoji. Up to 60 characters. Not
allowed: `\ / : * ? " < > |` or the Windows device names (`CON`, `COM1`, …).
Names ignore case, because Windows filenames do.

## Worktrees

```powershell
wtf create
```

Asks which root folder (personal, work), which project, which branch, and which
repos. It creates the worktrees, copies the gitignored files that a worktree
would otherwise miss (`.env`, local config, certs), links any read-along
dependency repos, scaffolds a `.plan/` folder, and then **prints the paths and
stops**.

Nothing is opened. You copy a path into whichever pane you want.

```
Paths
  feed
    C:\Users\you\Documents\projects\worktrees\pigeon-feat-feed\feed
  bot
    C:\Users\you\Documents\projects\worktrees\pigeon-feat-feed\bot
```

Other commands: `wtf add`, `wtf remove`, `wtf delete`, `wtf list`, `wtf status`,
`wtf doctor`, `wtf config`.

## All commands

```
wtf create  [ctx proj branch apps...] [--dry-run]   make worktrees, print the paths
wtf add     [ctx proj branch apps...] [--dry-run]   add repos/deps to a feature
wtf remove  [ctx proj branch apps...] [--force]     drop repos/deps from a feature
wtf delete  [ctx proj branch] [--force] [--dry-run] tear a whole feature down
wtf list                                            every active feature
wtf status  [ctx proj branch]                       git state + plan progress
wtf doctor  [--fix]                                 find and repair leftovers
wtf config                                          set up roots and repo groups

wtf snap    [name] [--without-me]                   save THIS tab as a layout
wtf tab ls                                          list saved layouts
wtf tab open [name]                                 rebuild a layout in a new tab
wtf tab edit [name]                                 edit a layout's commands
wtf tab rm  [name]                                  delete a layout

wtf hotkey install [snap|open] [COMBO]              defaults: ALT+SHIFT+S / ALT+SHIFT+O
wtf hotkey status | remove [snap|open]
```

Leave a name out of any layout command and you get a list to pick from.

## About the hotkeys

They are Start Menu shortcuts carrying a Windows "shortcut key" — no extra
software, no background process.

The focused application sees the key **first**. Windows only acts on the
shortcut key when the application does not handle it. `ALT+SHIFT+S` and
`ALT+SHIFT+O` are not Windows Terminal bindings, so they reach `wtf` even while
the terminal is focused — which is exactly what snapping the front tab needs.
They also stay clear of the pane keys you already use: `ALT+SHIFT+plus/minus` to
split, `ALT+SHIFT+arrows` to resize.

If an application does bind one of them, that application wins while it has
focus. Rebind with `wtf hotkey install snap CTRL+ALT+S`.

The hotkey windows are launched through `conhost.exe` on purpose. Windows 11
hosts console applications inside Windows Terminal by default, and a window
opened that way *is* a terminal window — which would let a snapshot capture
itself instead of your tab. `conhost` gives it a classic console window instead.
As a second guard, the snapshot works out which window is its own and rules it
out before choosing what to capture.

**Installing verifies itself.** Writing the shortcut file is not enough: Windows
only registers the key once Explorer has read the file, and if it never does the
key is dead with no error shown anywhere. So `wtf hotkey install` tells the
shell about the new shortcut, then checks that the combination really is
registered, retries once, and tells you plainly if it still is not — rather than
reporting success for a key that does nothing.

`wtf hotkey status` reports the same thing, so if a key ever stops working:

```powershell
wtf hotkey status     # says NOT registered when the key is dead
wtf hotkey install    # rewrites it and verifies
```

## Files

| Path | What it is |
|---|---|
| `wtf.ps1` | worktree engine, shared UI, dispatcher; loads the rest |
| `wtf-layout.ps1` | capture, directory resolution, geometry→tree, diff, restore |
| `wtf-tab.ps1` | `snap` and the `tab` commands, pane editor, picker |
| `wtf-map.ps1` | draws a layout as boxes |
| `wtf-prefill.ps1` | types a command at a pane's prompt without running it |
| `wtf-hotkey.ps1` | install/remove the global hotkeys |
| `wtf-snap-hotkey.ps1`, `wtf-open-hotkey.ps1` | what the hotkeys run |
| `config.json` | your root folders and repo groups (ignored by git) |
| `layouts/*.json` | one file per saved layout (ignored by git) |

## How it works, briefly

Windows Terminal has no API for reading its own panes, so `wtf` reads the
accessibility tree: every pane is a `TermControl` element with an exact
rectangle. Only the **active** tab is in that tree, so a snapshot is tab-scoped
by construction.

Rebuilding is one `wt.exe` call per step, never one long command line — inside a
single command line the sub-commands do not carry focus between them, so
`focus-pane` is ignored and nested layouts come out wrong.

See [IMPLEMENTATION.md](IMPLEMENTATION.md) for the details, including the
Windows Terminal behaviour this depends on and the bugs found while building it.

## Licence

MIT.
