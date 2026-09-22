import SwiftUI
import ZulipAPI

struct SignInView: View {
    @Environment(AppModel.self) private var model

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var realmURL: URL?
    @State private var settings: ServerSettings?
    @State private var checking = false
    @State private var lookupError: String?

    var body: some View {
        NavigationStack {
            Form {
                if let settings, let realmURL {
                    connected(settings, realmURL)
                } else {
                    addressEntry
                }
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var addressEntry: some View {
        Section {
            TextField("chat.example.com", text: $address)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { Task { await lookUp() } }

            Button {
                Task { await lookUp() }
            } label: {
                HStack {
                    Text("Continue")
                    if checking { Spacer(); ProgressView() }
                }
            }
            .disabled(address.isEmpty || checking)
        } header: {
            Text("Zulip server")
        } footer: {
            if let lookupError {
                Text(lookupError).foregroundStyle(.red)
            } else {
                Text("The address of your Zulip organization.")
            }
        }
    }

    @ViewBuilder
    private func connected(_ settings: ServerSettings, _ realmURL: URL) -> some View {
        Section {
            LabeledContent(settings.realm_name ?? "Zulip", value: realmURL.host() ?? "")
            Button("Use a different server") {
                self.settings = nil
                self.realmURL = nil
            }
            .font(.subheadline)
        }

        if settings.passwordAuthEnabled {
            Section {
                TextField(settings.usernameIsEmail ? "Email" : "Username", text: $username)
                    .textContentType(settings.usernameIsEmail ? .emailAddress : .username)
                    .keyboardType(settings.usernameIsEmail ? .emailAddress : .default)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Button("Sign in") {
                    Task { await model.signIn(realmURL: realmURL, username: username, password: password) }
                }
                .disabled(username.isEmpty || password.isEmpty || model.isWorking)
            } footer: {
                if let error = model.signInError {
                    Text(error).foregroundStyle(.red)
                }
            }
        }

        if !settings.externalMethods.isEmpty {
            Section("Or continue with") {
                ForEach(settings.externalMethods) { method in
                    Button(method.display_name) {
                        Task { await model.signInWithBrowser(realmURL: realmURL, method: method) }
                    }
                }
            }
        }
    }

    private func lookUp() async {
        checking = true
        lookupError = nil
        defer { checking = false }
        do {
            let (url, found) = try await model.serverSettings(for: address)
            realmURL = url
            settings = found
        } catch {
            lookupError = AppModel.describe(error)
        }
    }
}
