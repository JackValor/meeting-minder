import Foundation

/// User-tunable configuration, persisted in `UserDefaults`.
///
/// The OAuth client ID/secret live here rather than being baked into the binary so
/// that each install can point at its own Google Cloud project.
final class AppSettings {
    static let shared = AppSettings()

    static let didChangeNotification = Notification.Name("MeetingMinderSettingsDidChange")

    private enum Key {
        static let clientID = "googleClientID"
        static let clientSecret = "googleClientSecret"
        static let leadTimeMinutes = "leadTimeMinutes"
        static let playSound = "playAlertSound"
        static let menuTitleMaxChars = "menuTitleMaxChars"
        static let ignoreDeclined = "ignoreDeclinedEvents"
        static let ignoreAllDay = "ignoreAllDayEvents"
        static let hasCompletedFirstRun = "hasCompletedFirstRun"
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.leadTimeMinutes: 5,
            Key.playSound: true,
            Key.menuTitleMaxChars: 28,
            Key.ignoreDeclined: true,
            Key.ignoreAllDay: true,
        ])
    }

    var clientID: String {
        get { (defaults.string(forKey: Key.clientID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), Key.clientID) }
    }

    /// Google issues a "secret" for Desktop clients but documents it as non-confidential.
    /// Optional: clients created with PKCE-only support can leave it blank.
    var clientSecret: String {
        get { (defaults.string(forKey: Key.clientSecret) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), Key.clientSecret) }
    }

    /// How long before an event starts the blocker appears.
    var leadTimeMinutes: Int {
        get { max(1, min(60, defaults.integer(forKey: Key.leadTimeMinutes))) }
        set { set(max(1, min(60, newValue)), Key.leadTimeMinutes) }
    }

    var playSound: Bool {
        get { defaults.bool(forKey: Key.playSound) }
        set { set(newValue, Key.playSound) }
    }

    var menuTitleMaxChars: Int {
        get { max(8, min(60, defaults.integer(forKey: Key.menuTitleMaxChars))) }
        set { set(max(8, min(60, newValue)), Key.menuTitleMaxChars) }
    }

    var ignoreDeclined: Bool {
        get { defaults.bool(forKey: Key.ignoreDeclined) }
        set { set(newValue, Key.ignoreDeclined) }
    }

    var ignoreAllDay: Bool {
        get { defaults.bool(forKey: Key.ignoreAllDay) }
        set { set(newValue, Key.ignoreAllDay) }
    }

    var hasCompletedFirstRun: Bool {
        get { defaults.bool(forKey: Key.hasCompletedFirstRun) }
        set { defaults.set(newValue, forKey: Key.hasCompletedFirstRun) }
    }

    var isConfigured: Bool { !clientID.isEmpty }

    private func set(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: AppSettings.didChangeNotification, object: nil)
    }
}
