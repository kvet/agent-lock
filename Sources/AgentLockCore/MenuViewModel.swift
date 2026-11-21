import Foundation

/// Everything the menu bar shows, computed from a snapshot. Pure, so it is unit-tested
/// without AppKit.
public struct MenuModel: Equatable {
    public struct Job: Equatable {
        /// Stable identity across refreshes (used to update the open menu in place).
        public var id: String
        public var mode: Mode?
        /// Badge text, e.g. "SHARED", "EXCL", "NEXT · EXCL".
        public var badge: String
        /// Main label: the description if one was given, else the command (both truncated).
        public var label: String
        /// Command truncated to about 60 characters.
        public var command: String
        /// Whether `label` is the description (then the menu also shows `command`).
        public var hasDescription: Bool
        /// Declared resources, e.g. ["docker"].
        public var uses: [String]
        /// Command for the clipboard (shell-quoted).
        public var fullCommand: String
        /// cwd abbreviated with "~".
        public var cwdDisplay: String?
        public var cwd: String?
        public var pid: Int32?
        /// "running 3m 05s", "waiting 12s", "since 07:52:14".
        public var detail: String
        public var isNext: Bool
    }

    public var symbolName: String
    /// True when an exclusive job is running (the title then uses `exclusiveSymbol`).
    public var exclusiveRunning: Bool
    /// "" when idle, otherwise "2/3", plus " +4" when jobs are waiting.
    public var title: String
    public var running: [Job]
    /// Head of the line first (isNext), then the other waiters.
    public var queued: [Job]
    public var slots: Int

    public static let idleSymbol = "square.stack.3d.up"
    public static let busySymbol = "square.stack.3d.up.fill"
    public static let exclusiveSymbol = "lock.fill"

    public static let commandLimit = 60

    public init(snapshot s: Snapshot, now: Int64, home: String = NSHomeDirectory()) {
        slots = s.slots
        exclusiveRunning = s.running.contains { $0.mode == .exclusive }
        let waiting = s.waitingCount
        let idle = s.slotsInUse == 0 && s.running.isEmpty && waiting == 0
        symbolName = exclusiveRunning ? Self.exclusiveSymbol : (idle ? Self.idleSymbol : Self.busySymbol)
        if idle {
            title = ""
        } else {
            title = "\(s.slotsInUse)/\(s.slots)" + (waiting > 0 ? " +\(waiting)" : "")
        }
        running = s.running.map { Self.job($0, isNext: false, now: now, home: home) }
        queued = (s.next.map { [Self.job($0, isNext: true, now: now, home: home)] } ?? [])
            + s.queued.map { Self.job($0, isNext: false, now: now, home: home) }
    }

    static func job(_ info: JobInfo, isNext: Bool, now: Int64, home: String) -> Job {
        let modeBadge: String
        switch info.mode {
        case .shared: modeBadge = "SHARED"
        case .exclusive: modeBadge = "EXCL"
        case nil: modeBadge = "?"
        }
        let detail: String
        let id: String
        switch info {
        case .record(let r):
            id = "\(r.pid)-\(r.enqueuedAt)"
            if let started = r.startedAt {
                detail = "running " + formatElapsed(millis: now - started)
            } else {
                detail = "waiting " + formatElapsed(millis: now - r.enqueuedAt)
            }
        case .legacy(let raw):
            id = raw
            detail = info.legacySince.map { "since \($0)" } ?? ""
        }
        return Job(
            id: id,
            mode: info.mode,
            badge: isNext ? "NEXT · \(modeBadge)" : modeBadge,
            label: truncate(info.description ?? info.command, to: commandLimit),
            command: truncate(info.command, to: commandLimit),
            hasDescription: info.description != nil,
            uses: info.uses,
            fullCommand: info.shellCommand,
            cwdDisplay: info.cwd.map { abbreviateHome($0, home: home) },
            cwd: info.cwd,
            pid: info.pid,
            detail: detail,
            isNext: isNext)
    }
}

/// "42s", "3m 05s", "1h 02m".
public func formatElapsed(millis: Int64) -> String {
    let s = max(0, millis / 1000)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
    return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
}

public func truncate(_ s: String, to limit: Int) -> String {
    s.count <= limit ? s : String(s.prefix(limit - 1)) + "…"
}

public func abbreviateHome(_ path: String, home: String) -> String {
    if path == home { return "~" }
    if !home.isEmpty, path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}
