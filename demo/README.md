# Recording the README demo

How to record `demo/afk.gif` yourself, and what to change when you want it to
show something else.

## Once

```bash
brew install vhs        # pulls ttyd and ffmpeg with it
```

## Every time

```bash
./demo/setup-demo.sh        # fresh demo repo + fresh sandbox
vhs demo/demo.tape          # records; takes as long as the agent takes
./demo/check-recording.sh   # did the session actually run? exits non-zero if not
open demo/afk.gif           # then watch it
```

`setup-demo.sh` is not optional. It destroys **and** rebuilds two things: the
directory `/tmp/afk-demo` and the `afk-demo` sandbox. The sandbox keeps its own
clone, so a leftover one still has `PROMPT.md`'s boxes ticked and the agent
answers `ALL_DONE` on iteration 1 — a correct-looking recording of nothing.

Run `check-recording.sh` before watching anything. VHS types commands at a
terminal; it never checks that they ran. The script reads side effects instead
(`.afkrc` written, `iter-3.json` present, commits on `afk-agent`), which is the
only reliable way to tell a good take from a broken one.

## What the tape records

Five steps, all real, in `demo/demo.tape`:

| Step | Command | Ends when |
|---|---|---|
| 1 | `MAX_ITERATIONS=3 afk init` | fixed `Sleep` |
| 2 | `afk config` | fixed `Sleep` |
| 3 | `afk prompt "say hello"` | `Wait+Screen` on the extract line |
| 4 | `cat PROMPT.md` | fixed `Sleep` |
| 5 | `afk loop` | `Wait+Screen` on `sentinel reached` |

Before step 1, hidden from the recording: set `PATH` and `PS1`, `cd` to the demo
repo, and run `afk smoke` to build the sandbox. Sandbox creation is a one-off
cost a viewer pays once; on camera it would be the first minute of the GIF.

## Changing it

**Different commands.** Edit `demo/demo.tape`. Anything that runs the agent
should end on `Wait+Screen /marker/` rather than a `Sleep`: a Sleep long enough
to be safe records minutes of dead air after a fast run, and at 15fps that is
thousands of wasted frames.

**Different tasks.** Edit the `PROMPT.md` heredoc in `demo/setup-demo.sh`. Keep
it short — the whole list has to fit the recording area — and keep the "reply in
a single short line" instruction, or a chatty agent scrolls the interesting part
off screen. `hello.sh` in the same script is what the agent edits; give it fewer
or more missing features to make the loop shorter or longer.

**Size and shape.** In the tape's `Set` block: `Width`/`Height` (currently
1100x640, sized so the loop's three iterations fit without scrolling),
`FontSize`, `Framerate` (15 — drop to 10 if the GIF gets heavy), `TypingSpeed`.
The current recording is ~330 KB for ~86 seconds.

**Update the README** if you change what the steps are — the prose under
"What it looks like" describes them one by one.

## Keeping yourself out of it

The GIF is sanitized by construction, not by editing frames afterwards:

- **Recorded in `/tmp/afk-demo`**, so afk's first line of output reads
  `>> repository: /private/tmp/afk-demo` instead of `/Users/<you>/...`.
- **`PS1` set by hand** in the hidden block. A login shell's prompt carries a
  username and a hostname.
- **A repo-local git identity** (`dev <dev@example.com>`), set by
  `setup-demo.sh`, so no commit shows your name.

The one thing none of this controls is what the agent writes back. Read the
final frames before publishing.

## Two traps that each cost a take

**`Wait+Screen` matches the command you typed, not just its output.** Waiting on
`/WARMED/` after typing `echo WARMED` matches the instant the text is typed. VHS
then races ahead and types the next command into a terminal that is still busy,
where `sbx` swallows it on stdin — so later steps silently never run. Split the
marker in the tape source (`printf 'WARM''ED\n'`) so the typed line does not
contain it.

**`clear` does not erase scrollback.** `Wait+Screen` searches the whole buffer,
including text `clear` only scrolled away, so a marker left over from an earlier
step matches immediately. The transitions use `clear && printf '\033[3J'`, and
run hidden — which also looks better than watching `clear` get typed.

Both failures produce a plausible-looking GIF. Hence `check-recording.sh`.
