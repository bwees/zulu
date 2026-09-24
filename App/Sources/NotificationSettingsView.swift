import SwiftUI
import UserNotifications

/// Point the app at a zulu-notifyd, see whether it is watching this account, and send
/// a push to prove the whole path works.
struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(NotificationServiceSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var urlDraft = ""
    @State private var urlError: String?

    var body: some View {
        NavigationStack {
            Form {
                serviceSection
                deviceSection
                if settings.canTalkToService {
                    statusSection
                    testSection
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task {
                urlDraft = settings.serviceURL?.absoluteString ?? ""
                await settings.refreshPermission()
                await settings.refreshStatus()
            }
        }
    }

    private var serviceSection: some View {
        Section {
            TextField("https://notify.example.com", text: $urlDraft)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(saveURL)
            Button("Save", action: saveURL)
                .disabled(urlDraft == (settings.serviceURL?.absoluteString ?? ""))
        } header: {
            Text("Service URL")
        } footer: {
            if let urlError {
                Text(urlError).foregroundStyle(.red)
            } else {
                Text("Leave empty to turn push notifications off.")
            }
        }
    }

    private var deviceSection: some View {
        Section("This device") {
            LabeledContent("Permission", value: permissionLabel)
            LabeledContent("APNs token", value: settings.deviceToken == nil ? "None yet" : "Received")
            LabeledContent("Registration") { registrationLabel }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            switch settings.status {
            case .idle:
                EmptyView()
            case .running:
                ProgressView()
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            case .done(let status):
                LabeledContent("Account", value: status.accountStatus)
                if let detail = status.statusDetail, !detail.isEmpty {
                    LabeledContent("Detail", value: detail)
                }
                LabeledContent("Watching Zulip", value: status.queueConnected ? "Yes" : "No")
                if status.parked {
                    LabeledContent("Parked until", value: Self.describe(status.parkedUntil))
                }
                LabeledContent("Last event", value: Self.describe(status.lastEventAt))
                LabeledContent("Devices", value: "\(status.devices)")
                if let lastError = status.lastError, !lastError.isEmpty {
                    LabeledContent("Last error", value: lastError)
                }
            }
        } header: {
            HStack {
                Text("Service status")
                Spacer()
                Button("Refresh") { Task { await settings.refreshStatus() } }
                    .font(.caption)
            }
        }
    }

    private var testSection: some View {
        Section {
            Button("Send test notification") { Task { await settings.sendTest() } }
                .disabled(settings.test.isRunning)
        } footer: {
            switch settings.test {
            case .idle:
                EmptyView()
            case .running:
                Text("Sending…")
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            case .done(let receipt) where receipt.sent:
                Text("APNs accepted it. It should arrive in a second or two.")
            case .done(let receipt):
                Text("APNs refused it: \(receipt.statusCode) \(receipt.reason ?? "")")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var registrationLabel: some View {
        switch settings.registration {
        case .unconfigured:
            Text(settings.serviceURL == nil ? "Off" : "Not registered")
        case .waitingForDeviceToken:
            Text("Waiting for APNs")
        case .registering:
            ProgressView()
        case .registered:
            Text("Registered")
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        }
    }

    private var permissionLabel: String {
        switch settings.permission {
        case .authorized: "Allowed"
        case .denied: "Denied in Settings"
        case .provisional, .ephemeral: "Quiet delivery"
        case .notDetermined: "Not asked"
        @unknown default: "Unknown"
        }
    }

    private func saveURL() {
        let draft = urlDraft
        Task {
            do {
                try await settings.setServiceURL(draft, account: model.account)
                urlError = nil
                await settings.refreshStatus()
            } catch {
                urlError = error.localizedDescription
            }
        }
    }

    /// Go sends an unset time as year 1 instead of leaving the field out.
    private static func describe(_ date: Date?) -> String {
        guard let date, date.timeIntervalSince1970 > 0 else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }
}

private extension NotificationServiceSettings.Check {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
