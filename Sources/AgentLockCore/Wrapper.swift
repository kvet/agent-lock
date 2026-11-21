import Darwin
import Foundation

/// Runs a command under the lock: queue for slots, run the child, forward signals,
/// release, and return the exit code. Mirrors the Perl script step by step.
public final class Wrapper {
    let config: Config
    let mode: Mode
    let argv: [String]
    private var record: JobRecord
    private var lastNote: TimeInterval = 0

    public init(config: Config, options: RunOptions) {
        precondition(!options.argv.isEmpty)
        self.config = config
        self.mode = options.mode
        self.argv = options.argv
        self.record = JobRecord(pid: getpid(), mode: options.mode, enqueuedAt: nowMillis(), cwd: currentDirectory(),
                                argv: options.argv, description: options.description, uses: options.uses)
    }

    private func path(_ name: String) -> String { config.dir + "/" + name }

    private func fatal(_ message: String) -> Never {
        writeStderr("agent-lock: \(message)\n")
        exit(1)
    }

    private func openLockOrDie(_ name: String) -> Int32 {
        let fd = LockFiles.openLock(path(name))
        if fd < 0 { fatal("open \(name): \(LockFiles.errorText())") }
        return fd
    }

    /// At most once every 60 s while waiting for slots.
    private func noteWaiting() {
        let now = Date().timeIntervalSince1970
        if now - lastNote < 60 { return }
        lastNote = now
        let holders = StateReader(config: config).holders().running.map(\.text)
        writeStderr("agent-lock: waiting (\(mode.rawValue)) behind: \(holders.isEmpty ? "queue" : holders.joined(separator: " | "))\n")
    }

    /// Creates `waiting.<pid>`, already locked (O_EXLOCK makes create+lock atomic, so readers
    /// never mistake a fresh file for a stale one). Returns -1 if the registry is unavailable;
    /// it only affects visibility, never locking.
    private func registerWaiting() -> Int32 {
        let p = path(LockFiles.waitingPrefix + String(record.pid))
        while true {
            var fd: Int32
            repeat { fd = open(p, O_RDWR | O_CREAT | O_CLOEXEC | O_EXLOCK, 0o644) } while fd < 0 && errno == EINTR
            if fd < 0 { return -1 }
            // A reader may have unlinked a stale file of the same name while we waited for its lock.
            if LockFiles.sameFile(fd, p) {
                LockFiles.writeInfo(fd, record.jsonLine())
                return fd
            }
            close(fd)
        }
    }

    /// Steps 1–3: get in line, take slots at the head of the line, leave the line.
    /// Returns the held slot descriptors.
    func acquire() -> [Int32] {
        LockFiles.ensureDirectory(config.dir)
        let waitingFD = registerWaiting()

        // 1. Get in line.
        let queue = openLockOrDie(LockFiles.queueName)
        if !LockFiles.tryLock(queue, LOCK_EX) {
            if let ahead = JobInfo.parse(LockFiles.readInfo(fd: queue)) {
                writeStderr("agent-lock: waiting in queue behind: \(ahead.text)\n")
            }
            if !LockFiles.lock(queue, LOCK_EX) { fatal("queue: \(LockFiles.errorText())") }
        }
        LockFiles.writeInfo(queue, record.jsonLine())

        // 2. Take slots while at the head of the line.
        var held = [Int32]()
        switch mode {
        case .exclusive:
            // Lock every possible slot (not just 0..<N), in ascending order, so an exclusive
            // job also excludes shared jobs that read a different slot count: ones started
            // before the count was lowered, or after it was raised.
            let upper = max(Config.maxSlots, StateReader(config: config).slotIndices().count)
            for i in 0..<upper {
                let fd = openLockOrDie(LockFiles.slotName(i))
                if !LockFiles.tryLock(fd, LOCK_EX) {
                    noteWaiting()
                    if !LockFiles.lock(fd, LOCK_EX) { fatal("slot.\(i): \(LockFiles.errorText())") }
                }
                held.append(fd)
            }
        case .shared:
            acquire: while true {
                for i in 0..<config.slots {
                    let fd = openLockOrDie(LockFiles.slotName(i))
                    if LockFiles.tryLock(fd, LOCK_EX) {
                        held.append(fd)
                        break acquire
                    }
                    close(fd)
                }
                noteWaiting()
                usleep(500_000)
            }
        }
        record.startedAt = nowMillis()
        let info = record.jsonLine()
        for fd in held { LockFiles.writeInfo(fd, info) }

        // No longer waiting.
        if waitingFD >= 0 {
            unlink(path(LockFiles.waitingPrefix + String(record.pid)))
            close(waitingFD)
        }

        // 3. Leave the line for the next waiter.
        LockFiles.writeInfo(queue, "")
        flock(queue, LOCK_UN)
        close(queue)
        return held
    }

    /// Acquire, run, release. Returns the wrapper's exit code.
    public func run() -> Int32 {
        let held = acquire()
        // 4. Run the command; lock fds are close-on-exec, so only this wrapper holds them.
        let code = runChild(argv)
        for fd in held { LockFiles.writeInfo(fd, "") }
        return code
    }
}

/// The child pid that signal handlers forward to. Only read from the handlers.
private var forwardPid: pid_t = 0

private func forwardSignal(_ sig: Int32) {
    if forwardPid > 0 { kill(forwardPid, sig) }
}

/// Spawns `argv` (PATH lookup like execvp) with AGENT_LOCK_HELD=1, forwards SIGINT/SIGTERM/SIGHUP
/// to it, and waits. Returns the child's exit code, 128 + signal if it was killed by a signal,
/// or 127 if it could not be executed.
func runChild(_ argv: [String]) -> Int32 {
    setenv("AGENT_LOCK_HELD", "1", 1)
    let forwarded: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    // Block the forwarded signals across spawn + handler install so none is lost or
    // delivered before we know the child's pid. The child gets the original mask.
    var block = sigset_t(), original = sigset_t()
    sigemptyset(&block)
    for s in forwarded { sigaddset(&block, s) }
    sigprocmask(SIG_BLOCK, &block, &original)

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setsigmask(&attr, &original)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGMASK))
    defer { posix_spawnattr_destroy(&attr) }

    var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cargs.append(nil)
    defer { for p in cargs { free(p) } }

    var pid: pid_t = 0
    let rc = posix_spawnp(&pid, argv[0], nil, &attr, cargs, environ)
    if rc != 0 {
        sigprocmask(SIG_SETMASK, &original, nil)
        writeStderr("agent-lock: exec \(argv[0]): \(LockFiles.errorText(rc))\n")
        return 127
    }

    forwardPid = pid
    for s in forwarded { signal(s, forwardSignal) }
    sigprocmask(SIG_SETMASK, &original, nil)

    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    let sig = status & 0x7f
    return sig != 0 ? 128 + sig : (status >> 8) & 0xff
}

/// Nested call: replace this process with the command, without locking.
public func execDirect(_ argv: [String]) -> Never {
    var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cargs.append(nil)
    execvp(argv[0], cargs)
    writeStderr("agent-lock: exec \(argv[0]): \(LockFiles.errorText())\n")
    exit(127)
}

public func writeStderr(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}

func currentDirectory() -> String {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    if getcwd(&buf, buf.count) != nil { return String(cString: buf) }
    return FileManager.default.currentDirectoryPath
}
