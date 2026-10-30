import AppKit
import ServiceManagement

/// Launch at login through `SMAppService.mainApp` (status `.requiresApproval` -> System Settings > Login Items; no LaunchAgent plist is ever written). On by default: the first
/// launch of an installed copy registers once (`applyDefaultOnce`), after that only the General toggle registers or unregisters, so turning it off sticks.
/// A bare executable (not inside an .app: tests, the command line) cannot register: state `.unavailable`.
@MainActor
enum LoginItem {
    enum State: Equatable { case enabled, disabled, requiresApproval, unavailable }

    /// `.notFound` is not "this Mac can't do login items" — SMAppService returns it for a bundle it has simply never been asked about before (every fresh
    /// install's first launch) as well as for one the person explicitly turned off in System Settings, so it means the same thing `.notRegistered` does:
    /// off, not unavailable. Treating it as `.unavailable` was the actual bug behind "open at login" never switching itself on: `applyDefaultOnce` only
    /// registers when `state == .disabled`, and a brand new copy's status is `.notFound`, so the one-shot default silently never ran.
    nonisolated static func state(for status: SMAppService.Status, bundled: Bool) -> State {
        guard bundled else { return .unavailable }
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .unavailable
        }
    }

    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var state: State { state(for: SMAppService.mainApp.status, bundled: isBundled) }

    /// Registers or unregisters; throws the system error. The setting mirror (`launchAtLogin`) follows the real state.
    static func set(enabled: Bool) throws {
        guard isBundled else { throw LoginItemError.notBundled }
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        let now = state == .enabled
        AppSettings.shared.update { $0.launchAtLogin = now }
    }
}

enum LoginItemError: Error { case notBundled }

extension LoginItem {
    /// The owner's default: Swamp Converter starts with the Mac. Runs once per settings file; a failure (a copy on a drive that is not mounted at login, a copy macOS
    /// refuses) just leaves it off, and General shows the real state with its toggle.
    static func applyDefaultOnce(settings: AppSettings = .shared) {
        guard isBundled, !settings.data.loginItemDefaultApplied else { return }
        settings.update { $0.loginItemDefaultApplied = true }
        let current = state
        // Registration is tracked system-wide by bundle identifier, not by this particular launch, so it can already be .enabled here (an earlier install
        // registered it and the person never turned it off) even though `set(enabled:)` was never called from this process. Either way, keep the settings
        // mirror honest instead of only updating it on the branch that actually calls register().
        settings.update { $0.launchAtLogin = (current == .enabled) }
        guard current == .disabled else { return }
        try? set(enabled: true)
    }
}
