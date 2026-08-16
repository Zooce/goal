<!-- goal-agent-rules:start -->
## Goal (agent rules)

When the `goal` CLI is installed and this project is initialized for goal:

1. **Session start:** run `goal status --full`. The active goal body is the
   acceptance criteria. Notes are a natural product of review.
   Only write notes in a review session.
2. **Session phase:** this session is design (form one or more independent
   buildable goals; never a wrapper that only holds the pieces), build
   (implement to the goal), or review (check the work and leave findings).
   If the user did not say which, ask once before doing goal work. Do not
   guess from whether notes exist. If they do not pick a phase, stop.
   With an active goal, starting-work language ("let's get to work") is build.
3. **Track work in goal:** prefer existing goals (`goal list`, `goal start <id>`)
   over inventing a parallel todo list.
4. **Non-interactive only:** pass explicit goal IDs; use title args, `--file`,
   `-q`/`--quiet`, and `--yes` as needed. Never rely on TTY pickers or editors.
5. **Do not complete, stop, delete, or switch goals** unless the user asks.
   Finishing the code is not the same as completing the goal.
6. **Do not run git commands that change the repo** unless the user asks
   (commit, push, reset, etc.). Goal may still record its own state commits.

For how to run each session, load the `goal` skill when available.
<!-- goal-agent-rules:end -->
