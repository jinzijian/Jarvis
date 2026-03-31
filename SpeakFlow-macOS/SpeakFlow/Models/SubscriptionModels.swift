import Foundation

struct SubscriptionStatus: Decodable {
    let is_active: Bool
    let plan_name: String?
    let plan_display_name: String?
    let status: String?
    let current_period_end: String?
    let cancelled_at: String?
    let stripe_subscription_id: String?

    var periodEndDate: Date? {
        guard let str = current_period_end else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: str) ?? ISO8601DateFormatter().date(from: str)
    }

    var daysRemaining: Int? {
        guard let end = periodEndDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: end).day
    }

    var statusLabel: String {
        guard is_active else { return "No active plan" }
        switch status {
        case "active": return "Active"
        case "trialing": return "Trial"
        case "past_due": return "Past Due"
        case "cancelled": return "Cancelled"
        default: return status ?? "Unknown"
        }
    }
}

struct UsagePeriod: Decodable {
    let api_calls: Int
    let audio_seconds: Double
    let input_tokens: Int
    let output_tokens: Int

    var audioMinutes: Double { audio_seconds / 60.0 }
    var totalTokens: Int { input_tokens + output_tokens }
}

struct UsageStats: Decodable {
    let today: UsagePeriod
    let total: UsagePeriod
}

struct PortalSession: Decodable {
    let portal_url: String
}
