#!/usr/bin/env bash

# Purpose:
#   Run a goal command in a throwaway test repo so we can verify behavior safely.
#
# What this script does:
#   1) Creates a temp workspace under .testing/
#   2) Creates isolated local + global git repos for goal
#   3) Bootstraps with `goal init` (unless you are testing `goal init` itself)
#   4) Runs the command you pass in
#   5) Prints all output and exit codes
#   6) Cleans up with `goal deinit` (unless KEEP_TEST_DIR=1 or you are testing `goal deinit`)
#   7) Deletes temp workspace unless KEEP_TEST_DIR=1

# -u: error on unset variables (helps catch typos)
# -o pipefail: fail pipelines when any command fails
set -u -o pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/test-goal-command.sh <goal-command> [args...]

Examples:
  scripts/test-goal-command.sh status
  scripts/test-goal-command.sh new "Test goal"

Notes:
  - Creates an isolated temp workspace under .testing/
  - Auto-detects `init` and `deinit` test commands to avoid double-running them
  - Runs your command and prints output
  - Runs goal deinit for cleanup (unless KEEP_TEST_DIR=1 or command is `deinit`)
  - Set KEEP_TEST_DIR=1 to keep the temp directory and skip cleanup deinit
  - Set GOAL_BIN=/path/to/goal to override binary discovery
EOF
}

# Require at least one argument (the goal command to run).
if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

# Keep all passed args together so quoted values remain intact.
cmd_args=("$@")
tested_command="${cmd_args[0]}"

# Special handling for commands that this script normally runs itself.
# - testing `init`: don't do bootstrap init first
# - testing `deinit`: don't do cleanup deinit afterwards
bootstrap_init=true
cleanup_deinit=true
if [[ "$tested_command" == "init" ]]; then
  bootstrap_init=false
fi
if [[ "$tested_command" == "deinit" ]]; then
  cleanup_deinit=false
fi

# Resolve project root based on this script's location.
# This lets the script run correctly from any current directory.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Find a goal binary in this order:
#   1) GOAL_BIN env var
#   2) local build output (zig-out/bin/goal)
#   3) system PATH
if [[ -n "${GOAL_BIN:-}" ]]; then
  goal_bin="$GOAL_BIN"
elif [[ -x "$repo_root/zig-out/bin/goal" ]]; then
  goal_bin="$repo_root/zig-out/bin/goal"
elif command -v goal >/dev/null 2>&1; then
  goal_bin="$(command -v goal)"
else
  echo "error: could not find goal binary. Build first or set GOAL_BIN." >&2
  exit 1
fi

# Sanity check that the chosen binary is executable.
if [[ ! -x "$goal_bin" ]]; then
  echo "error: goal binary is not executable: $goal_bin" >&2
  exit 1
fi

# Build the test directory tree.
# - test_dir: one unique temp directory for this run
# - repo_dir: local git project where we run commands
# - base_root/.goal: isolated global goal repo for this run only
# - xdg_root: isolated config location (so we don't touch real user config)
mkdir -p "$repo_root/.testing"
test_dir="$(mktemp -d "$repo_root/.testing/goal-cmd-XXXXXX")"
repo_dir="$test_dir/repo"
base_root="$test_dir/base-root"
xdg_root="$test_dir/xdg"

mkdir -p "$repo_dir" "$base_root/.goal" "$xdg_root"

echo "== test workspace =="
echo "$test_dir"
echo

echo "== binary =="
echo "$goal_bin"
echo

# Initialize git repo for isolated global goal data.
# goal init/deinit will commit there, so we configure author identity.
git -C "$base_root/.goal" init >/dev/null
git -C "$base_root/.goal" config user.email test@example.com
git -C "$base_root/.goal" config user.name test

# Initialize local project repo and set author identity there too.
git -C "$repo_dir" init >/dev/null
git -C "$repo_dir" config user.email test@example.com
git -C "$repo_dir" config user.name test

# Point goal at our isolated directories instead of real user paths.
# These exports apply only to this script process and its children.
# They do not affect your shell after the script exits (unless sourced).
export GOAL_BASE_DIR="$base_root"
export XDG_CONFIG_HOME="$xdg_root"

# Optional bootstrap init.
# We send one blank line to accept default project name prompt.
if [[ "$bootstrap_init" == "true" ]]; then
  echo "== goal init =="
  if ! (cd "$repo_dir" && printf '\n' | "$goal_bin" init 2>&1); then
    echo
    echo "init failed; skipping command and cleanup deinit." >&2
    [[ "${KEEP_TEST_DIR:-0}" == "1" ]] || rm -rf "$test_dir"
    exit 1
  fi
else
  echo "== goal init (skipped) =="
  echo "Detected test command 'init'; skipping auto-bootstrap init."
fi

# Show and run requested goal command.
echo
printf '== goal'
for arg in "${cmd_args[@]}"; do
  printf ' %q' "$arg"
done
printf ' ==\n'

# Capture command exit code without stopping script, so cleanup still runs.
# For interactive commands we auto-answer the common prompts:
# - init: send one blank line for project name
# - deinit: send "y" to confirmation prompts
cmd_rc=0
if [[ "$tested_command" == "init" ]]; then
  (cd "$repo_dir" && printf '\n' | "$goal_bin" "${cmd_args[@]}" 2>&1) || cmd_rc=$?
elif [[ "$tested_command" == "deinit" ]]; then
  (set +o pipefail; cd "$repo_dir" && yes y | "$goal_bin" "${cmd_args[@]}" 2>&1) || cmd_rc=$?
else
  (cd "$repo_dir" && "$goal_bin" "${cmd_args[@]}" 2>&1) || cmd_rc=$?
fi

echo
echo "command exit code: $cmd_rc"

deinit_rc=0
if [[ "${KEEP_TEST_DIR:-0}" == "1" || "$cleanup_deinit" == "false" ]]; then
  # Skip cleanup deinit if user asked to keep state, or if we are testing deinit.
  echo
  echo "== goal deinit (skipped) =="
  if [[ "${KEEP_TEST_DIR:-0}" == "1" ]]; then
    echo "KEEP_TEST_DIR=1 is set; skipping deinit to preserve test repo state."
  else
    echo "Detected test command 'deinit'; skipping auto-cleanup deinit."
  fi
  echo
  echo "deinit exit code: $deinit_rc"

  if [[ "${KEEP_TEST_DIR:-0}" == "1" ]]; then
    echo
    echo "keeping test directory: $test_dir"
  else
    rm -rf "$test_dir"
  fi
else
  # Cleanup via deinit.
  # We pipe from `yes y` so every confirmation prompt gets a "y" automatically.
  # `yes` exits with SIGPIPE once goal deinit exits, so we temporarily disable
  # pipefail to avoid treating that expected SIGPIPE as an error.
  echo
  echo "== goal deinit =="
  (set +o pipefail; cd "$repo_dir" && yes y | "$goal_bin" deinit 2>&1) || deinit_rc=$?
  echo
  echo "deinit exit code: $deinit_rc"

  # Remove temp directory after successful/attempted cleanup.
  rm -rf "$test_dir"
fi

# Final exit behavior:
# - If tested command failed, return that code (most important signal)
# - Otherwise return deinit cleanup code
if [[ $cmd_rc -ne 0 ]]; then
  exit $cmd_rc
fi
exit $deinit_rc
