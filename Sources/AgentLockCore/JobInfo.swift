import Foundation

public enum Mode: String, Codable, Equatable {
    case shared, exclusive
}

/// Structured info record, written as single-line JSON into lock and waiting files.
public struct JobRecord: Codable, Equatable {
    public var pid: Int32
    public var mode: Mode
    /// Epoch milliseconds when the job started waiting.
    public var enqueuedAt: Int64
    /// Epoch milliseconds when the slots were acquired; nil while waiting.
    public var startedAt: Int64?
    public var cwd: String
    public var argv: [String]
    /// What the job is for, as given with --desc. Absent when not given.
    public var description: String?
    /// Declared resources (--uses), e.g. ["docker"]. Absent when none. Informational only.
    public var uses: [String]?

    public init(pid: Int32, mode: Mode, enqueuedAt: Int64, startedAt: Int64? = nil, cwd: String, argv: [String],
                description: String? = nil, uses: [String] = []) {
        self.pid = pid
        self.mode = mode
        self.enqueuedAt = enqueuedAt
        self.startedAt = startedAt
        self.cwd = cwd
        self.argv = argv
        self.description = description
        self.uses = uses.isEmpty ? nil : uses
    }

    public func jsonLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding a struct of strings and integers cannot fail.
        let data = try! encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

/// What a reader finds in a lock file: a JSON record, or the Perl script's plain text
/// (`pid=<pid> <mode> since <HH:MM:SS> in <cwd>: <cmd>`), kept verbatim.
public enum JobInfo: Equatable {
    case record(JobRecord)
    case legacy(String)

    /// Parses a lock file's contents. Empty contents mean "no info" and give nil.
    public static func parse(_ text: String) -> JobInfo? {
        var s = text
        if s.hasSuffix("\n") { s.removeLast() }
        if s.isEmpty { return nil }
        if s.hasPrefix("{"), let record = try? JSONDecoder().decode(JobRecord.self, from: Data(s.utf8)) {
            return .record(record)
        }
        return .legacy(s)
    }

    public var pid: Int32? {
        switch self {
        case .record(let r): return r.pid
        case .legacy: return legacyFields?.pid
        }
    }

    public var mode: Mode? {
        switch self {
        case .record(let r): return r.mode
        case .legacy: return legacyFields?.mode
        }
    }

    public var description: String? {
        if case .record(let r) = self { return r.description }
        return nil
    }

    public var uses: [String] {
        if case .record(let r) = self { return r.uses ?? [] }
        return []
    }

    public var cwd: String? {
        switch self {
        case .record(let r): return r.cwd
        case .legacy: return legacyFields?.cwd
        }
    }

    /// The command as one line (argv joined by spaces, as the Perl script showed it).
    public var command: String {
        switch self {
        case .record(let r): return r.argv.joined(separator: " ")
        case .legacy(let s): return legacyFields?.command ?? s
        }
    }

    /// The command quoted for pasting into a shell.
    public var shellCommand: String {
        switch self {
        case .record(let r): return r.argv.map(shellQuote).joined(separator: " ")
        case .legacy: return command
        }
    }

    /// One-line text in the Perl script's format, so `status` text output stays the same.
    /// "since" is the start time for running jobs and the enqueue time for waiting ones.
    public var text: String {
        switch self {
        case .legacy(let s):
            return s
        case .record(let r):
            let since = clockTime(epochMillis: r.startedAt ?? r.enqueuedAt)
            var line = "pid=\(r.pid) \(r.mode.rawValue) since \(since) in \(r.cwd): \(command)"
            // Extras go after the command so the Perl-compatible prefix is unchanged.
            var extras = [String]()
            if let d = r.description { extras.append(d) }
            if let u = r.uses, !u.isEmpty { extras.append("(uses \(u.joined(separator: ", ")))") }
            if !extras.isEmpty { line += " — " + extras.joined(separator: " ") }
            return line
        }
    }

    struct LegacyFields {
        var pid: Int32
        var mode: Mode
        var since: String
        var cwd: String
        var command: String
    }

    private static let legacyPattern = try! NSRegularExpression(
        pattern: #"^pid=(\d+) (shared|exclusive) since (\d\d:\d\d:\d\d) in (.*?): (.*)$"#,
        options: [.dotMatchesLineSeparators])

    var legacyFields: LegacyFields? {
        guard case .legacy(let s) = self else { return nil }
        let ns = s as NSString
        guard let m = JobInfo.legacyPattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              let pid = Int32(ns.substring(with: m.range(at: 1))),
              let mode = Mode(rawValue: ns.substring(with: m.range(at: 2)))
        else { return nil }
        return LegacyFields(pid: pid, mode: mode, since: ns.substring(with: m.range(at: 3)),
                            cwd: ns.substring(with: m.range(at: 4)), command: ns.substring(with: m.range(at: 5)))
    }

    /// The legacy "since HH:MM:SS" value, when this is a parseable legacy record.
    public var legacySince: String? { legacyFields?.since }
}

public func nowMillis() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1000).rounded())
}

/// Local wall-clock time as HH:MM:SS.
public func clockTime(epochMillis: Int64) -> String {
    var t = time_t(epochMillis / 1000)
    var parts = tm()
    localtime_r(&t, &parts)
    return String(format: "%02d:%02d:%02d", parts.tm_hour, parts.tm_min, parts.tm_sec)
}

func shellQuote(_ arg: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,+@%")
    if !arg.isEmpty, arg.unicodeScalars.allSatisfy({ safe.contains($0) }) { return arg }
    return "'" + arg.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}
