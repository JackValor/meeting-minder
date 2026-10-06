import AppKit
import ServiceManagement

/// Owns the menu bar item: the always-visible next-meeting text and the dropdown.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private static let upcomingLimit = 6
    private static let titleRefreshInterval: TimeInterval = 10

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let auth: GoogleAuthService
    private let store: CalendarStore
    private let settings: AppSettings
    private var titleTimer: Timer?

    var onSignIn: (() -> Void)?
    var onSignOut: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onPreviewAlert: (() -> Void)?
    var onRefresh: (() -> Void)?

    init(auth: GoogleAuthService, store: CalendarStore, settings: AppSettings = .shared) {
        self.auth = auth
        self.store = store
        self.settings = settings
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading

        refreshTitle()

        let timer = Timer(timeInterval: Self.titleRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTitle() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        titleTimer = timer
    }

    deinit {
        titleTimer?.invalidate()
    }

    // MARK: - Menu bar title

    func refreshTitle() {
        guard let button = statusItem.button else { return }

        guard case .signedIn = auth.state else {
            button.image = symbol(auth.state == .signingIn ? "calendar.badge.clock" : "calendar.badge.exclamationmark")
            button.attributedTitle = attributed(primary: auth.state == .signingIn ? " Signing in…" : " Sign in", secondary: nil)
            button.toolTip = "Meeting Minder — not connected to Google Calendar"
            return
        }

        button.image = symbol("calendar")

        let now = Date()
        guard let next = store.nextEvent(at: now) else {
            button.attributedTitle = attributed(primary: "", secondary: nil)
            button.toolTip = "Meeting Minder — no upcoming events"
            return
        }

        // Nothing is written into the menu bar until the meeting is within the hour — a
        // title parked there for something six hours away is noise. `compact` returns nil
        // beyond the hour and "now" for a meeting already under way, so it gates the title
        // and supplies the countdown in one go.
        guard let countdown = RelativeTime.compact(from: now, to: next.start) else {
            button.attributedTitle = attributed(primary: "", secondary: nil)
            button.toolTip = "Next: \(next.displayTitle)\n\(next.timeRangeDescription) · \(next.calendarTitle)"
            return
        }

        let title = next.displayTitle.truncated(to: settings.menuTitleMaxChars)
        button.attributedTitle = attributed(primary: " " + title, secondary: countdown)
        button.toolTip = "\(next.displayTitle)\n\(next.timeRangeDescription) · \(next.calendarTitle)"
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Meeting Minder")
        image?.isTemplate = true
        return image
    }

    /// The "in 17m" suffix. Deliberately greyer than the event title, but lifted well above
    /// `secondaryLabelColor` (~55% of the label colour), which reads as murky against a dark
    /// menu bar. Declared as an explicitly dynamic colour so it resolves per appearance
    /// rather than freezing whichever one happened to be active at launch.
    private static let suffixColor = NSColor(name: "MenuBarEventSuffix") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(white: 1.0, alpha: 0.60)   // lighter grey on the dark menu bar
            : NSColor(white: 0.0, alpha: 0.55)   // unchanged against a light menu bar
    }

    private func attributed(primary: String, secondary: String?) -> NSAttributedString {
        let font = NSFont.menuBarFont(ofSize: 0)
        let result = NSMutableAttributedString(string: primary, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])
        if let secondary {
            result.append(NSAttributedString(string: "  \(secondary)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize - 0.5, weight: .medium),
                .foregroundColor: Self.suffixColor,
            ]))
        }
        return result
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()

        switch auth.state {
        case .notConfigured:
            menu.addItem(header("Set up Google access to begin"))
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Settings…", keyEquivalent: ",") { [weak self] in
                self?.onOpenSettings?()
            })

        case .signedOut:
            menu.addItem(header("Not signed in"))
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Sign in with Google…") { [weak self] in
                self?.onSignIn?()
            })

        case .signingIn:
            menu.addItem(header("Waiting for Google in your browser…"))

        case .signedIn:
            addEventSection(to: menu, now: now)
        }

        if let error = auth.lastError ?? store.lastErrorMessage {
            menu.addItem(.separator())
            menu.addItem(header(error.truncated(to: 90), isWarning: true))
        }

        menu.addItem(.separator())

        if case .signedIn = auth.state {
            menu.addItem(ClosureMenuItem(title: "Refresh Now", keyEquivalent: "r") { [weak self] in
                self?.onRefresh?()
            })
        }
        menu.addItem(ClosureMenuItem(title: "Test Alert") { [weak self] in
            self?.onPreviewAlert?()
        })

        menu.addItem(.separator())

        let launchItem = ClosureMenuItem(title: "Launch at Login") { [weak self] in
            self?.toggleLaunchAtLogin()
        }
        launchItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(launchItem)

        if case .signedIn = auth.state {
            menu.addItem(ClosureMenuItem(title: "Settings…", keyEquivalent: ",") { [weak self] in
                self?.onOpenSettings?()
            })
            menu.addItem(ClosureMenuItem(title: "Sign Out") { [weak self] in
                self?.onSignOut?()
            })
        } else if case .notConfigured = auth.state {
            // Settings already offered above.
        } else {
            menu.addItem(ClosureMenuItem(title: "Settings…", keyEquivalent: ",") { [weak self] in
                self?.onOpenSettings?()
            })
        }

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit Meeting Minder", keyEquivalent: "q") {
            NSApp.terminate(nil)
        })
    }

    func menuWillOpen(_ menu: NSMenu) {
        onRefresh?()
    }

    private func addEventSection(to menu: NSMenu, now: Date) {
        let upcoming = store.upcoming(limit: Self.upcomingLimit, at: now)

        guard let next = upcoming.first else {
            menu.addItem(header("No upcoming events"))
            return
        }

        let relative = next.isInProgress(at: now)
            ? "In progress"
            : RelativeTime.description(from: now, to: next.start).capitalizedFirst
        menu.addItem(header("\(relative) · \(next.timeRangeDescription)"))
        menu.addItem(.separator())

        for event in upcoming {
            menu.addItem(eventItem(for: event, now: now))
        }

        if let email = auth.email {
            menu.addItem(.separator())
            menu.addItem(header(email))
        }
    }

    private func eventItem(for event: CalendarEvent, now: Date) -> NSMenuItem {
        let item = ClosureMenuItem(title: event.displayTitle) {
            if let link = event.meetingLink {
                NSWorkspace.shared.open(link.url)
            } else if let html = event.htmlLink {
                NSWorkspace.shared.open(html)
            }
        }

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none

        let time = Calendar.current.isDateInToday(event.start)
            ? formatter.string(from: event.start)
            : shortDate(event.start)

        let attributed = NSMutableAttributedString(
            string: time.paddedForMenu,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
                .foregroundColor: event.isInProgress(at: now) ? NSColor.systemGreen : NSColor.secondaryLabelColor,
            ])
        attributed.append(NSAttributedString(
            string: event.displayTitle.truncated(to: 44),
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor,
            ]))
        item.attributedTitle = attributed

        if let link = event.meetingLink {
            item.image = NSImage(systemSymbolName: link.provider.symbolName, accessibilityDescription: nil)
            item.image?.isTemplate = true
            item.toolTip = "Join \(link.provider.displayName): \(link.url.absoluteString)"
        } else if event.htmlLink != nil {
            item.toolTip = "Open in Google Calendar"
        } else {
            item.isEnabled = false
        }
        return item
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E HH:mm"
        return formatter.string(from: date)
    }

    private func header(_ text: String, isWarning: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
            .foregroundColor: isWarning ? NSColor.systemOrange : NSColor.secondaryLabelColor,
        ])
        return item
    }

    // MARK: - Launch at login

    private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

private extension String {
    /// Pads the leading time column so titles line up in the menu.
    var paddedForMenu: String {
        let target = 9
        return count >= target ? self + "  " : self + String(repeating: " ", count: target - count)
    }
}
