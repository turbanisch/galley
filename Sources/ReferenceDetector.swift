import AppKit
import PDFKit

/// Many PDFs (journal articles, Word exports) have no internal links. This finds mentions of
/// figures and tables ("Table 3", "Fig. 2", "Tabellen 2 und 4") and numbered citations ([12],
/// [3–5]) in the text and adds invisible link annotations to their targets, in memory only.
/// Being ordinary links, they work with previews, the split view and link hints.
@MainActor
enum ReferenceDetector {
    private enum Kind: String { case table, figure }

    /// Words for tables and figures in several languages (lowercase, without a trailing dot).
    private static let words: [String: Kind] = {
        var map: [String: Kind] = [:]
        for word in ["table", "tables", "tab", "tabs", "tabelle", "tabellen", "tableau", "tableaux",
                     "tabla", "tablas", "tabella"] { map[word] = .table }
        for word in ["figure", "figures", "fig", "figs", "abbildung", "abbildungen", "abb", "grafik", "grafiken",
                     "schaubild", "schaubilder", "exhibit", "exhibits", "chart", "charts", "graph", "graphs",
                     "figura", "figuras", "graphique", "graphiques", "gráfico", "gráficos"] { map[word] = .figure }
        return map
    }()

    /// "3", "A20", "4.1", or a Roman numeral ("Table IV", common in economics journals).
    private static let label = #"(?:[A-Z]?\.?\d+(?:\.\d+)?|[IVXL]{1,5}(?![\p{L}\d]))"#

    private struct Spot {
        let page: PDFPage
        let range: NSRange
    }

    /// Where each document's reference list starts (page index as x, heading top as y).
    private final class ReferenceList {
        let startPage: Int, headingTop: CGFloat, endPage: Int
        init(startPage: Int, headingTop: CGFloat, endPage: Int) {
            self.startPage = startPage; self.headingTop = headingTop; self.endPage = endPage
        }
    }
    private static let referenceLists = NSMapTable<PDFDocument, ReferenceList>.weakToStrongObjects()

    /// Whether a spot is inside the reference list (e.g. its back-references "[1863]" to the
    /// pages citing an entry, which shouldn't get link hints).
    static func isInReferenceList(_ page: PDFPage, y: CGFloat) -> Bool {
        guard let document = page.document, let list = referenceLists.object(forKey: document) else { return false }
        let index = document.index(for: page)
        return (index > list.startPage && index <= list.endPage) || (index == list.startPage && y < list.headingTop)
    }

    /// Numbered reference list found: then author–year detection is skipped (its entries would
    /// be continuation lines like "Agricultural Economics. 2020", matching words in the text).
    private static var usesNumberedCitations = false

    /// Where links came from or what was done to them (for the test report).
    static let origins = NSMapTable<PDFAnnotation, NSString>.weakToStrongObjects()

    /// Some PDFs contain tiny link areas (a couple of points, e.g. leftovers at a sentence end)
    /// that nobody could aim at; they would only produce stray link hints. The PDF's own link on
    /// a one-digit footnote mark is only about 3.3 points wide, though. (Galley's own links keep
    /// the stricter limit: on tiny digits they are mostly subscripts in formulas.)
    static func isUsableLink(_ annotation: PDFAnnotation) -> Bool {
        let minWidth: CGFloat = (origins.object(forKey: annotation) as String?) == "galley" ? 4 : 3
        return annotation.bounds.width >= minWidth && annotation.bounds.height >= 4
    }

    /// What the last run found, for the debug log.
    static var report: [String] = []

    /// A target the jump palette (G) can go to, found along with the links.
    struct JumpTarget {
        enum Kind { case figure, table, equation, note, reference }
        let kind: Kind
        /// The number it goes by ("3", "IV", "12"); nil for author–year entries.
        let label: String?
        /// The caption, note or entry text from the target on (a line or two).
        let title: String
        /// More words to match (an entry's author names and year).
        let keywords: String
        let page: PDFPage
        /// Top left of the target's text.
        let point: NSPoint
    }
    private final class JumpTargets { var items: [JumpTarget] = [] }
    private static let jumpTargetLists = NSMapTable<PDFDocument, JumpTargets>.weakToStrongObjects()
    private static var collected: [JumpTarget] = []

    /// The document's jump targets, in page order.
    static func jumpTargets(in document: PDFDocument) -> [JumpTarget] {
        jumpTargetLists.object(forKey: document)?.items ?? []
    }

    private static func collect(_ kind: JumpTarget.Kind, _ label: String?, _ spot: Spot, keywords: String = "",
                                title: String? = nil) {
        guard let selection = spot.page.selection(for: spot.range) else { return }
        let bounds = selection.bounds(for: spot.page)
        collected.append(JumpTarget(kind: kind, label: label, title: title ?? lineText(spot), keywords: keywords,
                                    page: spot.page, point: topLeft(of: bounds, on: spot.page)))
    }

    /// The text from a spot to the end of its line, and on over the next lines (up to four in
    /// all) while it plainly goes on: the line is short ("Table 3" alone above its title), ends
    /// with a comma, hyphen or a word like "and", or the next line starts in lowercase. A
    /// reference entry goes on until it ends with a period (not after its year or an initial, and
    /// not into the next entry, "Smith,");
    /// a caption stops after its first sentence (not into the figure's notes).
    private enum Extent { case plain, caption, entry }
    private static let continuing: Set<String> = ["and", "or", "of", "the", "a", "an", "in", "on", "for", "to", "by",
        "with", "across", "before", "after", "between", "from", "at", "vs", "und", "der", "die", "das", "für", "von", "mit"]
    private static func lineText(_ spot: Spot, after: Bool = false, extent: Extent = .plain) -> String {
        guard let text = spot.page.string as NSString? else { return "" }
        let pieces = linePieces(spot, after: after, extent: extent)
        let result = join(pieces.map { NSAttributedString(string: text.substring(with: $0)) }).string
        var flat = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if extent == .caption { flat = firstSentence(flat, after: spot.range.length) }
        return flat.count > 300 ? String(flat.prefix(300)) + "…" : flat
    }

    /// The pieces of the page's text `lineText` takes (see there).
    private static func linePieces(_ spot: Spot, after: Bool, extent: Extent) -> [NSRange] {
        guard let text = spot.page.string as NSString?, spot.range.location < text.length else { return [] }
        let from = after ? NSMaxRange(spot.range) : spot.range.location
        var line = text.lineRange(for: NSRange(location: from, length: 0))
        var pieces = [NSRange(location: from, length: NSMaxRange(line) - from)]
        var result = text.substring(with: pieces[0])
        for _ in 0..<3 where NSMaxRange(line) < text.length {
            let next = text.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
            let current = result.trimmingCharacters(in: .whitespacesAndNewlines)
            let following = text.substring(with: next).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !following.isEmpty, current.count < 300 else { break }
            let lastWord = current.split(whereSeparator: { !$0.isLetter }).last.map { $0.lowercased() } ?? ""
            let newEntry = following.range(of: #"^\p{Lu}[\p{L}'’\-]+,"#, options: .regularExpression) != nil
            // (Short: for a caption only the bare label, "Table 3" above its title – "Table 1:
            // Summary Statistics" is complete, and the table's first row would follow.)
            let short = extent == .caption ? current.count <= spot.range.length + 2 : current.count < 30
            // (A caption ending in a period is complete, and a next line in lowercase may be a
            // table's first row, "ln p∗", or the other column's text.)
            let goesOn = short || (extent != .caption || current.last != ".")
                && (",-–—:;".contains(current.last ?? ".") || continuing.contains(lastWord)
                    || (extent != .caption && following.first?.isLowercase == true))
                || (extent == .entry && !newEntry && (current.last != "."
                    // (A period after the year or an initial doesn't end the entry: "… Price. 2016.")
                    || current.range(of: #"(?:\b(?:1[89]|20)\d\d[a-z]?\)?|\b\p{Lu})\.$"#, options: .regularExpression) != nil))
            guard goesOn else { break }
            result = current.hasSuffix("-") ? String(current.dropLast()) + following : current + " " + following
            line = next
            pieces.append(next)
        }
        return pieces
    }

    /// Pieces of text joined into one, with a space between them, or none after a hyphen at a
    /// line end ("Inter-" + "national" → "International", "1995-" + "2009" → "1995-2009").
    private static func join(_ parts: [NSAttributedString]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for part in parts {
            let trimmed = trim(part)
            guard trimmed.length > 0 else { continue }
            if result.string.hasSuffix("-") {
                // (A word broken at the line end loses its hyphen; "1995-" + "2009" keeps it.)
                let before = result.string.dropLast().last
                if before?.isLetter == true, trimmed.string.first?.isLowercase == true {
                    result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
                }
            } else if result.length > 0 {
                result.append(NSAttributedString(string: " "))
            }
            result.append(trimmed)
        }
        return result
    }

    private static func trim(_ text: NSAttributedString) -> NSAttributedString {
        let string = text.string as NSString
        var range = NSRange(location: 0, length: string.length)
        while range.length > 0, let c = Unicode.Scalar(string.character(at: range.location)),
              CharacterSet.whitespacesAndNewlines.contains(c) { range.location += 1; range.length -= 1 }
        while range.length > 0, let c = Unicode.Scalar(string.character(at: NSMaxRange(range) - 1)),
              CharacterSet.whitespacesAndNewlines.contains(c) { range.length -= 1 }
        return text.attributedSubstring(from: range)
    }

    /// Up to the end of the first sentence after the label (a caption's title, not its notes).
    /// Not at an abbreviation ("SOE vs. Domestic", "Smith et al. Data", "U.S. Imports").
    private static let abbreviations: Set<String> = ["vs", "e.g", "i.e", "cf", "al", "fig", "figs", "eq", "eqs", "no",
                                                     "approx", "incl", "resp", "ca", "dr", "st", "mr", "jr", "vol", "pp"]
    private static func firstSentence(_ text: String, after labelLength: Int) -> String {
        var from = text.index(text.startIndex, offsetBy: min(labelLength, text.count))
        while let end = text.range(of: #"[.!?] (?=\p{Lu})"#, options: .regularExpression, range: from..<text.endIndex) {
            let word = text[..<end.lowerBound].split(whereSeparator: { !$0.isLetter && $0 != "." }).last
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() } ?? ""
            if text[end.lowerBound] == ".", word.count == 1 || abbreviations.contains(word) {
                from = end.upperBound
                continue
            }
            return String(text[..<end.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    // MARK: Caption titles

    /// A figure's or table's title as it appears on the page: read by layout where possible
    /// (PDFKit's text order may jump between columns, or put a title before its label), else from
    /// the text; small marks at its end dropped ("LIVING STANDARDSᵃ", a slide's "Notes" button).
    private static func captionTitle(_ spot: Spot) -> String {
        func flat(_ text: NSAttributedString) -> String { text.string.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        var text = textCaption(spot)
        if let layout = layoutCaption(spot) {
            // (Unless the caption plainly goes on – "… Domestic Output and" – but no line follows
            // on the page, while the text does: then the text has the rest, wherever it is set.)
            let read = flat(layout), plain = flat(text)
            let lastWord = read.split(separator: " ").last.map { $0.lowercased() } ?? ""
            let goesOn = ",-–(".contains(read.last ?? ".") || continuing.contains(lastWord)
            if !(goesOn && plain.count > read.count && plain.hasPrefix(read)) { text = layout }
        }
        var flat = withoutTrailingMarks(text).string
            .replacingOccurrences(of: "\u{AD}", with: "")             // soft hyphens
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        flat = firstSentence(flat, after: spot.range.length)
        return flat.count > 300 ? String(flat.prefix(300)) + "…" : flat
    }

    private static func textCaption(_ spot: Spot) -> NSAttributedString {
        guard let attributed = spot.page.attributedString else { return NSAttributedString(string: lineText(spot, extent: .caption)) }
        return join(linePieces(spot, after: false, extent: .caption).map { attributed.attributedSubstring(from: $0) })
    }

    /// The font a piece of text mostly uses (by characters).
    private static func fontName(_ text: NSAttributedString) -> String {
        var counts: [String: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? NSFont { counts[font.fontName, default: 0] += range.length }
        }
        return counts.max { $0.value < $1.value }?.key ?? ""
    }

    /// The largest type in a piece of text (small capitals come out as two sizes).
    private static func typeSize(_ text: NSAttributedString) -> CGFloat {
        var size: CGFloat = 0
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let font = value as? NSFont,
                  !(text.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            size = max(size, font.pointSize)
        }
        return size
    }

    /// The caption read off the page: the label's line from the label rightwards (pieces close
    /// together, in the same size), then the lines below it in the same column while the caption
    /// plainly goes on: the label stood alone, or the line ends with a comma, hyphen, open
    /// parenthesis or a word like "and", or the next line starts in lowercase, or is centred under
    /// a centred line. Each next line is in about the same size and close below (wrapped caption
    /// lines are at most ~1.45 type sizes apart; a table's header or the notes start further
    /// down; a line that ends with a hyphen, comma, open parenthesis or "and" may be followed after
    /// a wider gap, as in a caption set with 1.5 line spacing). Nil on rotated pages (their text
    /// positions use another frame), for text set sideways (a landscape table on an upright page)
    /// and where PDFKit's positions are off the page.
    private static func layoutCaption(_ spot: Spot) -> NSAttributedString? {
        let page = spot.page
        guard page.rotation == 0, let labelSelection = page.selection(for: spot.range) else { return nil }
        let label = labelSelection.bounds(for: page)
        guard label.height > 0, label.width > label.height,
              page.bounds(for: .cropBox).insetBy(dx: -2, dy: -2).contains(label) else { return nil }
        struct Line { let text: NSAttributedString; let rect: NSRect; let size: CGFloat }
        let box = page.bounds(for: .cropBox)
        let reach = max(label.height, 8) * 8
        let region = NSRect(x: box.minX, y: label.minY - reach, width: box.width, height: reach + label.height + 2)
        let lines: [Line] = (page.selection(for: region)?.selectionsByLine() ?? []).compactMap { selection in
            guard let text = selection.attributedString,
                  !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let rect = selection.bounds(for: page)
            let size = typeSize(text)
            return rect.width > 0 && rect.height > 0 && size > 0 ? Line(text: text, rect: rect, size: size) : nil
        }
        let center = NSPoint(x: label.minX + min(label.width, label.height) / 2, y: label.midY)
        guard let start = lines.first(where: { $0.rect.insetBy(dx: -1, dy: -1).contains(center) }) else { return nil }

        // The label's line: pieces to its right, close together and in about the same size.
        var first = [start]
        var right = start.rect.maxX
        let rest = lines.filter { abs($0.rect.midY - start.rect.midY) < start.rect.height * 0.5 && $0.rect.minX >= start.rect.maxX - 1 }
        for piece in rest.sorted(by: { $0.rect.minX < $1.rect.minX }) {
            guard piece.rect.minX - right < max(start.size, 6) * 2.5, abs(piece.size - start.size) <= start.size * 0.35 else { break }
            first.append(piece)
            right = piece.rect.maxX
        }
        // (Not the text before the label, should PDFKit's line begin earlier.)
        var startText = start.text
        let word = (page.string as NSString?)?.substring(with: spot.range).trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first.map(String.init) ?? ""
        let found = (startText.string as NSString).range(of: word)
        if found.location != NSNotFound, found.location > 0 {
            startText = startText.attributedSubstring(from: NSRange(location: found.location, length: startText.length - found.location))
        }
        var title = join([startText] + first.dropFirst().map(\.text))
        var previous = first.dropFirst().reduce(start.rect) { $0.union($1.rect) }
        var previousFont = fontName(start.text)
        // The widest line on the page: a caption line that wide is wrapping.
        let textWidth = (page.selection(for: box)?.selectionsByLine() ?? []).map { $0.bounds(for: page).width }
            .filter { $0 < box.width * 0.95 }.max() ?? box.width
        var column = (minX: previous.minX, maxX: previous.maxX)
        let labelOnly = (title.string as NSString).length <= spot.range.length + 1
        var reference = first.map(\.size).max() ?? start.size
        for index in 0..<4 {
            let below = lines.filter { line in
                line.rect.midY < previous.midY - reference * 0.5 && line.rect.maxX > column.minX && line.rect.minX < column.maxX
            }
            guard let next = below.max(by: { $0.rect.maxY < $1.rect.maxY }) else { break }
            let step = previous.maxY - next.rect.maxY
            if index == 0 && labelOnly {
                guard step <= max(reference, next.size) * 2.2 else { break }     // the title under its label
                reference = next.size
            } else {
                guard abs(next.size - reference) <= reference * 0.15 else { break }
                let current = title.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let last = current.last, !".!?".contains(last) else { break }
                let following = next.text.string.trimmingCharacters(in: .whitespacesAndNewlines)
                let lastWord = last.isLetter ? current.split(whereSeparator: { !$0.isLetter }).last.map { $0.lowercased() } ?? "" : ""
                let openParenthesis = current.filter { $0 == "(" }.count > current.filter { $0 == ")" }.count
                let size = max(reference, next.size)
                let plainlyOn = ",-–—:;(".contains(last) || continuing.contains(lastWord) || openParenthesis
                let centred = abs(next.rect.midX - previous.midX) < 3 && next.rect.width < previous.width
                    && step <= reference * 1.3
                // (A line as wide as the text wraps – "… Robustness to Initial" / "County Strategic …" –
                // unless the next line is in another font: notes after a bold title.)
                let full = previous.width >= textWidth * 0.85 && fontName(next.text) == previousFont
                guard (plainlyOn && step <= size * 2) || (step <= size * 1.45
                        && (centred || full || following.first?.isLowercase == true)) else { break }
            }
            title = join([title, next.text])
            previous = next.rect
            previousFont = fontName(next.text)
            column = (min(column.minX, next.rect.minX), max(column.maxX, next.rect.maxX))
        }
        return title
    }

    /// Without small type at the very end: a footnote mark right after the last word (up to two
    /// characters without capitals, below 85% of the title's size) or words in much smaller type (below 65%:
    /// a slide's navigation buttons, "Notes", "Back"). Small capitals stay (~75–80%).
    private static func withoutTrailingMarks(_ text: NSAttributedString) -> NSAttributedString {
        var counts: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? NSFont { counts[(font.pointSize * 2).rounded() / 2, default: 0] += range.length }
        }
        guard let main = counts.max(by: { $0.value < $1.value })?.key, main > 0 else { return text }
        var result = trim(text)
        for _ in 0..<4 {
            guard result.length > 1 else { break }
            var range = NSRange()
            let font = result.attribute(.font, at: result.length - 1, effectiveRange: &range) as? NSFont
            guard let size = font?.pointSize else { break }
            let run = (result.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            let before = range.location > 0 ? (result.string as NSString).character(at: range.location - 1) : 32
            // (No capitals: "TRADE WAR" in small capitals ends in a smaller "AR".)
            let mark = run.count <= 2 && size < main * 0.85 && !run.contains(where: \.isUppercase)
                && !(Unicode.Scalar(before).map { CharacterSet.whitespaces.contains($0) } ?? true)
            guard range.location > 0, mark || size < main * 0.65 else { break }
            result = trim(result.attributedSubstring(from: NSRange(location: 0, length: range.location)))
        }
        return result
    }

    static func addLinks(to document: PDFDocument) {
        report = []
        collected = []
        defer {
            let list = JumpTargets()
            list.items = collected.sorted { a, b in
                let ia = document.index(for: a.page), ib = document.index(for: b.page)
                return ia != ib ? ia < ib : a.point.y > b.point.y
            }
            jumpTargetLists.setObject(list, forKey: document)
            collected = []
        }
        keptBecause = [:]
        usesNumberedCitations = false
        var texts: [(page: PDFPage, text: NSString)] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let string = page.string else { continue }
            texts.append((page, string as NSString))
        }
        if let start = referenceListStart(texts) {
            let heading = texts[start.index].page.selection(for: NSRange(location: start.location, length: 1))?
                .bounds(for: texts[start.index].page)
            // The list ends at the last page in a row that still looks like references (an
            // appendix may follow).
            var end = start.index
            if let entryLine = try? NSRegularExpression(
                pattern: #"(?m)^[ \t]*(?:\p{Lu}[^\n]{0,220}?\b(?:19|20)\d\d|\[?\d{1,3}[\].])"#) {
                var index = start.index + 1
                while index < texts.count,
                      entryLine.numberOfMatches(in: texts[index].text as String,
                                                range: NSRange(location: 0, length: texts[index].text.length)) >= 3 {
                    end = index
                    index += 1
                }
            }
            referenceLists.setObject(ReferenceList(startPage: document.index(for: texts[start.index].page),
                                                   headingTop: heading?.maxY ?? .greatestFiniteMagnitude,
                                                   endPage: document.index(for: texts[end].page)), forKey: document)
        }
        addFigureAndTableLinks(texts)
        addSectionLinks(document, texts)
        addEquationLinks(texts)
        addNumberedCitationLinks(texts)
        if !usesNumberedCitations { addAuthorYearLinks(texts) }
        addFootnoteLinks(document)
        report.append("existing links kept: " + keptBecause.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
    }

    // MARK: Footnotes

    /// Footnote marks are small raised numbers right after a word in body text ("wage.³"); the
    /// footnote starts with the same small number at the beginning of a line, followed by the
    /// footnote's (larger) text, lower on the same page or on the next one. The conditions keep
    /// out subscripts, exponents, numbers in tables and figure axes, and numbers inside footnotes.
    private static func addFootnoteLinks(_ document: PDFDocument) {
        struct SmallNumber {
            let number: Int
            let range: NSRange
            let isMark: Bool        // in the text (else: the start of a footnote)
            let y: CGFloat
        }
        func isDigit(_ character: unichar) -> Bool { character >= 48 && character <= 57 }
        func isSpace(_ character: unichar) -> Bool { character == 32 || character == 9 || character == 10 || character == 13 }

        var perPage: [(page: PDFPage, numbers: [SmallNumber])] = []
        var smallRuns = 0
        var rejected: [String: Int] = [:]
        // The document's body size (a page's may be a table's).
        var documentCounts: [CGFloat: Int] = [:]
        for index in 0..<document.pageCount {
            guard let attributed = document.page(at: index)?.attributedString else { continue }
            attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                guard let font = value as? NSFont else { return }
                documentCounts[(font.pointSize * 2).rounded() / 2, default: 0] += range.length
            }
        }
        let documentBody = documentCounts.max(by: { $0.value < $1.value })?.key ?? 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let attributed = page.attributedString else { continue }
            let text = attributed.string as NSString
            func size(at location: Int) -> CGFloat {
                guard location >= 0, location < attributed.length else { return 0 }
                return (attributed.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
            }
            // The body text size: the most common font size, by character count.
            var counts: [CGFloat: Int] = [:]
            attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                guard let font = value as? NSFont else { return }
                counts[(font.pointSize * 2).rounded() / 2, default: 0] += range.length
            }
            guard let body = counts.max(by: { $0.value < $1.value })?.key, body > 0 else { continue }

            var numbers: [SmallNumber] = []
            var location = 0
            while location < text.length {
                guard isDigit(text.character(at: location)) else { location += 1; continue }
                var end = location
                let runSize = size(at: location)
                // Split where the size changes: "¹100 questionnaire forms" is the footnote number 1
                // followed by the footnote's text.
                while end < text.length, isDigit(text.character(at: end)), abs(size(at: end) - runSize) < 0.5 { end += 1 }
                let digits = NSRange(location: location, length: end - location)
                location = end
                let digitSize = size(at: digits.location)
                guard digits.length <= 3, digitSize > 0, digitSize <= body * 0.8,
                      let number = Int(text.substring(with: digits)), number > 0,
                      // The whole run in the small size (not the end of a bigger number).
                      size(at: NSMaxRange(digits) - 1) <= body * 0.8 else { continue }
                smallRuns += 1
                let before = digits.location - 1
                let lineStart = before < 0 || text.character(at: before) == 10 || text.character(at: before) == 13

                // The start of a footnote: at a line start and followed on the same line (after a
                // space or period) by larger text. A number alone at a line start is a mark that
                // PDFKit moved past a line break ("… the mita.⏎26⏎Specifically, …").
                var next = NSMaxRange(digits)
                while next < text.length, [32, 9, 46].contains(text.character(at: next)) { next += 1 }
                var isStart = lineStart && next < text.length && ![10, 13].contains(text.character(at: next))
                    && size(at: next) >= digitSize * 1.15
                // PDFKit may also break the line after a raised footnote number ("3⏎More than …");
                // then the footnote's (smaller than body) text starts just right of the number, at
                // its height – on one of the next lines, as PDFKit may list the footnote's lines out
                // of order ("4⏎captures.⏎In Appendix 2 …"). (Body-size text there is a formula:
                // a sum's limit above "ln y"; so is text not starting with a capital or a word,
                // the limit below a sum, "l=0".)
                if lineStart, !isStart, next < text.length, [10, 13].contains(text.character(at: next)),
                   let numberBounds = page.selection(for: digits)?.bounds(for: page) {
                    var lineBreak = next
                    for _ in 0..<3 where !isStart && lineBreak < text.length {
                        var after = lineBreak
                        while after < text.length, isSpace(text.character(at: after)) { after += 1 }
                        guard after < text.length else { break }
                        let textSize = size(at: after)
                        let word = text.substring(with: NSRange(location: after, length: min(2, text.length - after)))
                        let startsLikeText = word.first?.isUppercase == true || (word.count == 2 && word.allSatisfy(\.isLetter))
                        if startsLikeText, textSize >= digitSize * 1.15, textSize < documentBody * 0.95,
                           let textBounds = page.selection(for: NSRange(location: after, length: 1))?.bounds(for: page) {
                            let gap = textBounds.minX - numberBounds.maxX
                            isStart = gap > -1 && gap < body * 0.6
                                && textBounds.minY < numberBounds.maxY && textBounds.maxY > numberBounds.minY
                        }
                        lineBreak = after
                        while lineBreak < text.length, ![10, 13].contains(text.character(at: lineBreak)) { lineBreak += 1 }
                    }
                }
                if isStart {
                    guard let selection = page.selection(for: digits) else { continue }
                    numbers.append(SmallNumber(number: number, range: digits, isMark: false, y: selection.bounds(for: page).midY))
                } else {
                    guard before >= 0 else { continue }
                    // A mark: right after a body-size character (a word or punctuation, no space).
                    // (PDFKit sometimes puts a space between a word and a raised number; then the
                    // gap on the page decides.)
                    var previousIndex = before
                    if isSpace(text.character(at: previousIndex)), previousIndex > 0,
                       !isSpace(text.character(at: previousIndex - 1)) { previousIndex -= 1 }
                    guard !isSpace(text.character(at: previousIndex)) else { rejected["space before", default: 0] += 1; continue }
                    guard size(at: previousIndex) >= body * 0.9 else {
                        rejected["small text before", default: 0] += 1
                        continue
                    }
                    guard let selection = page.selection(for: digits),
                          let previous = page.selection(for: NSRange(location: previousIndex, length: 1)) else { continue }
                    let mark = selection.bounds(for: page), word = previous.bounds(for: page)
                    // (No "raised" test: PDFKit reports a superscript's bounds at the line's height, so
                    // it can't be told from a subscript here. Requiring a matching footnote start
                    // keeps subscripts out in practice.)
                    guard word.height > 0 else { continue }
                    guard mark.minX - word.maxX < body * 0.6 else { rejected["far from word", default: 0] += 1; continue }
                    numbers.append(SmallNumber(number: number, range: digits, isMark: true, y: mark.midY))
                }
            }
            perPage.append((page, numbers))
        }

        var added = 0
        // Endnotes: a "Notes" heading near the end, then "1. …", "2. …" in order. (Only in order,
        // and anywhere in the line: PDFKit may list hanging numbers apart from their text,
        // "Notes 1. 2. For an extensive …".)
        var endnotes: [Int: (PDFPage, NSRange)] = [:]
        if let headingPattern = try? NSRegularExpression(
               pattern: #"(?m)^[ \t]*(?:Notes|NOTES|Endnotes|ENDNOTES|Anmerkungen|ANMERKUNGEN|Endnoten|ENDNOTEN)[ \t\r:]*$"#),
           let notePattern = try? NSRegularExpression(pattern: #"(?<![\d.,\-–])(\d{1,3})[.)](?=[ \t\r\n])"#) {
            var heading: (index: Int, location: Int)?
            for index in 0..<document.pageCount {
                guard let text = document.page(at: index)?.string as NSString? else { continue }
                if let last = headingPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)).last {
                    heading = (index, NSMaxRange(last.range))
                }
            }
            if let heading {
                var expected = 1
                scan: for index in heading.index..<document.pageCount {
                    guard let page = document.page(at: index), let text = page.string as NSString? else { continue }
                    let from = index == heading.index ? heading.location : 0
                    for match in notePattern.matches(in: text as String, range: NSRange(location: from, length: text.length - from)) {
                        let number = Int(text.substring(with: match.range(at: 1))) ?? 0
                        if number == expected {
                            endnotes[number] = (page, match.range(at: 1))
                            expected += 1
                        }
                    }
                    if index > heading.index + 5 && endnotes.isEmpty { break scan }
                }
                if endnotes.count < 3 { endnotes = [:] }
            }
        }
        report.append("endnotes: \(endnotes.count)")
        var lastEndnote = 0
        // Footnote numbers only go up through a paper (or start again at 1, as in a book's
        // chapters): a raised "2" in "σ²" after footnote 30 is no mark.
        // (Compared with earlier pages only: within a page, PDFKit's text order may jump
        // between columns.)
        var lastFootnote = 0, pageMax = 0
        var footnoteStarts = Set<String>()     // "page:location", for the jump palette
        for (number, (page, range)) in endnotes {
            collect(.note, String(number), Spot(page: page, range: range),
                    title: "\(number) " + lineText(Spot(page: page, range: range), after: true))
        }
        func inOrder(_ number: Int) -> Bool { number >= lastFootnote || number == 1 }

        for (index, entry) in perPage.enumerated() {
            lastFootnote = max(lastFootnote, pageMax)
            for mark in entry.numbers where mark.isMark {
                var target: (PDFPage, NSRange)?
                if !inOrder(mark.number) {
                    // (No footnote; an endnote is checked by its own order below.)
                } else if let note = entry.numbers.first(where: { !$0.isMark && $0.number == mark.number && $0.y < mark.y }) {
                    target = (entry.page, note.range)
                } else if index + 1 < perPage.count,
                          let note = perPage[index + 1].numbers.first(where: { !$0.isMark && $0.number == mark.number }) {
                    target = (perPage[index + 1].page, note.range)
                } else if let note = endnotes[mark.number],
                          // (In order through the text: a subscript "2" after note 7 is no mark.)
                          mark.number == lastEndnote || mark.number == lastEndnote + 1 {
                    target = note
                    lastEndnote = mark.number
                }
                guard let (page, range) = target else { continue }
                if endnotes.isEmpty { pageMax = max(pageMax, mark.number) }
                if endnotes[mark.number]?.1 != range || endnotes[mark.number]?.0 != page,
                   footnoteStarts.insert("\(document.index(for: page)):\(range.location)").inserted {
                    collect(.note, String(mark.number), Spot(page: page, range: range),
                            title: "\(mark.number) " + lineText(Spot(page: page, range: range), after: true))
                }
                let spot = Spot(page: page, range: range)
                // A PDF link that only points at the top of a page (PDFKit loses "fit width"
                // targets): point it at the footnote.
                if retargetVagueLink(on: entry.page, range: mark.range, to: spot, onlyNearPageTop: true) == .none {
                    addLink(on: entry.page, range: mark.range, to: spot)
                }
                added += 1
            }
        }
        let marks = perPage.reduce(0) { $0 + $1.numbers.filter(\.isMark).count }
        let starts = perPage.reduce(0) { $0 + $1.numbers.filter { !$0.isMark }.count }
        var unmatched: [String] = []
        for (index, entry) in perPage.enumerated() {
            for mark in entry.numbers where mark.isMark {
                let found = entry.numbers.contains { !$0.isMark && $0.number == mark.number }
                    || (index + 1 < perPage.count && perPage[index + 1].numbers.contains { !$0.isMark && $0.number == mark.number })
                    || endnotes[mark.number] != nil
                if !found { unmatched.append("p\(document.index(for: entry.page) + 1) \(mark.number)") }
            }
        }
        report.append("footnote marks without a footnote start: \(unmatched.joined(separator: ", "))")
        let startsList = perPage.flatMap { entry in entry.numbers.filter { !$0.isMark }.map { "p\(document.index(for: entry.page) + 1) \($0.number)" } }
        report.append("footnote starts: \(startsList.joined(separator: ", "))")
        let marksList = perPage.flatMap { entry in entry.numbers.filter(\.isMark).map { "p\(document.index(for: entry.page) + 1) \($0.number)" } }
        report.append("footnote marks: \(marksList.joined(separator: ", "))")
        report.append("footnotes: \(smallRuns) small numbers, \(marks) marks, \(starts) footnote starts, \(added) marks linked; rejected: " + rejected.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
    }

    // MARK: Figures and tables

    private static func addFigureAndTableLinks(_ texts: [(page: PDFPage, text: NSString)]) {
        // Captions: a line starting with a known word and a label, then punctuation or the line end.
        guard let captionPattern = try? NSRegularExpression(
            pattern: #"(?m)^[ \t]*([\p{L}]+)\.?[ \t]*("# + label + #")(?:[ \t]*([:|–—]|\.(?=[\s–—-])|$)|[ \t]+(?=[\p{Lu}\d]))"#) else { return }
        // A sentence can also put "Table 3." at a line start, so rank the candidates: a colon or
        // dash is surely a caption, a line end ("Table 3" above its title) likely, then a period,
        // and least a title right after the number ("Table 4 P2P lending …", Word; a sentence
        // goes on in lowercase: "Table 1 reports …"). ("Table 6.B distinguishes …" is none.)
        var captions: [String: (spot: Spot, rank: Int)] = [:]
        for (page, text) in texts {
            let matches = captionPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length))
                .filter { words[text.substring(with: $0.range(at: 1)).lowercased()] != nil }
            // Entries in a list of figures or tables ("Figure 1: Trends ……… 10") are no captions.
            // Dot leaders and a page number at the end of the line (or, wrapped, the next one)
            // give one away; without leaders, three or more lines like that of one kind on a page,
            // their numbers rising, make a list (a page may hold both lists).
            let pageNumbers: [(number: Int?, leaders: Bool)] = matches.map { match in
                let after = NSMaxRange(match.range(at: 2))
                let tail = text.substring(with: NSRange(location: after, length: min(300, text.length - after)))
                let lines = tail.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).prefix(2)
                for (index, line) in lines.enumerated() {
                    // (A next line that starts another entry is not this one's.)
                    if index == 1, line.range(of: #"^[ \t]*[\p{L}]+\.?[ \t]*\d"#, options: .regularExpression) != nil { break }
                    guard let found = line.range(of: #"(?:[.…][ \t]*){4,}\d{1,4}[ \t]*$|[ \t]\d{1,4}[ \t]*$"#, options: .regularExpression) else { continue }
                    let piece = line[found]
                    return (Int(piece.filter(\.isNumber)), piece.contains(where: { $0 == "." || $0 == "…" }))
                }
                return (nil, false)
            }
            let kinds = matches.map { words[text.substring(with: $0.range(at: 1)).lowercased()]! }
            let listKinds = Set(kinds.filter { kind in
                let numbered = zip(kinds, pageNumbers).filter { $0.0 == kind }.compactMap(\.1.number)
                return numbered.count >= 3 && zip(numbered, numbered.dropFirst()).allSatisfy { $0 <= $1 }
            })
            for (match, (kind, entry)) in zip(matches, zip(kinds, pageNumbers)) {
                if entry.leaders || (listKinds.contains(kind) && entry.number != nil) { continue }
                let key = kind.rawValue + " " + text.substring(with: match.range(at: 2))
                // (No punctuation group: the title follows the number directly.)
                let markRange = match.range(at: 3)
                let mark = markRange.location != NSNotFound && markRange.length > 0 ? text.substring(with: markRange) : ""
                var rank = markRange.location == NSNotFound ? 3 : (mark == "." ? 2 : (mark.isEmpty ? 1 : 0))
                // A table's continuation on the next page ("TABLE I—Continued") only if nothing better.
                let after = NSMaxRange(match.range(at: 2))
                let next = text.substring(with: NSRange(location: after, length: min(20, text.length - after))).lowercased()
                if next.range(of: #"^\W*(?:\(?continued|cont\.|\(cont)"#, options: .regularExpression) != nil { rank += 10 }
                if let existing = captions[key], existing.rank <= rank { continue }
                captions[key] = (Spot(page: page, range: match.range), rank)
            }
        }
        guard !captions.isEmpty else { return }
        for (key, caption) in captions {
            let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
            collect(parts[0] == Kind.table.rawValue ? .table : .figure, parts[1], caption.spot,
                    title: captionTitle(caption.spot))
        }

        // Mentions: a known word with one or more labels ("Tables 2 and 4", "Figs. 2–4").
        let joiners = #"(?:\s*(?:,|;|&|–|-|and|und|to|bis|et|y|e|or|oder)\s*)"#
        guard let mentionPattern = try? NSRegularExpression(
            pattern: #"(?i)(?<![\p{L}])([\p{L}]+)\.?\s?("# + label + #")((?:"# + joiners + label + #")*)"#),
              let labelPattern = try? NSRegularExpression(pattern: label) else { return }
        for (page, text) in texts {
            for match in mentionPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                let word = text.substring(with: match.range(at: 1)).lowercased()
                guard let kind = words[word] else { continue }
                // A dot only after an abbreviation ("Fig. 2"); after a word it ends the sentence
                // ("… in the main tables." above the page number 6).
                let between = NSRange(location: NSMaxRange(match.range(at: 1)),
                                      length: match.range(at: 2).location - NSMaxRange(match.range(at: 1)))
                if text.substring(with: between).contains("."),
                   !["fig", "figs", "tab", "tabs", "abb"].contains(word) { continue }
                // The word and the first label, then each further label on its own.
                var pieces = [(NSUnionRange(match.range(at: 1), match.range(at: 2)), text.substring(with: match.range(at: 2)))]
                let rest = match.range(at: 3)
                if rest.length > 0 {
                    for labelMatch in labelPattern.matches(in: text as String, range: rest) {
                        pieces.append((labelMatch.range, text.substring(with: labelMatch.range)))
                    }
                }
                // The PDF may link only the number ("Table [I]"): extend that link over the word.
                extendNumberLink(on: page, word: match.range(at: 1), number: match.range(at: 2))
                for (range, name) in pieces {
                    guard let target = captions[kind.rawValue + " " + name]?.spot else { continue }
                    // Not the caption itself.
                    if target.page == page, NSIntersectionRange(target.range, range).length > 0 { continue }
                    addLink(on: page, range: range, to: target)
                }
            }
        }
    }

    // MARK: Sections and equations

    private static let sectionLabel = #"(?:\d{1,2}(?:\.\d{1,2}){0,3}|[IVX]{2,6}|[A-Z](?:\.\d{1,2}){0,3})(?![\p{L}\d])"#

    /// The most common font size on a page, and whether the text at a location is a heading
    /// (bold, or larger than that).
    private static func headingFont(_ attributed: NSAttributedString, at location: Int, body: CGFloat) -> Bool {
        guard location < attributed.length,
              let font = attributed.attribute(.font, at: location, effectiveRange: nil) as? NSFont else { return false }
        let name = font.fontName.lowercased()
        let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
            || ["bold", "semibold", "demi", "heavy", "black", "-bd", ".b"].contains { name.contains($0) }
        return bold || font.pointSize >= body * 1.08
    }

    private static func bodySize(_ attributed: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            counts[(font.pointSize * 2).rounded() / 2, default: 0] += range.length
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? 0
    }

    /// "Section 3.2", "Sections 2 and 4", "Appendix A" → the numbered heading ("3.2 Labor strikes",
    /// "A Data Appendix", "Appendix A: Proofs"), set in bold or a larger size.
    private static func addSectionLinks(_ document: PDFDocument, _ texts: [(page: PDFPage, text: NSString)]) {
        guard let headingLine = try? NSRegularExpression(
                pattern: #"(?m)^[ \t]*(?:(?:Appendix|APPENDIX|Anhang|ANHANG|Chapter|CHAPTER|Kapitel)[ \t]+)?("# + sectionLabel + #")\.?[ \t:]+(\p{Lu}[^\n]{1,90})$"#)
        else { return }
        var headings: [String: (spot: Spot, title: String)] = [:]
        var titlePages: [String: Set<Int>] = [:]
        var appendixHeadings: [String: Spot] = [:]
        guard let appendixInLine = try? NSRegularExpression(pattern: #"(?i)\b(?:appendix|anhang)[ \t]+("# + sectionLabel + #")"#) else { return }
        for (page, text) in texts {
            let index = document.index(for: page)
            if let list = referenceLists.object(forKey: document), index > list.startPage, index <= list.endPage { continue }
            guard let attributed = page.attributedString else { continue }
            let body = bodySize(attributed)
            guard body > 0 else { continue }
            for match in headingLine.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                let title = text.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                // A sentence, not a title.
                if title.hasSuffix(".") && title.split(separator: " ").count > 6 { continue }
                titlePages[title.lowercased(), default: []].insert(index)
                guard headingFont(attributed, at: match.range(at: 2).location, body: body),
                      headingFont(attributed, at: match.range(at: 1).location, body: body) else { continue }
                let key = text.substring(with: match.range(at: 1))
                // A letter alone ("A Real-Effort Experiment" is a title starting with "A"): only
                // as "Appendix A …" or in the appendix after the reference list.
                if key.first?.isLetter == true, !key.contains("."), key.count == 1, !["I", "V", "X"].contains(key) {
                    let line = text.substring(with: match.range).trimmingCharacters(in: .whitespaces)
                    let afterList = referenceLists.object(forKey: document).map { index > $0.startPage } ?? false
                    if !line.lowercased().contains("appendix") && !line.lowercased().contains("anhang") && !afterList { continue }
                }
                if headings[key] == nil { headings[key] = (Spot(page: page, range: match.range), title.lowercased()) }
                // "A. Appendix 1: List of …": also known as Appendix 1.
                let line = text.substring(with: match.range)
                if let appendixMatch = appendixInLine.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                    let name = (line as NSString).substring(with: appendixMatch.range(at: 1))
                    if appendixHeadings[name] == nil { appendixHeadings[name] = Spot(page: page, range: match.range) }
                }
            }
        }
        // A running header ("44 ALBERTO ALESINA AND DAVID DOLLAR") repeats on many pages, and
        // numbered sections come in sequence: 3 needs 1 and 2, 3.2 needs 3.
        headings = headings.filter { (titlePages[$0.value.title]?.count ?? 0) < 2 }
        func inSequence(_ key: String) -> Bool {
            let parts = key.split(separator: ".")
            if parts.count > 1 { return headings[parts.dropLast().joined(separator: ".")] != nil }
            guard let number = Int(key) else { return true }
            return (1..<max(number, 1)).allSatisfy { headings[String($0)] != nil }
        }
        headings = headings.filter { inSequence($0.key) }
        report.append("section headings: " + headings.keys.sorted().joined(separator: ", "))
        guard !headings.isEmpty else { return }

        let joiners = #"(?:\s*(?:,|&|–|-|and|und|to|bis|or|oder)\s*)"#
        guard let mentionPattern = try? NSRegularExpression(
                pattern: #"(?<![\p{L}])(Sections?|Secs?\.|Subsections?|Appendix|Appendices|Chapters?|Ch\.|Abschnitte?|Abschnitts|Kapitel|Kap\.|Anhang)\s?("# + sectionLabel + #")((?:"# + joiners + sectionLabel + #")*)"#),
              let labelPattern = try? NSRegularExpression(pattern: sectionLabel) else { return }
        var added = 0
        for (page, text) in texts {
            for match in mentionPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                var pieces = [(NSUnionRange(match.range(at: 1), match.range(at: 2)), text.substring(with: match.range(at: 2)))]
                if match.range(at: 3).length > 0 {
                    for labelMatch in labelPattern.matches(in: text as String, range: match.range(at: 3)) {
                        pieces.append((labelMatch.range, text.substring(with: labelMatch.range)))
                    }
                }
                // "Appendix 1" is an appendix heading, or a heading after the reference list, never
                // section 1 of the main text.
                let word = text.substring(with: match.range(at: 1)).lowercased()
                let isAppendix = word.hasPrefix("append") || word.hasPrefix("anhang")
                for (range, name) in pieces {
                    let target: Spot
                    if isAppendix, let appendix = appendixHeadings[name] {
                        target = appendix
                    } else if let heading = headings[name]?.spot {
                        if isAppendix, let list = referenceLists.object(forKey: document),
                           document.index(for: heading.page) < list.startPage { continue }
                        target = heading
                    } else { continue }
                    if target.page == page, NSIntersectionRange(target.range, range).length > 0 { continue }
                    addLink(on: page, range: range, to: target)
                    added += 1
                }
            }
        }
        report.append("sections: \(added) mentions linked")
    }

    /// "(3)" in the text → the equation numbered "(3)": alone at the right end of a line, after a
    /// wide gap. (Table headers "(1) (2) (3)" have several on a line, so they don't count.)
    private static func isDigitChar(_ c: unichar) -> Bool { c >= 48 && c <= 57 }

    private static func addEquationLinks(_ texts: [(page: PDFPage, text: NSString)]) {
        guard let numberPattern = try? NSRegularExpression(pattern: #"\(((?:[A-Z]\.?)?\d{1,3}[a-z]?)\)"#) else { return }
        var equations: [String: Spot] = [:]
        var mentions: [(page: PDFPage, range: NSRange, number: String)] = []
        for (page, text) in texts {
            guard page.rotation == 0 else { continue }
            var charRects: [(Int, NSRect)]?
            var textRight: CGFloat?
            let numberBounds: [(range: NSRange, rect: NSRect)] = numberPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)).compactMap { m in
                page.selection(for: m.range).map { (m.range, $0.bounds(for: page)) }
            }
            for match in numberPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                let number = text.substring(with: match.range(at: 1))
                guard let selection = page.selection(for: match.range) else { continue }
                let bounds = selection.bounds(for: page)
                // What is printed on the same visual line, by position (PDFKit's text order
                // doesn't always follow the layout).
                if charRects == nil {
                    // PDFKit's character bounds are sometimes off on a whole page (seen with
                    // Unicode math letters, "𝑦𝑖𝑡 = 𝛽1ELEC"): then measure each character as a
                    // selection, which is slower but right. (Checked on this number's digit.)
                    let digit = page.characterBounds(at: match.range.location + 1)
                    let reliable = bounds.insetBy(dx: -2, dy: -2).contains(NSPoint(x: digit.midX, y: digit.midY))
                    charRects = (0..<text.length).compactMap { i in
                        let c = text.character(at: i)
                        // (Spaces of any kind, which TeX output may stretch across the gap
                        // before an equation number.)
                        guard let scalar = Unicode.Scalar(c), !CharacterSet.whitespacesAndNewlines.contains(scalar),
                              !(0x2000...0x200B).contains(Int(c)), c != 0xA0, c != 0x3000 else { return nil }
                        let r = reliable ? page.characterBounds(at: i)
                            : page.selection(for: NSRange(location: i, length: 1))?.bounds(for: page) ?? .zero
                        return r.width > 0 && r.height > 0 && r.width < r.height * 3 ? (i, r) : nil
                    }
                }
                let band = (bounds.minY + bounds.height * 0.3)...(bounds.maxY - bounds.height * 0.3)
                let onLine = charRects!.filter { !NSLocationInRange($0.0, match.range) && $0.1.maxY >= band.lowerBound && $0.1.minY <= band.upperBound }
                let leftRects = onLine.filter { $0.1.midX < bounds.minX }, rightRects = onLine.filter { $0.1.midX > bounds.maxX }
                let gap = leftRects.map { bounds.minX - $0.1.maxX }.min() ?? .greatestFiniteMagnitude
                let gapAfter = rightRects.map { $0.1.minX - bounds.maxX }.min() ?? .greatestFiniteMagnitude
                // Another "(n)" on the line: a table's column headers "(1) (2) (3)".
                let row = numberBounds.contains { other in
                    other.range.location != match.range.location
                        && other.rect.maxY >= band.lowerBound && other.rect.minY <= band.upperBound
                }
                // Alone at the line's right end, after a wide gap, with the formula to its left.
                // (Or alone at the right margin, beside a tall formula.) A formula filling the
                // line leaves less room: then at least an em, with the number flush at the text's
                // right edge (a justified line of prose stretches its spaces less than that).
                let pageBox = page.bounds(for: .cropBox)
                if textRight == nil { textRight = charRects!.map { $0.1.maxX }.max() ?? 0 }
                let size = (page.attributedString.flatMap { match.range.location + 1 < $0.length
                    ? $0.attribute(.font, at: match.range.location + 1, effectiveRange: nil) as? NSFont : nil })?.pointSize ?? bounds.height
                let wideFormula = gap >= size && bounds.maxX >= textRight! - 1 && leftRects.count >= 10
                let isEquationNumber = rightRects.isEmpty && !row && !number.hasPrefix("0")
                    && (leftRects.isEmpty ? bounds.minX > pageBox.minX + pageBox.width * 0.75 : gap > bounds.height * 2.5 || wideFormula)
                if isEquationNumber {
                    if equations[number] == nil { equations[number] = Spot(page: page, range: match.range) }
                } else {
                    // In running text: close to the words on both sides. (A column header in a
                    // regression table, "(1)   (2)   (3)", stands apart.)
                    if !row, gap < bounds.height * 1.2 || leftRects.isEmpty, gapAfter < bounds.height * 1.2 || rightRects.isEmpty,
                       !(leftRects.isEmpty && rightRects.isEmpty) {
                        mentions.append((page, match.range, number))
                    }
                }
            }
        }
        report.append("equations: " + equations.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ", "))
        // Only for documents that number their equations (not a lone "(1)" somewhere).
        guard equations.count >= 2 else { return }
        for (number, spot) in equations { collect(.equation, number, spot, title: "Equation (\(number))") }
        // An inline list, "we run (1) OLS, (2) PPML, and (3) …": counting up from (1) within one
        // sentence, with other words between the items. References to equations have only
        // joiners between them ("(1) and (2)", "(1), (2), and (3)", "(1)–(3)"), and equations
        // discussed one by one sit in different sentences.
        let joinerWords: Set<String> = ["and", "or", "to", "through", "und", "oder", "bis", "et", "ou", "y", "o", "e"]
        func pageIndex(_ page: PDFPage) -> Int { page.document?.index(for: page) ?? -1 }
        var listItems = Set<String>()     // "page:location"
        for (page, text) in texts {
            let here = numberPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length))
                .map { (range: $0.range, number: text.substring(with: $0.range(at: 1))) }
            var i = 0
            while i < here.count {
                guard here[i].number == "1" else { i += 1; continue }
                var run = [here[i]]
                var hasWords = false
                var j = i + 1
                while j < here.count, here[j].number == String(run.count + 1) {
                    let previous = run.last!
                    let between = text.substring(with: NSRange(location: NSMaxRange(previous.range),
                                                               length: here[j].range.location - NSMaxRange(previous.range)))
                    // A sentence ends in between: not one list.
                    if between.range(of: #"[.!?]\s+\p{Lu}"#, options: .regularExpression) != nil || between.count > 400 { break }
                    let words = between.split { !$0.isLetter }.map { $0.lowercased() }
                    if words.contains(where: { !joinerWords.contains($0) }) { hasWords = true }
                    run.append(here[j])
                    j += 1
                }
                if run.count >= 2 && hasWords {
                    for item in run { listItems.insert("\(pageIndex(page)):\(item.range.location)") }
                }
                i = max(j, i + 1)
            }
        }
        let otherNumbered: Set<String> = ["column", "columns", "col", "cols", "panel", "panels", "row", "rows", "model", "models",
            "assumption", "assumptions", "condition", "conditions", "proposition", "propositions", "lemma", "lemmas",
            "theorem", "theorems", "corollary", "hypothesis", "hypotheses", "step", "steps", "item", "items", "footnote",
            "note", "question", "questions", "specification", "specifications", "regression", "regressions", "spalte", "spalten", "zeile", "zeilen", "modell", "annahme", "hypothese", "schritt"]
        var added = 0
        for mention in mentions {
            guard let target = equations[mention.number],
                  !listItems.contains("\(pageIndex(mention.page)):\(mention.range.location)") else { continue }
            let text = texts.first { $0.page == mention.page }?.text
            // Not inside a list "(1) … (2) …" at a line start, and not a year-like "(2010)".
            if let text, mention.range.location > 0 {
                let previous = text.character(at: mention.range.location - 1)
                if previous == 10 || previous == 13 { continue }
                // A volume and issue, "80(4)".
                if previous >= 48 && previous <= 57 { continue }
            }
            // "Column (3)", "Model (2)", "Assumption (1)": numbered, but not an equation.
            if let text {
                let before = text.substring(with: NSRange(location: max(0, mention.range.location - 20),
                                                          length: min(20, mention.range.location)))
                if let word = before.split(whereSeparator: { !$0.isLetter }).last?.lowercased(), otherNumbered.contains(word) { continue }
            }
            if let selection = mention.page.selection(for: mention.range),
               isInReferenceList(mention.page, y: selection.bounds(for: mention.page).midY) { continue }
            addLink(on: mention.page, range: mention.range, to: target)
            added += 1
        }
        report.append("equations: \(added) mentions linked")
    }

    // MARK: Reference list

    private static let headingPattern = try? NSRegularExpression(
        pattern: #"(?mi)^[ \t]*(?:(?:\d+|[ivxl]{1,5}|[a-z])\.?[ \t]*)?(references|bibliography|literature cited|works cited|literatur|literaturverzeichnis|références|bibliographie|referencias|bibliografía|bibliografia|riferimenti bibliografici)[ \t\r]*$"#)

    /// Where the reference list starts: the last such heading (page index, character offset).
    private static func referenceListStart(_ texts: [(page: PDFPage, text: NSString)]) -> (index: Int, location: Int)? {
        guard let headingPattern else { return nil }
        var start: (index: Int, location: Int)?
        for (index, entry) in texts.enumerated() {
            let matches = headingPattern.matches(in: entry.text as String, range: NSRange(location: 0, length: entry.text.length))
            if let last = matches.last { start = (index, last.range.location) }
        }
        return start
    }

    // MARK: Author–year citations

    private struct AuthorEntry {
        let firstAuthor: String          // lowercase
        let names: Set<String>           // all capitalized words before the year, lowercase
        let year: String                 // "2012", "2012a"
        let spot: Spot
    }

    /// "Herzer and Nunnenkamp (2012)", "(Herzer & Nunnenkamp, 2012; Smith, 2010)", "Fehr et al.
    /// (2009)", "Smith (2010, 2012a)": found by working back from the reference list. Its entries
    /// give first author and year; the text is searched only for those, which keeps the many
    /// other years and names in a paper from turning into links.
    private static func addAuthorYearLinks(_ texts: [(page: PDFPage, text: NSString)]) {
        guard let start = referenceListStart(texts),
              let entryPattern = try? NSRegularExpression(
                pattern: #"(?m)^[ \t]*(\p{Lu}(?: (?=\p{Lu}{2}))?[\p{L}\p{M}\p{Sk}'’\-]+)((?:[ \t]+[\p{L}\p{M}\p{Sk}'’\-]+){0,3}[ \t]?,[ \t\n](?=\p{Lu}|(?:1\d|20)\d\d)[^\n]{0,220}?(?:\n[ \t]*)?)(?<!\d[–\-])\b((?:1\d|20)\d\d[a-z]?)\b(?![–\-]\d)"#),
              // Springer's style: the year in parentheses at the end of the entry, a few lines on
              // ("Arellano, M., Bond, S.: Some Tests … ⏎to Employment … 58, 277 (1991)"); not past
              // a line that starts another entry ("Name, I." – not "Series, 16425." or "University
              // Press, Ithaca NY (2013)" – or a rule). The name may start with a particle ("de Haan,
              // J."); an organization has a colon instead of the comma ("World Bank.: …").
              // (Not "In: Harrison, A. (ed.) …", the book of a chapter.)
              let endYearPattern = try? NSRegularExpression(
                pattern: #"(?m)^[ \t]*(?!In:)((?:(?:de|van|von|di|da|del|della|du|le|la)(?:[ \t]+(?:der|den|la))?[ \t]+)?\p{Lu}[\p{L}\p{M}\p{Sk}'’\-]+)((?:[ \t]+[\p{L}\p{M}\p{Sk}'’\-]+){0,3}(?:[ \t]?,|\.?:)[ \t]+\p{Lu}[^\n]*?(?:\n(?![ \t]*(?:(?:de|van|von|di|da|del|della|du|le|la)[ \t]+)?(?:\p{Lu}[\p{L}\p{M}\p{Sk}'’\-]+(?:[ \t]+[\p{L}\p{M}\p{Sk}'’\-]+){0,3},[ \t]+\p{Lu}[.\-]|[\x{2012}-\x{2015}_]))[^\n]*?){0,3}?\()((?:1\d|20)\d\d[a-z]?)\)\.?[ \t]*(?:$|(?=http))"#),
              // Organizations in capitals, without a comma: "CENTER FOR INTERNATIONAL EARTH SCIENCE
              // INFORMATION (2004)", "INSTITUTO NACIONAL DE RECURSOS NATURALES (INRENA) (1997)".
              let organizationPattern = try? NSRegularExpression(
                pattern: #"(?m)^[ \t]*(\p{Lu}{2,}[\p{Lu}\p{M}'’\-]*)((?:[ \t]+[\p{Lu}\p{M}'’\-()&]+){1,10}[ \t]*\()((?:1\d|20)\d\d[a-z]?)\)"#),
              // … or in ordinary capitalization: "World Health Organization (2001)", "IMS. (2011)".
              let organizationTitlePattern = try? NSRegularExpression(
                pattern: #"(?m)^[ \t]*(\p{Lu}[\p{L}\p{M}'’\-&]+)((?:[ \t]+(?:of|for|and|on|the|de|du|des|der|für|und|\p{Lu}[\p{L}\p{M}'’\-&]*)){0,7}\.?[ \t]*\()((?:1\d|20)\d\d[a-z]?)\)"#),
              let wordPattern = try? NSRegularExpression(pattern: #"\p{Lu}[\p{L}\p{M}\p{Sk}'’\-]{2,}"#),
              let repeatPattern = try? NSRegularExpression(pattern: #"(?m)^[ \t\x{2012}-\x{2015}_-]*\(((?:1\d|20)\d\d[a-z]?)\)"#),
              let yearPattern = try? NSRegularExpression(pattern: #"(?<![\d/.-])((?:1\d|20)\d\d[a-z]?)(?![\d])"#) else { return }

        // 1. Entries: a line starting with a capitalized name, with a year later on that line
        //    ("Herzer, D., & Nunnenkamp, P. (2012)", "Amiti, Mary, …, and David E. Weinstein. 2019.").
        var entries: [AuthorEntry] = []
        // Only the list's own pages (an appendix may follow: "IV regressions, … in 2010").
        var listEnd = texts.count - 1
        if let document = texts.first?.page.document, let list = referenceLists.object(forKey: document),
           let last = texts.lastIndex(where: { document.index(for: $0.page) <= list.endPage }) { listEnd = last }
        for index in start.index...max(start.index, listEnd) {
            let (page, text) = texts[index]
            let from = index == start.index ? start.location : 0
            let range = NSRange(location: from, length: text.length - from)
            // Repeated authors are often replaced by a rule ("——— (1988): …", which may come out
            // as nothing at all): a line starting with the year is another entry by the author before.
            let repeats = repeatPattern.matches(in: text as String, range: range)
            var nextRepeat = 0
            var entryRanges: [NSRange] = []
            func addRepeats(before location: Int) {
                while nextRepeat < repeats.count, repeats[nextRepeat].range.location < location {
                    let year = repeats[nextRepeat].range(at: 1)
                    nextRepeat += 1
                    // (Not the end of an entry: "… 353–390⏎(2019)".)
                    guard let previous = entries.last,
                          !entryRanges.contains(where: { NSLocationInRange(year.location, $0) }) else { continue }
                    entries.append(AuthorEntry(firstAuthor: previous.firstAuthor, names: previous.names,
                                               year: text.substring(with: year), spot: Spot(page: page, range: year)))
                }
            }
            defer { addRepeats(before: Int.max) }
            // Where both find something, the one starting first: a match starting on a later line
            // of an entry ("Series, 16425. (2010)") is no entry of its own. For the same entry, the
            // year at its end when the first one follows a word – a title's ("World Inequality
            // Report 2018. … (2017a)"), not "Smith, J. (2010)" or "Weinstein. 2019.".
            let endYearMatches = endYearPattern.matches(in: text as String, range: range)
            var people: [NSTextCheckingResult] = []
            for match in (entryPattern.matches(in: text as String, range: range).map { match -> NSTextCheckingResult in
                let year = match.range(at: 3).location
                guard year >= 2, text.character(at: year - 1) == 32,
                      let scalar = Unicode.Scalar(text.character(at: year - 2)), CharacterSet.letters.contains(scalar),
                      let atEnd = endYearMatches.first(where: { $0.range.location == match.range.location }) else { return match }
                return atEnd
            } + endYearMatches).sorted(by: { $0.range.location < $1.range.location })
            where !people.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) {
                people.append(match)
            }
            let organizations = (organizationPattern.matches(in: text as String, range: range)
                                 + organizationTitlePattern.matches(in: text as String, range: range)).filter { org in
                !people.contains { NSIntersectionRange($0.range, org.range).length > 0 }
            }
            entryRanges = (people + organizations).map(\.range)
            for match in (people + organizations).sorted(by: { $0.range.location < $1.range.location }) {
                addRepeats(before: match.range.location)
                // (Small caps sometimes come out as "N ILES": join them.)
                let first = fold(text.substring(with: match.range(at: 1)).replacingOccurrences(of: " ", with: ""))
                let head = text.substring(with: NSRange(location: match.range(at: 1).location,
                                                        length: match.range(at: 3).location - match.range(at: 1).location))
                var names = Set<String>()
                for word in wordPattern.matches(in: head, range: NSRange(location: 0, length: (head as NSString).length)) {
                    names.insert(fold((head as NSString).substring(with: word.range)))
                }
                // The target: the first author's name, not the whole text line (PDFKit sometimes
                // joins an entry's first line with the end of the one before).
                entries.append(AuthorEntry(firstAuthor: first, names: names,
                                           year: text.substring(with: match.range(at: 3)),
                                           spot: Spot(page: page, range: match.range(at: 1))))
            }
        }
        report.append("author–year: \(entries.count) entries: " + entries.map { "\($0.firstAuthor) \($0.year)" }.joined(separator: ", "))
        guard entries.count >= 3 else { return }
        for entry in entries {
            var title = lineText(entry.spot, extent: .entry)
            // A repeated author ("——— (1988)"): the name from the entry before.
            if title.first?.isLetter != true { title = entry.firstAuthor.capitalized + " " + title }
            collect(.reference, nil, entry.spot, keywords: entry.names.joined(separator: " ") + " " + entry.year, title: title)
        }
        var byYear: [String: [AuthorEntry]] = [:]
        for entry in entries { byYear[entry.year, default: []].append(entry) }

        // 2. Citations: each year in the text, with the names just before it.
        var added = 0, retargeted = 0
        var unmatched: [String] = [], outcomes: [String] = [], listSamples: [String] = []
        defer {
            report.append("author–year unmatched in list: " + listSamples.joined(separator: " | "))
            report.append("author–year unmatched: " + unmatched.joined(separator: " | "))
            report.append("author–year outcomes: " + outcomes.joined(separator: " | "))
        }
        // The text before the list, and any appendix after it.
        let citingPages = Array(0...start.index) + Array(min(listEnd + 1, texts.count)..<texts.count)
        for index in citingPages {
            let (page, text) = texts[index]
            let end = index == start.index ? start.location : text.length
            var previous: (end: Int, entry: AuthorEntry)?
            for match in yearPattern.matches(in: text as String, range: NSRange(location: 0, length: end)) {
                let year = text.substring(with: match.range(at: 1))
                guard let candidates = byYear[year] else { previous = nil; continue }
                // The words before this year, back to the previous ";", "(", ")", "[" or "]", except
                // a "(" right before the year, as in "Smith (2010)".
                var namePage = page, nameText = text
                var windowStart = 0, raw = "", window = "", nameFromWindow = true
                var best: (entry: AuthorEntry, score: Int, position: String.Index)?
                for attempt in 0..<2 {
                    var nameEnd = match.range.location
                    if attempt == 1 {
                        // A citation broken across pages ("… Topalova⏎ ⏎360 V. Lang, …⏎2010"): with the
                        // year among the page's first lines (running head, page number), the names
                        // may end the page before.
                        guard best == nil, index > 0, citingPages.contains(index - 1),
                              text.substring(to: match.range.location).filter(\.isNewline).count <= 2 else { break }
                        namePage = texts[index - 1].page
                        nameText = texts[index - 1].text
                        nameEnd = nameText.length
                        while nameEnd > 0, let scalar = Unicode.Scalar(nameText.character(at: nameEnd - 1)),
                              CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "([")).contains(scalar) {
                            nameEnd -= 1
                        }
                    }
                    windowStart = max(0, nameEnd - 90)
                    raw = nameText.substring(with: NSRange(location: windowStart, length: nameEnd - windowStart))
                    // A name broken at its hyphen ("Goldsmith-⏎Pinkham"), or hyphenated at the line end
                    // ("Ham-⏎mar"): both readings, the list decides.
                    func cleaned(_ lineEndHyphen: String) -> String {
                        var window = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "-\r\n", with: lineEndHyphen).replacingOccurrences(of: "-\n", with: lineEndHyphen)
                        if window.hasSuffix("(") || window.hasSuffix("[") { window.removeLast() }
                        // An acronym in parentheses belongs to the name: "Ministro de Educación del Perú (MINEDU) (2005b)".
                        window = window.replacingOccurrences(of: #"\s*\(\p{Lu}{2,}\)"#, with: "", options: .regularExpression)
                        if let cut = window.lastIndex(where: { ";()[]".contains($0) }) {
                            window = String(window[window.index(after: cut)...])
                        }
                        return window
                    }
                    window = cleaned("-")
                    let unbroken = fold(cleaned(""))
                    nameFromWindow = true
                    if attempt == 0, !window.contains(where: { $0.isLetter }), let prev = previous,
                       text.substring(with: NSRange(location: prev.end, length: max(0, match.range.location - prev.end)))
                           .range(of: #"^[\s,;]*$"#, options: .regularExpression) != nil {
                        // "Smith (2010, 2012)": the same authors as the citation just before.
                        window = prev.entry.names.joined(separator: " ")
                        nameFromWindow = false
                    }
                    let lower = fold(window)
                    // The entry whose first author is in the window, preferring the one that shares
                    // the most other names, then the one named nearest the year.
                    // (Name particles written apart in the text and together in the list, or the other
                    // way round: "Di Maggio" / "DiMaggio".)
                    let joined = lower.replacingOccurrences(of: #"\b(di|de|da|del|della|van|von|der|den|le|la|du|mac|mc) "#,
                                                            with: "$1", options: .regularExpression)
                    for entry in candidates {
                        let author = entry.firstAuthor.replacingOccurrences(of: " ", with: "")
                        let found: Range<String.Index>
                        if let direct = lower.range(of: entry.firstAuthor, options: .backwards), isWordBoundary(lower, direct) {
                            found = direct
                        } else if let other = joined.range(of: author, options: .backwards), isWordBoundary(joined, other) {
                            // (A position in the joined text: close enough for ranking, mapped by offset.)
                            let offset = joined.distance(from: joined.startIndex, to: other.lowerBound)
                            let start = lower.index(lower.startIndex, offsetBy: min(offset, lower.count))
                            found = start..<start
                        } else if let other = unbroken.range(of: entry.firstAuthor, options: .backwards), isWordBoundary(unbroken, other) {
                            let offset = unbroken.distance(from: unbroken.startIndex, to: other.lowerBound)
                            let start = lower.index(lower.startIndex, offsetBy: min(offset, lower.count))
                            found = start..<start
                        } else { continue }
                        let score = entry.names.filter { lower.contains($0) || joined.contains($0) || unbroken.contains($0) }.count
                        if best == nil || score > best!.score || (score == best!.score && found.lowerBound > best!.position) {
                            best = (entry, score, found.lowerBound)
                        }
                    }
                }
                guard let best else {
                    if unmatched.count < 40 { unmatched.append("p\(index + 1) “\(window.suffix(40))” \(year)") }
                    // (Diagnostic: how the list spells this name, if it's there.)
                    if let word = wordPattern.matches(in: window, range: NSRange(location: 0, length: (window as NSString).length)).last,
                       word.range.length > 3, listSamples.count < 15 {
                        let tail = (window as NSString).substring(with: NSRange(location: word.range.location + 1, length: word.range.length - 1))
                        for listIndex in start.index..<texts.count {
                            let listText = texts[listIndex].text
                            let found = listText.range(of: tail, options: .caseInsensitive)
                            if found.location != NSNotFound {
                                let from = max(0, found.location - 30)
                                listSamples.append("\(tail): " + listText.substring(with: NSRange(location: from, length: min(60, listText.length - from))).debugDescription)
                                break
                            }
                        }
                    }
                    previous = nil
                    continue
                }
                // A number between the name and the year that isn't a year itself: not one citation
                // (on a turned page, the running head "MELISSA DELL" before Wiley's download stamp
                // "14680262, 2010, 6, Downloaded from …"). Not across pages, where the page's foot
                // and head come in between.
                if nameFromWindow, namePage === page, String(fold(window)[best.position...])
                    .replacingOccurrences(of: #"\b(?:1\d|20)\d\d[a-z]?\b"#, with: "", options: .regularExpression)
                    .contains(where: { $0.isASCII && $0.isNumber }) {
                    outcomes.append("p\(index + 1) \(best.entry.firstAuthor) \(year), a number between name and year: skipped")
                    previous = nil
                    continue
                }
                if namePage !== page {
                    // Split across pages: the year here, the name at the end of the page before.
                    previous = (NSMaxRange(match.range), best.entry)
                    let existing = retargetVagueLink(on: page, range: match.range(at: 1), to: best.entry.spot, onlyNearPageTop: true)
                    outcomes.append("p\(index + 1) \(best.entry.firstAuthor) \(year), name on the page before: \(existing)")
                    switch existing {
                    case .none: addLink(on: page, range: match.range(at: 1), to: best.entry.spot); added += 1
                    case .retargeted: retargeted += 1
                    case .kept: break
                    }
                    if let offset = lastFoldedOccurrence(of: best.entry.firstAuthor, in: raw) {
                        // To the end of its line (not over the page's foot, as Springer's "1 3").
                        let rest = NSRange(location: windowStart + offset, length: (raw as NSString).length - offset)
                        let lineEnd = nameText.rangeOfCharacter(from: .newlines, range: rest).location
                        let end = lineEnd == NSNotFound ? NSMaxRange(rest) : lineEnd
                        addLink(on: namePage, range: NSRange(location: rest.location, length: end - rest.location), to: best.entry.spot)
                    }
                    continue
                }
                // The link: from the first author's name to the end of the year (just the year when
                // the name came from the citation before).
                var linkRange = match.range(at: 1)
                if nameFromWindow, let offset = lastFoldedOccurrence(of: best.entry.firstAuthor, in: raw) {
                    let nameLocation = windowStart + offset
                    linkRange = NSRange(location: nameLocation, length: NSMaxRange(match.range(at: 1)) - nameLocation)
                }
                previous = (NSMaxRange(match.range), best.entry)
                // A PDF link on the citation (or only on its year, as in "Cieza de León (1959)"):
                // correct it if it's vague, and link the name too. Otherwise add our own link.
                var existing = retargetVagueLink(on: page, range: linkRange, to: best.entry.spot, onlyNearPageTop: true)
                if existing == .none {
                    existing = retargetVagueLink(on: page, range: match.range(at: 1), to: best.entry.spot, onlyNearPageTop: true,
                                                 citation: linkRange)
                }
                outcomes.append("p\(index + 1) \(best.entry.firstAuthor) \(year): \(existing)")
                switch existing {
                case .none:
                    addLink(on: page, range: linkRange, to: best.entry.spot)
                    added += 1
                case .retargeted, .kept:
                    if existing == .retargeted { retargeted += 1 }
                    // The name, without the " (" before the year (which would touch the year's link).
                    var nameEnd = match.range(at: 1).location
                    while nameEnd > linkRange.location,
                          let scalar = Unicode.Scalar(text.character(at: nameEnd - 1)),
                          CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "(,[")).contains(scalar) {
                        nameEnd -= 1
                    }
                    if nameEnd > linkRange.location {
                        addLink(on: page, range: NSRange(location: linkRange.location, length: nameEnd - linkRange.location),
                                to: best.entry.spot, nextToPDFLink: true)
                    }
                }
            }
        }
        report.append("author–year: \(added) added, \(retargeted) retargeted")
    }

    /// Lowercase without accents: LaTeX often writes "ä" as "a" plus a separate accent mark,
    /// which would otherwise not match.
    private static func fold(_ string: String) -> String {
        // Also drop spacing accents ("G¨achter"), which folding leaves in place.
        let folded = string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter {
            $0.properties.generalCategory != .modifierSymbol && $0.properties.generalCategory != .nonspacingMark
        }))
    }

    /// Where `name` (already folded) last occurs in `text`, ignoring case and accents, as a
    /// UTF-16 offset into `text`. Works character by character so that separate accent marks
    /// ("G¨achter") don't throw the position off.
    private static func lastFoldedOccurrence(of name: String, in text: String) -> Int? {
        var folded: [Character] = []
        var origins: [Int] = []
        var offset = 0
        var previous: Character = " "
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            defer { previous = character }
            // (A line break after a hyphen, "Goldsmith-⏎Pinkham", doesn't count; nor does the hyphen
            // for a name without one, "Ham-⏎mar".)
            if character.isNewline && previous == "-" { offset += String(character).utf16.count; continue }
            if character == "-", !name.contains("-"), index + 1 < characters.count, characters[index + 1].isNewline {
                offset += 1
                continue
            }
            // (Spaces don't count either: "Di Maggio" is "DiMaggio" in the list.)
            if character.isWhitespace && !name.contains(" ") { offset += String(character).utf16.count; continue }
            for piece in fold(String(character)) {
                folded.append(piece)
                origins.append(offset)
            }
            offset += String(character).utf16.count
        }
        let pattern = Array(name)
        guard !pattern.isEmpty, folded.count >= pattern.count else { return nil }
        for start in stride(from: folded.count - pattern.count, through: 0, by: -1)
        where Array(folded[start..<start + pattern.count]) == pattern {
            return origins[start]
        }
        return nil
    }

    private static func isWordBoundary(_ text: String, _ range: Range<String.Index>) -> Bool {
        let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : " "
        let after = range.upperBound < text.endIndex ? text[range.upperBound] : " "
        return !before.isLetter && !after.isLetter
    }

    // MARK: Numbered citations

    private static func addNumberedCitationLinks(_ texts: [(page: PDFPage, text: NSString)]) {
        guard let entryPattern = try? NSRegularExpression(pattern: #"\[(\d{1,3})\]|(?<![\d.,:;/(])(\d{1,3})\.(?!\d)"#),
              let citationPattern = try? NSRegularExpression(pattern: #"\[(\d{1,3}(?:\s*[,–-]\s*\d{1,3})*)\]"#),
              let numberPattern = try? NSRegularExpression(pattern: #"\d{1,3}"#) else { return }

        guard let start = referenceListStart(texts) else { report.append("citations: no reference list heading"); return }
        report.append("citations: reference list from page \(start.index + 1)")

        // Entry numbers ("12." or "[12]") form a column at the left of each entry. Text order
        // can't be trusted (PDFKit may put a number set apart from its entry anywhere in the
        // line), so look at positions: keep the numbers that line up with at least two others.
        var candidates: [(number: Int, spot: Spot, x: CGFloat)] = []
        for index in start.index..<texts.count {
            let (page, text) = texts[index]
            let from = index == start.index ? start.location : 0
            let range = NSRange(location: from, length: text.length - from)
            for match in entryPattern.matches(in: text as String, range: range) {
                let numberRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                guard let number = Int(text.substring(with: numberRange)),
                      let selection = page.selection(for: match.range) else { continue }
                candidates.append((number, Spot(page: page, range: match.range), selection.bounds(for: page).minX))
            }
        }
        var columns: [Int: Int] = [:]                       // x in 4-point steps → count
        for candidate in candidates { columns[Int(candidate.x / 4), default: 0] += 1 }
        func inColumn(_ x: CGFloat) -> Bool {
            let bin = Int(x / 4)
            return (columns[bin - 1] ?? 0) + (columns[bin] ?? 0) + (columns[bin + 1] ?? 0) >= 3
        }
        var entries: [Int: Spot] = [:]
        for candidate in candidates where inColumn(candidate.x) && entries[candidate.number] == nil {
            entries[candidate.number] = candidate.spot
        }
        report.append("citations: \(entries.count) entries, e.g. \(entries.keys.sorted().prefix(5))")
        // A numbered list counts 1, 2, 3, … without gaps (stray numbers in an author–year list
        // don't).
        var run = 0
        while entries[run + 1] != nil { run += 1 }
        usesNumberedCitations = run >= 5
        guard run >= 3 else { return }
        for number in 1...run {
            guard let spot = entries[number] else { continue }
            collect(.reference, String(number), spot, title: "[\(number)] " + lineText(spot, after: true, extent: .entry))
        }
        var added = 0, retargeted = 0, kept = 0
        defer { report.append("citations: \(added) added, \(retargeted) retargeted, \(kept) existing links kept") }

        for index in 0..<texts.count {
            let (page, text) = texts[index]
            // Citations in the text, not the reference list itself.
            let end = index < start.index ? text.length : (index == start.index ? start.location : 0)
            guard end > 0 else { continue }
            for match in citationPattern.matches(in: text as String, range: NSRange(location: 0, length: end)) {
                for numberMatch in numberPattern.matches(in: text as String, range: match.range(at: 1)) {
                    guard let number = Int(text.substring(with: numberMatch.range)), let target = entries[number] else { continue }
                    switch retargetVagueLink(on: page, range: numberMatch.range, to: target) {
                    case .none: addLink(on: page, range: numberMatch.range, to: target); added += 1
                    case .retargeted: retargeted += 1
                    case .kept: kept += 1
                    }
                }
            }
        }
    }

    // MARK: Links

    /// Some PDFs do link citations, but only to the top of the reference page (PLOS, some
    /// Elsevier journals). Point such a link at its entry instead. Returns true if the spot
    /// already has a link (retargeted, or left alone if it goes somewhere else entirely).
    private enum Existing { case none, retargeted, kept }
    /// Why PDF links were left alone (debug log).
    private static var keptBecause: [String: Int] = [:]

    /// Links in the PDF that cover a whole group of citations ("Barbieri, 2002; Li and Reuveny,
    /// 2011; …") with one target. Galley lays its own links for the single citations on top;
    /// the group link only remains for what's left over, and gets no link hint of its own.
    static let groupLinks = NSHashTable<PDFAnnotation>.weakObjects()

    /// The topmost link at a point (detected links are added last, so they win over group links).
    static func link(on page: PDFPage, at point: NSPoint) -> PDFAnnotation? {
        page.annotations.reversed().first { $0.type == "Link" && $0.bounds.contains(point) }
    }

    private static func retargetVagueLink(on page: PDFPage, range: NSRange, to target: Spot,
                                          onlyNearPageTop: Bool = false, citation: NSRange? = nil) -> Existing {
        guard let selection = page.selection(for: range) else { return .none }
        // The last line of the citation (the year): over two lines, the whole bounds would
        // reach over neighbouring links.
        let bounds = selection.selectionsByLine().last?.bounds(for: page) ?? selection.bounds(for: page)
        // The link this citation sits in (its centre inside the link: a neighbouring link that
        // merely touches it, like "Figure 1" before a footnote mark, doesn't count).
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        guard let link = page.annotations.first(where: {
            $0.type == "Link" && $0.bounds.insetBy(dx: -1, dy: -1).contains(center) && !groupLinks.contains($0)
        }) else { return .none }
        // Much wider than this one citation: a link for a whole group of them.
        if link.bounds.width > bounds.width * 1.6 + 12 {
            groupLinks.add(link)
            return .none
        }
        let destination = link.destination ?? (link.action as? PDFActionGoTo)?.destination
        guard let destination, let destinationPage = destination.page else { keptBecause["web link"] = (keptBecause["web link"] ?? 0) + 1; return .kept }
        if onlyNearPageTop, destinationPage == target.page, let entry = target.page.selection(for: target.range) {
            // Already precise (within a few points of the entry): leave it. Otherwise our match
            // (name and year, or a footnote's number) is the better target: some PDFs point a
            // hundred points above the entry, or to the page before it.
            // (Within half a line: in small print, 15 points is already the entry before.)
            let entryBounds = entry.selectionsByLine().first?.bounds(for: target.page) ?? entry.bounds(for: target.page)
            let gap = destination.point.y - entryBounds.maxY
            let tolerance = max(3, entryBounds.height / 2)
            if abs(gap) <= tolerance { keptBecause["precise"] = (keptBecause["precise"] ?? 0) + 1; return .kept }
        }
        // (PLOS links point at each entry, but as a "fit this rectangle" target that PDFKit turns
        // into the top of the page. So don't trust the point; trust the page.)
        guard let targetSelection = target.page.selection(for: target.range) else { return .kept }
        let targetBounds = targetSelection.bounds(for: target.page)
        // Only if the entry is on the page the link points to or a few pages after it (some PDFs
        // point every citation at the start of the list); otherwise it's probably another kind of
        // link that just happens to contain a number.
        guard let document = page.document else { return .kept }
        let linkedIndex = document.index(for: destinationPage), targetIndex = document.index(for: target.page)
        guard targetIndex >= linkedIndex - 1, targetIndex <= linkedIndex + 6 else {
            keptBecause["other page \(linkedIndex + 1)→\(targetIndex + 1)"] = (keptBecause["other page \(linkedIndex + 1)→\(targetIndex + 1)"] ?? 0) + 1
            return .kept
        }
        let precise = PDFDestination(page: target.page, at: topLeft(of: targetBounds, on: target.page))
        // The PDF may split one citation into several links ("Glaeser and Shleifer" + "2002",
        // or the two lines of a broken citation): retarget every piece with the same target
        // that lies on the citation's own text. (Only there: in PLOS, neighbouring citations
        // [3]–[6] all share one target, though they mean different entries.)
        let originalPoint = destination.point
        // (`citation`: the whole citation when only its year was looked up.)
        let citationSelection = citation.flatMap { page.selection(for: $0) } ?? selection
        let citationLines = citationSelection.selectionsByLine().map { $0.bounds(for: page).insetBy(dx: -2, dy: -1) }
        for piece in page.annotations where piece.type == "Link" && !groupLinks.contains(piece) {
            let pieceDestination = piece.destination ?? (piece.action as? PDFActionGoTo)?.destination
            guard piece === link || (citationLines.contains(where: { $0.intersects(piece.bounds) })
                                     && pieceDestination?.page == destinationPage
                                     && abs((pieceDestination?.point.y ?? 0) - originalPoint.y) < 1
                                     && abs((pieceDestination?.point.x ?? 0) - originalPoint.x) < 1) else { continue }
            piece.action = nil
            piece.destination = precise
            origins.setObject("pdf, retargeted" as NSString, forKey: piece)
        }
        return .retargeted
    }

    /// A rectangle's top left corner as the page is shown (on a turned page, another corner).
    static func topLeft(of rect: NSRect, on page: PDFPage) -> NSPoint {
        guard page.rotation != 0 else { return NSPoint(x: rect.minX, y: rect.maxY) }
        let shown = page.transform(for: .mediaBox), r = rect.applying(shown)
        return NSPoint(x: r.minX, y: r.maxY).applying(shown.inverted())
    }

    private static func extendNumberLink(on page: PDFPage, word: NSRange, number: NSRange) {
        guard let numberSelection = page.selection(for: number),
              let wordSelection = page.selection(for: NSRange(location: word.location, length: number.location - word.location)) else { return }
        let numberBounds = numberSelection.bounds(for: page), wordBounds = wordSelection.bounds(for: page)
        guard wordBounds.width > 0, abs(wordBounds.midY - numberBounds.midY) < numberBounds.height / 2,   // same line
              let link = page.annotations.first(where: { $0.type == "Link" && $0.bounds.intersects(numberBounds) }),
              !link.bounds.intersects(wordBounds.insetBy(dx: 2, dy: 2)),
              let destination = link.destination ?? (link.action as? PDFActionGoTo)?.destination else { return }
        let annotation = PDFAnnotation(bounds: wordBounds.insetBy(dx: -0.5, dy: -0.5), forType: .link, withProperties: nil)
        annotation.destination = destination
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        origins.setObject("galley" as NSString, forKey: annotation)
        page.addAnnotation(annotation)
    }

    private static func addLink(on page: PDFPage, range: NSRange, to target: Spot, nextToPDFLink: Bool = false) {
        guard let selection = page.selection(for: range),
              let targetSelection = target.page.selection(for: target.range) else { return }
        // One annotation per line: a citation broken across lines ("Fajgelbaum / et al. (2019)")
        // would otherwise get one big rectangle over both lines, covering its neighbours.
        let lines = selection.selectionsByLine().map { $0.bounds(for: page) }.filter { $0.width > 0 && $0.height > 0 }
        guard !lines.isEmpty else { return }
        // Where the PDF (or an earlier detection) already has a link, keep it. (With `nextToPDFLink`
        // – a citation's name, its year linked by the PDF – not a link on a neighbouring line that
        // only reaches a few points into this one: PDF link boxes can be taller than the line spacing.)
        if lines.contains(where: { line in
            page.annotations.contains {
                guard $0.type == "Link", !groupLinks.contains($0) else { return false }
                let overlap = $0.bounds.intersection(line)
                return nextToPDFLink ? overlap.width > 0 && overlap.height >= line.height / 2 : $0.bounds.intersects(line)
            }
        }) { return }
        let targetBounds = targetSelection.bounds(for: target.page)
        let destination = PDFDestination(page: target.page, at: topLeft(of: targetBounds, on: target.page))
        for line in lines {
            let annotation = PDFAnnotation(bounds: line.insetBy(dx: -0.5, dy: -0.5), forType: .link, withProperties: nil)
            annotation.destination = destination
            let border = PDFBorder()
            border.lineWidth = 0
            annotation.border = border
            origins.setObject("galley" as NSString, forKey: annotation)
            page.addAnnotation(annotation)
        }
    }
}
