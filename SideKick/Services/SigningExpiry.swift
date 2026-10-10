import Foundation

enum SigningExpiry {
    /// Count partial days so a fresh seven-day profile doesn't immediately show six.
    static func daysRemaining(until expiration: Date, now: Date = .now) -> Int {
        max(Int(ceil(expiration.timeIntervalSince(now) / 86_400)), 0)
    }

    static func description(until expiration: Date, now: Date = .now) -> String {
        guard expiration > now else { return "Expired" }
        let days = daysRemaining(until: expiration, now: now)
        return "in \(days) \(days == 1 ? "day" : "days")"
    }
}
