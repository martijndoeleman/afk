# Tasks

The task list `afk-loop.sh` works through. One item per iteration, in order.
Each item should be small enough for a fresh context window to finish in a few
turns, and should end in a commit.

Replace these with real work once you've confirmed the loop runs. They exist so
you can watch a loop end to end cheaply:

    ./afk-loop.sh smoke     # sandbox + auth + network, no model work
    ./afk-loop.sh           # the loop itself
    git log --oneline agent-loop

Expect roughly $0.15 per iteration, plus one final iteration that finds nothing
left to do and replies ALL_DONE.

- [ ] Create `demo/hello.txt` containing the single word `hello`.
- [ ] Create `demo/world.txt` containing the single word `world`.
- [ ] Create `demo/README.md` listing the files in `demo/` and what they contain.
