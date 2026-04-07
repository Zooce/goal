# Plan: Add Project Name

## Goal

Add a `project_name` field to the per-project `m` metadata file (`~/.goal/<goal_id>/m`). It is set during `goal init` with a prompt (defaulting to the repo name), auto-migrated for existing projects on load, and editable via `goal config project-name`.

## Done When

Running `goal init` prompts for a project name (default: repo name) and stores it in the `m` file. Existing projects auto-migrate their `m` file on first load by inferring the name from the current repo. Running `goal config project-name` prints the current value, and `goal config project-name "new name"` updates it.

## Out of Scope

- Displaying the project name in `goal list`, `goal status`, or any other command.
- Any changes to how goals are displayed or organized in the terminal.

## Deferred

- Showing the project name in `goal list` or `goal status` output.
- Project name validation (e.g., disallowing empty or duplicate names).

## Tasks

> Work through tasks in order. Do not begin a task until the previous task's
> Checklist is fully checked off.
>
> Every task must name specific files, functions, identifiers, or commands.
> If a task can be executed without reading the code, it's specific enough.
> If not, rewrite it before starting.

### Task 1: Add `project_name` to `M` struct and handle migration in `Meta.zig`

Add `project_name: ?[]const u8 = null` to the `M` struct in `src/Meta.zig:17-19`. Update `Meta.load()` to detect when `project_name` is `null` (existing project), resolve the repo name via `git.projectRoot()`, extract the last path component, store it in the `M` struct, and call `store()` to persist the migration. Update `Meta.store()` to serialize the `project_name` field. Update `Meta.create()` to accept an optional `project_name` parameter and serialize it into the new `m` file.

**Verify:**
- `zig build` succeeds
- `zig build test` passes
- Manual test — existing project migration:
  1. `mkdir -p .testing/test-migrate && cd .testing/test-migrate && git init`
  2. `goal init` (use any name)
  3. Manually edit the `m` file to remove the `.project_name` line, simulating an old-format file
  4. Run `goal list` or `goal new` (any command that loads `Meta`) — it should auto-migrate and populate `project_name` from the repo name
  5. Inspect the `m` file again to confirm `.project_name = "test-migrate"` was written back
  6. `cd -` and `rm -rf .testing/test-migrate`

**Checklist:**
- [x] Implemented
- [x] Verified

### Task 2: Prompt for project name in `goal init`

In `src/commands/init.zig`, after opening directories but before calling `Meta.create()`, get the git repo root using `git.projectRoot()`. Extract the last path component as the default. Prompt the user using `cli.getAnswer()` with a message like "Project name (default: <repo_name>):". If the user enters nothing, use the default. Pass the resolved name to `Meta.create()`.

> NOTE: During manual testing you may pipe the custom name like `echo 'my-cool-project\n' | goal init`.

**Verify:**
- `zig build` succeeds
- `zig build test` passes
- Manual test — `goal init` with custom name:
  1. `mkdir -p .testing/test-init-custom && cd .testing/test-init-custom && git init`
  2. `goal init` — when prompted, type a custom name (e.g., "my-cool-project")
  3. Inspect the `m` file: `cat ~/.goal/$(cat .goal/.goal_id)/m` — confirm `.project_name = "my-cool-project"`
  4. `cd -` and `rm -rf .testing/test-init-custom`
- Manual test — `goal init` with default (accept repo name):
  1. `mkdir -p .testing/test-init-default && cd .testing/test-init-default && git init`
  2. `goal init` — when prompted, press Enter without typing anything
  3. Inspect the `m` file: `cat ~/.goal/$(cat .goal/.goal_id)/m` — confirm `.project_name = "test-init-default"`
  4. `cd -` and `rm -rf .testing/test-init-default`

**Checklist:**
- [x] Implemented
- [x] Verified

### Task 3: Add `project-name` key to `goal config`

In `src/commands/config.zig`, add a new `project_name` variant to `ConfigKey` (or handle it separately since it lives in `Meta`/`m` rather than `Config`). Update `parseArgs()` to recognize `project-name` as a valid key. Update `run()` to:
- On `goal config project-name`: load `Meta`, print the current `project_name`
- On `goal config project-name "new name"`: load `Meta`, update `project_name`, call `Meta.store()`

This requires loading `Meta` (via `Meta.load()`) instead of `Config` for this key, since the data lives in the `m` file.

**Verify:**
- `zig build` succeeds
- `zig build test` passes
- Manual test — read project name:
  1. `mkdir -p .testing/test-config-read && cd .testing/test-config-read && git init`
  2. `goal init` (accept default name)
  3. `goal config project-name` — output should show the current project name
  4. `cd -` and `rm -rf .testing/test-config-read`
- Manual test — update project name:
  1. `mkdir -p .testing/test-config-update && cd .testing/test-config-update && git init`
  2. `goal init` (accept default name)
  3. `goal config project-name "renamed-project"` — should confirm the update
  4. `goal config project-name` — output should show "renamed-project"
  5. Inspect the `m` file: `cat ~/.goal/$(cat .goal/.goal_id)/m` — confirm `.project_name = "renamed-project"`
  6. `cd -` and `rm -rf .testing/test-config-update`

**Checklist:**
- [ ] Implemented
- [ ] Verified
