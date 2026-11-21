import Darwin
import Foundation

/// Thin wrappers over the POSIX calls the locking model is built on.
/// All descriptors are opened close-on-exec so only the wrapper process holds the locks.
public enum LockFiles {
    public static let queueName = "queue.lock"
    public static let waitingPrefix = "waiting."

    public static func slotName(_ i: Int) -> String { "slot.\(i)" }

    public static func errorText(_ code: Int32 = errno) -> String {
        String(cString: strerror(code))
    }

    /// Opens (creating if needed) a lock file for reading and writing. Returns -1 on error.
    public static func openLock(_ path: String) -> Int32 {
        var fd: Int32
        repeat { fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644) } while fd < 0 && errno == EINTR
        return fd
    }

    /// Non-blocking lock attempt. Returns true if the lock was taken.
    public static func tryLock(_ fd: Int32, _ op: Int32) -> Bool {
        flock(fd, op | LOCK_NB) == 0
    }

    /// Blocking lock, retrying on EINTR. Returns false on any other error.
    public static func lock(_ fd: Int32, _ op: Int32) -> Bool {
        while flock(fd, op) != 0 {
            if errno != EINTR { return false }
        }
        return true
    }

    /// Replaces the file's contents with `info` (no trailing newline, as the Perl script did).
    public static func writeInfo(_ fd: Int32, _ info: String) {
        _ = ftruncate(fd, 0)
        let bytes = Array(info.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress! + off, bytes.count - off, off_t(off)) }
            if n < 0 {
                if errno == EINTR { continue }
                return
            }
            off += n
        }
    }

    public static func readInfo(fd: Int32) -> String {
        var out = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        var off: off_t = 0
        while true {
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, $0.count, off) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
            off += off_t(n)
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func readInfo(path: String) -> String {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { return "" }
        defer { close(fd) }
        return readInfo(fd: fd)
    }

    /// Is the lock on `path` held by anyone? Takes LOCK_SH|LOCK_NB and, if that succeeds,
    /// unlocks immediately. A missing file is not held.
    public static func isHeld(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// Whether `fd` still refers to the file currently at `path` (it may have been unlinked).
    public static func sameFile(_ fd: Int32, _ path: String) -> Bool {
        var a = stat(), b = stat()
        return fstat(fd, &a) == 0 && stat(path, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    public static func ensureDirectory(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
}
