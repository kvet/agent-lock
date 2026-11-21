# Steps for you

Things only you can do. Steps 1–2 are for now; Homebrew (step 4) is for when you're happy with the tool.

## 1. Try it locally

```sh
cd ~/Projects/Testing/agent-lock
swift build -c release
.build/release/agent-lock version
```

**Already done:** `~/.claude/bin/agent-lock` is now a copy of the release build, and the Perl script is kept as `~/.claude/bin/agent-lock.pl.bak`. Jobs still running under Perl wrappers share the same state directory, so both work side by side.

- Roll back: `mv ~/.claude/bin/agent-lock.pl.bak ~/.claude/bin/agent-lock`
- After changing the code, reinstall without disturbing running agents (copy, then atomic rename):

  ```sh
  swift build -c release && cp .build/release/agent-lock ~/.claude/bin/.agent-lock.new && mv -f ~/.claude/bin/.agent-lock.new ~/.claude/bin/agent-lock
  ```

Run the menu bar app in a terminal:

```sh
.build/release/agent-lock menubar
```

Things to check by hand:

- [ ] Start jobs in a few terminals (`agent-lock shared -- sleep 60`, `agent-lock exclusive -- sleep 20`). The counts in the menu bar update within about 2 s.
- [ ] `kill -9` a wrapper pid (from `agent-lock status`). The menu bar updates.
- [ ] Menu › job › Terminate stops the job after the confirmation.
- [ ] Copy Command, Copy PID and Reveal cwd do what they say.
- [ ] The title shows `2/3 +1`-style counts, and the icon turns into an orange lock during an exclusive job.

## 2. Create the GitHub repo

1. Create an empty repo `agent-lock` on GitHub, under your user or your org. Don't add a README or license: the repo already has them.
2. Then:

   ```sh
   cd ~/Projects/Testing/agent-lock
   git add -A && git commit -m "Initial Swift implementation"
   git branch -M main
   git remote add origin git@github.com:kvet/agent-lock.git
   git push -u origin main
   ```

3. Replace `kvet` / `kvet` with the real owner in `README.md` and `Formula/agent-lock.rb`.
4. Check that the **CI** workflow passes under the Actions tab.

## 3. Decide

- **Interop test in CI.** The mixed Perl/Swift test only runs where `~/.claude/bin/agent-lock` is the Perl script, so it is skipped in CI. If you want it in CI, vendor the Perl script into `Tests/Fixtures/`.
- **Copyright line** in `LICENSE` currently reads "agent-lock contributors". Put your name or your org's there if you prefer.

## 4. Later: Homebrew

1. Create a second empty GitHub repo named `homebrew-tap` under the same owner, and clone it next to this one (`~/Projects/Testing/homebrew-tap`).
2. Copy `Formula/agent-lock.rb` into the tap at `Formula/agent-lock.rb`.
3. Release:

   ```sh
   # bump AgentLock.version in Sources/AgentLockCore/Config.swift if needed, commit, push
   scripts/release.sh 0.1.0 ../homebrew-tap
   ```

   This tags and pushes `v0.1.0`, then fills in `url` and `sha256` in the tap's formula. It doesn't push the tap.
4. In the tap, run `brew install --build-from-source ./Formula/agent-lock.rb && brew test agent-lock`, then commit and push.
5. On a clean machine, or after `brew uninstall agent-lock`: run `brew install kvet/tap/agent-lock` and `brew services start agent-lock`, and check that the status item appears.
6. Point the symlink at the Homebrew copy instead of your local build. Agents call `~/.claude/bin/agent-lock` today, so either keep a symlink there (`ln -sf "$(brew --prefix)/bin/agent-lock" ~/.claude/bin/agent-lock`) or change your CLAUDE.md to call plain `agent-lock`.
7. Tell coworkers about the README's **Agent instructions** section.
