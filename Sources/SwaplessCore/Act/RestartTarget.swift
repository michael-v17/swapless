import Foundation

/// The code allowlist (§ J). This enum is the **only** input the actuator accepts: no API takes
/// a pid or a path from a rule. Processes are resolved from the current snapshot by exact
/// executable path + euid == getuid().
public enum RestartTarget: String, Sendable, CaseIterable, Hashable {
    /// WallpaperImageExtension (trigger) + WallpaperAgent (restart set).
    case wallpaper = "wallpaper"
    #if DEBUG
    /// The rig's own `swapless-leak-helper` at `SWAPLESS_RIG_HELPER_PATH` (DEBUG builds only).
    case rigHelper = "rig-helper"
    #endif

    public static let wallpaperExtensionPath =
        "/System/Library/ExtensionKit/Extensions/WallpaperImageExtension.appex/Contents/MacOS/WallpaperImageExtension"
    public static let wallpaperAgentPath =
        "/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent"
    public static let rigHelperBasename = "swapless-leak-helper"
}
