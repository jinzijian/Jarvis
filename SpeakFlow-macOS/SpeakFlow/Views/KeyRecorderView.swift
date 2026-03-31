import AppKit
import Carbon
import HotKey
import SwiftUI

// MARK: - Hotkey Action Definitions

enum HotkeyAction: String, CaseIterable, Identifiable {
    case voiceDictation = "voiceDictation"
    case screenshotVoice = "screenshotVoice"
    case fullScreenVoice = "fullScreenVoice"
    case agentVoice = "agentVoice"
    case bugReport = "bugReport"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .voiceDictation: return "Voice Dictation"
        case .screenshotVoice: return "Screenshot + Voice"
        case .fullScreenVoice: return "Full Screen + Voice"
        case .agentVoice: return "Agent Mode"
        case .bugReport: return "Bug Report"
        }
    }

    var description: String {
        switch self {
        case .voiceDictation: return "Press to start, press again to stop. Text appears at cursor."
        case .screenshotVoice: return "Capture a screen region, then describe what you need."
        case .fullScreenVoice: return "Silently captures your screen, then speak your instruction."
        case .agentVoice: return "Speak a command for the AI agent to execute autonomously."
        case .bugReport: return "Speak to report a bug. Your voice is transcribed and saved."
        }
    }

    var defaultKeyCombo: KeyCombo {
        switch self {
        case .voiceDictation: return KeyCombo(key: .z, modifiers: [.option])
        case .screenshotVoice: return KeyCombo(key: .z, modifiers: [.option, .shift])
        case .fullScreenVoice: return KeyCombo(key: .z, modifiers: [.control, .option])
        case .agentVoice: return KeyCombo(key: .a, modifiers: [.option])
        case .bugReport: return KeyCombo(key: .b, modifiers: [.option])
        }
    }

    var userDefaultsKey: String { "hotkey_\(rawValue)" }
}

// MARK: - Hotkey Bindings Manager

final class HotkeyBindingsManager: ObservableObject {
    static let shared = HotkeyBindingsManager()

    @Published var bindings: [HotkeyAction: KeyCombo]

    private init() {
        var loaded: [HotkeyAction: KeyCombo] = [:]
        for action in HotkeyAction.allCases {
            if let dict = UserDefaults.standard.dictionary(forKey: action.userDefaultsKey),
               let combo = KeyCombo(dictionary: dict) {
                loaded[action] = combo
            } else {
                loaded[action] = action.defaultKeyCombo
            }
        }
        self.bindings = loaded
    }

    func keyCombo(for action: HotkeyAction) -> KeyCombo {
        bindings[action] ?? action.defaultKeyCombo
    }

    func update(action: HotkeyAction, keyCombo: KeyCombo) {
        bindings[action] = keyCombo
        UserDefaults.standard.set(keyCombo.dictionary, forKey: action.userDefaultsKey)
        NotificationCenter.default.post(name: .hotkeyBindingsChanged, object: nil)
    }

    func resetToDefault(action: HotkeyAction) {
        bindings[action] = action.defaultKeyCombo
        UserDefaults.standard.removeObject(forKey: action.userDefaultsKey)
        NotificationCenter.default.post(name: .hotkeyBindingsChanged, object: nil)
    }

    func resetAllToDefaults() {
        for action in HotkeyAction.allCases {
            bindings[action] = action.defaultKeyCombo
            UserDefaults.standard.removeObject(forKey: action.userDefaultsKey)
        }
        NotificationCenter.default.post(name: .hotkeyBindingsChanged, object: nil)
    }

    func isDefault(action: HotkeyAction) -> Bool {
        let current = keyCombo(for: action)
        let def = action.defaultKeyCombo
        return current.carbonKeyCode == def.carbonKeyCode && current.carbonModifiers == def.carbonModifiers
    }

    /// Check if a key combo conflicts with another action
    func conflictingAction(for combo: KeyCombo, excluding: HotkeyAction) -> HotkeyAction? {
        for action in HotkeyAction.allCases where action != excluding {
            let existing = keyCombo(for: action)
            if existing.carbonKeyCode == combo.carbonKeyCode && existing.carbonModifiers == combo.carbonModifiers {
                return action
            }
        }
        return nil
    }
}

extension Notification.Name {
    static let hotkeyBindingsChanged = Notification.Name("hotkeyBindingsChanged")
}

// MARK: - Key Recorder View

struct KeyRecorderView: View {
    let action: HotkeyAction
    @ObservedObject var manager: HotkeyBindingsManager
    @Binding var recordingAction: HotkeyAction?
    @State private var conflictMessage: String?

    private var isRecording: Bool { recordingAction == action }
    private var combo: KeyCombo { manager.keyCombo(for: action) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Key combo display / recorder button
            Button {
                if isRecording {
                    recordingAction = nil
                } else {
                    conflictMessage = nil
                    recordingAction = action
                }
            } label: {
                Text(isRecording ? "Type shortcut..." : combo.description)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(minWidth: 120)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        isRecording
                            ? Color.accentColor.opacity(0.15)
                            : Color(nsColor: .windowBackgroundColor)
                    )
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                isRecording ? Color.accentColor : Color(nsColor: .separatorColor),
                                lineWidth: isRecording ? 1.5 : 0.5
                            )
                    )
            }
            .buttonStyle(.plain)
            .background(
                isRecording
                    ? KeyEventCaptureView { keyCode, modifiers in
                        handleCapturedKey(keyCode: keyCode, modifiers: modifiers)
                    }
                    .frame(width: 0, height: 0)
                    : nil
            )

            // Action info
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 13, weight: .medium))
                Text(action.description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                if let conflict = conflictMessage {
                    Text(conflict)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            // Reset button
            if !manager.isDefault(action: action) {
                Button {
                    manager.resetToDefault(action: action)
                    conflictMessage = nil
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset to default")
            }
        }
    }

    private func handleCapturedKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        // Escape cancels recording
        if keyCode == 53 {
            recordingAction = nil
            return
        }

        // Require at least one modifier
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        guard !mods.isEmpty else { return }

        let newCombo = KeyCombo(carbonKeyCode: UInt32(keyCode), carbonModifiers: mods.carbonFlags)

        // Check conflicts
        if let conflict = manager.conflictingAction(for: newCombo, excluding: action) {
            conflictMessage = "Conflicts with \"\(conflict.title)\""
            return
        }

        conflictMessage = nil
        manager.update(action: action, keyCombo: newCombo)
        recordingAction = nil
    }
}

// MARK: - NSView wrapper to capture key events

private struct KeyEventCaptureView: NSViewRepresentable {
    let onKeyDown: (UInt16, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onKeyDown = onKeyDown
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onKeyDown = onKeyDown
    }
}

class KeyCaptureNSView: NSView {
    var onKeyDown: ((UInt16, NSEvent.ModifierFlags) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event.keyCode, event.modifierFlags)
    }
}

// MARK: - Shortcuts Settings Section

// MARK: - Quick Shortcut Recorder

/// Which quick shortcut slot is being recorded
enum QuickShortcutSlot: Hashable {
    case trigger        // modifier key for tap / double-tap
    case screenshot     // trigger + modifier combo
    case fullScreen     // trigger + key combo
}

/// Captures a modifier-only key press (for trigger key recording)
private struct ModifierKeyCaptureView: NSViewRepresentable {
    let onFlagsChanged: (UInt16, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> ModifierCaptureNSView {
        let view = ModifierCaptureNSView()
        view.onFlagsChanged = onFlagsChanged
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: ModifierCaptureNSView, context: Context) {
        nsView.onFlagsChanged = onFlagsChanged
    }
}

class ModifierCaptureNSView: NSView {
    var onFlagsChanged: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    var onKeyDown: ((UInt16, NSEvent.ModifierFlags) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func flagsChanged(with event: NSEvent) {
        onFlagsChanged?(event.keyCode, event.modifierFlags)
    }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event.keyCode, event.modifierFlags)
    }
}

/// Captures a modifier+key combo (for full screen key recording)
private struct ComboKeyCaptureView: NSViewRepresentable {
    let onKeyDown: (UInt16, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> ModifierCaptureNSView {
        let view = ModifierCaptureNSView()
        view.onKeyDown = onKeyDown
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: ModifierCaptureNSView, context: Context) {
        nsView.onKeyDown = onKeyDown
    }
}

// MARK: - Shortcuts Settings Section

struct ShortcutsSettingsView: View {
    @ObservedObject var manager = HotkeyBindingsManager.shared
    @ObservedObject var quickConfig = QuickShortcutConfig.shared
    @State private var recordingAction: HotkeyAction?
    @State private var recordingSlot: QuickShortcutSlot?
    @State private var showAlternateShortcuts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Primary: Quick shortcuts (editable)
            quickShortcutRow(
                shortcut: quickConfig.triggerKeyName,
                action: "Voice Dictation",
                detail: "Tap to start/stop. Text appears at cursor.",
                slot: .trigger
            )
            Divider()
            quickShortcutRow(
                shortcut: "\(quickConfig.triggerKeyName) × 2",
                action: "Agent Mode",
                detail: "Double-tap to start. Speak a command for the AI agent.",
                slot: nil  // derived from trigger, not independently editable
            )
            Divider()
            quickShortcutRow(
                shortcut: quickConfig.screenshotDisplayName,
                action: "Screenshot + Voice",
                detail: "Capture a screen region, then describe what you need.",
                slot: .screenshot
            )
            Divider()
            quickShortcutRow(
                shortcut: quickConfig.fullScreenDisplayName,
                action: "Full Screen + Voice",
                detail: "Silently captures your screen, then speak your instruction.",
                slot: .fullScreen
            )
            Divider()
            quickShortcutRow(
                shortcut: quickConfig.contextDisplayName,
                action: "Context Mode",
                detail: "Select text first, then speak to transform or ask about it.",
                slot: nil  // derived from trigger
            )

            Divider()

            // Alternate shortcuts (collapsible)
            DisclosureGroup(isExpanded: $showAlternateShortcuts) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(HotkeyAction.allCases.enumerated()), id: \.element.id) { index, action in
                        KeyRecorderView(
                            action: action,
                            manager: manager,
                            recordingAction: $recordingAction
                        )
                        if index < HotkeyAction.allCases.count - 1 {
                            Divider()
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Reset All to Defaults") {
                            manager.resetAllToDefaults()
                            recordingAction = nil
                        }
                        .controlSize(.small)
                        .disabled(HotkeyAction.allCases.allSatisfy { manager.isDefault(action: $0) })
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Alternate Shortcuts")
                    .font(.system(size: 12, weight: .medium))
            }
        }
    }

    @ViewBuilder
    private func quickShortcutRow(shortcut: String, action: String, detail: String, slot: QuickShortcutSlot?) -> some View {
        let isRecordingThis = slot != nil && recordingSlot == slot

        HStack(alignment: .top, spacing: 12) {
            Button {
                if let slot {
                    if isRecordingThis {
                        recordingSlot = nil
                    } else {
                        recordingSlot = slot
                    }
                }
            } label: {
                Text(isRecordingThis ? "Press key..." : shortcut)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(minWidth: 120)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        isRecordingThis
                            ? Color.accentColor.opacity(0.15)
                            : Color(nsColor: .windowBackgroundColor)
                    )
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                isRecordingThis ? Color.accentColor : Color(nsColor: .separatorColor),
                                lineWidth: isRecordingThis ? 1.5 : 0.5
                            )
                    )
            }
            .buttonStyle(.plain)
            .disabled(slot == nil)
            .background(
                Group {
                    if isRecordingThis, let slot {
                        captureView(for: slot)
                            .frame(width: 0, height: 0)
                    }
                }
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(action)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func captureView(for slot: QuickShortcutSlot) -> some View {
        switch slot {
        case .trigger:
            ModifierKeyCaptureView { keyCode, flags in
                // Accept modifier key presses (Control, Option, Shift, Command)
                if modifierFlag(for: keyCode) != nil && keyCode != 0 {
                    quickConfig.triggerKeyCode = keyCode
                    recordingSlot = nil
                }
            }
        case .screenshot:
            ModifierKeyCaptureView { keyCode, flags in
                // Accept a modifier that's different from the trigger
                if let flag = modifierFlag(for: keyCode),
                   flag != quickConfig.triggerModifierFlag {
                    quickConfig.screenshotModifier = flag
                    recordingSlot = nil
                }
            }
        case .fullScreen:
            ComboKeyCaptureView { keyCode, flags in
                // Escape cancels
                if keyCode == 53 {
                    recordingSlot = nil
                    return
                }
                // Accept any letter/number key
                quickConfig.fullScreenKeyCode = keyCode
                recordingSlot = nil
            }
        }
    }
}
