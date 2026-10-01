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

## Install

Linux and macOS, x86_64 and aarch64, from a [GitHub Release](https://github.com/Zooce/goal/releases).

```sh
curl -fsSL https://raw.githubusercontent.com/Zooce/goal/master/install.sh | sh
```

The script downloads the binary, checks it against `SHA256SUMS`, and
copies it to `~/.local/bin`. A different directory:

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

### Download

Each release has `SHA256SUMS` and one file per machine:

- `goal-linux-x86_64`
- `goal-linux-aarch64`
- `goal-macos-x86_64`
- `goal-macos-aarch64`

Tag `v1.0`, Linux x86_64 file `goal-linux-x86_64`. Pick the file for your machine.

```sh
set -eu
version=1.0
asset=goal-linux-x86_64
mkdir -p ~/.local/bin
curl -fsSL -o SHA256SUMS \
  "https://github.com/Zooce/goal/releases/download/v${version}/SHA256SUMS"
curl -fsSL -o "$asset" \
  "https://github.com/Zooce/goal/releases/download/v${version}/${asset}"
grep " ${asset}$" SHA256SUMS | sha256sum -c -
cp "$asset" ~/.local/bin/goal
chmod 755 ~/.local/bin/goal
~/.local/bin/goal --version
```

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

Install the goal skill with the Skills CLI:

```bash
npx skills add Zooce/goal
npx skills add Zooce/goal@goal
goal status --full         # active goal body and notes
```

## Build

Requires [Zig 0.16](https://ziglang.org/download/).

```bash
zig build
```

The binary is `zig-out/bin/goal`. `goal --version` prints `major.minor`
(zon `1.0.0` prints `goal 1.0`).

## Releases

Pushing a git tag `v<major>.<minor>` (zon `1.0.0` is tag `v1.0`)
publishes a GitHub Release with Linux and macOS binaries (x86_64 and
aarch64) and SHA256 checksums. The Linux binaries are musl builds, so
one file runs on most Linux systems. See [Install](#install) to download
it.

How to cut a release is in [CONTRIBUTING.md](CONTRIBUTING.md).

## More

```bash
goal help
goal help start
```

Per-command flags live there. Configuration: `goal help config`
(`base-dir`, `editor`, `old-after`; env `GOAL_BASE_DIR`, `GOAL_EDITOR`, `GOAL_OLD_AFTER`).
