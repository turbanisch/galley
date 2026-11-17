import AppKit
import CoreImage
import PDFKit

/// The colour pages are shown in (View menu, D or ⌘9). Applied while PDFKit draws each page
/// (`ThemedPage`), so text stays as sharp as in the original and only the screen changes – never
/// the file. Dark inverts brightness but keeps the hue (a red line stays red), with softer
/// contrast than black on white.
enum PageTheme: String, CaseIterable {
    case light, sepia, dark

    static let didChange = Notification.Name("GalleyPageThemeDidChange")
    private static let key = "GalleyPageTheme"

    /// Kept in a variable: PDFKit draws pages on background threads, many times a second.
    nonisolated(unsafe) private static var stored = UserDefaults.standard.string(forKey: key).flatMap(PageTheme.init) ?? .light

    static var current: PageTheme {
        get { stored }
        set {
            stored = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            var order = recent.filter { $0 != newValue }
            order.insert(newValue, at: 0)
            UserDefaults.standard.set(order.map(\.rawValue), forKey: orderKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    private static let orderKey = "GalleyPageThemeOrder"

    /// All themes, most recently used first (the current one first): the switcher's order, so
    /// one tap of D goes back to the previous colour.
    static var recent: [PageTheme] {
        let saved = (UserDefaults.standard.stringArray(forKey: orderKey) ?? []).compactMap(PageTheme.init)
        let order = [current] + saved + allCases
        return order.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    var title: String { rawValue.capitalized }

    var inverts: Bool { self == .dark }

    /// What a blank page looks like in this theme.
    var paperColor: CGColor {
        guard let paper = paperAndInk?.paper else { return CGColor(gray: 1, alpha: 1) }
        return CGColor(srgbRed: paper[0], green: paper[1], blue: paper[2], alpha: 1)
    }

    /// What black text looks like in this theme.
    var inkColor: CGColor {
        guard let ink = paperAndInk?.ink else { return CGColor(gray: 0, alpha: 1) }
        return CGColor(srgbRed: ink[0], green: ink[1], blue: ink[2], alpha: 1)
    }

    /// sRGB components of the paper (what white becomes) and of the ink (what black becomes).
    private var paperAndInk: (paper: [CGFloat], ink: [CGFloat])? {
        switch self {
        case .light: return nil
        case .sepia: return ([0.957, 0.925, 0.847], [0.23, 0.18, 0.13])   // #F4ECD8, dark brown
        case .dark: return ([0.118, 0.118, 0.118], [0.86, 0.86, 0.86])      // #1E1E1E, #DCDCDC
        }
    }

    /// Draws a page (`drawPage`) recoloured, with blend modes in a layer of its own: Sepia scales
    /// each channel between ink and paper; Dark inverts (difference with white), takes the hue
    /// back from the original (the page drawn again in hue mode), then scales between paper and ink.
    func draw(_ rect: CGRect, in context: CGContext, drawPage: () -> Void) {
        guard let (paper, ink) = paperAndInk else { drawPage(); return }
        // On a rotated page `rect` (unrotated) covers only part of it: fill generously, PDFKit
        // clips to the page.
        let area = rect.insetBy(dx: -max(rect.width, rect.height), dy: -max(rect.width, rect.height))
        func fill(_ components: [CGFloat], _ blend: CGBlendMode) {
            context.setBlendMode(blend)
            context.setFillColor(CGColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: 1))
            context.fill(area)
        }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        fill([1, 1, 1], .normal)
        drawPage()
        if inverts {
            fill([1, 1, 1], .difference)
            // In a layer of its own: on screen PDFKit draws some text (e.g. a running head) in a
            // way that ignores the blend mode, which painted it black over the inverted page:
            // only its outline was left.
            context.setBlendMode(.hue)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawPage()
            context.endTransparencyLayer()
            fill((0..<3).map { ink[$0] - paper[$0] }, .multiply)
            fill(paper, .plusLighter)
        } else {
            fill((0..<3).map { paper[$0] - ink[$0] }, .multiply)
            fill(ink, .plusLighter)
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// The same mapping as a colour matrix, for page images (thumbnails don't go through
    /// `ThemedPage`): converted to sRGB values, mapped, converted back. For Dark: invert,
    /// rotate the hue by 180° (which turns the inverted hue back), scale between paper and ink.
    private var filters: [CIFilter] {
        guard let (paper, ink) = paperAndInk, let matrix = CIFilter(name: "CIColorMatrix"),
              let toSRGB = CIFilter(name: "CILinearToSRGBToneCurve"),
              let toLinear = CIFilter(name: "CISRGBToneCurveToLinear") else { return [] }
        func vector(_ values: [CGFloat]) -> CIVector { CIVector(values: values, count: values.count) }
        var rows: [[CGFloat]]
        if inverts {
            let hueTurn: [[CGFloat]] = [[-0.574, 1.430, 0.144], [0.426, 0.430, 0.144], [0.426, 1.430, -0.856]]
            rows = (0..<3).map { i in hueTurn[i].map { -(ink[i] - paper[i]) * $0 } }
        } else {
            rows = (0..<3).map { i in (0..<3).map { $0 == i ? paper[i] - ink[i] : 0 } }
        }
        for (i, name) in ["inputRVector", "inputGVector", "inputBVector"].enumerated() {
            matrix.setValue(vector(rows[i] + [0]), forKey: name)
        }
        matrix.setValue(vector([0, 0, 0, 1]), forKey: "inputAVector")
        matrix.setValue(vector([ink[0], ink[1], ink[2], 0]), forKey: "inputBiasVector")
        return [toSRGB, matrix, toLinear]
    }

    /// A page image (thumbnail, cover while rendering) in the current colours.
    static func recolor(_ image: NSImage) -> NSImage {
        let theme = current
        guard theme != .light, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        var output = CIImage(cgImage: cg)
        for filter in theme.filters {
            filter.setValue(output, forKey: kCIInputImageKey)
            guard let result = filter.outputImage else { return image }
            output = result
        }
        guard let recolored = context.createCGImage(output, from: output.extent) else { return image }
        return NSImage(cgImage: recolored, size: image.size)
    }

    private static let context = CIContext()
}

/// A document whose pages draw themselves in the current page colour.
final class ThemedDocument: PDFDocument {
    override var pageClass: AnyClass { ThemedPage.self }
}

final class ThemedPage: PDFPage {
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        PageTheme.current.draw(bounds(for: box), in: context) { super.draw(with: box, to: context) }
    }
}

/// Until a page's tiles are drawn, PDFKit shows layers under them: a plain white one and a small
/// picture of the page – made without `ThemedPage`, so in the original colours (and it keeps
/// setting both back): a white flash at the edge of a page when paging through. A transparent
/// view on each page (`pageOverlayViewProvider`) keeps them in the page colour.
final class PagePaper: NSObject, PDFPageOverlayViewProvider {
    static let shared = PagePaper()

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? { PaperKeeper() }
}

private final class PaperKeeper: NSView {
    private var paperLayers: [(layer: CALayer, preview: PagePreview)] = []
    private var observations: [NSKeyValueObservation] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The page's own layers with a plain background colour (not the tiles, not this view).
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observations = []
        NotificationCenter.default.removeObserver(self)
        paperLayers = (superview?.layer?.sublayers ?? []).filter {
            $0 !== layer && $0.backgroundColor != nil && ($0.sublayers ?? []).isEmpty
        }.map { ($0, PagePreview()) }
        for (paper, preview) in paperLayers {
            Self.paint(paper)
            preview.update(paper)
            observations.append(paper.observe(\.backgroundColor) { paper, _ in Self.paint(paper) })
            observations.append(paper.observe(\.contents) { paper, _ in preview.update(paper) })
        }
        // The layer holding the markup layers (next to the selection's), watched for new ones.
        markupHolders = (superview?.layer?.sublayers ?? []).filter { holder in
            (holder.sublayers ?? []).contains { Self.isMarkup($0) || Self.isSelection($0) }
        }
        for holder in markupHolders {
            Self.styleMarkup(in: holder)
            observations.append(holder.observe(\.sublayers) { holder, _ in Self.styleMarkup(in: holder) })
        }
        // The selection's (and search results') rectangles, in a layer inside each selection effect.
        selectionHolders = markupHolders.flatMap { ($0.sublayers ?? []).filter(Self.isSelection) }.flatMap { $0.sublayers ?? [] }
        for holder in selectionHolders {
            Self.styleSelection(in: holder)
            observations.append(holder.observe(\.sublayers) { holder, _ in Self.styleSelection(in: holder) })
        }
        pageLayer = superview?.layer
        if let pageLayer {
            edge.update(pageLayer)
            observations.append(pageLayer.observe(\.borderColor) { [edge] page, _ in edge.update(page) })
        }
        guard pageLayer != nil else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: PageTheme.didChange, object: nil)
    }

    private var markupHolders: [CALayer] = []
    private var selectionHolders: [CALayer] = []
    private var pageLayer: CALayer?
    private let edge = PageEdge()

    @objc private func themeChanged() {
        for (paper, preview) in paperLayers {
            Self.paint(paper)
            preview.update(paper, themeChanged: true)
        }
        if let pageLayer { edge.update(pageLayer, themeChanged: true) }
        markupHolders.forEach(Self.styleMarkup)
        selectionHolders.forEach(Self.styleSelection)
        // Annotations that draw themselves (Galley's comment markers) have a layer of their own,
        // which redrawing the page doesn't reach.
        for holder in markupHolders {
            for layer in holder.sublayers ?? [] where "\(type(of: layer))" == "PDFPageLayerAnnotationEffect" {
                layer.setNeedsDisplay()
            }
        }
    }

    nonisolated private static func isSelection(_ layer: CALayer) -> Bool {
        "\(type(of: layer))" == "PDFPageLayerSelectionEffect"
    }

    /// The selection is drawn the same way: light blue rectangles multiplied with the page, which
    /// on a dark page leaves only a faint tint. There they are laid on see-through.
    nonisolated private static func styleSelection(in holder: CALayer) {
        let inverts = PageTheme.current.inverts
        let filter: String? = inverts ? nil : "multiplyBlendMode"
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [holder] + (holder.sublayers ?? []) {
            if layer.compositingFilter as? String != filter { layer.compositingFilter = filter }
        }
        let opacity: Float = inverts ? 0.45 : 1
        if holder.opacity != opacity { holder.opacity = opacity }
        CATransaction.commit()
    }

    /// On screen PDFKit draws highlights and underlines as layers of their own over the page: a
    /// rectangle in the annotation's colour per line (thin ones for underlines), multiplied with
    /// the page. On a dark page that gives black, so there they are laid on normally – highlights
    /// see-through, so the light text stays readable.
    nonisolated private static func isMarkup(_ layer: CALayer) -> Bool {
        "\(type(of: layer))" == "PDFPageLayerMarkupAnnotationEffect"
    }

    nonisolated private static func styleMarkup(in holder: CALayer) {
        let inverts = PageTheme.current.inverts
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for markup in (holder.sublayers ?? []) where isMarkup(markup) {
            let isUnderline = (markup.sublayers ?? []).allSatisfy { $0.frame.height < 3 }
            let filter: String? = inverts ? nil : "multiplyBlendMode"
            if markup.compositingFilter as? String != filter { markup.compositingFilter = filter }
            let opacity: Float = inverts && !isUnderline ? 0.45 : 1
            if markup.opacity != opacity { markup.opacity = opacity }
        }
        CATransaction.commit()
    }

    nonisolated private static func paint(_ paper: CALayer) {
        let color = PageTheme.current.paperColor
        guard paper.backgroundColor != color else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paper.backgroundColor = color
        CATransaction.commit()
    }
}

/// The picture of a page PDFKit shows before its tiles, swapped for a recoloured copy. The
/// original is kept for the next theme change; PDFKit may set the picture from any thread.
private final class PagePreview: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var original: NSImage?
    private var shown: NSImage?

    func update(_ layer: CALayer, themeChanged: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard let image = layer.contents as? NSImage else { return }
        if image !== shown { original = image } else if !themeChanged { return }   // our own copy
        guard let original else { return }
        let recolored = PageTheme.recolor(original)
        shown = recolored
        guard recolored !== image else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = recolored
        CATransaction.commit()
    }
}

/// The page's 1-point edge, drawn over everything: PDFKit draws it black at 6 %, invisible on a
/// dark page, which is then hard to tell from the grey behind it. And PDFKit's tiles are white
/// beyond the page: where the edge falls on a fraction of a pixel, a light hairline shows on the
/// right and bottom. On dark pages a solid grey edge, lighter than page and background, covers it
/// and frames the page; PDFKit's own colour is kept for the other themes.
private final class PageEdge: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var original: CGColor?
    private var shown: CGColor?
    private static let darkEdge = CGColor(gray: 0.3, alpha: 1)

    func update(_ layer: CALayer, themeChanged: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let current = layer.borderColor
        if current != shown { original = current } else if !themeChanged { return }   // our own colour
        let wanted = PageTheme.current.inverts ? Self.darkEdge : original
        shown = wanted
        guard wanted != current else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.borderColor = wanted
        CATransaction.commit()
    }
}
