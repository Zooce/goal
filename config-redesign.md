# `goal config` Command Redesign

This document captures the design decisions reached through iterative discussion for the new `goal config` command.

## Goals and Philosophy

- Make the command surface more explicit and discoverable using subcommands (`list`, `get`, `set`, `unset`, `defaults`).
- Clearly expose the configuration layering: `env var > project config > global config > defaults`.
- Support distinct views:
  - Effective/merged configuration (what the program actually uses).
  - Strict global config file contents only (no overrides).
  - Pure built-in defaults.
- Treat `config` subcommands as first-class commands (each in their own file, with `main`/`parseArgs`/`run`).
- Prioritize clean separation over backward compatibility.
- Keep writes surgical (only touch the key being changed) instead of snapshotting the merged state.
- Favor scripting-friendly behaviors where reasonable (e.g., `get` on missing key prints nothing and exits 0).

## Command Surface

### Subcommands

- `list`
- `get`
- `set`
- `unset`
- `defaults`

### Bare `goal config`

`goal config` (with no subcommand) shows the config-specific help menu, listing the available subcommands and basic usage. Each subcommand will have its own help text.

### Backward Compatibility

**None.** The previous flat syntax (`goal config <key>`, `goal config <key> <value>`, `goal config --list`, `-l`, etc.) will not be supported. This is a deliberate redesign.

## Subcommand Details

### `goal config list`

- `goal config list` — Shows the **effective** configuration after all layers (environment variables > project `.goal/config` > global config file > built-in defaults).
- `goal config list --global` — Shows **only** the contents of the global config file (strict file contents; no project overrides, no environment variables, no defaults injected).
- Does **not** accept a key as an argument. Use `get` for single-key retrieval.
- Output: Keys and values, preceded by a description line explaining the view being shown.

### `goal config get <key>`

- `goal config get <key>` — Prints the raw value for the key from the effective (merged) configuration.
- `goal config get <key> --global` — Prints the raw value from the global config file only.
- If the key has no explicit value in the requested scope: prints nothing and exits 0 (script-friendly).
- Output when present: just the raw value (no `key = ` prefix).

### `goal config set <key> <value>`

- `goal config set <key> <value>` — Sets the key, writing to the **project** config file by default.
- `goal config set <key> <value> --global` — Writes to the global config file.
- **Surgical writes only**: Only the specified key is modified in the target file. The rest of the file is left untouched. No snapshotting of the current effective config.
- Silent on success (no output, exit 0).

### `goal config unset <key>`

- `goal config unset <key>` — Removes any explicit value for the key in the target scope (so higher layers or defaults will apply).
- Supports `--global`.
- Idempotent: If the key is already absent in the target scope, it is a silent success (exit 0). The desired state is already achieved.

### `goal config defaults`

- Shows only the built-in default values that `goal` knows about for all config keys.
- No flags supported (in particular, no `--global`).
- Intended for triage/debugging ("what would goal use if nothing was configured?").
- Output: Keys and values, preceded by a description line.

## `--global` Flag

- Supported on `list`, `get`, `set`, and `unset`.
- Controls the target scope (global config file vs. the default effective/project behavior).
- Each subcommand parses and handles `--global` itself (no central pre-processing in the dispatcher).

Dropped ideas:
- `--default` flag (removed due to added complexity around scoping and fallbacks).

## Output Formatting

- **List-style commands** (`list`, `list --global`, `defaults`): Use a "keys and values" format. A leading description line states what view/layer is being shown (e.g., effective merged, global-only, or built-in defaults).
- `get`: Raw value only (when present).
- Writes (`set`/`unset`): Silent on success.

Description line examples (directionally agreed):
- Effective list: something like "Effective configuration (env vars > project config > global config > defaults):"
- `--global` list: something like "Global configuration (from the global config file only):"
- `defaults`: something like "Built-in default values:"

## `project-name`

- Removed entirely from `goal config`.
- Will move to `goal init`. Re-running `goal init` in an already-initialized project should allow updating the project name (and other reasonable re-initialization actions in the future).

## Architectural Changes

### Dispatcher

- `src/commands/config.zig` becomes a thin dispatcher (modeled after how `main.zig` dispatches to top-level commands).
- It looks at the first argument after `config` and delegates to the appropriate subcommand module.
- Bare `config` (or unknown subcommand) leads to config-specific help.
- No shared pre-parsing of flags (such as `--global`) at the dispatcher level.

### Subcommand Modules

New files:
- `src/commands/config/list.zig`
- `src/commands/config/get.zig`
- `src/commands/config/set.zig`
- `src/commands/config/unset.zig`
- `src/commands/config/defaults.zig`

Each subcommand module will be structured like other commands (`main`, `parseArgs`, `run`).

### Config Handling

- `Config.zig` will focus on loading the **effective** (merged) runtime configuration for use by the rest of the program (other commands, `Directories`, etc.).
- The new config subcommands will handle loading, parsing, and writing config files + environment variables **directly**, rather than primarily through the existing `Config` struct.
- This supports the different required views (effective, strict global-only, pure defaults) and surgical writes cleanly.

### Shared Utilities (Future)

- A common file `src/config_utils.zig` is planned to hold shared config-related utilities (path resolution, file parsing, surgical write helpers, key definitions, etc.).
- The user intends to implement the individual subcommands first and extract common logic into `config_utils.zig` as overlap emerges, rather than designing the shared module up front.

### Config Keys

The main keys remain:
- `base-dir`
- `editor`
- `commit`

(`project-name` is leaving the config command.)

## Non-Goals / Dropped

- `--default` flag on list/get/set.
- Backward compatibility with the old flat interface.
- `list` accepting a key argument (use `get` instead).
- Complex flag ordering gymnastics from the old parser (subcommand style makes intent clearer).

## Open / Future Considerations (Not Yet Decided in Detail)

- Exact final wording of description lines and precise output formatting details.
- Exact contents and API of `config_utils.zig` (to be discovered during implementation).
- Detailed error messages and validation behavior (unknown keys, invalid boolean values for `commit`, missing files, etc.).
- Where built-in default values are defined and how the `defaults` subcommand sources them.
- Help text updates in `src/commands/help.zig`.
- Test strategy (following existing patterns with `TestEnv` and programmatic command invocation).

## Summary of Layering Views

| Command                  | View Provided                     | Includes Env? | Includes Project? | Includes Global? | Includes Defaults? |
|--------------------------|-----------------------------------|---------------|-------------------|------------------|--------------------|
| `list`                   | Effective (merged)                | Yes           | Yes               | Yes              | Yes                |
| `list --global`          | Strict global file only           | No            | No                | Yes              | No                 |
| `get` / `get --global`   | Single key from chosen scope      | (per scope)   | (per scope)       | (per scope)      | (per scope)        |
| `defaults`               | Built-in defaults only            | No            | No                | No               | Yes (only)         |

This structure makes the layering explicit and queryable.

---

*Document created from design iteration in April 2026.*