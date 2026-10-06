import AppKit
import Combine
import os
import SwiftUI

@main
enum MeetingMinderMain {
    /// Held for the process lifetime; `NSApplication.delegate` does not retain it.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        // Menu bar only — no Dock tile, no app switcher entry.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let settings = AppSettings.shared
    private lazy var auth = GoogleAuthService(settings: settings)
    private lazy var store = CalendarStore(auth: auth, settings: settings)
    private lazy var scheduler = AlertScheduler(store: store, settings: settings)
    private let presenter = AlertPresenter()
    private let settingsWindow = SettingsWindowController()
    private var statusItem: StatusItemController?
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Meeting Minder launching")

        let statusItem = StatusItemController(auth: auth, store: store, settings: settings)
        self.statusItem = statusItem

        wireMenu(statusItem)
        wireAlerts()
        observeState()

        scheduler.start()
        if auth.isSignedIn {
            store.start()
        }

        // `--preview-alert` shows a sample blocker straight away, for checking the
        // alert without waiting for a real meeting.
        if CommandLine.arguments.contains("--preview-alert") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.scheduler.showPreview()
            }
            return
        }

        if !settings.isConfigured || !settings.hasCompletedFirstRun {
            settings.hasCompletedFirstRun = true
            openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        scheduler.stop()
        store.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Wiring

    private func wireMenu(_ statusItem: StatusItemController) {
        statusItem.onSignIn = { [weak self] in self?.signIn() }
        statusItem.onSignOut = { [weak self] in self?.signOut() }
        statusItem.onOpenSettings = { [weak self] in self?.openSettings() }
        statusItem.onPreviewAlert = { [weak self] in self?.scheduler.showPreview() }
        statusItem.onRefresh = { [weak self] in self?.store.refresh() }

        store.onChange = { [weak self] in self?.statusItem?.refreshTitle() }
    }

    private func wireAlerts() {
        let actions = AlertActions(
            join: { [weak self] in self?.scheduler.joinCurrent() },
            dismiss: { [weak self] in self?.scheduler.dismissCurrent() },
            remind: { [weak self] option in self?.scheduler.remind(option) }
        )

        scheduler.onPresent = { [weak self] event in
            self?.presenter.present(event: event, actions: actions)
        }
        scheduler.onUpdate = { [weak self] event in
            self?.presenter.update(event: event)
        }
        scheduler.onHide = { [weak self] in
            self?.presenter.dismiss()
            self?.statusItem?.refreshTitle()
        }
    }

    private func observeState() {
        // `@Published` fires on willSet, so hop a cycle to read the settled value.
        auth.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.statusItem?.refreshTitle() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: AppSettings.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.auth.settingsChanged()
                self?.statusItem?.refreshTitle()
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    private func signIn() {
        Task { @MainActor in
            await auth.signIn()
            guard auth.isSignedIn else { return }
            store.reset()
            store.start()
            statusItem?.refreshTitle()
        }
    }

    private func signOut() {
        Task { @MainActor in
            await auth.signOut()
            store.stop()
            store.reset()
            statusItem?.refreshTitle()
        }
    }

    private func openSettings() {
        settingsWindow.show(rootView: SettingsView(
            auth: auth,
            settings: settings,
            onCredentialsChanged: { [weak self] in self?.auth.settingsChanged() },
            onSignIn: { [weak self] in self?.signIn() },
            onSignOut: { [weak self] in self?.signOut() }
        ))
    }
}
