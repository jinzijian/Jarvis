import SwiftUI

@MainActor
enum UpgradeWindow {
    private static var window: NSWindow?

    static func show(appState: AppState) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = UpgradeView(appState: appState, onDismiss: { close() })
        let hosting = NSHostingController(rootView: view)

        let w = NSWindow(contentViewController: hosting)
        w.title = "Upgrade to Pro — SpeakFlow"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 420, height: 520))
        w.center()
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = w
    }

    static func close() {
        window?.close()
        window = nil
    }
}

struct UpgradeView: View {
    @ObservedObject var appState: AppState
    var onDismiss: () -> Void

    @State private var isLoadingMonthly = false
    @State private var isLoadingAnnual = false
    @State private var inviteCode = ""
    @State private var isRedeeming = false
    @State private var message = ""
    @State private var messageIsError = false

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.orange)
                Text("Upgrade to Pro")
                    .font(.system(size: 20, weight: .bold))
                Text("Subscribe to start using SpeakFlow")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 4)

            // Pricing cards
            VStack(spacing: 12) {
                // Monthly card
                pricingCard(
                    title: "Monthly",
                    price: "$1",
                    subtitle: "first month, then $12.99/mo",
                    featured: false,
                    isLoading: isLoadingMonthly
                ) {
                    checkout(plan: "monthly", setLoading: { isLoadingMonthly = $0 })
                }

                // Annual card
                pricingCard(
                    title: "Annual",
                    price: "$99.99/yr",
                    subtitle: "Save 36% — $8.33/mo",
                    featured: true,
                    isLoading: isLoadingAnnual
                ) {
                    checkout(plan: "annual", setLoading: { isLoadingAnnual = $0 })
                }
            }

            // Features
            VStack(alignment: .leading, spacing: 6) {
                featureRow("Unlimited voice commands")
                featureRow("Screenshot & text context")
                featureRow("All languages supported")
                featureRow("Cancel anytime")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)

            Divider()

            // Invite code
            VStack(spacing: 8) {
                Text("Have an invite code?")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    TextField("Enter code", text: $inviteCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Button("Redeem") { redeem() }
                        .controlSize(.small)
                        .disabled(inviteCode.isEmpty || isRedeeming)
                }
            }

            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(messageIsError ? .red : .green)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    @ViewBuilder
    private func pricingCard(
        title: String,
        price: String,
        subtitle: String,
        featured: Bool,
        isLoading: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                        if featured {
                            Text("BEST VALUE")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(4)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(price)
                        .font(.system(size: 18, weight: .bold))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                featured
                    ? Color.accentColor.opacity(0.08)
                    : Color(nsColor: .controlBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(featured ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: featured ? 1.5 : 0.5)
            )
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .disabled(isLoadingMonthly || isLoadingAnnual)
    }

    @ViewBuilder
    private func featureRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.green)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.primary.opacity(0.8))
        }
    }

    private func checkout(plan: String, setLoading: @escaping (Bool) -> Void) {
        setLoading(true)
        message = ""
        Task {
            do {
                let url = try await AuthService.shared.createCheckoutSession(plan: plan)
                if let nsURL = URL(string: url) {
                    NSWorkspace.shared.open(nsURL)
                }
                message = "Complete payment in your browser"
                messageIsError = false
            } catch {
                message = error.localizedDescription
                messageIsError = true
            }
            setLoading(false)
        }
    }

    private func redeem() {
        isRedeeming = true
        message = ""
        Task {
            do {
                let msg = try await AuthService.shared.redeemInviteCode(inviteCode)
                message = msg
                messageIsError = false
                inviteCode = ""
                appState.applySubscriptionStatus(SubscriptionStatus(is_active: true, plan_name: "invite", plan_display_name: "Pro", status: "active", current_period_end: nil, cancelled_at: nil, stripe_subscription_id: nil))
                onDismiss()
            } catch {
                message = error.localizedDescription
                messageIsError = true
            }
            isRedeeming = false
        }
    }
}
