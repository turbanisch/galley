import AppKit
import PDFKit

/// A link's jump target, as found under the mouse.
struct LinkTarget {
    /// The view the link was found in (the main view or the split pane).
    let view: PDFView
    let annotation: PDFAnnotation
    let page: PDFPage
    let destination: PDFDestination
}

/// PDFKit turns anything in the text that looks like a URL into a clickable link, even with
/// `enableDataDetectors` off. As a view's delegate this is asked before any URL is opened, and
/// opens only those of link annotations the PDF itself has at that spot.
final class WebLinkFilter: NSObject, PDFViewDelegate {
    static let shared = WebLinkFilter()

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        guard let window = sender.window else { return }
        let inWindow = NSApp.currentEvent.flatMap { $0.window === window ? $0.locationInWindow : nil }
            ?? window.mouseLocationOutsideOfEventStream
        let point = sender.convert(inWindow, from: nil)
        guard let page = sender.page(for: point, nearest: false),
              let link = Self.webLink(on: page, at: sender.convert(point, to: page)) else { return }
        NSWorkspace.shared.open(link)
    }

    /// The URL of a link annotation in the PDF at this point, if any.
    static func webLink(on page: PDFPage, at point: NSPoint) -> URL? {
        for annotation in page.annotations.reversed()
        where annotation.type == "Link" && annotation.bounds.insetBy(dx: -1, dy: -1).contains(point) {
            if let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url { return url }
        }
        return nil
    }
}

/// The content of the link preview popover: a small, scrollable PDF view of the same document,
/// positioned at the link's target with the text block filling the width.
final class LinkPreviewController: NSViewController {
    /// Where the target ends up in the preview.
    enum Placement {
        /// Near the top, with a little context above (headings, citations, tables with the caption on top).
        case top
        /// The anchor is a caption below its figure: show the figure above it.
        /// (The figure's top and its caption's top, in page coordinates.)
        case figure(top: CGFloat, caption: CGFloat)
    }

    let previewView: PDFView
    private let document: PDFDocument
    private let destination: PDFDestination
    private let column: (minX: CGFloat, maxX: CGFloat)?
    private let placement: Placement
    private let size: NSSize
    private let scale: CGFloat
    private var positioned = false
    private static let hiddenStrip: CGFloat = 16
    /// Called on a click; true when ⌘ was held (open in the split view).
    var onOpen: ((_ inSplit: Bool) -> Void)?

    /// `mainScale` is the main view's zoom, so text in the preview is as large as in the document;
    /// `available` is the main view's size, which caps the preview.
    init(document: PDFDocument, destination: PDFDestination, column: (minX: CGFloat, maxX: CGFloat)?,
         placement: Placement, mainScale: CGFloat, available: NSSize) {
        self.document = document
        self.destination = destination
        self.placement = placement
        // The width of a page as shown (a turned page's height).
        func shownWidth(_ page: PDFPage?) -> CGFloat? {
            page.map { $0.bounds(for: .mediaBox).applying($0.transform(for: .mediaBox)).width }
        }
        let pageWidth = shownWidth(destination.page) ?? 612
        // A page wider than the document's usual ones (a landscape table, turned or stored that
        // way): the text column, measured on the usual pages, doesn't apply; the whole page's width.
        let isWide = pageWidth > (shownWidth(document.page(at: 0)) ?? pageWidth) * 1.15
        self.column = isWide ? nil : column
        let contentWidth = isWide ? pageWidth : column.map { ($0.maxX - $0.minX) * 1.06 } ?? pageWidth
        let maxWidth = max(360, available.width * 0.8)
        let width = min(max(contentWidth * mainScale, 360), maxWidth)
        let height = min(max(available.height * 0.42, 260), 560)
        size = NSSize(width: width.rounded(), height: height.rounded())
        scale = size.width / contentWidth
        previewView = PDFView(frame: NSRect(origin: .zero, size: size))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        previewView.displayMode = .singlePageContinuous
        previewView.displaysPageBreaks = true
        previewView.enableDataDetectors = false
        previewView.delegate = WebLinkFilter.shared
        previewView.pageOverlayViewProvider = PagePaper.shared
        previewView.autoScales = false
        previewView.backgroundColor = DocumentWindowController.canvasColor
        previewView.document = document
        // PDFKit keeps turning its horizontal scroller back on. Make the PDF view a bit taller than
        // the popover and clip it, so the scroller sits below the visible area.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.clipsToBounds = true
        previewView.frame = NSRect(x: 0, y: -Self.hiddenStrip, width: size.width, height: size.height + Self.hiddenStrip)
        previewView.autoresizingMask = [.width, .height]
        container.addSubview(previewView)
        view = container
        preferredContentSize = size
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        previewView.addGestureRecognizer(click)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        hideHorizontalScroller()
        guard !positioned, previewView.bounds.width > 0 else { return }
        positioned = true
        position()
    }

    private func position() {
        previewView.scaleFactor = scale
        previewView.layoutDocumentView()
        previewView.reveal(destination, column: column, placement: placement,
                           visibleHeight: (previewView.bounds.height - Self.hiddenStrip) / scale)
        hideHorizontalScroller()
    }

    /// The column fills the width, so the page's margins stick out on both sides; scrolling there
    /// isn't useful and the scroller is just clutter. PDFKit nests its scroll view, so search for it.
    private func hideHorizontalScroller() {
        func find(_ view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView { return scrollView }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        guard let scrollView = find(previewView) else { return }
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
    }

    @objc private func clicked() {
        onOpen?(NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
    }
}

extension PDFView {
    /// Scrolls so that `destination` is shown with the text column's left edge at the left
    /// (as in the link preview). `visibleHeight` in page points; defaults to the view's height.
    func reveal(_ destination: PDFDestination, column: (minX: CGFloat, maxX: CGFloat)?,
                placement: LinkPreviewController.Placement, visibleHeight: CGFloat? = nil) {
        guard let page = destination.page else { return }
        let bounds = page.bounds(for: .mediaBox)
        if page.rotation != 0 {
            // A turned page (a landscape table): up on screen runs along another of the page's
            // axes. The target at the top with a small margin, the page's left edge at the left
            // (column and figure framing assume an upright page).
            let shown = page.transform(for: .mediaBox), shownBounds = bounds.applying(shown)
            let target = NSPoint(x: min(max(destination.point.x, bounds.minX), bounds.maxX),
                                 y: min(max(destination.point.y, bounds.minY), bounds.maxY)).applying(shown)
            let point = NSPoint(x: shownBounds.minX, y: min(target.y + 10, shownBounds.maxY)).applying(shown.inverted())
            scrollToTop(point, on: page)
            return
        }
        let left = column.map { $0.minX - ($0.maxX - $0.minX) * 0.03 } ?? bounds.minX
        let anchorY = destination.point.y > bounds.maxY ? bounds.maxY : destination.point.y
        let height = visibleHeight ?? self.bounds.height / max(scaleFactor, 0.01)
        let above: CGFloat
        switch placement {
        case .top:
            // A hint of what comes before: most of a line's height (10 points for ordinary text,
            // less in small print, where 10 points would show a whole line of the entry before).
            let probeX = column.map { destination.point.x > $0.minX ? destination.point.x + 2 : $0.minX + 2 } ?? destination.point.x + 2
            if let line = page.selectionForLine(at: NSPoint(x: probeX, y: anchorY - 3)),
               let text = line.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let lineHeight = line.bounds(for: page).height
                above = lineHeight > 0 && lineHeight < 40 ? min(10, max(3, lineHeight * 0.75)) : 10
            } else {
                above = 10
            }
        case .figure(let figureTop, let caption):
            // The whole figure with its caption below, if it fits; otherwise as much of the
            // figure as fits, with the caption's first lines at the bottom.
            if figureTop - caption + 10 + 40 <= height {
                above = figureTop + 10 - anchorY
            } else {
                above = caption + max(height * 0.5, height - 45) - anchorY
            }
        }
        let top = min(anchorY + above, bounds.maxY)
        scrollToTop(NSPoint(x: left, y: top), on: page)
    }

    /// Scrolls so that a point of a page is at the top of the view.
    private func scrollToTop(_ point: NSPoint, on page: PDFPage) {
        go(to: PDFDestination(page: page, at: point))
        // PDFKit doesn't always put the point at the very top (e.g. a footnote near the bottom of
        // a page, where the next page would come into view): scroll the rest of the way ourselves.
        guard let scroll = enclosingScrollViewInside(), let documentView = scroll.documentView else { return }
        layoutDocumentView()
        let clip = scroll.contentView
        let wanted = NSPoint(x: 0, y: isFlipped ? self.bounds.minY + safeAreaInsets.top : self.bounds.maxY - safeAreaInsets.top)
        let actual = convert(point, from: page)
        let wantedInDocument = documentView.convert(wanted, from: self)
        let actualInDocument = documentView.convert(actual, from: self)
        var origin = clip.bounds.origin
        origin.y += actualInDocument.y - wantedInDocument.y
        guard abs(actualInDocument.y - wantedInDocument.y) > 1 else { return }
        clip.setBoundsOrigin(clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    /// PDFKit's own scroll view, somewhere inside the PDF view.
    func enclosingScrollViewInside() -> NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return find(self)
    }

    /// The scale at which the text column (with a little margin) fills the view's width.
    func textColumnScale(column: (minX: CGFloat, maxX: CGFloat)?) -> CGFloat? {
        guard bounds.width > 0, let page = document?.page(at: 0) else { return nil }
        let contentWidth = column.map { ($0.maxX - $0.minX) * 1.06 } ?? page.bounds(for: .mediaBox).width
        return bounds.width / contentWidth
    }
}
