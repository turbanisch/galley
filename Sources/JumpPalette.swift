import AppKit
import PDFKit

/// The jump palette (G): go to a page, section, figure, table, equation, note, reference list
/// entry or annotation. A pop-up picks the type, the field takes a number or words, the matches
/// are listed below. The first key typed picks the type (P S F T E N R A); a digit or any other key goes into
/// the field, with the type as it is (Page at first). Backspace in the empty field picks the type
/// again. ↑/↓ or a click shows the selected match in the document, the palette staying open;
/// Return jumps, ⌘Return shows the target in the split view, Esc cancels (back to where the
/// reading was).
@MainActor
final class JumpPalette: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    enum Target {
        case page(Int)
        case section(OutlineNode)
        case spot(PDFDestination)
        case annotation(PDFAnnotation)
    }

    struct Entry {
        /// What the list shows ("3.2 Robustness checks", "Table 3: Summary statistics").
        let title: String
        /// The number it goes by ("3.2", "3", "IV"), matched before the words.
        let number: String?
        /// More words to match (an entry's author names and year).
        var keywords = ""
        let pageIndex: Int
        /// The top-level section it is in ("5 Results", "Appendix").
        var section: String? = nil
        let target: Target
        /// Annotations: the comment (the title is the highlighted text) and the highlight's colour.
        var comment: String? = nil
        var color: NSColor? = nil
    }

    struct Kind {
        let key: Character
        /// Singular, lowercase ("table").
        let name: String
        let entries: [Entry]
    }


    let panel: JumpPanel
    private let kinds: [Kind]
    private let pages: (String, Bool) -> [Entry]
    /// Next to the page field, for PDFs with printed page numbers: "as printed" or "in PDF".
    private let numbering = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hasPrintedPages: Bool
    /// Called when the page numbering is switched (the window keeps it for next time).
    var onNumberingChange: ((Bool) -> Void)?
    private let onChoose: (Target, Bool) -> Void
    private let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let field = NSTextField(string: "")
    private let table = NSTableView()
    /// How many there are ("16 equations", "None found").
    private let status = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    /// Hidden for pages (the list and the buttons).
    private var listViews: [NSView] = []
    private var isCompact: Bool?
    private var fullSize: NSSize
    private var content: NSStackView?
    private var fullWidth: [NSLayoutConstraint] = []
    private var compactWidth: [NSLayoutConstraint] = []
    private var matches: [Entry] = []
    /// The next key picks the type (right after G, or after Backspace in the empty field).
    private var choosingType = true

    /// `kinds` starts with the pages (key "p", whose matches come from `pages`). Types the
    /// document has nothing of are listed too: an empty list says so.
    private let pageCount: Int

    init(kinds: [Kind], pageCount: Int, hasPrintedPages: Bool = false, pagesAsPrinted: Bool = false,
         pages: @escaping (String, Bool) -> [Entry], onChoose: @escaping (Target, Bool) -> Void) {
        self.kinds = kinds
        self.pages = pages
        self.hasPrintedPages = hasPrintedPages
        self.pageCount = pageCount
        self.onChoose = onChoose
        // A floating panel over the window, not a sheet: a click outside, switching away or Esc
        // closes it, and it doesn't hold up the window or the app (⌘Q). Resizable, for papers
        // with long captions, and movable by its background (out of the way while stepping
        // through matches); size and place are remembered, a double-click on the background
        // puts it back.
        // Pages need only the field: the panel starts small and grows to its full size for the
        // other types.
        fullSize = UserDefaults.standard.string(forKey: Self.sizeKey).map(NSSizeFromString) ?? Self.defaultSize
        panel = JumpPanel(contentRect: NSRect(origin: .zero, size: fullSize),
                          styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.contentMinSize = NSSize(width: 460, height: 300)
        panel.isMovableByWindowBackground = true
        super.init()
        panel.delegate = self

        for kind in kinds {
            let name = kind.name.prefix(1).uppercased() + kind.name.dropFirst()
            popUp.addItem(withTitle: "\(name) (\(kind.key.uppercased()))")   // its key, as in a menu
        }
        popUp.target = self
        popUp.action = #selector(typeChosen(_:))
        field.delegate = self
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        numbering.addItems(withTitles: ["as printed", "in PDF"])     // reads on: "Page 362 as printed"
        numbering.selectItem(at: pagesAsPrinted ? 0 : 1)
        numbering.target = self
        numbering.action = #selector(numberingChosen(_:))
        numbering.toolTip = "Page numbers as printed on the pages, or counted in the PDF (Tab switches)"
        let row = NSStackView(views: [popUp, field, numbering])
        row.orientation = .horizontal
        row.spacing = 8


        // One line per match with its page on the right; the selected one in full (appendix
        // captions often differ only at the end), with the section it is in underneath.
        let column = NSTableColumn(identifier: Self.cellID)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .fullWidth
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.refusesFirstResponder = true      // typing stays in the field
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        table.doubleAction = #selector(doubleClicked(_:))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelAction(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let go = NSButton(title: "Go", target: self, action: #selector(go(_:)))
        go.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, go])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        listViews = [status, scroll, buttons]
        let content = NSStackView(views: [row, status, scroll, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.setCustomSpacing(6, after: row)
        content.setCustomSpacing(14, after: scroll)
        content.setHuggingPriority(.defaultLow, for: .vertical)
        self.content = content
        fullWidth = [row, status, scroll].map { $0.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40) }
        compactWidth = [field.widthAnchor.constraint(equalToConstant: 48)]

        panel.onCommandReturn = { [weak self] in self?.choose(inSplit: true) }
        panel.onMenuShortcut = { [weak self] in self?.close() }
        panel.onBackgroundDoubleClick = { [weak self] in self?.resetPlace() }
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        panel.initialFirstResponder = field
        refresh()
    }

    private static let sizeKey = "GalleyJumpPaletteSize"
    private static let placeKey = "GalleyJumpPalettePlace"
    private static let defaultSize = NSSize(width: 600, height: 520)
    /// Where the middle of its top edge goes, as fractions of the window's width and height
    /// from its top left: centred, a little above the middle.
    private static let defaultPlace = NSPoint(x: 0.5, y: 0.22)
    /// Called once the palette has closed (chosen, cancelled or clicked away).
    var onClose: (() -> Void)?
    /// Called when ↑/↓ or a click selects a match: the document shows it, the palette stays open.
    var onFollow: ((Target) -> Void)?
    /// Called when Esc or Cancel closes the palette.
    var onCancel: (() -> Void)?
    private var isClosed = false

    /// Shows the palette over `window`, where it was last time.
    func show(over window: NSWindow) {
        let place = UserDefaults.standard.string(forKey: Self.placeKey).map(NSPointFromString) ?? Self.defaultPlace
        panel.setFrame(frame(size: panel.frame.size, place: place, over: window), display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        panel.layoutIfNeeded()
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func frame(size: NSSize, place: NSPoint, over window: NSWindow) -> NSRect {
        let parent = window.frame
        var origin = NSPoint(x: parent.minX + parent.width * place.x - size.width / 2,
                             y: parent.maxY - parent.height * place.y - size.height)
        if let visible = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        return NSRect(origin: origin, size: size)
    }

    /// Double-click on the background: back to the usual size and place.
    private func resetPlace() {
        guard let window = panel.parent else { return }
        UserDefaults.standard.removeObject(forKey: Self.placeKey)
        UserDefaults.standard.removeObject(forKey: Self.sizeKey)
        fullSize = Self.defaultSize
        let size = isCompact == true ? panel.frame.size : fullSize
        panel.setFrame(frame(size: size, place: Self.defaultPlace, over: window), display: true, animate: true)
    }

    /// Small (pages: field and status line only) or full size (a list of matches), keeping the
    /// top edge and the middle in place.
    private func setCompact(_ compact: Bool) {
        guard compact != isCompact else { return }
        if isCompact == false { fullSize = panel.frame.size }
        isCompact = compact
        for view in listViews { view.isHidden = compact }
        NSLayoutConstraint.deactivate(compact ? fullWidth : compactWidth)
        NSLayoutConstraint.activate(compact ? compactWidth : fullWidth)
        content?.edgeInsets = compact ? NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
                                      : NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        var size = fullSize
        if compact {
            size = compactSize()
            panel.contentMinSize = size
            panel.contentMaxSize = size
        } else {
            panel.contentMinSize = NSSize(width: 460, height: 300)
            panel.contentMaxSize = NSSize(width: 10000, height: 10000)
        }
        let old = panel.frame
        let frame = NSRect(x: old.midX - size.width / 2, y: old.maxY - size.height, width: size.width, height: size.height)
        panel.setFrame(frame, display: true, animate: panel.isVisible)
        if !compact { table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count)) }
    }

    private func compactSize() -> NSSize {
        panel.contentView?.layoutSubtreeIfNeeded()
        return panel.contentView?.fittingSize ?? NSSize(width: 240, height: 60)
    }

    private var kind: Kind { kinds[max(popUp.indexOfSelectedItem, 0)] }

    private var pagesAsPrinted: Bool { hasPrintedPages && numbering.indexOfSelectedItem == 0 }

    private func refresh() {
        numbering.isHidden = !(kind.key == "p" && hasPrintedPages)
        setCompact(kind.key == "p")
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        let ranked = kind.key == "p" ? [] : Self.rank(kind.entries, query)
        // Figures, tables, equations, notes and entries come under the top-level section they are in (a
        // heading row each), in document order, also while typing; the best match is selected.
        let splitIntoSections = "ftenra".contains(kind.key) && kind.entries.contains { $0.section != nil }
        matches = kind.key == "p" ? pages(query, pagesAsPrinted) : (splitIntoSections ? ranked.sorted() : ranked).map { kind.entries[$0] }
        let best = splitIntoSections ? ranked.first.flatMap { ranked.sorted().firstIndex(of: $0) } : 0
        field.placeholderString = kind.key == "p" ? nil : "Number or words"
        let sections = matches.map(\.section)
        if splitIntoSections {
            rows = []
            var current: String??
            for (index, section) in sections.enumerated() {
                if current != .some(section) {
                    rows.append(.heading(section ?? "Before the first section"))
                    current = .some(section)
                }
                rows.append(.match(index))
            }
        } else {
            rows = matches.indices.map { .match($0) }
        }
        let first = best.flatMap { best in rows.firstIndex { if case .match(best) = $0 { return true } else { return false } } }
        expandedRow = first ?? -1
        table.reloadData()
        let plural = kind.name + "s"
        if kind.key == "p" {
            status.stringValue = ""
        } else if kind.entries.isEmpty {
            status.stringValue = "No \(plural) found in this document"
        } else if query.isEmpty {
            status.stringValue = "\(kind.entries.count) \(kind.entries.count == 1 ? kind.name : plural)"
        } else {
            status.stringValue = "\(matches.count) of \(kind.entries.count) \(kind.entries.count == 1 ? kind.name : plural)"
        }
        if let first {
            table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
            table.scrollRowToVisible(0)
            table.scrollRowToVisible(first)
        }

    }

    /// Exact number first ("3", "IV", "(12)"), then numbers starting with it ("3" → 3.1, 3.2;
    /// also after a letter prefix: "21" → A.21),
    /// then entries with every typed word at the start of one of their words (those starting with
    /// the first typed word first: an entry's first author, a caption's first word), then any that
    /// contain the text (from three characters on). In document order within each group.
    /// A number alone ("3", "A.1") only matches numbers, not years or values in a caption.
    static func filter(_ entries: [Entry], _ query: String) -> [Entry] { rank(entries, query).map { entries[$0] } }

    /// The indices of the matching entries, best first (see `filter`).
    static func rank(_ entries: [Entry], _ query: String) -> [Int] {
        func fold(_ string: String) -> String { string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        func words(_ string: String) -> [Substring] { string.split { !$0.isLetter && !$0.isNumber } }
        func withoutPrefix(_ number: String) -> String {
            String(number.drop { $0.isLetter }.drop { $0 == "." || $0 == "-" })
        }
        let typed = fold(query)
        guard !typed.isEmpty else { return Array(entries.indices) }
        let typedWords = words(typed)
        let numberOnly = typed.contains(where: \.isNumber) && !typed.contains(" ")
        var ranked: [(rank: Int, order: Int)] = []
        for (order, entry) in entries.enumerated() {
            let number = entry.number.map(fold)
            let text = fold(entry.title + " " + entry.keywords)
            let rank: Int
            if let number, number == typed || "(\(number))" == typed {
                rank = 0
            } else if let number, !typed.contains(" "),
                      number.hasPrefix(typed) || withoutPrefix(number).hasPrefix(typed) {
                rank = 1      // (also "21" for A.21: the number after a letter prefix)
            } else if numberOnly {
                continue
            } else if !typedWords.isEmpty, typedWords.allSatisfy({ word in words(text).contains { $0.hasPrefix(word) } }) {
                // (The first word first: "autor" lists Autor's papers before Acemoglu, Autor, ….)
                let first = words(fold(entry.title)).first { $0.contains(where: \.isLetter) }
                rank = first?.hasPrefix(typedWords[0]) == true ? 2 : 3
            } else if typed.count >= 3, text.contains(typed) {
                rank = 4
            } else { continue }
            ranked.append((rank, order))
        }
        return ranked.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.order < $1.order }.map(\.order)
    }

    // MARK: Keys

    func controlTextDidChange(_ notification: Notification) {
        if choosingType {
            choosingType = false
            let text = field.stringValue
            if text.count == 1, let key = text.lowercased().first, let index = kinds.firstIndex(where: { $0.key == key }) {
                field.stringValue = ""
                popUp.selectItem(at: index)
            }
        }
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            let step = selector == #selector(NSResponder.moveUp(_:)) ? -1 : 1
            var row = table.selectedRow + step
            while row >= 0, row < rows.count, match(at: row) == nil { row += step }     // over the headings
            guard row >= 0, row < rows.count else { return true }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            // (Moving up to the first match: show its heading too.)
            table.scrollRowToVisible(step < 0 && row > 0 && match(at: row - 1) == nil ? row - 1 : row)
            follow()
            return true
        case #selector(NSResponder.deleteBackward(_:)) where field.stringValue.isEmpty:
            choosingType = true
            return true
        case #selector(NSResponder.insertTab(_:)) where kind.key == "p" && hasPrintedPages:
            numbering.selectItem(at: 1 - numbering.indexOfSelectedItem)     // Tab: as printed ↔ in PDF
            numberingChosen(numbering)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            choose(inSplit: false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    @objc private func numberingChosen(_ sender: NSPopUpButton) {
        onNumberingChange?(pagesAsPrinted)
        refresh()
        panel.makeFirstResponder(field)
    }

    @objc private func typeChosen(_ sender: NSPopUpButton) {
        choosingType = false
        refresh()
        panel.makeFirstResponder(field)
    }

    /// The selected match shown in the document (not while typing: the list changes with every key).
    private func follow() {
        guard let entry = match(at: table.selectedRow) else { return }
        onFollow?(entry.target)
    }

    @objc private func clicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        follow()
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        choose(inSplit: false)
    }

    @objc private func go(_ sender: Any?) { choose(inSplit: false) }
    @objc private func cancelAction(_ sender: Any?) { cancel() }

    private func cancel() {
        close()
        onCancel?()
    }

    private func choose(inSplit: Bool) {
        guard let entry = match(at: table.selectedRow) else { NSSound.beep(); return }
        let target = entry.target, onChoose = onChoose
        close()
        onChoose(target, inSplit)
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        UserDefaults.standard.set(NSStringFromSize(isCompact == false ? panel.frame.size : fullSize), forKey: Self.sizeKey)
        let parent = panel.parent
        if let window = parent?.frame, window.width > 0, window.height > 0 {
            let place = NSPoint(x: (panel.frame.midX - window.minX) / window.width,
                                y: (window.maxY - panel.frame.maxY) / window.height)
            UserDefaults.standard.set(NSStringFromPoint(place), forKey: Self.placeKey)
        }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKey()
        onClose?()
    }

    // MARK: List

    private enum Row { case heading(String), match(Int) }
    private var rows: [Row] = []

    private func match(at row: Int) -> Entry? {
        guard row >= 0, row < rows.count, case .match(let index) = rows[row] else { return nil }
        return matches[index]
    }

    /// Whether the list is split into sections (then the rows don't repeat theirs).
    private var grouped: Bool { rows.contains { if case .heading = $0 { return true } else { return false } } }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { match(at: row) == nil }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { match(at: row) != nil }

    private static let cellID = NSUserInterfaceItemIdentifier("match")
    private static let headingID = NSUserInterfaceItemIdentifier("heading")
    private static let annotationID = NSUserInterfaceItemIdentifier("annotation")
    /// The selected row, shown in full.
    private var expandedRow = -1

    private func page(_ entry: Entry) -> String? {
        if case .page = entry.target, kind.key == "p" { return nil }     // "Page 38" says it already
        return "p. \(entry.pageIndex + 1)"
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        guard let entry = match(at: row) else {
            guard case .heading(let title) = rows[row] else { return nil }
            let cell = tableView.makeView(withIdentifier: Self.headingID, owner: self) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = Self.headingID
                let label = NSTextField(labelWithString: "")
                label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
                label.textColor = .secondaryLabelColor
                label.lineBreakMode = .byTruncatingTail
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()
            cell.textField?.stringValue = title
            return cell
        }
        if let color = entry.color {
            let cell = tableView.makeView(withIdentifier: Self.annotationID, owner: self) as? AnnotationCell ?? AnnotationCell()
            cell.identifier = Self.annotationID
            cell.show(entry.title, comment: entry.comment, color: color, page: page(entry), expanded: row == expandedRow)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? MatchCell ?? MatchCell()
        cell.identifier = Self.cellID
        cell.show(entry.title, page: page(entry), section: grouped ? nil : entry.section, expanded: row == expandedRow)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let entry = match(at: row), let column = tableView.tableColumns.first else { return 22 }
        if entry.color != nil {
            return AnnotationCell.height(entry.title, comment: entry.comment, expanded: row == expandedRow, width: column.width)
        }
        return MatchCell.height(entry.title, section: grouped ? nil : entry.section, expanded: row == expandedRow,
                                width: column.width)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let previous = expandedRow
        expandedRow = table.selectedRow
        let changed = IndexSet([previous, expandedRow].filter { $0 >= 0 && $0 < rows.count })
        guard !changed.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            table.noteHeightOfRows(withIndexesChanged: changed)
        }
        table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
        if expandedRow >= 0 { table.scrollRowToVisible(expandedRow) }

    }
}

/// A match: its title on one line and its page on the right; when selected, the whole title and
/// (in a list not split into sections) its top-level section, small and grey, underneath.
private final class MatchCell: NSTableCellView {
    private static let titleFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private static let sectionFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    private static let inset: CGFloat = 6, pageWidth: CGFloat = 44, padding: CGFloat = 8
    private let title = NSTextField(wrappingLabelWithString: "")
    private let page = NSTextField(labelWithString: "")
    private let section = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = Self.titleFont
        title.cell?.truncatesLastVisibleLine = true
        page.font = Self.titleFont
        page.textColor = .secondaryLabelColor
        page.alignment = .right
        section.font = Self.sectionFont
        section.textColor = .secondaryLabelColor
        section.lineBreakMode = .byTruncatingTail
        for label in [title, page, section] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
        }
        textField = title
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            title.trailingAnchor.constraint(equalTo: page.leadingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding / 2),
            page.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            page.widthAnchor.constraint(equalToConstant: Self.pageWidth),
            page.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            section.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            section.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            section.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    convenience init() { self.init(frame: .zero) }

    func show(_ text: String, page pageText: String?, section sectionText: String?, expanded: Bool) {
        title.stringValue = text
        title.maximumNumberOfLines = expanded ? 0 : 1
        // (Cut in the middle: captions often differ only at the end, "… donors" / "… (aggregates)".)
        title.lineBreakMode = expanded ? .byWordWrapping : .byTruncatingMiddle
        page.stringValue = pageText ?? ""
        section.stringValue = sectionText ?? ""
        section.isHidden = !expanded || sectionText == nil
    }

    private static let probe: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = titleFont
        return label
    }()

    private static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }

    static func height(_ text: String, section: String?, expanded: Bool, width: CGFloat) -> CGFloat {
        var height = lineHeight(titleFont)
        if expanded {
            probe.stringValue = text
            probe.preferredMaxLayoutWidth = max(width - 2 * inset - pageWidth - 8 - 4, 50)
            height = max(height, ceil(probe.fittingSize.height))
            if section != nil { height += 1 + lineHeight(sectionFont) }
        }
        return height + padding
    }
}

/// An annotation: a bar in the highlight's colour beside the highlighted text (one line, like any
/// other entry), a speech bubble by the page number if there is a comment; when selected, the whole
/// text and below it the comment, in italics and without the bar.
private final class AnnotationCell: NSTableCellView {
    private static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private static let commentFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    private static let inset: CGFloat = 6, barGap: CGFloat = 9, pageWidth: CGFloat = 44, bubbleWidth: CGFloat = 16
    private static let padding: CGFloat = 8, commentGap: CGFloat = 6
    private let bar = NSView()
    private let quote = NSTextField(wrappingLabelWithString: "")
    private let bubble = NSImageView(image: NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Comment") ?? NSImage())
    private let page = NSTextField(labelWithString: "")
    private let comment = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1
        quote.font = Self.font
        quote.cell?.truncatesLastVisibleLine = true
        bubble.contentTintColor = .labelColor
        bubble.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .regular)
        page.font = Self.font
        page.textColor = .secondaryLabelColor
        page.alignment = .right
        comment.font = Self.commentFont
        for view in [bar, quote, bubble, page, comment] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for label in [quote, page, comment] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        textField = quote
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            bar.widthAnchor.constraint(equalToConstant: 3),
            bar.topAnchor.constraint(equalTo: quote.topAnchor, constant: 1),
            bar.bottomAnchor.constraint(equalTo: quote.bottomAnchor, constant: -1),
            quote.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Self.barGap),
            quote.trailingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: -4),
            quote.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding / 2),
            bubble.widthAnchor.constraint(equalToConstant: Self.bubbleWidth),
            bubble.trailingAnchor.constraint(equalTo: page.leadingAnchor, constant: -4),
            bubble.centerYAnchor.constraint(equalTo: page.centerYAnchor),
            page.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            page.widthAnchor.constraint(equalToConstant: Self.pageWidth),
            page.firstBaselineAnchor.constraint(equalTo: quote.firstBaselineAnchor),
            comment.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            comment.trailingAnchor.constraint(equalTo: quote.trailingAnchor),
            comment.topAnchor.constraint(equalTo: quote.bottomAnchor, constant: Self.commentGap),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    convenience init() { self.init(frame: .zero) }

    func show(_ text: String, comment commentText: String?, color: NSColor, page pageText: String?, expanded: Bool) {
        bar.layer?.backgroundColor = color.cgColor
        quote.stringValue = text.isEmpty ? "Highlight" : text
        quote.maximumNumberOfLines = expanded ? 0 : 1
        quote.lineBreakMode = expanded ? .byWordWrapping : .byTruncatingTail
        bubble.isHidden = commentText == nil
        page.stringValue = pageText ?? ""
        comment.stringValue = commentText ?? ""
        comment.isHidden = !expanded || commentText == nil
    }

    private static let probe = NSTextField(wrappingLabelWithString: "")

    private static func lineHeight() -> CGFloat { ceil(font.ascender - font.descender + font.leading) }

    static func height(_ text: String, comment: String?, expanded: Bool, width: CGFloat) -> CGFloat {
        var height = lineHeight()
        if expanded {
            let quoteWidth = width - 2 * inset - barGap - 4 - bubbleWidth - 4 - pageWidth
            probe.font = font
            probe.preferredMaxLayoutWidth = max(quoteWidth - 4, 50)
            probe.stringValue = text
            height = max(height, ceil(probe.fittingSize.height))
            if let comment {
                probe.preferredMaxLayoutWidth = max(quoteWidth + barGap - 4, 50)
                probe.font = commentFont
                probe.stringValue = comment
                height += commentGap + ceil(probe.fittingSize.height)
            }
        }
        return height + padding
    }
}

/// The palette's panel: ⌘Return shows the target in the split view (Return is the Go button's);
/// a double-click on its background puts it back in place.
/// Any other menu shortcut (⌘W, ⌘F, ⌘+ …) closes the palette and then goes to the document
/// window, except the field's own Cut, Copy, Paste and Select All.
final class JumpPanel: NSPanel {
    var onCommandReturn: (() -> Void)?
    var onMenuShortcut: (() -> Void)?
    var onBackgroundDoubleClick: (() -> Void)?

    /// Resizing and moving back into place: quicker than the system's window animation.
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        min(super.animationResizeTime(newFrame) * 0.5, 0.12)
    }

    override func sendEvent(_ event: NSEvent) {
        // (Before the title bar, which would zoom the panel.)
        if event.type == .leftMouseDown, event.clickCount == 2, let content = contentView,
           let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow),
           hit === content || hit is NSStackView {
            onBackgroundDoubleClick?()
            return
        }
        super.sendEvent(event)
    }

    private static let fieldActions: Set<Selector> = [#selector(NSText.cut(_:)), #selector(NSText.copy(_:)),
                                                      #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:))]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            onCommandReturn?()
            return true
        }
        if super.performKeyEquivalent(with: event) { return true }
        guard let item = NSApp.mainMenu.flatMap({ Self.item(in: $0, for: event) }),
              let action = item.action, !Self.fieldActions.contains(action) else { return false }
        onMenuShortcut?()
        DispatchQueue.main.async { NSApp.sendEvent(event) }   // now with the document window key
        return true
    }

    /// The menu item whose shortcut `event` is.
    private static func item(in menu: NSMenu, for event: NSEvent) -> NSMenuItem? {
        let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let flags = event.modifierFlags.intersection(relevant)
        guard flags.contains(.command), let key = event.characters(byApplyingModifiers: [])?.lowercased() else { return nil }
        for item in menu.items {
            if let submenu = item.submenu, let found = self.item(in: submenu, for: event) { return found }
            guard !item.keyEquivalent.isEmpty else { continue }
            var mods = item.keyEquivalentModifierMask.intersection(relevant)
            if item.keyEquivalent != item.keyEquivalent.lowercased() { mods.insert(.shift) }
            if item.keyEquivalent.lowercased() == key, mods == flags { return item }
        }
        return nil
    }
}
