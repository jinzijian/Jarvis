import XCTest
@testable import SpeakFlow

@MainActor
final class HeartbeatSchedulerTests: XCTestCase {

    private var scheduler: HeartbeatScheduler!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakflow-hb-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        scheduler = HeartbeatScheduler(fileURL: tempDir.appendingPathComponent("heartbeats.json"))
    }

    override func tearDown() async throws {
        scheduler.stop()
        scheduler = nil
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Entry Management

    func test_add_and_listAll() {
        let entry = makeEntry(message: "test reminder", minutesFromNow: 10)
        scheduler.add(entry)

        let list = scheduler.listAll()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].message, "test reminder")
    }

    func test_add_multiple_and_sorted() {
        let later = makeEntry(message: "later", minutesFromNow: 60)
        let sooner = makeEntry(message: "sooner", minutesFromNow: 5)
        scheduler.add(later)
        scheduler.add(sooner)

        let list = scheduler.listAll()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].message, "sooner") // sorted by triggerAt ascending
        XCTAssertEqual(list[1].message, "later")
    }

    func test_remove_existing_returns_true() {
        let entry = makeEntry(message: "to remove", minutesFromNow: 10)
        scheduler.add(entry)
        XCTAssertTrue(scheduler.remove(id: entry.id))
        XCTAssertTrue(scheduler.listAll().isEmpty)
    }

    func test_remove_nonexistent_returns_false() {
        XCTAssertFalse(scheduler.remove(id: UUID()))
    }

    func test_remove_does_not_affect_others() {
        let e1 = makeEntry(message: "keep", minutesFromNow: 10)
        let e2 = makeEntry(message: "remove", minutesFromNow: 20)
        scheduler.add(e1)
        scheduler.add(e2)
        scheduler.remove(id: e2.id)

        let list = scheduler.listAll()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].message, "keep")
    }

    // MARK: - Persistence

    func test_persistence_round_trip() {
        let fileURL = tempDir.appendingPathComponent("persist-hb.json")
        let s1 = HeartbeatScheduler(fileURL: fileURL)
        let entry = makeEntry(message: "persisted", minutesFromNow: 30)
        s1.add(entry)

        let s2 = HeartbeatScheduler(fileURL: fileURL)
        let list = s2.listAll()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].message, "persisted")
    }

    func test_corrupted_file_does_not_crash() {
        let fileURL = tempDir.appendingPathComponent("corrupt-hb.json")
        try? "not json!!!".write(to: fileURL, atomically: true, encoding: .utf8)
        let s = HeartbeatScheduler(fileURL: fileURL)
        XCTAssertTrue(s.listAll().isEmpty)
    }

    // MARK: - Fire Logic

    func test_oneshot_entry_removed_after_fire() {
        // Create entry with triggerAt in the past → should fire on next check
        let entry = makeEntry(message: "fire me", minutesFromNow: -1, repeatRule: nil)
        scheduler.add(entry)

        // Start scheduler — it calls checkAndFire immediately
        var firedMessages: [String] = []
        scheduler.onAgentTrigger = { msg in firedMessages.append(msg) }
        scheduler.start()

        // Give timer a moment
        let expectation = XCTestExpectation(description: "Wait for check")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        // One-shot should be removed
        XCTAssertTrue(scheduler.listAll().isEmpty)
    }

    func test_repeating_entry_rescheduled_after_fire() {
        let entry = makeEntry(message: "daily task", minutesFromNow: -1, repeatRule: "daily")
        scheduler.add(entry)
        scheduler.start()

        let expectation = XCTestExpectation(description: "Wait for check")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        let list = scheduler.listAll()
        XCTAssertEqual(list.count, 1)
        // triggerAt should have been updated to ~tomorrow
        XCTAssertGreaterThan(list[0].triggerAt, Date())
    }

    func test_multiple_entries_all_fire() {
        let e1 = makeEntry(message: "first", minutesFromNow: -1, action: .notify)
        let e2 = makeEntry(message: "second", minutesFromNow: -1, action: .notify)
        let e3 = makeEntry(message: "third", minutesFromNow: -1, action: .notify)
        scheduler.add(e1)
        scheduler.add(e2)
        scheduler.add(e3)
        scheduler.start()

        let expectation = XCTestExpectation(description: "Wait for check")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        // All one-shot entries should be removed after firing
        XCTAssertTrue(scheduler.listAll().isEmpty)
    }

    func test_future_entry_not_fired() {
        let entry = makeEntry(message: "future", minutesFromNow: 60)
        scheduler.add(entry)
        scheduler.start()

        let expectation = XCTestExpectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        // Should still be there
        XCTAssertEqual(scheduler.listAll().count, 1)
    }

    // MARK: - Helpers

    private func makeEntry(
        message: String,
        minutesFromNow: Int,
        repeatRule: String? = nil,
        action: HeartbeatAction = .notify
    ) -> HeartbeatEntry {
        HeartbeatEntry(
            id: UUID(),
            triggerAt: Date().addingTimeInterval(TimeInterval(minutesFromNow * 60)),
            repeatRule: repeatRule,
            action: action,
            message: message,
            context: nil,
            createdAt: Date()
        )
    }
}
