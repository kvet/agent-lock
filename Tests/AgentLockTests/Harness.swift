import AgentLockCore
import Darwin
import Foundation
import Testing

struct TimeoutError: Error, CustomStringConvertible {
    let description: String
}

/// Locates the built `agent-lock` binary: $AGENT_LOCK_BIN, else next to the test bundle.
func agentLockBinary() -> String {
    if let p = ProcessInfo.processInfo.environment["AGENT_LOCK_BIN"], !p.isEmpty { return p }
    var dirs = Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent().path }
    dirs.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path)
    // Fallback: the package's own debug build.
    let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    dirs.append(packageRoot.appendingPathComponent(".build/debug").path)
    for d in dirs {
        let p = d + "/agent-lock"
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue,
           FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
    }
    fatalError("agent-lock binary not found; build it or set AGENT_LOCK_BIN")
}

/// One isolated state directory plus helpers to spawn wrappers against it.
final class Harness {
    let root: String
    let stateDir: String
    let slots: Int
    let binary = agentLockBinary()
    private var processes: [Process] = []
    private var counter = 0

    init(slots: Int = 3, stateDir: String? = nil) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-lock-tests-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        self.root = root
        self.stateDir = root + "/" + (stateDir ?? "state")
        self.slots = slots
    }

    deinit {
        for p in processes where p.isRunning { kill(p.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(atPath: root)
    }

    var config: Config { Config(slots: slots, dir: stateDir) }
    var logPath: String { root + "/log" }

    /// Environment for spawned wrappers. Strips AGENT_LOCK_HELD, which is set when the
    /// test run itself is wrapped in agent-lock, and points HOME at the temp root so no
    /// user config file is read.
    func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("AGENT_LOCK_") }
        env["HOME"] = root
        env["AGENT_LOCK_DIR"] = stateDir
        env["AGENT_LOCK_SLOTS"] = String(slots)
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Starts `executable args` in the background with stdout/stderr going to files.
    @discardableResult
    func start(_ executable: String, _ args: [String], env extra: [String: String] = [:]) throws -> Process {
        counter += 1
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.environment = environment(extra)
        p.currentDirectoryURL = URL(fileURLWithPath: root)
        FileManager.default.createFile(atPath: root + "/out.\(counter)", contents: nil)
        FileManager.default.createFile(atPath: root + "/err.\(counter)", contents: nil)
        p.standardOutput = FileHandle(forWritingAtPath: root + "/out.\(counter)")
        p.standardError = FileHandle(forWritingAtPath: root + "/err.\(counter)")
        p.standardInput = FileHandle.nullDevice
        try p.run()
        processes.append(p)
        return p
    }

    @discardableResult
    func spawn(_ mode: String, _ cmd: [String], env: [String: String] = [:]) throws -> Process {
        try start(binary, [mode, "--"] + cmd, env: env)
    }

    /// A job that logs "+ id" when it starts and "- id" when it ends, sleeping in between.
    /// Appends of short lines are atomic, so the log order is the real event order.
    func loggedJob(_ id: String, sleep seconds: Double) -> [String] {
        ["/bin/sh", "-c", "echo \"+ $1\" >> \"$2\"; sleep \(seconds); echo \"- $1\" >> \"$2\"", "sh", id, logPath]
    }

    /// Runs the binary to completion and captures its output.
    func run(_ args: [String], env: [String: String] = [:]) throws -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        p.environment = environment(env)
        p.currentDirectoryURL = URL(fileURLWithPath: root)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (exitCode(p), String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    func snapshot() -> Snapshot {
        StateReader(config: config).snapshot()
    }

    func logLines() -> [String] {
        ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func waitUntil(_ what: String, timeout: Double = 10, _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { throw TimeoutError(description: "timed out waiting for: \(what)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func waitExit(_ p: Process, timeout: Double = 20) async throws -> Int32 {
        try await waitUntil("pid \(p.processIdentifier) to exit", timeout: timeout) { !p.isRunning }
        return exitCode(p)
    }
}

/// The shell-style exit code: status, or 128 + signal.
func exitCode(_ p: Process) -> Int32 {
    p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
}

/// Replays a "+ id" / "- id" log and returns the maximum number of jobs running at once,
/// plus, for each id, the set of other ids that were running at some point alongside it.
func replay(_ lines: [String]) -> (maxConcurrent: Int, overlaps: [String: Set<String>]) {
    var active = Set<String>()
    var overlaps: [String: Set<String>] = [:]
    var maxConcurrent = 0
    for line in lines {
        let id = String(line.dropFirst(2))
        if line.hasPrefix("+ ") {
            for other in active {
                overlaps[id, default: []].insert(other)
                overlaps[other, default: []].insert(id)
            }
            active.insert(id)
            maxConcurrent = max(maxConcurrent, active.count)
        } else {
            active.remove(id)
        }
    }
    return (maxConcurrent, overlaps)
}
