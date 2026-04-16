... omg stop being so bad at this ...

## Testing

When verifying commands that modify project state or require an initialized goal repository, always use a test directory under `.testing/`:

1. Create a fresh test directory, then run all commands with a single `cd`:
   ```bash
   mkdir -p .testing/<test-name>
   cd .testing/<test-name> && git init && goal init && goal <command> [args...]
   ```

4. Verify the expected behavior in the test repo.

Note: Never run goal commands directly in the main `/home/zooce/Documents/goal` repository — that would initialize goal in the actual project.