import AgentLockCore
import Foundation
import Testing

struct ConfigTests {
    @Test func defaults() throws {
        let c = try Config.load(environment: ["HOME": "/nonexistent-home"])
        #expect(c == Config(slots: 3, dir: "/nonexistent-home/.claude/state/agent-lock"))
    }

    @Test func fileThenEnvironment() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/.config/agent-lock", withIntermediateDirectories: true)
        try "# comment\nslots = 4\ndir=~/locks\nunknown=1\n".write(toFile: home + "/.config/agent-lock/config", atomically: true, encoding: .utf8)

        #expect(try Config.load(environment: ["HOME": home]) == Config(slots: 4, dir: home + "/locks"))
        #expect(try Config.load(environment: ["HOME": home, "AGENT_LOCK_SLOTS": "2", "AGENT_LOCK_DIR": "/x"])
            == Config(slots: 2, dir: "/x"))
    }

    @Test func invalidSlots() {
        for bad in ["0", "-1", "three"] {
            #expect(throws: ConfigError.self) { try Config.load(environment: ["HOME": "/h", "AGENT_LOCK_SLOTS": bad]) }
        }
    }
}

struct JobInfoTests {
    let record = JobRecord(pid: 12, mode: .exclusive, enqueuedAt: 1_000, startedAt: 2_000, cwd: "/a/b", argv: ["echo", "hi there"])

    @Test func recordRoundTrip() {
        let line = record.jsonLine()
        #expect(!line.contains("\n"))
        #expect(!line.contains(#"\/"#))
        #expect(JobInfo.parse(line) == .record(record))
        #expect(JobInfo.parse(line + "\n") == .record(record))
    }

    @Test func waitingRecordOmitsStartedAt() {
        var r = record
        r.startedAt = nil
        #expect(!r.jsonLine().contains("startedAt"))
        #expect(JobInfo.parse(r.jsonLine()) == .record(r))
    }

    @Test func emptyIsNil() {
        #expect(JobInfo.parse("") == nil)
        #expect(JobInfo.parse("\n") == nil)
    }

    @Test func legacyText() {
        let s = "pid=99 shared since 07:52:14 in /Users/me/proj: pnpm check --filter x"
        let info = JobInfo.parse(s)
        #expect(info == .legacy(s))
        #expect(info?.text == s)
        #expect(info?.pid == 99)
        #expect(info?.mode == .shared)
        #expect(info?.cwd == "/Users/me/proj")
        #expect(info?.command == "pnpm check --filter x")
        #expect(info?.legacySince == "07:52:14")
        // Unparseable text is still shown verbatim.
        #expect(JobInfo.parse("something else")?.text == "something else")
        #expect(JobInfo.parse("{not json")?.text == "{not json")
    }

    @Test func textMatchesPerlFormat() {
        let text = JobInfo.record(record).text
        #expect(text.hasPrefix("pid=12 exclusive since "))
        #expect(text.hasSuffix(" in /a/b: echo hi there"))
        #expect(JobInfo.record(record).shellCommand == "echo 'hi there'")
    }
}

struct StatusOutputTests {
    @Test func idleText() {
        #expect(Snapshot(slots: 3).textOutput() == "running: (none)\nnext:    (none)\n")
    }

    @Test func json() throws {
        let r = JobRecord(pid: 1, mode: .shared, enqueuedAt: 5, cwd: "/", argv: ["x"])
        let s = Snapshot(slots: 2, slotsInUse: 1, running: [.legacy("old \"text\"")], next: .record(r), queued: [])
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(s.jsonOutput().utf8)) as? [String: Any])
        #expect(obj["slots"] as? Int == 2)
        #expect(obj["running"] as? [String] == ["old \"text\""])
        #expect((obj["next"] as? [String: Any])?["pid"] as? Int == 1)
        #expect((obj["queued"] as? [Any])?.isEmpty == true)
        #expect(Snapshot(slots: 1).jsonOutput() == #"{"slots":1,"running":[],"next":null,"queued":[]}"# + "\n")
    }
}

struct MenuModelTests {
    let now: Int64 = 1_700_000_000_000

    func rec(_ pid: Int32, _ mode: Mode, waitedSec: Int64, ranSec: Int64? = nil, cwd: String = "/Users/me/p", argv: [String] = ["pnpm", "test"]) -> JobInfo {
        .record(JobRecord(pid: pid, mode: mode, enqueuedAt: now - waitedSec * 1000,
                          startedAt: ranSec.map { now - $0 * 1000 }, cwd: cwd, argv: argv))
    }

    @Test func idle() {
        let m = MenuModel(snapshot: Snapshot(slots: 3), now: now, home: "/Users/me")
        #expect(m.title == "")
        #expect(m.symbolName == MenuModel.idleSymbol)
        #expect(!m.exclusiveRunning)
        #expect(m.running.isEmpty && m.queued.isEmpty)
    }

    @Test func busyAndQueued() {
        let s = Snapshot(
            slots: 3, slotsInUse: 2,
            running: [rec(1, .shared, waitedSec: 300, ranSec: 185), rec(2, .shared, waitedSec: 10, ranSec: 5)],
            next: rec(3, .exclusive, waitedSec: 42),
            queued: [rec(4, .shared, waitedSec: 30), rec(5, .shared, waitedSec: 3700)])
        let m = MenuModel(snapshot: s, now: now, home: "/Users/me")
        #expect(m.title == "2/3 +3")
        #expect(m.symbolName == MenuModel.busySymbol)
        #expect(m.running.map(\.detail) == ["running 3m 05s", "running 5s"])
        #expect(m.running[0].cwdDisplay == "~/p")
        #expect(m.running[0].badge == "SHARED")
        #expect(m.queued.map(\.pid) == [3, 4, 5])
        #expect(m.queued[0].isNext && m.queued[0].badge == "NEXT · EXCL")
        #expect(m.queued.map(\.detail) == ["waiting 42s", "waiting 30s", "waiting 1h 01m"])
        #expect(m.slots == 3)
    }

    @Test func busyWithoutQueue() {
        let m = MenuModel(snapshot: Snapshot(slots: 3, slotsInUse: 1, running: [rec(1, .shared, waitedSec: 1, ranSec: 1)]), now: now)
        #expect(m.title == "1/3")
    }

    @Test func exclusiveRunning() {
        let m = MenuModel(snapshot: Snapshot(slots: 3, slotsInUse: 3, running: [rec(1, .exclusive, waitedSec: 1, ranSec: 1)]), now: now)
        #expect(m.exclusiveRunning)
        #expect(m.symbolName == MenuModel.exclusiveSymbol)
        #expect(m.title == "3/3")
    }

    @Test func truncatesCommandAndHandlesLegacy() {
        let long = Array(repeating: "word", count: 30)
        let legacy = JobInfo.legacy("pid=7 exclusive since 10:00:00 in /Users/me: make bench")
        let m = MenuModel(snapshot: Snapshot(slots: 3, slotsInUse: 2,
                                             running: [rec(1, .shared, waitedSec: 1, ranSec: 1, argv: long), legacy]),
                          now: now, home: "/Users/me")
        #expect(m.running[0].command.count == MenuModel.commandLimit)
        #expect(m.running[0].command.hasSuffix("…"))
        #expect(m.running[1].pid == 7)
        #expect(m.running[1].badge == "EXCL")
        #expect(m.running[1].cwdDisplay == "~")
        #expect(m.running[1].detail == "since 10:00:00")
        #expect(m.exclusiveRunning)
    }

    @Test func elapsedFormatting() {
        #expect(formatElapsed(millis: -5) == "0s")
        #expect(formatElapsed(millis: 59_999) == "59s")
        #expect(formatElapsed(millis: 60_000) == "1m 00s")
        #expect(formatElapsed(millis: 3_600_000 + 120_000) == "1h 02m")
    }
}

struct RunOptionsTests {
    @Test func plainCommand() {
        #expect(RunOptions.parse(mode: .shared, ["--", "pnpm", "test"]) == RunOptions(mode: .shared, argv: ["pnpm", "test"]))
        #expect(RunOptions.parse(mode: .shared, ["pnpm", "test"]) == RunOptions(mode: .shared, argv: ["pnpm", "test"]))
        // Options after the command belong to the command.
        #expect(RunOptions.parse(mode: .shared, ["pnpm", "--desc", "x"])?.argv == ["pnpm", "--desc", "x"])
        #expect(RunOptions.parse(mode: .shared, ["--", "--desc", "x"])?.argv == ["--desc", "x"])
    }

    @Test func descriptionAndUses() {
        let o = RunOptions.parse(mode: .exclusive, ["--desc", "redis specs", "--uses", "docker, db", "-u", "docker", "--uses=gpu", "--", "make"])
        #expect(o == RunOptions(mode: .exclusive, description: "redis specs", uses: ["docker", "db", "gpu"], argv: ["make"]))
        #expect(RunOptions.parse(mode: .shared, ["-d", "a\nb ", "true"])?.description == "a b")
        #expect(RunOptions.parse(mode: .shared, ["--desc=", "true"])?.description == nil)
    }

    @Test func usageErrors() {
        for args in [[], ["--"], ["--desc"], ["--uses", "docker"], ["--desc", "x", "--"]] {
            #expect(RunOptions.parse(mode: .shared, args) == nil, "args \(args)")
        }
    }
}

struct DescriptionAndUsesTests {
    @Test func recordEncodingIsBackwardCompatible() {
        let plain = JobRecord(pid: 1, mode: .shared, enqueuedAt: 1, cwd: "/", argv: ["x"])
        #expect(!plain.jsonLine().contains("description"))
        #expect(!plain.jsonLine().contains("uses"))
        // A record written by an older Swift build (no new fields) still parses.
        let old = #"{"argv":["x"],"cwd":"/","enqueuedAt":1,"mode":"shared","pid":1}"#
        #expect(JobInfo.parse(old) == .record(plain))

        let full = JobRecord(pid: 1, mode: .shared, enqueuedAt: 1, cwd: "/", argv: ["x"], description: "d", uses: ["docker"])
        #expect(JobInfo.parse(full.jsonLine()) == .record(full))
    }

    @Test func textSuffix() {
        let r = JobRecord(pid: 5, mode: .shared, enqueuedAt: 1, startedAt: 2, cwd: "/p", argv: ["pnpm", "test"],
                          description: "redis specs", uses: ["docker", "db"])
        #expect(JobInfo.record(r).text.hasSuffix(" in /p: pnpm test — redis specs (uses docker, db)"))
        var onlyUses = r
        onlyUses.description = nil
        #expect(JobInfo.record(onlyUses).text.hasSuffix(": pnpm test — (uses docker, db)"))
    }

    @Test func menuModel() {
        let r = JobRecord(pid: 5, mode: .shared, enqueuedAt: 0, startedAt: 0, cwd: "/p", argv: ["pnpm", "test"],
                          description: "redis specs", uses: ["docker"])
        let m = MenuModel(snapshot: Snapshot(slots: 3, slotsInUse: 1, running: [.record(r)]), now: 1000)
        #expect(m.running[0].label == "redis specs")
        #expect(m.running[0].hasDescription)
        #expect(m.running[0].command == "pnpm test")
        #expect(m.running[0].uses == ["docker"])

        var plain = r
        plain.description = nil
        plain.uses = nil
        let p = MenuModel(snapshot: Snapshot(slots: 3, slotsInUse: 1, running: [.record(plain)]), now: 1000)
        #expect(p.running[0].label == "pnpm test")
        #expect(!p.running[0].hasDescription)
        #expect(p.running[0].uses.isEmpty)
    }
}
