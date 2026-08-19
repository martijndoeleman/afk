# afk

afk runs a coding agent headlessly, inside one long-lived
[Docker Sandbox](https://docs.docker.com/ai/sandboxes/) — while you are
away-from-keyboard.

Each afk run is a **fresh process with an empty context window**. Continuity
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

**2. Host dependencies.** `sbx`, `jq`, `git`. The script checks on startup
and exits if any are missing.

**3. Agent credentials.** Any agent inside a sandbox needs its own login; host credentials are
not shared into it. Log in once in the sandbox — credentials persist across restarts and are
shared by every sandbox, including ones you create later for other repos.

```bash
sbx run --name afk        # attach interactively
/login                    # inside the sandbox (Claude Code), then: exit
```

**4. A prompt file.** Create `PROMPT.md` in the repo you want to work on. This is
afk's input for loops, and it is sent to the agent on every
iteration. It should say how to work, list what to work on, tell the agent how to mark things as done, 
and define criteria for when there is no work left to do (together with the done sentinel read by afk).
See [PROMPT.md](/PROMPT.md) for an example. NB: Commit this file to git prior to running `afk loop` so it gets cloned into the sandbox.

**5. Settings for a specific repository (Optional).** `afk init` creates a default `.afkrc` file when not present — 
This allows you to save different configurations (agent, sanbox name, model, etc.) between repositories.
It is recommended to commit `.afkrc` to git so `afk` configuration can be tracked and shared:

```bash
afk init      # writes .afkrc, then commit it
```

See [Repository settings](#repository-settings).

---

## Usage

```bash
afk init             # write .afkrc for this repo (do this once, per repo)
afk config           # show every effective setting and where it came from
afk smoke            # verify sandbox + auth + network + model. Do before first run.
afk loop             # run agent in loop with instructions from PROMPT_FILE
afk prompt "<text>"  # run the agent once on an ad-hoc prompt
afk shell            # drop into the sandbox shell
afk remove           # destroy the sandbox
afk                  # print the command list (no default subcommand)
```

Without installing, `./afk.sh loop` and friends do the same thing.

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
afk init            # once — pins the sandbox name and agent for this repo in .afkrc
afk smoke           # test whether sandbox + agent + model + network works
afk loop            # loop with PROMPT_FILE as input
afk prompt <text>   # send ad-hoc prompt to agent
```

### Repository settings

`afk init` writes `.afkrc` at the repository root — every setting at its default,
commented out, so the file is its own documentation. Two kinds of line come out
uncommented: `BOX`, set to this directory's name, and anything you set in the
environment for that invocation. So the way to pin a setup is to try it by hand
and then freeze it:

```bash
AGENT=codex EFFORT=high afk init
```

```sh
# .afkrc — afk settings for this repository. Written by `afk init`.
BOX=my-project
AGENT=codex
EFFORT=high
# BRANCH=afk-agent
# MAX_ITERATIONS=10
```

The thing that must differ per repository is **`BOX`**: sandboxes are looked up by name
only, so two projects sharing one name means the second silently attaches to the
*first* project's sandbox — same clone, same old prompt file — and your new repo
is never mounted. `BOX` therefore defaults to the repository's directory name.
 `afk init` writes that name into `.afkrc` where you can see and change it.

`afk init` also appends `LOG_DIR` to the repository's `.gitignore` — iteration
logs are noise, not history. It is skipped when git already ignores the directory,
when the entry is already there, or when `LOG_DIR` points outside the repository.

Commit `.afkrc` to git. It is what makes `cd ~/code/my-project && afk loop` use the right
sandbox and the right agent without being explicitly told. `afk init` refuses to overwrite
an existing file; `FORCE=1 afk init` regenerates it, keeping whatever it already
set.

`.afkrc` is **parsed, not sourced** — literal `KEY=value` lines, no expansion, no
substitution, and an unknown key is an error rather than a line that quietly does
nothing. Running `afk` in a repository must not be a way for that repository to
run shell code on your host; that is what the sandbox is for. Blank lines and
`#` comments are ignored, a trailing `# comment` after a value is stripped, and
quoting a value keeps any `#` inside it.

### Configuration

Settings come from three places, in order: **the environment**, then
**`.afkrc`**, then the built-in defaults. So a `.afkrc` pins the project and an
environment variable still overrides it for one run:

```bash
MAX_ITERATIONS=3 MODEL=sonnet afk loop
```

`afk config` prints the resolved value of every setting and which of the three it
came from — the answer to "why did it use *that* sandbox?". It touches no
sandbox.

| Variable | Default | Notes |
|---|---|---|
| `AGENT` | `claude` | `claude` or `codex` |
| `BOX` | repo directory name | Sandbox name; **one per project** |
| `USE_CLONE` | `1` | `1` = private in-VM clone, `0` = mount your tree directly |
| `BRANCH` | `afk-agent` | Branch the agent commits to |
| `MAX_ITERATIONS` | `10` | Hard cap. Always set one |
| `MAX_TURNS` | `40` | Agentic turns per iteration; `0` or `-1` = unlimited (Claude Code only) |
| `STOP_ON_NO_COMMIT` | `1` | Bail if an iteration commits nothing |
| `PROMPT_FILE` | `PROMPT.md` | The prompt file to use in `afk loop` |
| `DONE_SENTINEL` | `ALL_DONE` | What the agent says when the work is finished |
| `MODEL` | agent default | Claude Code defaults to `opus` |
| `EFFORT` | `medium` | `low`/`medium`/`high`/`xhigh`/`max` |
| `LOG_DIR` | `./.afk-logs` | Per-iteration JSON |
| `SLEEP_BETWEEN` | `0` | Seconds between iterations |
| `CPUS` / `MEMORY` | auto | e.g. `MEMORY=8g`, `CPUS=2` |

Every one of them can also go in `.afkrc`, and `afk init` lists them all.

---

## Run Invocation

Two ways to put the agent to work. Both run in the same sandbox, on the same
`$BRANCH`, and return their work the same way.

### Loop — `afk loop`

Unattended, many iterations. `PROMPT_FILE` (`PROMPT.md`) is sent as
prompt every iteration, each one a fresh process with an empty context. 
It fully relies on the `PROMPT_FILE` for instructions, done criteria,
and stops on the `ALL_DONE` sentinel, on an iteration that commits nothing,
or on `MAX_ITERATIONS`. Per-iteration output lands in `.afk-logs/iter-N.json`.

```bash
afk loop
MAX_ITERATIONS=3 afk loop
```

### Ad-hoc prompt — `afk prompt`

One run, one prompt:

```bash
afk prompt "Add a --dry-run flag to the importer and commit it."
afk prompt < brief.md          # a markdown file, or anything piped in
```
Output lands in `.afk-logs/prompt.json`. 

**Remember:** always instruct an agent to commit its work on the local branch (inside the sandbox) so work can be easily retrieved by the default extraction method.

### Getting the work back

In clone mode (the default) the agent commits to a clone **inside** the VM, and
your working tree is never touched. At the end of a `loop` or a `prompt`, afk
streams `$BRANCH` out as a git bundle over `sbx exec` and fetches it into your
repo.

If your local `$BRANCH` has diverged, the fetch is refused rather than forced, 
the bundle is kept in `.afk-logs/` and afk prints the command to fetch it under
another name. Nothing is ever overwritten.

### Take a look inside — `afk shell`

```bash
afk shell
```

An interactive bash session in the sandbox, starting the box if it is stopped.
This is where you go when a run ends badly: read the agent's branch and diffs,
run the tests it could not get passing, or check that `PROMPT.md` says what you
think it says. Nothing you do here reaches your working tree; `exit` leaves the
sandbox running, `afk remove` destroys it.

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

- **`MAX_TURNS` has no effect** — no `--max-turns` equivalent, so `MAX_ITERATIONS` is
  your only bound on a runaway iteration. Set it low at first.
- **`EFFORT` is a config override** (`-c model_reasoning_effort=...`), not a flag.
- **`MODEL` has no default.** An unrecognised name degrades quietly rather than
  erroring, so check `codex --help` for valid names.

### Adding another agent

`sbx` also ships copilot, cursor, droid, gemini, kiro and opencode templates. To
add one, write a profile in the `AGENT PROFILES` block — three functions:

```
build_agent_flags <prompt> <max_turns>   -> sets the AGENT_FLAGS array
agent_text  <raw_output>                 -> prints the final message
agent_failed <raw_output>                -> true if the run errored
```

Everything outside that block is agent-neutral. The easiest way to write one is
to run the agent once by hand inside a sandbox and look at its actual output —
the event schemas are not reliably documented.