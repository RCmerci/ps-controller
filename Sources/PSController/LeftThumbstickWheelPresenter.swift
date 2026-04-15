import AppKit
import Foundation

protocol LeftThumbstickWheelPresenting: AnyObject {
    func show(slots: [ThumbstickWheelSlot], selectedIndex: Int)
    func updateSelection(selectedIndex: Int, slots: [ThumbstickWheelSlot])
    func hide()
}

final class LeftThumbstickWheelPresenter: LeftThumbstickWheelPresenting {
    private let panel: NSPanel
    private let wheelView: LeftThumbstickWheelView

    init(size: CGFloat = 360) {
        let frame = NSRect(x: 0, y: 0, width: size, height: size)
        self.wheelView = LeftThumbstickWheelView(frame: frame)

        self.panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = wheelView
    }

    func show(slots: [ThumbstickWheelSlot], selectedIndex: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.wheelView.update(slots: slots, selectedIndex: selectedIndex)
            self.centerPanelOnMainScreen()
            self.panel.orderFrontRegardless()
        }
    }

    func updateSelection(selectedIndex: Int, slots: [ThumbstickWheelSlot]) {
        DispatchQueue.main.async { [weak self] in
            self?.wheelView.update(slots: slots, selectedIndex: selectedIndex)
        }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            self?.panel.orderOut(nil)
        }
    }

    private func centerPanelOnMainScreen() {
        guard let screenFrame = NSScreen.main?.visibleFrame else { return }

        let origin = NSPoint(
            x: screenFrame.midX - (panel.frame.width / 2),
            y: screenFrame.midY - (panel.frame.height / 2)
        )

        panel.setFrameOrigin(origin)
    }
}

private final class LeftThumbstickWheelView: NSView {
    private var slots: [ThumbstickWheelSlot] = []
    private var selectedIndex: Int = 0

    func update(slots: [ThumbstickWheelSlot], selectedIndex: Int) {
        self.slots = slots
        self.selectedIndex = selectedIndex
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard slots.count == 6 else { return }

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) * 0.45

        for index in 0..<6 {
            let centerAngle = centerAngleDegrees(for: index)
            let startAngle = centerAngle - 30.0
            let endAngle = centerAngle + 30.0

            let segment = NSBezierPath()
            segment.move(to: center)
            segment.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle)
            segment.close()

            if index == selectedIndex {
                NSColor.systemBlue.withAlphaComponent(0.9).setFill()
            } else {
                NSColor.black.withAlphaComponent(0.65).setFill()
            }

            segment.fill()

            NSColor.white.withAlphaComponent(0.25).setStroke()
            segment.lineWidth = 1.0
            segment.stroke()

            drawTitle(for: index, center: center, radius: radius)
        }

        let innerRadius = radius * 0.38
        let innerCircle = NSBezierPath(ovalIn: NSRect(
            x: center.x - innerRadius,
            y: center.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        ))

        NSColor.black.withAlphaComponent(0.8).setFill()
        innerCircle.fill()

        let centerTitle = "Left Stick"
        let centerAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
        ]

        let centerSize = centerTitle.size(withAttributes: centerAttributes)
        centerTitle.draw(at: NSPoint(x: center.x - centerSize.width / 2, y: center.y - centerSize.height / 2), withAttributes: centerAttributes)
    }

    private func drawTitle(for index: Int, center: NSPoint, radius: CGFloat) {
        let title = slots[index].title
        let angle = centerAngleDegrees(for: index) * (.pi / 180)
        let textRadius = radius * 0.68

        let position = NSPoint(
            x: center.x + (cos(angle) * textRadius),
            y: center.y + (sin(angle) * textRadius)
        )

        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]

        let size = title.size(withAttributes: attributes)
        let drawPoint = NSPoint(x: position.x - size.width / 2, y: position.y - size.height / 2)
        title.draw(at: drawPoint, withAttributes: attributes)
    }

    private func centerAngleDegrees(for index: Int) -> CGFloat {
        90.0 - (CGFloat(index) * 60.0)
    }
}
