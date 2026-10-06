import SwiftUI

struct SettingsView: View {
    @ObservedObject var auth: GoogleAuthService

    let settings: AppSettings
    var onCredentialsChanged: () -> Void
    var onSignIn: () -> Void
    var onSignOut: () -> Void

    @State private var clientID: String = ""
    @State private var clientSecret: String = ""
    @State private var leadTimeMinutes: Int = 5
    @State private var playSound: Bool = true
    @State private var menuTitleMaxChars: Double = 28
    @State private var showSetupHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    accountRow
                } header: {
                    Text("Google Account")
                }

                Section {
                    TextField("Client ID", text: $clientID, prompt: Text("000000-abc.apps.googleusercontent.com"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: clientID) { _, newValue in
                            settings.clientID = newValue
                            onCredentialsChanged()
                        }

                    SecureField("Client Secret", text: $clientSecret, prompt: Text("Optional"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: clientSecret) { _, newValue in
                            settings.clientSecret = newValue
                            onCredentialsChanged()
                        }

                    DisclosureGroup("How do I get these?", isExpanded: $showSetupHelp) {
                        setupInstructions
                    }
                    .font(.callout)
                } header: {
                    Text("OAuth Client")
                } footer: {
                    Text("Meeting Minder talks to Google directly from your Mac using your own OAuth client. Nothing is sent anywhere else.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Warn me", selection: $leadTimeMinutes) {
                        ForEach([1, 2, 3, 5, 10, 15], id: \.self) { minutes in
                            Text("\(minutes) minutes before").tag(minutes)
                        }
                    }
                    .onChange(of: leadTimeMinutes) { _, newValue in settings.leadTimeMinutes = newValue }

                    Toggle("Play a sound with the alert", isOn: $playSound)
                        .onChange(of: playSound) { _, newValue in settings.playSound = newValue }

                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: $menuTitleMaxChars, in: 10...50, step: 1) {
                            Text("Menu bar title length")
                        } minimumValueLabel: {
                            Text("10").font(.caption2)
                        } maximumValueLabel: {
                            Text("50").font(.caption2)
                        }
                        .onChange(of: menuTitleMaxChars) { _, newValue in
                            settings.menuTitleMaxChars = Int(newValue)
                        }
                        Text("Truncate to \(Int(menuTitleMaxChars)) characters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Alerts")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: 580)
        .onAppear(perform: loadCurrentValues)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var accountRow: some View {
        switch auth.state {
        case .notConfigured:
            statusLine(symbol: "exclamationmark.circle.fill", tint: .orange,
                       title: "Add an OAuth client ID below to get started")

        case .signedOut:
            HStack {
                statusLine(symbol: "person.crop.circle.badge.xmark", tint: .secondary, title: "Not signed in")
                Spacer()
                Button("Sign in with Google…", action: onSignIn)
            }

        case .signingIn:
            HStack {
                ProgressView().controlSize(.small)
                Text("Finish signing in with the browser window…")
                Spacer()
                Button("Cancel") { auth.cancelSignIn() }
            }

        case .signedIn(let email):
            HStack {
                statusLine(symbol: "checkmark.circle.fill", tint: .green,
                           title: email ?? "Signed in to Google Calendar")
                Spacer()
                Button("Sign Out", action: onSignOut)
            }
        }

        if let error = auth.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusLine(symbol: String, tint: Color, title: String) -> some View {
        Label {
            Text(title).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }

    private var setupInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            instruction(1, "Open the Google Cloud Console and create (or pick) a project.")
            instruction(2, "Enable the Google Calendar API for that project.")
            instruction(3, "On the OAuth consent screen, choose External, add yourself as a Test user, and add the scope calendar.readonly.")
            instruction(4, "Under Credentials, create an OAuth client ID of type Desktop app.")
            instruction(5, "Paste the client ID (and secret, if shown) above.")

            Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                .font(.callout)
                .padding(.top, 2)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 6)
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).").monospacedDigit()
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadCurrentValues() {
        clientID = settings.clientID
        clientSecret = settings.clientSecret
        leadTimeMinutes = settings.leadTimeMinutes
        playSound = settings.playSound
        menuTitleMaxChars = Double(settings.menuTitleMaxChars)
    }
}
