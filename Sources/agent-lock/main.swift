import AgentLockCore
import Darwin
import Foundation

let usageText = """
    usage: agent-lock shared|exclusive [--desc TEXT] [--uses RES[,RES...]] [--] <cmd...>
           agent-lock status [--json]
           agent-lock menubar
           agent-lock version

    """

func usage() -> Never {
    writeStderr(usageText)
    exit(64)
}

func loadConfig() -> Config {
    do {
        return try Config.load()
    } catch {
        writeStderr("agent-lock: \(error)\n")
        exit(64)
    }
}

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { usage() }
let command = args.removeFirst()

switch command {
case "status":
    var json = false
    for a in args {
        if a == "--json" { json = true } else { usage() }
    }
    let config = loadConfig()
    LockFiles.ensureDirectory(config.dir)
    let snapshot = StateReader(config: config).snapshot()
    print(json ? snapshot.jsonOutput() : snapshot.textOutput(), terminator: "")
    exit(0)

case "version", "--version":
    print("agent-lock \(AgentLock.version)")
    exit(0)

case "menubar":
    if !args.isEmpty { usage() }
    runMenuBar(config: loadConfig())

case "shared", "exclusive":
    guard let options = RunOptions.parse(mode: Mode(rawValue: command)!, args) else { usage() }
    // Nested call: we already hold a lock further up; locking again would deadlock.
    // Same truthiness as Perl: unset, "" and "0" are false.
    if let held = ProcessInfo.processInfo.environment["AGENT_LOCK_HELD"], held != "", held != "0" {
        execDirect(options.argv)
    }
    exit(Wrapper(config: loadConfig(), options: options).run())

default:
    usage()
}
