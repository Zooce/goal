# AGENTS.md

Guidelines for agentic coding agents working on this Zig project.

## Plan and Build Agents

- Never commit any changes (or run any command that might commit changes) to the `master` branch
- Never test manually. We must create/run tests to verify changes.
- Always create your own test project under the .agents/ directory to experiment in
    - run `git init && goal init` in your test project to tes your changes in
- Always create your own branch when making changes to the main project

## Code Style Guidelines

Follow the official Zig style guide with one modification: function parameters use underscore suffix (e.g., `param_name_`).
