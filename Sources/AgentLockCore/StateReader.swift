import Darwin
import Foundation

/// A point-in-time view of the state directory.
public struct Snapshot: Equatable {
    /// Configured slot count (N).
    public var slots: Int
    /// Number of slot locks currently held (0...N). Can exceed the number of running jobs:
    /// an exclusive job at the head of the line holds the slots it has taken so far.
    public var slotsInUse: Int
    /// Distinct holders, in slot order.
    public var running: [JobInfo]
    /// The real head of the line: the record in `queue.lock`.
    public var next: JobInfo?
    /// Other waiters, in enqueue order (approximate: flock wakeup order is not guaranteed FIFO).
    public var queued: [JobInfo]

    public init(slots: Int, slotsInUse: Int = 0, running: [JobInfo] = [], next: JobInfo? = nil, queued: [JobInfo] = []) {
        self.slots = slots
        self.slotsInUse = slotsInUse
        self.running = running
        self.next = next
        self.queued = queued
    }

    /// Jobs waiting, including the head of the line.
    public var waitingCount: Int { (next == nil ? 0 : 1) + queued.count }
}

public struct StateReader {
    public let config: Config

    public init(config: Config) {
        self.config = config
    }

    private func path(_ name: String) -> String { config.dir + "/" + name }

    /// Slot indices to look at: 0..<N plus any higher `slot.<i>` file that exists, which a
    /// job started with a larger slot count (before the count was lowered) may hold.
    func slotIndices() -> [Int] {
        var upper = config.slots
        if let names = try? FileManager.default.contentsOfDirectory(atPath: config.dir) {
            for name in names where name.hasPrefix("slot.") {
                if let i = Int(name.dropFirst(5)), i >= 0, i < 1024 { upper = max(upper, i + 1) }
            }
        }
        return Array(0..<upper)
    }

    /// Holders of the slots, deduplicated by their info (an exclusive job writes the same
    /// info into every slot it holds), plus how many slots are in use.
    ///
    /// `inUse` counts held slots below N, plus held slots at or above N whose holder is not
    /// exclusive (leftovers from before the slot count was lowered). Exclusive jobs lock
    /// slots up to `Config.maxSlots`, and those extra locks are not "in use" capacity.
    public func holders() -> (running: [JobInfo], inUse: Int) {
        var seen = Set<String>()
        var running = [JobInfo]()
        var inUse = 0
        for i in slotIndices() {
            let p = path(LockFiles.slotName(i))
            guard LockFiles.isHeld(p) else { continue }
            let raw = LockFiles.readInfo(path: p)
            let info = JobInfo.parse(raw)
            if i < config.slots || (info != nil && info?.mode != .exclusive) { inUse += 1 }
            guard let info, seen.insert(raw).inserted else { continue }
            running.append(info)
        }
        return (running, inUse)
    }

    public func next() -> JobInfo? {
        let p = path(LockFiles.queueName)
        guard LockFiles.isHeld(p) else { return nil }
        return JobInfo.parse(LockFiles.readInfo(path: p))
    }

    /// Records from `waiting.*` files whose lock is held. Unheld files were left behind by
    /// killed processes and are deleted when `cleanStale` is set.
    public func waiters(cleanStale: Bool = true) -> [JobInfo] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: config.dir) else { return [] }
        var out = [JobInfo]()
        for name in names where name.hasPrefix(LockFiles.waitingPrefix) {
            let p = path(name)
            let fd = open(p, O_RDONLY | O_CLOEXEC)
            if fd < 0 { continue }
            defer { close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                // Nobody holds it: stale. Unlink while holding the lock, and only if the path
                // still names this file, so a new waiter reusing the pid is never affected.
                if cleanStale && LockFiles.sameFile(fd, p) { unlink(p) }
                flock(fd, LOCK_UN)
                continue
            }
            if errno != EWOULDBLOCK { continue }
            if let info = JobInfo.parse(LockFiles.readInfo(fd: fd)) { out.append(info) }
        }
        out.sort { a, b in
            switch (a, b) {
            case let (.record(x), .record(y)): return (x.enqueuedAt, x.pid) < (y.enqueuedAt, y.pid)
            case (.record, .legacy): return true
            default: return false
            }
        }
        return out
    }

    public func snapshot(cleanStale: Bool = true) -> Snapshot {
        let (running, inUse) = holders()
        let next = next()
        var queued = waiters(cleanStale: cleanStale)
        // The head of the line keeps its waiting file until it has its slots; list it once.
        if let headPid = next?.pid {
            queued.removeAll { $0.pid == headPid }
        }
        return Snapshot(slots: config.slots, slotsInUse: inUse, running: running, next: next, queued: queued)
    }
}
