---
name: goal
description: >
  Use the goal CLI for work context: session start, design / build / review
  phases, status, start/stop, create goals, break down a problem, review findings, list/show,
  complete. Use when the project uses goal, at session start/resume, when the
  user mentions goals/todos/what am I working on, or when designing, decomposing,
  building, reviewing, starting, or completing work. Prefer goal over inventing
  a parallel task list.
---

# Goal skill

`goal` tracks one piece of work at a time. Use it instead of a second todo list.

Prerequisites: `goal` is installed and the project is initialized. If
`goal status --full` fails because the project is not initialized, say so and
ask before running `goal init`.

## Session start

When `goal` is available and the project is initialized:

1. Run `goal status --full`.
2. Treat the active goal body as the acceptance criteria. Notes are a
   natural product of review.
3. Follow the hard rules below.

## Escape hatch

If you asked which phase (design, build, review) and the user does not pick
one, stop following this skill. Help normally. Do not create or start goals.

## Hard rules

1. **Do not invent a second tracker.** Prefer existing goals (`goal start <id>`,
   `goal list --all`) over parallel todo lists.
2. **Non-interactive only.** Always pass explicit goal IDs. Use title args,
   `--file`, `-q`/`--quiet`, and `--yes` where needed. Never rely on TTY pickers
   or opening an editor.
3. **Do not complete, stop, delete, or start a different goal unless the user
   asks.** Finishing implementation is not the same as completing the goal.
4. **Do not run git commands that change the repo unless the user asks.**
   That includes commit, add, push, reset, and checkout that discards work.
   `goal` itself may create its own commits when you run goal commands that
   mutate state.
5. **Only write notes in a review session.**

## Session phase

A new session does not remember which phase it is. The goal body and notes do
not tell you the phase. Do not guess from whether notes exist or how complete
the body looks.

Pick the phase in this order:

1. **The user said it.** Design: form the goal, write the acceptance criteria,
   decompose, break down, plan. Build: implement, do the work, first
   batch, address the review notes. Review: review, check against the goal,
   leave findings.
2. **Orientation only.** "What's next?", "where are we?", status. Answer from
   `goal status --full` / `goal list`. Do not pick a phase yet.
3. **No active goal, and they described new work.** Ask whether they want this
   tracked in goal before creating anything. They may only want to think the
   idea through. If they say yes, that is design: form one or more buildable
   goals before building. If they do not, exit this skill.
4. **A goal is active and they did not say the phase.** Ask once:

   What kind of work are we doing? (design, build, review)

   If they do not pick design, build, or review, exit this skill.

If they change phase mid-session (for example design, then "ok, implement it"),
suggest starting a new session for the new phase. If they want to continue
here anyway, follow the new phase. Do not write a note about the switch.

Then follow the matching playbook.

### Design

The output of this phase is one or more **buildable** goals. A goal is
buildable when it has a clearly defined problem, clearly defined input and
output, clearly defined constraints, and at least a rough idea of the solution.

- Write that in the goal body (`goal new`, `goal start new`, or
  `goal edit <id> --file`). Once a goal is buildable and build has started,
  leave the body alone.
- If the overall problem is larger than one build session, break it down:
  `goal new` for each buildable piece. Tell the user the new ids. Complete
  or delete the original only if they ask.
- Do not implement unless they also asked.
- Do not write notes. The goal body is the artifact.

### Build

Implement to the active goal: this goal's slice of the overall problem.

- Do the work described by the goal body.
- Do not edit the goal body.
- Do not write notes. If the work will not fit, design did not produce a
  buildable goal. Stop implementing and return to design: break the problem
  into buildable goals instead of journaling.
- Address NEW review notes. Leave existing notes in place. A later review
  session checks again.

### Review

Check the work against the goal. This is a new agent session on the same
active goal, not a new goal command.

The work is the change under review: usually the git history of the current
branch against its base branch (or against origin if the current branch is
`master`).

- Read the goal body, existing notes, and the work.
- If the work does not meet the goal, `goal note` the findings (text or `--file`).
- Do not implement unless they ask.
- Do not complete unless they ask. That ask will usually come after a review
  that found no remaining gaps.

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

### Start / stop

```bash
goal start <id>                    # activate an existing goal (id required)
goal start new "short title"       # create and start in one step
goal start new --file path.md      # create from file and start
goal stop                          # active -> Next (only if user asks)
goal stop --later                  # active -> Later (only if user asks)
```

Do not call `goal start` without an id (picker).

### Create goals

```bash
goal new "title of the goal"              # create only (goes to Next)
goal new "title" -q                       # print only the new id
goal new --file path.md                   # body from file (first line = title)
id=$(goal new "title" -q)                 # compose ids via argv / command substitution
goal start "$id"
```

Do not pass a title that is only a reserved word like `new`. Prefer a clear
title line; put the acceptance criteria in the body via `--file` if needed.

### Edit the goal (design)

```bash
goal edit <id> --file path.md             # replace goal file from path
```

Do not run bare `goal edit` / `goal edit <id>` without `--file` (opens editor).
Once build has started, do not reshape the body; create a new goal instead.

### Notes (review findings only)

There must be an active goal. Notes attach only to that goal.

```bash
goal note "Missing: X does not meet the goal because Y"
goal note --file findings.md
goal note "short title" -q                # print only note id
```

### Complete / delete (user must ask)

```bash
goal complete --yes                       # complete active goal (required non-TTY)
goal delete <id> --yes                    # delete by id (required non-TTY)
```

`complete` finishes and deletes the active goal. Always pass `--yes` so prompts
never hang. Completing is not implied by "the code is done" or "tests pass".

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
| Keep following this skill after they did not pick a phase | Stop; help normally |
| Guess design / build / review from notes or the body | Use what the user said, or ask once |
| Create goals when they were only thinking out loud | Ask first whether to track it in goal |
| Note progress so the next session can resume | Break the problem into smaller buildable goals, or wait for a review session |
| Edit the goal body mid-build | Leave the body; create a new goal if direction changed |
| Complete/stop because the patch is finished | Wait for explicit user instruction |
| Commit project files "to finish the goal" | Only commit when the user asks |
| Parallel markdown todo list for the same work | `goal new` / `start` / `list` |
| Pipe ids or body on stdin | Title args, `--file`, `id=$(goal new ... -q)` |
| Assume active goal for start/delete/next/later | Those commands do not default to active |

## Scripting notes

- Compose ids with argv or command substitution: `id=$(goal new "title" -q)`.
- Field flags on `show` are line-oriented and safe for scripts.
- Non-TTY: commands that confirm (`complete`, `delete`) require `--yes`.
- If a command errors because there is no active goal, start or create one only
  if that matches the user's request; otherwise report the error.
