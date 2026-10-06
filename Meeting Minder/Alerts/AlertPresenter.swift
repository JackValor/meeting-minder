import AppKit
import SwiftUI

/// A borderless window that sits above everything — including full-screen apps and the
/// menu bar — and can take keyboard focus despite having no title bar.
final class BlockerWindow: NSWindow {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Puts the blocker on every attached display and tears it down again.
@MainActor
final class AlertPresenter {

    private var windows: [BlockerWindow] = []
    private var model: AlertViewModel?

    var isPresenting: Bool { !windows.isEmpty }

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Presentation

    func present(event: CalendarEvent, actions: AlertActions) {
        dismiss()

        let model = AlertViewModel(event: event, actions: actions)
        self.model = model
        buildWindows(for: model, onCancel: actions.dismiss)

        // An accessory app still needs to steal focus for the blocker to be usable.
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
    }

    /// Refreshes the displayed details in place when the underlying event changes.
    func update(event: CalendarEvent) {
        model?.event = event
    }

    func dismiss() {
        model?.stop()
        model = nil
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
    }

    // MARK: - Windows

    private func buildWindows(for model: AlertViewModel, onCancel: @escaping () -> Void) {
        for screen in NSScreen.screens {
            let window = BlockerWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.onCancel = onCancel
            // Above the screen saver so nothing — including full-screen video — covers it.
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.isMovable = false
            window.animationBehavior = .none
            window.contentView = NSHostingView(rootView: AlertView(model: model))
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    @objc private func screensChanged() {
        // Rebuild so a newly attached display is covered too.
        guard let model, isPresenting else { return }
        let onCancel = model.actions.dismiss
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
        buildWindows(for: model, onCancel: onCancel)
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
    }
}
