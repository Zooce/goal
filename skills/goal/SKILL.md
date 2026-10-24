---
name: goal
description: >
  How to run the goal CLI. Maps phrases such as "create a goal for ..."
  and "what's next?" to commands, and suggests `goal init` when this
  project is not initialized. Use when the user mentions goal, asks
  what's next, or asks to list, show, search, create, edit, start,
  stop, queue, note, complete, close, or delete a goal.
---

# Goal

`goal` stores goals on disk: one active goal, a Next queue, and Later. `goal help` and `goal help <command>` print the full flag list.

This skill is installed, so the goal CLI is installed and the user wants to use it.

## Not initialized

This project is not initialized when `.goal/project_id` is missing. Goal commands then fail with `There's no project_id file. Run goal init.` Suggest `goal init` and wait for a yes. `goal init` creates the project store. Then run the command they asked for.

## Phrases

Run the command that matches what they asked. The sections below own flags and command behavior. The title is the rest of their request. When they also give a body, use `--file`.

| They say | Command |
| --- | --- |
| create a goal for ..., new goal ..., add a goal ... | `goal new "<title>"` |
| start a goal for ..., create and start a goal for ... | `goal start new "<title>"` |
| start goal `<id>`, work on goal `<id>` | `goal start <id>` |
| what's next? | What's next, below |
| show goal `<id>` | `goal show <id>` |
| search goals for ... | `goal search <pattern>` |
| stop the goal, pause the goal | `goal stop` |
| stop the goal and backlog it | `goal stop --later` |
| next goal `<id>`, queue goal `<id>` | `goal next <id>` |
| later goal `<id>`, backlog goal `<id>` | `goal later <id>` |
| note on the goal ..., add a goal note ... | `goal note "..."` |
| edit the goal, change the goal | `goal edit <id> --file <path>` |
| complete the goal, close the goal, delete the goal, mark the goal done | `goal close --yes` |
| close goal `<id>`, delete goal `<id>` | `goal close <id> --yes` |

## What's next

When the user asks what's next:

1. Run `goal list`.
2. If a goal is active, run `goal status --full` and continue that goal. The body and notes are the work.
3. If no goal is active, ask which Next goal to start. Later is the backlog.

When they choose an id, run `goal start <id>`, then `goal status --full`, and continue that goal.

## When the work is finished

When the work in a goal is finished, tell the user that goal is done. Include the goal ID. Say so in the same turn the work finishes, so they do not have to ask. Close the goal only when they ask.

## Non-interactive

Pass ids and content as arguments (`id=$(goal new "title" -q)`, then `goal start "$id"`). An agent is not a TTY.

- `start`, `next`, and `later` require a goal ID.
- `show`, `edit`, `note`, and `close` use the active goal when the id is omitted.
- `close` needs `--yes`. `close --old` takes no goal ID.
- `new` and `note` need a title argument or `--file`. `edit` needs `--file`. Without those, the command opens an editor on a TTY and errors otherwise.

## Read

```bash
goal list                         # Active, Next, Later
goal list --next                  # Next only; --active, --later, and --old combine
goal status                       # active goal tag and note titles
goal status --full                # active goal file and note bodies
goal show <id>                    # goal file and notes; also finds deleted goals
goal show --title                 # one field; also --id, --tag, --path, --category
goal search <pattern>             # regex over Active, Next, and Later; needs rg
goal search <pattern> --all       # include deleted goals
```

`goal list` prints sections named `Active Goals`, `Next Goals`, and `Goals for Later`. A goal line is `  <id>. <title>`, plus ` (<N> days)` when the goal is older than old-after (default 60d). An empty section is `  (none)`.

`goal list` rejects `--all`. `goal search --all` is the flag that includes deleted goals. Search with no matches exits 0. `goal status` with no active goal exits 0.

`goal list --old` prints only goals past old-after. It fails when old-after is 0d.

## Create and edit

```bash
goal new "title"                  # prints "Goal #<id> - <title>"
goal new "title" -q               # prints only the id
goal new --file path.md           # first line is the title; the rest is the body
goal start new "title"            # create and make it the active goal
goal start new --file path.md
goal edit <id> --file path.md     # replace that goal file
```

A title cannot be a command name (`goal new "new"` is invalid). A title argument and `--file` cannot be combined.

`goal new` writes Later and leaves the active goal unchanged.

## Active goal

```bash
goal start <id>
goal stop                         # active goal becomes first in Next
goal stop --later                 # active goal moves to Later
```

`goal start`, including `goal start new`, errors when a goal is already active on this branch: `Goal #<id> is already active on this branch.`

## Queue

```bash
goal next <id>                    # Later -> Next, or move a Next goal to the front
goal next <id> <id>               # first id ends up first
goal later <id>                   # Next -> Later
```

`goal next` and `goal later` move Next and Later goals. Move the active goal with `goal stop` or `goal stop --later`.

## Notes

The first line of a note is the title. The rest is the body. With no id, the note is attached to the active goal, which errors when none is active. An id attaches the note to that goal and leaves the active goal unchanged.

```bash
goal note "Title line"
goal note <id> --file findings.md
goal note "Title" -q              # prints only the new note id
```

`goal note 5` writes a note titled "5" on the active goal. Pass the id and the text, or the id and `--file`, to attach a note to goal 5.

## Close

```bash
goal close --yes                  # active goal -> deleted
goal close <id> --yes             # that goal -> deleted; active goal unchanged
goal close <id> <id> --yes        # each of those goals
goal close --old --yes            # old Next and Later goals
```

`goal close` moves the goal file to deleted. It does not activate another goal. With no id, it closes the active goal and errors when none is active. An id closes that goal, including the active goal on this branch. A goal that is active on another branch cannot be closed.

`goal close --old` skips the active goal. It fails when old-after is 0d, or when no Next or Later goal is old enough.
