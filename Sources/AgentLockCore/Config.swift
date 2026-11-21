import Foundation

public enum AgentLock {
    public static let version = "0.1.0"
}

public struct ConfigError: Error, CustomStringConvertible {
    public let description: String
}

/// Slot count and state directory. Every process on the machine must use the same
/// directory. The slot count may differ between processes for a while (it can be changed
/// while jobs run): exclusive jobs always lock `slot.0` ..< `slot.\(maxSlots)`, so they
/// exclude shared jobs whatever count those read.
public struct Config: Equatable {
    public static let defaultSlots = 3
    /// Upper bound for the slot count, and the number of slot files exclusive jobs lock.
    public static let maxSlots = 16

    public var slots: Int
    public var dir: String

    public init(slots: Int, dir: String) {
        self.slots = slots
        self.dir = dir
    }

    static func home(_ env: [String: String]) -> String {
        env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
    }

    public static func filePath(environment env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        home(env) + "/.config/agent-lock/config"
    }

    /// Environment variables win over `~/.config/agent-lock/config`, which wins over defaults.
    public static func load(environment env: [String: String] = ProcessInfo.processInfo.environment) throws -> Config {
        let home = home(env)
        var slotsText: String?
        var dir: String?

        let file = filePath(environment: env)
        if let text = try? String(contentsOfFile: file, encoding: .utf8) {
            for rawLine in text.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "slots": slotsText = value
                case "dir": dir = value
                default: break
                }
            }
        }
        if let v = env["AGENT_LOCK_SLOTS"], !v.isEmpty { slotsText = v }
        if let v = env["AGENT_LOCK_DIR"], !v.isEmpty { dir = v }

        var slots = defaultSlots
        if let slotsText {
            guard let n = Int(slotsText), (1...maxSlots).contains(n) else {
                throw ConfigError(description: "invalid slot count '\(slotsText)' (must be an integer from 1 to \(maxSlots))")
            }
            slots = n
        }
        var resolvedDir = dir ?? "~/.claude/state/agent-lock"
        if resolvedDir == "~" {
            resolvedDir = home
        } else if resolvedDir.hasPrefix("~/") {
            resolvedDir = home + resolvedDir.dropFirst()
        }
        return Config(slots: slots, dir: resolvedDir)
    }

    /// Writes `slots=<n>` into the config file, keeping its other lines (and comments).
    /// New wrappers pick it up when they start; running jobs are unaffected.
    public static func saveSlots(_ n: Int, environment env: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard (1...maxSlots).contains(n) else {
            throw ConfigError(description: "invalid slot count \(n) (must be from 1 to \(maxSlots))")
        }
        let file = filePath(environment: env)
        var lines = ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        var replaced = false
        lines = lines.compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "="),
                  t[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == "slots" else { return line }
            if replaced { return nil }  // drop duplicates
            replaced = true
            return "slots=\(n)"
        }
        if !replaced { lines.append("slots=\(n)") }
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(toFile: file, atomically: true, encoding: .utf8)
    }
}
