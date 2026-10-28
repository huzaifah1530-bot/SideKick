import Foundation
import XCTest
@testable import SideKickCore

final class DailyRefreshReminderPlanTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/London")!
        return value
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testMissedShortcutStillHasDailyRemindersScheduledAhead() {
        let plan = DailyRefreshReminderPlan(hour: 9, minute: 0)
        let dates = plan.fireDates(now: date("2026-10-28T08:00:00Z"), lastSuccess: nil, calendar: calendar, count: 3)
        XCTAssertEqual(dates, [date("2026-10-28T09:10:00Z"), date("2026-10-29T09:10:00Z"), date("2026-10-30T09:10:00Z")])
    }

    func testSuccessCancelsOnlyTodaysReminderAndFailureDoesNotAcknowledgeTomorrow() {
        let plan = DailyRefreshReminderPlan(hour: 9, minute: 0)
        let dates = plan.fireDates(now: date("2026-10-28T09:02:00Z"), lastSuccess: date("2026-10-28T09:01:00Z"), calendar: calendar, count: 2)
        XCTAssertEqual(dates.first, date("2026-10-29T09:10:00Z"))
        XCTAssertEqual(plan.fireDates(now: date("2026-10-29T08:00:00Z"), lastSuccess: date("2026-10-28T09:01:00Z"), calendar: calendar, count: 2).first, dates.first)
    }

    func testGraceCanCrossMidnightAndCalendarDaysHandleDST() {
        let late = DailyRefreshReminderPlan(hour: 23, minute: 55)
        XCTAssertEqual(late.fireDates(now: date("2026-10-29T00:01:00Z"), lastSuccess: nil, calendar: calendar, count: 1).first, date("2026-10-29T00:05:00Z"))
        let morning = DailyRefreshReminderPlan(hour: 9, minute: 0)
        XCTAssertEqual(morning.fireDates(now: date("2026-10-24T07:00:00Z"), lastSuccess: nil, calendar: calendar, count: 2), [date("2026-10-24T08:10:00Z"), date("2026-10-25T09:10:00Z")])
    }
}
