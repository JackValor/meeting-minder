import Combine
import SwiftUI

struct AlertActions {
    var join: () -> Void
    var dismiss: () -> Void
    var remind: (ReminderPolicy.Option) -> Void
}

/// Drives the live countdown on the blocker.
@MainActor
final class AlertViewModel: ObservableObject {
    @Published var event: CalendarEvent
    @Published private(set) var now: Date = Date()

    let actions: AlertActions
    private var timer: Timer?

    init(event: CalendarEvent, actions: AlertActions) {
        self.event = event
        self.actions = actions

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

struct AlertView: View {
    @ObservedObject var model: AlertViewModel
    @State private var hasAppeared = false

    private var secondsUntilStart: TimeInterval {
        model.event.start.timeIntervalSince(model.now)
    }

    /// The accent warms up as the meeting gets closer, then turns red once it has begun.
    private var accent: Color {
        if secondsUntilStart <= 0 { return Color(red: 0.99, green: 0.35, blue: 0.36) }
        if secondsUntilStart <= 120 { return Color(red: 1.00, green: 0.71, blue: 0.24) }
        return Color(red: 0.39, green: 0.63, blue: 1.00)
    }

    private var reminderOptions: [ReminderPolicy.Option] {
        ReminderPolicy.availableOptions(start: model.event.start, now: model.now)
    }

    /// Only meaningful when there is something to join and the join would be an early one.
    private var showsEarlyJoinHint: Bool {
        model.event.meetingLink != nil
            && ReminderPolicy.shouldRemindAfterEarlyJoin(start: model.event.start, now: model.now)
    }

    private var startTimeText: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: model.event.start)
    }

    private var headlineText: String {
        secondsUntilStart > 0
            ? "Starts in \(RelativeTime.countdown(from: model.now, to: model.event.start))"
            : RelativeTime.description(from: model.now, to: model.event.start).capitalizedFirst
    }

    var body: some View {
        ZStack {
            backdrop
            card
                .frame(maxWidth: 760)
                .padding(48)
                .scaleEffect(hasAppeared ? 1 : 0.96)
                .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { hasAppeared = true }
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.05, blue: 0.08),
                         Color(red: 0.07, green: 0.08, blue: 0.13)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [accent.opacity(0.28), .clear],
                center: .center, startRadius: 40, endRadius: 620
            )
            .animation(.easeInOut(duration: 0.6), value: accent)
        }
        .ignoresSafeArea()
    }

    // MARK: - Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            titleBlock
            detailBlock
            Divider().overlay(Color.white.opacity(0.10))
            buttons
                .animation(.easeInOut(duration: 0.25), value: reminderOptions)
                .animation(.easeInOut(duration: 0.25), value: showsEarlyJoinHint)
        }
        .padding(44)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color(red: 0.09, green: 0.10, blue: 0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.55), radius: 44, y: 18)
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: secondsUntilStart <= 0 ? "exclamationmark.triangle.fill" : "bell.badge.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(accent)

            Text(headlineText)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .monospacedDigit()
                .contentTransition(.numericText())

            Spacer(minLength: 16)

            Text(model.event.calendarTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var titleBlock: some View {
        Text(model.event.displayTitle)
            .font(.system(size: 46, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(3)
            .minimumScaleFactor(0.55)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var detailBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            detailRow(icon: "clock", text: model.event.timeRangeDescription)

            if let location = model.event.location {
                detailRow(icon: "mappin.and.ellipse", text: location)
            }
            if model.event.attendeeCount > 1 {
                detailRow(icon: "person.2", text: "\(model.event.attendeeCount) guests")
            }
            if let link = model.event.meetingLink {
                detailRow(icon: link.provider.symbolName, text: link.provider.displayName)
            }
        }
    }

    private func detailRow(icon: String, text: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 20, alignment: .center)
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.80))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Buttons

    private var buttons: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                if let link = model.event.meetingLink {
                    Button(action: model.actions.join) {
                        Label(link.provider.joinButtonTitle, systemImage: "video.fill")
                    }
                    .buttonStyle(AlertButtonStyle(kind: .primary, accent: accent))
                    .keyboardShortcut(.defaultAction)
                }

                Button("Dismiss", action: model.actions.dismiss)
                    .buttonStyle(AlertButtonStyle(kind: model.event.meetingLink == nil ? .primary : .secondary, accent: accent))
                    .keyboardShortcut(.cancelAction)

                Spacer(minLength: 0)
            }

            // Each option drops away once the meeting is too close for it to land ahead.
            if !reminderOptions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(reminderOptions, id: \.self) { option in
                        Button(option.buttonTitle) { model.actions.remind(option) }
                            .buttonStyle(AlertButtonStyle(kind: .subtle, accent: accent))
                    }
                    Spacer(minLength: 0)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
            }

            if showsEarlyJoinHint {
                Label("Joining now? You'll be reminded again at \(startTimeText).",
                      systemImage: "arrow.trianglehead.counterclockwise")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .transition(.opacity)
            }
        }
    }
}

private struct AlertButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, subtle }

    let kind: Kind
    let accent: Color

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: kind == .subtle ? 14 : 16, weight: .semibold, design: .rounded))
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .subtle ? 16 : 26)
            .padding(.vertical, kind == .subtle ? 9 : 14)
            .background(
                RoundedRectangle(cornerRadius: kind == .subtle ? 10 : 14, style: .continuous)
                    .fill(background(pressed: configuration.isPressed))
                    .overlay(
                        RoundedRectangle(cornerRadius: kind == .subtle ? 10 : 14, style: .continuous)
                            .stroke(Color.white.opacity(kind == .primary ? 0 : 0.16), lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { isHovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Color(red: 0.06, green: 0.07, blue: 0.10)
        case .secondary, .subtle: return .white.opacity(0.88)
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary:
            return accent.opacity(pressed ? 0.82 : (isHovering ? 1.0 : 0.94))
        case .secondary:
            return Color.white.opacity(pressed ? 0.18 : (isHovering ? 0.14 : 0.09))
        case .subtle:
            return Color.white.opacity(pressed ? 0.16 : (isHovering ? 0.12 : 0.06))
        }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
