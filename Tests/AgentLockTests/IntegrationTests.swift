import AgentLockCore
import Darwin
import Foundation
import Testing

/// Spawns the built binary against temporary state directories. Serialized because the
/// assertions are about timing and parallel load would make them noisy.
@Suite(.serialized)
struct IntegrationTests {
    @Test func concurrencyCap() async throws {
        let h = try Harness(slots: 3)
        let jobs = try (1...6).map { try h.spawn("shared", h.loggedJob("s\($0)", sleep: 0.4)) }
        for j in jobs { #expect(try await h.waitExit(j) == 0) }
        let lines = h.logLines()
        #expect(lines.count == 12)
        #expect(replay(lines).maxConcurrent == 3)
    }

    @Test func exclusiveRunsAlone() async throws {
        let h = try Harness(slots: 3)
        var jobs = [Process]()
        for i in 1...3 { jobs.append(try h.spawn("shared", h.loggedJob("a\(i)", sleep: 0.3))) }
        jobs.append(try h.spawn("exclusive", h.loggedJob("X", sleep: 0.3)))
        for i in 1...3 { jobs.append(try h.spawn("shared", h.loggedJob("b\(i)", sleep: 0.3))) }
        for j in jobs { #expect(try await h.waitExit(j) == 0) }
        let lines = h.logLines()
        #expect(lines.contains("+ X"))
        #expect(lines.count == 14)
        #expect(replay(lines).overlaps["X", default: []].isEmpty)
    }

    @Test func exclusiveIsNotStarved() async throws {
        let h = try Harness(slots: 3)
        let holders = try (1...3).map { try h.spawn("shared", h.loggedJob("s\($0)", sleep: 1.5)) }
        try await h.waitUntil("3 holders") { h.snapshot().running.count == 3 }
        let x = try h.spawn("exclusive", h.loggedJob("X", sleep: 0.2))
        try await h.waitUntil("exclusive at head of line") { h.snapshot().next?.pid == x.processIdentifier }
        let late = try (4...5).map { try h.spawn("shared", h.loggedJob("s\($0)", sleep: 0.1)) }
        for j in holders + [x] + late { #expect(try await h.waitExit(j) == 0) }
        let lines = h.logLines()
        let xStart = try #require(lines.firstIndex(of: "+ X"))
        for id in ["s4", "s5"] {
            let start = try #require(lines.firstIndex(of: "+ \(id)"))
            #expect(xStart < start, "exclusive job should start before \(id)")
        }
    }

    /// Lowering the slot count while jobs run: an exclusive job started with the new, smaller
    /// count must still wait for shared jobs holding slots above it.
    @Test func shrinkingSlotsWhileJobsRun() async throws {
        let h = try Harness(slots: 3)
        let shared = try (1...3).map { try h.spawn("shared", h.loggedJob("s\($0)", sleep: 1.0)) }
        try await h.waitUntil("3 holders") { h.snapshot().running.count == 3 }

        let small = Config(slots: 2, dir: h.stateDir)
        let s = StateReader(config: small).snapshot()
        #expect(s.running.count == 3, "a reader with fewer slots still sees every holder")
        #expect(s.slotsInUse == 3)

        let x = try h.spawn("exclusive", h.loggedJob("X", sleep: 0.3), env: ["AGENT_LOCK_SLOTS": "2"])
        for j in shared + [x] { #expect(try await h.waitExit(j) == 0) }
        #expect(replay(h.logLines()).overlaps["X", default: []].isEmpty)
    }

    /// Raising the slot count while an exclusive job runs: a shared job started with the new,
    /// larger count must not slip in next to it on a slot the exclusive job didn't know about.
    @Test func growingSlotsWhileExclusiveRuns() async throws {
        let h = try Harness(slots: 2)
        let x = try h.spawn("exclusive", h.loggedJob("X", sleep: 1.0))
        try await h.waitUntil("exclusive running") { h.logLines().contains("+ X") }
        let s = h.snapshot()
        #expect(s.running.count == 1)
        #expect(s.slotsInUse == 2, "an exclusive job counts as N in use, not as every slot file it locks")

        let late = try h.spawn("shared", h.loggedJob("s", sleep: 0.1), env: ["AGENT_LOCK_SLOTS": "4"])
        for j in [x, late] { #expect(try await h.waitExit(j) == 0) }
        #expect(replay(h.logLines()).overlaps["X", default: []].isEmpty)
    }

    @Test func killNineReleasesSlot() async throws {
        let h = try Harness(slots: 1)
        let childPidFile = h.root + "/child.pid"
        let holder = try h.spawn("shared", ["/bin/sh", "-c", "echo $$ > \"$1\"; exec sleep 30", "sh", childPidFile])
        try await h.waitUntil("holder running") { h.snapshot().slotsInUse == 1 }
        kill(holder.processIdentifier, SIGKILL)
        _ = try await h.waitExit(holder)
        defer { killChild(childPidFile) }
        let s = h.snapshot()
        #expect(s.slotsInUse == 0)
        #expect(s.running.isEmpty)
        #expect(try h.run(["status"]).out == "running: (none)\nnext:    (none)\n")
        // And the slot is actually free.
        #expect(try h.run(["shared", "--", "true"]).code == 0)
    }

    @Test func killNineRemovesWaiter() async throws {
        let h = try Harness(slots: 1)
        let childPidFile = h.root + "/child.pid"
        let holder = try h.spawn("shared", ["/bin/sh", "-c", "echo $$ > \"$1\"; exec sleep 30", "sh", childPidFile])
        defer { killChild(childPidFile) }
        try await h.waitUntil("holder running") { h.snapshot().running.count == 1 }
        let w1 = try h.spawn("shared", ["true"])
        try await h.waitUntil("w1 at head") { h.snapshot().next?.pid == w1.processIdentifier }
        let w2 = try h.spawn("shared", ["true"])
        try await h.waitUntil("w2 queued") { h.snapshot().queued.map(\.pid) == [w2.processIdentifier] }

        kill(w2.processIdentifier, SIGKILL)
        _ = try await h.waitExit(w2)
        try await h.waitUntil("w2 gone from queue") { h.snapshot().queued.isEmpty }
        #expect(!FileManager.default.fileExists(atPath: h.stateDir + "/waiting.\(w2.processIdentifier)"))

        kill(w1.processIdentifier, SIGKILL)
        _ = try await h.waitExit(w1)
        try await h.waitUntil("w1 gone from head") { h.snapshot().next == nil }
        #expect(h.snapshot().waitingCount == 0)
        kill(holder.processIdentifier, SIGKILL)
    }

    @Test func nestedCallRunsImmediately() async throws {
        let h = try Harness(slots: 1)
        let childPidFile = h.root + "/child.pid"
        let holder = try h.spawn("shared", ["/bin/sh", "-c", "echo $$ > \"$1\"; exec sleep 30", "sh", childPidFile])
        defer { killChild(childPidFile) }
        try await h.waitUntil("holder running") { h.snapshot().running.count == 1 }
        let started = Date()
        let r = try h.run(["exclusive", "--", "sh", "-c", "exit 3"], env: ["AGENT_LOCK_HELD": "1"])
        #expect(r.code == 3)
        #expect(Date().timeIntervalSince(started) < 2)
        kill(holder.processIdentifier, SIGKILL)
    }

    @Test func childSeesAgentLockHeld() throws {
        let h = try Harness()
        #expect(try h.run(["shared", "sh", "-c", #"test "$AGENT_LOCK_HELD" = 1"#]).code == 0)
    }

    @Test func exitCodes() throws {
        let h = try Harness()
        #expect(try h.run(["shared", "--", "sh", "-c", "exit 7"]).code == 7)
        #expect(try h.run(["exclusive", "sh", "-c", "exit 0"]).code == 0)
        #expect(try h.run(["shared", "--", "sh", "-c", "kill -9 $$"]).code == 128 + 9)
        let missing = try h.run(["shared", "--", "/nonexistent/command"])
        #expect(missing.code == 127)
        #expect(missing.err.contains("agent-lock: exec /nonexistent/command"))
        #expect(try h.run(["shared", "--", "no-such-command-on-path-xyz"]).code == 127)
        for args in [[], ["shared"], ["shared", "--"], ["exclusive"], ["bogus", "true"], ["status", "--bogus"],
                     ["shared", "--desc"], ["shared", "--desc", "x"], ["exclusive", "--uses", "docker", "--"]] {
            let r = try h.run(args)
            #expect(r.code == 64, "args \(args)")
            #expect(r.err.hasPrefix("usage:"), "args \(args)")
        }
    }

    @Test func signalForwarding() async throws {
        let h = try Harness()
        let ready = h.root + "/ready", got = h.root + "/got"
        let script = #"trap 'echo term > "$2"; exit 0' TERM; echo ready > "$1"; while :; do sleep 0.05; done"#
        let p = try h.spawn("shared", ["/bin/sh", "-c", script, "sh", ready, got])
        try await h.waitUntil("child ready") { FileManager.default.fileExists(atPath: ready) }
        kill(p.processIdentifier, SIGTERM)
        #expect(try await h.waitExit(p) == 0)
        #expect(FileManager.default.fileExists(atPath: got))
        #expect(h.snapshot().slotsInUse == 0)
    }

    @Test func statusJSONAndQueueOrder() async throws {
        let h = try Harness(slots: 1)
        #expect(try h.run(["status"]).out == "running: (none)\nnext:    (none)\n")

        let childPidFile = h.root + "/child.pid"
        let holder = try h.spawn("shared", ["/bin/sh", "-c", "echo $$ > \"$1\"; exec sleep 30", "sh", childPidFile])
        defer { killChild(childPidFile) }
        try await h.waitUntil("holder running") { h.snapshot().running.count == 1 }
        var waiters = [Process]()
        for i in 1...3 {
            waiters.append(try h.spawn(i == 2 ? "exclusive" : "shared", ["true"]))
            try await h.waitUntil("waiter \(i) registered") { h.snapshot().waitingCount == i }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let r = try h.run(["status", "--json"])
        #expect(r.code == 0)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        #expect(Set(json.keys) == ["slots", "running", "next", "queued"])
        #expect(json["slots"] as? Int == 1)

        let running = try #require(json["running"] as? [[String: Any]])
        #expect(running.count == 1)
        let rec = running[0]
        #expect(Set(rec.keys) == ["pid", "mode", "enqueuedAt", "startedAt", "cwd", "argv"])
        #expect(rec["pid"] as? Int == Int(holder.processIdentifier))
        #expect(rec["mode"] as? String == "shared")
        #expect((rec["argv"] as? [String])?.first == "/bin/sh")
        #expect(rec["cwd"] as? String != nil)

        let next = try #require(json["next"] as? [String: Any])
        #expect(next["pid"] as? Int == Int(waiters[0].processIdentifier))
        #expect(next["startedAt"] == nil)

        let queued = try #require(json["queued"] as? [[String: Any]])
        #expect(queued.compactMap { $0["pid"] as? Int } == waiters[1...].map { Int($0.processIdentifier) })
        #expect(queued.compactMap { $0["mode"] as? String } == ["exclusive", "shared"])
        let times = queued.compactMap { $0["enqueuedAt"] as? Int }
        #expect(times == times.sorted())

        let text = try h.run(["status"]).out.split(separator: "\n").map(String.init)
        #expect(text.count == 4)
        #expect(text[0].hasPrefix("running: pid=\(holder.processIdentifier) shared since "))
        #expect(text[1].hasPrefix("next:    pid=\(waiters[0].processIdentifier) shared since "))
        #expect(text[2].hasPrefix("queued:  pid=\(waiters[1].processIdentifier) exclusive since "))
        #expect(text[3].hasPrefix("queued:  pid=\(waiters[2].processIdentifier) shared since "))

        kill(holder.processIdentifier, SIGKILL)
        for w in waiters { #expect(try await h.waitExit(w) == 0) }
    }

    @Test func descriptionAndUsesInStatus() async throws {
        let h = try Harness(slots: 1)
        let ready = h.root + "/ready"
        let p = try h.start(h.binary, ["shared", "--desc", "redis specs", "--uses", "docker,db", "--",
                                       "/bin/sh", "-c", "echo $AGENT_LOCK_HELD > \"$1\"; sleep 30", "sh", ready])
        try await h.waitUntil("job running") { FileManager.default.fileExists(atPath: ready) }

        let json = try #require(try JSONSerialization.jsonObject(with: Data(h.run(["status", "--json"]).out.utf8)) as? [String: Any])
        let rec = try #require((json["running"] as? [[String: Any]])?.first)
        #expect(rec["description"] as? String == "redis specs")
        #expect(rec["uses"] as? [String] == ["docker", "db"])
        // The options are not passed to the command.
        #expect((rec["argv"] as? [String])?.first == "/bin/sh")

        let text = try h.run(["status"]).out
        #expect(text.hasPrefix("running: pid=\(p.processIdentifier) shared since "))
        #expect(text.contains(" — redis specs (uses docker, db)\n"))
        kill(p.processIdentifier, SIGTERM)
        _ = try await h.waitExit(p)

        // Nested calls accept (and ignore) the options too.
        #expect(try h.run(["shared", "--desc", "inner", "--uses", "docker", "--", "sh", "-c", "exit 4"],
                          env: ["AGENT_LOCK_HELD": "1"]).code == 4)
    }

    @Test func legacySlotIsReportedAsRawText() async throws {
        let h = try Harness(slots: 1)
        LockFiles.ensureDirectory(h.stateDir)
        let legacy = "pid=4242 shared since 07:52:14 in /tmp/project: pnpm check"
        let fd = LockFiles.openLock(h.stateDir + "/slot.0")
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(LockFiles.tryLock(fd, LOCK_EX))
        LockFiles.writeInfo(fd, legacy)

        #expect(try h.run(["status"]).out == "running: \(legacy)\nnext:    (none)\n")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(h.run(["status", "--json"]).out.utf8)) as? [String: Any])
        #expect(json["running"] as? [String] == [legacy])

        // A Swift waiter behind the legacy holder names it in its waiting message.
        let p = try h.spawn("shared", ["true"])
        try await h.waitUntil("waiter at head") { h.snapshot().next?.pid == p.processIdentifier }
        flock(fd, LOCK_UN)
        #expect(try await h.waitExit(p) == 0)
        let err = try String(contentsOfFile: h.root + "/err.1", encoding: .utf8)
        #expect(err.contains("agent-lock: waiting (shared) behind: \(legacy)"))
    }

    /// The Perl script and the Swift binary contending for the same directory.
    @Test(.enabled(if: legacyScript() != nil, "needs /usr/bin/perl and ~/.claude/bin/agent-lock (Perl)"))
    func mixedWithPerlScript() async throws {
        let script = try #require(legacyScript())
        // The Perl script hardcodes $HOME/.claude/state/agent-lock and 3 slots.
        let h = try Harness(slots: 3, stateDir: ".claude/state/agent-lock")
        var jobs = [Process]()
        for i in 1...3 {
            jobs.append(try h.start("/usr/bin/perl", [script, "shared", "--"] + h.loggedJob("perl\(i)", sleep: 0.5)))
            jobs.append(try h.spawn("shared", h.loggedJob("swift\(i)", sleep: 0.5)))
        }
        try await h.waitUntil("a Perl holder is visible") {
            h.snapshot().running.contains { if case .legacy = $0 { return true } else { return false } }
        }
        for j in jobs { #expect(try await h.waitExit(j) == 0) }
        #expect(h.logLines().count == 12)
        #expect(replay(h.logLines()).maxConcurrent == 3)

        // Exclusive in Swift excludes Perl shared jobs, and vice versa.
        jobs = [
            try h.start("/usr/bin/perl", [script, "shared", "--"] + h.loggedJob("p", sleep: 0.4)),
            try h.spawn("exclusive", h.loggedJob("X", sleep: 0.4)),
            try h.start("/usr/bin/perl", [script, "exclusive", "--"] + h.loggedJob("PX", sleep: 0.4)),
            try h.spawn("shared", h.loggedJob("s", sleep: 0.4)),
        ]
        for j in jobs { #expect(try await h.waitExit(j) == 0) }
        let overlaps = replay(Array(h.logLines().dropFirst(12))).overlaps
        #expect(overlaps["X", default: []].isEmpty)
        #expect(overlaps["PX", default: []].isEmpty)
    }
}

func legacyScript() -> String? {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"), let pw = getpwuid(getuid()) else { return nil }
    let bin = String(cString: pw.pointee.pw_dir) + "/.claude/bin/"
    // The original location, or the backup kept after swapping in the Swift binary.
    for path in [bin + "agent-lock", bin + "agent-lock.pl.bak"] {
        if let head = try? String(contentsOfFile: path, encoding: .utf8), head.hasPrefix("#!/usr/bin/perl") { return path }
    }
    return nil
}

func killChild(_ pidFile: String) {
    if let s = try? String(contentsOfFile: pidFile, encoding: .utf8),
       let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
        kill(pid, SIGKILL)
    }
}
