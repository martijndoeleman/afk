# demo.tape — the README recording. One continuous session, no clears: the whole
# thing scrolls past the way it would if you ran it yourself.
#
#   ./demo/setup-demo.sh       # first: fresh demo repo AND fresh sandbox
#   vhs demo/demo.tape         # writes demo/afk.gif
#   ./demo/check-recording.sh  # did the session actually run?
#
# The sandbox is built on camera, inside the `afk prompt` step — that is the
# first command that needs one, and it is what a new user sees on their first
# run. Every step here is real, so the recording takes as long as the agent does.
#
# The agent steps end on `Wait+Screen` rather than a fixed Sleep: a Sleep long
# enough to be safe would record minutes of dead air after a fast run.
#
# Careful with those markers. Wait+Screen searches the whole terminal buffer,
# which without clears holds everything printed so far — so each marker has to
# be text that cannot have appeared in an earlier step, or in the command line
# VHS types. `sentinel reached` is unique to the end of the loop; the extract
# line is not, which is why the loop does not wait on it.

Output demo/afk.gif

Set Shell bash
Set FontSize 14
Set Width 1100
Set Height 800
Set Padding 20
Set TypingSpeed 55ms
Set Framerate 12

# Only the shell setup is hidden — it would otherwise put a $HOME on screen.
Hide
Type 'export PATH="$HOME/.local/bin:$PATH"'
Enter
Type 'export PS1="\[\033[1;36m\]demo\[\033[0m\] $ "'
Enter
Type "cd /tmp/afk-demo"
Enter
Type "clear && printf '\033[3J'"
Enter
Sleep 2s
Show

# 1. freeze this repository's settings. MAX_ITERATIONS comes from the
#    environment, so `init` writes that one uncommented; the rest stay defaults.
Sleep 1s
Type "MAX_ITERATIONS=3 afk init"
Sleep 400ms
Enter
Sleep 2s

# 2. every effective setting, and where each one came from
Type "afk config"
Sleep 400ms
Enter
Sleep 2s

# 3. one ad-hoc run. This is the first command that needs a sandbox, so the
#    sandbox gets built here, on camera.
Type 'afk prompt "say hello"'
Sleep 400ms
Enter
# extract() prints this last, whether the fetch worked or not
Wait+Screen@900s /(review with: git log|could not|not clone mode)/
Sleep 4s

# 4. the work queued up for the agent
Type "cat PROMPT.md"
Sleep 400ms
Enter
Sleep 5s

# 5. the loop works the list: one item per iteration, until the sentinel
Type "afk loop"
Sleep 400ms
Enter
# Unique to the loop's ending — the extract line above is already on screen by
# now, so waiting on that would match instantly.
Wait+Screen@900s /(sentinel reached|no commit this iteration|exited|reported an error)/
Sleep 5s

Sleep 4s
