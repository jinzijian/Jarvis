import SwiftUI

struct LoginWindow {
    private static var window: NSWindow?

    static func show(appState: AppState) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = LoginView(appState: appState, onDismiss: { close() })
        let hostingController = NSHostingController(rootView: view)

        let win = NSWindow(contentViewController: hostingController)
        win.title = "Sign In — SpeakFlow"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 360, height: 420))
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = win
    }

    static func close() {
        window?.close()
        window = nil
    }
}

struct LoginView: View {
    @ObservedObject var appState: AppState
    var onDismiss: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var isGoogleLoading = false
    @State private var errorMessage: String?

    private let oauthService = OAuthService.shared

    var body: some View {
        VStack(spacing: 20) {
            // Logo
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                Text("SpeakFlow")
                    .font(.system(size: 20, weight: .bold))
            }
            .padding(.top, 8)

            // Google Sign In
            Button(action: googleLogin) {
                HStack(spacing: 8) {
                    if isGoogleLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("G")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.blue)
                    }
                    Text("Continue with Google")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isLoading || isGoogleLoading)

            // Divider
            HStack {
                Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)
                Text("or").font(.system(size: 12)).foregroundColor(.secondary)
                Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)
            }

            // Email/Password Form
            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .lineLimit(2)
            }

            Button(action: login) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Sign In with Email")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(email.isEmpty || password.isEmpty || isLoading || isGoogleLoading)
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 360)
    }

    private func googleLogin() {
        isGoogleLoading = true
        errorMessage = nil

        oauthService.startGoogleLogin { result in
            isGoogleLoading = false
            switch result {
            case .success(let response):
                appState.isLoggedIn = true
                appState.userEmail = response.user.email
                KeychainService.shared.userEmail = response.user.email
                appState.loadSubscription()
                onDismiss()
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func login() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let response = try await AuthService.shared.login(email: email, password: password)
                await MainActor.run {
                    appState.isLoggedIn = true
                    appState.userEmail = response.user.email
                    KeychainService.shared.userEmail = response.user.email
                    appState.loadSubscription()
                    isLoading = false
                    onDismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}
