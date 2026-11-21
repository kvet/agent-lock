# Template for kvet/homebrew-tap: copy to Formula/agent-lock.rb in the tap repo.
# scripts/release.sh rewrites `url` and `sha256` there for each release.
class AgentLock < Formula
  desc "Machine-wide job queue for parallel coding agents, with a menu bar app"
  homepage "https://github.com/kvet/agent-lock"
  url "https://github.com/kvet/agent-lock/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on :macos
  depends_on macos: :ventura

  def install
    # SwiftPM's own sandbox conflicts with Homebrew's.
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/agent-lock"
  end

  service do
    run [opt_bin/"agent-lock", "menubar"]
    keep_alive successful_exit: false
    process_type :interactive
  end

  def caveats
    <<~EOS
      To show the menu bar item now and at every login:
        brew services start agent-lock

      To make coding agents use it, paste the snippet from
        https://github.com/kvet/agent-lock#agent-instructions
      into your CLAUDE.md or AGENTS.md.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/agent-lock version")
    ENV["AGENT_LOCK_DIR"] = testpath/"state"
    system bin/"agent-lock", "shared", "--", "true"
  end
end
