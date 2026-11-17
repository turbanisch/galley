import AppKit
import QuartzCore
import PDFKit
import SwiftUI

private struct FileSignature: Equatable {
    let modified: Date
    let size: Int
    let inode: Int
}

extension NSToolbarItem.Identifier {
    static let galleySearch = NSToolbarItem.Identifier("galley.search")
}

enum ZoomMode {
    case fitWidth, fitPage, fitText, readingSize, actualSize, custom
}

/// Holds the main view and the split pane. Toggle Sidebar travels up the responder chain and
/// would stop here (no sidebar in this split), so pass it on to the outer split with the sidebar.
final class DocumentSplitController: NSSplitViewController {
    override func toggleSidebar(_ sender: Any?) {
        (parent as? NSSplitViewController)?.toggleSidebar(sender)
    }
}

@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let url: URL
    let model = ViewerModel()
    let pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
    private(set) var isClosed = false

    private var sidebarItem: NSSplitViewItem?
    /// Set while View → Slide Show waits for full screen to begin.
    private var slideShowPending = false
    /// Whether the slide show switched to full screen itself (and leaves it again).
    private var slideShowMadeFullScreen = false
    /// What the slide show changed, to restore when full screen ends; nil when no show runs.
    private var slideShowSaved: (sidebarCollapsed: Bool, toolbarVisible: Bool, separator: NSTitlebarSeparatorStyle,
                                 zoom: ZoomMode, scale: CGFloat, displayMode: PDFDisplayMode)?
    private weak var sidebarView: NSView?
    private var searchItem: NSSearchToolbarItem?
    private var lastQuery = ""

    private var loadedSignature: FileSignature?
    private var pendingSignature: FileSignature?
    private var failedAttempts = 0
    private var reloadTimer: Timer?
    private weak var observedClipView: NSClipView?
    private var pendingScrollOrigin: NSPoint?
    private var lastSubtitle = ""
    private var sectionPinnedUntil = Date.distantPast
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var documentSplit: NSSplitViewController!
    private var splitPaneItem: NSSplitViewItem?
    /// A second view of the same document (⌥⌘S, or ⌘-click a link); nil when closed.
    private(set) var splitPane: PDFView?
    private var splitIsStacked: Bool?
    /// Set once Switch Split Orientation was used; until then each opening picks by window shape.
    private var userChoseOrientation = false
    private var pendingSplitOrigin: NSPoint?
    private var swallowMouseUp = false
    /// Every mode the window is in counts as used (also the one it opens with, e.g. Fit Page for
    /// slides), so after a free zoom the switcher offers the mode it came from first. Not the
    /// slide show's own Fit Page.
    private var zoomMode: ZoomMode = .readingSize {
        didSet { if slideShowSaved == nil { zoomHistory.use(zoomMode) } }
    }
    private var isApplyingZoom = false
    private var lastFittedScale: CGFloat = 0
    private var lastScreenNumber: CGDirectDisplayID?
    /// Type size of the body text in PDF points (nil if it can't be measured, e.g. scans).
    private var bodyTypeSize: CGFloat?
    /// Horizontal extent of the text block in page space (nil if it can't be measured).
    private var textColumn: (minX: CGFloat, maxX: CGFloat)?
    /// Highlights added or removed and not yet saved into the file.
    private let annotations = Annotations()
    /// The colour M, U and A use (1–8): yellow in each new window, then the last one chosen here.
    /// (Colours often carry a meaning; one carried over from the last paper would be a silent mistake.)
    private var colorIndex = 0

    // MARK: Setup

    init?(url: URL) {
        guard let doc = DocumentWindowController.loadDocument(at: url) else { return nil }
        self.url = url
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        super.init(window: window)

        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = url.lastPathComponent
        window.representedURL = url
        window.minSize = NSSize(width: 520, height: 400)

        configurePDFView()
        model.controller = self

        let split = NSSplitViewController()
        let sidebarVC = NSHostingController(rootView: SidebarView(model: model))
        sidebarView = sidebarVC.view
        sidebarVC.sizingOptions = []
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebar.minimumThickness = 190
        sidebar.maximumThickness = 460
        sidebarItem = sidebar
        let pdfVC = NSViewController()
        pdfVC.view = pdfView
        // The document area: the main view, and optionally a split pane next to or below it.
        let documentSplit = DocumentSplitController()
        documentSplit.splitView.isVertical = true
        documentSplit.splitView.dividerStyle = .thin
        let mainItem = NSSplitViewItem(viewController: pdfVC)
        mainItem.minimumThickness = 200
        documentSplit.addSplitViewItem(mainItem)
        self.documentSplit = documentSplit
        NotificationCenter.default.addObserver(self, selector: #selector(documentSplitResized(_:)),
                                               name: NSSplitView.didResizeSubviewsNotification,
                                               object: documentSplit.splitView)
        let content = NSSplitViewItem(viewController: documentSplit)
        content.minimumThickness = 320
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(content)
        split.splitView.autosaveName = "GalleySidebarSplit"
        window.contentViewController = split

        let toolbar = NSToolbar(identifier: "GalleyToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        placeWindow(window)

        pdfView.document = doc
        perform(#selector(initialLayout), with: nil, afterDelay: 0)
        loadedSignature = currentSignature()
        documentDidLoad(doc, isReload: false)

        let timer = Timer(timeInterval: 0.3, target: self, selector: #selector(checkForChanges),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        reloadTimer = timer

        window.makeFirstResponder(pdfView)

        window.acceptsMouseMovedEvents = true
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .otherMouseDown, .rightMouseDown]) { [weak self] event in
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if event.type == .leftMouseDown || event.type == .otherMouseDown || event.type == .rightMouseDown { self.hideLinkHints() }
                if event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
                    if self.showContextMenu(for: event) {
                        if event.type == .leftMouseDown { self.swallowMouseUp = true }
                        return true
                    }
                    return false
                }
                if event.type == .leftMouseDown {
                    self.mouseDownLocation = event.locationInWindow
                    return self.handleMouseDown(event)
                }
                if event.type == .otherMouseDown { return self.handleMiddleClick(event) }
                if event.type == .leftMouseDragged { return self.handleLinkPressDrag(event) }
                if event.type == .leftMouseUp {
                    defer { self.swallowMouseUp = false }
                    if self.linkPress != nil { return self.endLinkPress() }
                    if !self.swallowMouseUp { self.noteClick(event) }
                    return self.swallowMouseUp
                }
                self.handleMouseMoved()
                // PDFKit runs data detection on hover: dates, addresses and phone numbers get a
                // dashed outline with a menu (and `enableDataDetectors = false` is ignored). Keeping
                // mouse moves over the pages away from PDFKit stops that; the cursor is set here.
                return event.window === self.window && self.updateCursorOverPages()
            }
            return swallow ? nil : event
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
            return handled ? nil : event
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func configurePDFView() {
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.enableDataDetectors = false   // no date/address/phone highlights and popovers
        pdfView.delegate = WebLinkFilter.shared // nor links made from URLs in the text
        pdfView.pageOverlayViewProvider = PagePaper.shared
        pdfView.autoScales = false
        pdfView.backgroundColor = Self.canvasColor
        pdfView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewPositionChanged(_:)),
                                               name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleZoomUpdate),
                                               name: NSView.frameDidChangeNotification, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleZoomUpdate),
                                               name: NSWindow.didChangeScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleZoomUpdate),
                                               name: NSWindow.didChangeBackingPropertiesNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleZoomUpdate),
                                               name: ReadingSizeStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged(_:)),
                                               name: .PDFViewScaleChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(pageThemeChanged),
                                               name: PageTheme.didChange, object: nil)
    }

    /// The pages draw themselves in the new colour; PDFKit only has to draw them again.
    @objc private func pageThemeChanged() {
        closePreview()
        for view in [pdfView, splitPane].compactMap({ $0 }) {
            view.needsDisplay = true
            view.documentView?.needsDisplay = true
        }
        model.themeVersion += 1
    }

    /// Grey behind the pages, matching Preview (which uses its own shade, not a system color).
    static let canvasColor = NSColor(name: "GalleyCanvas") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(white: isDark ? 0.16 : 0.59, alpha: 1)
    }

    /// Reads the whole file into memory, so a recompile that rewrites the file can't disturb the open copy.
    static func loadDocument(at url: URL) -> PDFDocument? {
        guard let data = try? Data(contentsOf: url),
              let doc = ThemedDocument(data: data),
              doc.pageCount > 0 else { return nil }
        DestinationFixer.fix(doc, data: data)  // link targets PDFKit moves to the top of the page
        ReferenceDetector.addLinks(to: doc)   // figure, table and citation links where the PDF has none
        return doc
    }

    private func documentDidLoad(_ doc: PDFDocument, isReload: Bool) {
        closePreview()
        let metrics = Self.measureText(doc)
        bodyTypeSize = metrics.typeSize
        textColumn = metrics.column
        debugLog("body type size \(bodyTypeSize.map { fmt($0) } ?? "not measurable")")
        debugLog(DestinationFixer.report)
        for line in ReferenceDetector.report { debugLog("references: " + line) }
        let built = OutlineBuilder.build(doc)
        model.flat = built.flat
        model.outlineTitle = built.title
        if isReload { model.replaceOutline(built.nodes) } else { model.outline = built.nodes }
        model.documentVersion += 1
        if !isReload {
            model.resetExpansion()
            // Slides are found by their pages: thumbnails and whole slides (their outline, if any,
            // stays in the View menu). Scans usually have no outline either: show their pages instead.
            let slides = OutlineDetector.isSlides(doc)
            model.sidebarMode = slides || built.nodes.isEmpty ? .thumbnails : .outline
            if slides { zoomMode = .fitPage }
        }
        if !model.searchText.isEmpty {
            runSearch(model.searchText, jump: false)
        } else {
            pdfView.highlightedSelections = nil
        }
        attachScrollObserver()
        updatePositionUI()
        Annotations.updateCommentMarkers(in: doc)
    }

    // MARK: Auto-reload

    private func currentSignature() -> FileSignature? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return FileSignature(modified: (attrs[.modificationDate] as? Date) ?? .distantPast,
                             size: (attrs[.size] as? NSNumber)?.intValue ?? 0,
                             inode: (attrs[.systemFileNumber] as? NSNumber)?.intValue ?? 0)
    }

    @objc private func checkForChanges() {
        guard savesInFlight == 0 else { return }
        guard let sig = currentSignature() else { pendingSignature = nil; return }
        if sig == loadedSignature { pendingSignature = nil; return }
        // Wait until the file has stopped changing for one tick before reading it.
        guard sig == pendingSignature else {
            pendingSignature = sig
            failedAttempts = 0
            return
        }
        if reloadDocument() {
            loadedSignature = sig
            pendingSignature = nil
        } else {
            failedAttempts += 1
            if failedAttempts > 20 { loadedSignature = sig }   // broken file: stop retrying until it changes
        }
    }

    private static func looksComplete(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return false }
        let count = min(size, 4096)
        do { try handle.seek(toOffset: size - count) } catch { return false }
        guard let tail = try? handle.read(upToCount: Int(count)) else { return false }
        return tail.range(of: Data("%%EOF".utf8)) != nil
    }

    private func reloadDocument() -> Bool {
        saveAnnotationsNow()
        guard Self.looksComplete(url), let doc = Self.loadDocument(at: url) else { return false }
        let origin = Self.findScrollView(in: pdfView)?.contentView.bounds.origin
        let scale = pdfView.scaleFactor
        let mode = pdfView.displayMode

        let splitOrigin = splitPane.flatMap { Self.findScrollView(in: $0)?.contentView.bounds.origin }
        pdfView.document = doc
        pdfView.displayMode = mode
        if let pane = splitPane {
            pane.document = doc
            fitSplitPane()
            pendingSplitOrigin = splitOrigin
            restoreSplitOrigin()
            perform(#selector(restoreSplitOrigin), with: nil, afterDelay: 0)
        }
        if zoomMode == .custom { pdfView.scaleFactor = scale } else { applyZoomMode() }
        pdfView.layoutDocumentView()

        if let origin {
            pendingScrollOrigin = origin
            applyScrollOrigin()
            // PDFView sometimes scrolls again after layout; apply once more on the next run loop pass.
            perform(#selector(finishScrollRestore), with: nil, afterDelay: 0)
        }
        window?.undoManager?.removeAllActions(withTarget: self)   // they refer to the old document's pages
        documentDidLoad(doc, isReload: true)
        return true
    }

    private func applyScrollOrigin() {
        guard let origin = pendingScrollOrigin, let scroll = Self.findScrollView(in: pdfView) else { return }
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func finishScrollRestore() {
        applyScrollOrigin()
        pendingScrollOrigin = nil
        updatePositionUI()
    }

    private static func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    // MARK: Position tracking

    private func attachScrollObserver() {
        guard observedClipView == nil, let scroll = Self.findScrollView(in: pdfView) else { return }
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewPositionChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: clip)
        observedClipView = clip
    }

    @objc private func viewPositionChanged(_ note: Notification) {
        hideLinkHints()
        removePDFKitToolTips()
        if previewPopover?.isShown == true, !mouseIsInPreview { closePreview() }
        updatePositionUI()
    }

    /// The page and page-space y coordinate at the top edge of the visible area (below the toolbar)
    /// of the main view, or of `view` (the split pane).
    private func visibleTop(in view: PDFView? = nil) -> (page: PDFPage, pageIndex: Int, y: CGFloat)? {
        let pdfView = view ?? pdfView
        guard let doc = pdfView.document else { return nil }
        let inset = pdfView.safeAreaInsets.top
        let bounds = pdfView.bounds
        let viewY = pdfView.isFlipped ? bounds.minY + inset + 2 : bounds.maxY - inset - 2
        let point = NSPoint(x: bounds.midX, y: viewY)
        guard let page = pdfView.page(for: point, nearest: true) else { return nil }
        let pagePoint = pdfView.convert(point, to: page)
        let index = doc.index(for: page)
        // In the grey gap below a page (Fit Page on the last page: the slack left so no scroll bar
        // appears ends up at the top): the next page is the one at the top, from its top edge.
        if pagePoint.y < page.bounds(for: pdfView.displayBox).minY, let next = doc.page(at: index + 1) {
            return (next, index + 1, next.bounds(for: pdfView.displayBox).maxY)
        }
        return (page, index, pagePoint.y)
    }

    private func updatePositionUI() {
        guard let doc = pdfView.document, let top = visibleTop() else { return }
        let number = "\(top.pageIndex + 1)"
        var subtitle = "Page \(number) of \(doc.pageCount)"
        // The printed page number, when the PDF has one that differs.
        if let label = top.page.label, !label.isEmpty, label != number { subtitle += " (\(label))" }
        if subtitle != lastSubtitle {
            lastSubtitle = subtitle
            window?.subtitle = subtitle
        }
        if model.currentPageIndex != top.pageIndex { model.currentPageIndex = top.pageIndex }

        // Right after a click in the outline, keep the clicked entry highlighted.
        guard Date() >= sectionPinnedUntil else { return }

        model.setCurrentSection(sectionID(at: top))
    }

    /// The last outline entry that starts at or above the top of the view.
    private func sectionID(at top: (page: PDFPage, pageIndex: Int, y: CGFloat)) -> Int? {
        let pageIndex = top.pageIndex
        let y = top.y
        var best: Int? = nil
        var bestPage = -1
        var bestY: CGFloat = 0
        for entry in model.flat {
            let isAbove = entry.pageIndex < pageIndex || (entry.pageIndex == pageIndex && entry.y >= y - 24)
            guard isAbove else { continue }
            let isEarlier = entry.pageIndex < bestPage || (entry.pageIndex == bestPage && entry.y > bestY)
            if best != nil && isEarlier { continue }
            best = entry.id
            bestPage = entry.pageIndex
            bestY = entry.y
        }
        return best
    }

    /// How far (in view points, positive = down) the view must scroll to bring a page point
    /// to the top of the visible area, just below the toolbar.
    private func distanceToTop(of point: NSPoint, on page: PDFPage, in view: PDFView? = nil) -> CGFloat? {
        let pdfView = view ?? pdfView
        guard let scroll = Self.findScrollView(in: pdfView) else { return nil }
        let inset = max(scroll.contentInsets.top, pdfView.safeAreaInsets.top)
        let target = pdfView.convert(point, from: page)
        if pdfView.isFlipped {
            return target.y - (pdfView.bounds.minY + inset)
        }
        return (pdfView.bounds.maxY - inset) - target.y
    }

    /// The page-space y that `go(to:)` scrolls to the top of the view for this heading.
    private func targetY(for node: OutlineNode) -> CGFloat? {
        guard let doc = pdfView.document, let index = node.pageIndex, let page = doc.page(at: index) else { return nil }
        return min(node.y + 12, page.bounds(for: .mediaBox).maxY)
    }

    /// In the split pane (`view`) only the pane moves: the sidebar and the history follow the main view.
    func go(to node: OutlineNode, in view: PDFView? = nil) {
        let pdfView = view ?? pdfView
        guard let doc = pdfView.document, let index = node.pageIndex, let page = doc.page(at: index),
              let y = targetY(for: node) else { return }
        if let distance = distanceToTop(of: NSPoint(x: 0, y: y), on: page, in: pdfView),
           let scroll = Self.findScrollView(in: pdfView),
           abs(distance) <= 1.5 * (pdfView.bounds.height - max(scroll.contentInsets.top, pdfView.safeAreaInsets.top)) {
            // Short jump: glide there, so the eye can follow. The distance is measured from where
            // the view is right now, so don't add it to a still-running animation's target.
            scrollAnimationEnds = .distantPast
            scrollBy(distance, animated: true, in: pdfView)
        } else {
            // Long jump: go straight there.
            pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: y)))
        }
        guard view == nil || view === self.pdfView else { return }
        perform(#selector(alignHorizontallyAction), with: nil, afterDelay: 0)
        guard node.id >= 0 else { return }
        model.setCurrentSection(node.id)
        sectionPinnedUntil = Date().addingTimeInterval(0.4)
    }

    // MARK: Zoom

    /// The zoom a mode stands for right now (nil for a custom zoom or before layout).
    /// Computed from the page and window geometry, so it gives the same result every time.
    private func scale(for mode: ZoomMode) -> CGFloat? {
        guard mode != .custom,
              let page = pdfView.currentPage ?? pdfView.document?.page(at: 0),
              let scroll = Self.findScrollView(in: pdfView) else { return nil }

        let scale: CGFloat
        let screen = window?.screen ?? NSScreen.main
        if mode == .actualSize {
            scale = Self.paperScale(for: screen)
        } else if mode == .readingSize {
            // Capped so that the text column always fits: a column cut off at the side would mean
            // scrolling sideways on every line (small screens, half a window in the split view).
            let reading = readingScale(for: screen)
            let cap = self.scale(for: .fitText) ?? .greatestFiniteMagnitude
            isReadingSizeCapped = cap < reading
            scale = min(reading, cap)
        } else {
            // Visible area: the PDF view (already at its new size during a resize) minus the part
            // under the toolbar and a classic scroll bar, if one takes up space.
            let bounds = pdfView.bounds.size
            let topInset = max(scroll.contentInsets.top, pdfView.safeAreaInsets.top)
            var scrollerWidth: CGFloat = 0
            if scroll.scrollerStyle == .legacy, scroll.hasVerticalScroller, let scroller = scroll.verticalScroller {
                scrollerWidth = scroller.frame.width
            }
            let availableWidth = bounds.width - scrollerWidth - 2
            let availableHeight = bounds.height - topInset - scroll.contentInsets.bottom - 2
            guard availableWidth > 50, availableHeight > 50 else { return nil }

            // Page size in points, respecting rotation; two pages side by side in two-page mode.
            var size = page.bounds(for: pdfView.displayBox).size
            if page.rotation % 180 != 0 { size = NSSize(width: size.height, height: size.width) }
            // PDFKit lays pages out in whole points (Beamer's 272.126 takes 273): fit those, or a
            // large zoom overflows by a pixel and brings up a scroll bar.
            size = NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
            let columns: CGFloat = pdfView.displayMode == .twoUpContinuous || pdfView.displayMode == .twoUp ? 2 : 1
            let margins = pdfView.displaysPageBreaks ? pdfView.pageBreakMargins : NSEdgeInsets()
            let marginW = (margins.left + margins.right) * columns
            let marginH = margins.top + margins.bottom
            let contentW = size.width * columns

            // Whether PDFKit scales the margins with the page or not, never overflow.
            func fit(_ available: CGFloat, _ content: CGFloat, _ margin: CGFloat) -> CGFloat {
                min((available - margin) / content, available / (content + margin))
            }
            var s = fit(availableWidth, contentW, marginW)
            if mode == .fitPage { s = min(s, fit(availableHeight, size.height, marginH)) }
            // Fit Text Width: the text block (plus a little air) fills the width; single-page layout only.
            if mode == .fitText, columns == 1, let column = textColumn {
                s = availableWidth / ((column.maxX - column.minX) * 1.06)
            }
            scale = s
        }
        return scale > 0 ? scale : nil
    }

    /// Applies the current zoom mode; does nothing for a custom zoom.
    private func applyZoomMode() {
        guard slideShowSaved == nil else { return }     // PDFKit fits the slides itself
        lastScreenNumber = Self.displayID(of: window?.screen)
        guard let scale = scale(for: zoomMode) else { return }
        let changed = abs(scale - pdfView.scaleFactor) > 0.0005
        // The page mostly in view, so Fit Page can line it up again after re-fitting.
        let anchor = pdfView.page(for: NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY), nearest: true)
        if changed {
            isApplyingZoom = true
            pdfView.autoScales = false
            pdfView.scaleFactor = scale
            pdfView.layoutDocumentView()
            lastFittedScale = pdfView.scaleFactor
            isApplyingZoom = false
        }
        // After a zoom change PDFKit leaves the page top under the toolbar; Fit Page lines it up.
        if changed, zoomMode == .fitPage, let anchor { pdfView.go(to: anchor) }
        // Every zoom mode keeps the page centered across (a free zoom is left alone).
        alignHorizontally()
        debugLog("applied \(zoomMode) scale=\(fmt(scale)) changed=\(changed)")
        perform(#selector(logLayoutAfterwards), with: nil, afterDelay: 0.5)
    }

    // MARK: Debug log (enabled with: defaults write io.github.turbanisch.galley GalleyDebugLog /path/to/file)

    private func fmt(_ v: CGFloat) -> String { String(format: "%.3f", Double(v)) }
    private func fmt(_ r: NSRect) -> String {
        String(format: "(%.0f,%.0f %.0f×%.0f)", Double(r.minX), Double(r.minY), Double(r.width), Double(r.height))
    }

    private func debugLog(_ message: String) {
        guard let path = UserDefaults.standard.string(forKey: "GalleyDebugLog") else { return }
        let scroll = Self.findScrollView(in: pdfView)
        let screen = window?.screen
        var line = "\(Date().formatted(.dateTime.hour().minute().second())) \(message)"
        line += " | screen=\(Self.displayID(of: screen).map { "\($0)" } ?? "?") frame=\(screen.map { fmt($0.frame) } ?? "?") backing=\(fmt(screen?.backingScaleFactor ?? 0))"
        line += " | window=\(window.map { fmt($0.frame) } ?? "?") pdfView=\(fmt(pdfView.bounds)) safeTop=\(fmt(pdfView.safeAreaInsets.top))"
        if let scroll {
            line += " | clip=\(fmt(scroll.contentView.frame)) clipBounds=\(fmt(scroll.contentView.bounds)) insetsTop=\(fmt(scroll.contentInsets.top))"
            line += " doc=\(scroll.documentView.map { fmt($0.frame) } ?? "?")"
        }
        line += " | pdfScale=\(fmt(pdfView.scaleFactor)) mode=\(zoomMode)"
        if let page = pdfView.currentPage { line += " page=\(fmt(page.bounds(for: pdfView.displayBox)))" }
        line += "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }

    @objc private func logLayoutAfterwards() {
        debugLog("0.5 s later")
    }

    /// Horizontal position for the current mode: the text block centered for Fit Text Width,
    /// otherwise the page. A free zoom is left alone.
    private func alignHorizontally() {
        guard zoomMode != .custom else { return }
        if zoomMode == .fitText { centerTextBlock() } else { centerHorizontally() }
    }

    @objc private func alignHorizontallyAction() {
        alignHorizontally()
    }

    private func centerTextBlock() {
        guard let column = textColumn, let page = pdfView.currentPage,
              let scroll = Self.findScrollView(in: pdfView) else { centerHorizontally(); return }
        let middle = pdfView.convert(NSPoint(x: (column.minX + column.maxX) / 2, y: page.bounds(for: .mediaBox).midY),
                                     from: page)
        let delta = middle.x - pdfView.bounds.midX           // in view points
        let clip = scroll.contentView
        guard clip.frame.width > 0, abs(delta) > 0.5 else { return }
        var origin = clip.bounds.origin
        origin.x += delta * clip.bounds.width / clip.frame.width
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }

    /// Removes any sideways scroll offset left over from a wider zoom.
    private func centerHorizontally() {
        guard let scroll = Self.findScrollView(in: pdfView), let document = scroll.documentView else { return }
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        // Negative when the page is narrower than the view: that is how PDFKit centers it.
        let centered = (document.frame.width - clip.bounds.width) / 2
        guard abs(origin.x - centered) > 0.5 else { return }
        origin.x = centered
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }

    private static func displayID(of screen: NSScreen?) -> CGDirectDisplayID? {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    /// Scale at which one inch in the PDF is one inch on this display.
    private static func paperScale(for screen: NSScreen?) -> CGFloat {
        guard let screen, let id = displayID(of: screen) else { return 1 }
        let millimeters = CGDisplayScreenSize(id)
        guard millimeters.width > 0 else { return 1 }
        let pointsPerMillimeter = screen.frame.width / millimeters.width
        return pointsPerMillimeter * 25.4 / 72      // one PDF point is 1/72 inch
    }

    /// Estimated viewing distance: about 50 cm for a laptop, more for larger monitors (27" ≈ 70 cm).
    private static func viewingDistance(for screen: NSScreen?) -> CGFloat {
        guard let id = displayID(of: screen) else { return 50 }
        if CGDisplayIsBuiltin(id) != 0 { return 50 }
        let mm = CGDisplayScreenSize(id)
        guard mm.width > 0 else { return 60 }
        let diagonalInches = (mm.width * mm.width + mm.height * mm.height).squareRoot() / 25.4
        return min(max(30 + 1.5 * diagonalInches, 45), 80)
    }

    /// Reading Size shows body text as large as type of this size printed and held at 40 cm,
    /// whatever its size in the PDF (10 pt papers as before, 12 pt ones smaller, posters much smaller).
    private static let referenceTypeSize: CGFloat = 8.7
    /// … but a text block wider than this many type sizes (single-column papers: 32–42; two
    /// columns of small type: 55–66) is shown no wider than this, so small type set in long lines
    /// isn't enlarged into very wide ones.
    private static let maxBlockWidthInTypeSizes: CGFloat = 55

    /// Reading Size, times the user's own preference. Falls back to the printed size when the text
    /// can't be measured.
    private func readingScale(for screen: NSScreen?) -> CGFloat {
        var scale = Self.paperScale(for: screen) * Self.viewingDistance(for: screen) / 40 * ReadingSizeStore.factor
        if let size = bodyTypeSize {
            var correction = Self.referenceTypeSize / size
            if let column = textColumn {
                correction = min(correction, Self.maxBlockWidthInTypeSizes * Self.referenceTypeSize / (column.maxX - column.minX))
            }
            scale *= min(max(correction, 0.2), 2.5)
        }
        return scale
    }

    /// Measures the body text on a few early pages: the median type size of long lines (body text,
    /// not headings or captions) and the horizontal extent of the text block (ignoring outliers such
    /// as margin notes or page numbers). The type size, not the height of the line boxes: that
    /// comes from the font's declared height and is off by up to half in either direction (Lang and
    /// Tavares: 9.5 pt type in 14.3-point boxes; Campante: 12 pt in 10.6). Box heights only when
    /// PDFKit reports no type size.
    private static func measureText(_ doc: PDFDocument) -> (typeSize: CGFloat?, column: (minX: CGFloat, maxX: CGFloat)?) {
        let count = doc.pageCount
        let indices = count <= 1 ? [0] : Array(1..<min(count, 7))
        var heights: [CGFloat] = []
        var typeSizes: [CGFloat] = []
        var lefts: [CGFloat] = []
        var rights: [CGFloat] = []
        for index in indices {
            guard let page = doc.page(at: index),
                  let selection = page.selection(for: page.bounds(for: .mediaBox)) else { continue }
            for line in selection.selectionsByLine() {
                guard let text = line.string, text.trimmingCharacters(in: .whitespaces).count >= 40 else { continue }
                let bounds = line.bounds(for: page)
                if bounds.height > 2 && bounds.height < 40 {
                    heights.append(bounds.height)
                    if let string = line.attributedString, string.length > 0,
                       let font = string.attribute(.font, at: string.length / 2, effectiveRange: nil) as? NSFont,
                       font.pointSize > 2 && font.pointSize < 40 {
                        typeSizes.append(font.pointSize)
                    }
                }
                lefts.append(bounds.minX)
                rights.append(bounds.maxX)
            }
        }
        guard heights.count >= 10 else { return (nil, nil) }
        heights.sort()
        typeSizes.sort()
        lefts.sort()
        rights.sort()
        let minX = lefts[lefts.count / 10]
        let maxX = rights[rights.count * 9 / 10]
        let column: (minX: CGFloat, maxX: CGFloat)? = maxX - minX > 100 ? (minX, maxX) : nil
        let size = typeSizes.count >= 10 ? typeSizes[typeSizes.count / 2] : heights[heights.count / 2]
        return (size, column)
    }

    /// First layout after opening: apply the zoom, then show the first page below the toolbar.
    @objc private func initialLayout() {
        applyZoomMode()
        if let first = pdfView.document?.page(at: 0) { pdfView.go(to: first) }
    }

    @objc private func applyZoomModeAction() {
        applyZoomMode()
    }

    /// Re-fit once, after the current layout pass, however many triggers arrive
    /// (resizing, display or backing-scale changes, PDFKit's own zoom changes).
    @objc private func scheduleZoomUpdate(_ sender: Any? = nil) {
        if let note = sender as? Notification { debugLog("trigger \(note.name.rawValue)") }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(applyZoomModeAction), object: nil)
        perform(#selector(applyZoomModeAction), with: nil, afterDelay: 0)
    }

    /// A zoom we didn't make ourselves (e.g. pinching the trackpad) ends the fit mode.
    @objc private func scaleChanged(_ note: Notification) {
        fitSplitPane()   // the pane follows the main view's zoom
        guard !isApplyingZoom, abs(pdfView.scaleFactor - lastFittedScale) > 0.001 else { return }
        let type = NSApp.currentEvent?.type
        if type == .magnify || type == .smartMagnify {
            // A real zoom gesture ends the mode.
            zoomMode = .custom
            updatePositionUI()
        } else if zoomMode != .custom {
            // PDFKit changed the zoom itself (e.g. after moving to another display): restore the mode.
            scheduleZoomUpdate()
        }
    }

    // MARK: Link previews
    //
    // Hovering over an internal link (e.g. "Figure 3", a citation, a section reference) shows its
    // target in a popover. The mouse can move into the popover to scroll; a click there jumps.

    private var previewPopover: NSPopover?
    private var pendingLink: LinkTarget?
    private var shownLink: PDFAnnotation?
    private var shownTarget: LinkTarget?

    static func isUsableLink(_ annotation: PDFAnnotation) -> Bool {
        ReferenceDetector.isUsableLink(annotation)
    }

    /// The PDF view (main or split pane), page and page point under the mouse.
    private func pageUnderMouse() -> (PDFView, PDFPage, NSPoint)? {
        guard let window else { return nil }
        for view in [pdfView] + (splitPane.map { [$0] } ?? []) {
            let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard view.bounds.contains(point), let page = view.page(for: point, nearest: false) else { continue }
            return (view, page, view.convert(point, to: page))
        }
        return nil
    }

    private func linkUnderMouse() -> LinkTarget? {
        guard let hit = pageUnderMouse() else { return nil }
        let (view, page, pagePoint) = hit
        guard let annotation = ReferenceDetector.link(on: page, at: pagePoint) ?? page.annotation(at: pagePoint),
              Self.isUsableLink(annotation),
              let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination,
              destination.page != nil else { return nil }
        return LinkTarget(view: view, annotation: annotation, page: page, destination: destination)
    }

    private var mouseIsInPreview: Bool {
        guard let popover = previewPopover, popover.isShown,
              let frame = popover.contentViewController?.view.window?.frame else { return false }
        return frame.contains(NSEvent.mouseLocation)
    }

    private var lastPreviewDistance = CGFloat.greatestFiniteMagnitude
    private var closingPopovers: [NSPopover] = []

    @objc private func popoverDidClose(_ note: Notification) {
        guard let popover = note.object as? NSPopover else { return }
        NotificationCenter.default.removeObserver(self, name: NSPopover.didCloseNotification, object: popover)
        closingPopovers.removeAll { $0 === popover }
    }

    /// Distance from the mouse to the popover, in screen points.
    private func distanceToPreview() -> CGFloat {
        guard let frame = previewPopover?.contentViewController?.view.window?.frame else { return .greatestFiniteMagnitude }
        let p = NSEvent.mouseLocation
        let dx = max(frame.minX - p.x, 0, p.x - frame.maxX)
        let dy = max(frame.minY - p.y, 0, p.y - frame.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Sets the cursor PDFKit would show (link hand, I-beam over text). Returns false when the
    /// mouse isn't over a page, so the event goes on as usual.
    private func updateCursorOverPages() -> Bool {
        guard let hit = pageUnderMouse() else { return false }
        let page = hit.1, pagePoint = hit.2
        if let annotation = ReferenceDetector.link(on: page, at: pagePoint) ?? page.annotation(at: pagePoint),
           annotation.type == "Link" {
            NSCursor.pointingHand.set()
        } else if let line = page.selectionForLine(at: pagePoint),
                  line.bounds(for: page).insetBy(dx: -3, dy: -2).contains(pagePoint) {
            // Anywhere on a line of text, including between words, like Preview.
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
        return true
    }

    /// PDFKit shows a "Go to page N" tooltip on links, which only duplicates the link preview.
    /// There's no setting for it; it comes from tooltip areas on PDFKit's page views, which it
    /// recreates as pages appear, so they are removed again whenever the view scrolls.
    private func removePDFKitToolTips() {
        func strip(_ view: NSView) {
            view.removeAllToolTips()
            view.subviews.forEach(strip)
        }
        strip(pdfView)
        if let splitPane { strip(splitPane) }
    }

    private func handleMouseMoved() {
        if heldHint != nil || commentPopover?.isShown == true { return }
        if updateCommentHover() { return }     // a held link hint shows its preview until the key is released
        // Also the URL tooltip of a link PDFKit made from text; a real web link keeps its tooltip.
        if linkUnderMouse() != nil { removePDFKitToolTips() }
        else if let hit = pageUnderMouse(), WebLinkFilter.webLink(on: hit.1, at: hit.2) == nil { removePDFKitToolTips() }
        // Track the distance on every move (also while on the link), so the first move off the
        // link already tells whether the mouse is heading for the popover.
        let previousDistance = lastPreviewDistance
        lastPreviewDistance = previewPopover?.isShown == true ? distanceToPreview() : .greatestFiniteMagnitude
        if mouseIsInPreview {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(closePreviewIfIdle), object: nil)
            return
        }
        guard window?.isKeyWindow == true else { return }
        let target = linkUnderMouse()
        if let target, target.annotation === shownLink, previewPopover?.isShown == true {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(closePreviewIfIdle), object: nil)
            return
        }
        if let target {
            guard pendingLink?.annotation !== target.annotation else { return }
            pendingLink = target
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(showPendingPreview), object: nil)
            // Quick to switch from one preview to the next; a short delay before the first one.
            perform(#selector(showPendingPreview), with: nil, afterDelay: previewPopover?.isShown == true ? 0.15 : 0.5)
        } else {
            pendingLink = nil
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(showPendingPreview), object: nil)
            if previewPopover?.isShown == true {
                // Heading for the popover: a grace period to get there. Moving elsewhere: close soon.
                let approaching = distanceToPreview() < previousDistance
                NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(closePreviewIfIdle), object: nil)
                if approaching {
                    perform(#selector(closePreviewIfIdle), with: nil, afterDelay: 0.3)
                } else {
                    closePreview()
                }
            }
        }
    }

    @objc private func showPendingPreview() {
        // ⌘ held: about to ⌘-click into the split view, no preview needed.
        guard !NSEvent.modifierFlags.contains(.command) else { pendingLink = nil; return }
        guard let target = pendingLink, linkUnderMouse()?.annotation === target.annotation else { return }
        presentPreview(for: target)
    }

    private func presentPreview(for target: LinkTarget) {
        guard let doc = pdfView.document else { return }
        closePreview()
        let controller = LinkPreviewController(document: doc, destination: target.destination, column: textColumn,
                                               placement: Self.placement(for: target.destination),
                                               mainScale: target.view.scaleFactor, available: pdfView.bounds.size)
        controller.onOpen = { [weak self] inSplit in self?.openPreviewTarget(target, inSplit: inSplit) }
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .semitransient
        // On dark pages a light popover shows only its tip and scroll bar: a dark one has an edge.
        popover.appearance = PageTheme.current.inverts ? NSAppearance(named: .darkAqua) : nil
        popover.contentSize = controller.view.frame.size
        // The system's opening animation sometimes draws a shrunken copy of the popover in the
        // wrong place (when the popover has to be shifted sideways to fit). So open without it and
        // fade in ourselves; closing keeps the system's fade-out.
        popover.animates = false
        let rect = target.view.convert(target.annotation.bounds, from: target.page)
        popover.show(relativeTo: rect, of: target.view, preferredEdge: .maxY)
        popover.animates = true
        if let popoverWindow = controller.view.window {
            popoverWindow.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                popoverWindow.animator().alphaValue = 1
            }
        }
        previewPopover = popover
        shownLink = target.annotation
        shownTarget = target
    }

    /// hyperref puts a float's anchor at its top (with hypcap, the caption package's default) or at
    /// its caption. A top anchor or a table caption (tables are captioned above) can go at the top
    /// of the preview; a figure caption sits below its figure, so the figure is shown above it.
    private static func placement(for destination: PDFDestination) -> LinkPreviewController.Placement {
        guard let page = destination.page, page.rotation == 0 else { return .top }
        let bounds = page.bounds(for: .mediaBox)
        let y = min(destination.point.y, bounds.maxY)
        let pattern = #"(?m)^\s*(Figure|Fig\.|Abbildung|Abb\.)\s*[0-9A-Z]"#
        func hasCaption(_ rect: NSRect) -> Bool {
            page.selection(for: rect)?.string?.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        // The caption: at the target, or a little below it (some PDFs point into the figure,
        // e.g. Dell's, about 80 points above the caption).
        var captionY: CGFloat?
        if hasCaption(NSRect(x: bounds.minX, y: y - 40, width: bounds.width, height: 50)) {
            captionY = y
        } else {
            var d: CGFloat = 0
            while d < 220, y - d - 14 > bounds.minY {
                let band = NSRect(x: bounds.minX, y: y - d - 14, width: bounds.width, height: 14)
                if hasCaption(band) { captionY = y - d; break }
                // Running text: the target isn't in a figure ("Figure 3 shows …" further down
                // is a sentence, not a caption).
                if (page.selection(for: band)?.string?.filter { !$0.isWhitespace }.count ?? 0) > 60 { break }
                d += 8
            }
        }
        guard let captionY else {
            // Equations get the same small margin as everything else: better that the eye lands on
            // the right equation than that a tall one is shown whole (scrolling up is easy).
            return .top
        }

        // Which side is the figure on? Body text is a dense line in the page's main font; a
        // chart has a few labels, usually in another font or size (or none: an image).
        var bodyFont: (name: String, size: CGFloat)?
        if let attributed = page.attributedString {
            var counts: [String: Int] = [:]
            var sizes: [String: CGFloat] = [:]
            attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                guard let font = value as? NSFont else { return }
                let key = font.fontName + " " + String(Int((font.pointSize * 2).rounded()))
                counts[key, default: 0] += range.length
                sizes[key] = font.pointSize
            }
            if let top = counts.max(by: { $0.value < $1.value }) {
                bodyFont = (String(top.key.split(separator: " ").dropLast().joined(separator: " ")), sizes[top.key] ?? 0)
            }
        }
        func characters(_ rect: NSRect) -> Int {
            guard let attributed = page.selection(for: rect)?.attributedString else { return 0 }
            var count = 0
            attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                guard let font = value as? NSFont else { return }
                // (The same family counts: italics and bold in running text.)
                if let bodyFont {
                    let family = { (name: String) -> String in
                        let base = name.split(separator: "+").last.map(String.init) ?? name   // "ABCDEF+Times-Roman"
                        return base.split(separator: "-").first.map(String.init) ?? base
                    }
                    guard family(font.fontName) == family(bodyFont.name), abs(font.pointSize - bodyFont.size) <= 1 else { return }
                }
                count += (attributed.string as NSString).substring(with: range).filter { !$0.isWhitespace }.count
            }
            return count
        }
        // The text column's width: what most full lines on the page span.
        let pageLines = (page.selection(for: bounds)?.selectionsByLine() ?? []).map { $0.bounds(for: page) }
        let lineWidths = pageLines.map(\.width).filter { $0 > 50 }.sorted()
        let columnWidth = lineWidths.isEmpty ? bounds.width * 0.6 : lineWidths[lineWidths.count * 8 / 10]
        // A line of body text: in the body font and across most of the column. (Panel titles,
        // axis labels and legends inside a figure are short or sparse.)
        // (Or a paragraph's short last line, "experiment).": starting at the column's left edge,
        // where panel titles inside a figure are usually centered.)
        var leftEdges: [Int: Int] = [:]
        for line in pageLines where line.width >= columnWidth * 0.8 { leftEdges[Int(line.minX / 3), default: 0] += 1 }
        let columnLeft = leftEdges.max { $0.value < $1.value }.map { CGFloat($0.key) * 3 }
        func isWideBodyLine(_ rect: NSRect) -> Bool {
            guard characters(rect) > 35, let selection = page.selection(for: rect) else { return false }
            return selection.selectionsByLine().contains { $0.bounds(for: page).width >= columnWidth * 0.8 }
        }
        func isBodyLine(_ rect: NSRect) -> Bool {
            if isWideBodyLine(rect) { return true }
            // A short line at the column's left edge counts only as the end of a paragraph, with
            // a full line right above it ("Panel A. …" in a figure has none).
            guard let columnLeft, characters(rect) > 6, let selection = page.selection(for: rect) else { return false }
            return selection.selectionsByLine().contains { line in
                let lineBounds = line.bounds(for: page)
                guard abs(lineBounds.minX - columnLeft) <= 4, lineBounds.height > 0 else { return false }
                let above = NSRect(x: bounds.minX, y: lineBounds.maxY + 1, width: bounds.width, height: lineBounds.height * 1.2)
                return isWideBodyLine(above)
            }
        }
        // The figure's top: going up from the caption, the first line of body text, or the page top.
        var top = captionY
        while top < bounds.maxY - 6 {
            if isBodyLine(NSRect(x: bounds.minX, y: top + 2, width: bounds.width, height: 10)) { break }
            top += 6
        }
        // Nothing at all between the caption and the page top: just the margin, no figure.
        if top >= bounds.maxY - 6,
           (page.selection(for: NSRect(x: bounds.minX, y: captionY + 2, width: bounds.width, height: bounds.maxY - captionY - 2))?
               .string?.filter { !$0.isWhitespace }.count ?? 0) == 0 {
            return captionY == y ? .top : .figure(top: captionY, caption: captionY)
        }
        // A figure at the page top: stop below the running header (journal, page number).
        if top >= bounds.maxY - 6, let header = pageLines.max(by: { $0.maxY < $1.maxY }),
           header.minY > bounds.maxY - bounds.height * 0.1, header.minY > captionY {
            top = header.minY - 12   // (the preview adds 10 points above)
        }
        // Text right above the caption (or the page top): the caption sits above its figure,
        // so show it at the top.
        if top - captionY <= 20 || captionY > bounds.maxY - 60 {
            return captionY == y ? .top : .figure(top: captionY, caption: captionY)
        }
        return .figure(top: top, caption: captionY)
    }

    @objc private func closePreviewIfIdle() {
        guard !mouseIsInPreview, linkUnderMouse()?.annotation !== shownLink else { return }
        closePreview()
    }

    private func closePreview() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(closePreviewIfIdle), object: nil)
        lastPreviewDistance = .greatestFiniteMagnitude
        if let popover = previewPopover, popover.isShown {
            // Keep the popover (and its PDF view) alive until its fade-out has finished; releasing
            // it mid-animation leaves an empty white window flashing somewhere on screen.
            closingPopovers.append(popover)
            NotificationCenter.default.addObserver(self, selector: #selector(popoverDidClose(_:)),
                                                   name: NSPopover.didCloseNotification, object: popover)
            popover.close()
        }
        previewPopover = nil
        shownLink = nil
        shownTarget = nil
    }

    /// A click in the preview: jump where the link is (main view or split pane); with ⌘, show
    /// the target in the split pane.
    private func openPreviewTarget(_ target: LinkTarget, inSplit: Bool) {
        closePreview()
        if inSplit {
            openSplit(at: target.destination)
        } else if target.view === pdfView {
            recordJump()
            pdfView.go(to: target.destination)
            perform(#selector(alignHorizontallyAction), with: nil, afterDelay: 0)
        } else {
            target.view.reveal(target.destination, column: textColumn, placement: Self.placement(for: target.destination))
        }
    }

    // MARK: Link hints (R, as in \ref)
    //
    // Every internal link on screen gets a short label; typing it opens the target in the split
    // view (with ⇧: jumps there). Esc cancels.

    private var hintOverlays: [NSView] = []
    private var hintOverlay: NSView? { hintOverlays.first }
    private var hints: [(label: HintLabel, target: LinkTarget)] = []
    private var typedHint = ""

    private func showLinkHints() {
        closePreview()
        var found: [LinkTarget] = []
        for view in [pdfView] + (splitPane.map { [$0] } ?? []) {
            var visible = view.bounds
            visible.size.height -= view.safeAreaInsets.top
            if !view.isFlipped { visible.origin.y = 0 } else { visible.origin.y = view.safeAreaInsets.top }
            var inView: [(LinkTarget, NSRect)] = []
            for page in view.visiblePages {
                for annotation in page.annotations where !ReferenceDetector.groupLinks.contains(annotation) {
                    guard let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination,
                          destination.page != nil else { continue }
                    let rect = view.convert(annotation.bounds, from: page)
                    guard visible.intersects(rect), Self.isUsableLink(annotation),
                          !ReferenceDetector.isInReferenceList(page, y: annotation.bounds.midY) else { continue }
                    // A link broken across two lines is two annotations: label it once. The second
                    // part sits on the next line, starting further left. (Only matching the target
                    // is not enough: some PDFs point every citation to the same spot.)
                    // The first part also has to end at the right edge of the text column, and the
                    // second start at its left edge ([20] at a line end and [21] below it are two links).
                    let columnEdges = self.textColumn.map { column -> (left: CGFloat, right: CGFloat) in
                        let left = view.convert(NSPoint(x: column.minX, y: 0), from: page).x
                        let right = view.convert(NSPoint(x: column.maxX, y: 0), from: page).x
                        return (left, right)
                    }
                    if let edges = columnEdges, inView.contains(where: { previous in
                        let (earlier, earlierRect) = previous
                        let slack = (edges.right - edges.left) * 0.04
                        return earlier.destination.page == destination.page
                            && abs(earlier.destination.point.y - destination.point.y) < 1
                            && rect.maxY <= earlierRect.midY
                            && earlierRect.minY - rect.maxY < rect.height
                            && earlierRect.maxX > edges.right - slack
                            && rect.minX < edges.left + slack
                    }) { continue }
                    // One link split into pieces on the same line ("equation" + "(4)"): label once.
                    if inView.contains(where: { previous in
                        let (earlier, earlierRect) = previous
                        return earlier.destination.page == destination.page
                            && abs(earlier.destination.point.y - destination.point.y) < 1
                            && abs(earlierRect.midY - rect.midY) < rect.height / 2
                            && (rect.minX - earlierRect.maxX < 12 && earlierRect.minX - rect.maxX < 12)
                    }) { continue }
                    inView.append((LinkTarget(view: view, annotation: annotation, page: page, destination: destination), rect))
                }
            }
            // Reading order: top to bottom, then left to right.
            inView.sort { abs($0.1.midY - $1.1.midY) > 3 ? $0.1.midY > $1.1.midY : $0.1.minX < $1.1.minX }
            found += inView.map { $0.0 }
        }
        guard !found.isEmpty else { NSSound.beep(); return }

        // One overlay per PDF view. (Not on the window's content view: that's a split view, which
        // would treat the overlay as another pane and move it.)
        var overlays: [PassthroughView] = []
        func overlay(for view: PDFView) -> PassthroughView {
            if let existing = overlays.first(where: { $0.superview === view }) { return existing }
            let new = PassthroughView(frame: view.bounds)
            new.autoresizingMask = [.width, .height]
            view.addSubview(new)
            overlays.append(new)
            return new
        }
        let labels = HintLabel.labels(count: found.count)
        hints = []
        for (target, text) in zip(found, labels) {
            let label = HintLabel(text: text)
            let overlay = overlay(for: target.view)
            let rect = overlay.convert(target.view.convert(target.annotation.bounds, from: target.page), from: target.view)
            // Just above the start of the link, like a tag, so the link text stays readable.
            // (From the middle of the link: Galley's own links span the whole line height, so
            // their top edge sits well above the text.)
            // Footnote marks (a short run of digits or symbols, raised above the text): over the
            // top of the line, so the mark stays visible.
            let linkText = target.page.selection(for: target.annotation.bounds)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let isMark = !linkText.isEmpty && linkText.count <= 3
                && !linkText.contains(where: { $0.isLetter }) && !linkText.contains(".")
            let y = isMark ? rect.maxY - 2 : rect.midY + min(rect.height / 2 - 4, 4 * target.view.scaleFactor)
            label.setFrameOrigin(NSPoint(x: rect.minX - 3, y: y))
            overlay.addSubview(label)
            hints.append((label, target))
        }
        hintOverlays = overlays
        typedHint = ""
    }

    private func hideLinkHints() {
        hintOverlays.forEach { $0.removeFromSuperview() }
        hintOverlays = []
        hints = []
        typedHint = ""
    }

    private func handleHintKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        if event.keyCode == 53 { hideLinkHints(); return true }          // Esc
        if event.keyCode == 51 {                                           // Backspace
            typedHint = String(typedHint.dropLast())
        } else {
            if event.charactersIgnoringModifiers?.lowercased() == "r", flags.isSubset(of: .shift) {
                hideLinkHints()                                            // R again: hide
                return true
            }
            // Anything that can't be part of a label (arrows, Space, digits, ⌘-shortcuts, …) ends
            // the labels and then does its usual job.
            guard event.specialKey == nil, flags.isSubset(of: .shift),
                  let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1,
                  hints.contains(where: { $0.label.text.contains(key) }) else {
                hideLinkHints()
                return false
            }
            typedHint += key
        }
        let matching = hints.filter { $0.label.text.hasPrefix(typedHint) }
        if matching.isEmpty { NSSound.beep(); hideLinkHints(); return true }
        if let exact = matching.first(where: { $0.label.text == typedHint }) {
            let target = exact.target
            hideLinkHints()
            if flags.contains(.shift) {
                openPreviewTarget(target, inSplit: false)          // ⇧: jump
            } else {
                // Decided on release: a tap opens the split view, holding shows the preview.
                heldHint = (target, event.keyCode)
                perform(#selector(showHeldHintPreview), with: nil, afterDelay: 0.3)
            }
            return true
        }
        for hint in hints {
            let matches = hint.label.text.hasPrefix(typedHint)
            hint.label.isHidden = !matches
            if matches { hint.label.show(typed: typedHint) }
        }
        return true
    }

    /// The link hint whose last letter is being held, and that key.
    private var heldHint: (target: LinkTarget, keyCode: UInt16)?
    private var heldHintPreviewShown = false

    @objc private func showHeldHintPreview() {
        guard let held = heldHint else { return }
        heldHintPreviewShown = true
        presentPreview(for: held.target)
    }

    /// While a label's last letter is down: swallow its repeats; on release, open the split view
    /// (tap) or close the preview (hold). Any other key ends the hold first.
    private func handleHeldHintKey(_ event: NSEvent) -> Bool {
        guard let held = heldHint else { return false }
        if event.keyCode == held.keyCode {
            if event.type == .keyDown { return true }                 // key repeat
            if event.type == .keyUp {
                endHeldHint()
                if heldHintPreviewShown {
                    closePreview()
                } else {
                    openPreviewTarget(held.target, inSplit: true)
                }
                heldHintPreviewShown = false
                return true
            }
            return false
        }
        if event.type == .flagsChanged { return false }
        endHeldHint()
        if heldHintPreviewShown { closePreview(); heldHintPreviewShown = false }
        return false
    }

    private func endHeldHint() {
        heldHint = nil
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(showHeldHintPreview), object: nil)
    }

    // MARK: Split view (⌥⌘S)
    //
    // A second view of the same document, beside the main view on wide windows, below it on
    // narrow ones. Its text column fills its width. ⌘-click on a link (or in a link preview)
    // shows the target there; links clicked inside the pane jump within the pane.

    /// Single-letter shortcuts (no text field has focus here). Not in the menus: a key equivalent
    /// without a modifier would also fire while typing in the search field.
    private func handleSingleKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        // + / −: zoom like ⌘+ / ⌘− (held down, it keeps zooming).
        let character = event.charactersIgnoringModifiers ?? ""
        let plainOrShift = flags.isEmpty || flags == .shift     // "+" needs ⇧ on some layouts
        if plainOrShift && (character == "+" || character == "=") { zoomInAction(nil); return true }
        if plainOrShift && (character == "-" || character == "_") { zoomOutAction(nil); return true }
        guard !event.isARepeat else { return false }
        if event.characters == "/", flags.isSubset(of: .shift) {     // ⇧7 on German keyboards
            focusSearch(nil)
            return true
        }
        if event.characters == "?", flags.isSubset(of: .shift) {     // ⇧ß on German keyboards
            NSApp.sendAction(#selector(AppDelegate.showShortcutsAction(_:)), to: nil, from: nil)
            return true
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if let kind = [SwitcherKind.zoom, .pageTheme].first(where: { $0.key == key }), flags.isEmpty || flags == .shift {
            switcherByKey = true
            advanceSwitcher(kind, by: flags == .shift ? -1 : 1)
            if switcherOverlay != nil { scheduleSwitcherCommit() } else { switcherByKey = false }
            return true
        }
        guard flags.isEmpty else { return false }
        switch key {
        case "b": (window?.contentViewController as? NSSplitViewController)?.toggleSidebar(nil)
        case "s":
            // With a link preview showing: its target in the split view (opened if needed).
            if previewPopover?.isShown == true, let target = shownTarget {
                openPreviewTarget(target, inSplit: true)
            } else {
                toggleSplitViewAction(nil)
            }
        case "f": focusSearch(nil)
        case "g": goToPageAction(nil)
        case "m": highlightSelectionAction(nil)
        case "u": underlineSelectionAction(nil)
        case "1", "2", "3", "4", "5", "6", "7", "8": chooseColor(Int(key)! - 1)
        case "a": commentAction(nil)
        case "r": showLinkHints()
        default: return false
        }
        return true
    }

    @objc func showOutlineAction(_ sender: Any?) { showSidebarMode(.outline) }
    @objc func showThumbnailsAction(_ sender: Any?) { showSidebarMode(.thumbnails) }

    private func showSidebarMode(_ mode: SidebarMode) {
        model.sidebarMode = mode
        if let sidebarItem, sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = false }
    }

    /// H J K L as arrow keys (not with ⌘ or ⌃, which mean something else).
    private static func vimArrow(for event: NSEvent, flags: NSEvent.ModifierFlags) -> NSEvent.SpecialKey? {
        guard flags.isDisjoint(with: [.command, .control]),
              let character = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        switch character {
        case "h": return .leftArrow
        case "j": return .downArrow
        case "k": return .upArrow
        case "l": return .rightArrow
        default: return nil
        }
    }

    private var isSplitFocused: Bool {
        guard let pane = splitPane, let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: pane)
    }

    @objc func toggleSplitViewAction(_ sender: Any?) {
        if splitPane != nil { closeSplit() } else { openSplit(at: nil) }
    }

    @objc func toggleSplitOrientationAction(_ sender: Any?) {
        guard splitPane != nil else { NSSound.beep(); return }
        splitIsStacked = !(splitIsStacked ?? false)
        userChoseOrientation = true   // kept for this window from now on
        arrangeSplit()
    }

    /// Opens the pane if needed and shows `destination` there (nil: where the main view is).
    private func openSplit(at destination: PDFDestination?, placement: LinkPreviewController.Placement? = nil) {
        guard let doc = pdfView.document else { return }
        let isNew = splitPane == nil
        if isNew {
            let pane = PDFView(frame: .zero)
            pane.displayMode = .singlePageContinuous
            pane.displaysPageBreaks = true
            pane.enableDataDetectors = false
            pane.delegate = WebLinkFilter.shared
            pane.pageOverlayViewProvider = PagePaper.shared
            pane.autoScales = false
            pane.backgroundColor = Self.canvasColor
            pane.document = doc
            pane.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(splitPaneResized(_:)),
                                                   name: NSView.frameDidChangeNotification, object: pane)
            let paneVC = NSViewController()
            paneVC.view = pane
            let item = NSSplitViewItem(viewController: paneVC)
            item.minimumThickness = 200
            item.canCollapse = true      // dragging the divider to the edge closes the pane
            documentSplit.addSplitViewItem(item)
            splitPaneItem = item
            splitPane = pane
            if !userChoseOrientation {
                let size = documentSplit.splitView.bounds.size
                splitIsStacked = size.width < size.height   // stacked only in a portrait-shaped area
            }
            arrangeSplit()
            // Refit the main view to its new half right away (not on the next pass), so the pane
            // is set up once, at its final zoom.
            if zoomMode != .custom { applyZoomMode() }
        }
        guard let pane = splitPane else { return }
        fitSplitPane()
        if let destination {
            pane.reveal(destination, column: textColumn, placement: placement ?? Self.placement(for: destination))
        } else {
            mirrorMainPosition()
        }
        if isNew { coverPaneWhileRendering() }
    }

    // ⌘ with an outline entry, a thumbnail, a search result or Go to Page: the target in the split
    // pane, as ⌘-click does for links. The main view stays where it is.

    func showInSplit(_ node: OutlineNode) {
        guard let doc = pdfView.document, let index = node.pageIndex, let page = doc.page(at: index),
              let y = targetY(for: node) else { return }
        // `reveal` adds about a line above the anchor, so the heading lands where `go(to:)` puts it.
        openSplit(at: PDFDestination(page: page, at: NSPoint(x: 0, y: y - 10)), placement: .top)
    }

    func showPageInSplit(_ index: Int) {
        guard let page = pdfView.document?.page(at: index) else { return }
        openSplit(at: PDFDestination(page: page, at: NSPoint(x: 0, y: page.bounds(for: .mediaBox).maxY)), placement: .top)
    }

    private func showInSplit(_ selection: PDFSelection) {
        guard let page = selection.pages.first else { return }
        let bounds = selection.bounds(for: page)
        openSplit(at: PDFDestination(page: page, at: NSPoint(x: bounds.minX, y: bounds.maxY)), placement: .top)
        splitPane?.setCurrentSelection(selection, animate: true)
    }

    /// PDFKit draws a new view's pages in the background, tile by tile, so a fresh pane is blank
    /// for a moment. Cover it with a quick picture of the visible pages until PDFKit has caught up.
    private var splitCover: NSView?

    private func coverPaneWhileRendering() {
        guard let pane = splitPane, let screen = pane.window?.screen ?? NSScreen.main else { return }
        pane.layoutDocumentView()
        let scale = screen.backingScaleFactor
        let cover = NSView(frame: pane.bounds)
        cover.autoresizingMask = [.width, .height]
        for page in pane.visiblePages {
            let box = page.bounds(for: .mediaBox)
            let rect = pane.convert(box, from: page)
            guard rect.intersects(pane.bounds), rect.width > 1 else { continue }
            let image = page.thumbnail(of: NSSize(width: rect.width * scale, height: rect.height * scale), for: .mediaBox)
            let imageView = NSImageView(frame: rect)
            imageView.imageScaling = .scaleAxesIndependently
            imageView.image = PageTheme.recolor(image)
            cover.addSubview(imageView)
        }
        guard !cover.subviews.isEmpty else { return }
        pane.addSubview(cover)
        splitCover = cover
        perform(#selector(removeSplitCover), with: nil, afterDelay: 0.4)
    }

    @objc private func removeSplitCover() {
        guard let cover = splitCover else { return }
        splitCover = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            cover.animator().alphaValue = 0
        }
        cover.perform(#selector(NSView.removeFromSuperview), with: nil, afterDelay: 0.2)
    }

    @objc private func documentSplitResized(_ note: Notification) {
        guard splitPaneItem?.isCollapsed == true else { return }
        // Not in the middle of the split view's own resizing.
        perform(#selector(closeCollapsedSplit), with: nil, afterDelay: 0)
    }

    @objc private func closeCollapsedSplit() {
        if splitPaneItem?.isCollapsed == true { closeSplit() }
    }

    /// Opening without a link: the pane starts exactly where the main view is.
    private func mirrorMainPosition() {
        guard let pane = splitPane, let doc = pdfView.document else { return }
        pane.layoutDocumentView()
        if abs(pane.scaleFactor - pdfView.scaleFactor) < 0.001,
           let main = Self.findScrollView(in: pdfView), let scroll = Self.findScrollView(in: pane) {
            // Same zoom, so the same document layout: copy the vertical scroll position.
            let clip = scroll.contentView
            var origin = clip.bounds.origin
            origin.y = main.contentView.bounds.origin.y
            if let documentView = scroll.documentView {
                origin.x = (documentView.bounds.width - clip.bounds.width) / 2   // centered
            }
            clip.setBoundsOrigin(clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
        } else if let top = visibleTop(), let page = doc.page(at: top.pageIndex) {
            pane.reveal(PDFDestination(page: page, at: NSPoint(x: 0, y: top.y)), column: textColumn, placement: .top)
        }
    }

    private func closeSplit() {
        guard let pane = splitPane else { return }
        closePreview()
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: pane)
        splitCover = nil
        if let item = splitPaneItem { documentSplit.removeSplitViewItem(item) }
        splitPaneItem = nil
        splitPane = nil
        window?.makeFirstResponder(pdfView)
    }

    /// Half and half, side by side or stacked.
    private func arrangeSplit() {
        guard let pane = splitPane else { return }
        let stacked = splitIsStacked ?? false
        let splitView = documentSplit.splitView
        splitView.isVertical = !stacked
        documentSplit.view.layoutSubtreeIfNeeded()
        let length = stacked ? splitView.bounds.height : splitView.bounds.width
        splitView.setPosition(((length - splitView.dividerThickness) / 2).rounded(), ofDividerAt: 0)
        documentSplit.view.layoutSubtreeIfNeeded()
        debugLog("split \(stacked ? "stacked" : "side by side"): container \(splitView.bounds), main \(pdfView.frame), pane \(pane.frame)")
        fitSplitPane()
    }

    /// The pane uses the main view's zoom, smaller only where its text column wouldn't fit.
    private func fitSplitPane() {
        guard let pane = splitPane, let fit = pane.textColumnScale(column: textColumn) else { return }
        let scale = min(pdfView.scaleFactor, fit)
        guard abs(pane.scaleFactor - scale) > 0.001 else { return }
        // Keep the spot in the middle of the pane where it is (going via PDFDestination drifts,
        // because of the toolbar inset and the margin reveal adds).
        let center = NSPoint(x: pane.bounds.midX, y: pane.bounds.midY)
        guard let page = pane.page(for: center, nearest: true) else { pane.scaleFactor = scale; return }
        let anchor = pane.convert(center, to: page)
        pane.scaleFactor = scale
        pane.layoutDocumentView()
        guard let scroll = Self.findScrollView(in: pane), let documentView = scroll.documentView else { return }
        let clip = scroll.contentView
        let anchorNow = documentView.convert(pane.convert(anchor, from: page), from: pane)
        let centerNow = documentView.convert(center, from: pane)
        var origin = clip.bounds.origin
        origin.y += anchorNow.y - centerNow.y
        if let column = textColumn {
            // Center the text column (it fills the width at Fit Text Width, has room otherwise).
            let middle = documentView.convert(pane.convert(NSPoint(x: (column.minX + column.maxX) / 2, y: anchor.y),
                                                           from: page), from: pane).x
            origin.x = middle - clip.bounds.width / 2
        }
        clip.setBoundsOrigin(clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    @objc private func splitPaneResized(_ note: Notification) {
        fitSplitPane()
    }

    @objc private func restoreSplitOrigin() {
        guard let origin = pendingSplitOrigin, let pane = splitPane,
              let scroll = Self.findScrollView(in: pane) else { return }
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Jump history (⌘⌥← / ⌘⌥→)
    //
    // Jumps are recorded, small movements (↑/↓ steps, pages, scrolling) are not. A quick run of
    // heading jumps counts as one jump, so Back returns to where the run started.

    private struct Position {
        let page: Int
        let y: CGFloat
    }

    private var backStack: [Position] = []
    private var forwardStack: [Position] = []
    private var lastJumpRecorded = Date.distantPast

    private func currentPosition() -> Position? {
        guard let top = visibleTop() else { return nil }
        return Position(page: top.pageIndex, y: top.y)
    }

    /// Call before a jump. `coalesce`: part of a quick run of similar jumps (e.g. repeated ⌥↓).
    private func recordJump(coalesce: Bool = false, from position: Position? = nil) {
        let now = Date()
        defer { lastJumpRecorded = now }
        if coalesce, now.timeIntervalSince(lastJumpRecorded) < 1.5 { return }
        guard let position = position ?? currentPosition() else { return }
        if let last = backStack.last, last.page == position.page, abs(last.y - position.y) < 5 { return }
        backStack.append(position)
        if backStack.count > 100 { backStack.removeFirst() }
        forwardStack.removeAll()
    }

    private func show(_ position: Position) {
        guard let doc = pdfView.document, doc.pageCount > 0,
              let page = doc.page(at: min(position.page, doc.pageCount - 1)) else { return }
        pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: position.y)))
        perform(#selector(alignHorizontallyAction), with: nil, afterDelay: 0)
    }

    @objc func historyBackAction(_ sender: Any?) {
        guard let target = backStack.popLast() else { NSSound.beep(); return }
        if let current = currentPosition() { forwardStack.append(current) }
        lastJumpRecorded = .distantPast
        show(target)
    }

    @objc func historyForwardAction(_ sender: Any?) {
        guard let target = forwardStack.popLast() else { NSSound.beep(); return }
        if let current = currentPosition() { backStack.append(current) }
        lastJumpRecorded = .distantPast
        show(target)
    }

    /// A deliberate jump to a heading (outline click): recorded in the history.
    func navigate(to node: OutlineNode) {
        recordJump()
        go(to: node)
    }

    // MARK: Keyboard navigation

    /// The same keys work whether the document or the sidebar has focus:
    /// ↑/↓ headings, ⌥↑/⌥↓ chapters, ←/→ and Page Up/Down pages, ⌥←/⌥→ collapse/expand.
    /// Returns true when the key was used.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])

        // Releasing ⌘ confirms a switcher, like ⌘Tab.
        if event.type == .flagsChanged {
            if switcherOverlay != nil && !switcherByKey && !flags.contains(.command) { commitSwitcher() }
            // ⌘ pressed over a link: the split view is next, so drop the preview (not when the
            // mouse is in the preview, where ⌘-click opens its target in the split).
            if flags.contains(.command), previewPopover?.isShown == true, !mouseIsInPreview { closePreview() }
            return false
        }
        if heldHint != nil, handleHeldHintKey(event) { return true }
        if event.type == .keyUp {
            if event.keyCode == holdKeyCode { releaseHoldScroll() }
            return false
        }
        if hintOverlay != nil, handleHintKey(event, flags: flags) { return true }
        if event.keyCode == 53, previewPopover?.isShown == true {
            closePreview()
            return true
        }
        // ⌘0 / ⌘9 (key positions of 0 and 9) open/advance the zoom / page colour switcher, with ⇧ back.
        if event.keyCode == 29 || event.keyCode == 25, flags == .command || flags == [.command, .shift] {
            let kind: SwitcherKind = event.keyCode == 29 ? .zoom : .pageTheme
            if switcherOverlay != nil && switcherKind != kind { hideSwitcher() }
            advanceSwitcher(kind, by: flags.contains(.shift) ? -1 : 1)
            return true
        }
        if switcherOverlay != nil {
            if switcherByKey {
                // Opened with Z or D: the same key steps on, Return confirms, Esc cancels; any
                // other key confirms and then does its usual job.
                let key = event.charactersIgnoringModifiers?.lowercased()
                if key == switcherKind.key && (flags.isEmpty || flags == .shift) {
                    advanceSwitcher(switcherKind, by: flags == .shift ? -1 : 1)
                    scheduleSwitcherCommit()
                    return true
                }
                if event.keyCode == 53 { hideSwitcher(); return true }
                commitSwitcher()
                if event.keyCode == 36 || event.keyCode == 76 { return true }
            } else {
                if event.keyCode == 53 { hideSwitcher() }       // Esc cancels
                return true
            }
        }

        if isSearchFieldFocused { return handleSearchKey(event, flags: flags) }
        guard !(window?.firstResponder is NSText) else { return false }   // typing in another text field

        if slideShowSaved != nil, handleSlideShowKey(event, flags: flags) { return true }

        // Space starts/stops auto-scroll; while it runs, + / − change its speed and Esc stops it.
        if event.keyCode == 49 {
            if !event.isARepeat && flags.isEmpty { toggleAutoScroll() }
            return true
        }
        if isAutoScrolling {
            let character = event.charactersIgnoringModifiers ?? ""
            let plainOrShift = flags.isEmpty || flags == .shift     // "+" needs ⇧ on some layouts
            if plainOrShift && (character == "+" || character == "=") { changeAutoScrollSpeed(by: Self.autoScrollStep); return true }
            if plainOrShift && (character == "-" || character == "_") { changeAutoScrollSpeed(by: 1 / Self.autoScrollStep); return true }
            stopAutoScroll()
            if event.keyCode == 53 { return true }          // Esc only stops
        }

        // Esc in the sidebar hands the focus back to the document.
        if event.keyCode == 53, isSidebarFocused {
            window?.makeFirstResponder(pdfView)
            return true
        }

        // Esc clears a text selection.
        if event.keyCode == 53, flags.isEmpty {
            let view = isSplitFocused ? splitPane ?? pdfView : pdfView
            if !(view.currentSelection?.string ?? "").isEmpty {
                view.clearSelection()
                return true
            }
        }

        // Esc with nothing else to dismiss closes the split view.
        if event.keyCode == 53, flags.isEmpty, splitPane != nil {
            closeSplit()
            return true
        }

        // Delete (⌫ or ⌦): removes the selected highlights (never adds one, unlike M).
        if event.keyCode == 51 || event.keyCode == 117, flags.isEmpty, removeSelectedHighlights() { return true }

        if handleSingleKey(event, flags: flags) { return true }

        // H J K L work like ← ↓ ↑ →, with the same modifiers (⌥J: next heading, …).
        let vimKey = Self.vimArrow(for: event, flags: flags)

        // A focused split pane takes the same keys as the main view (but keeps out of the history).
        let pane = isSplitFocused ? splitPane : nil

        guard let key = event.specialKey ?? vimKey else { return false }
        switch (key, flags) {
        // The document's structure, the same wherever the focus is.
        case (.downArrow, .option): return moveHeading(by: 1, chaptersOnly: false, in: pane)
        case (.upArrow, .option): return moveHeading(by: -1, chaptersOnly: false, in: pane)
        case (.downArrow, [.option, .shift]): return moveHeading(by: 1, chaptersOnly: true, in: pane)
        case (.upArrow, [.option, .shift]): return moveHeading(by: -1, chaptersOnly: true, in: pane)
        case (.pageDown, []): return movePage(by: 1, in: pane)
        case (.pageUp, []): return movePage(by: -1, in: pane)
        // ⌘⌥← / ⌘⌥→: back and forward through the jump history.
        case (.leftArrow, [.command, .option]):
            historyBackAction(nil)
            return true
        case (.rightArrow, [.command, .option]):
            historyForwardAction(nil)
            return true
        // ⌘↑ / ⌘↓ (and Home / End): the very beginning or end of the document.
        case (.upArrow, .command), (.home, []):
            if let pane { scrollBy(-1_000_000_000, animated: false, in: pane); return true }
            recordJump()
            scrollBy(-1_000_000_000, animated: false)
            alignHorizontally()
            return true
        case (.downArrow, .command), (.end, []):
            if let pane { scrollBy(1_000_000_000, animated: false, in: pane); return true }
            recordJump()
            scrollBy(1_000_000_000, animated: false)
            alignHorizontally()
            return true
        default: break
        }

        if isSidebarFocused, model.sidebarMode == .thumbnails, model.searchText.isEmpty {
            // Thumbnails: ↑/↓ like ←/→, one page at a time.
            switch (key, flags) {
            case (.downArrow, []), (.rightArrow, []): return movePage(by: 1)
            case (.upArrow, []), (.leftArrow, []): return movePage(by: -1)
            default: return false
            }
        }

        if isSidebarFocused {
            // A focused sidebar behaves like any Mac list.
            switch (key, flags) {
            case (.downArrow, []): return moveInSidebar(by: 1)
            case (.upArrow, []): return moveInSidebar(by: -1)
            case (.rightArrow, []): return expandOrDescend()
            case (.leftArrow, []): return collapseOrAscend()
            default: return false
            }
        }

        // The document: small steps and pages.
        switch (key, flags) {
        case (.downArrow, []): return beginScrollStep(1, event: event, in: pane ?? pdfView)
        case (.upArrow, []): return beginScrollStep(-1, event: event, in: pane ?? pdfView)
        case (.rightArrow, []): return movePage(by: 1, in: pane)
        case (.leftArrow, []): return movePage(by: -1, in: pane)
        default: return false
        }
    }

    // MARK: Smooth scrolling

    private var scrollTarget: NSPoint?
    private weak var scrollTargetClip: NSClipView?       // whose target it is (main view or split pane)
    private var scrollAnimationEnds = Date.distantPast
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    /// Distance from one line of body text to the next, in view points (about 1.35 × the type size).
    private var linePitch: CGFloat { linePitch(in: pdfView) }

    private func linePitch(in view: PDFView) -> CGFloat {
        (bodyTypeSize ?? 10) * 1.35 * view.scaleFactor
    }

    /// Scrolls by `distance` view points (positive = down). Animated steps ease in and out;
    /// quick repeated presses add up instead of restarting from the half-finished position.
    private func scrollBy(_ distance: CGFloat, animated: Bool, in view: PDFView? = nil) {
        guard let scroll = Self.findScrollView(in: view ?? pdfView) else { return }
        let clip = scroll.contentView
        guard clip.frame.height > 0 else { return }
        let ratio = clip.bounds.height / clip.frame.height             // view points → document units
        let base = (Date() < scrollAnimationEnds && scrollTargetClip === clip ? scrollTarget : nil) ?? clip.bounds.origin
        let sign: CGFloat = (scroll.documentView?.isFlipped ?? false) ? 1 : -1
        var target = base
        target.y += sign * distance * ratio
        target = clip.constrainBoundsRect(NSRect(origin: target, size: clip.bounds.size)).origin

        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            scrollTarget = target
            scrollTargetClip = clip
            scrollAnimationEnds = Date().addingTimeInterval(0.25)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clip.animator().setBoundsOrigin(target)
            }
        } else {
            scrollAnimationEnds = .distantPast
            NSAnimationContext.runAnimationGroup { context in      // also cancels a running animation
                context.duration = 0
                clip.animator().setBoundsOrigin(target)
            }
        }
        scroll.reflectScrolledClipView(clip)
    }

    // ↓ / ↑ (J / K) in the document. One smooth motion for both a press and a hold, so there is
    // no seam between them: a press moves at least three lines and eases out; holding keeps
    // going and speeds up the longer the key is down; releasing eases out. macOS key repeats are
    // ignored: they start only after a pause, which made holding jerky.

    private var holdKeyCode: UInt16?
    private weak var holdView: PDFView?            // the main view or the split pane
    private var holdDirection: CGFloat = 0
    private var holdStarted: CFTimeInterval = 0
    private var holdVelocity: CGFloat = 0          // lines per second
    private var holdTravelled: CGFloat = 0         // lines since the last key press
    private var holdY: CGFloat?
    private var holdLink: CADisplayLink?
    private var holdLastTick: CFTimeInterval = 0
    private var holdReleased = true

    private static let stepLines: CGFloat = 2      // minimum distance of one press
    private static let holdSpeed: CGFloat = 16     // lines per second while held
    private static let easeInRate: CGFloat = 25    // higher: reaches full speed sooner
    private static let easeOutRate: CGFloat = 22   // higher: stops sooner

    private func beginScrollStep(_ direction: CGFloat, event: NSEvent, in view: PDFView) -> Bool {
        if event.isARepeat { return true }                       // the hold is timed by us
        if view !== holdView { endHoldScroll(immediately: true) }
        holdView = view
        if direction != holdDirection { holdVelocity = 0 }       // reversing starts from rest
        holdKeyCode = event.keyCode
        holdDirection = direction
        holdReleased = false
        holdTravelled = 0
        holdStarted = CACurrentMediaTime()
        if holdLink == nil {
            holdY = nil
            holdLastTick = 0
            let link = pdfView.displayLink(target: self, selector: #selector(holdScrollTick(_:)))
            link.add(to: .main, forMode: .common)
            holdLink = link
        }
        return true
    }

    private func releaseHoldScroll() {
        holdReleased = true
        holdKeyCode = nil
    }

    private func endHoldScroll(immediately: Bool) {
        releaseHoldScroll()
        if immediately {
            holdLink?.invalidate()
            holdLink = nil
            holdVelocity = 0
            holdDirection = 0
        }
    }

    @objc private func holdScrollTick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = CGFloat(holdLastTick == 0 ? 1.0 / 60 : min(now - holdLastTick, 0.05))
        holdLastTick = now
        // Held: a constant speed, reached quickly. Released: keep the speed until the remaining
        // minimum distance (two lines per press) can be covered while easing out, then ease out.
        // (Speeding up on long holds is off for now: the keys are for short distances.)
        let cruise = Self.holdSpeed
        let target: CGFloat
        if !holdReleased {
            target = cruise
        } else if holdTravelled + holdVelocity / Self.easeOutRate < Self.stepLines {
            target = max(holdVelocity, 8)
        } else {
            target = 0
        }
        let rate: CGFloat = target == 0 ? Self.easeOutRate : (holdVelocity < target ? Self.easeInRate : 6)
        holdVelocity += (target - holdVelocity) * min(1, dt * rate)
        holdTravelled += holdVelocity * dt
        if holdReleased && target == 0 && holdVelocity < 0.6 { endHoldScroll(immediately: true); return }

        guard let view = holdView, let scroll = Self.findScrollView(in: view),
              scroll.contentView.frame.height > 0 else { endHoldScroll(immediately: true); return }
        let clip = scroll.contentView
        let actual = clip.bounds.origin.y
        if holdY == nil || abs(actual - (holdY ?? actual)) > 2 { holdY = actual }
        let ratio = clip.bounds.height / clip.frame.height
        let sign: CGFloat = (scroll.documentView?.isFlipped ?? false) ? 1 : -1
        let wanted = (holdY ?? actual) + sign * holdDirection * holdVelocity * linePitch(in: view) * dt * ratio
        var origin = clip.bounds.origin
        origin.y = wanted
        let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        clip.setBoundsOrigin(constrained)
        scroll.reflectScrolledClipView(clip)
        if abs(constrained.y - origin.y) > 1 { endHoldScroll(immediately: true) } else { holdY = wanted }
    }

    private var isSidebarFocused: Bool {
        guard let responder = window?.firstResponder as? NSView, let sidebarView else { return false }
        return responder.isDescendant(of: sidebarView)
    }

    /// ↑ / ↓ in a focused sidebar: the next visible row, like any list.
    private func moveInSidebar(by delta: Int) -> Bool {
        let rows = model.visibleRows.filter { $0.node.pageIndex != nil }
        guard !rows.isEmpty else { NSSound.beep(); return true }
        let index = model.highlightedRowID.flatMap { id in rows.firstIndex { $0.id == id } }
        let target = index.map { $0 + delta } ?? 0
        guard rows.indices.contains(target) else { NSSound.beep(); return true }
        recordJump(coalesce: true)
        go(to: rows[target].node)
        return true
    }

    // MARK: Auto-scroll (Space)

    private static let autoScrollSpeedKey = "GalleyAutoScrollLinesPerSecond"
    private static let defaultAutoScrollSpeed: CGFloat = 0.55
    /// Each + / − changes the speed by 15 %, so the steps feel even at any speed.
    private static let autoScrollStep: CGFloat = 1.15

    /// The speed as steps from the default ("+3", "−1"), easier to remember than lines per second.
    private var autoScrollSpeedText: String {
        let steps = Int((log(autoScrollSpeed / Self.defaultAutoScrollSpeed) / log(Self.autoScrollStep)).rounded())
        return steps == 0 ? "default" : steps > 0 ? "+\(steps)" : "−\(-steps)"
    }
    private var isAutoScrolling: Bool { autoScrollTarget > 0 }
    private var autoScrollTarget: CGFloat = 0          // lines per second; 0 = slowing down / off
    private var autoScrollVelocity: CGFloat = 0        // current speed in lines per second
    private var autoScrollY: CGFloat?                  // exact position; the view rounds to pixels
    private var frameStats: (frames: Int, dropped: Int, moves: [CGFloat], since: CFTimeInterval) = (0, 0, [], 0)

    private var autoScrollSpeed: CGFloat {
        get {
            let value = UserDefaults.standard.double(forKey: Self.autoScrollSpeedKey)
            return value > 0 ? CGFloat(value) : Self.defaultAutoScrollSpeed
        }
        set { UserDefaults.standard.set(Double(min(max(newValue, 0.1), 10)), forKey: Self.autoScrollSpeedKey) }
    }

    private func toggleAutoScroll() {
        if isAutoScrolling { stopAutoScroll() } else { startAutoScroll() }
    }

    private func startAutoScroll() {
        autoScrollTarget = autoScrollSpeed
        // Space is easy to hit by accident, so say what happened and how to undo it.
        showNotice("Auto-scroll", detail: "+ / − speed · Space stops")
        guard displayLink == nil else { return }
        autoScrollVelocity = 0
        lastTick = 0
        autoScrollY = nil
        let link = pdfView.displayLink(target: self, selector: #selector(autoScrollTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Slows down smoothly and then stops.
    private func stopAutoScroll() {
        let wasRunning = isAutoScrolling
        autoScrollTarget = 0
        if wasRunning { hideNotice() }   // the auto-scroll notice, if still showing
    }

    private func stopContinuousScroll() {
        stopAutoScroll()
        endHoldScroll(immediately: false)    // the key-up would never reach us
    }

    private func changeAutoScrollSpeed(by factor: CGFloat) {
        autoScrollSpeed *= factor
        autoScrollTarget = autoScrollSpeed
        showNotice("Speed \(autoScrollSpeedText)", detail: "")
    }

    /// Runs once per screen refresh; eases the speed towards the target.
    @objc private func autoScrollTick(_ link: CADisplayLink) {
        let now = link.timestamp
        let rawDt = lastTick == 0 ? 0 : now - lastTick
        let dt = CGFloat(lastTick == 0 ? 1.0 / 60 : min(now - lastTick, 0.05))
        lastTick = now
        autoScrollVelocity += (autoScrollTarget - autoScrollVelocity) * min(1, dt * 4)
        recordFrame(rawDt: rawDt, expected: link.targetTimestamp - link.timestamp, now: now)
        guard let scroll = Self.findScrollView(in: pdfView), scroll.contentView.frame.height > 0 else { return }
        let clip = scroll.contentView
        if autoScrollTarget == 0 && autoScrollVelocity < 0.02 {
            endAutoScroll(link)
            return
        }
        // Follow manual scrolling (trackpad) instead of fighting it.
        let actual = clip.bounds.origin.y
        if autoScrollY == nil || abs(actual - (autoScrollY ?? actual)) > 2 { autoScrollY = actual }
        let ratio = clip.bounds.height / clip.frame.height
        let sign: CGFloat = (scroll.documentView?.isFlipped ?? false) ? 1 : -1
        let wanted = (autoScrollY ?? actual) + sign * autoScrollVelocity * linePitch * dt * ratio
        let pixel = ratio / (window?.backingScaleFactor ?? 2)        // document units per device pixel (log)
        var origin = clip.bounds.origin
        origin.y = wanted
        let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        let before = clip.bounds.origin.y
        clip.setBoundsOrigin(constrained)
        scroll.reflectScrolledClipView(clip)
        frameStats.moves.append(abs(clip.bounds.origin.y - before) / pixel)
        // Keep the exact position unless the view had to stop us (end of the document).
        if abs(constrained.y - origin.y) > 1 {
            endAutoScroll(link)
        } else {
            autoScrollY = wanted
        }
    }

    /// Debug log only: once per second, how many frames were late and how far the page moved per frame
    /// (in device pixels).
    private func recordFrame(rawDt: CFTimeInterval, expected: CFTimeInterval, now: CFTimeInterval) {
        guard UserDefaults.standard.string(forKey: "GalleyDebugLog") != nil else { return }
        if frameStats.since == 0 { frameStats.since = now }
        frameStats.frames += 1
        if expected > 0, rawDt > expected * 1.5 { frameStats.dropped += 1 }
        if now - frameStats.since >= 1 {
            let moves = frameStats.moves.map { String(format: "%.1f", Double($0)) }.joined(separator: " ")
            debugLog(String(format: "autoscroll %.2f lines/s: %d frames, %d late, frame interval %.1f ms, px per frame: ",
                            Double(autoScrollVelocity), frameStats.frames, frameStats.dropped, expected * 1000) + moves)
            frameStats = (0, 0, [], now)
        }
    }

    private func endAutoScroll(_ link: CADisplayLink) {
        link.invalidate()
        displayLink = nil
        autoScrollTarget = 0
        autoScrollVelocity = 0
    }

    /// Jumps to the top of the next/previous page; ← first returns to the top of the current page.
    private func movePage(by delta: Int, in view: PDFView? = nil) -> Bool {
        let pdfView = view ?? pdfView
        guard let doc = pdfView.document, let top = visibleTop(in: pdfView) else { return false }
        let isTwoUp = pdfView.displayMode == .twoUp || pdfView.displayMode == .twoUpContinuous
        let step = isTwoUp ? 2 : 1
        var target = top.pageIndex + delta * step
        if delta < 0 {
            let pageTop = top.page.bounds(for: pdfView.displayBox).maxY
            if pageTop - top.y > 20 { target = top.pageIndex }
        }
        guard target >= 0, target < doc.pageCount, let page = doc.page(at: target) else {
            NSSound.beep()
            return true
        }
        // Back to the top of this page glides, so it's clear the next press goes to the previous
        // page; whole-page steps are instant (snappy, and no transitions between slides). It
        // stops where a jump would: with the grey margin above the page, which Fit Page includes.
        let margin = pdfView.displaysPageBreaks ? pdfView.pageBreakMargins.top : 0
        let pageTop = NSPoint(x: 0, y: page.bounds(for: pdfView.displayBox).maxY + margin)
        if target == top.pageIndex, let distance = distanceToTop(of: pageTop, on: page, in: pdfView) {
            scrollAnimationEnds = .distantPast
            scrollBy(distance, animated: true, in: pdfView)
        } else {
            pdfView.go(to: page)
        }
        if pdfView === self.pdfView { perform(#selector(alignHorizontallyAction), with: nil, afterDelay: 0) }
        return true
    }

    /// A click on a page thumbnail.
    func showPage(_ index: Int) {
        guard let page = pdfView.document?.page(at: index) else { return }
        recordJump()
        pdfView.go(to: page)
        perform(#selector(alignHorizontallyAction), with: nil, afterDelay: 0)
    }

    private func expandOrDescend() -> Bool {
        guard let id = model.highlightedRowID,
              let row = model.visibleRows.first(where: { $0.id == id }) else { return false }
        guard let children = row.node.children else { NSSound.beep(); return true }
        if !model.expanded.contains(id) {
            model.toggle(id)
        } else if let first = children.first {
            go(to: first)
        }
        return true
    }

    private func collapseOrAscend() -> Bool {
        guard let id = model.highlightedRowID else { return false }
        if model.expanded.contains(id) {
            model.toggle(id)
        } else if let parent = model.parentID(of: id),
                  let row = model.visibleRows.first(where: { $0.id == parent }) {
            go(to: row.node)
        } else {
            NSSound.beep()
        }
        return true
    }

    /// Whether a heading lies clearly above the top of the view, i.e. we are in the middle of its section.
    private func isWellAbove(_ node: OutlineNode, in view: PDFView? = nil) -> Bool {
        guard let top = visibleTop(in: view), let pageIndex = node.pageIndex, let y = targetY(for: node) else { return false }
        if pageIndex != top.pageIndex { return pageIndex < top.pageIndex }
        return y > top.y + 30
    }

    /// Without an outline the keys only beep, so they keep one meaning everywhere.
    /// In the split pane (`view`), from the pane's own section; the sidebar stays with the main view.
    func moveHeading(by delta: Int, chaptersOnly: Bool, in view: PDFView? = nil) -> Bool {
        let inPane = view != nil && view !== pdfView
        // All headings in reading order, collapsed or not; the sidebar reveals where we land.
        let all = model.allRows.filter { $0.node.pageIndex != nil }
        guard !all.isEmpty else { NSSound.beep(); return true }   // no outline: nothing to move to
        // An entry starting exactly where its first child starts (the "Appendix" group) would
        // cost a key press that doesn't move: step to the child instead (chapters keep it).
        func sameSpot(_ a: OutlineRowItem, _ b: OutlineRowItem) -> Bool {
            a.node.pageIndex == b.node.pageIndex && abs(a.node.y - b.node.y) < 1
        }
        var rows: [OutlineRowItem] = []
        var standIn: [Int: Int] = [:]      // skipped entry → the child that replaces it
        for (index, row) in all.enumerated() {
            if !chaptersOnly, index + 1 < all.count, all[index + 1].depth > row.depth, sameSpot(row, all[index + 1]) {
                standIn[row.id] = all[index + 1].id
                continue
            }
            rows.append(row)
        }
        let matches: (OutlineRowItem) -> Bool = { !chaptersOnly || $0.depth == 0 }
        var currentID = inPane ? visibleTop(in: view).flatMap { sectionID(at: $0) } : model.currentSectionID
        while let id = currentID, let child = standIn[id] { currentID = child }
        let anchor = currentID.flatMap { id in rows.firstIndex { $0.id == id } }

        var target: OutlineRowItem?
        if delta > 0 {
            let start = min((anchor ?? -1) + 1, rows.count)
            target = rows[start...].first(where: matches)
        } else if let anchor {
            // First go to the start of the current section (or chapter) if we're in the middle of it.
            let current = chaptersOnly ? (rows[...anchor].lastIndex { $0.depth == 0 } ?? anchor) : anchor
            if isWellAbove(rows[current].node, in: view) {
                target = rows[current]
            } else {
                target = rows[..<current].last(where: matches)
            }
        }

        guard let target else {
            NSSound.beep()
            return true
        }
        if inPane {
            go(to: target.node, in: view)
            return true
        }
        recordJump(coalesce: true)
        go(to: target.node)
        model.reveal(target.id)
        return true
    }

    // MARK: Search
    //
    // Typing searches; ↑/↓ move through the results (the document follows); Return stays at the
    // current result and ends the search; Esc goes back to where the search started.

    private var searchOrigin: NSPoint?
    private var searchOriginPosition: Position?

    private var isSearchFieldFocused: Bool {
        guard let editor = window?.firstResponder as? NSTextView, let field = searchItem?.searchField else { return false }
        return editor.delegate === field
    }

    @objc private func searchFieldAction(_ sender: NSSearchField) {
        let query = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != lastQuery else { return }
        lastQuery = query
        if query.isEmpty {
            searchOrigin = nil            // cleared with the ✕ button: nothing to go back to
        } else {
            rememberSearchOrigin()
        }
        runSearch(query, jump: true)
    }

    private func rememberSearchOrigin() {
        guard searchOrigin == nil, let scroll = Self.findScrollView(in: pdfView) else { return }
        searchOrigin = scroll.contentView.bounds.origin
        searchOriginPosition = currentPosition()
    }

    /// Keys while typing in the search field. Returns true when handled.
    private func handleSearchKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        // ⌥↓/⌥↑: the next/previous section with matches; ⌥⇧: the next/previous chapter.
        if event.keyCode == 125 || event.keyCode == 126, flags == .option || flags == [.option, .shift] {
            guard !model.results.isEmpty else { return false }
            jumpToSearchGroup(event.keyCode == 125 ? 1 : -1, chapters: flags.contains(.shift))
            return true
        }
        guard flags.isEmpty || event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 53 else { return false }
        switch event.keyCode {
        case 125:                                   // ↓
            guard !model.results.isEmpty else { return false }
            step(1)
            return true
        case 126:                                   // ↑
            guard !model.results.isEmpty else { return false }
            step(-1)
            return true
        case 36, 76:                                // Return / Enter: stay here
            if flags == .command {                  // ⌘Return: the match in the split view, back here
                guard let index = model.currentResult, model.results.indices.contains(index) else { NSSound.beep(); return true }
                let selection = model.results[index].selection
                endSearch(returnToOrigin: true)
                showInSplit(selection)
                return true
            }
            let query = searchItem?.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !query.isEmpty && query != lastQuery {   // typed faster than the search started
                lastQuery = query
                rememberSearchOrigin()
                runSearch(query, jump: true)
            }
            endSearch(returnToOrigin: false)
            return true
        case 53:                                    // Esc: back to where we were
            endSearch(returnToOrigin: true)
            return true
        default:
            return false
        }
    }

    private func endSearch(returnToOrigin: Bool) {
        // Staying at a match is a jump: Back returns to where the search started.
        if !returnToOrigin, searchOrigin != nil, let origin = searchOriginPosition {
            recordJump(from: origin)
        }
        searchOriginPosition = nil
        if returnToOrigin, let origin = searchOrigin, let scroll = Self.findScrollView(in: pdfView) {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        searchOrigin = nil
        lastQuery = ""
        searchItem?.searchField.stringValue = ""
        searchItem?.endSearchInteraction()
        model.searchText = ""
        model.results = []
        model.currentResult = nil
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()
        window?.makeFirstResponder(pdfView)
        updatePositionUI()
    }

    // MARK: Search options (magnifying-glass menu of the search field)

    enum MatchMode: Int { case wordStart, wholeWord, anywhere, regex }
    enum CaseMode: Int { case smart, matchCase, ignoreCase }

    private static var matchMode: MatchMode {
        get { MatchMode(rawValue: UserDefaults.standard.integer(forKey: "GalleySearchMatch")) ?? .wordStart }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "GalleySearchMatch") }
    }

    private static var caseMode: CaseMode {
        get { CaseMode(rawValue: UserDefaults.standard.integer(forKey: "GalleySearchCase")) ?? .smart }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "GalleySearchCase") }
    }

    /// Searches the page text ourselves. Defaults: matches at word beginnings (so "hic" doesn't find
    /// "which"), smart case (case matters only if the query has a capital letter) and smart accents
    /// (accents matter only if the query has one, so "Garcia" finds "García" but "Müller" not "Muller").
    private func findMatches(_ query: String, in doc: PDFDocument) -> [PDFSelection] {
        if Self.matchMode == .regex { return findRegexMatches(query, in: doc) }
        var options: NSString.CompareOptions = []
        switch Self.caseMode {
        case .smart: if query == query.lowercased() { options.insert(.caseInsensitive) }
        case .matchCase: break
        case .ignoreCase: options.insert(.caseInsensitive)
        }
        if query == query.folding(options: .diacriticInsensitive, locale: nil) {
            options.insert(.diacriticInsensitive)
        }
        let mode = Self.matchMode

        func isWordCharacter(_ text: NSString, _ index: Int) -> Bool {
            guard index >= 0, index < text.length, let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }

        var selections: [PDFSelection] = []
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index), let string = page.string else { continue }
            let text = string as NSString
            var searchRange = NSRange(location: 0, length: text.length)
            while searchRange.length > 0 {
                let found = text.range(of: query, options: options, range: searchRange)
                guard found.location != NSNotFound else { break }
                let startsWord = !isWordCharacter(text, found.location - 1)
                let endsWord = !isWordCharacter(text, found.location + found.length)
                let accepted: Bool
                switch mode {
                case .wordStart: accepted = startsWord
                case .wholeWord: accepted = startsWord && endsWord
                case .anywhere, .regex: accepted = true      // (regex is searched separately)
                }
                if accepted, let selection = page.selection(for: found) { selections.append(selection) }
                let next = found.location + max(found.length, 1)
                searchRange = NSRange(location: next, length: max(0, text.length - next))
            }
        }
        return selections
    }

    /// Regular expressions (an option for the rare power use): smart case still applies, ignoring
    /// escapes like \D or \S; accents and word beginnings don't. An incomplete pattern, as while
    /// typing, finds nothing.
    private func findRegexMatches(_ pattern: String, in doc: PDFDocument) -> [PDFSelection] {
        var options: NSRegularExpression.Options = []
        switch Self.caseMode {
        case .smart:
            let literal = pattern.replacingOccurrences(of: #"\\."#, with: "", options: .regularExpression)
            if literal == literal.lowercased() { options.insert(.caseInsensitive) }
        case .matchCase: break
        case .ignoreCase: options.insert(.caseInsensitive)
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        var selections: [PDFSelection] = []
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index), let string = page.string else { continue }
            for match in regex.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length))
            where match.range.length > 0 {
                if let selection = page.selection(for: match.range) { selections.append(selection) }
            }
        }
        return selections
    }

    private func searchMenu() -> NSMenu {
        let menu = NSMenu(title: "Search Options")
        func option(_ title: String, tag: Int, on: Bool, help: String) {
            let item = NSMenuItem(title: title, action: #selector(searchOptionChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = on ? .on : .off
            item.toolTip = help
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.sectionHeader(title: "Match"))
        option("At Word Beginnings", tag: 0, on: Self.matchMode == .wordStart,
               help: "Finds words that start with your search: “elect” finds “election” and “electoral”, but not “selection”.")
        option("Whole Words", tag: 1, on: Self.matchMode == .wholeWord,
               help: "Finds only complete words: “elect” finds “elect”, but not “election”.")
        option("Anywhere", tag: 2, on: Self.matchMode == .anywhere,
               help: "Finds your search anywhere, also inside words: “hic” also finds “which”.")
        option("Regular Expression", tag: 3, on: Self.matchMode == .regex,
               help: "Treats your search as a regular expression: “19[5-9]\\d” finds years from 1950 to 1999.")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Case"))
        option("Smart Case", tag: 10, on: Self.caseMode == .smart,
               help: "Ignores case unless your search contains a capital letter: “hic” finds “HIC”, but “HIC” finds only “HIC”. Accents work the same way: “Garcia” finds “García”, but “Müller” finds only “Müller”.")
        option("Match Case", tag: 11, on: Self.caseMode == .matchCase,
               help: "Upper and lower case must match exactly.")
        option("Ignore Case", tag: 12, on: Self.caseMode == .ignoreCase,
               help: "Upper and lower case never matter.")
        return menu
    }

    @objc private func searchOptionChosen(_ sender: NSMenuItem) {
        if sender.tag < 10 {
            Self.matchMode = MatchMode(rawValue: sender.tag) ?? .wordStart
        } else {
            Self.caseMode = CaseMode(rawValue: sender.tag - 10) ?? .smart
        }
        searchItem?.searchField.searchMenuTemplate = searchMenu()   // refresh the checkmarks
        if !lastQuery.isEmpty { runSearch(lastQuery, jump: true) }
    }

    /// The outline entry a position belongs to (the last heading at or above it).
    private func sectionContaining(pageIndex: Int, y: CGFloat) -> Int? {
        var best: Int? = nil
        var bestPage = -1
        var bestY: CGFloat = 0
        for entry in model.flat {
            let isAbove = entry.pageIndex < pageIndex || (entry.pageIndex == pageIndex && entry.y >= y)
            guard isAbove else { continue }
            let isEarlier = entry.pageIndex < bestPage || (entry.pageIndex == bestPage && entry.y > bestY)
            if best != nil && isEarlier { continue }
            best = entry.id
            bestPage = entry.pageIndex
            bestY = entry.y
        }
        return best
    }

    private func runSearch(_ query: String, jump: Bool) {
        model.searchText = query
        guard !query.isEmpty, let doc = pdfView.document else {
            model.results = []
            model.currentResult = nil
            pdfView.highlightedSelections = nil
            return
        }
        if let sidebarItem, sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = false }

        let selections = findMatches(query, in: doc)
        var results: [SearchResult] = []
        results.reserveCapacity(selections.count)
        for (i, selection) in selections.enumerated() {
            selection.color = NSColor.systemYellow.withAlphaComponent(0.5)
            var pageIndex = 0
            var section: Int? = nil
            if let page = selection.pages.first {
                pageIndex = doc.index(for: page)
                section = sectionContaining(pageIndex: pageIndex, y: selection.bounds(for: page).maxY)
            }
            var snippet = AttributedString(query)
            if i < 400, let context = selection.copy() as? PDFSelection {
                context.extendForLineBoundaries()
                let line = (context.string ?? "")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                snippet = Self.highlighted(line, query)
            }
            results.append(SearchResult(id: i, pageIndex: pageIndex, pageLabel: "\(pageIndex + 1)",
                                        sectionID: section, snippet: snippet, selection: selection))
        }
        model.results = results
        model.currentResult = nil
        pdfView.highlightedSelections = selections

        if jump, !results.isEmpty {
            // The first match in the document: when looking up a term, its first mention (where
            // it's introduced or defined) is usually the one wanted. Esc goes back.
            selectResult(0)
        }
    }

    private static func highlighted(_ line: String, _ query: String) -> AttributedString {
        guard let range = line.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return AttributedString(line)
        }
        let before = line[line.startIndex..<range.lowerBound]
        let after = line[range.upperBound...]
        let prefix: String = before.count > 40 ? "…" + String(before.suffix(40)) : String(before)
        var result = AttributedString(prefix)
        var match = AttributedString(String(line[range]))
        match.inlinePresentationIntent = .stronglyEmphasized
        result.append(match)
        result.append(AttributedString(String(after.prefix(160))))
        return result
    }

    /// Moves to the first match of the next/previous section (or chapter) that has matches.
    /// Unlike heading navigation, going back doesn't stop at the current one's first match:
    /// that's no landmark the way a heading is.
    private func jumpToSearchGroup(_ delta: Int, chapters: Bool) {
        func key(_ result: SearchResult) -> Int {
            let k = model.searchKey(for: result)
            return chapters && k >= 0 ? (model.ancestors(of: k).last ?? k) : k
        }
        var starts: [(key: Int, index: Int)] = []
        for (index, result) in model.results.enumerated() {
            let k = key(result)
            if starts.last?.key != k { starts.append((k, index)) }
        }
        let current = model.currentResult ?? -1
        let group = starts.lastIndex { $0.index <= current } ?? -1
        let target = group + delta
        guard starts.indices.contains(target) else { NSSound.beep(); return }
        selectResult(starts[target].index)
    }

    /// Clicking a section while searching: its first match.
    func selectFirstResult(forKey key: Int) {
        if let index = model.results.firstIndex(where: { model.searchKey(for: $0) == key }) {
            selectResult(index)
        }
    }

    /// ⌘-click on a section while searching: its first match in the split view.
    func showFirstResultInSplit(forKey key: Int) {
        if let result = model.results.first(where: { model.searchKey(for: $0) == key }) {
            showInSplit(result.selection)
        }
    }

    func selectResult(_ index: Int) {
        guard model.results.indices.contains(index) else { return }
        model.currentResult = index
        let selection = model.results[index].selection
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.go(to: selection)
    }

    private func step(_ delta: Int) {
        let count = model.results.count
        guard count > 0 else { return }
        let hadMatch = model.currentResult != nil
        let base = model.currentResult ?? (delta > 0 ? -1 : 0)
        let target = ((base + delta) % count + count) % count
        selectResult(target)
        // Wrapped around: say so, or the long jump back is easy to miss.
        if count > 1, hadMatch, target != base + delta {
            showNotice(delta > 0 ? "Back to the first match" : "On to the last match", detail: "")
        }
    }

    // MARK: Menu actions

    @objc func focusSearch(_ sender: Any?) { searchItem?.beginSearchInteraction() }
    @objc func findNextMatch(_ sender: Any?) { step(1) }
    @objc func findPreviousMatch(_ sender: Any?) { step(-1) }

    @objc func zoomInAction(_ sender: Any?) {
        zoomMode = .custom
        pdfView.zoomIn(nil)
    }
    @objc func zoomOutAction(_ sender: Any?) {
        zoomMode = .custom
        pdfView.zoomOut(nil)
    }
    @objc func fitPageAction(_ sender: Any?) { selectZoomMode(.fitPage) }
    @objc func readingSizeAction(_ sender: Any?) { selectZoomMode(.readingSize) }
    @objc func fitWidthAction(_ sender: Any?) { selectZoomMode(.fitWidth) }
    @objc func fitTextAction(_ sender: Any?) { selectZoomMode(.fitText) }
    @objc func actualSizeAction(_ sender: Any?) { selectZoomMode(.actualSize) }

    @objc func increaseReadingSizeAction(_ sender: Any?) { adjustReadingSize(by: 1.08) }
    @objc func decreaseReadingSizeAction(_ sender: Any?) { adjustReadingSize(by: 1 / 1.08) }

    /// ⌥⌘+ / ⌥⌘−: change the Reading Size preference – only while Reading Size is active.
    private func adjustReadingSize(by step: CGFloat) {
        guard zoomMode == .readingSize else { NSSound.beep(); return }
        ReadingSizeStore.factor *= step
        applyZoomMode()
        showNotice("Reading Size \(readingAdjustmentText() ?? "±0%")", detail: "Saved for all documents")
    }

    @objc func resetReadingSizeAction(_ sender: Any?) {
        ReadingSizeStore.factor = 1
        applyZoomMode()
        updatePositionUI()
        showNotice("Reading Size reset", detail: "Back to the calculated default")
    }

    /// Menu version of the ⌘0 switcher: goes straight to the previously used mode.
    @objc func switchZoomModeAction(_ sender: Any?) {
        let modes = zoomSwitcherModes()
        guard !modes.isEmpty else { return }
        let index = zoomMode == .custom ? 0 : min(1, modes.count - 1)
        selectZoomMode(modes[index])
    }

    /// Menu version of the ⌘9 switcher: goes straight to the previously used page colour.
    @objc func switchPageThemeAction(_ sender: Any?) {
        PageTheme.current = PageTheme.recent[1]
    }

    var currentZoomMode: ZoomMode { zoomMode }
    /// Reading Size is smaller than set because the text column wouldn't fit otherwise.
    private(set) var isReadingSizeCapped = false

    /// "+16%" / "−8%" when Reading Size has been adjusted, otherwise nil.
    func readingAdjustmentText() -> String? {
        let factor = ReadingSizeStore.factor
        let percent = Int((abs(factor - 1) * 100).rounded())
        guard percent > 0 else { return nil }
        return "\(factor > 1 ? "+" : "−")\(percent)%"
    }

    func selectZoomMode(_ mode: ZoomMode) {
        let page = pdfView.currentPage
        zoomMode = mode
        applyZoomMode()
        if mode == .fitPage, let page { pdfView.go(to: page) }
        updatePositionUI()
    }

    // MARK: Switchers (⌘0 zoom mode, ⌘9 page colour; work like ⌘Tab)

    private enum SwitcherKind {
        case zoom, pageTheme

        /// The single key that opens and steps it (with ⇧: back).
        var key: String { self == .zoom ? "z" : "d" }
    }

    private var zoomHistory = ZoomHistory()
    private var switcherKind = SwitcherKind.zoom
    private var switcherItems: [SwitcherItem] = []
    private var switcherActions: [() -> Void] = []
    private var switcherIndex = 0
    private var switcherOverlay: NSView?
    private var switcherHost: NSHostingView<SwitcherView>?

    /// Modes in most-recently-used order, current mode first.
    private func zoomSwitcherModes() -> [ZoomMode] {
        var order = zoomHistory.order
        if zoomMode != .custom {
            order.removeAll { $0 == zoomMode }
            order.insert(zoomMode, at: 0)
        }
        return order
    }

    private func advanceSwitcher(_ kind: SwitcherKind, by delta: Int) {
        if switcherOverlay == nil {
            switcherKind = kind
            let startsAtCurrent: Bool
            switch kind {
            case .zoom:
                let modes = zoomSwitcherModes()
                switcherItems = modes.map { SwitcherItem(title: $0.title, icon: .symbol($0.symbol)) }
                switcherActions = modes.map { mode in { [weak self] in self?.selectZoomMode(mode) } }
                startsAtCurrent = zoomMode == .custom
            case .pageTheme:
                let themes = PageTheme.recent
                switcherItems = themes.map { SwitcherItem(title: $0.title, icon: .swatch(Color(cgColor: $0.paperColor))) }
                switcherActions = themes.map { theme in { PageTheme.current = theme } }
                startsAtCurrent = false
            }
            guard !switcherItems.isEmpty else { return }
            if startsAtCurrent {
                switcherIndex = 0
            } else {
                guard switcherItems.count > 1 else { NSSound.beep(); return }
                switcherIndex = delta > 0 ? 1 : switcherItems.count - 1
            }
            showSwitcher()
        } else {
            let count = switcherItems.count
            switcherIndex = ((switcherIndex + delta) % count + count) % count
            switcherHost?.rootView = SwitcherView(items: switcherItems, selected: switcherIndex)
        }
    }

    /// A switcher opened with Z or D (no ⌘ to release): confirms after a short pause.
    private var switcherByKey = false

    private func scheduleSwitcherCommit() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(commitSwitcherAfterPause), object: nil)
        perform(#selector(commitSwitcherAfterPause), with: nil, afterDelay: 1.0)
    }

    @objc private func commitSwitcherAfterPause() {
        if switcherByKey { commitSwitcher() }
    }

    private func commitSwitcher() {
        guard switcherOverlay != nil, switcherActions.indices.contains(switcherIndex) else { return }
        let choose = switcherActions[switcherIndex]
        hideSwitcher()
        choose()
    }

    private func showSwitcher() {
        guard let content = window?.contentView else { return }
        let panel = NSVisualEffectView()
        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 14
        panel.layer?.masksToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false

        let host = NSHostingView(rootView: SwitcherView(items: switcherItems, selected: switcherIndex))
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(host)
        content.addSubview(panel)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            host.topAnchor.constraint(equalTo: panel.topAnchor),
            host.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            panel.centerXAnchor.constraint(equalTo: pdfView.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor),
        ])
        switcherOverlay = panel
        switcherHost = host
    }

    private func hideSwitcher() {
        switcherByKey = false
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(commitSwitcherAfterPause), object: nil)
        guard let panel = switcherOverlay else { return }
        switcherOverlay = nil
        switcherHost = nil
        panel.animator().alphaValue = 0
        perform(#selector(removeOverlay(_:)), with: panel, afterDelay: 0.3)
    }

    @objc private func removeOverlay(_ view: NSView) {
        view.removeFromSuperview()
    }

    // MARK: Notice (brief overlay, like the system volume display)

    private var noticeOverlay: NSView?

    private func showNotice(_ title: String, detail: String) {
        guard let content = window?.contentView else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideNotice), object: nil)
        if let old = noticeOverlay { old.removeFromSuperview() }

        let panel = NSVisualEffectView()
        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 14
        panel.layer?.masksToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        let host = NSHostingView(rootView: NoticeView(title: title, detail: detail))
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(host)
        content.addSubview(panel)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            host.topAnchor.constraint(equalTo: panel.topAnchor),
            host.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            panel.centerXAnchor.constraint(equalTo: pdfView.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor),
        ])
        noticeOverlay = panel
        perform(#selector(hideNotice), with: nil, afterDelay: 1.2)
    }

    @objc private func hideNotice() {
        guard let panel = noticeOverlay else { return }
        noticeOverlay = nil
        panel.animator().alphaValue = 0
        perform(#selector(removeOverlay(_:)), with: panel, afterDelay: 0.3)
    }
    @objc func toggleTwoPagesAction(_ sender: Any?) {
        pdfView.displayMode = pdfView.displayMode == .twoUpContinuous ? .singlePageContinuous : .twoUpContinuous
        applyZoomMode()
    }

    @objc func nextPageAction(_ sender: Any?) { _ = movePage(by: 1) }
    @objc func previousPageAction(_ sender: Any?) { _ = movePage(by: -1) }
    @objc func firstPageAction(_ sender: Any?) { pdfView.goToFirstPage(nil) }
    @objc func lastPageAction(_ sender: Any?) { pdfView.goToLastPage(nil) }
    /// Clicking a link (e.g. a reference to a section or figure) is a jump.
    /// A click on an internal link: remember where we were before PDFKit jumps. (PDFKit's own
    /// annotation-hit notification isn't posted for links, or comes too late.)
    /// A click on an internal link. With ⌘ the target opens in the split pane (and the click is
    /// kept from PDFKit). Otherwise PDFKit jumps; for the main view, remember where we were first.
    /// (PDFKit's own annotation-hit notification isn't posted for links, or comes too late.)
    /// Returns true when the click was used.
    /// Middle click on a link (or in its preview) opens the target in the split pane, like
    /// opening a link in a new tab in a browser.
    private func handleMiddleClick(_ event: NSEvent) -> Bool {
        guard event.buttonNumber == 2 else { return false }
        if mouseIsInPreview, let target = shownTarget {
            openPreviewTarget(target, inSplit: true)
            return true
        }
        guard event.window === window, let target = linkUnderMouse() else { return false }
        closePreview()
        openSplit(at: target.destination)
        return true
    }

    private func handleMouseDown(_ event: NSEvent) -> Bool {
        if slideShowSaved != nil, event.window === window, linkUnderMouse() == nil,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           pdfView.bounds.contains(pdfView.convert(event.locationInWindow, from: nil)) {
            showSlide(by: 1)     // a click anywhere but on a link: next slide
            swallowMouseUp = true
            return true
        }
        guard event.window === window, event.clickCount == 1, let target = linkUnderMouse() else { return false }
        closePreview()
        if event.modifierFlags.contains(.command) {
            openSplit(at: target.destination)
            swallowMouseUp = true
            return true
        }
        // A detected link on top of a PDF link for a whole group of citations: PDFKit might
        // follow the group link, so jump ourselves.
        let pagePoint = target.view.convert(target.view.convert(event.locationInWindow, from: nil), to: target.page)
        if let underneath = target.page.annotation(at: pagePoint), underneath !== target.annotation {
            openPreviewTarget(target, inSplit: false)
            swallowMouseUp = true
            return true
        }
        // A plain press on a link: follow it on release, or select text if the mouse moves on
        // (PDFKit would neither select nor follow then).
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
            if target.view === pdfView { recordJump() }
            return false
        }
        linkPress = (target, event.locationInWindow, false)
        target.view.window?.makeFirstResponder(target.view)
        return true
    }

    /// A press on a link that hasn't been released yet; `dragging` once it selects text instead.
    private var linkPress: (target: LinkTarget, start: NSPoint, dragging: Bool)?
    private var mouseDownLocation: NSPoint?

    private func handleLinkPressDrag(_ event: NSEvent) -> Bool {
        guard var press = linkPress else { return false }
        let view = press.target.view
        if !press.dragging {
            guard hypot(event.locationInWindow.x - press.start.x, event.locationInWindow.y - press.start.y) > 3 else { return true }
            press.dragging = true
            linkPress = press
        }
        Self.findScrollView(in: view)?.contentView.autoscroll(with: event)
        let point = view.convert(event.locationInWindow, from: nil)
        guard let doc = view.document, let page = view.page(for: point, nearest: true) else { return true }
        let startPoint = view.convert(view.convert(press.start, from: nil), to: press.target.page)
        let selection = doc.selection(from: press.target.page, at: startPoint, to: page, at: view.convert(point, to: page))
        view.setCurrentSelection(selection, animate: false)
        return true
    }

    private func endLinkPress() -> Bool {
        guard let press = linkPress else { return false }
        linkPress = nil
        if !press.dragging {
            if press.target.view === pdfView { recordJump() }
            press.target.view.go(to: press.target.destination)
        }
        return true
    }

    /// A single click (no drag, no modifier) on a highlight selects its text, so M removes it.
    private func noteClick(_ event: NSEvent) {
        guard event.window === window, event.clickCount == 1,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let down = mouseDownLocation,
              hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) <= 3 else { return }
        let location = event.locationInWindow
        // After PDFKit has handled the click (which clears the selection).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for view in [self.pdfView, self.splitPane].compactMap({ $0 }) {
                let point = view.convert(location, from: nil)
                if view.bounds.contains(point), let page = view.page(for: point, nearest: false),
                   let marker = CommentMarker.at(view.convert(point, to: page), on: page),
                   let highlight = marker.highlight, let selection = Annotations.selection(of: highlight) {
                    // A click on a comment marker: the comment, ready to edit.
                    view.setCurrentSelection(selection, animate: false)
                    self.window?.makeFirstResponder(view)
                    self.commentAction(nil)
                    return
                }
                guard view.bounds.contains(point), (view.currentSelection?.string ?? "").isEmpty,
                      let page = view.page(for: point, nearest: false),
                      let selection = Annotations.selection(at: view.convert(point, to: page), on: page) else { continue }
                view.setCurrentSelection(selection, animate: false)
            }
        }
    }

    private var jumpPalette: JumpPalette?
    /// The jump palette's page numbering (as printed or in the PDF), kept while the window is open.
    private var pagesAsPrinted = false
    /// Where the reading was when the palette opened, and whether the document has followed its
    /// selection since (recorded in the history at the first step, so Back returns there).
    private var paletteStart: Position?
    private var paletteFollowed = false
    /// Slide titles for the palette, worked out on first use (per document version).
    private var slideTitleCache: (version: Int, items: [OutlineDetector.Item])?

    /// G: the jump palette (see JumpPalette).
    @objc func goToPageAction(_ sender: Any?) {
        guard let window, let doc = pdfView.document, jumpPalette == nil else { return }
        func pageIndex(_ page: PDFPage) -> Int { doc.index(for: page) }

        var kinds = [JumpPalette.Kind(key: "p", name: "page", entries: [])]
        var sections: [JumpPalette.Entry] = []
        if OutlineDetector.isSlides(doc) {
            if slideTitleCache?.version != model.documentVersion {
                slideTitleCache = (model.documentVersion, OutlineDetector.slideTitles(doc))
            }
            sections = (slideTitleCache?.items ?? []).compactMap { item in
                item.pageIndex.map { JumpPalette.Entry(title: item.label, number: nil, pageIndex: $0, target: .page($0)) }
            }
        } else {
            func add(_ nodes: [OutlineNode]) {
                for node in nodes {
                    if let index = node.pageIndex {
                        sections.append(JumpPalette.Entry(title: node.fullLabel, number: node.number, pageIndex: index,
                                                          target: .section(node)))
                    }
                    add(node.children ?? [])
                }
            }
            add(model.outline)
        }
        kinds.append(JumpPalette.Kind(key: "s", name: OutlineDetector.isSlides(doc) ? "slide" : "section", entries: sections))
        // The top-level section each figure, table, … is in: the last such heading before it.
        var headings: [(page: Int, y: CGFloat, label: String)] = []
        if !OutlineDetector.isSlides(doc) {
            for node in model.outline {
                if let index = node.pageIndex { headings.append((index, node.y, node.fullLabel)) }
            }
        }
        headings.sort { $0.page != $1.page ? $0.page < $1.page : $0.y > $1.y }
        func section(page: Int, y: CGFloat) -> String? {
            headings.last { $0.page < page || ($0.page == page && $0.y >= y - 1) }?.label
        }
        let targets = ReferenceDetector.jumpTargets(in: doc)
        let types: [(Character, String, ReferenceDetector.JumpTarget.Kind)] = [
            ("f", "figure", .figure), ("t", "table", .table), ("e", "equation", .equation),
            ("n", "footnote", .note), ("r", "reference", .reference)]
        for (key, name, kind) in types {
            let entries = targets.filter { $0.kind == kind }.map { target in
                JumpPalette.Entry(title: target.title, number: target.label, keywords: target.keywords,
                                  pageIndex: pageIndex(target.page),
                                  section: section(page: pageIndex(target.page), y: target.point.y),
                                  target: .spot(PDFDestination(page: target.page, at: target.point)))
            }
            kinds.append(JumpPalette.Kind(key: key, name: name, entries: entries))
        }
        // The reader's highlights, in reading order: found by their text or their comment.
        var notes: [JumpPalette.Entry] = []
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            for annotation in Annotations.inReadingOrder(on: page) {
                let comment = annotation.contents.flatMap { $0.isEmpty ? nil : $0 }
                notes.append(JumpPalette.Entry(title: Annotations.text(of: annotation), number: nil, keywords: comment ?? "",
                                               pageIndex: index, section: section(page: index, y: annotation.bounds.maxY),
                                               target: .annotation(annotation), comment: comment, color: annotation.color))
            }
        }
        kinds.append(JumpPalette.Kind(key: "a", name: "annotation", entries: notes))

        // Pages by the number printed on them (when the PDF has its own that differ from the
        // count) or by their place in the PDF – the pop-up next to the field decides, no guessing.
        let hasPrintedPages = (0..<doc.pageCount).contains { index in
            doc.page(at: index)?.label.map { !$0.isEmpty && $0 != "\(index + 1)" } ?? false
        }
        let pages: (String, Bool) -> [JumpPalette.Entry] = { text, asPrinted in
            guard !text.isEmpty else { return [] }
            if asPrinted && hasPrintedPages {
                return (0..<doc.pageCount).filter { doc.page(at: $0)?.label == text }.map { index in
                    JumpPalette.Entry(title: "Page \(text) as printed", number: nil, pageIndex: index, target: .page(index))
                }
            }
            guard let number = Int(text), number >= 1, number <= doc.pageCount else { return [] }
            return [JumpPalette.Entry(title: "Page \(number)", number: nil, pageIndex: number - 1, target: .page(number - 1))]
        }

        let palette = JumpPalette(kinds: kinds, pageCount: doc.pageCount, hasPrintedPages: hasPrintedPages,
                                  pagesAsPrinted: pagesAsPrinted, pages: pages) { [weak self] target, inSplit in
            self?.jump(to: target, inSplit: inSplit)
        }
        palette.onNumberingChange = { [weak self] asPrinted in self?.pagesAsPrinted = asPrinted }
        jumpPalette = palette
        paletteStart = currentPosition()
        paletteFollowed = false
        palette.onFollow = { [weak self] target in
            guard let self else { return }
            if !paletteFollowed { recordJump(from: paletteStart) }
            paletteFollowed = true
            go(to: target)
        }
        palette.onCancel = { [weak self] in self?.undoPaletteFollow() }
        // (Released after the call that closed it has returned.)
        palette.onClose = { [weak self] in DispatchQueue.main.async { self?.jumpPalette = nil } }
        palette.show(over: window)
    }

    private func jump(to target: JumpPalette.Target, inSplit: Bool) {
        guard inSplit else {
            recordJump(from: paletteStart)     // (already done if the document followed the palette)
            go(to: target)
            return
        }
        undoPaletteFollow()
        switch target {
        case .page(let index): showPageInSplit(index)
        case .section(let node): showInSplit(node)
        case .spot(let destination): openSplit(at: destination)
        case .annotation(let annotation):
            if let selection = Annotations.selection(of: annotation) { showInSplit(selection) }
        }
    }

    private func go(to target: JumpPalette.Target) {
        guard let doc = pdfView.document else { return }
        switch target {
        case .page(let index):
            guard let page = doc.page(at: index) else { return }
            pdfView.go(to: page)
        case .section(let node):
            go(to: node)
        case .spot(let destination):
            // Framed as in a link preview (a figure above its caption shown whole).
            pdfView.reveal(destination, column: textColumn, placement: Self.placement(for: destination))
        case .annotation(let annotation):
            show(annotation)
        }
    }

    /// A highlight brought into view (with a few lines above it, unless it is well in view
    /// already) and selected, so M, A and Delete act on it.
    private func show(_ annotation: PDFAnnotation) {
        guard let doc = pdfView.document, let page = annotation.page,
              let selection = Annotations.selection(of: annotation) else { return }
        let rect = pdfView.convert(annotation.bounds, from: page)
        if !pdfView.bounds.insetBy(dx: 0, dy: 60).contains(rect) {
            go(to: OutlineNode(id: -1, label: "", pageIndex: doc.index(for: page), pageLabel: "",
                               y: annotation.bounds.maxY + 36, initiallyOpen: false))
        }
        pdfView.setCurrentSelection(selection, animate: false)
    }

    /// Back to where the reading was before the document followed the palette (Esc, or the
    /// target shown in the split view instead).
    private func undoPaletteFollow() {
        guard paletteFollowed, let start = paletteStart else { return }
        paletteFollowed = false
        if let last = backStack.last, last.page == start.page, abs(last.y - start.y) < 5 { backStack.removeLast() }
        show(start)
    }

    @objc func revealInFinderAction(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Highlights

    /// M (or ⌃⌘H, as in Preview): highlights the selection; on a highlight, removes it; on an
    /// underline, turns it into a highlight.
    @objc func highlightSelectionAction(_ sender: Any?) { mark(as: .highlight) }

    /// U (or ⌃⌘U, as in Preview): the same for underlines.
    @objc func underlineSelectionAction(_ sender: Any?) { mark(as: .underline) }

    private func mark(as style: Annotations.Style) {
        Annotations.currentStyle = style
        let view = isSplitFocused ? splitPane ?? pdfView : pdfView
        guard let doc = view.document, let selection = view.currentSelection,
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let change = annotations.toggle(selection, as: style, color: Annotations.colors[colorIndex].color,
                                              in: doc) else { NSSound.beep(); return }
        // The selection stays: M again takes the highlight back.
        let name = style == .highlight ? "Highlight" : "Underline"
        registerUndo(of: change, name: change.added.isEmpty ? "Remove \(name)" : name)
        scheduleAnnotationSave()
    }

    /// 1–8 (or Edit → Colour): the colour of the selected annotations, or a highlight in that colour
    /// on plain selected text; it also becomes the colour of the next ones.
    func chooseColor(_ index: Int) {
        guard Annotations.colors.indices.contains(index) else { return }
        colorIndex = index
        MenuBuilder.updateColorChecks(index)
        let view = isSplitFocused ? splitPane ?? pdfView : pdfView
        guard let selection = view.currentSelection,
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let touched = Annotations.markup(touching: selection)
        if touched.isEmpty {
            mark(as: .highlight)
        } else {
            setColors(touched.map { ($0, Annotations.colors[index].color) })
        }
    }

    @objc func colorMenuAction(_ sender: NSMenuItem) { chooseColor(sender.tag) }

    private func setColors(_ colors: [(PDFAnnotation, NSColor)]) {
        guard let doc = pdfView.document else { return }
        let old = colors.map { ($0.0, $0.0.color) }
        for (annotation, color) in colors { annotations.setColor(color, of: annotation, in: doc) }
        window?.undoManager?.registerUndo(withTarget: self) { controller in controller.setColors(old) }
        window?.undoManager?.setActionName("Colour")
        scheduleAnnotationSave()
    }

    private func removeSelectedHighlights() -> Bool {
        let view = isSplitFocused ? splitPane ?? pdfView : pdfView
        guard let doc = view.document, let selection = view.currentSelection,
              let change = annotations.remove(touching: selection, in: doc) else { return false }
        view.clearSelection()
        registerUndo(of: change, name: "Remove Highlight")
        scheduleAnnotationSave()
        return true
    }

    /// File → Export Without Annotations: a clean copy to pass on; this file keeps its annotations.
    @objc func exportCleanAction(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " (clean).pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let destination = panel.url else { return }
            guard destination.standardizedFileURL != self.url else { NSSound.beep(); return }   // not over the open file
            let url = self.url
            Annotations.saveQueue.async {     // after any save still running
                let result = Result { try Annotations.writeClean(from: url, to: destination) }
                DispatchQueue.main.async {
                    guard case .failure(let error) = result else { return }
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t export “\(destination.lastPathComponent)”"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    /// Edit → Remove All Annotations: a clean document for a new start (undoable; the original
    /// also stays available through Revert to Original).
    @objc func removeAllAnnotationsAction(_ sender: Any?) {
        guard let doc = pdfView.document else { return }
        let count = Annotations.removableCount(in: doc)
        let alert = NSAlert()
        guard count > 0 else {
            alert.messageText = "“\(url.lastPathComponent)” has no annotations"
            alert.runModal()
            return
        }
        alert.messageText = "Remove all \(count == 1 ? "annotation" : "\(count) annotations") from “\(url.lastPathComponent)”?"
        alert.informativeText = "Highlights, underlines, comments and notes go, including ones made in other apps. "
            + "Links and form fields stay."
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let change = annotations.removeAll(in: doc) else { return }
        pdfView.clearSelection()
        splitPane?.clearSelection()
        registerUndo(of: change, name: "Remove All Annotations")
        scheduleAnnotationSave()
    }

    // MARK: Rotation

    /// View → Rotate Left / Rotate Right (no shortcuts: rarely needed): turns the page in view by
    /// a quarter turn, saved into the file like highlights; undoable.
    @objc func rotateLeftAction(_ sender: Any?) { rotateCurrentPage(by: -90, name: "Rotate Left") }
    @objc func rotateRightAction(_ sender: Any?) { rotateCurrentPage(by: 90, name: "Rotate Right") }

    private func rotateCurrentPage(by degrees: Int, name: String) {
        let view = isSplitFocused ? splitPane ?? pdfView : pdfView
        guard let page = view.currentPage else { return }
        rotate(page, by: degrees, name: name)
        view.go(to: page)
    }

    private func rotate(_ page: PDFPage, by degrees: Int, name: String) {
        guard let doc = pdfView.document else { return }
        closePreview()
        annotations.rotate(page, by: degrees, in: doc)
        for view in [pdfView, splitPane].compactMap({ $0 }) { view.layoutDocumentView() }
        model.pageRotated(doc.index(for: page))
        window?.undoManager?.registerUndo(withTarget: self) { controller in
            controller.rotate(page, by: -degrees, name: name)
        }
        window?.undoManager?.setActionName(name)
        scheduleAnnotationSave()
    }

    // MARK: Context menu

    /// A right-click (or ⌃-click) on the pages: a menu for the selected text or the annotation
    /// under the mouse (which gets selected first), instead of PDFKit's view options. Nowhere
    /// else is there a menu. macOS adds the user's services for text (search, AI assistants);
    /// which ones appear is their choice in System Settings, so they stay.
    private func showContextMenu(for event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        for view in [pdfView, splitPane].compactMap({ $0 }) {
            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else { continue }
            closePreview()
            window?.makeFirstResponder(view)
            if let page = view.page(for: point, nearest: false) {
                let pagePoint = view.convert(point, to: page)
                let inSelection = view.currentSelection.map {
                    $0.selectionsByLine().contains { $0.pages.contains(page) && $0.bounds(for: page).insetBy(dx: -2, dy: -2).contains(pagePoint) }
                } ?? false
                if !inSelection, let annotation = Annotations.selection(at: pagePoint, on: page) {
                    view.setCurrentSelection(annotation, animate: false)
                }
            }
            guard let selection = view.currentSelection,
                  !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            NSMenu.popUpContextMenu(contextMenu(for: selection, in: view), with: event, for: view)
            return true
        }
        return false
    }

    private func contextMenu(for selection: PDFSelection, in view: PDFView) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command, .control]
            item.target = target ?? self
            menu.addItem(item)
        }
        func colors(checked: Int) {
            let item = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (index, entry) in Annotations.colors.enumerated() {
                let color = NSMenuItem(title: "\(entry.name) (\(index + 1))", action: #selector(colorMenuAction(_:)), keyEquivalent: "")
                color.tag = index
                color.target = self
                color.image = MenuBuilder.swatch(entry.color)
                color.state = index == checked ? .on : .off
                submenu.addItem(color)
            }
            item.submenu = submenu
            menu.addItem(item)
        }
        let touched = Annotations.markup(touching: selection)
        if touched.isEmpty {
            add("Highlight", #selector(highlightSelectionAction(_:)), key: "h")
            add("Underline", #selector(underlineSelectionAction(_:)), key: "u")
            colors(checked: colorIndex)
            add("Add Comment…", #selector(commentAction(_:)))
        } else {
            let first = touched[0]
            add((first.contents ?? "").isEmpty ? "Add Comment…" : "Edit Comment…", #selector(commentAction(_:)))
            colors(checked: Annotations.nearestColor(to: first.color))
            let underlines = touched.filter { $0.type == "Underline" }.count
            if underlines < touched.count { add("Change to Underline", #selector(underlineSelectionAction(_:))) }
            if underlines > 0 { add("Change to Highlight", #selector(highlightSelectionAction(_:))) }
            menu.addItem(.separator())
            let what = touched.count > 1 ? "Annotations" : underlines > 0 ? "Underline" : "Highlight"
            add("Remove \(what)", #selector(removeAnnotationsAction(_:)))
        }
        menu.addItem(.separator())
        add("Copy", #selector(NSText.copy(_:)), target: view)
        menu.items.last?.keyEquivalent = "c"
        menu.items.last?.keyEquivalentModifierMask = .command
        return menu
    }

    @objc private func removeAnnotationsAction(_ sender: Any?) {
        if !removeSelectedHighlights() { NSSound.beep() }
    }

    private var commentPopover: NSPopover?
    /// The comment shown while the mouse is on its marker.
    private var hoverPopover: NSPopover?
    private weak var hoveredMarker: CommentMarker?

    /// Over a comment marker: its comment in a popover (returns true, so no link preview opens).
    private func updateCommentHover() -> Bool {
        var found: (CommentMarker, PDFView, PDFPage)?
        for view in [pdfView, splitPane].compactMap({ $0 }) {
            guard let window, let screenPoint = Optional(NSEvent.mouseLocation) else { break }
            let point = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
            guard view.bounds.contains(point), let page = view.page(for: point, nearest: false),
                  let marker = CommentMarker.at(view.convert(point, to: page), on: page) else { continue }
            found = (marker, view, page)
            break
        }
        guard let (marker, view, page) = found, let comment = marker.highlight?.contents, !comment.isEmpty else {
            if hoverPopover != nil {
                hoverPopover?.close()
                hoverPopover = nil
                hoveredMarker = nil
            }
            return false
        }
        if marker === hoveredMarker { return true }
        hoverPopover?.close()
        closePreview()
        let label = NSTextField(wrappingLabelWithString: comment)
        label.preferredMaxLayoutWidth = 280
        label.frame.size = label.fittingSize
        let content = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.width + 20, height: label.frame.height + 16))
        label.frame.origin = NSPoint(x: 10, y: 8)
        container.addSubview(label)
        content.view = container
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = content
        popover.show(relativeTo: view.convert(marker.bounds, from: page), of: view, preferredEdge: .maxY)
        hoverPopover = popover
        hoveredMarker = marker
        return true
    }

    /// A (Add Comment): a comment on the selected highlight (the selection is marked first if it
    /// isn't, in the style last used with M or U).
    @objc func commentAction(_ sender: Any?) {
        let view = isSplitFocused ? splitPane ?? pdfView : pdfView
        guard let doc = view.document, let selection = view.currentSelection,
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        if Annotations.markup(touching: selection).isEmpty {
            guard let change = annotations.toggle(selection, as: Annotations.currentStyle,
                                                  color: Annotations.colors[colorIndex].color,
                                                  in: doc) else { NSSound.beep(); return }
            registerUndo(of: change, name: Annotations.currentStyle == .underline ? "Underline" : "Highlight")
            scheduleAnnotationSave()
        }
        guard let annotation = Annotations.markup(touching: selection).first, let page = annotation.page else { return }
        closePreview()
        let old = annotation.contents
        let editor = CommentEditor(comment: old)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = editor
        popover.delegate = editor
        editor.popover = popover
        editor.onClose = { [weak self] text in
            guard let self else { return }
            let comment = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if comment != (old ?? "") { self.setComment(comment.isEmpty ? nil : comment, of: annotation, was: old) }
            self.commentPopover = nil
            self.window?.makeFirstResponder(view)
        }
        commentPopover = popover
        popover.show(relativeTo: view.convert(annotation.bounds, from: page), of: view, preferredEdge: .minY)
    }

    private func setComment(_ comment: String?, of annotation: PDFAnnotation, was old: String?) {
        guard let doc = pdfView.document else { return }
        annotations.setComment(comment, of: annotation, in: doc)
        window?.undoManager?.registerUndo(withTarget: self) { controller in
            controller.setComment(old, of: annotation, was: comment)
        }
        window?.undoManager?.setActionName("Comment")
        scheduleAnnotationSave()
    }

    private func registerUndo(of change: Annotations.Change, name: String) {
        window?.undoManager?.registerUndo(withTarget: self) { controller in
            controller.applyAnnotationChange(change.inverse, name: name)
        }
        window?.undoManager?.setActionName(name)
    }

    private func applyAnnotationChange(_ change: Annotations.Change, name: String) {
        guard let doc = pdfView.document else { return }
        annotations.apply(change, in: doc)
        registerUndo(of: change, name: name)
        scheduleAnnotationSave()
    }

    private func scheduleAnnotationSave() {
        if let doc = pdfView.document { Annotations.updateCommentMarkers(in: doc) }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(saveAnnotationsAction), object: nil)
        perform(#selector(saveAnnotationsAction), with: nil, afterDelay: 1)
    }

    /// File → Revert to Original: puts back the copy kept before Galley first wrote to the file.
    @objc func revertToOriginalAction(_ sender: Any?) {
        guard let original = try? Annotations.originalURL(of: url), FileManager.default.fileExists(atPath: original.path) else {
            let alert = NSAlert()
            alert.messageText = "Galley hasn’t changed “\(url.lastPathComponent)”"
            alert.informativeText = "There is no earlier version to go back to."
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Revert “\(url.lastPathComponent)” to the original?"
        alert.informativeText = "The file goes back to how it was before Galley first saved highlights into it. "
            + "All highlights and rotations made since then are removed, including any made in other apps."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(saveAnnotationsAction), object: nil)
        annotations.discard()
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: original)
        } catch {
            let failure = NSAlert(error: error)
            failure.runModal()
            return
        }
        _ = reloadDocument()
        loadedSignature = currentSignature()
        pendingSignature = nil
    }

    /// Saves in progress; while one runs, a changed file is our own write, not a reason to reload.
    private var savesInFlight = 0

    /// A second after the last change: saves in the background (PDFKit rewrites the whole file,
    /// which takes a noticeable moment).
    @objc private func saveAnnotationsAction() {
        guard let doc = pdfView.document, let batch = annotations.takeBatch(in: doc) else { return }
        let url = url
        savesInFlight += 1
        Annotations.saveQueue.async {
            let result = Result { try Annotations.write(batch, to: url) }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.saveFinished(batch, result) }
            }
        }
    }

    /// Saves and waits (closing the window, quitting, reloading).
    func saveAnnotationsNow() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(saveAnnotationsAction), object: nil)
        guard let doc = pdfView.document, let batch = annotations.takeBatch(in: doc) else { return }
        let url = url
        savesInFlight += 1
        let result = Annotations.saveQueue.sync { Result { try Annotations.write(batch, to: url) } }
        saveFinished(batch, result)
    }

    private func saveFinished(_ batch: Annotations.Batch, _ result: Result<Void, Error>) {
        savesInFlight -= 1
        if case .failure(let error) = result {
            annotations.saveFailed(batch)
            let alert = NSAlert()
            alert.messageText = "Couldn’t save the highlights in “\(url.lastPathComponent)”"
            alert.informativeText = error.localizedDescription + " The file was left unchanged."
            alert.runModal()
        }
        if savesInFlight == 0 {
            loadedSignature = currentSignature()     // our own write: no reload
            pendingSignature = nil
        }
    }

    // MARK: Window delegate

    // MARK: Window frame (remembered by Galley itself; macOS's autosave allows only one window per name)

    private static let frameKey = "GalleyLastWindowFrame"

    private func placeWindow(_ window: NSWindow) {
        guard let string = UserDefaults.standard.string(forKey: Self.frameKey) else {
            window.setContentSize(NSSize(width: 1100, height: 820))
            window.center()
            return
        }
        var frame = NSRectFromString(string)
        // Keep it on a connected screen (e.g. after unplugging a monitor).
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        // Don't stack exactly on top of another open Galley window.
        let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.windowController is DocumentWindowController }
        while others.contains(where: { $0.frame.origin == frame.origin }) {
            frame.origin.x += 24
            frame.origin.y -= 24
        }
        window.setFrame(frame, display: false)
    }

    private func rememberWindowFrame() {
        guard let window, window.isVisible, !window.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
    }

    func windowDidResize(_ notification: Notification) {
        rememberWindowFrame()
    }

    /// After a move, re-apply the zoom mode if the window ended up on another display.
    func windowDidMove(_ notification: Notification) {
        rememberWindowFrame()
        guard Self.displayID(of: window?.screen) != lastScreenNumber else { return }
        debugLog("trigger windowDidMove (new display)")
        scheduleZoomUpdate()
    }


    // MARK: Slide show

    /// View → Slide Show (⇧⌘F): full screen, one page at a time on black, without sidebar and
    /// toolbar; for any document. Plain full screen (⌃⌘F) stays the normal view.
    @objc func toggleSlideShowAction(_ sender: Any?) {
        guard let window else { return }
        if slideShowSaved != nil { endSlideShow(); return }
        if window.styleMask.contains(.fullScreen) {
            startSlideShow()
            refitSlide()
        } else {
            slideShowPending = true
            slideShowMadeFullScreen = true
            window.toggleFullScreen(nil)
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard slideShowPending else { return }
        slideShowPending = false
        startSlideShow()
    }

    /// PDFKit fitted the slide while the window was still growing: fit it again at full size.
    func windowDidEnterFullScreen(_ notification: Notification) {
        if slideShowSaved != nil { refitSlide() }
    }

    /// Leaving full screen some other way (green button, ⌃⌘F) ends the slide show too.
    func windowWillExitFullScreen(_ notification: Notification) {
        slideShowMadeFullScreen = false
        if slideShowSaved != nil { endSlideShow() }
    }

    /// PDFKit fits the slide itself (`autoScales` in single-page mode): it centers it without
    /// scrolling, where our own fit would be off by a fraction of a point and bring up a scroll bar.
    private func startSlideShow() {
        guard slideShowSaved == nil, let window else { return }
        let page = pdfView.currentPage
        slideShowSaved = (sidebarItem?.isCollapsed ?? true, window.toolbar?.isVisible ?? true,
                          window.titlebarSeparatorStyle, zoomMode, pdfView.scaleFactor, pdfView.displayMode)
        stopAutoScroll()
        closePreview()
        if splitPane != nil { closeSplit() }
        sidebarItem?.isCollapsed = true
        window.toolbar?.isVisible = false
        window.titlebarSeparatorStyle = .none
        pdfView.displayMode = .singlePage
        pdfView.displaysPageBreaks = false
        pdfView.pageShadowsEnabled = false
        pdfView.backgroundColor = .black
        setScrollBackground(.black)
        zoomMode = .fitPage
        pdfView.autoScales = true
        if let page { pdfView.go(to: page) }
        window.makeFirstResponder(pdfView)
    }

    private func refitSlide() {
        pdfView.autoScales = false
        pdfView.autoScales = true
        pdfView.layoutDocumentView()
    }

    /// Back to the view before the slide show, on the page it ended on; out of full screen if the
    /// slide show went into it.
    private func endSlideShow() {
        guard let saved = slideShowSaved else { return }
        slideShowSaved = nil
        let page = pdfView.currentPage
        pdfView.autoScales = false
        pdfView.displayMode = saved.displayMode
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = Self.canvasColor
        setScrollBackground(Self.canvasColor)
        window?.titlebarSeparatorStyle = saved.separator
        window?.toolbar?.isVisible = saved.toolbarVisible
        sidebarItem?.isCollapsed = saved.sidebarCollapsed
        zoomMode = saved.zoom
        if zoomMode == .custom { pdfView.scaleFactor = saved.scale }
        if let page { pdfView.go(to: page) }
        scheduleZoomUpdate()
        if slideShowMadeFullScreen {
            slideShowMadeFullScreen = false
            window?.toggleFullScreen(nil)
        }
    }

    /// Next/previous slide: Space, →, ↓, J, L, Page Down, Return and ⇧Space, ←, ↑, K, H, Page Up;
    /// Home/End the first and last; Esc ends the slide show. Other keys work as usual.
    private func handleSlideShowKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        if event.keyCode == 53, flags.isEmpty {
            endSlideShow()
            return true
        }
        if event.keyCode == 49, flags.isSubset(of: .shift) { return showSlide(by: flags == .shift ? -1 : 1) }
        if event.keyCode == 36 || event.keyCode == 76, flags.isEmpty { return showSlide(by: 1) }
        guard flags.isEmpty, let key = event.specialKey ?? Self.vimArrow(for: event, flags: flags) else { return false }
        switch key {
        case .rightArrow, .downArrow, .pageDown: return showSlide(by: 1)
        case .leftArrow, .upArrow, .pageUp: return showSlide(by: -1)
        case .home: return showSlide(by: -1_000_000)
        case .end: return showSlide(by: 1_000_000)
        default: return false
        }
    }

    @discardableResult
    private func showSlide(by delta: Int) -> Bool {
        guard let doc = pdfView.document, let current = pdfView.currentPage else { return false }
        let index = doc.index(for: current)
        let target = min(max(index + delta, 0), doc.pageCount - 1)
        if target == index {
            if abs(delta) == 1 { NSSound.beep() }
        } else if let page = doc.page(at: target) {
            pdfView.go(to: page)
            debugLog("slide \(target + 1)")
        }
        NSCursor.setHiddenUntilMouseMoves(true)
        return true
    }

    /// The area around the pages that PDFKit's own background doesn't cover (the scroll view's).
    private func setScrollBackground(_ color: NSColor) {
        guard let scroll = Self.findScrollView(in: pdfView) else { return }
        scroll.backgroundColor = color
        scroll.contentView.backgroundColor = color
    }

    func windowDidBecomeKey(_ notification: Notification) {
        MenuBuilder.updateColorChecks(colorIndex)
    }

    func windowDidResignKey(_ notification: Notification) {
        stopContinuousScroll()
        hideSwitcher()      // the ⌘ release would never reach us
        hideLinkHints()
        if heldHint != nil {
            endHeldHint()
            if heldHintPreviewShown { closePreview(); heldHintPreviewShown = false }
        }
    }

    func windowWillClose(_ notification: Notification) {
        saveAnnotationsNow()
        rememberWindowFrame()
        reloadTimer?.invalidate()
        reloadTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        closePreview()
        displayLink?.invalidate()
        displayLink = nil
        keyMonitor = nil
        isClosed = true
        (NSApp.delegate as? AppDelegate)?.controllerDidClose(self)
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .galleySearch]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .galleySearch:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.placeholderString = "Search"
            item.searchField.sendsSearchStringImmediately = false
            item.searchField.sendsWholeSearchString = false
            item.searchField.target = self
            item.searchField.action = #selector(searchFieldAction(_:))
            item.preferredWidthForSearchField = 220
            item.searchField.searchMenuTemplate = searchMenu()
            searchItem = item
            return item
        default:
            return nil
        }
    }
}
