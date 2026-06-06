# wtf — Agentic Terminal Slots: Implementation Tracker

Living record of the slot/session redesign. Updated as work lands.

## Core model (the rules we settled on)

- **A slot exists only if it has a real command (a real session).** No empty slots are ever stored.
- `wtf create` seeds the executor *count/roles* into `_PLAN.md` + `.plan/<exec>/` folders so the
  planner knows how many executors exist — but it does **not** create slots in meta.
- Slots are born in `wtf edit` when you paste a resume command (full command, session id baked in).
  wtf runs that command verbatim and never scripts past it (you answer whatever the CLI prompts).
- **"Not using" in edit:** slot has a command → **archive** it (reviewable/reopenable later);
  slot has no command → **delete** it. Nothing empty is kept.
- **Layout (hardcoded):** planner → own tab. root-exec executors → side-by-side **panes** in one tab
  (`split-pane -V`, exec-1 left, exec-2 right). freeform / researcher / custom → own tab.
- **Mono** features: no `.code-workspace` (open the repo folder directly); `.plan/` lives inside the
  repo, git-excluded locally. **Multi** keeps the workspace.
- `wtf open` never prompts. `wtf edit` configures and **stops** (never opens).

## Commands

| Command | Role |
|---|---|
| `wtf create` | worktrees + workspace(multi) + plan/.plan folders; seeds exec count; no slots |
| `wtf open` | reopen editor + runners + saved agent slots (auto-resume); zero-slot = hint, no empty tabs |
| `wtf edit` | state-aware walk-through to set up / change agent terminals; saves and stops |
| `wtf sessions` | list active + archived sessions for a feature; reopen one in the agents window |
| `wtf status` | per-feature dashboard: git status, slots, plan-task progress |
| `wtf add/remove/list/doctor/config` | unchanged |

## Six-step plan & status

- [x] **1. Bug fixes** — freeform = own tab (`tab` layout, purple `#A855F7`); panes `-V` (left/right);
      `wtf edit` saves and stops (no open).
- [x] **2. No-empty-slot invariant** — create seeds `_PLAN.md` + `.plan/<exec>/` from the chosen exec
      count and stores `execCount` in meta, but creates **no** slots; `Get-WtfSlots` never seeds and
      drops any empty-command slot; `open` on a zero-slot feature prints a hint, no empty tabs.
- [x] **3. State-aware walk-through** — `Invoke-WtfSlotWalkthrough` branches: FIRST-TIME (no active
      slots) just asks each suggested terminal for a command, skip = not created; EDITING (slots
      exist) offers keep/change/not-using + add + restore-archived.
- [x] **4. Archive model** — `archivedSlots` in meta; "not using" on a real session archives it
      (with `archivedAt`); empties are simply never stored. `Set-WtfMetaSlots` persists both arrays.
- [x] **5. `wtf sessions`** — lists active + archived; reopen one via `Invoke-WtfLaunchOneSlot` into
      the existing `wtf-agents-<branch>` window (no new window).
- [x] **6. `wtf status`** — git status per worktree + active/archived sessions + plan checkbox
      progress (`_PLAN.md` + each `.plan/<exec>/tasks.md`).

## Verification

- [x] Full AST parse clean
- [x] Launcher trace: planner tab + 2 exec panes (`-V` left/right) + freeform own tab + encoded cmds
- [x] Invariant: empty-command slots dropped by `Get-WtfSlots`
- [x] Archive round-trip + `Set-WtfMetaSlots` (hashtable + PSCustomObject)
- [x] Walk-through: first-time (give 2, skip 1 → 2 active, 0 archived); editing (keep/keep/archive → archived w/ date)
- [x] `wtf sessions` reopen → single tab into existing agents window
- [x] `wtf status` plan progress counts (1/3, 2/3, 0/2)

## Dispatcher

- `wtf sessions` / `wtf session` → `Invoke-WtfSessions`
- `wtf status` → `Invoke-WtfStatus`
- Help text updated.

## Round 2 — UI/UX refinements (done)

- [x] **Working-directory bug** — agent tabs were starting in the home dir because
      pwsh's `$PROFILE` runs `Set-Location ~` after `wt -d`. Fixed by baking
      `Set-Location -LiteralPath '<dir>'` into the launched script (before the
      user's command), so the agent always starts in the worktree/feature dir.
- [x] **Distinct colors** — planner orange, root-exec **blue** `#3B82F6`,
      freeform **purple** `#A855F7`, researcher teal `#14B8A6`.
- [x] **Preview** — pane executors bracketed `[ a │ b ]`; explainer line removed.
- [x] **Edit TUI** — replaced the linear walk-through with a **live slot board**
      (`Invoke-WtfSlotBoard`): ↑↓ move · enter edit (inline overlay) · a add ·
      x archive · r restore · s save · esc cancel. First-time features pre-seed
      suggested placeholder rows; save drops any placeholder without a command.
      `Invoke-WtfSlotWalkthrough` is now a thin wrapper over the board.
- [x] Verified: launch dir bake, insert-at-boundaries splice, save-drops-empties,
      colors, bracketed preview, full launcher argv. Parse clean.

## Round 3 — UI unification + real-run testing (done)

Ran the tool for real against throwaway git sandboxes (bare-remote + worktrees),
not just parse checks. Verified end-to-end: `config show`, `list`, `doctor`,
`create` (real worktrees + `.plan/` tree + meta `execCount`/`slots=0`), `open`
(agent tabs rooted at feature root, bracketed pane preview, runner per-worktree
dirs), `status` (git + sessions + plan progress), `sessions` (active list).

Fixes found by actually running it:
- [x] **`Write-WtfSummary` box overflow** — long branch/path lines blew past the
      border. Added `_wtf_fit_ansi` (ANSI-aware truncation with `…`). Also fixed a
      PowerShell precedence bug in it: `func $x -le $y` parses as
      `func ($x -le $y)` — needed `(func $x) -le $y`. Box now always aligns.
- [x] **`Write-WtfHeader`** refined to a rail + bold title + faint rule, matching
      the pickers/board.
- [x] Confirmed the live **slot board** frame renders cleanly (rail, highlight,
      `┌/└` pane brackets, amber "needs command", hint footer).
- [x] Confirmed the **working-dir fix** end-to-end: every agent tab's `-d` is the
      feature root and `Set-Location` is baked into the command.

UI status: pickers, multi-select, slot board, headers, summary, status, sessions,
and all step/ok/warn/fail lines now share one premium aesthetic.

## Notes / decisions log

- Archive scope = per-feature, in that feature's `.wtf-meta.json`.
- `wtf sessions` reopen docks into the existing agents window (no new window).
- We are NOT building a per-CLI config registry / id-only capture now (wtf stays CLI-agnostic;
  you paste the full resume command).
