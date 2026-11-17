import AppKit
import PDFKit

/// The reader's own highlights and underlines, saved into the PDF in the standard form Zotero
/// imports (/Highlight or /Underline with one quadrilateral per line, the colour in /C, a comment
/// in /Contents).
///
/// Pages the reader turned are saved the same way (their /Rotate).
///
/// The open document carries Galley's detected links and repaired link targets, which must
/// never reach the file. So saving starts from a clean copy of the file on disk and applies only
/// the highlights added or removed since the last save.
@MainActor
final class Annotations {
    /// Zotero's yellow (#ffd400), so highlights look the same there.
    nonisolated static let yellow = NSColor(srgbRed: 1, green: 212 / 255, blue: 0, alpha: 1)

    /// Zotero's eight colours, in its order (keys 1–8).
    nonisolated static let colors: [(name: String, color: NSColor)] = [
        ("Yellow", yellow), ("Red", rgb(0xff6666)), ("Green", rgb(0x5fb236)), ("Blue", rgb(0x2ea8e5)),
        ("Purple", rgb(0xa28ae5)), ("Magenta", rgb(0xe56eee)), ("Orange", rgb(0xf19837)), ("Grey", rgb(0xaaaaaa)),
    ]

    nonisolated private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    /// The one of the eight colours closest to `color` (an annotation made elsewhere may use others).
    static func nearestColor(to color: NSColor) -> Int {
        func rgb(_ c: NSColor) -> (CGFloat, CGFloat, CGFloat) {
            let c = c.usingColorSpace(.sRGB) ?? c
            return (c.redComponent, c.greenComponent, c.blueComponent)
        }
        let (r, g, b) = rgb(color)
        return colors.indices.min { i, j in
            let (r1, g1, b1) = rgb(colors[i].color), (r2, g2, b2) = rgb(colors[j].color)
            return pow(r1 - r, 2) + pow(g1 - g, 2) + pow(b1 - b, 2) < pow(r2 - r, 2) + pow(g2 - g, 2) + pow(b2 - b, 2)
        } ?? 0
    }

    private static let styleKey = "GalleyAnnotationStyle"

    /// The style A uses on plain text: the one last chosen with M or U.
    static var currentStyle: Style {
        get { UserDefaults.standard.string(forKey: styleKey) == "underline" ? .underline : .highlight }
        set { UserDefaults.standard.set(newValue == .underline ? "underline" : "highlight", forKey: styleKey) }
    }

    enum Style {
        case highlight, underline

        /// The PDF subtype, as `PDFAnnotation.type` gives it.
        var type: String { self == .highlight ? "Highlight" : "Underline" }
    }

    static func isMarkup(_ annotation: PDFAnnotation) -> Bool {
        ["Highlight", "Underline", "StrikeOut", "Squiggly"].contains(annotation.type ?? "")
    }

    fileprivate struct Removal {
        let page: Int
        let type: String
        let bounds: NSRect

        func matches(_ annotation: PDFAnnotation, on page: Int) -> Bool {
            page == self.page && annotation.type == type && Annotations.sameRect(annotation.bounds, bounds)
        }
    }

    /// A new comment or colour on an annotation already in the file (only /Contents and /C change).
    fileprivate struct Edit {
        let key: Removal
        let comment: String?
        let color: NSColor
    }

    private(set) var added: [PDFAnnotation] = []
    private var removed: [Removal] = []
    private var edits: [Edit] = []
    /// Pages turned with View → Rotate Left / Right: page index → its rotation now.
    private var rotations: [Int: Int] = [:]
    var hasChanges: Bool { !added.isEmpty || !removed.isEmpty || !edits.isEmpty || !rotations.isEmpty }

    /// Annotations added to and removed from pages in one step (undone by swapping the two).
    struct Change {
        var added: [(annotation: PDFAnnotation, page: PDFPage)] = []
        var removed: [(annotation: PDFAnnotation, page: PDFPage)] = []
        var inverse: Change { Change(added: removed, removed: added) }
        var isEmpty: Bool { added.isEmpty && removed.isEmpty }
    }

    /// Highlights (or underlines) the selection. Where it touches annotations of that style, it
    /// removes them instead; annotations of the other style become this one (comment and colour
    /// kept). Returns nil when there is nothing to mark.
    func toggle(_ selection: PDFSelection, as style: Style = .highlight, color: NSColor = yellow,
                in doc: PDFDocument) -> Change? {
        let lines = Self.lines(of: selection)
        guard !lines.isEmpty else { return nil }
        let touched: [(annotation: PDFAnnotation, page: PDFPage)] = Self.markup(touching: lines).compactMap { annotation in
            annotation.page.map { (annotation, $0) }
        }
        let other = touched.filter { $0.annotation.type != style.type }
        var change = Change()
        if !other.isEmpty {
            change.removed = other
            change.added = other.map { annotation, page in
                let copy = Self.markup(Self.lineRects(of: annotation), type: style.type, color: annotation.color)
                copy.contents = annotation.contents
                return (copy, page)
            }
        } else if !touched.isEmpty {
            change.removed = touched
        } else {
            change.added = lines.map { page, rects in (Self.markup(rects, type: style.type, color: color), page) }
        }
        apply(change, in: doc)
        return change
    }

    /// Removes every annotation the selection touches (nil if it touches none).
    func remove(touching selection: PDFSelection, in doc: PDFDocument) -> Change? {
        let touched: [(annotation: PDFAnnotation, page: PDFPage)] = Self.markup(touching: selection).compactMap { annotation in
            annotation.page.map { (annotation, $0) }
        }
        guard !touched.isEmpty else { return nil }
        let change = Change(removed: touched)
        apply(change, in: doc)
        return change
    }

    /// What Remove All Annotations takes away: highlights, comments, notes, drawings – from any
    /// app – but not links, form fields or Galley's markers. Popups (the windows notes open in) go
    /// too: PDFKit doesn't reliably say whose they are, and without their note they show nothing.
    nonisolated static func isRemovable(_ annotation: PDFAnnotation) -> Bool {
        !(annotation is CommentMarker) && !["Link", "Widget"].contains(annotation.type ?? "")
    }

    /// How many there are, not counting popups.
    static func removableCount(in doc: PDFDocument) -> Int {
        (0..<doc.pageCount).reduce(0) { total, index in
            total + (doc.page(at: index)?.annotations.filter { isRemovable($0) && $0.type != "Popup" }.count ?? 0)
        }
    }

    /// Removes every such annotation in the document (nil if there are none).
    func removeAll(in doc: PDFDocument) -> Change? {
        var change = Change()
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            change.removed += page.annotations.filter(Self.isRemovable).map { ($0, page) }
        }
        guard !change.isEmpty else { return nil }
        apply(change, in: doc)
        return change
    }

    /// The highlights a selection touches, in reading order.
    static func markup(touching selection: PDFSelection) -> [PDFAnnotation] {
        markup(touching: lines(of: selection))
    }

    private static func lines(of selection: PDFSelection) -> [PDFPage: [NSRect]] {
        var lines: [PDFPage: [NSRect]] = [:]
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let rect = line.bounds(for: page)
                if rect.width > 0.5, rect.height > 0.5 { lines[page, default: []].append(rect) }
            }
        }
        return lines
    }

    private static func markup(touching lines: [PDFPage: [NSRect]]) -> [PDFAnnotation] {
        lines.sorted { ($0.key.document?.index(for: $0.key) ?? 0) < ($1.key.document?.index(for: $1.key) ?? 0) }
            .flatMap { page, rects in
                page.annotations.filter { annotation in
                    isMarkup(annotation) && lineRects(of: annotation).contains { quad in
                        rects.contains { quad.intersection($0).width > 1 }
                    }
                }.sorted { $0.bounds.maxY > $1.bounds.maxY }
            }
    }

    /// Sets a highlight's comment (nil or empty: none). Zotero reads it from /Contents.
    func setComment(_ comment: String?, of annotation: PDFAnnotation, in doc: PDFDocument) {
        annotation.contents = comment?.isEmpty == true ? nil : comment
        recordEdit(of: annotation, in: doc)
    }

    func setColor(_ color: NSColor, of annotation: PDFAnnotation, in doc: PDFDocument) {
        annotation.color = color
        recordEdit(of: annotation, in: doc)
    }

    private func recordEdit(of annotation: PDFAnnotation, in doc: PDFDocument) {
        // One not yet saved is written as it is anyway.
        guard !added.contains(where: { $0 === annotation }), let page = annotation.page else { return }
        let key = Removal(page: doc.index(for: page), type: annotation.type ?? "", bounds: annotation.bounds)
        edits.removeAll { $0.key.page == key.page && $0.key.type == key.type && Self.sameRect($0.key.bounds, key.bounds) }
        edits.append(Edit(key: key, comment: annotation.contents, color: annotation.color))
    }

    /// Turns a page by a quarter turn (negative: to the left), saved into the file like highlights.
    func rotate(_ page: PDFPage, by degrees: Int, in doc: PDFDocument) {
        page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        rotations[doc.index(for: page)] = page.rotation
    }

    func apply(_ change: Change, in doc: PDFDocument) {
        for (annotation, page) in change.removed { remove(annotation, from: page, in: doc) }
        for (annotation, page) in change.added { add(annotation, to: page, in: doc) }
    }

    private func add(_ annotation: PDFAnnotation, to page: PDFPage, in doc: PDFDocument) {
        // Putting back one that came from the file cancels its removal.
        if let index = removed.firstIndex(where: { $0.matches(annotation, on: doc.index(for: page)) }) {
            removed.remove(at: index)
        } else {
            added.append(annotation)
        }
        page.addAnnotation(annotation)
        if let popup = annotation.popup { page.addAnnotation(popup) }
    }

    private func remove(_ annotation: PDFAnnotation, from page: PDFPage, in doc: PDFDocument) {
        if let index = added.firstIndex(where: { $0 === annotation }) {
            added.remove(at: index)
        } else {
            removed.append(Removal(page: doc.index(for: page), type: annotation.type ?? "", bounds: annotation.bounds))
        }
        if let popup = annotation.popup { page.removeAnnotation(popup) }
        page.removeAnnotation(annotation)
    }

    /// Forgets the pending changes (the file is about to be replaced).
    func discard() {
        added.removeAll()
        removed.removeAll()
        edits.removeAll()
        rotations.removeAll()
    }

    /// The text of a markup annotation under a point of its page, as a selection (nil if none).
    static func selection(at point: NSPoint, on page: PDFPage) -> PDFSelection? {
        page.annotations.last(where: { isMarkup($0) && lineRects(of: $0).contains { $0.contains(point) } })
            .flatMap(selection(of:))
    }

    /// A page's highlights from top to bottom (left to right on a line).
    static func inReadingOrder(on page: PDFPage) -> [PDFAnnotation] {
        page.annotations.filter(isMarkup).sorted {
            abs($0.bounds.maxY - $1.bounds.maxY) > 2 ? $0.bounds.maxY > $1.bounds.maxY : $0.bounds.minX < $1.bounds.minX
        }
    }

    /// Puts a marker after every highlight with a comment (and removes the others). The markers
    /// are on screen only: saving starts from the file, so they never reach it.
    static func updateCommentMarkers(in doc: PDFDocument) {
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            let commented = page.annotations.filter { isMarkup($0) && !($0.contents ?? "").isEmpty }
            let markers = page.annotations.compactMap { $0 as? CommentMarker }
            // Unchanged: leave the page alone (no redraw).
            if markers.count == commented.count,
               zip(markers, commented).allSatisfy({ $0.highlight === $1 && sameRect($0.bounds, CommentMarker.bounds(after: $1)) }) { continue }
            for marker in markers { page.removeAnnotation(marker) }
            for highlight in commented { page.addAnnotation(CommentMarker(after: highlight)) }
        }
    }

    /// The text a markup annotation covers, as a selection (nil if it covers none).
    static func selection(of annotation: PDFAnnotation) -> PDFSelection? {
        guard let page = annotation.page, let doc = page.document else { return nil }
        let selection = PDFSelection(document: doc)
        for line in lines(of: annotation) { selection.add(line) }
        return selection.string?.isEmpty == false ? selection : nil
    }

    /// The covered text as one line of reading text: words split at a line end ("percent-/age")
    /// joined again.
    static func text(of annotation: PDFAnnotation) -> String {
        var text = ""
        for line in lines(of: annotation) {
            let part = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if text.hasSuffix("-"), part.first?.isLowercase == true {
                text.removeLast()
                text += part
            } else {
                text += (text.isEmpty ? "" : " ") + part
            }
        }
        return text
    }

    private static func lines(of annotation: PDFAnnotation) -> [PDFSelection] {
        guard let page = annotation.page else { return [] }
        // Inset, so that the lines above and below and the letters just before and after (whose
        // boxes touch the line's ends) aren't picked up.
        return lineRects(of: annotation).compactMap {
            page.selection(for: $0.insetBy(dx: min(1.5, $0.width / 4), dy: $0.height / 4))
        }
    }

    /// One highlight or underline annotation covering the given lines of a page.
    nonisolated private static func markup(_ rects: [NSRect], type: String, color: NSColor,
                                           date: Date = Date()) -> PDFAnnotation {
        let bounds = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        let annotation = PDFAnnotation(bounds: bounds, forType: type == "Underline" ? .underline : .highlight,
                                       withProperties: nil)
        annotation.color = color
        annotation.modificationDate = date
        // Upper left, upper right, lower left, lower right of each line, relative to the bounds.
        annotation.quadrilateralPoints = rects.flatMap { rect -> [NSValue] in
            let r = rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            return [NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY),
                    NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY)].map { NSValue(point: $0) }
        }
        return annotation
    }

    /// The line rectangles of a markup annotation in page space (its bounds if it has no quads).
    nonisolated fileprivate static func lineRects(of annotation: PDFAnnotation) -> [NSRect] {
        let points = (annotation.quadrilateralPoints ?? []).map { $0.pointValue }
        guard points.count >= 4 else { return [annotation.bounds] }
        let origin = annotation.bounds.origin
        return stride(from: 0, through: points.count - 4, by: 4).map { i in
            let xs = points[i..<i + 4].map { $0.x + origin.x }, ys = points[i..<i + 4].map { $0.y + origin.y }
            return NSRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }

    // MARK: Saving

    enum SaveError: LocalizedError {
        case unreadable, mismatch, writeFailed, checkFailed

        var errorDescription: String? {
            switch self {
            case .unreadable: "The file on disk couldn’t be read."
            case .mismatch: "The file on disk has changed (its page count differs)."
            case .writeFailed: "PDFKit couldn’t write the file."
            case .checkFailed: "The written file didn’t read back correctly, so the original was kept."
            }
        }
    }

    /// A highlight to write, read off its annotation on the main thread. Any other kind (a note
    /// put back by undoing Remove All) is written as a copy of itself.
    struct NewHighlight: @unchecked Sendable {
        let page: Int
        let type: String
        let rects: [NSRect]
        let color: NSColor
        let contents: String?
        let date: Date
        var copy: PDFAnnotation? = nil
    }

    /// The changes handed to one save. They leave the pending lists when the save starts, so
    /// anything done meanwhile goes into the next save; a failed save puts them back.
    struct Batch: @unchecked Sendable {
        fileprivate let annotations: [PDFAnnotation]
        fileprivate let removals: [Removal]
        fileprivate let edits: [Edit]
        fileprivate let rotations: [Int: Int]
        let highlights: [NewHighlight]
        let pageCount: Int
    }

    /// Takes the pending changes for a save (nil if there are none).
    func takeBatch(in doc: PDFDocument) -> Batch? {
        guard hasChanges else { return nil }
        let highlights = added.compactMap { annotation -> NewHighlight? in
            guard let page = annotation.page else { return nil }
            if annotation.type != Style.highlight.type && annotation.type != Style.underline.type {
                return NewHighlight(page: doc.index(for: page), type: annotation.type ?? "", rects: [], color: annotation.color,
                                    contents: annotation.contents, date: Date(), copy: annotation.copy() as? PDFAnnotation)
            }
            return NewHighlight(page: doc.index(for: page), type: annotation.type ?? "Highlight",
                                rects: Self.lineRects(of: annotation), color: annotation.color,
                                contents: annotation.contents, date: annotation.modificationDate ?? Date())
        }
        let batch = Batch(annotations: added, removals: removed, edits: edits, rotations: rotations,
                          highlights: highlights, pageCount: doc.pageCount)
        added.removeAll()
        removed.removeAll()
        edits.removeAll()
        rotations.removeAll()
        return batch
    }

    func saveFailed(_ batch: Batch) {
        added = batch.annotations.filter { $0.page != nil } + added
        removed = batch.removals + removed
        edits = batch.edits + edits
        rotations.merge(batch.rotations) { newer, _ in newer }
    }

    /// Saves run one after another, off the main thread.
    nonisolated static let saveQueue = DispatchQueue(label: "io.github.turbanisch.galley.save")

    /// Writes a batch into the file: a clean copy plus the changes goes to a temporary file, is
    /// read back and checked, and only then replaces the original. Before the first save the
    /// original is kept in ~/Library/Application Support/Galley/Originals.
    nonisolated static func write(_ batch: Batch, to url: URL) throws {
        guard let data = try? Data(contentsOf: url), let clean = PDFDocument(data: data) else { throw SaveError.unreadable }
        guard clean.pageCount == batch.pageCount else { throw SaveError.mismatch }

        for (index, rotation) in batch.rotations { clean.page(at: index)?.rotation = rotation }
        for edit in batch.edits {
            guard let page = clean.page(at: edit.key.page),
                  let match = page.annotations.first(where: { edit.key.matches($0, on: edit.key.page) }) else { continue }
            match.contents = edit.comment
            match.color = edit.color
        }
        for removal in batch.removals {
            guard let page = clean.page(at: removal.page),
                  let match = page.annotations.first(where: { removal.matches($0, on: removal.page) }) else { continue }
            if let popup = match.popup { page.removeAnnotation(popup) }
            page.removeAnnotation(match)
        }
        for new in batch.highlights {
            if let copy = new.copy {
                clean.page(at: new.page)?.addAnnotation(copy)
                continue
            }
            guard let page = clean.page(at: new.page), !new.rects.isEmpty else { continue }
            let annotation = markup(new.rects, type: new.type, color: new.color, date: new.date)
            annotation.contents = new.contents
            page.addAnnotation(annotation)
        }

        // Everything taken back (a highlight added, later removed): rather than rewrite the file
        // once more, put back the original Galley kept, untouched and at its own size.
        if let original = try? originalURL(of: url), let originalDoc = PDFDocument(url: original),
           contentSignature(originalDoc) == contentSignature(clean) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: original)
            return
        }

        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                 appropriateFor: url, create: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let temporary = folder.appendingPathComponent(url.lastPathComponent)
        guard clean.write(to: temporary) else { throw SaveError.writeFailed }
        guard let check = PDFDocument(url: temporary), check.pageCount == clean.pageCount,
              textLength(check) >= textLength(clean) * 99 / 100 else { throw SaveError.checkFailed }

        try keepOriginal(of: url)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    nonisolated fileprivate static func sameRect(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    /// File → Export Without Annotations: the file on disk with every annotation Remove All would
    /// take away removed, written to `destination` (checked like a save; the original is untouched).
    nonisolated static func writeClean(from url: URL, to destination: URL) throws {
        guard let data = try? Data(contentsOf: url), let clean = PDFDocument(data: data) else { throw SaveError.unreadable }
        for index in 0..<clean.pageCount {
            guard let page = clean.page(at: index) else { continue }
            for annotation in page.annotations where isRemovable(annotation) { page.removeAnnotation(annotation) }
        }
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                 appropriateFor: destination, create: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let temporary = folder.appendingPathComponent(destination.lastPathComponent)
        guard clean.write(to: temporary) else { throw SaveError.writeFailed }
        guard let check = PDFDocument(url: temporary), check.pageCount == clean.pageCount else { throw SaveError.checkFailed }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    /// What a reader could have changed: every page's rotation and every annotation's type, place,
    /// text, colour and form value, page by page (not only highlights – notes or form entries made
    /// elsewhere count too).
    nonisolated private static func contentSignature(_ doc: PDFDocument) -> [[String]] {
        (0..<doc.pageCount).map { index in
            ["rotation \(doc.page(at: index)?.rotation ?? 0)"] + (doc.page(at: index)?.annotations ?? []).map { annotation in
                let b = annotation.bounds
                let c = annotation.color.usingColorSpace(.sRGB) ?? annotation.color
                return [annotation.type ?? "", String(format: "%.1f %.1f %.1f %.1f", b.minX, b.minY, b.width, b.height),
                        annotation.contents ?? "", annotation.widgetStringValue ?? "",
                        String(format: "%.2f %.2f %.2f", c.redComponent, c.greenComponent, c.blueComponent)].joined(separator: "|")
            }.sorted()
        }
    }

    nonisolated private static func textLength(_ doc: PDFDocument) -> Int {
        (0..<doc.pageCount).reduce(0) { $0 + (doc.page(at: $1)?.string?.count ?? 0) }
    }

    /// A copy of the file as it was before Galley first wrote to it (named after its folder too:
    /// Zotero keeps each attachment in a folder of its own, and file names can repeat).
    nonisolated static func originalURL(of url: URL) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("Galley/Originals", isDirectory: true)
        let name = url.deletingLastPathComponent().lastPathComponent + " – " + url.lastPathComponent
        return folder.appendingPathComponent(name)
    }

    nonisolated private static func keepOriginal(of url: URL) throws {
        let backup = try originalURL(of: url)
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: url, to: backup)
        }
    }
}

/// The box for a highlight's comment, shown in a popover below it. Return finishes (⇧Return or
/// ⌥Return starts a new line), as do Esc and a click elsewhere; `onClose` gets the text.
@MainActor
final class CommentEditor: NSViewController, NSTextViewDelegate, NSPopoverDelegate {
    private let initial: String
    private var textView: NSTextView!
    var onClose: ((String) -> Void)?
    weak var popover: NSPopover?

    init(comment: String?) {
        initial = comment ?? ""
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        // The system's text view in a scroll view, set up to wrap lines at its width.
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 84)
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        textView = scroll.documentView as? NSTextView
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.allowsUndo = true
        textView.string = initial
        textView.delegate = self
        textView.setValue(NSAttributedString(string: "Add comment…", attributes: [
            .foregroundColor: NSColor.placeholderTextColor, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]), forKey: "placeholderAttributedString")
        view = scroll
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
        textView.selectedRange = NSRange(location: (textView.string as NSString).length, length: 0)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        switch selector {
        case #selector(NSResponder.insertNewline(_:)) where shift:
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)):
            popover?.performClose(nil)
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        default:
            return false
        }
    }

    func popoverDidClose(_ notification: Notification) {
        onClose?(textView.string)
        onClose = nil
    }
}

/// A small speech bubble (white, black outline) after a highlight with a comment, raised like a
/// footnote mark.
/// Drawn by Galley only (never saved).
final class CommentMarker: PDFAnnotation {
    weak var highlight: PDFAnnotation?

    init(after highlight: PDFAnnotation) {
        self.highlight = highlight
        super.init(bounds: Self.bounds(after: highlight), forType: .square, withProperties: nil)
        shouldPrint = false
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Above the end of the highlight's last line, the lowest point of its tip (32.7 % of the
    /// icon's width in from its left edge, measured) on the highlight's right edge as PDFKit shows
    /// it – 0.8 pt beyond the line, which it pads on every side – its lower part over the line.
    static func bounds(after highlight: PDFAnnotation) -> NSRect {
        let last = Annotations.lineRects(of: highlight).min { $0.minY < $1.minY } ?? highlight.bounds
        let size = min(max(last.height * 0.75, 6), 11)
        return NSRect(x: last.maxX + 0.8 - size * 0.327, y: last.maxY - size * 0.45, width: size, height: size)
    }

    static func at(_ point: NSPoint, on page: PDFPage) -> CommentMarker? {
        page.annotations.lazy.compactMap { $0 as? CommentMarker }.first { $0.bounds.insetBy(dx: -2, dy: -2).contains(point) }
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        // A white bubble underneath, so the highlight doesn't show through, then the outline in
        // the text colour (black, sepia's brown). On dark pages the fill is the page colour.
        let theme = PageTheme.current
        let fillColor = theme.inverts ? NSColor(cgColor: theme.paperColor) ?? .black : .white
        let outlineColor = NSColor(cgColor: theme.inkColor) ?? .black
        guard let fill = NSImage(systemSymbolName: "bubble.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [fillColor])),
              let outline = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [outlineColor])) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        // The filled symbol is a touch larger than the outline (at the tip it reaches past it):
        // 1.5 % smaller, it stays inside, with no white peeking out.
        fill.draw(in: bounds.insetBy(dx: bounds.width * 0.015, dy: bounds.height * 0.015))
        outline.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
}
