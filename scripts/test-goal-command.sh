#!/usr/bin/env bash

# Purpose:
#   Run a goal command in a throwaway test repo so we can verify behavior safely.
#
# What this script does:
#   1) Creates a temp workspace under .testing/
#   2) Creates isolated local + global git repos for goal
#   3) Bootstraps with `goal init` (unless testing `goal init` itself)
#   4) Runs the command(s) you pass in
#   5) Prints all output and exit codes
#   6) Cleans up with `goal deinit` (unless KEEP_TEST_DIR=1 or testing `deinit`)
#   7) Deletes temp workspace unless KEEP_TEST_DIR=1
#
# Improvements over original:
#   - Removed unused `tested_command` variable
#   - Fixed exit-code tracking (now captures *first* non-zero exit code across multiple commands)
#   - Parser now cleanly supports both single-command (`status`) *and* multi-command (`-c ...`) usage
#   - Command banner uses conditional quoting for human-readable output
#   - Robust `trap`-based cleanup (handles early exits, signals, etc.)
#   - Fixed misleading "deinit exit code" logging when deinit is skipped
#   - Better error checking (mktemp success) and clearer logging
#   - Minor cleanups for readability and maintainability
#   - Added --help / -h support
#   - Cleaned up -c parser loop (removed redundant inner if, clearer structure)
#   - `local` declaration for loop variable in print_cmd_banner
#   - Added -p flag to pipe input values to a command

# -u: error on unset variables
# -o pipefail: fail pipelines when any command fails
set -u -o pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/test-goal-command.sh <command> [args...] [-p <value> ...]
  scripts/test-goal-command.sh -c <command> [args...] [-p <value> ...] [-c <command> [args...] [-p <value> ...] ...]

Examples:
  scripts/test-goal-command.sh status
  scripts/test-goal-command.sh new "Test goal"
  scripts/test-goal-command.sh start -p 1
  scripts/test-goal-command.sh -c status -c start -p 1
  scripts/test-goal-command.sh -c start -p 1 -p 2 -c status

Notes:
  - Creates an isolated temp workspace under .testing/
  - Auto-detects `init` and `deinit` to avoid double-running them
  - Use -p to pipe input values to a command (one newline-terminated value per -p)
  - Set KEEP_TEST_DIR=1 to keep the temp directory and skip cleanup deinit
  - Set GOAL_BIN=/path/to/goal to override binary discovery
EOF
}

# Parse commands - support both single command and multiple -c flags.
# pipe_inputs is a parallel array to commands; each entry holds -p values
# (printf '%q '-encoded, or empty if none) for the corresponding command.
commands=()
pipe_inputs=()

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
  usage
  exit 0
fi

# Collect one command group from "$@" into `current` (command args) and
# `pipes` (-p values). Stops at the next -c or end of args.
# Errors if -p is not immediately followed by a value.
collect_group() {
  current=()
  pipes=()
  while [[ $# -gt 0 && "$1" != "-c" ]]; do
    if [[ "$1" == "-p" ]]; then
      shift
      if [[ $# -eq 0 || "$1" == "-c" || "$1" == "-p" ]]; then
        echo "error: -p requires a value" >&2
        exit 1
      fi
      pipes+=("$1")
    else
      current+=("$1")
    fi
    shift
  done
}

if [[ "$1" == "-c" ]]; then
  # Multiple commands mode: consume -c, collect each group until next -c or end
  while [[ $# -gt 0 ]]; do
    shift  # consume the -c
    if [[ $# -eq 0 || "$1" == "-c" ]]; then
      echo "error: -c requires a command argument" >&2
      exit 1
    fi
    collect_group "$@"
    # Advance past the args collect_group consumed (command args + "-p value" pairs)
    shift $(( ${#current[@]} + ${#pipes[@]} * 2 ))
    commands+=("$(printf '%q ' "${current[@]}")")
    pipe_inputs+=("$(printf '%q ' "${pipes[@]}")")
  done
else
  # Single command mode (most common)
  collect_group "$@"
  if [[ ${#current[@]} -eq 0 ]]; then
    echo "error: no command specified" >&2
    exit 1
  fi
  commands+=("$(printf '%q ' "${current[@]}")")
  pipe_inputs+=("$(printf '%q ' "${pipes[@]}")")
fi

# Determine special handling for init/deinit
bootstrap_init=true
cleanup_deinit=true
for cmd_str in "${commands[@]}"; do
  cmd_name="${cmd_str%% *}"
  if [[ "$cmd_name" == "init" ]]; then
    bootstrap_init=false
  fi
  if [[ "$cmd_name" == "deinit" ]]; then
    cleanup_deinit=false
  fi
done

# Resolve project root
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Find goal binary
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

if [[ ! -x "$goal_bin" ]]; then
  echo "error: goal binary is not executable: $goal_bin" >&2
  exit 1
fi

# Create test workspace
mkdir -p "$repo_root/.testing"
test_dir="$(mktemp -d "$repo_root/.testing/goal-cmd-XXXXXX")" || {
  echo "error: failed to create temporary directory" >&2
  exit 1
}
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

# Initialize isolated git repos
git -C "$base_root/.goal" init >/dev/null
git -C "$base_root/.goal" config user.email test@example.com
git -C "$base_root/.goal" config user.name test

git -C "$repo_dir" init >/dev/null
git -C "$repo_dir" config user.email test@example.com
git -C "$repo_dir" config user.name test

# Isolate goal environment
export GOAL_BASE_DIR="$base_root"
export XDG_CONFIG_HOME="$xdg_root"

# Setup cleanup trap (final rm -rf, respects KEEP_TEST_DIR)
final_cleanup() {
  if [[ "${KEEP_TEST_DIR:-0}" == "1" ]]; then
    echo
    echo "Keeping test directory: $test_dir"
  else
    rm -rf "$test_dir"
  fi
}
trap final_cleanup EXIT

# Optional bootstrap init
if [[ "$bootstrap_init" == "true" ]]; then
  echo "== goal init (bootstrap) =="
  if ! (cd "$repo_dir" && printf '\n' | "$goal_bin" init 2>&1); then
    echo "error: bootstrap init failed" >&2
    exit 1
  fi
else
  echo "== goal init (skipped) =="
  echo "Testing 'init' command; skipping auto-bootstrap."
fi

# Print a human-readable command banner.
# Uses conditional quoting: args with spaces get double-quotes, others are bare.
# (Avoids %q's shell-escape syntax like Test\ goal, which is harder to read.)
print_cmd_banner() {
  local arg
  printf '== goal'
  for arg in "$@"; do
    if [[ "$arg" =~ [[:space:]] ]]; then
      printf ' "%s"' "$arg"
    else
      printf ' %s' "$arg"
    fi
  done
  printf ' ==\n'
}

# Run all test commands
overall_rc=0
for i in "${!commands[@]}"; do
  cmd_str="${commands[$i]}"
  pipe_str="${pipe_inputs[$i]}"

  eval "cmd_args=($cmd_str)"
  cmd_name="${cmd_args[0]}"

  # Resolve pipe input for this command:
  # - If -p values were given, use them (one newline-terminated value each)
  # - Otherwise fall back to built-in defaults for init/deinit
  cmd_pipes=()
  [[ -n "$pipe_str" ]] && eval "cmd_pipes=($pipe_str)"

  echo
  print_cmd_banner "${cmd_args[@]}"
  if [[ ${#cmd_pipes[@]} -gt 0 ]]; then
    printf '   pipe input:'
    printf ' "%s"' "${cmd_pipes[@]}"
    printf '\n'
  fi

  # Run the command, piping stdin as appropriate
  if [[ ${#cmd_pipes[@]} -gt 0 ]]; then
    # Explicit -p values: pipe each as a newline-terminated line
    (set +o pipefail; cd "$repo_dir" && printf '%s\n' "${cmd_pipes[@]}" | "$goal_bin" "${cmd_args[@]}" 2>&1)
    rc=$?
  elif [[ "$cmd_name" == "init" ]]; then
    # Default: accept the project name prompt with a blank line
    (cd "$repo_dir" && printf '\n' | "$goal_bin" "${cmd_args[@]}" 2>&1)
    rc=$?
  elif [[ "$cmd_name" == "deinit" ]]; then
    # Default: confirm all prompts with "y"
    (set +o pipefail; cd "$repo_dir" && yes y | "$goal_bin" "${cmd_args[@]}" 2>&1)
    rc=$?
  else
    (cd "$repo_dir" && "$goal_bin" "${cmd_args[@]}" 2>&1)
    rc=$?
  fi

  echo
  echo "command exit code: $rc"

  # Track first non-zero exit code (continue running remaining commands regardless)
  if [[ $rc -ne 0 && $overall_rc -eq 0 ]]; then
    overall_rc=$rc
  fi
done

# Cleanup deinit (if appropriate).
# Note: KEEP_TEST_DIR=1 suppresses deinit in addition to skipping the rm -rf.
# This is intentional — if you're keeping the dir to inspect state, running
# deinit would destroy that state before you get to look at it.
if [[ "$cleanup_deinit" == "true" && "${KEEP_TEST_DIR:-0}" != "1" ]]; then
  echo
  echo "== goal deinit (cleanup) =="
  (set +o pipefail; cd "$repo_dir" && yes y | "$goal_bin" deinit 2>&1)
  deinit_rc=$?
  echo
  echo "deinit exit code: $deinit_rc"
else
  echo
  echo "== goal deinit (skipped) =="
  if [[ "${KEEP_TEST_DIR:-0}" == "1" ]]; then
    echo "KEEP_TEST_DIR=1 is set; skipping deinit to preserve test repo state."
  else
    echo "Testing 'deinit' command; skipping auto-cleanup deinit."
  fi
  deinit_rc=0
fi

# Final exit: prioritize test command failures over cleanup
[[ $overall_rc -eq 0 ]] || exit $overall_rc
exit $deinit_rc
