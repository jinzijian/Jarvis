import XCTest
@testable import SpeakFlow

final class BrowserToolTests: XCTestCase {

    // MARK: - BrowserTool Unit Tests

    func testBrowserToolDefinition() {
        let tool = BrowserTool()
        let def = tool.toolDefinition()
        XCTAssertEqual(def.function.name, "browser")
        XCTAssertEqual(def.type, "function")
    }

    func testBrowserToolActionEnum() {
        let tool = BrowserTool()
        let params = tool.parameters
        guard let props = params["properties"] as? [String: Any],
              let action = props["action"] as? [String: Any],
              let enumValues = action["enum"] as? [String] else {
            XCTFail("Missing action enum in parameters")
            return
        }
        XCTAssertTrue(enumValues.contains("navigate"))
        XCTAssertTrue(enumValues.contains("snapshot"))
        XCTAssertTrue(enumValues.contains("click"))
        XCTAssertTrue(enumValues.contains("type"))
        XCTAssertTrue(enumValues.contains("press"))
        XCTAssertTrue(enumValues.contains("screenshot"))
        XCTAssertTrue(enumValues.contains("tabs"))
        XCTAssertTrue(enumValues.contains("login"))
    }

    func testBrowserToolRequiresAction() async throws {
        let tool = BrowserTool()
        do {
            _ = try await tool.execute(arguments: "{}")
            XCTFail("Should have thrown for missing action")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("action"))
        }
    }

    func testBrowserToolInvalidAction() async throws {
        let tool = BrowserTool()
        do {
            _ = try await tool.execute(arguments: #"{"action":"fly"}"#)
            XCTFail("Should have thrown for unknown action")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Unknown action"))
        }
    }

    // MARK: - BrowserManager Unit Tests

    func testChromeDetection() {
        // Just verify the manager exists and has correct defaults
        let manager = BrowserManager.shared
        XCTAssertEqual(manager.cdpURL, "http://127.0.0.1:9222")
        XCTAssertTrue(manager.userDataDir.contains(".speakflow/browser/user-data"))
    }

    // MARK: - BrowserSnapshot RefMap Tests

    func testRefMapStorage() {
        var refMap = BrowserSnapshot.RefMap()
        refMap.refs["e1"] = 100
        refMap.refs["e2"] = 200
        refMap.nodeInfo["e1"] = .init(role: "button", name: "Submit")
        refMap.nodeInfo["e2"] = .init(role: "textbox", name: "Email")

        XCTAssertEqual(refMap.refs.count, 2)
        XCTAssertEqual(refMap.refs["e1"], 100)
        XCTAssertEqual(refMap.nodeInfo["e1"]?.role, "button")
        XCTAssertEqual(refMap.nodeInfo["e2"]?.name, "Email")
    }

    // MARK: - BrowserError Tests

    func testBrowserErrorDescriptions() {
        XCTAssertTrue(BrowserError.chromeNotFound.localizedDescription.contains("Chrome"))
        XCTAssertTrue(BrowserError.cdpTimeout.localizedDescription.contains("10 seconds"))
        XCTAssertTrue(BrowserError.elementNotFound("e5").localizedDescription.contains("e5"))
        XCTAssertTrue(BrowserError.notRunning.localizedDescription.contains("not running"))
    }
}
