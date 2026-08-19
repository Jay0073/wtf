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

### Zoom

Panes are saved at the zoom you had them at, and rebuilt the same way.

Zoom in Windows Terminal belongs to one pane, not to the tab: CTRL+MINUS shrinks
the pane you are in and leaves the others alone. So each pane carries its own,
and a tab where one pane is small and the rest are normal comes back exactly
like that.

It is stored as the height of one text row in pixels, because that number does
not move when you resize the pane — only when the font size changes.

Rebuilding sends the same CTRL+MINUS you would press yourself, because `wt.exe`
has no way to set a font size. Each pane is focused first, then measured while it
holds the keyboard, so the keys and the measurement are always about the same
pane. Three things follow from that:

- It takes about a second, and you see `setting zoom - do not type for a moment`.
- If you switch to another window while it is working, it stops rather than
  typing into whatever you switched to, and tells you so.
- If a target zoom is between two font sizes, you get the nearer of the two.

A layout saved before this existed has no zoom recorded, so nothing is sent and
it opens at your normal size. Snap it once and the zoom is picked up.

### Searching a pane

Windows Terminal already has this, and it is easy to miss: **CTRL+SHIFT+F** opens
a find box for the pane you are in, with case-sensitive and regular-expression
toggles and next/previous buttons. It searches that pane's scrollback, not the
other panes.

### Which layout is this tab?

Snapping the same tab twice should update that layout, not make a second one. So
the tool has to answer one question first: **have I seen this tab before?**

It used to answer by reading the tab title. That is not good enough. As soon as
you add a pane by hand and run an agent in it, the program renames the tab and
the only clue is gone.

Windows gives every tab a runtime id of its own. You never see it, and we do not
get to choose it, but it is exactly what is needed. It stays the same while panes
are added and closed, while you switch tabs and come back, while a neighbouring
tab is closed, and while a program renames the tab. Every tab has a different one.

So the tool keeps a small notebook, `tab-bindings.json`:

```
tab 42.852866.4.368  ->  pgn-re
tab 42.852866.4.415  ->  wtf-citedspy
```

The first snap of a tab asks for a name and writes the note. Every snap after
that reads the id, finds the note, and goes straight to what changed:

```
▌ Changes to 'pgn-re' since it was saved
  pane 1  same       C:\Users\jay\Documents\projects\pigeon-resume
  pane 2  same       C:\Users\jay\Documents\projects\freellmapi
  pane 3  same       C:\Users\jay\Documents\projects\pigeon-resume
  pane 4  NEW        C:\Users\jay\Documents\projects\pigeon-claw

  ? pane 4 has no command. What should it run?
```

No name prompt, no guessing, no list. `wtf tab open` writes the note too, for the
tab it just built, so a reopened layout is bound from the moment it appears.

**The one limit.** The id only lives as long as Windows Terminal does. Closing
the terminal or restarting the machine forgets every note. Reopening a layout
with `wtf tab open` writes a fresh note straight away, so in normal use you never
notice. Only if you rebuild the same panes by hand after a restart does it have
to ask once.

Each note also records which terminal it was taken in, and when that terminal
started. A note from a terminal that has since restarted is thrown away rather
than trusted, so a recycled id can never point at the wrong tab.

**If there is no note**, it falls back: first the tab title, then the folders the
panes are in. Folder matching is a guess, so it shows you the layout it thinks
this is and asks. A match needs at least half the panes to line up — one folder
in common is not enough, since your home folder is in almost every layout.

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

### Long paths

Windows used to limit a full path to 260 characters. A worktree folder name is
already long, and `node_modules` adds another 150 on its own, so real projects
cross that line.

`wtf delete` handles it. Every git call is made with `core.longpaths=true`, and
if a folder still refuses to go, wtf deletes it itself through `\\?\` paths,
which the limit does not apply to. Junctions are unlinked, never followed, so a
dependency's real checkout is never touched.

This matters more than it sounds. `git worktree remove` unregisters the worktree
**before** it deletes the files, so when the delete failed you were left with a
folder git no longer knew about, and running the same command again could not
help.

## All commands

Every argument is optional. Leave one out and you are asked, or given a list to
pick from.

### Worktrees

| Command | What it does |
|---|---|
| `wtf create [ctx proj branch apps...]` | Asks root folder, project, branch and repos. Creates the git worktrees, copies the gitignored files a worktree would miss (`.env`, local config, certs), links read-along dependency repos, scaffolds `.plan/`, then **prints the paths and stops**. Opens nothing. |
| `wtf add [ctx proj branch apps...]` | Adds more repos or dependency repos to a feature that already exists. |
| `wtf remove [ctx proj branch apps...]` | Drops repos or dependencies from a feature, leaving the rest intact. Offers to delete the local branch for each repo removed. |
| `wtf delete [ctx proj branch]` | Tears a whole feature down: worktrees, junctions, the feature folder and its bookkeeping. |
| `wtf list` &nbsp;·&nbsp; `wtf ls` | Every active feature, with each repo's git state (clean / dirty / ahead / behind) and its path. |
| `wtf status [ctx proj branch]` | One feature in detail: per-repo git state, plus `.plan/` progress (how many steps are ticked off). |
| `wtf doctor` | Finds leftovers — ghost worktree records, orphaned folders, stale files — and reports them. |
| `wtf config` | Interactive menu: add root folders (personal, work), define multi-repo groups, rename or remove them, show everything. |
| `wtf config edit` | Opens `config.json` in your editor directly. |

### Tab layouts

| Command | What it does |
|---|---|
| `wtf snap [name]` | Saves the current tab as a layout: the pane tree, the split sizes, each pane's folder, command and zoom. A tab it has snapped before is recognised straight away and updated, with no name prompt. Draws the tab, then walks the panes asking for a command and whether it should run. Asks for a description. If the tab already belongs to a layout, this **updates** it. |
| `wtf tab ls` &nbsp;·&nbsp; `wtf tabs` | Lists every saved layout, each one **drawn** as boxes with its description. |
| `wtf tab open [name]` &nbsp;·&nbsp; `wtf open [name]` | Rebuilds a layout as a new tab in the current window. With no name you get a picker: names on the left, the highlighted layout drawn beside them, description below. |
| `wtf tab edit [name]` &nbsp;·&nbsp; `wtf edit [name]` | Opens the layout's JSON in your editor, to change commands or the `run` flag by hand. |
| `wtf tab rm [name]` | Deletes a layout, after confirming. |
| `wtf tab save [name]` | Same as `wtf snap`. |

### Hotkeys

| Command | What it does |
|---|---|
| `wtf hotkey install` | Installs both: **ALT+SHIFT+S** to snap the tab in front, **ALT+SHIFT+O** to open a layout. Verifies Windows really registered each key rather than assuming it. |
| `wtf hotkey install snap <COMBO>` | Rebinds just the snap key, e.g. `wtf hotkey install snap CTRL+ALT+S`. |
| `wtf hotkey install open <COMBO>` | Rebinds just the open key. |
| `wtf hotkey status` | Shows both shortcuts and whether Windows has actually registered them. |
| `wtf hotkey remove [snap\|open]` | Removes one hotkey, or both if you name neither. |

### Flags

| Flag | Applies to | Meaning |
|---|---|---|
| `--dry-run` | `create`, `add`, `remove`, `delete` | Show what would happen; change nothing. |
| `--force` | `remove`, `delete` | Skip the confirmation prompts. |
| `--fix` | `doctor` | Repair what it finds, instead of only reporting. |
| `--without-me` | `snap` | Leave out the pane you typed the command in — for when you opened a scratch pane just to run it. |
| `--foreground` | `snap` | Capture the window in front rather than the one this shell is in. This is how the hotkey calls it. |

### The two keys you will actually use

| Key | What happens |
|---|---|
| **ALT+SHIFT+S** | Saves the tab in front. Needs no free pane, and types nothing into yours. |
| **ALT+SHIFT+O** | Shows the layout picker and rebuilds the one you choose as a new tab. |

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
