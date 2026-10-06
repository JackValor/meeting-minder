import Foundation
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "MeetingMinder"

    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let calendar = Logger(subsystem: subsystem, category: "calendar")
    static let alerts = Logger(subsystem: subsystem, category: "alerts")
    static let app = Logger(subsystem: subsystem, category: "app")
}
