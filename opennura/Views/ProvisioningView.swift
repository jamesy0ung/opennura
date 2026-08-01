import SwiftUI

/// Sign in to a Nura account and recover the connected headphone's device key
/// via backend-assisted provisioning.
struct ProvisioningView: View {
    @ObservedObject var device: NuraDeviceManager
    @ObservedObject var provisioning: NuraProvisioningManager
    @Environment(\.dismiss) private var dismiss

    @State private var email: String = ""
    @State private var code: String = ""
    @State private var errorText: String?

    var body: some View {
        Group {
        #if os(iOS)
            phoneBody
        #else
            desktopBody
        #endif
        }
        .onChange(of: device.recoveredDeviceSerial) { serial in
            guard serial != nil else { return }
            Task { @MainActor in
                // Show the saved confirmation before returning to controls.
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            }
        }
        .onDisappear {
            device.clearRecoveredDeviceResult()
        }
    }

    #if os(iOS)
    private var phoneBody: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    recoveryHero
                    recoverySteps

                    if let serial = device.recoveredDeviceSerial {
                        phoneSuccess(serial: serial)
                    } else {
                        switch provisioning.authStep {
                        case .loggedOut:
                            phoneEmailStep
                        case .codeSent(let sentTo):
                            phoneCodeStep(sentTo: sentTo)
                        case .loggedIn(let account):
                            phoneRecoveryStep(account: account)
                        }
                    }

                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                    }

                    if provisioning.isBusy || !provisioning.status.isEmpty || !device.phase.isIdle {
                        phoneStatus
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 36)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Retrieve device key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear {
            if email.isEmpty { email = provisioning.userEmail ?? "" }
        }
    }

    private var recoveryHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 58, height: 58)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 17))
            Text("Retrieve device key")
                .font(.title.bold())
            Text("Sign in to retrieve the device key for your Nuraphone. It stays saved on this device.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recoverySteps: some View {
        HStack(spacing: 0) {
            stepMarker(number: 1, title: "Sign in", complete: isSignedIn || isRecovered)
            stepLine(complete: isSignedIn || isRecovered)
            stepMarker(number: 2, title: "Prepare", complete: isRecovered)
            stepLine(complete: isRecovered)
            stepMarker(number: 3, title: "Retrieve", complete: isRecovered)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Retrieval progress")
    }

    private var isSignedIn: Bool {
        if case .loggedIn = provisioning.authStep { return true }
        return false
    }

    private var isRecovered: Bool {
        device.recoveredDeviceSerial != nil
    }

    private func stepMarker(number: Int, title: String, complete: Bool) -> some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(complete ? Color.accentColor : Color.accentColor.opacity(0.13))
                if complete {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .font(.caption.bold())
            .frame(width: 28, height: 28)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func stepLine(complete: Bool) -> some View {
        Rectangle()
            .fill(complete ? Color.accentColor : Color.secondary.opacity(0.20))
            .frame(height: 2)
            .padding(.horizontal, 6)
            .offset(y: -10)
    }

    private var phoneEmailStep: some View {
        phonePanel(title: "Sign in to Nura", icon: "envelope") {
            Text("Use the email attached to your Nuraphone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Email address", text: $email)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .disableAutocorrection(true)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            primaryButton("Send login code", icon: "arrow.right") {
                run { try await provisioning.requestEmailCode(email) }
            }
            .disabled(provisioning.isBusy || email.isEmpty)
        }
    }

    private func phoneCodeStep(sentTo: String) -> some View {
        phonePanel(title: "Check your email", icon: "number") {
            Text("Enter the login code sent to \(sentTo).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Login code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.title3.monospaced())
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            primaryButton("Verify and continue", icon: "arrow.right") {
                run { try await provisioning.verifyEmailCode(code) }
            }
            .disabled(provisioning.isBusy || code.isEmpty)
            Button("Use a different email") {
                provisioning.logout()
                code = ""
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func phoneRecoveryStep(account: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            phonePanel(title: "Prepare your Nuraphone", icon: "headphones") {
                preparationRow("Powered on and being worn", icon: "power")
                preparationRow("Paired in Bluetooth settings", icon: "checkmark.circle")
            }
            primaryButton("Recover device key", icon: "key.horizontal") {
                errorText = nil
                device.fetchDeviceKey()
            }
            .disabled(provisioning.isBusy || !device.phase.isIdle)
            Text("Signed in as \(account)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Button("Sign out", role: .destructive) { provisioning.logout() }
                .font(.footnote)
                .frame(maxWidth: .infinity)
        }
    }

    private func phoneSuccess(serial: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(.green)
            Text("Device key saved")
                .font(.title2.bold())
            Text("Nuraphone \(serial) is ready for local control.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Label("Returning to controls…", systemImage: "arrow.right")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isSummaryElement)
    }

    private var phoneStatus: some View {
        HStack(spacing: 12) {
            if provisioning.isBusy || !device.phase.isIdle {
                ProgressView()
            } else {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Retrieval status")
                    .font(.subheadline.weight(.semibold))
                Text(provisioning.status.isEmpty ? "Communicating with your Nuraphone…" : provisioning.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func preparationRow(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline)
            .padding(.vertical, 2)
    }

    private func phonePanel<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func primaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
            }
            .font(.headline)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
    }
    #endif

    #if os(macOS)
    private var desktopBody: some View {
        NavigationStack {
            Form {
                switch provisioning.authStep {
                case .loggedOut: emailSection
                case .codeSent(let sentTo): codeSection(sentTo: sentTo)
                case .loggedIn(let account): recoverySection(account: account)
                }
                if let errorText {
                    Section { Text(errorText).font(.footnote).foregroundStyle(.red) }
                }
                statusSection
                explanationSection
            }
            .formStyle(.grouped)
            .navigationTitle("Recover Device Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 600, height: 560)
        .onAppear {
            if email.isEmpty { email = provisioning.userEmail ?? "" }
        }
    }
    #endif

    // MARK: - Sign in

    private var emailSection: some View {
        Section("Nura account") {
            TextField("Email address", text: $email)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                #endif
                .disableAutocorrection(true)

            Button {
                run { try await provisioning.requestEmailCode(email) }
            } label: {
                Label("Send login code", systemImage: "envelope")
            }
            .disabled(provisioning.isBusy || email.isEmpty)
        }
    }

    private func codeSection(sentTo: String) -> some View {
        Section("Enter the code") {
            Text("We sent a login code to \(sentTo).")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Login code", text: $code)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif

            Button {
                run { try await provisioning.verifyEmailCode(code) }
            } label: {
                Label("Verify & sign in", systemImage: "checkmark.shield")
            }
            .disabled(provisioning.isBusy || code.isEmpty)

            Button("Use a different email") {
                provisioning.logout()
                code = ""
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Recover

    private func recoverySection(account: String) -> some View {
        Section {
            LabeledContent("Account") { Text(account) }

            Button {
                errorText = nil
                device.fetchDeviceKey()
            } label: {
                Label("Recover key from connected Nura device", systemImage: "key.horizontal")
            }
            .disabled(provisioning.isBusy || !device.phase.isIdle)

            Button("Sign out", role: .destructive) {
                provisioning.logout()
            }
        } header: {
            Text("Signed in")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Key retrieval relays challenge-response authentication between your Nuraphone and Nura’s backend, and can take up to a minute")
            }
        }
    }

    // MARK: - Status & help

    private var statusSection: some View {
        Section {
            HStack {
                StatusBadge(phase: device.phase)
                Spacer()
                if provisioning.isBusy || !device.phase.isIdle {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if !provisioning.status.isEmpty {
                Text(provisioning.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var explanationSection: some View {
        Section {
            Text("Each nuraphone has a unique device key that is used to encrypt the session. This recovers the key from Nura's servers using your account, and persists it so you can connect without the account or offline.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private func run(_ operation: @escaping () async throws -> Void) {
        errorText = nil
        Task { @MainActor in
            do {
                try await operation()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
