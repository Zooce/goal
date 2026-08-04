---
name: goal
description: >
  Use the goal CLI to track work one goal at a time: session status, start/stop,
  create goals, append notes, list/show, complete. Use when the project uses
  goal, at session start/resume, when the user mentions goals/todos/what am I
  working on, or when starting, stopping, completing, or creating work items.
  Prefer goal over inventing a parallel task list.
---

# Goal skill

`goal` is the project's work tracker. Use it for work context instead of ad-hoc
markdown todos or a second task system.

Prerequisites: `goal` is installed, and the project has been initialized
(`goal init` was run; `.goal/` or project goal storage exists). If status fails
because the project is not initialized, say so and ask before running `goal init`.

## Hard rules for agents

1. **Session start.** When `goal` is available and the project is initialized,
   run `goal status --full` and treat the output as work context (active goal,
   notes, body).
2. **Do not invent a second tracker.** Prefer existing goals (`goal start <id>`,
   `goal list --all`) over parallel todo lists.
3. **Non-interactive only.** Always pass explicit goal IDs. Use title args,
   `--file`, `-q`/`--quiet`, and `--yes` where needed. Never rely on TTY pickers
   or opening an editor (agents run without a usable TTY for those flows).
4. **Do not complete, stop, or start a different goal unless the user asks.**
   While working an active goal, keep it active. Finishing implementation is not
   the same as completing the goal.
5. **Do not run git commands that change the repo unless the user asks.**
   That includes commit, add, push, reset, checkout that discards work, etc.
   `goal` itself may create its own commits when you run goal commands that
   mutate state; that is separate from committing project source changes.
6. **Capture progress with notes.** Use `goal note` for decisions, blockers, and
   progress the next session should see. Do not only leave that context in chat.

## Agent loop

Typical flow when the user wants work tracked:

```text
status --full  ->  (optional) new / start <id>  ->  work  ->  note  ->  (only if asked) complete | stop
```

1. `goal status --full` -- see active goal and full details.
2. If there is no active goal and the user wants to work on something known:
   `goal start <id>` (get ids from `goal list --all` or the user).
3. If they want a brand-new goal and to work it now:
   `goal start new "title here"` or create first with `goal new` then start.
4. Do the work. Append notes when something durable should be recorded.
5. **Complete or stop only when the user explicitly asks** (e.g. "complete this
   goal", "stop working on this", "mark it done").

## Command map

### Status and inspection

```bash
goal status --full          # active goal summary + full body and note bodies
goal list                   # active + next (default)
goal list --all             # active, next, later
goal list --later
goal show <id>              # full goal file + notes for that id
goal show --title           # active goal title only (or pass <id>)
goal show <id> --id --title # line-oriented fields for scripts
```

### Start / stop (lifecycle of "what I'm working on")

```bash
goal start <id>                    # activate an existing goal (id required for agents)
goal start new "short title"       # create and start in one step
goal start new --file path.md      # create from file and start
goal stop                          # active -> Next (only if user asks)
goal stop --later                  # active -> Later (only if user asks)
```

Do not call `goal start` without an id (picker). Do not default start/stop/next
to "whatever seems right" without a clear user request.

### Create goals

```bash
goal new "title of the goal"              # create only (goes to Next)
goal new "title" -q                       # print only the new id
goal new --file path.md                   # body from file (first line = title)
id=$(goal new "title" -q)                 # compose ids via argv / command substitution
goal start "$id"
```

Do not pass a title that is only a reserved word like `new`. Prefer a clear
title line; put longer detail in the body via `--file` if needed.

### Notes (progress while a goal is active)

There must be an active goal. Notes attach only to that goal.

```bash
goal note "Decision: use X because Y"
goal note --file details.md
goal note "short title" -q                # print only note id
```

Use notes for: decisions, progress checkpoints, blockers, acceptance updates,
and anything a future session should not re-derive from chat alone.

### Edit goal body (prefer note; rarely rewrite)

Prefer `goal note` over editing the goal file. Notes are the right place for
progress, decisions, scope tweaks, and mid-work discoveries.

If the user changes direction mid-work, prefer starting a **new** goal (and
stopping or completing the old one only if they ask) rather than rewriting the
current goal body. Goals are cheap to create and delete, so there is little
reason to reshape an existing one once work is underway.

Use `goal edit` mainly when the agent is still forming the goal with the user
(for example a session whose purpose is to figure out what the goal should be)
and the idea is not fully formed yet. Once the goal is clear and work has
started, append notes or create a new goal instead of editing.

```bash
goal edit <id> --file path.md             # replace goal file from path (agent-safe)
```

Do not run bare `goal edit` / `goal edit <id>` without `--file` (opens editor).

### Complete / delete (destructive; user must ask)

```bash
goal complete --yes                       # complete active goal (required non-TTY)
goal delete <id> --yes                    # delete by id (required non-TTY)
```

- `complete` finishes **and deletes** the active goal. Only when the user
  clearly wants the goal marked done/complete.
- Always pass `--yes` in agent sessions so prompts never hang.
- Completing is not implied by "the code is done" or "tests pass". Ask or wait
  for an explicit complete/stop/delete request.

### Queue: next / later

```bash
goal next <id>                            # Later -> Next
goal later <id>                           # Next -> Later
```

Ids required. Only when the user wants queue changes.

## What not to do

| Don't | Do instead |
|-------|------------|
| Open TTY pickers or editors | Pass ids, titles, `--file`, `-q`, `--yes` |
| `goal start` / `next` / `later` / `delete` with no id | Always pass the goal id |
| Complete/stop because the patch is finished | Wait for explicit user instruction |
| Commit project files "to finish the goal" | Only commit when the user asks |
| Rewrite the goal body mid-work for a new direction | `goal note`, or a new goal if direction changed |
| Parallel markdown todo list for the same work | `goal new` / `start` / `note` / `list` |
| Pipe ids or body on stdin | Title args, `--file`, `id=$(goal new ... -q)` |
| Assume active goal for start/delete/next/later | Those commands do not default to active |

## Scripting notes

- Compose ids with argv or command substitution: `id=$(goal new "title" -q)`.
- Field flags on `show` are line-oriented and safe for scripts.
- Non-TTY: commands that confirm (`complete`, `delete`) require `--yes`.
- If a command errors because there is no active goal, start or create one only
  if that matches the user's request; otherwise report the error.

## Quick examples

**Session start**

```bash
goal status --full
```

**User: "start goal 104"**

```bash
goal start 104
goal status --full
```

**User: "add a goal for rewriting the README" (not start yet)**

```bash
goal new "rewrite the README" -q
# tell the user the id; do not start unless they ask
```

**User: "create and start work on fixing env vars"**

```bash
goal start new "fix environment variables"
```

**During work (user did not ask to complete)**

```bash
goal note "Chose option B for config loading; tests still pending"
# ... implement ...
# do NOT: goal complete --yes
# do NOT: git commit ...
```

**User: "complete the goal"**

```bash
goal complete --yes
```

**User: "stop for now" / "park this"**

```bash
goal stop
# or: goal stop --later
```
