# goal

## What is this?

`goal` is a CLI tool for solo developers to capture and triage ideas, bugs, and
tasks without leaving the terminal. You run a quick command, your editor opens,
you write, you save and quit, and you're back to work. Goals are organized into
three categories — **Later** (unvetted ideas), **Next** (committed but not
started), and **Active** (in progress now, one at a time) — giving you a
small, honest working set instead of one endless list.

## What problem does it solve?

The context-switch cost of capturing a thought mid-flow is high enough that most
ideas just get lost. Existing tools — Jira, kanban boards, even a markdown
file — require leaving the terminal, navigating a UI, and managing state. That
friction is fine for a team with shared tracking needs, but it's overkill for a
solo developer who just wants to write something down and get back to work.
`goal` makes capture nearly free and triage lightweight, so you actually use it.

## What this is NOT

- **Not a project management tool.** There are no boards, assignees, due dates,
  or priorities beyond the three categories. If you need those, use Basecamp or
  a similar tool.
- **Not a team tool.** Goals are yours — scoped to your machine, your workflow.
  If your team is coordinating work, a shared PM tool is the right answer.
- **Not a global task manager.** Goals are per-project, initialized with
  `goal init` in a repo. It's about what you're doing *here*, not a unified
  inbox across everything you're working on.
