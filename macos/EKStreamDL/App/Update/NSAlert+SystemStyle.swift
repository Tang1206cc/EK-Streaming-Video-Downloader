import AppKit

extension NSAlert {
    private func applySystemButtonStyle() {
        for (index, button) in buttons.enumerated() {
            button.isBordered = true
            button.bezelStyle = .rounded
            button.controlSize = .large
            button.keyEquivalent = index == 0 ? "\r" : ""
            button.bezelColor = index == 0 ? .controlAccentColor : nil

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = button.alignment
            let textColor: NSColor = index == 0 ? .white : .labelColor
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle,
            ]
            let attributedTitle = NSAttributedString(string: button.title, attributes: attributes)
            button.attributedTitle = attributedTitle
            button.attributedAlternateTitle = attributedTitle
        }
    }

    @discardableResult
    func runModalWithSystemStyle() -> NSApplication.ModalResponse {
        applySystemButtonStyle()
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        return runModal()
    }
}
