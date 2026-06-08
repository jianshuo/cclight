import AppKit
import ServiceManagement
import CCLightCore

/// Handles one-time install steps on first launch and exposes "Install Hooks"
/// as a re-runnable action.
enum FirstRun {

    // MARK: - Security-scoped bookmark for ~/.claude

    /// UserDefaults key for the persisted security-scoped bookmark covering
    /// the user's ~/.claude directory.
    private static let bookmarkKey = "ClaudeSettingsBookmark"

    /// Show an open panel scoped to ~/.claude so the user grants access. The
    /// returned URL is security-scoped — caller must call
    /// `startAccessingSecurityScopedResource` before reading/writing, and
    /// `stopAccessingSecurityScopedResource` after.
    static func promptForClaudeAccess() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "CCLight needs one-time access to your ~/.claude folder to install the Claude Code hooks."
        panel.prompt = "Grant Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        panel.directoryURL = claudeDir
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // Save bookmark for reuse across launches.
        if let data = try? url.bookmarkData(options: .withSecurityScope,
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        return url
    }

    /// Resolve the saved bookmark to a URL the app can read/write. Returns nil
    /// if the bookmark is missing or stale.
    static func resolveClaudeAccess() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale) else { return nil }
        if stale { return nil }
        return url
    }

    // MARK: - Hooks dialog

    /// Best-effort check: try the bookmark first; if unavailable fall back to a
    /// direct stat (which the sandbox may deny, giving false-negative, so we
    /// return false conservatively).
    static func claudeSettingsExists() -> Bool {
        if let claudeDirURL = resolveClaudeAccess() {
            guard claudeDirURL.startAccessingSecurityScopedResource() else {
                return FileManager.default.fileExists(atPath: Paths.claudeSettingsFile.path)
            }
            defer { claudeDirURL.stopAccessingSecurityScopedResource() }
            let settingsURL = claudeDirURL.appendingPathComponent("settings.json")
            return FileManager.default.fileExists(atPath: settingsURL.path)
        }
        return FileManager.default.fileExists(atPath: Paths.claudeSettingsFile.path)
    }

    /// Shows a modal dialog asking the user to install hooks. Returns whether
    /// the user agreed *and* the install succeeded.
    @discardableResult
    static func offerHooksInstall() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Install Claude Code Hooks?"
        alert.informativeText = """
        检测到 Claude Code (~/.claude/settings.json)。
        是否将 cclight 的 hooks 加入其中？
        原文件会备份到 settings.json.cclight-backup。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return false }
        return installHooks()
    }

    /// Patch ~/.claude/settings.json via a security-scoped bookmark. Shows the
    /// open panel on first call so the user grants access. Returns success.
    @discardableResult
    static func installHooks() -> Bool {
        let claudeDirURL: URL
        if let cached = resolveClaudeAccess() {
            claudeDirURL = cached
        } else if let granted = promptForClaudeAccess() {
            claudeDirURL = granted
        } else {
            return false
        }
        guard claudeDirURL.startAccessingSecurityScopedResource() else { return false }
        defer { claudeDirURL.stopAccessingSecurityScopedResource() }
        let settingsURL = claudeDirURL.appendingPathComponent("settings.json")
        do {
            try HookInstaller.install(
                settingsURL: settingsURL,
                binaryPath: "/Applications/CCLight.app/Contents/MacOS/cclightcli"
            )
            return true
        } catch {
            NSLog("cclight installHooks failed: \(error)")
            return false
        }
    }

    @discardableResult
    static func uninstallHooks() -> Bool {
        guard let claudeDirURL = resolveClaudeAccess() else { return false }
        guard claudeDirURL.startAccessingSecurityScopedResource() else { return false }
        defer { claudeDirURL.stopAccessingSecurityScopedResource() }
        let settingsURL = claudeDirURL.appendingPathComponent("settings.json")
        do {
            try HookInstaller.uninstall(settingsURL: settingsURL)
            return true
        } catch {
            NSLog("cclight uninstallHooks failed: \(error)")
            return false
        }
    }

    // MARK: - Launch at Login

    static var isLaunchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    static func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("cclight setLaunchAtLogin failed: \(error)")
            }
        }
    }
}
