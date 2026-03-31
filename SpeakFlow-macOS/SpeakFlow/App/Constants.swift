import Cocoa
import Foundation

/// Extract "detail" field from a JSON error response body.
func parseAPIError(data: Data) -> String {
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let detail = json["detail"] as? String {
        return detail
    }
    return "Unknown error"
}

enum Constants {
    static let apiBaseURL = UserDefaults.standard.string(forKey: "apiBaseURL") ?? "http://localhost:8000/api/v1"
    static let keychainServiceName = "com.speakflow.macos"

    // Default hotkey: Option+Z (hold to record)
    // keyCode 6 = Z key
    static let defaultHotkeyKeyCode: UInt16 = 6
    static let defaultHotkeyModifiers: NSEvent.ModifierFlags = .option
}
