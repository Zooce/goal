<!-- goal-agent-rules:start -->
## Goal (agent rules)

When the `goal` CLI is installed and this project is initialized for goal:

1. **Session start:** run `goal status --full` and treat it as work context.
2. **Track work in goal:** prefer existing goals (`goal list`, `goal start <id>`)
   over inventing a parallel todo list or second task system.
3. **Progress:** capture decisions and progress with `goal note` (text or
   `--file`). Prefer notes over editing the goal body mid-work.
4. **Non-interactive only:** pass explicit goal IDs; use title args, `--file`,
   `-q`/`--quiet`, and `--yes` as needed. Never rely on TTY pickers or editors.
5. **Do not complete, stop, delete, or switch goals** unless the user asks.
   Finishing the code is not the same as completing the goal.
6. **Do not run git commands that change the repo** unless the user asks
   (commit, push, reset, etc.). Goal may still record its own state commits.

For command details, load the `goal` skill / playbook when available.
<!-- goal-agent-rules:end -->
