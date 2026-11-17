import CoreGraphics
import PDFKit

/// PDFKit drops the height of some link targets: "fit the page width at height y" (/FitH,
/// /FitBH) and "fit this rectangle" (/FitR) become "top of the page", so footnotes, sections and
/// citations in many publisher PDFs (Econometrica, PLOS) all land at the top of their page.
/// This reads the targets directly from the PDF with Core Graphics and gives the links their
/// real height back. Only the in-memory document is changed.
@MainActor
enum DestinationFixer {
    static var report = ""

    static func fix(_ document: PDFDocument, data: Data) {
        report = ""
        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider),
              let catalog = pdf.catalog else { return }

        // Page dictionaries → page index (destinations refer to pages by object).
        var pageIndex: [Int: Int] = [:]
        if pdf.numberOfPages > 0 {
            for number in 1...pdf.numberOfPages {
                if let dictionary = pdf.page(at: number)?.dictionary { pageIndex[key(dictionary)] = number - 1 }
            }
        }
        let names = NamedDestinations(catalog: catalog)

        var fixed = 0, checked = 0
        for number in 1...max(pdf.numberOfPages, 1) {
            guard number <= pdf.numberOfPages, let pageDictionary = pdf.page(at: number)?.dictionary,
                  let page = document.page(at: number - 1) else { continue }
            var annotations: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(pageDictionary, "Annots", &annotations), let annotations else { continue }
            let kitLinks = page.annotations.filter { $0.type == "Link" }
            guard !kitLinks.isEmpty else { continue }
            for i in 0..<CGPDFArrayGetCount(annotations) {
                var annotation: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annotations, i, &annotation), let annotation,
                      name(annotation, "Subtype") == "Link", let rect = rectangle(annotation, "Rect") else { continue }
                // The target: /Dest, or a GoTo action's /D; either an array or a name.
                var target: CGPDFObjectRef?
                if !CGPDFDictionaryGetObject(annotation, "Dest", &target) {
                    var action: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(annotation, "A", &action), let action, name(action, "S") == "GoTo" {
                        CGPDFDictionaryGetObject(action, "D", &target)
                    }
                }
                guard let target, let array = names.resolve(target),
                      let resolved = destination(array, pageIndex), let top = resolved.1,
                      let targetPage = document.page(at: resolved.0) else { continue }
                checked += 1
                // The matching PDFKit link: same rectangle.
                guard let kit = kitLinks.first(where: { abs($0.bounds.minX - rect.minX) < 1 && abs($0.bounds.minY - rect.minY) < 1
                    && abs($0.bounds.maxX - rect.maxX) < 1 && abs($0.bounds.maxY - rect.maxY) < 1 }) else { continue }
                let current = kit.destination ?? (kit.action as? PDFActionGoTo)?.destination
                if let current, current.page == targetPage, abs(current.point.y - top) < 2 { continue }
                let x = current.map { $0.point.x.isFinite && $0.point.x < 10_000 ? $0.point.x : 0 } ?? 0
                kit.action = nil
                kit.destination = PDFDestination(page: targetPage, at: NSPoint(x: x, y: top))
                ReferenceDetector.origins.setObject("pdf, height read" as NSString, forKey: kit)
                fixed += 1
            }
        }
        report = "destinations: \(checked) link targets read, \(fixed) corrected"
    }

    /// Page index and target height from a destination array [page /XYZ left top zoom],
    /// [page /FitH top], [page /FitBH top] or [page /FitR left bottom right top].
    private static func destination(_ array: CGPDFArrayRef, _ pageIndex: [Int: Int]) -> (Int, CGFloat?)? {
        var page: CGPDFDictionaryRef?
        guard CGPDFArrayGetDictionary(array, 0, &page), let page, let index = pageIndex[key(page)] else { return nil }
        var kindName: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(array, 1, &kindName), let kindName else { return (index, nil) }
        func number(_ i: Int) -> CGFloat? {
            var value: CGPDFReal = 0
            return CGPDFArrayGetNumber(array, i, &value) ? CGFloat(value) : nil
        }
        switch String(cString: kindName) {
        case "XYZ": return (index, number(3))
        case "FitH", "FitBH": return (index, number(2))
        case "FitR": return (index, number(5))
        default: return (index, nil)
        }
    }

    /// A dictionary's address, to recognize the same page object again.
    private static func key(_ dictionary: CGPDFDictionaryRef) -> Int {
        unsafeBitCast(dictionary, to: Int.self)
    }

    private static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }

    private static func rectangle(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGRect? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, key, &array), let array, CGPDFArrayGetCount(array) == 4 else { return nil }
        var values = [CGPDFReal](repeating: 0, count: 4)
        for i in 0..<4 { guard CGPDFArrayGetNumber(array, i, &values[i]) else { return nil } }
        return CGRect(x: min(values[0], values[2]), y: min(values[1], values[3]),
                      width: abs(values[2] - values[0]), height: abs(values[3] - values[1]))
    }
}

/// Named destinations: the old /Dests dictionary and the /Names → /Dests name tree.
@MainActor
private struct NamedDestinations {
    private var table: [String: CGPDFObjectRef] = [:]

    init(catalog: CGPDFDictionaryRef) {
        var dests: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Dests", &dests), let dests {
            var collected: [String: CGPDFObjectRef] = [:]
            CGPDFDictionaryApplyBlock(dests, { key, value, _ in
                collected[String(cString: key)] = value
                return true
            }, nil)
            table.merge(collected) { first, _ in first }
        }
        var namesDictionary: CGPDFDictionaryRef?, tree: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Names", &namesDictionary), let namesDictionary,
           CGPDFDictionaryGetDictionary(namesDictionary, "Dests", &tree), let tree {
            collect(tree, depth: 0)
        }
    }

    private mutating func collect(_ node: CGPDFDictionaryRef, depth: Int) {
        guard depth < 32 else { return }
        var names: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Names", &names), let names {
            let count = CGPDFArrayGetCount(names)
            var i = 0
            while i + 1 < count {
                var key: CGPDFStringRef?
                var value: CGPDFObjectRef?
                if CGPDFArrayGetString(names, i, &key), let key, let string = CGPDFStringCopyTextString(key) as String?,
                   CGPDFArrayGetObject(names, i + 1, &value), let value {
                    table[string] = value
                }
                i += 2
            }
        }
        var kids: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
            for i in 0..<CGPDFArrayGetCount(kids) {
                var kid: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(kids, i, &kid), let kid { collect(kid, depth: depth + 1) }
            }
        }
    }

    /// A destination as an array, following a name (string or name object) and a /D wrapper.
    func resolve(_ object: CGPDFObjectRef) -> CGPDFArrayRef? {
        var array: CGPDFArrayRef?
        if CGPDFObjectGetValue(object, .array, &array), let array { return array }
        var key: String?
        var string: CGPDFStringRef?
        var name: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .string, &string), let string { key = CGPDFStringCopyTextString(string) as String? }
        else if CGPDFObjectGetValue(object, .name, &name), let name { key = String(cString: name) }
        var dictionary: CGPDFDictionaryRef?
        if key == nil, CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary {
            var inner: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "D", &inner) { return inner }
        }
        guard let key, let value = table[key] else { return nil }
        if CGPDFObjectGetValue(value, .array, &array), let array { return array }
        if CGPDFObjectGetValue(value, .dictionary, &dictionary), let dictionary {
            var inner: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "D", &inner) { return inner }
        }
        return nil
    }
}
