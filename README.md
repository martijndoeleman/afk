# afk

afk runs a coding agent headlessly, inside one long-lived
[Docker Sandbox](https://docs.docker.com/ai/sandboxes/) — while you are
away-from-keyboard.

Each iteration is a **fresh process with an empty context window**. Continuity
comes from files and git history inside the sandbox's clone, not from
conversation history.

The sandbox is a microVM with its own filesystem and git clone, so the agent runs
with permission prompts disabled — the VM is the safety boundary, not the agent's
judgement. Your working tree is never touched; work comes back as a branch you
review before merging.

---

## Setup

**1. Docker Sandboxes.** Install the `sbx` CLI and sign in (needs Docker Desktop
running):

```bash
brew install --cask sbx     # macOS; see the docs for Windows/Linux
sbx login
sbx policy init balanced    # global network policy — see below
sbx diagnose                # should report all checks passing
```

Docs: [install](https://docs.docker.com/ai/sandboxes/install/) ·
[getting started](https://docs.docker.com/ai/sandboxes/get-started/)

**2. Host dependencies.** `sbx`, `jq`, `git`, `awk`. The script checks on startup
and exits if any are missing.

**3. Agent credentials.** The sandbox needs its own login; host credentials are
not shared into it. Log in once — credentials persist across restarts and are
shared by every sandbox, including ones you create later for other repos.

```bash
sbx run --name afk        # attach interactively
/login                    # inside the sandbox (Claude Code), then: exit
```

**4. A prompt file.** Create `PROMPT.md` in the repo you want worked on. This is
afk's only input, and it **is** the prompt — sent to the agent verbatim every
iteration. It says both how to work and what to work on:

```markdown
# Tasks

Do exactly ONE unchecked item below, then stop. Take them in order.
Run `npm test`, then mark the item [x] and commit it with the work.
If every item is already [x], reply with exactly: ALL_DONE

- [ ] Add a --dry-run flag to the importer.
- [ ] Backfill tests for the date parser.
```

The `PROMPT.md` in this repo is a fuller example to copy and adapt. Because the
file is used verbatim, it has to spell out `ALL_DONE` itself, or the loop
can only ever stop on `MAX_ITERS` — afk warns you if it doesn't. Keep each item
small enough for a fresh context window to finish in a few turns, and **commit
the file** — in clone mode the sandbox clones your committed checked-out ref, so
uncommitted changes are invisible to the agent.

afk re-reads the file from inside the sandbox before every iteration, so the
`[x]` marks the last iteration committed are what tell the next one what is
left.

---

## Usage

```bash
afk smoke            # verify sandbox + auth + network + model. Do this first.
afk loop             # run the loop
afk prompt "<text>"  # run the agent once on an ad-hoc prompt
afk shell            # drop into the sandbox to poke around
afk remove           # destroy the sandbox, start clean
afk                  # print the command list (no default subcommand)
```

Without installing, `./afk.sh loop` and friends do the same thing.

When the loop finishes it fetches the agent's branch back to your repo:

```bash
git log --oneline agent-loop
git diff main..agent-loop
```

### One-off prompts

`afk prompt` runs the agent **once**, on a prompt you pass in, instead of looping
over `PROMPT_FILE`. Same sandbox, same `$BRANCH`, same bundle fetch at the end, so
anything it commits comes back exactly as loop's work does:

```bash
afk prompt "Add a --dry-run flag to the importer and commit it."
afk prompt < brief.md          # multi-line prompt from a file or a pipe
MAX_TURNS=10 afk prompt "Summarise how the auth middleware works."
```

`PROMPT_FILE` and `DONE_SENTINEL` are not used, so nothing needs to be committed
first and no sentinel is required. Use it to try a task before writing it into
`PROMPT.md`, to ask a question about the code, or to clean up after a loop that
stopped early. The raw agent output lands in `.afk-logs/prompt.json`, overwritten
each run.

### Install it as a command

`./install.sh` puts `afk` on your `PATH` so you can call it by name from any
repository. It picks the first directory that is both on your `PATH` and writable
(`~/.local/bin`, `~/bin`, then `/usr/local/bin`), so it needs no `sudo`, and it
installs a **symlink** — `git pull` here updates the installed command.

```bash
./install.sh                 # from this repo, once
PREFIX=~/bin ./install.sh    # install somewhere specific
FORCE=1 ./install.sh         # replace a file that is already there
./install.sh uninstall       # remove the symlink
```

Re-running is harmless. It refuses to overwrite an existing `afk` that is not its
own symlink unless you pass `FORCE=1`, and tells you what to add to `PATH` if the
chosen directory is not on it.

### Working on another repository

afk works on **the repository you run it from** — there is no setting to point it
elsewhere, so `cd` to the target repo:

```bash
cd ~/code/my-project
BOX=my-project afk smoke
BOX=my-project afk loop
```

Any subdirectory will do; afk resolves the repository root, prints it on every
run, and refuses to start outside a git repository. That single path is what gets
mounted in the VM, what the branch is fetched back into, and where `.afk-logs/`
is written.

The one thing to get right is **a distinct `BOX` per repo**. Sandboxes are looked
up by name only, so a second project reusing the default `afk` silently attaches
to the *first* project's sandbox — same clone, same old task list — and your new
repo is never mounted.

Each target repo needs its own committed `PROMPT.md` (or set `PROMPT_FILE`). Agent
credentials carry over to every sandbox.

### Configuration

Every setting is an environment variable:

```bash
MAX_ITERS=3 MODEL=sonnet afk loop
```

| Variable | Default | Notes |
|---|---|---|
| `AGENT` | `claude` | `claude` or `codex` |
| `BOX` | `afk` | Sandbox name; **one per project** |
| `USE_CLONE` | `1` | `1` = private in-VM clone, `0` = mount your tree directly |
| `BRANCH` | `agent-loop` | Branch the agent commits to |
| `MAX_ITERS` | `10` | Hard cap. Always set one |
| `MAX_TURNS` | `40` | Agentic turns per iteration (Claude Code only) |
| `STOP_ON_NO_COMMIT` | `1` | Bail if an iteration commits nothing |
| `PROMPT_FILE` | `PROMPT.md` | The only input — it *is* the prompt |
| `DONE_SENTINEL` | `ALL_DONE` | What the agent says when the list is finished |
| `MODEL` | agent default | Claude Code defaults to `opus` |
| `EFFORT` | `medium` | `low`/`medium`/`high`/`xhigh`/`max` |
| `LOG_DIR` | `./.afk-logs` | Per-iteration JSON |
| `CPUS` / `MEMORY` | auto | e.g. `MEMORY=8g` |

There is no prompt setting. Everything you would put in one — how to test, what
to commit, when to stop — goes in `PROMPT_FILE`, next to the items it applies to.
For a prompt that is not worth a file of its own, use `afk prompt`.

---

## Network policy

All outbound TCP from a sandbox is proxied through the host and authorised
against a policy; UDP, ICMP, the host Docker daemon and sandbox-to-sandbox
traffic are blocked outright and cannot be opened up.

That policy is chosen **once**, during setup, and it is global: every sandbox afk
creates uses it. afk never sets it — `afk smoke` and `afk loop` inherit whatever
the host was initialised with.

| Policy | What it allows |
|---|---|
| `allow-all` | All outbound traffic |
| `balanced` | Typical development traffic — AI services, package registries |
| `deny-all` | Nothing outbound; you allow destinations one at a time |

**Use at least `balanced`.** `allow-all` gives an agent running with permission
prompts disabled a completely open egress path for an entire unattended run,
which is the one thing the VM boundary was supposed to buy you back. `deny-all`
is safest and a fine place to start, but nothing works until you allow the
agent's API endpoint and every registry the repo pulls from — expect `afk smoke`
to fail until you have.

`sbx policy init` is one-time; to start over, `sbx policy reset` then `init`
again. `sbx policy ls` shows what is actually in force.

### Widening and narrowing it

Deny beats allow, and rules are global unless you scope them with `--sandbox`.
Resources are hostnames, wildcard subdomains or IPs, comma-separated, with an
optional port:

```bash
sbx policy allow network "*.npmjs.org"                        # all sandboxes
sbx policy allow network --sandbox my-project internal.corp   # one sandbox only
sbx policy deny  network --sandbox my-project "*.slack.com"
sbx policy rm    network --resource api.example.com           # drop an allow rule
sbx policy ls --wide                                          # rule IDs, for --id
```

Use `--sandbox "$BOX"` for anything a single repo needs — a private registry, an
internal API — so one project's dependency does not become every project's
egress. Per-sandbox denies can only narrow egress, never widen it, so they are
safe on a host under centralised governance; `sbx policy inspect <rule>` tells
you whether a given rule is yours to remove.

You can also pin a restriction at creation time with `sbx create
--deny-network`. afk does not expose that flag, so create the sandbox yourself
first (afk reuses one that already exists under `$BOX`):

```bash
sbx create --clone --name my-project --deny-network "*.example.com" claude "$PWD"
BOX=my-project afk loop
```

Debugging: a blocked destination usually shows up as a hang or an opaque network
error inside an iteration, not as a policy message, so `sbx policy log` is the
first thing to read when an iteration fails for no visible reason.
`sbx policy check network --sandbox my-project https://api.example.com` tests a
single destination.

Docs: [security](https://docs.docker.com/ai/sandboxes/security/) ·
[defaults](https://docs.docker.com/ai/sandboxes/security/defaults/) ·
[`sbx policy`](https://docs.docker.com/reference/cli/sbx/)

---

## Using codex instead of Claude Code

```bash
AGENT=codex afk smoke
AGENT=codex sbx run --name afk    # then, inside: codex login
```

This builds a codex sandbox rather than a Claude Code one, so it needs its own
login. It also differs in ways that change what you get:

- **No cost reporting.** The running total stays at `$0`.
- **`MAX_TURNS` has no effect** — no `--max-turns` equivalent, so `MAX_ITERS` is
  your only bound on a runaway iteration. Set it low at first.
- **`EFFORT` is a config override** (`-c model_reasoning_effort=...`), not a flag.
- **`MODEL` has no default.** An unrecognised name degrades quietly rather than
  erroring, so check `codex --help` for valid names.

### Adding another agent

`sbx` also ships copilot, cursor, droid, gemini, kiro and opencode templates. To
add one, write a profile in the `AGENT PROFILES` block — four functions:

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
your repo. If your local `$BRANCH` has diverged, the fetch is refused rather than
forced: the bundle is kept in `.afk-logs/` and the loop prints the command to
fetch it under another name so you can diff the two. Nothing is ever overwritten.

Clone mode also adds a `sandbox-<name>` git remote, but **don't rely on it** —
sbx deletes it when the sandbox stops and does not restore it. The bundle path
works either way.

## Gotchas

- **The sandbox is persistent.** Re-running the loop reuses the same clone, so
  the agent finds the previous run's work already done and immediately reports
  `ALL_DONE`. Use `afk remove` for a clean run.
- **Commit `PROMPT.md` before running.** The clone only sees committed state.
- **The network policy is global, not per-repo.** See
  [Network policy](#network-policy).
- **The repo you are standing in is the repo that gets worked on.** `cd` first;
  afk prints the repository it resolved before doing anything.
- **Cost is front-loaded per iteration.** A fresh process re-reads the whole
  system prompt every time. Back-to-back iterations hit the 1-hour prompt cache
  and cost roughly a third of a cold start, so a loop with long gaps between
  iterations is significantly more expensive than one running straight through.
- **Idle iterations still cost money.** The final `ALL_DONE` iteration pays full
  overhead to say two words.
- **Workspace paths are case-sensitive inside the VM.** macOS is not, so
  `/Users/me/developer/x` works on the host and fails in the VM with an unhelpful
  `failed to run sandbox container`. afk resolves the real casing with
  `/bin/pwd -P`, so this only bites if you invoke `sbx` yourself.
