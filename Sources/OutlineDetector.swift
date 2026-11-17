import AppKit
import PDFKit

/// The table of contents for the sidebar: the PDF's own outline, cleaned up (stray entries,
/// a lone title entry, outlines that only list the files the PDF was merged from), or – when
/// there is none – one built from the headings in the text: numbered headings ("3.2 Labor
/// strikes", "II.A. Data", "IV. RESULTS") set in bold, a larger size or capitals, and unnumbered
/// ones in the style of "Introduction", "Conclusion", "References".
@MainActor
enum OutlineDetector {
    struct Item {
        var label: String
        /// The section number ("3.2", "II.A", "A"), shown apart from the title; nil when unnumbered.
        var number: String? = nil
        var pageIndex: Int?
        /// Top of the heading (or the PDF's target) in page coordinates.
        var y: CGFloat
        var isOpen: Bool
        var children: [Item]
    }

    struct Result {
        var items: [Item]
        /// Set when the whole outline hangs off a single entry (usually the document title).
        var title: Item?
    }

    /// What the last run did, for the test report and the debug log.
    static var report: [String] = []

    static func outline(for document: PDFDocument) -> Result {
        report = []
        let slides = isSlides(document)
        if slides { report.append("slides: page thumbnails and Fit Page by default") }
        if var items = pdfOutline(document) {
            // Entries that aren't sections ("This link is http://…", left over from a link
            // that was turned into a bookmark; "Abstract"; "Author's Addresses" pointing at the
            // address below the references).
            items.removeAll { $0.children.isEmpty && (isStray($0.label) || isNotASection($0.label)) }
            // Like Preview: a lone top-level entry with children is a title, not a section.
            if items.count == 1, !items[0].children.isEmpty {
                report.append("outline: from the PDF, title entry \"\(items[0].label)\" left out")
                var title = items[0]
                title.children = []
                return Result(items: groupAppendix(expandTopLevel(numbered(items[0].children, document)), document), title: title)
            }
            report.append("outline: from the PDF")
            return Result(items: groupAppendix(expandTopLevel(numbered(items, document)), document), title: nil)
        }
        // Slide titles aren't sections, and the type sizes on slides say little about structure.
        if slides {
            report.append("outline: none – slides")
            return Result(items: [], title: nil)
        }
        // Text recognized from a scanned page gets a slightly different size on every line, so
        // the type says nothing about headings.
        if isScanned(document) {
            report.append("outline: none – scanned pages with recognized text")
            return Result(items: [], title: nil)
        }
        let headings = detectHeadings(document)
        report.append("outline: \(headings.isEmpty ? "none found" : "\(headings.count) headings found in the text")")
        return Result(items: groupAppendix(expandTopLevel(numbered(tree(headings), nil)), document), title: nil)
    }

    /// Whether the document is a slide deck (Beamer, PowerPoint, Keynote, …): nearly all pages
    /// clearly wider than tall. A paper with a few landscape table pages doesn't qualify.
    static func isSlides(_ document: PDFDocument) -> Bool {
        let count = document.pageCount
        guard count > 1 else { return false }
        let wide = (0..<count).filter { index in
            guard let page = document.page(at: index) else { return false }
            var size = page.bounds(for: .cropBox).size
            if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
            return size.width > size.height * 1.15
        }.count
        return Double(wide) >= Double(count) * 0.9
    }

    /// Each slide's title, for the jump palette (not the outline, which 40–50 slides would
    /// overflow): the largest text in the top 40% of the slide, up to three lines in that size
    /// one below the other. Mostly letters (not a page number or a formula), not smaller than most of the slide's text, and in
    /// the font most slides use for their titles (a slide without a title would otherwise offer a
    /// formula or a chart label). The first slide (the talk's title) may differ. Overlays repeat a
    /// slide over several pages with the same title: only the first counts.
    static func slideTitles(_ document: PDFDocument) -> [Item] {
        var byPage: [Int: [Line]] = [:]
        for line in textLines(document, bodySize: bodySize(document)) { byPage[line.pageIndex, default: []].append(line) }
        var found: [(index: Int, title: String, top: CGFloat, font: String)] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let lines = byPage[index] else { continue }
            let box = page.bounds(for: .cropBox)
            // (Mostly letters: not a formula like "k = sf(k) − (d + n + θ)k" in the title's place.)
            let candidates = lines.filter { line in
                let letters = line.text.filter(\.isLetter).count
                return line.top >= box.maxY - box.height * 0.4 && letters >= 3
                    && Double(letters) >= Double(line.text.filter { !$0.isWhitespace }.count) * 0.6
            }
            guard let size = candidates.map(\.size).max() else { continue }
            let sizes = lines.map(\.size).sorted()
            guard size >= sizes[sizes.count / 2] else { continue }
            let large = candidates.filter { abs($0.size - size) < 0.5 }.sorted { $0.top > $1.top }
            var block = [large[0]]
            for line in large.dropFirst() where block.count < 3 {
                guard let last = block.last, last.bottom - line.top < line.size * 0.8, last.bottom > line.bottom else { break }
                block.append(line)
            }
            found.append((index, block.map(\.text).joined(separator: " "), block[0].top, block[0].fontName))
        }
        var fonts: [String: Int] = [:]
        for entry in found where entry.index > 0 { fonts[entry.font, default: 0] += 1 }
        let titleFont = fonts.max { $0.value < $1.value }?.key
        var items: [Item] = []
        var previous: (index: Int, title: String)?
        for entry in found where entry.index == 0 || entry.font == titleFont {
            defer { previous = (entry.index, entry.title) }
            if let previous, previous.index == entry.index - 1, previous.title == entry.title { continue }
            items.append(Item(label: entry.title, pageIndex: entry.index, y: entry.top, isOpen: false, children: []))
        }
        return items
    }

    /// Whether most pages are scans: an image with the recognized text laid over it invisibly
    /// (text render mode 3), as JSTOR and OCR tools do. Checks up to 8 pages after the first
    /// (often a born-digital cover sheet).
    static func isScanned(_ document: PDFDocument) -> Bool {
        guard let cg = document.documentRef, cg.numberOfPages > 1 else { return false }
        func streams(_ object: CGPDFObjectRef) -> Data {
            var stream: CGPDFStreamRef?
            var array: CGPDFArrayRef?
            var format = CGPDFDataFormat.raw
            if CGPDFObjectGetValue(object, .stream, &stream), let stream,
               let data = CGPDFStreamCopyData(stream, &format) { return data as Data }
            guard CGPDFObjectGetValue(object, .array, &array), let array else { return Data() }
            var data = Data()
            for index in 0..<CGPDFArrayGetCount(array) {
                var item: CGPDFObjectRef?
                if CGPDFArrayGetObject(array, index, &item), let item { data += streams(item) }
            }
            return data
        }
        let pages = Array(2...min(cg.numberOfPages, 9))
        let invisible = pages.filter { number in
            var contents: CGPDFObjectRef?
            guard let dictionary = cg.page(at: number)?.dictionary,
                  CGPDFDictionaryGetObject(dictionary, "Contents", &contents), let contents,
                  let text = String(data: streams(contents), encoding: .isoLatin1) else { return false }
            return text.range(of: #"(^|\s)3 Tr\b"#, options: .regularExpression) != nil
        }
        return invisible.count * 2 > pages.count
    }

    /// Top-level sections open (showing their subsections), everything deeper closed, whatever
    /// the PDF's bookmarks say (hyperref and Word often mark them all open). (The appendix is
    /// collapsed afterwards.)
    private static func expandTopLevel(_ items: [Item]) -> [Item] {
        func close(_ item: Item) -> Item {
            var item = item
            item.isOpen = false
            item.children = item.children.map(close)
            return item
        }
        return items.map { item in
            var item = item
            item.isOpen = true
            item.children = item.children.map(close)
            return item
        }
    }

    // MARK: Appendix

    /// Long appendices would crowd out the paper: everything from the first appendix entry on
    /// ("A Data Appendix", "Appendix A. Supplementary data", "Supplementary Material") goes into
    /// one collapsed "Appendix" entry. References before it stay with the paper. LaTeX's
    /// \appendix doesn't say "appendix" but numbers sections with letters: the first section
    /// labelled "A" after numbered ones starts it too.
    private static func groupAppendix(_ items: [Item], _ document: PDFDocument) -> [Item] {
        let named = items.firstIndex { isAppendixLabel($0.label) }
        var lettered: Int?
        var numberedBefore = 0
        for (index, item) in items.enumerated() {
            guard let label = item.number?.split(separator: ".").first.map(String.init) else { continue }
            if label.allSatisfy(\.isNumber) || (label.count > 1 && label.allSatisfy({ "IVXL".contains($0) })) {
                numberedBefore += 1
            } else if label == "A", numberedBefore >= 2 {
                lettered = index
                break
            }
        }
        guard let start = [named, lettered].compactMap({ $0 }).min() else { return items }
        let main = Array(items[..<start])
        var tail = Array(items[start...]).map(collapsed)
        if tail.count == 1 {
            report.append("appendix: 1 entry, collapsed")
            return main + tail
        }
        // The paper's own heading ("VI. Appendix", with "A. Appendix 1" … after it) holds the rest.
        if tail[0].children.isEmpty, ["appendix", "appendices", "anhang"].contains(normalized(tail[0].label)) {
            var group = tail.removeFirst()
            group.children = tail
            report.append("appendix: \(tail.count) entries under \"\(group.label)\"")
            return main + [group]
        }
        report.append("appendix: \(tail.count) entries grouped")
        let group = Item(label: "Appendix", pageIndex: tail[0].pageIndex, y: tail[0].y, isOpen: false, children: tail)
        return main + [group]
    }

    // MARK: Section numbers

    /// Splits each entry's number from its title ("3.1 Exports" → "3.1", "Exports"). For the PDF's
    /// bookmarks (`document`; nil for headings found in the text) the number printed in front of
    /// the heading on the page wins: bookmarks may leave numbers out (hyperref's default) or
    /// number differently ("I.i" for a printed "I.A.").
    private static func numbered(_ items: [Item], _ document: PDFDocument?) -> [Item] {
        var splits = items.map { splitNumber($0.label) }
        // A bare letter or Roman numeral ("A Simple Model", "I Introduction") is a number only
        // among siblings numbered the same way, or above subsections "A.1" ….
        let bareCount = splits.filter(\.bare).count
        for index in splits.indices where splits[index].bare {
            let number = splits[index].number ?? ""
            let firstChild = items[index].children.first.map { splitNumber($0.label).number ?? "" } ?? ""
            if bareCount < 2 && !firstChild.hasPrefix(number + ".") {
                splits[index] = (nil, items[index].label, false)
            }
        }
        return items.indices.map { index in
            var item = items[index]
            item.number = splits[index].number
            item.label = splits[index].title
            if let document, let printed = numberOnPage(item, document) {
                // Only the same section numbered differently ("I.i" printed "I.A"), never another one.
                let parts = item.number?.split(separator: ".") ?? []
                let printedParts = printed.split(separator: ".")
                if parts.isEmpty || (parts.count == printedParts.count && parts.dropLast() == printedParts.dropLast()) {
                    item.number = printed
                }
            }
            item.children = numbered(item.children, document)
            return item
        }
    }

    private static func splitNumber(_ label: String) -> (number: String?, title: String, bare: Bool) {
        // ("Appendix A. Supplementary data" keeps its words.)
        guard let match = matches(numbered, label), match.range(at: 1).location == 0 else { return (nil, label, false) }
        let ns = label as NSString
        let number = ns.substring(with: match.range(at: 1))
        let bare = number.count == 1 && number.first!.isLetter && match.range(at: 2).length == 0
        return (number, ns.substring(with: match.range(at: 3)), bare)
    }

    private static let labelOnly = try? NSRegularExpression(pattern: "^(" + label + #")[.:]?$"#)

    /// The number printed in front of the heading the bookmark points to: a line reading
    /// "3.2 Aid" (or the start of a heading wrapped over two lines), nearest to the target, or
    /// at the top of the next page when the target sits at the bottom of a page.
    private static func numberOnPage(_ item: Item, _ document: PDFDocument) -> String? {
        guard let index = item.pageIndex else { return nil }
        func plain(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
                .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
        }
        let title = plain(item.label)
        guard let firstWord = title.split(separator: " ").first else { return nil }
        // (The next page only when the target is near the bottom of its page.)
        let nearBottom = document.page(at: index).map { item.y < $0.bounds(for: .mediaBox).height * 0.15 } ?? false
        for pageIndex in nearBottom ? [index, index + 1] : [index] {
            guard let page = document.page(at: pageIndex), let text = page.string else { continue }
            var best: (number: String, distance: CGFloat)?
            for line in text.components(separatedBy: .newlines) {
                var flat = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                // "Appendix A. Leader data": the label after the word.
                if let word = flat.split(separator: " ").first, ["appendix", "anhang"].contains(word.lowercased()) {
                    flat = String(flat.dropFirst(word.count + 1))
                }
                guard let space = flat.firstIndex(of: " ") else { continue }
                let prefix = String(flat[..<space])
                let rest = plain(String(flat[flat.index(after: space)...]))
                guard rest.hasPrefix(firstWord), rest == title || (rest.count >= 12 && title.hasPrefix(rest)),
                      let match = matches(labelOnly, prefix) else { continue }
                let found = page.selection(for: (text as NSString).range(of: line))?.bounds(for: page)
                let top = pageIndex == index ? item.y : page.bounds(for: .mediaBox).maxY
                if pageIndex != index, let found, found.maxY < page.bounds(for: .mediaBox).height * 0.7 { continue }
                let distance = found.map { abs($0.maxY - top) } ?? .greatestFiniteMagnitude
                if best == nil || distance < best!.distance {
                    best = ((prefix as NSString).substring(with: match.range(at: 1)), distance)
                }
            }
            if let best { return best.number }
        }
        return nil
    }

    private static func collapsed(_ item: Item) -> Item {
        var item = item
        item.isOpen = false
        item.children = item.children.map(collapsed)
        return item
    }

    private static func isAppendixLabel(_ label: String) -> Bool {
        let text = label.lowercased()
        return text.contains("appendix") || text.contains("appendices") || text.contains("anhang")
            || normalized(label).hasPrefix("supplementary")
    }

    // MARK: The PDF's own outline

    /// The PDF's outline, or nil if it has none worth showing.
    private static func pdfOutline(_ document: PDFDocument) -> [Item]? {
        guard let root = document.outlineRoot, root.numberOfChildren > 0 else { return nil }
        func resolve(_ item: PDFOutline) -> (pageIndex: Int?, y: CGFloat) {
            let destination = item.destination ?? (item.action as? PDFActionGoTo)?.destination
            guard let destination, let page = destination.page else { return (nil, 0) }
            let index = document.index(for: page)
            guard index != NSNotFound else { return (nil, 0) }
            let top = page.bounds(for: .mediaBox).maxY
            let py = destination.point.y
            return (index, (py > top || py < -100_000) ? top : py)
        }
        func walk(_ parent: PDFOutline, depth: Int) -> [Item] {
            (0..<parent.numberOfChildren).compactMap { parent.child(at: $0) }.map { item in
                let text = (item.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let target = resolve(item)
                return Item(label: text.isEmpty ? "Untitled" : text, pageIndex: target.pageIndex, y: target.y,
                            isOpen: depth == 0 || item.isOpen, children: walk(item, depth: depth + 1))
            }
        }
        // JSTOR adds bookmarks that aren't sections: one per page ("p. 191") and the issue's
        // other articles, which point to web links rather than pages of this file.
        func prune(_ items: [Item]) -> [Item] {
            items.compactMap { item in
                var item = item
                item.children = prune(item.children)
                guard item.children.isEmpty else { return item }
                if item.pageIndex == nil || isPageNumber(item.label) { return nil }
                return item
            }
        }
        let all = walk(root, depth: 0)
        let items = relocateShared(prune(all), document)
        if items.isEmpty {
            report.append("PDF outline has no sections (page numbers, links elsewhere)")
            return nil
        }
        // Merged PDFs sometimes list their parts by file name ("deckblatt.pdf", "paper_final.pdf").
        let fileName = #"(?i)\.(pdf|docx?|tex|dvi|ps)$"#
        if items.allSatisfy({ $0.children.isEmpty && $0.label.range(of: fileName, options: .regularExpression) != nil }) {
            report.append("PDF outline only lists file names")
            return nil
        }
        // PowerPoint's export names every bookmark after the slide ("Slide 2", "Slide 1: Title").
        if items.allSatisfy({ $0.children.isEmpty && $0.label.range(of: #"(?i)^(slide|folie)\s+\d+\b"#, options: .regularExpression) != nil }) {
            report.append("PDF outline only lists slide numbers")
            return nil
        }
        return items
    }

    /// Some PDFs (Elsevier) point all bookmarks from the conclusion on – acknowledgements,
    /// appendices, references – at one spot. Bookmarks sharing their target with two or more
    /// others are looked up by their title in the text instead, in reading order after the
    /// bookmark before them ("Leader data" → "Appendix A. Leader data" on a later page). One not
    /// found keeps its target, unless it repeats a title already placed (a second
    /// "Acknowledgements"): then it is dropped.
    private static func relocateShared(_ items: [Item], _ document: PDFDocument) -> [Item] {
        func key(_ item: Item) -> String { "\(item.pageIndex ?? -1):\(Int(item.y.rounded()))" }
        var counts: [String: Int] = [:]
        func count(_ items: [Item]) { for item in items { counts[key(item), default: 0] += 1; count(item.children) } }
        count(items)
        guard counts.values.contains(where: { $0 >= 3 }) else { return items }
        func squeeze(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: "’", with: "'").filter { !$0.isWhitespace }
        }
        // Where reading has got to: the last bookmark placed (page, offset in its text – the text's
        // order follows the columns, unlike heights on the page).
        var position = (page: 0, offset: -1)
        var placed = Set<String>()
        func find(_ label: String) -> (page: Int, y: CGFloat, offset: Int)? {
            let title = squeeze(label)
            guard title.count >= 3 else { return nil }
            for index in position.page..<document.pageCount {
                guard let page = document.page(at: index), let text = page.string as NSString? else { continue }
                var found: (page: Int, y: CGFloat, offset: Int)?
                text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { line, range, _, stop in
                    guard let line else { return }
                    let flat = squeeze(line)
                    // The title alone, or after its number ("5.", "Appendix A.").
                    guard flat.hasSuffix(title), flat.count <= title.count + 14,
                          String(flat.dropLast(title.count)).range(of: #"^(?:appendix|anhang)?[a-z0-9.]*$"#, options: .regularExpression) != nil,
                          index > position.page || range.location > position.offset,
                          let top = page.selection(for: range)?.bounds(for: page).maxY else { return }
                    found = (index, top, range.location)
                    stop.pointee = true
                }
                if let found { return found }
            }
            return nil
        }
        func relocate(_ items: [Item]) -> [Item] {
            items.compactMap { item in
                var item = item
                let title = squeeze(item.label)
                if (counts[key(item)] ?? 0) >= 3 {
                    if let found = find(item.label) {
                        item.pageIndex = found.page
                        item.y = found.y
                        position = (found.page, found.offset)
                    } else if placed.contains(title), item.children.isEmpty {
                        return nil
                    }
                } else if let page = item.pageIndex, page != position.page {
                    position = (page, -1)
                }
                placed.insert(title)
                item.children = relocate(item.children)
                return item
            }
        }
        report.append("outline: bookmarks sharing one target looked up in the text")
        return relocate(items)
    }

    /// Front and back matter that isn't a section of the paper.
    private static func isNotASection(_ label: String) -> Bool {
        let text = label.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        return text == "abstract" || text.hasPrefix("author's address") || text.hasPrefix("authors' address")
            || text.hasPrefix("author address")
    }

    /// "p. 191", "Page 3", "S. 12", "iv".
    private static func isPageNumber(_ label: String) -> Bool {
        label.range(of: #"(?i)^(?:p\.|pp\.|page|seite|s\.)?\s*(?:\d+|[ivxlc]+)$"#, options: .regularExpression) != nil
    }

        private static func isStray(_ label: String) -> Bool {
        let lower = label.lowercased()
        return lower.contains("http://") || lower.contains("https://") || lower.contains("www.")
    }

    // MARK: Headings in the text

    private struct Line {
        var text: String
        let pageIndex: Int
        let top: CGFloat
        let bottom: CGFloat
        let minX: CGFloat
        let size: CGFloat
        let fontName: String
        let bold: Bool
        let italic: Bool
        /// One font (name and size, small capitals allowed) from start to end.
        let uniform: Bool
        let inReferenceList: Bool

        var allCaps: Bool {
            let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            return letters.count >= 4 && text == text.uppercased()
        }
        /// Bold, larger than the body text, or in capitals.
        /// (4% larger is enough: ISQ sets section headings at 9.96 pt in 9.46 pt text, and PDFKit
        /// may not report bold.)
        func emphasized(body: CGFloat) -> Bool { bold || size >= body * 1.04 || allCaps }
        var style: String { "\(fontName)|\((size * 2).rounded() / 2)|\(allCaps)" }
    }

    private struct Heading {
        var line: Line
        var title: String
        var label: [String]       // "II.A" → ["II", "A"]; empty when unnumbered
        /// A letter without a dot ("A Data Appendix"), which might just be the word "A".
        var bare = false
        var level = 0
    }

    private static let sectionWords: Set<String> = [
        "introduction", "conclusion", "conclusions", "concluding remarks", "summary", "discussion",
        "results", "data", "methods", "methodology", "materials and methods", "background",
        "literature review", "related literature", "model", "appendix", "references", "bibliography",
        "acknowledgments", "acknowledgements", "notes", "einleitung", "fazit",
        "zusammenfassung", "literatur", "literaturverzeichnis", "anhang"]

    private static let label = #"(?:[IVX]{1,6}(?:\.[A-Z]|\.[ivx]{1,4})?(?:\.\d{1,2}){0,2}|\d{1,2}(?:\.\d{1,2}){0,3}|[A-Z](?:\.\d{1,2}){0,3})"#
    private static let numbered = try? NSRegularExpression(
        pattern: #"^(?:(?:Appendix|APPENDIX|Anhang|ANHANG|Chapter|CHAPTER|Kapitel|KAPITEL)\s+)?("# + label + #")(\.|:)?\s+(\p{Lu}.*)$"#)
    /// Panel titles under a figure: "A. RMB volumes B. Number of loans".
    private static let secondLetter = try? NSRegularExpression(pattern: #"\s[B-H]\.\s+\p{Lu}"#)
    private static let caption = try? NSRegularExpression(
        pattern: #"^(?i:table|tables|tab\.|figure|figures|fig\.|graph|chart|exhibit|panel|note|notes|source|sources|abbildung|tabelle)\s*[:.]?\s*(?:[A-Z]?\.?\d|[IVX]+\b|[A-Z]\b)"#)

    private static func detectHeadings(_ document: PDFDocument) -> [Heading] {
        let body = bodySize(document)
        guard body > 0 else { return [] }
        let lines = textLines(document, bodySize: body)
        guard !lines.isEmpty else { return [] }

        // Running headers and footers repeat on many pages ("44 ALBERTO ALESINA AND DAVID DOLLAR").
        var pagesWithText: [String: Set<Int>] = [:]
        func runningKey(_ text: String) -> String {
            text.split(separator: " ").filter { Int($0) == nil }.joined(separator: " ").lowercased()
        }
        for line in lines { pagesWithText[runningKey(line.text), default: []].insert(line.pageIndex) }

        var candidates: [Heading] = []
        for line in joinWrappedHeadings(lines, body: body) {
            let text = line.text
            let words = text.split(separator: " ")
            guard line.uniform, !line.inReferenceList || isReferencesHeading(text),
                  line.size >= body * 0.95, text.count <= 140, words.count <= 18,
                  (pagesWithText[runningKey(text)]?.count ?? 0) < 3,
                  let first = text.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) || CharacterSet.decimalDigits.contains(first),
                  !text.hasSuffix(","), !text.hasSuffix(";"), !text.hasSuffix("-"),
                  !text.contains("@"), !text.contains("http"), !text.contains("="),
                  matches(caption, text) == nil else { continue }
            let digits = text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
            guard digits * 4 < text.count else { continue }      // numbers in a table

            if let match = matches(numbered, text) {
                let ns = text as NSString
                let key = ns.substring(with: match.range(at: 1))
                let title = ns.substring(with: match.range(at: 3))
                if title.hasSuffix(".") && title.split(separator: " ").count > 6 { continue }   // a sentence
                if key.count == 1, key.first!.isLetter, matches(secondLetter, title) != nil { continue }
                // Numbered and emphasized, or numbered in italics ("A. Data"), or a subsection
                // label with a letter ("II.A. Data", checked against its parent below).
                let parts = key.split(separator: ".").map(String.init)
                let lettered = parts.count > 1 && parts.contains { $0.first?.isLetter == true }
                guard line.emphasized(body: body) || line.italic || lettered else { continue }
                let bare = parts.count == 1 && key.first!.isLetter && match.range(at: 2).length == 0
                candidates.append(Heading(line: line, title: text, label: parts, bare: bare))
            } else {
                if text.hasSuffix(".") && words.count > 6 { continue }
                guard line.emphasized(body: body) else { continue }
                candidates.append(Heading(line: line, title: text, label: []))
            }
        }

        let numberedHeadings = acceptNumbered(candidates.filter { !$0.label.isEmpty }, lines: lines, body: body)
        let result = numberedHeadings.count >= 2
            ? addUnnumbered(to: numberedHeadings, candidates.filter { $0.label.isEmpty })
            : unnumberedOutline(candidates.filter { $0.label.isEmpty }, body: body)
        return result.filter { !isNotASection($0.title) }.map { heading in
            var heading = heading
            heading.title = displayTitle(heading.title.hasSuffix(":") ? String(heading.title.dropLast()) : heading.title)
            return heading
        }
    }

    // MARK: Numbered headings

    private enum Kind { case roman, letter, arabic }

    private static func romanValue(_ text: String) -> Int? {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50]
        var total = 0, previous = 0
        for character in text.reversed() {
            guard let value = values[character] else { return nil }
            total += value < previous ? -value : value
            previous = max(previous, value)
        }
        return total
    }

    /// Keeps numbered headings whose numbers make sense in order: subsections under their
    /// section (3.1 after 3, II.A after II), numbers rising without big jumps.
    private static func acceptNumbered(_ candidates: [Heading], lines: [Line], body: CGFloat) -> [Heading] {
        // "I", "V", "X" alone are Roman numerals if the document uses longer ones too.
        let usesRoman = candidates.contains { $0.label[0].count > 1 && romanValue($0.label[0]) != nil }
        func kind(_ part: String) -> Kind {
            if part.allSatisfy(\.isNumber) { return .arabic }
            if romanValue(part) != nil && (part.count > 1 || usesRoman) { return .roman }
            return .letter
        }
        func value(_ part: String) -> Int {
            switch kind(part) {
            case .arabic: return Int(part) ?? 0
            case .roman: return romanValue(part) ?? 0
            case .letter: return Int(part.unicodeScalars.first!.value) - 64
            }
        }
        // Appendices after the reference list ("A Data Appendix", "B.2 Robustness") are top level.
        let referencesStart = lines.first { isReferencesHeading($0.text) && $0.inReferenceList }
        func isAppendix(_ heading: Heading) -> Bool {
            if heading.title.lowercased().hasPrefix("appendix") { return true }
            guard let start = referencesStart, kind(heading.label[0]) == .letter else { return false }
            return heading.line.pageIndex > start.pageIndex
                || (heading.line.pageIndex == start.pageIndex && heading.line.top < start.top)
        }

        // Nesting of single labels by first appearance: I. → A. → 1. (Word documents).
        var kindOrder: [Kind] = []
        for heading in candidates where heading.label.count == 1 && !heading.bare && !isAppendix(heading) {
            let k = kind(heading.label[0])
            if !kindOrder.contains(k) { kindOrder.append(k) }
        }
        var accepted: [Heading] = []
        // The last accepted heading's label at each level, and the last number seen there.
        var path: [[String]] = []
        var lastValue: [Int] = []
        var lastKind: [Kind] = []
        for var heading in candidates {
            let parts = heading.label
            // "A Service of …": a bare letter is a label only in an appendix heading.
            if heading.bare && !heading.title.lowercased().contains("appendix") && !isAppendix(heading) { continue }
            let base = isAppendix(heading) ? 0 : (kindOrder.firstIndex(of: kind(parts[0])) ?? kindOrder.count)
            let level = base + parts.count - 1
            guard level <= path.count, level < 4 else { continue }       // no skipped level
            if parts.count > 1 {
                // 3.1 belongs under 3, II.A under II.
                guard level >= 1, path[level - 1] == Array(parts.dropLast()) else { continue }
            } else if level > 0 {
                guard heading.line.emphasized(body: body) || heading.line.italic else { continue }
            }
            let number = value(parts.last!)
            // (Appendix A after section 9 starts again.)
            let previous = level < lastValue.count && lastKind[level] == kind(parts.last!) ? lastValue[level] : 0
            // Numbers rise (allowing a repeat, a typo in some papers) without big jumps.
            guard number >= previous, number <= previous + 3 else { continue }
            if parts.count == 1 && level == 0 && !heading.line.emphasized(body: body) { continue }
            heading.level = level
            accepted.append(heading)
            path = Array(path.prefix(level)) + [parts]
            lastValue = Array(lastValue.prefix(level)) + [number]
            lastKind = Array(lastKind.prefix(level)) + [kind(parts.last!)]
        }
        // A single top-level number is too little to go on (a numbered list in bold).
        let topLevel = accepted.filter { $0.level == 0 }.count
        return topLevel >= 2 ? accepted : []
    }

    /// Unnumbered headings in a numbered document: known words ("References", "Abstract",
    /// "Data Appendix") in the style of a numbered heading.
    private static func addUnnumbered(to headings: [Heading], _ candidates: [Heading]) -> [Heading] {
        var levelOfStyle: [String: Int] = [:]
        for heading in headings where levelOfStyle[heading.line.style] == nil {
            levelOfStyle[heading.line.style] = heading.level
        }
        guard let first = headings.first else { return headings }
        var result = headings
        for candidate in candidates {
            guard levelOfStyle[candidate.line.style] != nil else { continue }
            let afterFirst = candidate.line.pageIndex > first.line.pageIndex
                || (candidate.line.pageIndex == first.line.pageIndex && candidate.line.top < first.line.top)
            let title = normalized(candidate.title)
            let known = sectionWords.contains(title)
            guard known || (afterFirst && (title.contains("appendix") || title.hasPrefix("supplementary"))) else { continue }
            var heading = candidate
            heading.level = 0
            result.append(heading)
        }
        return result.sorted { a, b in
            a.line.pageIndex != b.line.pageIndex ? a.line.pageIndex < b.line.pageIndex : a.line.top > b.line.top
        }
    }

    // MARK: Unnumbered headings

    /// Without numbers: the style used for "Introduction", "Results", "Conclusion" … is the top
    /// level; less prominent heading styles between those headings are the levels below.
    private static func unnumberedOutline(_ candidates: [Heading], body: CGFloat) -> [Heading] {
        var byStyle: [String: [Heading]] = [:]
        for candidate in candidates { byStyle[candidate.line.style, default: []].append(candidate) }
        let known = { (headings: [Heading]) in headings.filter { sectionWords.contains(normalized($0.title)) }.count }
        guard let anchor = byStyle.filter({ known($0.value) >= 2 }).max(by: { known($0.value) < known($1.value) }),
              let sample = anchor.value.first?.line else { return [] }
        func prominence(_ line: Line) -> (CGFloat, Int, Int) {
            ((line.size * 2).rounded() / 2, line.bold ? 1 : 0, line.allCaps ? 1 : 0)
        }
        func isLess(_ a: Line, _ b: Line) -> Bool { prominence(a) < prominence(b) }

        let top = anchor.value
        guard let firstTop = top.first?.line else { return [] }
        let end = top.first { $0.line.inReferenceList || isReferencesHeading($0.title) }?.line
        func inside(_ line: Line) -> Bool {
            let afterStart = line.pageIndex > firstTop.pageIndex || (line.pageIndex == firstTop.pageIndex && line.top < firstTop.top)
            guard let end else { return afterStart }
            let beforeEnd = line.pageIndex < end.pageIndex || (line.pageIndex == end.pageIndex && line.top > end.top)
            return afterStart && beforeEnd
        }
        var result = top.map { heading -> Heading in var heading = heading; heading.level = 0; return heading }
        // More prominent than the section headings: only known words ("Abstract"), not the title.
        for (style, headings) in byStyle where style != anchor.key && isLess(sample, headings[0].line) {
            for heading in headings where sectionWords.contains(normalized(heading.title)) {
                var heading = heading
                heading.level = 0
                result.append(heading)
            }
        }
        // Less prominent styles, in order: levels 1 and 2.
        let lower = byStyle.filter { $0.key != anchor.key && isLess($0.value[0].line, sample) }
            .map { $0.value.filter { inside($0.line) } }
            .filter { $0.count >= 2 && $0[0].line.size >= body * 0.95 && ($0[0].line.bold || $0[0].line.size >= body * 1.08) }
            .sorted { isLess($1[0].line, $0[0].line) }
        for (index, headings) in lower.prefix(2).enumerated() {
            for heading in headings {
                var heading = heading
                heading.level = index + 1
                result.append(heading)
            }
        }
        return result.sorted { a, b in
            a.line.pageIndex != b.line.pageIndex ? a.line.pageIndex < b.line.pageIndex : a.line.top > b.line.top
        }
    }

    // MARK: Lines

    private static func textLines(_ document: PDFDocument, bodySize: CGFloat) -> [Line] {
        var lines: [Line] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let attributed = page.attributedString else { continue }
            let text = attributed.string as NSString
            var location = 0
            while location < text.length {
                let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(lineRange)
                var range = lineRange
                // Trim whitespace and line breaks at both ends.
                while range.length > 0, let scalar = UnicodeScalar(text.character(at: range.location)),
                      CharacterSet.whitespacesAndNewlines.contains(scalar) { range.location += 1; range.length -= 1 }
                while range.length > 0, let scalar = UnicodeScalar(text.character(at: NSMaxRange(range) - 1)),
                      CharacterSet.whitespacesAndNewlines.contains(scalar) { range.length -= 1 }
                guard range.length >= 2, range.length <= 160 else { continue }

                var runs: [(font: NSFont, range: NSRange)] = []
                attributed.enumerateAttribute(.font, in: range) { value, run, _ in
                    guard let font = value as? NSFont else { return }
                    let piece = text.substring(with: run).trimmingCharacters(in: .whitespaces)
                    if !piece.isEmpty { runs.append((font, run)) }
                }
                guard let main = runs.map(\.font).max(by: { $0.pointSize < $1.pointSize }) else { continue }
                // A footnote mark at the end ("Introduction¹", "Data∗") isn't part of the heading.
                let marks = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: "∗*†‡§,"))
                while runs.count > 1, let last = runs.last, last.font.pointSize < main.pointSize * 0.8,
                      text.substring(with: last.range).unicodeScalars.allSatisfy({ marks.contains($0) || CharacterSet.whitespaces.contains($0) }) {
                    runs.removeLast()
                    range.length = last.range.location - range.location
                }
                guard let bounds = page.selection(for: range)?.bounds(for: page), bounds.height > 0 else { continue }
                // One font, allowing small capitals ("I. INTRODUCTION" in two sizes) and a smaller
                // remark at body size ("A Data Appendix (FOR ONLINE PUBLICATION)").
                let body = bodySize
                let uniform = runs.allSatisfy {
                    $0.font.fontName == main.fontName && $0.font.pointSize >= min(main.pointSize * 0.7, body * 0.95)
                }
                let name = main.fontName.lowercased()
                let traits = main.fontDescriptor.symbolicTraits
                let bold = traits.contains(.bold) || ["bold", "semibold", "demi", "heavy", "black", "-bd", ".b"].contains { name.contains($0) }
                let italic = traits.contains(.italic) || name.contains("italic") || name.contains("oblique") || name.hasSuffix("-it")
                let string = text.substring(with: range).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                lines.append(Line(text: string, pageIndex: index, top: bounds.maxY, bottom: bounds.minY, minX: bounds.minX,
                                  size: main.pointSize, fontName: main.fontName, bold: bold, italic: italic,
                                  uniform: uniform,
                                  inReferenceList: ReferenceDetector.isInReferenceList(page, y: bounds.midY)))
            }
        }
        return lines
    }

    /// A heading broken over two lines ("Related research on the competitive advantage of
    /// Chinese agricultural / exports") becomes one line.
    private static func joinWrappedHeadings(_ lines: [Line], body: CGFloat) -> [Line] {
        var result: [Line] = []
        for line in lines {
            if var previous = result.last, previous.pageIndex == line.pageIndex, previous.style == line.style,
               previous.uniform, line.uniform, previous.emphasized(body: body),
               previous.bottom - line.top < line.size * 0.8, previous.bottom > line.bottom,
               previous.text.count + line.text.count < 140,
               matches(numbered, line.text) == nil, let first = line.text.first, !first.isNumber {
                previous.text += previous.text.hasSuffix("-") ? line.text : " " + line.text
                result[result.count - 1] = Line(text: previous.text, pageIndex: previous.pageIndex, top: previous.top,
                                                bottom: line.bottom, minX: previous.minX, size: previous.size,
                                                fontName: previous.fontName, bold: previous.bold, italic: previous.italic,
                                                uniform: true, inReferenceList: previous.inReferenceList)
                continue
            }
            result.append(line)
        }
        return result
    }

    private static func bodySize(_ document: PDFDocument) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        for index in 0..<document.pageCount {
            guard let attributed = document.page(at: index)?.attributedString else { continue }
            attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                guard let font = value as? NSFont else { return }
                counts[(font.pointSize * 2).rounded() / 2, default: 0] += range.length
            }
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? 0
    }

    // MARK: Helpers

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> NSTextCheckingResult? {
        regex?.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    /// "5. CONCLUSION:" → "conclusion".
    private static func normalized(_ title: String) -> String {
        var text = title.lowercased()
        if let match = matches(numbered, title) { text = (title as NSString).substring(with: match.range(at: 3)).lowercased() }
        return text.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
    }

    private static func isReferencesHeading(_ text: String) -> Bool {
        ["references", "bibliography", "literature cited", "works cited", "literatur", "literaturverzeichnis"]
            .contains(normalized(text))
    }

    /// Headings set in capitals read better in the sidebar in title case:
    /// "II. DATA AND TIMELINE" → "II. Data and Timeline" (labels and "U.S." stay as they are).
    private static func displayTitle(_ text: String) -> String {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 4, text == text.uppercased() else { return text }
        let small: Set<String> = ["a", "an", "and", "as", "at", "by", "for", "from", "in", "of", "on", "or", "the", "to", "vs", "with"]
        var labelDone = matches(numbered, text) == nil
        return text.split(separator: " ").enumerated().map { index, word in
            let token = String(word)
            if !labelDone { labelDone = true; return token }        // "II." or "A."
            if token.contains(".") || token.contains(where: \.isNumber) { return token }
            let lower = token.lowercased()
            if index > 1 && small.contains(lower) { return lower }
            if token.count == 2 && !["is", "be", "do", "no", "up", "we", "it", "so", "if", "my"].contains(lower) && index > 0 {
                return token                                         // "HS", "EU", "UK"
            }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    /// Nests headings by level: each one under the last heading above its level.
    private static func tree(_ headings: [Heading]) -> [Item] {
        var roots: [Item] = []
        var stack: [(level: Int, path: [Int])] = []      // path of indices into roots/children
        func append(_ item: Item, at path: [Int]) -> [Int] {
            if path.isEmpty { roots.append(item); return [roots.count - 1] }
            func insert(_ items: inout [Item], _ rest: ArraySlice<Int>) -> Int {
                if rest.isEmpty { items.append(item); return items.count - 1 }
                return insert(&items[rest.first!].children, rest.dropFirst())
            }
            return path + [insert(&roots, path[...])]
        }
        for heading in headings {
            while let last = stack.last, last.level >= heading.level { stack.removeLast() }
            let item = Item(label: heading.title, pageIndex: heading.line.pageIndex, y: heading.line.top,
                            isOpen: stack.isEmpty, children: [])
            let path = append(item, at: stack.last?.path ?? [])
            stack.append((heading.level, path))
        }
        return roots
    }
}
