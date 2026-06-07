import AppKit
import Combine
import CCLightCore

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Owns the menu-bar status item: a tinted dot whose color tracks the merged
/// state, and a menu with the install/uninstall hooks actions.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private weak var store: StateStore?
    private var subs: Set<AnyCancellable> = []

    var onInstallHooks: (() -> Void)?
    var onUninstallHooks: (() -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var isLaunchAtLoginOn: () -> Bool = { false }
    var onTogglePlaySounds: (() -> Void)?
    var isPlaySoundsOn: () -> Bool = { false }

    init(store: StateStore) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.store = store
        super.init()

        setupButtonIcon(state: .idle)
        setupMenu()

        store.$currentState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.setupButtonIcon(state: state) }
            .store(in: &subs)

        store.$orderedSessionStates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMenu() }
            .store(in: &subs)
    }

    private func setupButtonIcon(state: MergedState) {
        guard let button = statusItem.button else { return }
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let dotRect = NSRect(x: 3, y: 3, width: 8, height: 8)
            switch state {
            case .working:   NSColor(red: 255/255, green: 176/255, blue: 0/255, alpha: 1).setFill()
            case .waiting:   NSColor(red: 95/255, green: 207/255, blue: 122/255, alpha: 1).setFill()
            case .attention: NSColor(red: 95/255, green: 207/255, blue: 122/255, alpha: 1).setFill()
            case .idle:      NSColor.white.setFill()
            }
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = false
        button.image = image
    }

    private func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshMenu()
    }

    private func refreshMenu() {
        guard let menu = statusItem.menu, let store = store else { return }
        menu.removeAllItems()

        // Per-session rows with colored dots. Capped at 4 by StateStore.
        let states = store.orderedSessionStates
        let ids = store.orderedSessionIds
        let cwds = store.orderedSessionCwds
        if states.isEmpty {
            let idle = NSMenuItem(title: "  No active sessions", action: nil, keyEquivalent: "")
            idle.isEnabled = false
            menu.addItem(idle)
        } else {
            let header = NSMenuItem(title: "Sessions (\(states.count))", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (i, state) in states.enumerated() {
                let name = Self.displayName(cwd: cwds[safe: i] ?? nil, id: ids[safe: i])
                let label = "\(name) — \(Self.label(for: state))"
                let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.image = Self.dotImage(forSessionState: state)
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        // Hooks submenu (install / uninstall).
        let hooksItem = NSMenuItem(title: "Hooks", action: nil, keyEquivalent: "")
        let hooksSubmenu = NSMenu()
        let installItem = NSMenuItem(
            title: "Install Claude Code Hooks",
            action: #selector(installHooks),
            keyEquivalent: ""
        )
        installItem.target = self
        hooksSubmenu.addItem(installItem)
        let uninstallItem = NSMenuItem(
            title: "Uninstall Claude Code Hooks",
            action: #selector(uninstallHooks),
            keyEquivalent: ""
        )
        uninstallItem.target = self
        hooksSubmenu.addItem(uninstallItem)
        hooksItem.submenu = hooksSubmenu
        menu.addItem(hooksItem)

        menu.addItem(.separator())

        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = isLaunchAtLoginOn() ? .on : .off
        menu.addItem(launchItem)

        let soundsItem = NSMenuItem(
            title: "Play Sounds",
            action: #selector(togglePlaySounds),
            keyEquivalent: ""
        )
        soundsItem.target = self
        soundsItem.state = isPlaySoundsOn() ? .on : .off
        menu.addItem(soundsItem)

        let about = NSMenuItem(title: "About CCLight", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Pick a human-readable display name. Prefer the cwd's last path component
    /// (e.g. `cclight` for `/Users/x/code/cclight`); fall back to the
    /// short session id.
    private static func displayName(cwd: String?, id: String?) -> String {
        if let cwd = cwd, !cwd.isEmpty {
            let base = (cwd as NSString).lastPathComponent
            if !base.isEmpty { return base }
        }
        return String(id?.prefix(8) ?? "?")
    }

    private static func dotImage(forSessionState state: MergedState) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { _ in
            let dotRect = NSRect(x: 2, y: 2, width: 8, height: 8)
            // Use the same palette as the notch glow so the menu reads as
            // the same status surface.
            switch state {
            case .working:
                NSColor(red: 255/255, green: 176/255, blue: 0/255, alpha: 1).setFill()
            case .waiting:
                NSColor(red: 95/255, green: 207/255, blue: 122/255, alpha: 1).setFill()
            case .attention:
                NSColor(red: 95/255, green: 207/255, blue: 122/255, alpha: 1).setFill()
            case .idle:
                NSColor.white.setFill()
            }
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func label(for state: MergedState) -> String {
        switch state {
        case .working:   return "working"
        case .waiting:   return "waiting"
        case .attention: return "needs you"
        case .idle:      return "idle"
        }
    }

    // MARK: - Actions

    @objc private func installHooks() { onInstallHooks?() }
    @objc private func uninstallHooks() { onUninstallHooks?() }
    @objc private func toggleLaunchAtLogin() { onToggleLaunchAtLogin?() }
    @objc private func togglePlaySounds() { onTogglePlaySounds?() }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) { refreshMenu() }
}
