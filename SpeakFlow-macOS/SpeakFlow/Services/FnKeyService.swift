import AppKit
import Foundation
import os.log

private let fnLogger = Logger(subsystem: "com.speakflow", category: "FnKeyService")

// MARK: - Modifier Key Mapping

/// Maps a modifier key code to the corresponding NSEvent.ModifierFlags
func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
    switch keyCode {
    case 59, 62: return .control   // left/right Control
    case 58, 61: return .option    // left/right Option
    case 56, 60: return .shift     // left/right Shift
    case 55, 54: return .command   // left/right Command
    case 63:     return .function  // fn/Globe
    default:     return nil
    }
}

/// Human-readable name for a modifier key code
func modifierKeyName(for keyCode: UInt16) -> String {
    switch keyCode {
    case 59: return "Left Control"
    case 62: return "Right Control"
    case 58: return "Left Option"
    case 61: return "Right Option"
    case 56: return "Left Shift"
    case 60: return "Right Shift"
    case 55: return "Left Command"
    case 54: return "Right Command"
    case 63: return "Fn"
    default: return "Key \(keyCode)"
    }
}

/// Human-readable name for a regular key code
func regularKeyName(for keyCode: UInt16) -> String {
    switch keyCode {
    case 0: return "A"
    case 1: return "S"
    case 2: return "D"
    case 3: return "F"
    case 4: return "H"
    case 5: return "G"
    case 6: return "Z"
    case 7: return "X"
    case 8: return "C"
    case 9: return "V"
    case 11: return "B"
    case 12: return "Q"
    case 13: return "W"
    case 14: return "E"
    case 15: return "R"
    case 16: return "Y"
    case 17: return "T"
    case 31: return "O"
    case 32: return "U"
    case 34: return "I"
    case 35: return "P"
    case 37: return "L"
    case 38: return "J"
    case 40: return "K"
    case 45: return "N"
    case 46: return "M"
    default: return String(format: "0x%02X", keyCode)
    }
}

/// Human-readable name for a modifier flag
func modifierFlagName(for flag: NSEvent.ModifierFlags) -> String {
    if flag.contains(.control) { return "Control" }
    if flag.contains(.option) { return "Option" }
    if flag.contains(.shift) { return "Shift" }
    if flag.contains(.command) { return "Command" }
    if flag.contains(.function) { return "Fn" }
    return "?"
}

// MARK: - Quick Shortcut Configuration

final class QuickShortcutConfig: ObservableObject {
    static let shared = QuickShortcutConfig()

    /// The modifier key used as the trigger (tap / double-tap)
    @Published var triggerKeyCode: UInt16 {
        didSet { save() }
    }

    /// The additional modifier for screenshot combo (trigger + this)
    @Published var screenshotModifier: NSEvent.ModifierFlags {
        didSet { save() }
    }

    /// The key code for full-screen combo (trigger + this key)
    @Published var fullScreenKeyCode: UInt16 {
        didSet { save() }
    }

    // Derived display names
    var triggerKeyName: String { modifierKeyName(for: triggerKeyCode) }

    var triggerModifierFlag: NSEvent.ModifierFlags {
        modifierFlag(for: triggerKeyCode) ?? .control
    }

    var screenshotDisplayName: String {
        "\(shortTriggerName) + \(modifierFlagName(for: screenshotModifier))"
    }

    var fullScreenDisplayName: String {
        "\(shortTriggerName) + \(regularKeyName(for: fullScreenKeyCode))"
    }

    var contextDisplayName: String {
        "Select + \(shortTriggerName)"
    }

    private var shortTriggerName: String {
        // Use abbreviated name for combos
        let name = triggerKeyName
        if name.hasPrefix("Left ") { return "L" + String(name.dropFirst(5)) }
        if name.hasPrefix("Right ") { return "R" + String(name.dropFirst(6)) }
        return name
    }

    private init() {
        let defaults = UserDefaults.standard

        let savedTrigger = UInt16(defaults.integer(forKey: "quickShortcut_triggerKeyCode"))
        // Migrate from old Control default (59) to Fn/Globe (63)
        if savedTrigger == 59 && !defaults.bool(forKey: "quickShortcut_migratedToFn") {
            self.triggerKeyCode = 63
            defaults.set(true, forKey: "quickShortcut_migratedToFn")
        } else {
            self.triggerKeyCode = savedTrigger != 0 ? savedTrigger : 63  // default: Fn/Globe
        }

        let screenshotRaw = defaults.integer(forKey: "quickShortcut_screenshotModifier")
        self.screenshotModifier = screenshotRaw != 0
            ? NSEvent.ModifierFlags(rawValue: UInt(screenshotRaw))
            : .option

        let savedFullScreen = UInt16(defaults.integer(forKey: "quickShortcut_fullScreenKeyCode"))
        if defaults.bool(forKey: "quickShortcut_fullScreenKeyCodeSet") {
            self.fullScreenKeyCode = savedFullScreen
        } else {
            self.fullScreenKeyCode = 0 // 'a' key, keyCode 0
            defaults.set(true, forKey: "quickShortcut_fullScreenKeyCodeSet")
        }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(Int(triggerKeyCode), forKey: "quickShortcut_triggerKeyCode")
        defaults.set(Int(screenshotModifier.rawValue), forKey: "quickShortcut_screenshotModifier")
        defaults.set(Int(fullScreenKeyCode), forKey: "quickShortcut_fullScreenKeyCode")
        defaults.set(true, forKey: "quickShortcut_fullScreenKeyCodeSet")
        NotificationCenter.default.post(name: .quickShortcutConfigChanged, object: nil)
    }
}

extension Notification.Name {
    static let quickShortcutConfigChanged = Notification.Name("quickShortcutConfigChanged")
}

// MARK: - FnKeyService

/// Monitors a configurable modifier key for tap, double-tap, and combo shortcuts.
///
/// Shortcuts (defaults — all configurable):
/// - trigger tap            → voice dictation toggle
/// - trigger double-tap     → agent mode toggle (only when idle)
/// - trigger + modifier     → screenshot + voice
/// - trigger + key          → full screen + voice
///
/// State-aware: when recording, a tap immediately stops recording
/// without entering the double-tap detection window.
final class FnKeyService {

    // MARK: - Callbacks

    var onFnSingleTap: (() -> Void)?
    var onFnDoubleTap: (() -> Void)?
    var onFnOption: (() -> Void)?
    var onFnA: (() -> Void)?
    var isRecording: (() -> Bool)?

    // MARK: - Configuration

    var doubleTapInterval: TimeInterval = 0.3
    private let config = QuickShortcutConfig.shared

    // MARK: - State

    private var flagsGlobalMonitor: Any?
    private var flagsLocalMonitor: Any?
    private var keyGlobalMonitor: Any?
    private var keyLocalMonitor: Any?
    private var configObserver: NSObjectProtocol?

    private var triggerIsDown = false
    private var triggerWasUsedWithCombo = false
    private var pendingSingleTap: DispatchWorkItem?
    private var lastTapTime: Date?
    /// Monotonic time of last handleTap() call to deduplicate global/local monitor events
    private var lastHandleTapTime: TimeInterval = 0

    private(set) var isRunning = false

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }

        flagsGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        keyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }
        flagsLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        keyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .quickShortcutConfigChanged, object: nil, queue: .main
        ) { [weak self] _ in
            // Reset state on config change
            self?.triggerIsDown = false
            self?.triggerWasUsedWithCombo = false
            self?.pendingSingleTap?.cancel()
            self?.pendingSingleTap = nil
        }

        isRunning = true
        fnLogger.info("FnKeyService started (trigger: \(self.config.triggerKeyName))")
    }

    func stop() {
        if let m = flagsGlobalMonitor { NSEvent.removeMonitor(m) }
        if let m = flagsLocalMonitor { NSEvent.removeMonitor(m) }
        if let m = keyGlobalMonitor { NSEvent.removeMonitor(m) }
        if let m = keyLocalMonitor { NSEvent.removeMonitor(m) }
        flagsGlobalMonitor = nil
        flagsLocalMonitor = nil
        keyGlobalMonitor = nil
        keyLocalMonitor = nil

        if let obs = configObserver {
            NotificationCenter.default.removeObserver(obs)
            configObserver = nil
        }

        pendingSingleTap?.cancel()
        pendingSingleTap = nil
        lastTapTime = nil
        triggerIsDown = false

        isRunning = false
    }

    // MARK: - Event Handling

    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == config.triggerKeyCode else { return }

        let flags = event.modifierFlags
        let triggerDown = flags.contains(config.triggerModifierFlag)

        if triggerDown && !triggerIsDown {
            triggerIsDown = true
            triggerWasUsedWithCombo = false

            // Check if screenshot modifier is already held
            if flags.contains(config.screenshotModifier) && config.screenshotModifier != config.triggerModifierFlag {
                triggerWasUsedWithCombo = true
                DispatchQueue.main.async { self.onFnOption?() }
            }
        } else if !triggerDown && triggerIsDown {
            triggerIsDown = false
            if !triggerWasUsedWithCombo {
                handleTap()
            }
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard triggerIsDown, !triggerWasUsedWithCombo else { return }

        if event.keyCode == config.fullScreenKeyCode {
            triggerWasUsedWithCombo = true
            DispatchQueue.main.async { self.onFnA?() }
        } else if event.modifierFlags.contains(config.screenshotModifier) && config.screenshotModifier != config.triggerModifierFlag {
            triggerWasUsedWithCombo = true
            DispatchQueue.main.async { self.onFnOption?() }
        } else {
            triggerWasUsedWithCombo = true
        }
    }

    // MARK: - Tap Detection

    private func handleTap() {
        // Deduplicate: global + local monitors can both fire for one physical key release
        let monotonicNow = ProcessInfo.processInfo.systemUptime
        if monotonicNow - lastHandleTapTime < 0.05 { return }
        lastHandleTapTime = monotonicNow

        if isRecording?() == true {
            pendingSingleTap?.cancel()
            pendingSingleTap = nil
            lastTapTime = nil
            DispatchQueue.main.async { self.onFnSingleTap?() }
            return
        }

        let now = Date()
        if let lastTap = lastTapTime, now.timeIntervalSince(lastTap) < doubleTapInterval {
            pendingSingleTap?.cancel()
            pendingSingleTap = nil
            lastTapTime = nil
            DispatchQueue.main.async { self.onFnDoubleTap?() }
            return
        }

        lastTapTime = now
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastTapTime = nil
            self.pendingSingleTap = nil
            self.onFnSingleTap?()
        }
        pendingSingleTap = work
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapInterval, execute: work)
    }
}
