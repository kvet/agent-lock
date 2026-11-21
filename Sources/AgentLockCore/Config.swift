import Foundation

public enum AgentLock {
    public static let version = "0.1.0"
}

public struct ConfigError: Error, CustomStringConvertible {
    public let description: String
}

/// Slot count and state directory. Every process on the machine must agree on both;
/// changing the slot count while jobs are running is unsupported.
public struct Config: Equatable {
    public static let defaultSlots = 3

    public var slots: Int
    public var dir: String

    public init(slots: Int, dir: String) {
        self.slots = slots
        self.dir = dir
    }

    /// Environment variables win over `~/.config/agent-lock/config`, which wins over defaults.
    public static func load(environment env: [String: String] = ProcessInfo.processInfo.environment) throws -> Config {
        let home = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        var slotsText: String?
        var dir: String?

        let file = home + "/.config/agent-lock/config"
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
            guard let n = Int(slotsText), n >= 1 else {
                throw ConfigError(description: "invalid slot count '\(slotsText)' (must be an integer >= 1)")
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
}
