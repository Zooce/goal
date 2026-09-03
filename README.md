# goal

A small CLI that keeps you on one goal at a time, and makes it easy to
write down the rest without leaving the terminal.

## Why

Two problems:

- Coming back to a project after time away. `goal status` shows what you
  were doing and any notes on it.
- Ideas, bugs, and other work show up while you are in the middle of
  something. `goal new` writes them down (they start in Later) so you can
  stay on the active goal.

You work on one active goal. Everything else is Next (ready to start) or
Later (not yet).

## Quick start

```bash
goal setup                 # once on this machine
goal init                  # once in this project
goal new "fix the picker"
goal start 1
goal status
goal note "repro: empty list"
goal complete --yes
```

On a terminal, `goal new` with no title opens your editor. The first line
is the title; the rest is the body.

## Everyday use

```bash
goal list                  # active + next
goal list --all            # include later
goal show 3                # full goal file and notes
goal start 3               # make 3 the active goal
goal stop                  # active -> next
goal stop --later          # active -> later
goal later 3               # next -> later
goal next 3                # later -> next (or move next to the front)
goal edit 3                # open the goal in your editor
goal search fix            # search goal text (needs ripgrep)
goal delete 3 --yes
```

There is no parent/child tree. If a goal is too big, create new goals for
the pieces and complete or delete the original.

## Scripts

Pass IDs and content on the command line. Do not pipe IDs or bodies on
stdin.

```bash
id=$(goal new "title" -q)
goal start "$id"
title="$(goal show --title)"
goal new --file notes.md
goal edit 3 --file notes.md
goal complete --yes
```

Non-TTY runs need an explicit ID (no picker) and `--yes` on confirm
commands (`complete`, `delete`, `deinit`).

## Agents

```bash
goal install-skill
goal status --full         # active goal body and notes
```

`install-skill` writes the goal skill for coding agents. Run it again
after upgrading `goal`.

## Build

Requires [Zig 0.16](https://ziglang.org/download/).

```bash
zig build
```

The binary is `zig-out/bin/goal`.

## More

```bash
goal help
goal help start
```

Per-command flags live there. Configuration: `goal help config`
(`base-dir`, `editor`; env `GOAL_BASE_DIR`, `GOAL_EDITOR`).
