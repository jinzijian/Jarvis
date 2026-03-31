import Foundation
import os.log

private let hkLogger = Logger(subsystem: "com.speakflow", category: "HotkeyService")

final class HotkeyService {
    /// Fn key service for modifier-key-based shortcuts (tap, double-tap, combos)
    let fnKeyService = FnKeyService()

    private(set) var isRunning = false

    func start() {
        guard !isRunning else {
            hkLogger.warning("start() called but already running, skipping")
            return
        }

        hkLogger.warning("Starting FnKeyService shortcuts...")
        fnKeyService.start()
        isRunning = true
    }

    func stop() {
        fnKeyService.stop()
        isRunning = false
    }
}
