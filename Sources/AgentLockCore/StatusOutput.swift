import Foundation

extension Snapshot {
    /// The Perl script's `running:` / `next:` lines, plus a `queued:` line per other waiter.
    public func textOutput() -> String {
        var out = ""
        if running.isEmpty {
            out += "running: (none)\n"
        } else {
            for info in running { out += "running: \(info.text)\n" }
        }
        out += "next:    \(next?.text ?? "(none)")\n"
        for info in queued { out += "queued:  \(info.text)\n" }
        return out
    }

    /// `{"slots": N, "running": [...], "next": record|null, "queued": [...]}`.
    /// Records are JSON objects; legacy plain-text infos are JSON strings.
    public func jsonOutput() -> String {
        func encode(_ info: JobInfo) -> String {
            switch info {
            case .record(let r): return r.jsonLine()
            case .legacy(let s): return jsonString(s)
            }
        }
        let runningJSON = running.map(encode).joined(separator: ",")
        let queuedJSON = queued.map(encode).joined(separator: ",")
        let nextJSON = next.map(encode) ?? "null"
        return #"{"slots":\#(slots),"running":[\#(runningJSON)],"next":\#(nextJSON),"queued":[\#(queuedJSON)]}"# + "\n"
    }
}

func jsonString(_ s: String) -> String {
    let data = try! JSONEncoder().encode([s])
    // Strip the surrounding [ ].
    return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
}
