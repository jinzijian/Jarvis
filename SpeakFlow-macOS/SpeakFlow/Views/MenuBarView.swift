import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("SpeakFlow")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            if appState.isLoggedIn {
                loggedInView
            } else {
                loggedOutView
            }
        }
        .frame(width: 300)
    }

    private var loggedInView: some View {
        VStack(spacing: 12) {
            // Permission warnings
            if appState.needsAccessibility {
                permissionBanner(
                    icon: "hand.raised.fill",
                    title: "Accessibility Permission Required",
                    detail: "Needed for hotkey & text input",
                    action: "Grant Access"
                ) {
                    appState.requestAccessibility()
                }
            }

            if appState.needsMicrophone {
                permissionBanner(
                    icon: "mic.slash.fill",
                    title: "Microphone Permission Required",
                    detail: "Needed to record your voice",
                    action: "Grant Access"
                ) {
                    appState.requestMicrophone()
                }
            }

            // Status
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Spacer()

                if appState.hotkeyReady {
                    Text("Fn ready")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Last result
            if let result = appState.lastResult {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Result")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Text(result)
                        .font(.system(size: 13))
                        .lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
                .padding(.horizontal, 16)
            }

            // Hotkey hint
            if !appState.needsAccessibility {
                Text("Hold Fn to record, release to process")
                    .font(.system(size: 12))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .padding(.top, 4)
            }

            Spacer()

            Divider()

            // Bottom buttons
            HStack {
                Button("Settings...") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func permissionBanner(icon: String, title: String, detail: String, action: String, onTap: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(.orange)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            Button(action) {
                onTap()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var loggedOutView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("Sign in to get started")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Button("Sign In") {
                LoginWindow.show(appState: appState)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()

            Divider()
            HStack {
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var statusColor: Color {
        switch appState.appPhase {
        case .idle: return .green
        case .recording: return .red
        case .processing: return .orange
        case .done: return .blue
        case .error: return .red
        }
    }

    private var statusText: String {
        switch appState.appPhase {
        case .idle: return "Ready"
        case .recording: return "Recording..."
        case .processing: return "Processing..."
        case .done: return "Done"
        case .error: return appState.lastError ?? "Error"
        }
    }
}
