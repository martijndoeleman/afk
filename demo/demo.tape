# demo.tape — the README recording. One continuous session, no clears: the whole
# thing scrolls past the way it would if you ran it yourself.
#
#   ./demo/setup-demo.sh       # first: fresh demo repo AND fresh sandbox
#   vhs demo/demo.tape         # writes demo/afk.gif

Output demo/afk.gif

Set Shell zsh
Set FontSize 20
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
Wait+Screen@900s /(fetched)/
Sleep 4s

# 4. the work queued up for the agent
Type "cat PROMPT.md"
Sleep 400ms
Enter
Sleep 4s

# 5. the loop works the list: one item per iteration, until the sentinel
Type "afk loop"
Sleep 400ms
Enter
# Unique to the loop's ending — the extract line above is already on screen by
# now, so waiting on that would match instantly.
Wait+Screen@900s /(sentinel)/
Sleep 4s
