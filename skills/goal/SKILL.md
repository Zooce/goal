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
`goal list` fails because the project is not initialized, say so and
ask before running `goal init`.

## Session start

When `goal` is available and the project is initialized:

1. Run `goal list`.
2. If a goal is active, run `goal status --full`. Treat that body as the
   acceptance criteria.

## Hard rules

1. **Do not invent a second tracker.** Prefer existing goals (`goal start <id>`,
   `goal list`) over parallel todo lists.
2. **Non-interactive only.** Always pass explicit goal IDs. Use title args,
   `--file`, `-q`/`--quiet`, and `--yes` where needed. Do not pipe ids or
   bodies on stdin. Never rely on TTY pickers or opening an editor.
   `start`, `next`, `later`, and `delete` do not default to the active goal.
3. **Do not complete, stop, delete, or start a different goal unless the user
   asks.** Finishing implementation is not the same as completing the goal.
   Completing a goal does not start the next one. To switch in the same
   session, the user must request it (for example "start 118" or "start the
   next goal").
4. **Do not run git commands that change the repo unless the user asks.**
   That includes commit, add, push, reset, and checkout that discards work.
5. **Only write notes in a review session.**

"proceed" continues the remaining work on the current goal. "approved" accepts
the change in front of you. Neither completes the current goal nor starts a
different one.

## Session phase

Do not ask whether the work is design, build, or review.

### What's next

When they ask what's next, use the session-start context:

- If a goal is active, continue that goal.
- If no goal is active, ask which Upcoming goal to start. Later is the backlog.

When they ask where we are, or for status, answer from that context.

### Design, build, or review

When they name a goal, or an active goal is continued:

- They are unsure of its purpose, or they want it reshaped, broken down, or
  planned: design.
- They asked to review the work against the goal: review.
- Otherwise build. The goal body is the work.

Design and review do not implement unless they also asked.

No active goal, and they described new work they have not tied to an existing
goal: ask whether they want it tracked before creating anything. If they say
yes, that is design. If they do not, do not create a goal.

### Design

The output of this phase is one or more **buildable** goals. A goal is
buildable when it has a clearly defined problem, clearly defined input and
output, clearly defined constraints, and at least a rough idea of the solution.
The pieces are the goals. Never create a wrapper whose only purpose is to hold
them.

Do exactly one of:

1. Refine the current goal (`goal edit <id> --file`) when it is already one
   buildable piece.
2. Create independent buildable goals (`goal new` / `goal start new`) when
   the work is more than one piece. Tell the user the new ids. If an existing
   goal was split, ask what to do with the original (complete, delete, or keep).

### Build

Implement the active goal.

- Do not edit the goal body.
- If the work will not fit, stop and return to design: break the problem
  into buildable goals.
- Fix open review notes. Leave the notes in place.

### Review

Check the work against the goal. The work is usually the git history of the
current branch against its base branch (or against origin if the current
branch is `master`).

- If the work does not meet the goal, `goal note` the findings (text or `--file`).

## Command map

### Status and inspection

```bash
goal status --full          # active goal body and notes
goal list                   # active, next, and later
goal show <id>              # full goal file and notes for that id
```

### Search

```bash
goal search <pattern>
goal search <pattern> --all               # include deleted goals
```

Needs `rg` on PATH.

### Start / stop

```bash
goal start <id>                    # activate an existing goal (id required)
goal start new "short title"       # create and start in one step
goal start new --file path.md      # create from file and start
goal stop                          # active -> Next
goal stop --later                  # active -> Later
```

`goal start` fails while another goal is active on this branch, so stop that
goal before starting the id they named. Then run `goal status --full`.

### Create goals

```bash
goal new "title of the goal"              # create only (goes to Later)
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

### Notes

With no goal ID, the note attaches to the active goal (an error if there
is none). `goal note <id> ...` attaches to that goal (Active, Next, or
Later) without starting it. A single positional without `--file` is still
note text on the active goal (`goal note 5` is a note titled "5").

```bash
goal note "Missing: X does not meet the goal because Y"
goal note <id> --file findings.md
```

### Complete / delete

```bash
goal complete --yes                       # complete active goal (required non-TTY)
goal complete <id> --yes                  # complete that goal without starting it
goal delete <id> --yes                    # delete by id (required non-TTY)
```

`complete` moves the goal to deleted.

Before completing a goal, if this is a git repo, run `git status --porcelain`.
Treat any path outside `.goal/` as uncommitted project work. If there is any,
stop and ask whether to commit it first. Do not complete until they answer.
If they say yes, commit, then complete. If they say no, complete without
committing those files.

### Queue: next / later

```bash
goal next <id>                            # Later -> Next, or move a Next goal to the front
goal later <id>                           # Next -> Later
```
