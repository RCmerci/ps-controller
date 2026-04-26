import Foundation
import CoreGraphics
import OSLog

protocol KeyboardShortcutInjecting {
    @discardableResult
    func postKeyEvent(keyCode: CGKeyCode, modifiers: CGEventFlags, isKeyDown: Bool) -> Bool
}

final class CGEventKeyboardShortcutInjector: KeyboardShortcutInjecting {
    private let logger: Logger

    init(logger: Logger = Logger(subsystem: "PSController", category: "KeyboardShortcut")) {
        self.logger = logger
    }

    @discardableResult
    func postKeyEvent(keyCode: CGKeyCode, modifiers: CGEventFlags, isKeyDown: Bool) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isKeyDown) else {
            logError("keyboard_shortcut_event_create_failed keyCode=\(keyCode) keyDown=\(isKeyDown)")
            return false
        }

        event.flags = modifiers
        event.post(tap: .cghidEventTap)
        logInfo("keyboard_shortcut_posted keyCode=\(keyCode) keyDown=\(isKeyDown) modifiers=\(modifiers.rawValue)")
        return true
    }

    private func logInfo(_ message: String) {
        logger.info("\(message, privacy: .public)")
        AppFileLogger.shared.info(category: "KeyboardShortcut", message)
    }

    private func logError(_ message: String) {
        logger.error("\(message, privacy: .public)")
        AppFileLogger.shared.error(category: "KeyboardShortcut", message)
    }
}
