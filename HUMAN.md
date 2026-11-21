# Steps for you

## Now

- [ ] **Check the menu bar app by hand.** It's running from `~/.claude/bin/agent-lock`.
  - Start jobs in a few terminals, e.g. `agent-lock shared --desc "test" --uses docker -- sleep 60` and `agent-lock exclusive -- sleep 20`. Within about 2 s the title shows counts like `2/3 +1`, and the icon turns into a lock during the exclusive job, in the same colour as other menu bar icons.
  - `kill -9` a wrapper pid from `agent-lock status`. The menu bar updates.
  - In a job's submenu, check that Terminate (after confirming), Copy Command, Copy PID and Reveal cwd each work.
- [ ] **Check CI is green:** https://github.com/kvet/agent-lock/actions
- [ ] **Update your `~/.claude/CLAUDE.md`** so agents pass `--desc` and `--uses docker`. The snippet is in the README's **Agent instructions** section.

## Decide

- **Perl interop test in CI.** It needs the Perl script, which only exists on your machine (`~/.claude/bin/agent-lock.pl.bak`), so CI skips it. To run it in CI, vendor the script into `Tests/Fixtures/`.
- **Copyright line** in `LICENSE`: "agent-lock contributors". Put your name or your org's there if you prefer.

## Later: Homebrew

1. Create an empty GitHub repo `kvet/homebrew-tap` and clone it next to this one (`~/Projects/Testing/homebrew-tap`).
2. Copy `Formula/agent-lock.rb` into the tap at `Formula/agent-lock.rb`.
3. If needed, bump `AgentLock.version` in `Sources/AgentLockCore/Config.swift`, then commit and push. Then run:

   ```sh
   scripts/release.sh 0.1.0 ../homebrew-tap
   ```

   This tags and pushes `v0.1.0` and fills in `url` and `sha256` in the tap's formula. It doesn't push the tap.
4. In the tap, run `brew install --build-from-source ./Formula/agent-lock.rb && brew test agent-lock`, then commit and push.
5. Run `brew services start agent-lock` and check that the status item appears. First stop the one started by hand: `pkill -f "agent-lock menubar"`.
6. Point `~/.claude/bin/agent-lock` at the Homebrew copy (`ln -sf "$(brew --prefix)/bin/agent-lock" ~/.claude/bin/agent-lock`), or change your CLAUDE.md to call plain `agent-lock`.
7. Remove the "tap is not published yet" note from the README's **Install** section.
8. Share https://github.com/kvet/agent-lock with coworkers. The README's **Install** section covers everything, including setting up their agents.

## Reference

- Roll back to the Perl script: `mv ~/.claude/bin/agent-lock.pl.bak ~/.claude/bin/agent-lock`
- Reinstall after code changes, without disturbing running agents:

  ```sh
  swift build -c release && cp .build/release/agent-lock ~/.claude/bin/.agent-lock.new && mv -f ~/.claude/bin/.agent-lock.new ~/.claude/bin/agent-lock
  pkill -f "agent-lock menubar"; ~/.claude/bin/agent-lock menubar &
  ```
