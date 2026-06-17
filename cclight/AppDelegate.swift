import AppKit
import SwiftUI
import CCLightCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: StateStore!
    private var menuBar: MenuBarController!

    /// One overlay per display we're currently lighting. Keyed by
    /// CGDirectDisplayID so we can reconcile against the live display set on
    /// every screen-parameters change (plug/unplug, primary swap, resolution).
    /// `frame` is the overlay window's frame, kept for dedup so a burst of
    /// notifications that doesn't actually move anything is a no-op.
    private struct Overlay {
        let window: NotchOverlayWindow
        let view: NotchOverlayView
        let displayID: CGDirectDisplayID
        let frame: CGRect
    }
    private var overlays: [CGDirectDisplayID: Overlay] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = StateStore()
        store.start()

        setupOverlays()
        // Follow displays when they change — plug/unplug an external monitor,
        // change the primary display, or alter resolution all post this.
        // setupOverlays() reconciles the overlay set against the live screens.
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
        menuBar.isShowOnExternalOn = { OverlayPreferences.showOnExternalDisplays }
        menuBar.onToggleShowOnExternal = { [weak self] in
            OverlayPreferences.showOnExternalDisplays.toggle()
            self?.setupOverlays()
        }

        DispatchQueue.main.async { [weak self] in self?.runFirstRunIfNeeded() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
    }

    /// The shape + window frame we want to draw on a given display.
    private struct DesiredOverlay {
        let shape: OverlayShape
        let frame: CGRect
    }

    /// Compute the overlay we want on each connected display:
    /// - The built-in notched display gets the U-shape (it may NOT be
    ///   `NSScreen.main` when an external is primary, so we detect it by notch).
    /// - Every other (non-notched) display gets a centered top bar, but only
    ///   when "Show on External Monitors" is enabled.
    /// A Mac with no notch (e.g. desktop, older laptop) therefore lights all
    /// its displays with bars when the toggle is on, and nothing when off.
    private func desiredOverlays() -> [CGDirectDisplayID: DesiredOverlay] {
        var desired: [CGDirectDisplayID: DesiredOverlay] = [:]
        let showExternal = OverlayPreferences.showOnExternalDisplays
        for screen in NSScreen.screens {
            guard let id = displayID(of: screen) else { continue }
            if let notchRect = NotchGeometry.notchRect(for: screen) {
                let shape = OverlayShape.notch(notchRect.size)
                let frame = NotchGeometry.overlayWindowFrame(notchRect: notchRect, glowPadding: shape.glowPadding)
                desired[id] = DesiredOverlay(shape: shape, frame: frame)
            } else if showExternal {
                let width = NotchGeometry.topBarWidth(for: screen)
                let barRect = NotchGeometry.topBarRect(for: screen, width: width)
                let shape = OverlayShape.bar(width: width)
                let frame = NotchGeometry.overlayWindowFrame(notchRect: barRect, glowPadding: shape.glowPadding)
                desired[id] = DesiredOverlay(shape: shape, frame: frame)
            }
        }
        return desired
    }

    /// Reconcile the live overlay windows against `desiredOverlays()`.
    /// Idempotent: displays whose desired frame is unchanged keep their existing
    /// window (no flash); displays that appeared/moved are (re)built; displays
    /// that vanished or were disabled are torn down. Safe to call on launch and
    /// on every screen-parameters / preference change.
    private func setupOverlays() {
        let desired = desiredOverlays()

        // Tear down overlays that are no longer wanted, or whose geometry moved.
        for (id, overlay) in overlays {
            if let d = desired[id], d.frame == overlay.frame { continue }
            teardownOverlay(displayID: id, reason: "display \(id) overlay removed/moved")
        }

        // Build overlays that are newly wanted (or were just torn down for a move).
        for (id, d) in desired where overlays[id] == nil {
            buildOverlay(displayID: id, shape: d.shape, frame: d.frame)
        }
    }

    private func buildOverlay(displayID id: CGDirectDisplayID, shape: OverlayShape, frame: CGRect) {
        NSLog("cclight: building overlay on display=\(id) shape=\(shape) frame=\(frame)")
        let window = NotchOverlayWindow(contentRect: frame)
        let view = NotchOverlayView(shape: shape)
        window.contentView = view
        // Record before ordering in: didChangeScreenNotification can fire
        // synchronously as the window lands on its screen, and the handler
        // looks the window up in `overlays`.
        overlays[id] = Overlay(window: window, view: view, displayID: id, frame: frame)
        window.orderFrontRegardless()
        view.bindSessions(store.$orderedSessionStates)
        flashSelfTest(view: view)
    }

    @objc private func screenParametersChanged() {
        setupOverlays()
    }

    @objc private func overlayWindowChangedScreen(_ note: Notification) {
        guard let window = note.object as? NotchOverlayWindow,
              let overlay = overlays.first(where: { $0.value.window === window })?.value else { return }
        // AppKit reparents a still-visible window onto a surviving display when
        // its own display is pulled (e.g. lid close into clamshell), before the
        // screen-parameters teardown runs — which would flash a stray overlay on
        // the wrong screen. If the window has moved off the display we built it
        // for, drop it now; setupOverlays() will rebuild correctly. A transient
        // nil screen during our own setup must not trigger a false teardown.
        if let currentID = window.screen.flatMap(displayID(of:)), currentID != overlay.displayID {
            teardownOverlay(displayID: overlay.displayID, reason: "overlay reparented display \(overlay.displayID)→\(currentID); hiding")
        }
    }

    /// Hide, close, and release one display's overlay window. Closing (not just
    /// dropping the reference) removes it from NSApp.windows so it can't be
    /// reparented back onto a display when coordinates shift.
    private func teardownOverlay(displayID id: CGDirectDisplayID, reason: String?) {
        guard let overlay = overlays.removeValue(forKey: id) else { return }
        if let reason { NSLog("cclight: \(reason)") }
        overlay.window.orderOut(nil)
        overlay.window.close()
    }

    /// CGDirectDisplayID backing an NSScreen, the stable key we reconcile on.
    private func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
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

    private func flashSelfTest(view: NotchOverlayView) {
        view.previewState(.working)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak view] in
            view?.previewState(self?.store.currentState ?? .idle)
        }
    }
}
