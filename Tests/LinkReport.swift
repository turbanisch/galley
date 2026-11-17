import AppKit
import PDFKit

/// Writes, for each PDF in test-pdf/, a plain-text list of its links after Galley's processing:
/// the text under each link and the first line a preview of its target starts with. Used by
/// test.sh to spot wrong targets and regressions without hovering over every link in the app.
@main
struct LinkReport {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        guard arguments.count >= 2 else {
            print("usage: linkreport <output folder> <file.pdf>…")
            exit(1)
        }
        let output = URL(fileURLWithPath: arguments.first!)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for path in arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data) else {
                print("  could not open \(url.lastPathComponent)")
                continue
            }
            DestinationFixer.fix(document, data: data)
            ReferenceDetector.addLinks(to: document)
            var lines = ["# \(url.lastPathComponent)", "# " + DestinationFixer.report]
            lines += ReferenceDetector.report.map { "# " + $0 }
            let outline = OutlineDetector.outline(for: document)
            lines += OutlineDetector.report.map { "# " + $0 }
            lines += outlineReport(outline, document)
            lines += jumpReport(document)
            lines += report(document)
            let name = url.deletingPathExtension().lastPathComponent + ".txt"
            try? lines.joined(separator: "\n").appending("\n").write(to: output.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    static func report(_ document: PDFDocument) -> [String] {
        var lines: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let links = page.annotations
                .filter { $0.type == "Link" && ReferenceDetector.isUsableLink($0) }
                .sorted { abs($0.bounds.midY - $1.bounds.midY) > 3 ? $0.bounds.midY > $1.bounds.midY : $0.bounds.minX < $1.bounds.minX }
            for link in links {
                let source = clean(page.selection(for: link.bounds)?.string)
                let origin = (ReferenceDetector.origins.object(forKey: link) as String?) ?? "pdf"
                if let action = link.action as? PDFActionURL {
                    lines.append("p\(index + 1) [\(origin)] \"\(source)\" → \(action.url?.absoluteString ?? "?")")
                    continue
                }
                guard let destination = link.destination ?? (link.action as? PDFActionGoTo)?.destination,
                      let target = destination.page else {
                    lines.append("p\(index + 1) [\(origin)] \"\(source)\" → (no target)")
                    continue
                }
                let targetIndex = document.index(for: target)
                lines.append("p\(index + 1) [\(origin)] \"\(source)\" → p\(targetIndex + 1) \"\(firstLine(at: destination, on: target))\"")
            }
        }
        return lines
    }

    /// Each outline entry, indented by level: `toc p3 "1 Introduction" → "+0 1 Introduction"`.
    @MainActor
    static func outlineReport(_ outline: OutlineDetector.Result, _ document: PDFDocument) -> [String] {
        var lines: [String] = []
        func walk(_ items: [OutlineDetector.Item], depth: Int) {
            for item in items {
                let indent = String(repeating: "  ", count: depth)
                let label = [item.number, item.label].compactMap { $0 }.joined(separator: " ")
                if let index = item.pageIndex, let page = document.page(at: index) {
                    let target = firstLine(at: PDFDestination(page: page, at: NSPoint(x: 0, y: item.y)), on: page)
                    lines.append("toc \(indent)p\(index + 1) \"\(clean(label))\" → \"\(target)\"")
                } else {
                    lines.append("toc \(indent)\"\(clean(label))\" → (no target)")
                }
                walk(item.children, depth: depth + 1)
            }
        }
        walk(outline.items, depth: 0)
        return lines
    }

    /// What the jump palette offers: figures, tables and slide titles one per line
    /// (`jump table "3" p12 → "+0 Table 3: Summary statistics"`), the rest as counts.
    @MainActor
    static func jumpReport(_ document: PDFDocument) -> [String] {
        var lines: [String] = []
        let targets = ReferenceDetector.jumpTargets(in: document)
        for target in targets where target.kind == .figure || target.kind == .table {
            let destination = PDFDestination(page: target.page, at: target.point)
            lines.append("jump \(target.kind) \"\(target.label ?? "")\" p\(document.index(for: target.page) + 1) → \"\(firstLine(at: destination, on: target.page))\"")
        }
        if OutlineDetector.isSlides(document) {
            for item in OutlineDetector.slideTitles(document) {
                lines.append("jump slide p\((item.pageIndex ?? 0) + 1) \"\(clean(item.label))\"")
            }
        }
        func pages(_ kind: ReferenceDetector.JumpTarget.Kind) -> String {
            let found = targets.filter { $0.kind == kind }
            return "\(found.count)" + (found.isEmpty ? "" : " (" + found.map { ($0.label ?? "") + "p\(document.index(for: $0.page) + 1)" }
                .joined(separator: " ") + ")")
        }
        lines.append("# jump: equations \(pages(.equation))")
        lines.append("# jump: notes \(pages(.note))")
        lines.append("# jump: references \(targets.filter { $0.kind == .reference }.count)")
        return lines
    }

    /// The text line at the target, and how far the target lies above that line's top
    /// ("+0" is exact; "+90" means a preview starts 90 points too high). Measured on the page as
    /// shown (a turned page turned upright).
    @MainActor
    static func firstLine(at destination: PDFDestination, on page: PDFPage) -> String {
        let shown = page.rotation == 0 ? .identity : page.transform(for: .mediaBox)
        let box = page.bounds(for: .mediaBox).applying(shown)
        let point = destination.point.y > page.bounds(for: .mediaBox).maxY ? destination.point : destination.point.applying(shown)
        guard point.y <= box.maxY else { return "(top of page)" }
        let y = point.y
        let band = NSRect(x: box.minX, y: y - 150, width: box.width, height: 154).applying(shown.inverted())
        guard let selection = page.selection(for: band) else { return "" }
        var best: (text: String?, top: CGFloat)?
        for line in selection.selectionsByLine() {
            let bounds: NSRect = line.bounds(for: page).applying(shown)
            // (Not the vertical "Downloaded from …" notes publishers print along the margin.)
            let isText: Bool = bounds.height > 0 && bounds.height < 30 && bounds.width > 40
            guard isText, bounds.maxY <= y + 4 else { continue }
            if best == nil || bounds.maxY > best!.top { best = (line.string, bounds.maxY) }
        }
        guard let best else { return "(nothing below)" }
        return "+\(Int((y - best.top).rounded())) " + clean(best.text)
    }

    static func clean(_ string: String?) -> String {
        let flat = (string ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
    }
}
