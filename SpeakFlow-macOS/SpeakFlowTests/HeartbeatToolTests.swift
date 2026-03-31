import XCTest
@testable import SpeakFlow

final class HeartbeatToolTests: XCTestCase {

    private let tool = HeartbeatTool()

    // MARK: - Relative Time Parsing

    func test_relative_minutes() throws {
        let before = Date()
        let result = try tool.parseTriggerTime("+10m")
        let after = Date()

        let expectedMin = before.addingTimeInterval(10 * 60)
        let expectedMax = after.addingTimeInterval(10 * 60)
        XCTAssertGreaterThanOrEqual(result, expectedMin)
        XCTAssertLessThanOrEqual(result, expectedMax)
    }

    func test_relative_hours() throws {
        let before = Date()
        let result = try tool.parseTriggerTime("+2h")
        let after = Date()

        let expectedMin = before.addingTimeInterval(2 * 3600)
        let expectedMax = after.addingTimeInterval(2 * 3600)
        XCTAssertGreaterThanOrEqual(result, expectedMin)
        XCTAssertLessThanOrEqual(result, expectedMax)
    }

    func test_relative_days() throws {
        let before = Date()
        let result = try tool.parseTriggerTime("+1d")
        let after = Date()

        let expectedMin = before.addingTimeInterval(86400)
        let expectedMax = after.addingTimeInterval(86400)
        XCTAssertGreaterThanOrEqual(result, expectedMin)
        XCTAssertLessThanOrEqual(result, expectedMax)
    }

    func test_relative_zero_minutes() throws {
        let before = Date()
        let result = try tool.parseTriggerTime("+0m")
        XCTAssertGreaterThanOrEqual(result.timeIntervalSince(before), -1)
        XCTAssertLessThanOrEqual(result.timeIntervalSince(before), 1)
    }

    // MARK: - ISO 8601 Parsing

    func test_iso8601_with_timezone() throws {
        let result = try tool.parseTriggerTime("2026-03-10T15:00:00+08:00")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expected = formatter.date(from: "2026-03-10T15:00:00+08:00")
        XCTAssertEqual(result, expected)
    }

    func test_iso8601_utc() throws {
        let result = try tool.parseTriggerTime("2026-03-10T07:00:00Z")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expected = formatter.date(from: "2026-03-10T07:00:00Z")
        XCTAssertEqual(result, expected)
    }

    func test_iso8601_with_fractional_seconds() throws {
        let result = try tool.parseTriggerTime("2026-03-10T07:00:00.123Z")
        XCTAssertNotNil(result)
    }

    // MARK: - Common Formats

    func test_datetime_format() throws {
        let result = try tool.parseTriggerTime("2026-03-10 15:00")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let expected = formatter.date(from: "2026-03-10 15:00")
        XCTAssertEqual(result, expected)
    }

    func test_hh_mm_future_today() throws {
        // Construct a time string that is definitely in the future today
        let calendar = Calendar.current
        let future = calendar.date(byAdding: .hour, value: 2, to: Date())!
        let hour = calendar.component(.hour, from: future)
        let minute = calendar.component(.minute, from: future)
        let timeStr = String(format: "%02d:%02d", hour, minute)

        let result = try tool.parseTriggerTime(timeStr)

        // Should be today
        XCTAssertTrue(calendar.isDateInToday(result))
    }

    func test_hh_mm_past_schedules_tomorrow() throws {
        // "00:01" is almost certainly in the past
        // Unless it's right after midnight — use "00:00" to be safe
        let result = try tool.parseTriggerTime("00:00")

        // If current time is past 00:00 (almost always), should be tomorrow
        let calendar = Calendar.current
        if calendar.component(.hour, from: Date()) > 0 || calendar.component(.minute, from: Date()) > 0 {
            XCTAssertTrue(calendar.isDateInTomorrow(result))
        }
    }

    // MARK: - Error Cases

    func test_invalid_input_throws() {
        XCTAssertThrowsError(try tool.parseTriggerTime("garbage"))
    }

    func test_invalid_relative_format_throws() {
        XCTAssertThrowsError(try tool.parseTriggerTime("+abc"))
    }

    func test_empty_string_throws() {
        XCTAssertThrowsError(try tool.parseTriggerTime(""))
    }
}
