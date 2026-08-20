# demo.tape — the README recording. One continuous session, no clears: the whole
# thing scrolls past the way it would if you ran it yourself.

Output demo/afk.gif

Set Shell bash
Set FontSize 20
Set Width 1300
Set Height 650
Set Padding 20
Set TypingSpeed 55ms
Set Framerate 12

Hide
Type "cd /tmp/afk-demo"
Enter
Type "clear"
Enter
Sleep 2s
Show

Sleep 1s
Type "MAX_ITERATIONS=3 afk init"
Sleep 400ms
Enter
Sleep 4s

Type "afk config"
Sleep 400ms
Enter
Sleep 4s

Type 'afk prompt "say hello"'
Sleep 400ms
Enter
Sleep 10s

Type "cat PROMPT.md"
Sleep 400ms
Enter
Sleep 4s

Type "afk loop"
Sleep 400ms
Enter
Sleep 45s
