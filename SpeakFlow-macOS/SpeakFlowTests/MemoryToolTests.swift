import XCTest
@testable import SpeakFlow

final class MemoryToolTests: XCTestCase {

    private var store: MemoryStore!
    private var tool: MemoryTool!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakflow-memtool-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = MemoryStore(fileURL: tempDir.appendingPathComponent("memory.json"))
        tool = MemoryTool(store: store)
    }

    override func tearDown() {
        tool = nil
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Save

    func test_save_action() async throws {
        let result = try await tool.execute(arguments: """
            {"action":"save","key":"name","value":"Alex"}
            """)
        XCTAssertTrue(result.contains("已保存"))
        XCTAssertEqual(store.get(key: "name")?.value, "Alex")
    }

    func test_save_missing_key_throws() async {
        do {
            _ = try await tool.execute(arguments: """
                {"action":"save","value":"no key"}
                """)
            XCTFail("Should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("key"))
        }
    }

    func test_save_missing_value_throws() async {
        do {
            _ = try await tool.execute(arguments: """
                {"action":"save","key":"novalue"}
                """)
            XCTFail("Should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("value"))
        }
    }

    // MARK: - Get

    func test_get_existing() async throws {
        store.save(key: "boss", value: "张三")
        let result = try await tool.execute(arguments: """
            {"action":"get","key":"boss"}
            """)
        XCTAssertTrue(result.contains("张三"))
    }

    func test_get_nonexistent() async throws {
        let result = try await tool.execute(arguments: """
            {"action":"get","key":"unknown"}
            """)
        XCTAssertTrue(result.contains("未找到"))
    }

    func test_get_missing_key_throws() async {
        do {
            _ = try await tool.execute(arguments: """
                {"action":"get"}
                """)
            XCTFail("Should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("key"))
        }
    }

    // MARK: - List

    func test_list_empty() async throws {
        let result = try await tool.execute(arguments: """
            {"action":"list"}
            """)
        XCTAssertTrue(result.contains("暂无"))
    }

    func test_list_with_entries() async throws {
        store.save(key: "a", value: "1")
        store.save(key: "b", value: "2")
        let result = try await tool.execute(arguments: """
            {"action":"list"}
            """)
        XCTAssertTrue(result.contains("a"))
        XCTAssertTrue(result.contains("b"))
    }

    // MARK: - Delete

    func test_delete_existing() async throws {
        store.save(key: "temp", value: "data")
        let result = try await tool.execute(arguments: """
            {"action":"delete","key":"temp"}
            """)
        XCTAssertTrue(result.contains("已删除"))
        XCTAssertNil(store.get(key: "temp"))
    }

    func test_delete_nonexistent() async throws {
        let result = try await tool.execute(arguments: """
            {"action":"delete","key":"ghost"}
            """)
        XCTAssertTrue(result.contains("未找到"))
    }

    // MARK: - Search

    func test_search_matches() async throws {
        store.save(key: "project", value: "SpeakFlow macOS app")
        store.save(key: "editor", value: "Cursor")
        let result = try await tool.execute(arguments: """
            {"action":"search","query":"SpeakFlow"}
            """)
        XCTAssertTrue(result.contains("project"))
        XCTAssertFalse(result.contains("editor"))
    }

    func test_search_no_match() async throws {
        store.save(key: "a", value: "b")
        let result = try await tool.execute(arguments: """
            {"action":"search","query":"quantum"}
            """)
        XCTAssertTrue(result.contains("未找到"))
    }

    func test_search_missing_query_throws() async {
        do {
            _ = try await tool.execute(arguments: """
                {"action":"search"}
                """)
            XCTFail("Should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("query"))
        }
    }

    // MARK: - Invalid Action

    func test_missing_action_throws() async {
        do {
            _ = try await tool.execute(arguments: "{}")
            XCTFail("Should throw")
        } catch {
            // Expected
        }
    }

    func test_unknown_action_throws() async {
        do {
            _ = try await tool.execute(arguments: """
                {"action":"fly"}
                """)
            XCTFail("Should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("fly"))
        }
    }

    // MARK: - Chinese Content

    func test_chinese_key_and_value() async throws {
        let result = try await tool.execute(arguments: """
            {"action":"save","key":"常去咖啡店","value":"星巴克 中关村店"}
            """)
        XCTAssertTrue(result.contains("已保存"))
        XCTAssertEqual(store.get(key: "常去咖啡店")?.value, "星巴克 中关村店")
    }
}
