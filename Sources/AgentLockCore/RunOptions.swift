/// Parsed arguments of `agent-lock shared|exclusive [options] [--] <cmd...>`.
public struct RunOptions: Equatable {
    public var mode: Mode
    public var description: String?
    /// Resources the job declares (e.g. "docker"). Informational only: they never affect locking.
    public var uses: [String]
    public var argv: [String]

    public init(mode: Mode, description: String? = nil, uses: [String] = [], argv: [String]) {
        self.mode = mode
        self.description = description
        self.uses = uses
        self.argv = argv
    }

    /// Parses everything after the mode word. Options come before the command; the first
    /// argument that is not an option (or a `--`) starts the command. Returns nil on a usage
    /// error (missing option value, or no command).
    public static func parse(mode: Mode, _ args: [String]) -> RunOptions? {
        var opts = RunOptions(mode: mode, argv: [])
        var rest = args[...]
        while let a = rest.first {
            let name: String, inline: String?
            if let eq = a.firstIndex(of: "="), a.hasPrefix("--") {
                name = String(a[..<eq])
                inline = String(a[a.index(after: eq)...])
            } else {
                name = a
                inline = nil
            }
            guard ["--desc", "-d", "--uses", "-u"].contains(name) else { break }
            rest = rest.dropFirst()
            let value: String
            if let inline {
                value = inline
            } else {
                guard let v = rest.first else { return nil }
                value = v
                rest = rest.dropFirst()
            }
            if name == "--desc" || name == "-d" {
                // One line, so `status` text output stays one line per job.
                let d = value.split(whereSeparator: \.isNewline).joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                opts.description = d.isEmpty ? nil : d
            } else {
                for r in value.split(separator: ",") {
                    let r = r.trimmingCharacters(in: .whitespaces)
                    if !r.isEmpty && !opts.uses.contains(r) { opts.uses.append(r) }
                }
            }
        }
        if rest.first == "--" { rest = rest.dropFirst() }
        guard !rest.isEmpty else { return nil }
        opts.argv = Array(rest)
        return opts
    }
}
