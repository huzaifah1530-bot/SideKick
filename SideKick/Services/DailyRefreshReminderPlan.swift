import Foundation

struct DailyRefreshReminderPlan {
    let hour: Int
    let minute: Int

    /// One-shot requests let a successful refresh cancel today's warning without
    /// disabling tomorrow's. Replenished whenever SideKick or its shortcut runs.
    func fireDates(now: Date, lastSuccess: Date?, calendar: Calendar = .current, count: Int = 28) -> [Date] {
        guard count > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        return (-1...count).compactMap { offset -> Date? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let scheduled = calendar.date(bySettingHour: min(23, max(0, hour)), minute: min(59, max(0, minute)), second: 0, of: day),
                  let fire = calendar.date(byAdding: .minute, value: 10, to: scheduled), fire > now else { return nil }
            if let lastSuccess, lastSuccess <= now, lastSuccess >= day { return nil }
            return fire
        }.prefix(count).map { $0 }
    }
}
