# goal

A CLI for tracking local goals, tasks, and ideas. It is not Jira, and it
is not shared with a team. Use it to break the work you need to do into
smaller changes that are easy to track.

You work on one active goal. Everything else is Next (ready to start) or
Later (not yet).

## Why

Two problems:

- Coming back to a project after time away. `goal status` shows what you
  were doing and any notes on it.
- Ideas, bugs, and other work show up while you are in the middle of
  something. `goal new` writes them down (they start in Later) so you can
  stay on the active goal.

## Install

Linux and macOS, x86_64 and aarch64. No Windows builds.

### mise

```sh
mise use -g github:Zooce/goal
```

A specific release. Drop the leading `v` from the tag (`1.0`):

```sh
mise use -g github:Zooce/goal@1.0
```

### install.sh

```sh
curl -fsSL https://raw.githubusercontent.com/Zooce/goal/master/install.sh | sh
```

The script downloads the archive, checks it against `SHA256SUMS`, and
copies `bin/goal` to `~/.local/bin`. A different directory:

```sh
curl -fsSL https://raw.githubusercontent.com/Zooce/goal/master/install.sh | GOAL_BIN="$HOME/bin" sh
```

A specific release:

```sh
curl -fsSL https://raw.githubusercontent.com/Zooce/goal/master/install.sh | GOAL_VERSION=v1.0 sh
```

If `~/.local/bin` is not on `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Then:

```sh
npx skills add Zooce/goal -g
```

### From source

Requires [Zig 0.17](https://ziglang.org/download/).

```bash
zig build
```

The binary is `zig-out/bin/goal`. `goal --version` prints `major.minor`
(zon `1.0.0` prints `goal 1.0`).

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
goal list                  # active, next, and later
goal show 3                # full goal file and notes
goal start 3               # make 3 the active goal
goal stop                  # active -> next
goal stop --later          # active -> later
goal later 3               # next -> later
goal next 3                # later -> next (or move next to the front)
goal edit 3                # open the goal in your editor
goal search fix            # search goal text (needs ripgrep)
goal complete --yes        # active goal
goal complete 3 --yes      # a Next or Later goal
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
goal complete "$id" --yes
```

Non-TTY runs need `--yes` on confirm commands (`complete`, `delete`,
`deinit`). Commands that pick a goal need an explicit ID (no picker).

## Agents

The goal skill documents the CLI and maps phrases such as "create a goal
for ..." to commands. When you ask "what's next?", the agent continues
the active goal, or asks which Next goal to start. If this project
is not initialized, the agent suggests `goal init`.

Install it with the Skills CLI:

```bash
npx skills add Zooce/goal
npx skills add Zooce/goal@goal
```

`goal status --full` prints the active goal body and notes.

## Releases

Pushing a git tag `v<major>.<minor>` (zon `1.0.0` is tag `v1.0`)
publishes a GitHub Release with Linux and macOS tarballs (x86_64 and
aarch64) and SHA256 checksums. The Linux binaries are musl builds, so
one file runs on most Linux systems.

`mise use github:Zooce/goal` installs those tarballs:
`goal-linux-x86_64.tar.gz`, `goal-linux-aarch64.tar.gz`,
`goal-macos-x86_64.tar.gz`, and `goal-macos-aarch64.tar.gz`. Each
archive contains `bin/goal`.

How to cut a release is in [CONTRIBUTING.md](CONTRIBUTING.md).

## More

```bash
goal help
goal help start
```

Per-command flags live there. Configuration: `goal help config`
(`base-dir`, `editor`, `old-after`; env `GOAL_BASE_DIR`, `GOAL_EDITOR`, `GOAL_OLD_AFTER`).
