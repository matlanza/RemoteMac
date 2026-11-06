import Foundation
import Combine
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var statusText = "Checking…"
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false

    private let service = SMAppService.mainApp

    func refresh() {
        switch service.status {
        case .enabled:
            isEnabled = true
            requiresApproval = false
            statusText = "Launch at login enabled"

        case .requiresApproval:
            isEnabled = false
            requiresApproval = true
            statusText = "Approval required in System Settings"

        case .notRegistered:
            isEnabled = false
            requiresApproval = false
            statusText = "Launch at login disabled"

        case .notFound:
            isEnabled = false
            requiresApproval = false
            statusText = "Launch at login disabled"

        @unknown default:
            isEnabled = false
            requiresApproval = false
            statusText = "Unknown login-item state"
        }
    }

    func enable() {
        do {
            if service.status != .enabled {
                try service.register()
            }
        } catch {
            statusText =
                "Could not enable launch at login: \(error.localizedDescription)"
        }

        refresh()
    }

    func disable() {
        do {
            try service.unregister()
        } catch {
            statusText =
                "Could not disable launch at login: \(error.localizedDescription)"
        }

        refresh()
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
