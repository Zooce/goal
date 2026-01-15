# AGENTS.md

Guidelines for agentic coding agents working on this Zig project.

## Plan and Build Agents

- Never commit any changes (or run any command that might commit changes) to the `master` branch
- Always create your own branch when making changes to the main project
- Always create your own test project under the .agents/ directory to experiment/test in
    - run `git init` and `GOAL_BASE_DIR=/tmp/.goal goal init` in your test project to test your changes in

## Code Style Guidelines

Follow the official Zig style guide with one modification: function parameters use underscore suffix (e.g., `param_name_`).
