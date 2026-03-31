import XCTest
@testable import SpeakFlow

final class MemoryStoreTests: XCTestCase {

    private var store: MemoryStore!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakflow-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = MemoryStore(fileURL: tempDir.appendingPathComponent("memory.json"))
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - CRUD

    func test_save_and_get() {
        store.save(key: "name", value: "Alex")
        let entry = store.get(key: "name")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.key, "name")
        XCTAssertEqual(entry?.value, "Alex")
    }

    func test_save_overwrites_existing() {
        store.save(key: "boss", value: "张三")
        store.save(key: "boss", value: "李四")
        let entry = store.get(key: "boss")
        XCTAssertEqual(entry?.value, "李四")
    }

    func test_get_nonexistent_returns_nil() {
        XCTAssertNil(store.get(key: "nonexistent"))
    }

    func test_delete_existing_returns_true() {
        store.save(key: "temp", value: "data")
        XCTAssertTrue(store.delete(key: "temp"))
        XCTAssertNil(store.get(key: "temp"))
    }

    func test_delete_nonexistent_returns_false() {
        XCTAssertFalse(store.delete(key: "ghost"))
    }

    func test_list_returns_sorted_by_date_descending() {
        store.save(key: "a", value: "1")
        Thread.sleep(forTimeInterval: 0.01)
        store.save(key: "b", value: "2")
        Thread.sleep(forTimeInterval: 0.01)
        store.save(key: "c", value: "3")

        let list = store.list()
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0].key, "c") // most recent first
        XCTAssertEqual(list[2].key, "a") // oldest last
    }

    func test_list_empty() {
        XCTAssertTrue(store.list().isEmpty)
    }

    // MARK: - Search

    func test_search_matches_key() {
        store.save(key: "GitHub用户名", value: "alexjin")
        store.save(key: "编辑器", value: "Cursor")
        let results = store.search(query: "GitHub")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].key, "GitHub用户名")
    }

    func test_search_matches_value() {
        store.save(key: "tool", value: "uses pnpm for packages")
        let results = store.search(query: "pnpm")
        XCTAssertEqual(results.count, 1)
    }

    func test_search_case_insensitive() {
        store.save(key: "Editor", value: "VSCode")
        let results = store.search(query: "vscode")
        XCTAssertEqual(results.count, 1)
    }

    func test_search_no_match() {
        store.save(key: "a", value: "b")
        XCTAssertTrue(store.search(query: "quantum").isEmpty)
    }

    // MARK: - Capacity Limits

    func test_capacity_limit_evicts_oldest() {
        // Save 502 entries — should cap at 500
        for i in 0..<502 {
            store.save(key: "key-\(i)", value: "val-\(i)")
        }
        let list = store.list()
        XCTAssertEqual(list.count, 500)
        // Oldest entries (key-0, key-1) should have been evicted
        XCTAssertNil(store.get(key: "key-0"))
        XCTAssertNil(store.get(key: "key-1"))
        // Newest should still exist
        XCTAssertNotNil(store.get(key: "key-501"))
    }

    func test_value_truncation() {
        let longValue = String(repeating: "x", count: 3000)
        store.save(key: "long", value: longValue)
        let entry = store.get(key: "long")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry!.value.count, 2000)
    }

    // MARK: - Persistence

    func test_persistence_round_trip() {
        let fileURL = tempDir.appendingPathComponent("persist.json")
        let store1 = MemoryStore(fileURL: fileURL)
        store1.save(key: "persist-key", value: "persist-value")

        // Wait briefly for async disk write
        Thread.sleep(forTimeInterval: 0.2)

        // Create a new instance pointing at the same file
        let store2 = MemoryStore(fileURL: fileURL)
        let entry = store2.get(key: "persist-key")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.value, "persist-value")
    }

    func test_corrupted_file_does_not_crash() {
        let fileURL = tempDir.appendingPathComponent("corrupt.json")
        try? "{{not valid json}}".write(to: fileURL, atomically: true, encoding: .utf8)
        let corruptStore = MemoryStore(fileURL: fileURL)
        XCTAssertTrue(corruptStore.list().isEmpty)
    }

    // MARK: - System Prompt

    func test_systemPromptSection_nil_when_empty() {
        XCTAssertNil(store.systemPromptSection())
    }

    func test_systemPromptSection_contains_entries() {
        store.save(key: "老板", value: "张三")
        let section = store.systemPromptSection()
        XCTAssertNotNil(section)
        XCTAssertTrue(section!.contains("老板"))
        XCTAssertTrue(section!.contains("张三"))
    }

    func test_systemPromptSection_truncates_long_values() {
        let longValue = String(repeating: "a", count: 500)
        store.save(key: "long", value: longValue)
        let section = store.systemPromptSection()!
        // Should contain "..." indicating truncation (200 char limit in prompt)
        XCTAssertTrue(section.contains("..."))
    }

    func test_systemPromptSection_caps_at_50() {
        for i in 0..<60 {
            store.save(key: "key-\(i)", value: "val")
        }
        let section = store.systemPromptSection()!
        let entryCount = section.components(separatedBy: "\n- **").count - 1
        XCTAssertLessThanOrEqual(entryCount, 50)
    }

    // MARK: - Thread Safety

    func test_concurrent_saves_do_not_crash() {
        let group = DispatchGroup()
        let iterations = 100

        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                self.store.save(key: "concurrent-\(i)", value: "value-\(i)")
                group.leave()
            }
        }

        group.wait()
        let list = store.list()
        XCTAssertEqual(list.count, iterations)
    }
}
