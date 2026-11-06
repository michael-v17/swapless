import ServiceManagement

/// `Open at login` via `SMAppService.mainApp`. The app ships the toggle; only the owner turns
/// it on (agents never install login items).
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Swapless: Open at login toggle failed: %@", error.localizedDescription)
        }
    }
}
