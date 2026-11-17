import AppKit

/// A transparent layer over the window for the link hint labels; clicks go through it.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One link hint label, in the style of a small yellow tag.
final class HintLabel: NSView {
    let text: String
    private let field: NSTextField

    init(text: String) {
        self.text = text
        field = NSTextField(labelWithString: text.uppercased())
        field.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        field.textColor = .black
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 1, green: 0.85, blue: 0.3, alpha: 1).cgColor
        layer?.cornerRadius = 3
        layer?.borderColor = NSColor(calibratedWhite: 0, alpha: 0.35).cgColor
        layer?.borderWidth = 0.5
        addSubview(field)
        field.sizeToFit()
        let size = NSSize(width: field.frame.width + 6, height: field.frame.height + 1)
        setFrameSize(size)
        field.setFrameOrigin(NSPoint(x: 3, y: 0.5))
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Shows how much of the label has been typed: typed letters dimmed.
    func show(typed: String) {
        let string = NSMutableAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.black,
        ])
        string.addAttribute(.foregroundColor, value: NSColor(calibratedWhite: 0, alpha: 0.35),
                            range: NSRange(location: 0, length: min(typed.count, text.count)))
        field.attributedStringValue = string
    }

    /// Labels for `count` links: single letters when they suffice, otherwise two letters each
    /// (so no label is the beginning of another). Home row first; no Y/Z (swapped on German
    /// keyboards) and no R (pressing R again hides the labels).
    static func labels(count: Int) -> [String] {
        let alphabet = Array("asdfjklghqweuiopxcvnmtb").map(String.init)
        if count <= alphabet.count { return Array(alphabet.prefix(count)) }
        var result: [String] = []
        for first in alphabet {
            for second in alphabet {
                result.append(first + second)
                if result.count == count { return result }
            }
        }
        return result
    }
}
