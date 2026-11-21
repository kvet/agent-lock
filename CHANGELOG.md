# Changelog

## Unreleased

- Swift rewrite of the Perl `agent-lock` script: same CLI, locking model and exit codes.
- Waiter registry (`waiting.<pid>` files) so every queued job is visible.
- Structured JSON info records; legacy plain-text records are still read.
- `status --json`, `queued:` lines in `status`, `version`.
- Configuration via `AGENT_LOCK_SLOTS` / `AGENT_LOCK_DIR` or `~/.config/agent-lock/config`.
- `--desc` and `--uses` (e.g. `--uses docker`): optional, informational job description and resource tags.
- `agent-lock menubar`: macOS menu bar app showing running and queued jobs.
