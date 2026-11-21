import AgentLockCore
import AppKit

/// `agent-lock menubar`: an NSStatusItem showing slots in use and the queue.
/// Runs without a Dock icon or .app bundle.
func runMenuBar(config: Config) -> Never {
    // One instance per state directory: a second `menubar` (e.g. run by hand while the
    // brew service is up) exits quietly. Exit 0, so launchd's keep_alive leaves it down.
    LockFiles.ensureDirectory(config.dir)
    let guardFD = LockFiles.openLock(config.dir + "/menubar.lock")
    if guardFD >= 0 && !LockFiles.tryLock(guardFD, LOCK_EX) {
        writeStderr("agent-lock: menu bar app is already running\n")
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = MenuBarController(config: config)
    controller.start()
    app.run()
    exit(0)
}

final class MenuBarController: NSObject, NSMenuDelegate {
    /// Re-read on every refresh, so slot count changes (from the menu or the config file)
    /// show up. The state directory stays the one the app started with.
    private var config: Config
    private var reader: StateReader { StateReader(config: config) }
    /// AGENT_LOCK_SLOTS in our environment overrides the config file, so the menu can't change it.
    private let slotsFromEnvironment = !(ProcessInfo.processInfo.environment["AGENT_LOCK_SLOTS"] ?? "").isEmpty
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?
    private var ticks = 0
    private var menuOpen = false
    private var model: MenuModel?
    /// Job item per job id, so the open menu can be updated in place each second.
    private var jobItems: [String: NSMenuItem] = [:]
    private var renderedIDs: [String] = []

    init(config: Config) {
        self.config = config
        super.init()
    }

    func start() {
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refresh()
        rebuildMenu()
        // Polling is required: when the kernel drops a lock because its holder died,
        // nothing on disk changes. 1 s ticks; the closed menu refreshes every other tick.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)  // .common includes menu tracking
        timer = t
    }

    private func tick() {
        ticks += 1
        if menuOpen {
            refresh()
            updateOpenMenu()
        } else if ticks % 2 == 0 {
            refresh()
        }
    }

    private func refresh() {
        if let fresh = try? Config.load() { config.slots = fresh.slots }
        let m = MenuModel(snapshot: reader.snapshot(), now: nowMillis())
        model = m
        guard let button = statusItem.button else { return }
        // The default symbol size (~13 pt) looks small next to other status items; 16 pt matches them.
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let image = (NSImage(systemSymbolName: m.symbolName, accessibilityDescription: "agent-lock")
            ?? NSImage(systemSymbolName: MenuModel.busySymbol, accessibilityDescription: "agent-lock"))?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        button.imagePosition = m.title.isEmpty ? .imageOnly : .imageLeading
        button.title = m.title.isEmpty ? "" : " " + m.title
        // No tint: a tinted status item loses the menu bar's automatic light/dark styling
        // (it renders black on a dark menu bar). The lock symbol marks exclusive runs.
        button.contentTintColor = nil
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuOpen = true
        refresh()
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuOpen = false
    }

    // MARK: Menu construction

    private func allJobs(_ m: MenuModel) -> [MenuModel.Job] { m.running + m.queued }

    private func updateOpenMenu() {
        guard let m = model else { return }
        let ids = allJobs(m).map(\.id) + m.queued.filter(\.isNext).map { "next:" + $0.id }
        if ids != renderedIDs {
            rebuildMenu()
            return
        }
        for job in allJobs(m) {
            jobItems[job.id]?.attributedTitle = jobTitle(job)
        }
    }

    private func rebuildMenu() {
        guard let m = model else { return }
        menu.removeAllItems()
        jobItems = [:]
        renderedIDs = allJobs(m).map(\.id) + m.queued.filter(\.isNext).map { "next:" + $0.id }

        menu.addItem(header("Running"))
        if m.running.isEmpty {
            menu.addItem(placeholder("No jobs running"))
        }
        for job in m.running { menu.addItem(jobItem(job)) }

        menu.addItem(.separator())
        menu.addItem(header("Queued"))
        if m.queued.isEmpty {
            menu.addItem(placeholder("Queue is empty"))
        }
        for job in m.queued { menu.addItem(jobItem(job)) }

        menu.addItem(.separator())
        menu.addItem(slotsItem(current: m.slots))
        menu.addItem(actionItem("Open State Folder", #selector(openStateFolder), job: nil))
        menu.addItem(placeholder("agent-lock \(AgentLock.version)"))
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func slotsItem(current: Int) -> NSMenuItem {
        let item = NSMenuItem(title: "Slots: \(current)", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        var choices = Array(1...8)
        if !choices.contains(current) { choices.append(current) }
        for n in choices {
            let choice = NSMenuItem(title: String(n), action: #selector(setSlots(_:)), keyEquivalent: "")
            choice.target = self
            choice.tag = n
            choice.state = n == current ? .on : .off
            choice.isEnabled = !slotsFromEnvironment
            sub.addItem(choice)
        }
        sub.addItem(.separator())
        sub.addItem(placeholder(slotsFromEnvironment
            ? "Set by AGENT_LOCK_SLOTS; change it there"
            : "Applies to jobs started from now on"))
        item.submenu = sub
        return item
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    private func placeholder(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func jobTitle(_ job: MenuModel.Job) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let badgeColor: NSColor = job.mode == .exclusive ? .systemOrange : .systemBlue
        s.append(NSAttributedString(string: job.badge, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold),
            .foregroundColor: badgeColor,
        ]))
        for resource in job.uses {
            s.append(NSAttributedString(string: " " + resource, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                .foregroundColor: NSColor.systemPurple,
            ]))
        }
        s.append(NSAttributedString(string: "  " + job.label, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
        ]))
        let secondary: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        if job.hasDescription {
            s.append(NSAttributedString(string: "\n" + job.command, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        let last = [job.cwdDisplay, job.detail.isEmpty ? nil : job.detail].compactMap { $0 }.joined(separator: " · ")
        if !last.isEmpty {
            s.append(NSAttributedString(string: "\n" + last, attributes: secondary))
        }
        return s
    }

    private func jobItem(_ job: MenuModel.Job) -> NSMenuItem {
        let item = NSMenuItem(title: job.label, action: nil, keyEquivalent: "")
        item.attributedTitle = jobTitle(job)
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(actionItem("Copy Command", #selector(copyCommand(_:)), job: job))
        let pid = actionItem("Copy PID", #selector(copyPID(_:)), job: job)
        pid.isEnabled = job.pid != nil
        sub.addItem(pid)
        let reveal = actionItem("Reveal cwd in Finder", #selector(revealCwd(_:)), job: job)
        reveal.isEnabled = job.cwd != nil
        sub.addItem(reveal)
        sub.addItem(.separator())
        let term = actionItem("Terminate…", #selector(terminate(_:)), job: job)
        term.isEnabled = job.pid != nil
        sub.addItem(term)
        item.submenu = sub
        jobItems[job.id] = item
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, job: MenuModel.Job?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = job.map(JobBox.init)
        return item
    }

    // MARK: Actions

    private func job(_ sender: NSMenuItem) -> MenuModel.Job? {
        (sender.representedObject as? JobBox)?.job
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func copyCommand(_ sender: NSMenuItem) {
        if let j = job(sender) { copy(j.fullCommand) }
    }

    @objc private func copyPID(_ sender: NSMenuItem) {
        if let pid = job(sender)?.pid { copy(String(pid)) }
    }

    @objc private func revealCwd(_ sender: NSMenuItem) {
        guard let cwd = job(sender)?.cwd else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
    }

    @objc private func terminate(_ sender: NSMenuItem) {
        guard let j = job(sender), let pid = j.pid else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Terminate this job?"
        alert.informativeText = "SIGTERM goes to the agent-lock wrapper (pid \(pid)), which forwards it to the command.\n\n" + (j.hasDescription ? "\(j.label)\n" : "") + j.command
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if kill(pid, SIGTERM) != 0 {
            let err = NSAlert()
            err.messageText = "Could not terminate pid \(pid)"
            err.informativeText = LockFiles.errorText()
            err.runModal()
        }
        refresh()
    }

    @objc private func setSlots(_ sender: NSMenuItem) {
        let n = sender.tag
        guard n != config.slots else { return }
        // The Perl script always uses slots 0-2 and doesn't know the rest of the protocol.
        let snapshot = reader.snapshot()
        let legacyActive = (snapshot.running + [snapshot.next].compactMap { $0 }).contains {
            if case .legacy = $0 { return true } else { return false }
        }
        if legacyActive && n != Config.defaultSlots {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Old agent-lock jobs are running"
            alert.informativeText = """
                Jobs started by the old Perl agent-lock always use 3 slots. Until they finish, \
                their exclusive jobs may overlap jobs on slots above 3.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Change to \(n)")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            try Config.saveSlots(n)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let err = NSAlert()
            err.messageText = "Could not save the slot count"
            err.informativeText = "\(error)"
            err.runModal()
            return
        }
        refresh()
        rebuildMenu()
    }

    @objc private func openStateFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: config.dir, isDirectory: true))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private final class JobBox: NSObject {
    let job: MenuModel.Job
    init(_ job: MenuModel.Job) { self.job = job }
}
