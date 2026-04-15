import Foundation
import CoreGraphics
import OSLog

protocol TextInputInjecting {
    @discardableResult
    func insertAtCursor(text: String) -> Bool
}

final class CGEventTextInputInjector: TextInputInjecting {
    private let logger: Logger

    init(logger: Logger = Logger(subsystem: "PSController", category: "TextInput")) {
        self.logger = logger
    }

    @discardableResult
    func insertAtCursor(text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            logDebug("text_input_skip_empty")
            return false
        }

        let utf16 = Array(normalized.utf16)

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            logError("text_input_event_create_failed")
            return false
        }

        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        logInfo("text_input_inserted chars=\(normalized.count)")
        return true
    }

    private func logInfo(_ message: String) {
        logger.info("\(message, privacy: .public)")
        AppFileLogger.shared.info(category: "TextInput", message)
    }

    private func logDebug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        AppFileLogger.shared.debug(category: "TextInput", message)
    }

    private func logError(_ message: String) {
        logger.error("\(message, privacy: .public)")
        AppFileLogger.shared.error(category: "TextInput", message)
    }
}
