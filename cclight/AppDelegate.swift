import AppKit
import SwiftUI
import CCLightCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: StateStore!
    private var overlayWindow: NotchOverlayWindow!
    private var overlayView: NotchOverlayView!
    private var menuBar: MenuBarController!
    /// Geometry of the overlay currently on screen, used to dedupe redundant
    /// rebuilds when screen-parameter notifications fire in bursts.
    private var currentNotchFrame: CGRect?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = StateStore()
        store.start()

        setupOverlay()
        // Follow the notch when displays change — plug/unplug an external
        // monitor, change the primary display, or alter resolution all post
        // this. setupOverlay() re-picks the notched screen each time.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // When the built-in display is unplugged (lid close / clamshell), AppKit
        // reparents our still-visible window onto a surviving display — the
        // external monitor — before the screen-parameters teardown runs. This
        // fires the instant that reparenting happens, so we can hide the orphan
        // before it flashes a stray ring on the external.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(overlayWindowChangedScreen),
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )

        menuBar = MenuBarController(store: store)
        menuBar.isLaunchAtLoginOn = { FirstRun.isLaunchAtLoginEnabled }
        menuBar.onInstallHooks = { [weak self] in self?.handleInstallHooks() }
        menuBar.onUninstallHooks = { [weak self] in self?.handleUninstallHooks() }
        menuBar.onToggleLaunchAtLogin = {
            FirstRun.setLaunchAtLogin(!FirstRun.isLaunchAtLoginEnabled)
        }
        menuBar.isPlaySoundsOn = { SoundPlayer.enabled }
        menuBar.onTogglePlaySounds = {
            SoundPlayer.enabled = !SoundPlayer.enabled
        }

        DispatchQueue.main.async { [weak self] in self?.runFirstRunIfNeeded() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
    }

    /// (Re)build the notch overlay on whichever connected display has a notch.
    /// Idempotent — tears down any existing overlay first, and is a no-op when
    /// the notch geometry is unchanged. If no notched display is attached the
    /// overlay is removed entirely (e.g. clamshell into an external monitor).
    private func setupOverlay() {
        // The notch lives on the built-in display, which may NOT be NSScreen.main
        // when an external monitor is the primary display. Prefer the first screen
        // that actually reports a notch.
        let notchedScreen = NSScreen.screens.first { NotchGeometry.notchRect(for: $0) != nil }
        guard let screen = notchedScreen,
              let notchRect = NotchGeometry.notchRect(for: screen) else {
            teardownOverlay(reason: "no notched display attached; overlay removed")
            return
        }
        // Skip the rebuild (and its flash) when nothing relevant moved.
        if currentNotchFrame == notchRect, overlayWindow != nil { return }
        // Geometry changed (or first build). Tear down the existing window FIRST —
        // an ordered-in NSWindow lives in NSApp.windows even after we drop our
        // reference, and would reappear when display coordinates shift back.
        teardownOverlay(reason: nil)
        currentNotchFrame = notchRect

        NSLog("cclight: notchRect=\(notchRect) on screen frame=\(screen.frame)")
        let frame = NotchGeometry.overlayWindowFrame(notchRect: notchRect, glowPadding: 90)
        let window = NotchOverlayWindow(contentRect: frame)
        let view = NotchOverlayView(notchSize: notchRect.size)
        window.contentView = view
        window.orderFrontRegardless()
        view.bindSessions(store.$orderedSessionStates)
        overlayWindow = window
        overlayView = view
        flashSelfTest()
    }

    @objc private func screenParametersChanged() {
        setupOverlay()
    }

    @objc private func overlayWindowChangedScreen() {
        guard let window = overlayWindow else { return }
        // Only tear down when we KNOW the window has been parked on a screen
        // with no notch (the orphan-reparent case). A transient nil screen
        // during our own setup must not trigger a false teardown.
        if let screen = window.screen, NotchGeometry.notchRect(for: screen) == nil {
            teardownOverlay(reason: "overlay reparented onto non-notched display; hiding")
        }
    }

    /// Hide, close, and release the current overlay window. Closing (not just
    /// dropping the reference) removes it from NSApp.windows so it can't be
    /// reparented back onto a display when coordinates shift.
    private func teardownOverlay(reason: String?) {
        if let reason, overlayWindow != nil { NSLog("cclight: \(reason)") }
        overlayWindow?.orderOut(nil)
        overlayWindow?.close()
        overlayWindow = nil
        overlayView = nil
        currentNotchFrame = nil
    }

    private func runFirstRunIfNeeded() {
        NSApp.activate(ignoringOtherApps: true)
        if FirstRun.claudeSettingsExists() {
            // Check whether cclight hooks are already present. We try the
            // bookmark-based path first; if no bookmark yet we do a best-effort
            // read from the standard location (may be denied in sandbox — in
            // that case we conservatively treat it as not-yet-installed and let
            // the user decide via the offer dialog, which will trigger the open
            // panel and grant access).
            let alreadyHasCCLight: Bool
            if let claudeDirURL = FirstRun.resolveClaudeAccess(),
               claudeDirURL.startAccessingSecurityScopedResource() {
                defer { claudeDirURL.stopAccessingSecurityScopedResource() }
                let settingsURL = claudeDirURL.appendingPathComponent("settings.json")
                alreadyHasCCLight = (try? Data(contentsOf: settingsURL))
                    .flatMap { String(data: $0, encoding: .utf8) }?
                    .contains(HookInstaller.marker) == true
            } else {
                alreadyHasCCLight = (try? Data(contentsOf: Paths.claudeSettingsFile))
                    .flatMap { String(data: $0, encoding: .utf8) }?
                    .contains(HookInstaller.marker) == true
            }
            if !alreadyHasCCLight {
                FirstRun.offerHooksInstall()
            }
        }
        if !FirstRun.isLaunchAtLoginEnabled {
            FirstRun.setLaunchAtLogin(true)
        }
    }

    private func handleInstallHooks() {
        if FirstRun.installHooks() {
            let alert = NSAlert()
            alert.messageText = "Hooks installed"
            alert.informativeText = "CCLight hooks added to ~/.claude/settings.json"
            alert.runModal()
        } else {
            let alert = NSAlert()
            alert.messageText = "Could not install hooks"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func handleUninstallHooks() {
        _ = FirstRun.uninstallHooks()
    }

    private func flashSelfTest() {
        guard let overlayView = overlayView else { return }
        overlayView.previewState(.working)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.overlayView?.previewState(self?.store.currentState ?? .idle)
        }
    }
}
