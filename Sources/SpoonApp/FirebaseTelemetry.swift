import AppKit
import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics

enum TelemetryPreferences {
    static let consentDecidedKey = "privacy.technicalDataCollectionDecided"
    static let collectionEnabledKey = "privacy.technicalDataCollectionEnabled"
}

@MainActor
final class SpoonApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        FirebaseTelemetry.shared.start()
    }
}

@MainActor
final class FirebaseTelemetry {
    static let shared = FirebaseTelemetry()

    private let defaults = UserDefaults.standard

    private init() {}

    func start() {
        if defaults.bool(forKey: TelemetryPreferences.consentDecidedKey) {
            applyCollectionSetting(defaults.bool(forKey: TelemetryPreferences.collectionEnabledKey))
            return
        }

        presentConsentAlert()
    }

    func updateConsent(enabled: Bool) {
        defaults.set(enabled, forKey: TelemetryPreferences.collectionEnabledKey)
        defaults.set(true, forKey: TelemetryPreferences.consentDecidedKey)
        applyCollectionSetting(enabled)
    }

    private func applyCollectionSetting(_ enabled: Bool) {
        if enabled {
            configureFirebaseIfNeeded()
            Analytics.setAnalyticsCollectionEnabled(true)
            Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
            Crashlytics.crashlytics().sendUnsentReports()
            return
        }

        guard FirebaseApp.app() != nil else { return }
        Analytics.setAnalyticsCollectionEnabled(false)
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(false)
        Crashlytics.crashlytics().deleteUnsentReports()
    }

    private func configureFirebaseIfNeeded() {
        guard FirebaseApp.app() == nil else { return }
        FirebaseApp.configure()
    }

    private func presentConsentAlert() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = String(localized: "Help Improve Spoon")
        alert.informativeText = String(localized: "Allow Spoon to collect technical usage analytics and crash reports? This data helps us improve reliability. Repository contents, file contents, credentials, and commit messages are never collected. You can change this choice at any time in Settings.")

        alert.addButton(withTitle: String(localized: "Allow"))
        let denyButton = alert.addButton(withTitle: String(localized: "Don't Allow"))
        denyButton.keyEquivalent = "\u{1b}"

        updateConsent(enabled: alert.runModal() == .alertFirstButtonReturn)
    }
}
