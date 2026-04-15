import ApplicationServices
import CoreGraphics
import Foundation

protocol MouseEventBridging {
    @discardableResult
    func requestAccessibilityIfNeeded(prompt: Bool) -> Bool
    func moveCursor(normalizedX: Double, normalizedY: Double)
    func leftClick()
    func rightClick()
    func scroll(lines: Int32)
}

final class MouseEventBridge: MouseEventBridging {
    private let pointerSpeed: Double

    init(pointerSpeed: Double = 22.0) {
        self.pointerSpeed = pointerSpeed
    }

    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestAccessibilityIfNeeded(prompt: Bool = true) -> Bool {
        guard !AXIsProcessTrusted() else { return true }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func moveCursor(normalizedX: Double, normalizedY: Double) {
        guard isAccessibilityGranted else { return }
        guard abs(normalizedX) > 0.01 || abs(normalizedY) > 0.01 else { return }
        guard let currentLocation = CGEvent(source: nil)?.location else { return }

        let deltaX = normalizedX * pointerSpeed
        let deltaY = normalizedY * pointerSpeed

        let nextPoint = CGPoint(
            x: currentLocation.x + deltaX,
            y: currentLocation.y - deltaY
        )

        CGWarpMouseCursorPosition(nextPoint)
    }

    func leftClick() {
        click(button: .left)
    }

    func rightClick() {
        click(button: .right)
    }

    func scroll(lines: Int32) {
        guard isAccessibilityGranted else { return }
        guard lines != 0 else { return }

        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: lines,
            wheel2: 0,
            wheel3: 0
        ) else {
            return
        }

        scrollEvent.post(tap: .cghidEventTap)
    }

    private func click(button: CGMouseButton) {
        guard isAccessibilityGranted else { return }
        guard let location = CGEvent(source: nil)?.location else { return }

        let downType: CGEventType = (button == .left) ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = (button == .left) ? .leftMouseUp : .rightMouseUp

        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: downType,
            mouseCursorPosition: location,
            mouseButton: button
        ),
        let up = CGEvent(
            mouseEventSource: nil,
            mouseType: upType,
            mouseCursorPosition: location,
            mouseButton: button
        ) else {
            return
        }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
