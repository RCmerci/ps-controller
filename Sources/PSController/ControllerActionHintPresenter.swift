import AppKit
import Foundation

protocol ControllerActionHintPresenting: AnyObject {
    func show(content: String)
    func hide()
}

final class ControllerActionHintPresenter: ControllerActionHintPresenting {
    private static let defaultActionLabel = "Default Key"

    private let panel: NSPanel
    private let hintView: ControllerActionHintView

    init(width: CGFloat = 920, height: CGFloat = 640) {
        let frame = NSRect(x: 0, y: 0, width: width, height: height)

        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = 22
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.96).cgColor

        hintView = ControllerActionHintView(frame: frame)
        hintView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(hintView)
        NSLayoutConstraint.activate([
            hintView.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            hintView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            hintView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            hintView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])

        panel.contentView = container
    }

    func show(content: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hintView.update(actionsByButton: Self.parse(content: content))
            self.positionPanel()
            self.panel.orderFrontRegardless()
        }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            self?.panel.orderOut(nil)
        }
    }

    private func positionPanel() {
        guard let visibleFrame = NSScreen.main?.visibleFrame else { return }

        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.midY - panel.frame.height / 2
        )

        panel.setFrameOrigin(origin)
    }

    private static func parse(content: String) -> [String: String] {
        var result: [String: String] = [:]

        for rawLine in content.split(separator: "\n") {
            let line = String(rawLine)
            guard let range = line.range(of: "->") else { continue }

            let key = line[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)

            guard !key.isEmpty else { continue }

            if value.isEmpty || value == "Unassigned" || value == "Default" {
                result[key] = Self.defaultActionLabel
            } else {
                result[key] = value
            }
        }

        return result
    }
}

private final class ControllerActionHintView: NSView {
    private struct MappingEntry {
        let key: String
        let shortName: String
    }

    private let entries: [MappingEntry] = [
        .init(key: "buttonMenu", shortName: "MENU"),
        .init(key: "buttonOptions", shortName: "OPT"),
        .init(key: "buttonHome", shortName: "HOME"),

        .init(key: "leftTrigger", shortName: "L2"),
        .init(key: "leftShoulder", shortName: "L1"),
        .init(key: "leftThumbstickButton", shortName: "L3"),
        .init(key: "touchpadButton", shortName: "TP"),

        .init(key: "rightTrigger", shortName: "R2"),
        .init(key: "rightShoulder", shortName: "R1"),
        .init(key: "rightThumbstickButton", shortName: "R3"),

        .init(key: "dpadUp", shortName: "D-Pad ↑"),
        .init(key: "dpadDown", shortName: "D-Pad ↓"),
        .init(key: "dpadLeft", shortName: "D-Pad ←"),
        .init(key: "dpadRight", shortName: "D-Pad →"),

        .init(key: "buttonY", shortName: "△"),
        .init(key: "buttonX", shortName: "□"),
        .init(key: "buttonB", shortName: "○"),
        .init(key: "buttonA", shortName: "✕")
    ]

    private var actionsByButton: [String: String] = [:]

    func update(actionsByButton: [String: String]) {
        self.actionsByButton = actionsByButton
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let canvas = bounds.insetBy(dx: 16, dy: 12)
        drawHeader(in: canvas)
        drawMappingTable(in: canvas)
    }

    private func drawHeader(in rect: CGRect) {
        let title = "Controller Button Mappings"
        let subtitle = "Direct mapping list (hold MENU to keep visible)"

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24, weight: .bold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.86)
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.black.withAlphaComponent(0.54)
        ]

        let titleSize = title.size(withAttributes: titleAttributes)
        let subtitleSize = subtitle.size(withAttributes: subtitleAttributes)

        title.draw(
            at: CGPoint(x: rect.midX - titleSize.width / 2, y: rect.maxY - 34),
            withAttributes: titleAttributes
        )
        subtitle.draw(
            at: CGPoint(x: rect.midX - subtitleSize.width / 2, y: rect.maxY - 54),
            withAttributes: subtitleAttributes
        )
    }

    private func drawMappingTable(in rect: CGRect) {
        let tableRect = CGRect(
            x: rect.minX + 12,
            y: rect.minY + 8,
            width: rect.width - 24,
            height: rect.height - 84
        )

        let panel = NSBezierPath(roundedRect: tableRect, xRadius: 10, yRadius: 10)
        NSColor.systemBlue.withAlphaComponent(0.06).setFill()
        panel.fill()
        NSColor.systemBlue.withAlphaComponent(0.20).setStroke()
        panel.lineWidth = 1
        panel.stroke()

        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.76)
        ]

        "Button".draw(at: CGPoint(x: tableRect.minX + 18, y: tableRect.maxY - 30), withAttributes: headerAttrs)
        "Action".draw(at: CGPoint(x: tableRect.minX + 280, y: tableRect.maxY - 30), withAttributes: headerAttrs)

        let divider = NSBezierPath()
        divider.move(to: CGPoint(x: tableRect.minX + 14, y: tableRect.maxY - 36))
        divider.line(to: CGPoint(x: tableRect.maxX - 14, y: tableRect.maxY - 36))
        NSColor.systemBlue.withAlphaComponent(0.25).setStroke()
        divider.lineWidth = 1
        divider.stroke()

        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.systemBlue.withAlphaComponent(0.95)
        ]

        let configuredActionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.84)
        ]

        let defaultActionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.systemOrange.withAlphaComponent(0.92)
        ]

        let rowHeight: CGFloat = 30
        var y = tableRect.maxY - 64

        for (index, entry) in entries.enumerated() {
            if y < tableRect.minY + 14 { break }

            if index % 2 == 0 {
                let altRow = NSBezierPath(
                    roundedRect: CGRect(x: tableRect.minX + 10, y: y - 4, width: tableRect.width - 20, height: rowHeight - 2),
                    xRadius: 6,
                    yRadius: 6
                )
                NSColor.systemBlue.withAlphaComponent(0.035).setFill()
                altRow.fill()
            }

            let keyText = "\(entry.shortName)  (\(entry.key))"
            let rawAction = normalizedAction(for: entry.key)
            let action = truncate(rawAction, maxLength: 74)
            let isDefaultAction = isDefaultActionLabel(rawAction)

            if isDefaultAction {
                drawDefaultActionHighlight(in: tableRect, rowY: y, rowHeight: rowHeight)
            }

            keyText.draw(at: CGPoint(x: tableRect.minX + 18, y: y + 4), withAttributes: keyAttrs)
            action.draw(
                at: CGPoint(x: tableRect.minX + 280, y: y + 4),
                withAttributes: isDefaultAction ? defaultActionAttrs : configuredActionAttrs
            )

            y -= rowHeight
        }

        let knownKeys = Set(entries.map(\.key))
        let extraKeys = actionsByButton.keys.filter { !knownKeys.contains($0) }.sorted()

        for key in extraKeys {
            if y < tableRect.minY + 14 { break }

            let rawAction = normalizedAction(for: key)
            let action = truncate(rawAction, maxLength: 74)
            let isDefaultAction = isDefaultActionLabel(rawAction)

            if isDefaultAction {
                drawDefaultActionHighlight(in: tableRect, rowY: y, rowHeight: rowHeight)
            }

            key.draw(at: CGPoint(x: tableRect.minX + 18, y: y + 4), withAttributes: keyAttrs)
            action.draw(
                at: CGPoint(x: tableRect.minX + 280, y: y + 4),
                withAttributes: isDefaultAction ? defaultActionAttrs : configuredActionAttrs
            )
            y -= rowHeight
        }
    }

    private func normalizedAction(for key: String) -> String {
        let action = actionsByButton[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return isDefaultActionLabel(action) ? "Default Key" : action
    }

    private func isDefaultActionLabel(_ action: String) -> Bool {
        let normalized = action.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty || normalized == "Unassigned" || normalized == "Default" || normalized == "Default Key"
    }

    private func drawDefaultActionHighlight(in tableRect: CGRect, rowY: CGFloat, rowHeight: CGFloat) {
        let highlightRect = CGRect(
            x: tableRect.minX + 270,
            y: rowY + 1,
            width: tableRect.width - 284,
            height: rowHeight - 8
        )
        let highlight = NSBezierPath(roundedRect: highlightRect, xRadius: 5, yRadius: 5)
        NSColor.systemOrange.withAlphaComponent(0.12).setFill()
        highlight.fill()
    }

    private func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 1)) + "…"
    }
}
