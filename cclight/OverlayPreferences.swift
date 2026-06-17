import Foundation

/// User-facing preferences for where the ambient overlay is drawn.
enum OverlayPreferences {
    private static let externalKey = "cclight.showOnExternalDisplays"

    /// Whether the ambient light is mirrored onto external (non-notched)
    /// displays as a centered top bar, in addition to the built-in notch.
    /// UserDefaults-backed; absent key → enabled (so the feature is on by
    /// default and a non-notch Mac still gets a bar). Changes take effect on
    /// the next overlay rebuild.
    static var showOnExternalDisplays: Bool {
        get {
            if UserDefaults.standard.object(forKey: externalKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: externalKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: externalKey) }
    }
}
