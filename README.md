# goal

A little CLI to help you track (and stay on track) with your project's goals.

> [!WARNING]
> THIS IS VERY MUCH AN ACTIVE WORK IN PROGRESS

## What problem does this solve?

Well, two really. I wanted a place to quickly write down ideas, bugs, todos, and all that without leaving my terminal. Second, I needed a way to get _back_ into
my project after leaving for a while (because life happens) -- I'm always starting projects then I get distracted and all my energy for the project leaves my
body becaues I can't really remember the frame of mind I was in.

`goal` helps with both of these because it let's you quickly write things down:

```bash
$ goal new
```

And it uses Git under the hood, adding a little tag in your commit messages so you can see where you are/were:

```bash
$ goal status

Goal #1 - do a thing

Commits:
* 9aaf4cc add `-m` option to `goal commit`
* a6ee0c1 okay here we go
* 860aa66 something here
* 2f4502a on anther branch dude
| * 0ae89a0 (master) what are you talking about
|/
* 0deda9f do it now
* 405c614 this is empty
* 11f292b try this out
* 9ba763a this is working
* 73b1aa4 The new `goal commit --pick` works
* bc91336 this is the way
* fcdce75 holy cow
* 08800a2 Started Goal #1 - do a thing

Staged changes:
 goal_test.py | 1 +
 1 file changed, 1 insertion(+)

Unstaged changes:
 .goal_id                               | 2 +-
 13eb6502-2fb0-4f4e-8dff-f629b55e1c36/1 | 1 -
 13eb6502-2fb0-4f4e-8dff-f629b55e1c36/2 | 1 -
 13eb6502-2fb0-4f4e-8dff-f629b55e1c36/3 | 1 -
 13eb6502-2fb0-4f4e-8dff-f629b55e1c36/m | 1 -
 5 files changed, 1 insertion(+), 5 deletions(-)
```

## Recommended approaches

`goal` stays simple on purpose: one active goal, plain create / start / stop / complete / delete. When a workflow is awkward, prefer a small habit over a new concept in the tool.

### Split a goal that got too big

If you start a goal and realize it should be several pieces of work:

1. Create the new goals (`goal new ...`) for each piece.
2. Carry over anything that still matters from the original (title intent, notes, acceptance ideas) into those new goals so the spirit is not lost.
3. Finish the original with either `goal complete` (if the split is the outcome of that work) or `goal delete` (if the original id is no longer useful).

There is no parent/child goal tree. Related work is just more goals you can start one at a time.

More recommended approaches can be added here as they come up.
