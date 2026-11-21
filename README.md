# agent-lock

A machine-wide job queue for coding agents (Claude Code and similar) running in parallel on one Mac.

When several agents run test suites, full checks and benchmarks at the same time, they slow each other down and benchmark numbers become meaningless. `agent-lock` wraps those heavy commands: up to N shared jobs run at once, exclusive jobs run alone, and everyone else waits in a fair queue. A menu bar app shows what is running and what is waiting.

```
$ agent-lock shared -- pnpm test          # takes 1 of N slots
$ agent-lock shared --desc "redis specs" --uses docker -- pnpm vitest run packages/redis
$ agent-lock exclusive -- pnpm bench      # takes all N slots, runs alone
$ agent-lock status
running: pid=4121 shared since 14:02:11 in /Users/me/proj-a: pnpm test
next:    pid=4188 exclusive since 14:02:40 in /Users/me/proj-b: pnpm bench
queued:  pid=4203 shared since 14:02:55 in /Users/me/proj-c: pnpm check
```

## Install

```sh
brew install kvet/tap/agent-lock
brew services start agent-lock      # menu bar item, now and at login
```

It builds from source, so it needs only the Xcode Command Line Tools (`xcode-select --install`). macOS 13 or later.

### From source

```sh
swift build -c release
cp .build/release/agent-lock ~/.local/bin/    # or anywhere on your PATH
```

## Usage

```
agent-lock shared|exclusive [--desc TEXT] [--uses RES[,RES...]] [--] <cmd...>
agent-lock status [--json]
agent-lock menubar
agent-lock version
```

| Command | What it does |
|---|---|
| `shared -- <cmd>` | Waits for one free slot, runs `cmd`, frees the slot. For tests, full checks, anything container-backed. |
| `exclusive -- <cmd>` | Waits for all slots, so it runs alone. For benchmarks. |
| `status` | Who holds slots (`running:`), who is at the head of the line (`next:`) and who waits behind it (`queued:`). |
| `status --json` | `{"slots": N, "running": [...], "next": record\|null, "queued": [...]}` |
| `menubar` | Runs the menu bar app in the foreground (`brew services` runs it for you). |
| `version` | Prints the version. |

Options before the command:

| Option | Meaning |
|---|---|
| `--desc TEXT`, `-d TEXT` | What the job is for, in a few words. Shown in `status` and in the menu bar instead of the raw command. |
| `--uses RES[,RES...]`, `-u RES` | Resources the job uses, such as `docker`. Repeatable. Shown as tags. |

Both are optional and informational: they never change when a job may start. Anything after `--` (or after the first argument that isn't one of these options) is the command.

The command's stdout, stderr and stdin pass straight through. Exit codes:

| Exit code | Meaning |
|---|---|
| the command's code | the command exited normally |
| 128 + signal | the command was killed by a signal |
| 127 | the command could not be executed |
| 64 | usage error |

While waiting, `agent-lock` prints `agent-lock: waiting ...` lines to stderr, at most once a minute.

Nested calls are safe: the wrapper sets `AGENT_LOCK_HELD=1` for the command, and an `agent-lock` call that sees it runs its command directly. A script wrapped in `agent-lock` can therefore call `agent-lock` again without deadlocking.

SIGINT, SIGTERM and SIGHUP sent to the wrapper are forwarded to the command.

### Status records

`status --json` lists each job as:

| Field | Meaning |
|---|---|
| `pid` | wrapper pid (send it SIGTERM to stop the job) |
| `mode` | `"shared"` or `"exclusive"` |
| `enqueuedAt` | epoch ms when the job started waiting |
| `startedAt` | epoch ms when it got its slots; absent while waiting |
| `cwd` | working directory |
| `argv` | the command |
| `description` | `--desc` text; absent when not given |
| `uses` | `--uses` resources, e.g. `["docker"]`; absent when none |

A job started by the older Perl version of `agent-lock` shows up as a plain string with its text info.

## Configuration

| Setting | Environment variable | Config file key | Default |
|---|---|---|---|
| Slot count (N) | `AGENT_LOCK_SLOTS` | `slots` | `3` |
| State directory | `AGENT_LOCK_DIR` | `dir` | `~/.claude/state/agent-lock` |

The config file is `~/.config/agent-lock/config`, with `key=value` lines:

```
slots=4
dir=~/.cache/agent-lock
```

Environment variables take precedence over the file.

> **Every process on the machine must agree on the slot count and directory.** Agents, terminals and the menu bar app all need the same values, so prefer the config file over per-shell environment variables. Changing the slot count while jobs are running is unsupported: finish or stop running jobs first.

## Menu bar

`brew services start agent-lock` adds a status item:

- an icon only when idle, `2/3` when 2 of 3 slots are in use, `+4` when 4 jobs are waiting, and an orange lock while an exclusive job runs;
- a **Running** section and a **Queued** section (head of the line first, marked `NEXT`), each job showing its description (or command), its `--uses` tags, directory and elapsed time;
- per job: Copy Command, Copy PID, Reveal cwd in Finder, Terminate (SIGTERM to the wrapper, after confirmation);
- Open State Folder, version and Quit.

It polls the state directory every 2 seconds (every second while the menu is open). Quit stays quit until the next login or `brew services restart agent-lock`. If the app crashes, `brew services` restarts it.

## How it works

- The state directory holds `queue.lock`, `slot.0` … `slot.{N-1}`, and a `waiting.<pid>` file per waiting job.
- Every lock is a `flock(2)` lock held by the wrapper process. The kernel drops it when the wrapper exits or is killed, even with `kill -9`, so there are never stale locks to clean up.
- **Fair queue.** Each job first takes `queue.lock` exclusively, then takes its slots while at the head of the line, then releases `queue.lock`. Waiters are served one at a time, so a waiting exclusive job can't be starved by a stream of shared jobs.
- **Shared** jobs take the first free slot, retrying every 0.5 s. **Exclusive** jobs lock every slot in turn.
- Each holder writes a one-line JSON record into its lock files; readers check whether a file is locked with a non-blocking `flock` probe.
- Each waiting job holds a lock on its `waiting.<pid>` file, so `status` and the menu bar can list the whole queue. A `waiting.*` file nobody holds is left over from a killed process and is deleted by the next reader. Queue order is by enqueue time and is approximate, since the kernel doesn't promise FIFO wakeups; the true head of the line is the record in `queue.lock`.
- The command runs as a child of the wrapper. Lock descriptors are close-on-exec, so only the wrapper holds the locks.

## Agent instructions

Paste this into `CLAUDE.md` or `AGENTS.md` (replace N with your slot count):

```markdown
**Heavy checks go through `agent-lock`** so parallel agents on this machine don't overlap and skew each other:
- `agent-lock exclusive -- <cmd>` for benchmarks (runs alone, waits for everything else)
- `agent-lock shared -- <cmd>` for test runs, full checks, anything container-backed (up to N at once)
- Add `--desc "<what this run is for, a few words>"` before `--`, and `--uses docker` when the command starts containers, e.g. `agent-lock shared --desc "redis adapter specs" --uses docker -- pnpm vitest run packages/redis`
- Quick things (fmt, lint, typecheck) run without it. `agent-lock status` shows who is running and who is next.
- Waiting is part of the command's runtime: a run that may wait behind others goes in a background task, not a foreground call that can hit a tool timeout. The lock is freed when the wrapper exits or is killed.
```

## Development

```sh
swift build
swift test            # needs a Swift 6 toolchain (Xcode 16+ or matching Command Line Tools)
```

Integration tests spawn the built binary against temporary state directories. If `/usr/bin/perl` and the legacy Perl script exist at `~/.claude/bin/agent-lock` (or `agent-lock.pl.bak` next to it), a mixed Perl/Swift test also runs.

Releases: bump `AgentLock.version` in `Sources/AgentLockCore/Config.swift`, commit, then run `scripts/release.sh <version> <path-to-homebrew-tap-checkout>`.

## License

MIT
