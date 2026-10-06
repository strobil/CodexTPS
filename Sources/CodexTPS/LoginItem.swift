import Observation
import OSLog
import ServiceManagement

private let log = Logger(subsystem: "local.codex-tps", category: "login-item")

@MainActor
@Observable
final class LoginItem {
    private(set) var status = SMAppService.mainApp.status
    private(set) var error: String?

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func toggle() {
        do {
            if isOn {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            error = nil
        } catch {
            log.error("login item: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
        refresh()
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
