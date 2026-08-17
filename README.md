# afk

afk is a tool for running coding agents while away-from-keyboard (afk).

## afk.sh

Runs a coding agent headlessly, over and over, inside one long-lived
[Docker Sandbox](https://docs.docker.com/ai/sandboxes/).

Each iteration is a **fresh process with an empty context window**. Continuity
comes from files and git history inside the sandbox's clone, not from
conversation history. The agent works one item off a task list per iteration and
commits; the loop stops when the list is done, when nothing gets committed, or
when it hits an iteration cap.

Because the sandbox is a microVM with its own filesystem and its own git clone,
the agent runs with permission prompts disabled. The VM is the safety boundary,
not the agent's judgement. Your working tree is never touched — work comes back
as a branch you review before merging.

---

## Setup

### 1. Docker Sandboxes

Install the `sbx` CLI and sign in. It needs Docker Desktop running.

```bash
brew install --cask sbx     # macOS; see the docs for Windows/Linux
sbx login
sbx diagnose                # should report all checks passing
```

Docs: [install](https://docs.docker.com/ai/sandboxes/install/) ·
[getting started](https://docs.docker.com/ai/sandboxes/get-started/)

### 2. Host dependencies

`sbx`, `jq`, `git` and `awk`. The script checks for these on startup and exits
if any are missing.

### 3. Agent credentials

The sandbox needs its own login — your host credentials are not shared into it
automatically. Log in once and you are done: the credentials persist across
restarts and are shared by every sandbox, including ones you create later for
other repos.

```bash
sbx run --name afk        # attach interactively
# then, inside the sandbox:
/login                         # Claude Code
exit
```

### 4. A task list

Create `TASKS.md` in the repo you want worked on, one checkbox per item:

```markdown
- [ ] Add a --dry-run flag to the importer.
- [ ] Backfill tests for the date parser.
```

Keep each item small enough for a fresh context window to finish in a few turns.
**Commit it** — in clone mode the sandbox clones your committed checked-out ref,
so uncommitted changes are invisible to the agent.

---

## Usage

```bash
afk smoke     # verify sandbox + auth + network + model. Do this first.
afk loop      # run the loop
afk shell     # drop into the sandbox to poke around
afk reset     # destroy the sandbox, start clean
afk           # print the command list
```

That is the installed name — see [below](#install-it-as-a-command). Without
installing, `./afk.sh loop` and friends do exactly the same thing. There is no
default subcommand: `afk` on its own prints usage rather than starting a run.

When the loop finishes it fetches the agent's branch back to your repo:

```bash
git log --oneline agent-loop
git diff main..agent-loop
```

### Install it as a command

`./install.sh` puts `afk` on your `PATH`, so you can call it by name from
any repository instead of typing a path to this one:

```bash
./install.sh                 # from this repo, once
cd ~/code/my-project
BOX=my-project afk smoke
BOX=my-project afk loop
```

It picks the first directory that is both on your `PATH` and writable
(`~/.local/bin`, `~/bin`, then `/usr/local/bin`), so it needs no `sudo`. It
installs a **symlink**, not a copy — `git pull` here updates the installed
command.

```bash
PREFIX=~/bin ./install.sh    # install somewhere specific
FORCE=1 ./install.sh         # replace a file that is already there
./install.sh uninstall       # remove the symlink
```

Re-running it is harmless. It refuses to overwrite an existing `afk` that
is not its own symlink unless you pass `FORCE=1`, and if the chosen directory is
not on your `PATH` it tells you what to add.

### Working on another repository

afk is not tied to this repo — it works on **the repository you run it from**,
and there is no setting to point it anywhere else. `cd` to the target repo:

```bash
cd ~/code/my-project
BOX=my-project afk smoke
BOX=my-project afk loop
```

Any subdirectory will do; afk resolves the repository root and works from there.
It prints the repository it resolved on every run, and refuses to start outside
a git repository. That single path is what gets mounted in the VM, what the
branch is fetched back into, and where `.afk-logs/` is written — they cannot
drift apart.

The one thing to get right is **a distinct `BOX` per repo**. Sandboxes are
looked up by name only, so a second project reusing the default `afk` silently
attaches to the *first* project's sandbox — same clone, same old task list — and
your new repo is never mounted. One name per repo, permanently.

Each target repo needs its own committed `TASKS.md` (or point `TASK_FILE`
elsewhere). Agent credentials are not per-repo — the login from
[Setup](#3-agent-credentials) carries over to every sandbox you create.

### Configuration

Every setting is an environment variable:

```bash
MAX_ITERS=3 MODEL=sonnet afk loop
```

| Variable | Default | Notes |
|---|---|---|
| `AGENT` | `claude` | `claude` or `codex` |
| `BOX` | `afk` | Sandbox name; **one per project** — reusing a name reuses that sandbox |
| `USE_CLONE` | `1` | `1` = private in-VM clone, `0` = mount your tree directly |
| `BRANCH` | `agent-loop` | Branch the agent commits to |
| `MAX_ITERS` | `10` | Hard cap. Always set one |
| `MAX_TURNS` | `40` | Agentic turns per iteration (Claude Code only) |
| `STOP_ON_NO_COMMIT` | `1` | Bail if an iteration commits nothing |
| `TASK_FILE` | `TASKS.md` | |
| `DONE_SENTINEL` | `ALL_DONE` | What the agent says when the list is finished |
| `MODEL` | agent default | Claude Code defaults to `opus` |
| `EFFORT` | `medium` | `low`/`medium`/`high`/`xhigh`/`max` |
| `PROMPT` | see script | The per-iteration instruction |
| `PROMPT_FILE` | — | Read the prompt from a host file instead |
| `LOG_DIR` | `./.afk-logs` | Per-iteration JSON |
| `CPUS` / `MEMORY` | auto | e.g. `MEMORY=8g` |

`PROMPT_FILE` contents are used **verbatim** — unlike the built-in default, it
does not interpolate `${DONE_SENTINEL}`, so spell the sentinel out in full or
the loop can only ever stop on `MAX_ITERS`. It warns you if you forget.

---

## Using codex instead of Claude Code

```bash
AGENT=codex afk smoke
```

This builds a codex sandbox rather than a Claude Code one, so it needs its own
login:

```bash
AGENT=codex sbx run --name afk
# inside the sandbox:
codex login
```

Codex differs from Claude Code in ways the profile absorbs, but which change
what you get:

- **No cost reporting.** The running total stays at `$0`. Claude Code reports
  `total_cost_usd` per iteration; codex reports nothing comparable.
- **`MAX_TURNS` has no effect.** There is no `--max-turns` equivalent, so
  `MAX_ITERS` is your only bound on a runaway iteration. Set it low at first.
- **`EFFORT` is passed as a config override** (`-c model_reasoning_effort=...`)
  rather than a flag.
- **`MODEL` has no default.** Codex uses whatever its own config says. Passing a
  name it does not recognise degrades quietly rather than erroring, so check
  `codex --help` for valid names rather than guessing.

### Adding another agent

`sbx` also ships codex, copilot, cursor, droid, gemini, kiro and opencode
templates. To add one, write a profile in the `AGENT PROFILES` block — four
functions:

```
build_agent_flags <prompt> <max_turns>   -> sets the AGENT_FLAGS array
agent_text  <raw_output>                 -> prints the final message
agent_cost  <raw_output>                 -> prints a dollar amount, or 0
agent_failed <raw_output>                -> true if the run errored
```

Everything outside that block is agent-neutral. The easiest way to write one is
to run the agent once by hand inside a sandbox and look at its actual output —
the event schemas are not reliably documented.

---

## How work gets back to you

In clone mode (the default) the agent commits to a clone **inside** the VM. The
loop streams that branch out as a git bundle over `sbx exec` and fetches it into
your repo.

If your local `$BRANCH` has diverged from the sandbox's, the fetch is refused
rather than forced. The bundle is kept in `.afk-logs/` and the loop prints the
command to fetch it under another name so you can diff the two. Nothing is ever
overwritten.

Clone mode also adds a `sandbox-<name>` git remote to your repo, but **don't
rely on it** — sbx deletes that remote when the sandbox stops and does not
restore it on restart. The bundle path works whether the sandbox is running or
stopped.

## Gotchas

- **The sandbox is persistent.** Re-running the loop reuses the same clone, so
  the agent will find work from the previous run already done and immediately
  report `ALL_DONE`. Use `afk reset` to remove the sandbox and start a clean run.
- **Commit `TASKS.md` before running.** The clone only sees committed state.
- **The repo you are standing in is the repo that gets worked on.** There is no
  way to aim afk elsewhere — `cd` first. It prints the repository it resolved
  before doing anything, so check that line if you are unsure.
- **Cost is front-loaded per iteration.** A fresh process re-reads the whole
  system prompt every time. Back-to-back iterations hit the 1-hour prompt cache
  and cost roughly a third of a cold start, so a loop with long gaps between
  iterations is significantly more expensive than one that runs straight
  through.
- **Idle iterations still cost money.** The final `ALL_DONE` iteration pays full
  overhead to say two words.
- **Workspace paths are case-sensitive inside the VM.** macOS is not, so a path
  like `/Users/me/developer/x` works on the host and fails in the VM with an
  unhelpful `failed to run sandbox container`. afk resolves the real casing with
  `/bin/pwd -P`, so this only bites if you invoke `sbx` yourself.
