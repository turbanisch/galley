import AppKit

/// The list of keyboard shortcuts (? or the Help menu): a panel with the keys in a grid, grouped
/// under section headings, in two columns. Single keys can't be shown in the menus (they would
/// fire while typing in the search field), so this is where they are listed.
final class ShortcutsPanel: NSPanel {
    static let shared = ShortcutsPanel()

    private typealias Section = (title: String, rows: [(keys: String, what: String)])

    private static let leftSections: [Section] = [
        ("Reading", [
            ("B", "Sidebar"),
            ("F or /", "Search"),
            ("G", "Go to"),
            ("S", "Split view"),
            ("Z", "Zoom mode (⇧Z back)"),
            ("D", "Page colour (⇧D back)"),
            ("+  −", "Zoom in, out"),
            ("Space", "Auto-scroll (+ − speed)"),
            ("Esc", "Close preview, search or split view"),
            ("?", "This list"),
        ]),
        ("Moving", [
            ("↑  ↓", "Scroll"),
            ("←  →", "Pages"),
            ("H J K L", "Like ← ↓ ↑ →"),
            ("⌥↑  ⌥↓", "Headings"),
            ("⌥⇧↑  ⌥⇧↓", "Chapters"),
            ("⌘↑  ⌘↓", "Start, end"),
            ("⌘⌥←  ⌘⌥→", "Back, forward"),
        ]),
        ("Highlights", [
            ("M", "Highlight, or remove it"),
            ("U", "Underline, or remove it"),
            ("1–8", "Colour"),
            ("A", "Comment"),
            ("Delete", "Remove"),
        ]),
    ]

    private static let rightSections: [Section] = [
        ("Links", [
            ("Hover", "Preview"),
            ("Click", "Jump"),
            ("⌘-click", "Open in split view"),
            ("S", "Preview's target in split view"),
            ("R", "Link hints"),
        ]),
        ("Link hints", [
            ("Label", "Open in split view"),
            ("Hold", "Preview"),
            ("⇧ Label", "Jump"),
        ]),
        ("Go to", [
            ("1 2 3 …", "Page"),
            ("S F T E", "Section, figure, table, equation"),
            ("N R A", "Note, reference, annotation"),
        ]),
        ("In Search and Go to", [
            ("↑  ↓", "Show each match"),
            ("Return", "Stay there"),
            ("⌘Return", "Show it in split view"),
            ("Esc", "Back to where you were"),
        ]),
        ("Slide show", [
            ("⇧⌘F", "Start, end"),
            ("Space", "Next page (⇧Space back)"),
        ]),
    ]

    private init() {
        super.init(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        title = "Keyboard Shortcuts"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let left = Self.grid(Self.leftSections), right = Self.grid(Self.rightSections)
        let content = NSView()
        for grid in [left, right] {
            grid.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(grid)
            NSLayoutConstraint.activate([
                grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
                grid.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            ])
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 28),
            right.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
        ])
        contentView = content
        setContentSize(content.fittingSize)
    }

    /// Keys right-aligned against what they do; each section's heading over the second column.
    private static func grid(_ sections: [Section]) -> NSGridView {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 4
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        for (index, section) in sections.enumerated() {
            let heading = NSTextField(labelWithString: section.title)
            heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            let headingRow = grid.addRow(with: [NSGridCell.emptyContentView, heading])
            if index > 0 { headingRow.topPadding = 12 }
            headingRow.bottomPadding = 2
            for row in section.rows {
                grid.addRow(with: [NSTextField(labelWithString: row.keys), NSTextField(labelWithString: row.what)])
            }
        }
        grid.setContentHuggingPriority(.required, for: .vertical)   // the shorter column isn't stretched
        return grid
    }

    func toggle() {
        if isVisible { close(); return }
        center()
        makeKeyAndOrderFront(nil)
    }

    // ? again or Esc closes the list.
    override func keyDown(with event: NSEvent) {
        if event.characters == "?" { close() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { close() }
}
