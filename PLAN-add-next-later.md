# Plan: Add Next/Later Categories

## Current State

The codebase has three goal categories:
- `a/` (active) — currently working on
- `i/` (inactive) — not working on, will become "later"
- `d/` (deleted) — completed

Commands currently use `inactive` for picking goals (edit, start, delete). The `goal list` command shows all active + inactive goals. New goals are created in "inactive".

Goal files live in the global `~/.goal/<goal_id>/` directory (not in the project repo). Starting and stopping a goal commit only the local `.goal/.active_id` change to the project's git history — the goal file moves happen entirely in global storage.

## Migration (Manual)

Before building, run the following to migrate existing goal storage:

```sh
# Rename the inactive directory to later
mv ~/.goal/<goal_id>/i ~/.goal/<goal_id>/l

# Create the new next directory
mkdir ~/.goal/<goal_id>/n
```

Replace `<goal_id>` with the UUID found in your project's `.goal/.goal_id` file.

## Approach

- [x] **Add `next`/`later` directories in `Directories.zig` and fix all `inactive` references**

  This is the foundation. Every other step depends on it. All in one step because
  splitting it would leave the binary broken between sub-tasks.

  In `Directories.zig`:
  - Rename field `.inactive` → `.later`, change path `"i"` → `"l"`
  - Add field `.next: Dir`, path `"n"`
  - Update `open`, `close`, and `listAll` accordingly
  - `listAll` should show "Later Goals" instead of "Inactive Goals"

  Fix all broken `.inactive` references (these will be compile errors after the above):
  - `commands/stop.zig:55` — change destination to `dirs.later` (temporary; will be
    updated properly in the `goal stop` step)
  - `commands/start.zig:227,239,260,331,398` — change to `dirs.later` (temporary)
  - `commands/edit.zig:62-63` — change to `dirs.later` (temporary)
  - `commands/delete.zig:53,71,107,122,133` — change to `dirs.later` (temporary)
  - `commands/new.zig:71,81` — change to `dirs.later`; `goal new` always creates in later

  After this step: all existing commands work, just against `l/` instead of `i/`.
  `goal list` shows active + later (temporary — fixed in the list step).

- [x] **Register `next` and `later` commands (stubs)**

  Depends on: previous step (`dirs.next` and `dirs.later` must exist).
  Reference: any existing command file as a structural template (e.g. `commands/stop.zig`).

  - Create `commands/next.zig` as a stub (parses args, prints a placeholder message)
  - Create `commands/later.zig` as a stub (same)
  - Add `.next` and `.later` to `Command` enum in `commands.zig`, export both modules
  - Add dispatch cases in `main.zig`
  - Add placeholder help text entries in `commands/help.zig`

  After this step: `goal next` and `goal later` run without crashing. All other
  commands still work.

- [x] **Implement `commands/next.zig`**

  Depends on: previous two steps.
  Reference: `commands/stop.zig` for the stop-first pattern; `commands/edit.zig:61-63`
  for the fallback-try dir lookup pattern.

  - Accept optional goal ID argument; prompt with later list if omitted
  - Only Later goals may be promoted to Next
  - Move goal file from `l/` → `n/`
  - Error if goal is not found in `l/`

- [x] **Implement `commands/later.zig`**

  Depends on: previous step (or can be done in parallel — same structure).
  Reference: `commands/next.zig` (mirror image).

  - Same structure as `next.zig` but moves to `l/`
  - Error if goal is not found in `n/`

- [x] **Update `goal stop`**

  Depends on: `Directories.zig` step.
  Reference: `commands/stop.zig:42-67` (existing run function).

  - Default: move stopped goal to `n/` (replace current `dirs.later` temporary)
  - Add `--later` flag to `parseArgs`; move to `l/` when set
  - Update `stop` help text in `commands/help.zig` to document `--later`

- [x] **Update `goal list`**

  Depends on: `Directories.zig` step.
  Reference: `commands/list.zig` and `Directories.listAll`.

  - Add flags to `parseArgs` in `list.zig`
  - Default (`listAll` or a new `listDefault`): show active + next only
  - With `--all`: show active + next + later
  - With `--active`: show active
  - With `--next`: show next
  - With `--later`: show later
  - Update `list` help text in `commands/help.zig` to mention new flags

- [x] **Update `goal edit`**

  Depends on: `Directories.zig` step.
  Reference: `commands/edit.zig:61-63` (already uses fallback-try — extend it).

  - Extend fallback-try chain: active → next → later
  - `getGoalChoice` interactive picker (no-ID path) shows all non-deleted goals
    (active + next + later)
  - Edge case: no goals to choose from

- [x] **Update `goal delete`**

  Depends on: `Directories.zig` step.
  Reference: `commands/delete.zig:53,71,107,122,133` (all currently hardcoded to `inactive`).

  - Fallback-try next → later for ID lookup and validation
  - Interactive picker shows next + later goals only
  - `run` function: rename from whichever dir the goal was found in → `d/`

- [x] **Update `goal start`**

  Depends on: `Directories.zig` step.
  Reference: `commands/start.zig:227,239,260,331,398`; `commands/edit.zig:61-63` for
  fallback-try pattern.

  - Fallback-try next → later for ID lookup (both the provided-ID and interactive paths)
  - Interactive picker shows next + later goals only
  - `std.fs.rename` source must be whichever dir the goal was found in

- [ ] **Update help text for `next` and `later`**

  Depends on: `next.zig` and `later.zig` being fully implemented.

  - Replace placeholder help entries with real usage, arguments, and examples in
    `commands/help.zig`
  - Add `next` and `later` to the main command list in the top-level help text

## Unknowns & Risks

- **Goal file paths** — When moving goals between categories, need to ensure proper error handling if the file already exists in the destination.
- **Interactive prompts** — Each command (start, delete, edit) maintains independent inline listing logic. The set of goals shown differs per command: edit shows all non-deleted, start/delete show next + later only.

## Edge Cases

- `goal stop --later` when no active goal — same "no active goal" error path as today, `--later` is irrelevant.
- `goal next <id>` where the goal is already in `n/` — explicit "already in next" error.
- `goal later <id>` where the goal is already in `l/` — explicit "already in later" error.
- `goal start` / `goal delete` interactive picker when both next and later are empty — fail with a clear message before prompting.
- Goal ID provided to `goal start` that exists in neither next nor later — error out after both fallback attempts.

## Impact Surface

- `src/Directories.zig` — rename `.inactive` field, add `.next` field, update `open`, `close`, `listAll`
- `src/commands.zig` — add `.next` and `.later` to `Command` enum, export new modules
- `src/main.zig` — add dispatch cases for `.next` and `.later`
- `src/commands/new.zig` — update `dirs.inactive` → `dirs.later` (goals always created in later)
- `src/commands/stop.zig` — add `--later` flag, default destination `n/`, update help
- `src/commands/start.zig` — fallback-try across next + later, update inline picker
- `src/commands/edit.zig` — fallback-try across active, next, later
- `src/commands/delete.zig` — fallback-try across next + later, update inline picker
- `src/commands/list.zig` — add `--all` flag, change default to active + next
- `src/commands/help.zig` — add help text for `next` and `later`, update `stop`, `list`
- `src/commands/next.zig` — new file
- `src/commands/later.zig` — new file

## Success Criteria

- [ ] `goal next <id>` moves goal to `n/`
- [ ] `goal later <id>` moves goal to `l/`
- [ ] Both `next` and `later` commands handle an active goal (stop it first)
- [ ] `goal next` and `goal later` without args prompt with goals from appropriate categories
- [ ] `goal stop` moves to `n/` by default
- [ ] `goal stop --later` moves to `l/`
- [ ] `goal list` shows only active + next by default
- [ ] `goal list --all` shows active + next + later
- [ ] `goal edit` can edit any non-deleted goal
- [ ] `goal delete` can delete from next or later (not active)
- [ ] `goal start` can pick from next + later
- [ ] Help text is updated for all affected commands

## Out of Scope

- `goal roadmap` command
- `goal suggest` command
- Any other roadmap/suggestion features
- Changing the default behavior of `goal new` (creates in "later")
- Automated migration / versioned directory structure

## Deferred

- Ideas for `goal roadmap` (show active + next as a view)
- Ideas for `goal suggest` (suggest next goal based on heuristics)
- Versioned migration system — a `.goal_version` file or similar to detect and run migrations automatically when the directory structure changes; cleanly removable once all users have migrated
- Unified interactive goal picker with arrow-key navigation (currently each command has independent inline listing logic)
