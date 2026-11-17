import SwiftUI
import PDFKit

// MARK: - Data

struct OutlineNode: Identifiable {
    let id: Int
    let label: String
    let pageIndex: Int?
    let pageLabel: String
    let y: CGFloat
    let initiallyOpen: Bool
    var children: [OutlineNode]?
    /// The section number ("3.2"), shown in grey before the label.
    var number: String? = nil

    /// Number and label, for tooltips.
    var fullLabel: String { [number, label].compactMap { $0 }.joined(separator: " ") }
}

/// Flattened outline entry used to work out which section is currently on screen.
struct OutlineEntry {
    let id: Int
    let pageIndex: Int
    let y: CGFloat
}

struct SearchResult: Identifiable {
    let id: Int
    let pageIndex: Int
    let pageLabel: String
    /// The outline section the match is in (nil before the first heading or without an outline).
    let sectionID: Int?
    let snippet: AttributedString
    let selection: PDFSelection
}


/// What the sidebar shows: the table of contents or page thumbnails (for slides, scans, …).
enum SidebarMode { case outline, thumbnails }

@MainActor
final class ViewerModel: ObservableObject {
    @Published var sidebarMode: SidebarMode = .outline
    /// The page at the top of the view (highlighted among the thumbnails).
    @Published var currentPageIndex = 0
    /// Bumped when the file is reloaded, so thumbnails are drawn again.
    @Published var documentVersion = 0 { didSet { thumbnails.removeAllObjects() } }
    /// Bumped when the page colour changes, so thumbnails are drawn again.
    @Published var themeVersion = 0 { didSet { thumbnails.removeAllObjects() } }
    private let thumbnails = NSCache<NSNumber, NSImage>()

    /// A page was turned: its thumbnail is drawn again.
    func pageRotated(_ index: Int) {
        thumbnails.removeObject(forKey: index as NSNumber)
        objectWillChange.send()
    }

    /// A page drawn at thumbnail size (at twice the resolution, for Retina screens), kept for reuse.
    func thumbnail(for page: PDFPage, index: Int, size: NSSize) -> NSImage {
        if let image = thumbnails.object(forKey: index as NSNumber), image.size.width >= size.width * 2 { return image }
        let image = PageTheme.recolor(page.thumbnail(of: NSSize(width: size.width * 2, height: size.height * 2), for: .cropBox))
        thumbnails.setObject(image, forKey: index as NSNumber)
        return image
    }
    @Published var outline: [OutlineNode] = [] { didSet { rebuildParents() } }
    @Published var outlineTitle: OutlineNode?
    @Published var expanded: Set<Int> = []
    /// Sections expanded automatically to reveal the current one; collapsed again when we leave them.
    private var autoExpanded: Set<Int> = []
    @Published var currentSectionID: Int?
    @Published var searchText = ""
    @Published var results: [SearchResult] = []
    @Published var currentResult: Int?
    var flat: [OutlineEntry] = []
    weak var controller: DocumentWindowController?
    private var parents: [Int: Int] = [:]
    private var labels: [Int: String] = [:]

    /// Which sidebar row a search result belongs to: its section, -2 before the first heading,
    /// or (without an outline) its page.
    func searchKey(for result: SearchResult) -> Int {
        if outline.isEmpty { return -(10 + result.pageIndex) }
        return result.sectionID ?? -2
    }

    var matchCounts: [Int: Int] {
        var counts: [Int: Int] = [:]
        for result in results { counts[searchKey(for: result), default: 0] += 1 }
        return counts
    }

    /// The outline filtered to sections with matches and their parents, in reading order.
    var searchRows: [OutlineRowItem] {
        let counts = matchCounts
        func pseudoRow(_ id: Int, _ label: String, page: Int) -> OutlineRowItem {
            OutlineRowItem(node: OutlineNode(id: id, label: label, pageIndex: page, pageLabel: "",
                                             y: 0, initiallyOpen: false, children: nil), depth: 0)
        }
        if outline.isEmpty {
            return counts.keys.map { -$0 - 10 }.sorted().map { pseudoRow(-(10 + $0), "Page \($0 + 1)", page: $0) }
        }
        var keep = Set(counts.keys.filter { $0 >= 0 })
        for id in Array(keep) { keep.formUnion(ancestors(of: id)) }
        var rows = allRows.filter { keep.contains($0.id) }
        if counts[-2] != nil { rows.insert(pseudoRow(-2, "Before the first section", page: 0), at: 0) }
        return rows
    }

    /// Expansion state for a freshly opened document (top level plus anything the PDF marks as open).
    func resetExpansion() {
        var open: Set<Int> = []
        func walk(_ nodes: [OutlineNode]) {
            for node in nodes {
                if node.initiallyOpen, node.children != nil { open.insert(node.id) }
                walk(node.children ?? [])
            }
        }
        walk(outline)
        expanded = open
    }

    /// A new outline for the same document, after the file changed on disk. Row ids are just
    /// positions, so a section added or removed would move the open/closed state onto other
    /// sections: carry it over by name instead (new sections get their default).
    func replaceOutline(_ nodes: [OutlineNode]) {
        func keys(_ nodes: [OutlineNode]) -> [Int: String] {
            var result: [Int: String] = [:]
            func walk(_ nodes: [OutlineNode], path: String) {
                var seen: [String: Int] = [:]
                for node in nodes where node.children != nil {
                    let count = seen[node.fullLabel, default: 0]
                    seen[node.fullLabel] = count + 1
                    let key = path + "\u{1}" + node.fullLabel + (count > 0 ? "\u{2}\(count)" : "")
                    result[node.id] = key
                    walk(node.children ?? [], path: key)
                }
            }
            walk(nodes, path: "")
            return result
        }
        let old = keys(outline)
        let known = Set(old.values)
        let wasOpen = Set(expanded.compactMap { old[$0] }), wasAuto = Set(autoExpanded.compactMap { old[$0] })
        outline = nodes
        resetExpansion()
        autoExpanded = []
        for (id, key) in keys(nodes) where known.contains(key) {
            if wasOpen.contains(key) { expanded.insert(id) } else { expanded.remove(id) }
            if wasAuto.contains(key) { autoExpanded.insert(id) }
        }
    }

    func parentID(of id: Int) -> Int? { parents[id] }

    func toggle(_ id: Int) {
        autoExpanded.remove(id)          // a manual toggle makes it the user's choice
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func ancestors(of id: Int?) -> [Int] {
        var result: [Int] = []
        var current = id
        while let node = current, let parent = parents[node] {
            result.append(parent)
            current = parent
        }
        return result
    }

    /// Expands the path to a section (remembering which ones we opened ourselves).
    func reveal(_ id: Int) {
        for ancestor in ancestors(of: id) where !expanded.contains(ancestor) {
            expanded.insert(ancestor)
            autoExpanded.insert(ancestor)
        }
    }

    /// Updates the current section and collapses automatically expanded sections we have left.
    func setCurrentSection(_ id: Int?) {
        if currentSectionID != id { currentSectionID = id }
        let keep = Set(ancestors(of: id))
        let leave = autoExpanded.subtracting(keep)
        guard !leave.isEmpty else { return }
        autoExpanded.subtract(leave)
        expanded.subtract(leave)
    }

    /// Every outline row in reading order, collapsed or not.
    var allRows: [OutlineRowItem] {
        var rows: [OutlineRowItem] = []
        func walk(_ nodes: [OutlineNode], depth: Int) {
            let column = numberColumns[depth] ?? 0
            for node in nodes {
                rows.append(OutlineRowItem(node: node, depth: depth, numberWidth: column, indent: indent(depth)))
                walk(node.children ?? [], depth: depth + 1)
            }
        }
        walk(outline, depth: 0)
        return rows
    }

    /// The outline rows that are currently visible, flattened with their depth.
    var visibleRows: [OutlineRowItem] {
        var rows: [OutlineRowItem] = []
        func walk(_ nodes: [OutlineNode], depth: Int) {
            let column = numberColumns[depth] ?? 0
            for node in nodes {
                rows.append(OutlineRowItem(node: node, depth: depth, numberWidth: column, indent: indent(depth)))
                if let children = node.children, expanded.contains(node.id) {
                    walk(children, depth: depth + 1)
                }
            }
        }
        walk(outline, depth: 0)
        return rows
    }

    /// The row to highlight: the current section, or its nearest visible ancestor if it is collapsed away.
    var highlightedRowID: Int? {
        guard var id = currentSectionID else { return nil }
        var chain: [Int] = [id]
        while let parent = parents[id] { chain.append(parent); id = parent }
        // Walk from the top: the first collapsed ancestor hides everything below it.
        for ancestor in chain.reversed().dropLast() where !expanded.contains(ancestor) {
            return ancestor
        }
        return currentSectionID
    }

    /// The number column's width per level, as wide as the widest number at that level anywhere
    /// in the outline, so titles of a level line up across sections.
    private(set) var numberColumns: [Int: CGFloat] = [:]

    /// Each level is indented past its parent level's numbers (or by the chevron's width where
    /// that level has none), so child numbers line up under the parent titles.
    func indent(_ depth: Int) -> CGFloat {
        (0..<depth).reduce(0) { total, level in
            let column = numberColumns[level] ?? 0
            return total + (column > 0 ? column + OutlineRowView.numberGap : OutlineRowView.indent)
        }
    }

    private func rebuildParents() {
        var numbers: [Int: [OutlineNode]] = [:]
        func collect(_ nodes: [OutlineNode], depth: Int) {
            numbers[depth, default: []] += nodes
            for node in nodes { collect(node.children ?? [], depth: depth + 1) }
        }
        collect(outline, depth: 0)
        numberColumns = [:]
        for depth in numbers.keys { numberColumns[depth] = OutlineRowView.numberColumn(numbers[depth]!, depth: depth) }
        var map: [Int: Int] = [:]
        var names: [Int: String] = [:]
        func walk(_ nodes: [OutlineNode], parent: Int?) {
            for node in nodes {
                names[node.id] = node.label
                if let parent { map[node.id] = parent }
                walk(node.children ?? [], parent: node.id)
            }
        }
        walk(outline, parent: nil)
        parents = map
        labels = names
    }
}

struct OutlineRowItem: Identifiable {
    let node: OutlineNode
    let depth: Int
    /// Width of the number column shared by this row's level (0 without numbers).
    var numberWidth: CGFloat = 0
    /// Leading indentation: a child level's numbers start where its parent level's titles do.
    var indent: CGFloat = 0
    var id: Int { node.id }
}

enum OutlineBuilder {
    struct Result {
        var nodes: [OutlineNode]
        var flat: [OutlineEntry]
        /// Set when the whole outline hangs off a single entry (usually the document title).
        var title: OutlineNode?
    }

    @MainActor
    static func build(_ doc: PDFDocument) -> Result {
        let detected = OutlineDetector.outline(for: doc)
        var counter = 0
        var flat: [OutlineEntry] = []

        func node(_ item: OutlineDetector.Item) -> OutlineNode {
            let id = counter
            counter += 1
            if let pageIndex = item.pageIndex {
                flat.append(OutlineEntry(id: id, pageIndex: pageIndex, y: item.y))
            }
            let kids = item.children.map(node)
            return OutlineNode(id: id,
                               label: item.label,
                               pageIndex: item.pageIndex,
                               pageLabel: item.pageIndex.map { "\($0 + 1)" } ?? "",   // PDF page numbers, not the printed labels
                               y: item.y,
                               initiallyOpen: item.isOpen,
                               children: kids.isEmpty ? nil : kids,
                               number: item.number)
        }

        let nodes = detected.items.map(node)
        let title = detected.title.map { item in
            OutlineNode(id: -1, label: item.label, pageIndex: item.pageIndex,
                        pageLabel: item.pageIndex.map { "\($0 + 1)" } ?? "", y: item.y,
                        initiallyOpen: false, children: nil)
        }
        return Result(nodes: nodes, flat: flat, title: title)
    }
}

/// The user's preferred Reading Size (set with Option-Cmd-+ / Option-Cmd--), the same on every display.
enum ReadingSizeStore {
    private static let key = "GalleyReadingSizePreference"   // relative to the measured text size

    static var factor: CGFloat {
        get {
            let value = UserDefaults.standard.double(forKey: key)
            return value > 0 ? CGFloat(value) : 1
        }
        set {
            UserDefaults.standard.set(Double(min(max(newValue, 0.5), 3)), forKey: key)
            NotificationCenter.default.post(name: ReadingSizeStore.didChange, object: nil)
        }
    }

    /// Posted when the preference changes, so every window in Reading Size updates at once.
    static let didChange = Notification.Name("GalleyReadingSizeDidChange")

}

// MARK: - Views

struct SidebarView: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        if !model.searchText.isEmpty {
            SearchOutlineView(model: model)
        } else {
            VStack(spacing: 0) {
                Picker("Sidebar", selection: $model.sidebarMode) {
                    Image(systemName: "list.bullet.indent").help("Table of Contents").tag(SidebarMode.outline)
                    Image(systemName: "rectangle.grid.1x2").help("Page Thumbnails").tag(SidebarMode.thumbnails)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                switch model.sidebarMode {
                case .thumbnails:
                    if let document = model.controller?.pdfView.document {
                        ThumbnailList(model: model, document: document)
                    }
                case .outline:
                    if model.outline.isEmpty {
                        ContentUnavailableView("No Table of Contents",
                                               systemImage: "list.bullet.indent",
                                               description: Text("This PDF doesn’t include an outline, and no headings were found in its text."))
                            .frame(maxHeight: .infinity)
                    } else {
                        OutlineList(model: model)
                    }
                }
            }
        }
    }
}

/// Page thumbnails in one column, like Preview's: a thin border instead of a shadow, the current
/// page on a rounded grey background with its number in an accent-colored capsule.
struct ThumbnailList: View {
    @ObservedObject var model: ViewerModel
    let document: PDFDocument
    @FocusState private var isFocused: Bool
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let current = model.currentPageIndex
        let emphasized = isFocused && activeState == .key
        GeometryReader { geometry in
        let box = ThumbnailCell.box(forWidth: geometry.size.width)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(0..<document.pageCount, id: \.self) { index in
                        if let page = document.page(at: index) {
                            ThumbnailCell(page: page, index: index, rotation: page.rotation, themeVersion: model.themeVersion,
                                          isCurrent: index == current, isEmphasized: emphasized, box: box, model: model)
                                .id(index)
                                .onTapGesture {
                                    isFocused = true
                                    if NSEvent.modifierFlags.contains(.command) {
                                        model.controller?.showPageInSplit(index)   // ⌘-click: in the split view
                                    } else {
                                        model.controller?.showPage(index)
                                    }
                                }
                        }
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { _, newValue in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(newValue) }
            }
        }
        }
        .id(model.documentVersion)       // a reloaded file starts afresh
    }
}

struct ThumbnailCell: View {
    let page: PDFPage
    let index: Int
    /// The page's rotation (a turned page gets a new cell size and image).
    let rotation: Int
    /// The page colour's version: passed in, not read from `model`, so a new colour redraws the
    /// cells already on screen (a plain `model` reference doesn't make SwiftUI update them).
    let themeVersion: Int
    let isCurrent: Bool
    let isEmphasized: Bool
    let box: NSSize
    let model: ViewerModel
    @State private var image: NSImage?

    /// Like Preview's largest thumbnails (about two and a half pages in view), smaller in a narrow sidebar;
    /// wide slides fill the width.
    static func box(forWidth width: CGFloat) -> NSSize {
        let fitted = min(260, max(width - 40, 60)).rounded()
        return NSSize(width: fitted, height: (fitted * 1.3).rounded())
    }

    private var size: NSSize {
        var bounds = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { bounds = NSSize(width: bounds.height, height: bounds.width) }
        let scale = min(box.width / max(bounds.width, 1), box.height / max(bounds.height, 1))
        return NSSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }

    var body: some View {
        let size = self.size
        VStack(spacing: 5) {
            Group {
                if let image {
                    Image(nsImage: image).resizable()
                } else {
                    Color.white
                }
            }
            .frame(width: size.width, height: size.height)
            .overlay(Rectangle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
            .padding(8)
            .background {
                if isCurrent { RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.22)) }
            }
            Text(page.label.flatMap { $0.isEmpty ? nil : $0 } ?? "\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(isCurrent && isEmphasized ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background {
                    if isCurrent {
                        Capsule().fill(isEmphasized ? Color.accentColor : Color.secondary.opacity(0.22))
                    }
                }
        }
        .contentShape(Rectangle())
        .task(id: "\(model.documentVersion) \(themeVersion) \(rotation) \(size.width)") { image = model.thumbnail(for: page, index: index, size: size) }
    }
}

struct OutlineList: View {
    @ObservedObject var model: ViewerModel
    @FocusState private var isFocused: Bool
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let rows = model.visibleRows
        let highlighted = model.highlightedRowID
        // Like any macOS list: accent-colored selection while the sidebar has focus, grey otherwise.
        let emphasized = isFocused && activeState == .key
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        OutlineRowView(row: row,
                                       isCurrent: row.id == highlighted,
                                       isEmphasized: emphasized,
                                       isExpanded: model.expanded.contains(row.id),
                                       model: model,
                                       onSelect: { isFocused = true })
                            .id(row.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onChange(of: highlighted) { _, newValue in
                if let newValue {
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(newValue) }
                }
            }
        }
    }

}

struct OutlineRowView: View {
    let row: OutlineRowItem
    let isCurrent: Bool
    let isEmphasized: Bool
    let isExpanded: Bool
    let model: ViewerModel
    let onSelect: () -> Void
    /// While searching: the number of matches in this section (nil = none), shown as a badge.
    var badge: Int? = nil
    /// While searching the tree is fully expanded, without disclosure arrows; a click selects
    /// the section's first match.
    var searchMode = false
    /// While searching: part of the current match's chapter, faintly tinted as one block
    /// (rounded at its first and last row).
    var chapterTint: (isFirst: Bool, isLast: Bool)? = nil

    /// macOS's "small" sidebar row height (also Finder's list rows).
    static let rowHeight: CGFloat = 24
    /// Indent per level: chevron width plus spacing, so a child's text lines up under its parent's title.
    static let indent: CGFloat = 16
    /// Space between a section number and its title.
    static let numberGap: CGFloat = 4

    private var titleFont: Font { Font(Self.nsFont(depth: row.depth)) }

    /// The title font per level (body semibold, body, callout), with digits of equal width so
    /// numbers line up.
    static func nsFont(depth: Int) -> NSFont {
        switch depth {
        case 0: return .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        case 1: return .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        default: return .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        }
    }

    /// The width of the widest number among these entries (0 if none is numbered).
    static func numberColumn(_ nodes: [OutlineNode], depth: Int) -> CGFloat {
        let font = nsFont(depth: depth)
        let widest = nodes.compactMap(\.number).map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max()
        return widest.map { ceil($0) } ?? 0
    }

    private var onAccent: Bool { isCurrent && isEmphasized }

    private var titleStyle: AnyShapeStyle {
        if onAccent { return AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor)) }
        return row.depth >= 2 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
    }

    private var detailStyle: AnyShapeStyle {
        onAccent ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor).opacity(0.8))
                 : AnyShapeStyle(.tertiary)
    }

    private var chevronStyle: AnyShapeStyle {
        onAccent ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor)) : AnyShapeStyle(.secondary)
    }

    var body: some View {
        HStack(spacing: 2) {
            if row.node.children != nil && !searchMode {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { model.toggle(row.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(chevronStyle)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 14, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if !searchMode {
                Color.clear.frame(width: 14, height: 16)
            }
            // The number in the page numbers' grey, in a column per level, so numbers and titles
            // of a level each start at one edge.
            if row.numberWidth > 0 {
                Text(row.node.number ?? "")
                    .font(titleFont)
                    .foregroundStyle(detailStyle)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: row.numberWidth, alignment: .leading)
                    .padding(.trailing, Self.numberGap)
            }
            Text(row.node.label)
                .font(titleFont)
                .foregroundStyle(titleStyle)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if searchMode {
                if let badge {
                    Text("\(badge)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(onAccent ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor))
                                                  : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(onAccent ? Color.white.opacity(0.25) : Color.secondary.opacity(0.15)))
                }
            } else {
                Text(row.node.pageLabel)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(detailStyle)
            }
        }
        .padding(.leading, row.indent + 2)
        .padding(.trailing, 6)
        .frame(minHeight: Self.rowHeight)
        .background {
            if let tint = chapterTint {
                UnevenRoundedRectangle(topLeadingRadius: tint.isFirst ? 5 : 0, bottomLeadingRadius: tint.isLast ? 5 : 0,
                                       bottomTrailingRadius: tint.isLast ? 5 : 0, topTrailingRadius: tint.isFirst ? 5 : 0)
                    .fill(Color.primary.opacity(0.045))   // the selection's grey, lighter
            }
            if isCurrent { SelectionBackground(emphasized: isEmphasized) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
            let inSplit = NSEvent.modifierFlags.contains(.command)   // ⌘-click: in the split view
            switch (searchMode, inSplit) {
            case (true, false): model.controller?.selectFirstResult(forKey: row.id)
            case (true, true): model.controller?.showFirstResultInSplit(forKey: row.id)
            case (false, false): model.controller?.navigate(to: row.node)
            case (false, true): model.controller?.showInSplit(row.node)
            }
        }
        .help(row.node.fullLabel)
    }
}

/// While searching, the sidebar shows the outline filtered to the sections with matches
/// (plus their parents), fully expanded, with a count badge on each. The current match's section
/// is selected; the document shows the context.
struct SearchOutlineView: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        let counts = model.matchCounts
        let rows = model.searchRows
        let currentKey = model.currentResult.flatMap { index in
            model.results.indices.contains(index) ? model.searchKey(for: model.results[index]) : nil
        }
        // The current match's chapter: its row and everything under it (they follow it).
        let chapter = currentKey.flatMap { key in key >= 0 ? (model.ancestors(of: key).last ?? key) : nil }
        let block = chapter.map { chapter in
            Set(rows.map(\.id).filter { $0 == chapter || model.ancestors(of: $0).contains(chapter) })
        } ?? []
        let blockFirst = rows.first { block.contains($0.id) }?.id
        let blockLast = rows.last { block.contains($0.id) }?.id
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(summary(sections: counts.count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)          // aligned with the top-level section titles
                        .padding(.bottom, 6)
                    ForEach(rows) { row in
                        OutlineRowView(row: row,
                                       isCurrent: row.id == currentKey,
                                       // Grey, as in the outline: the list shows where you are; the
                                       // keys go to the search field and the document.
                                       isEmphasized: false,
                                       isExpanded: true,
                                       model: model,
                                       onSelect: {},
                                       badge: counts[row.id],
                                       searchMode: true,
                                       chapterTint: block.contains(row.id)
                                           ? (row.id == blockFirst, row.id == blockLast) : nil)
                            .id(row.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onAppear {
                if let currentKey { proxy.scrollTo(currentKey, anchor: .center) }
            }
            .onChange(of: currentKey) { _, newValue in
                if let newValue { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(newValue, anchor: .center) } }
            }
        }
    }

    private func summary(sections: Int) -> String {
        let count = model.results.count
        guard count > 0 else { return "No matches" }
        if let current = model.currentResult { return "Match \(current + 1) of \(count)" }
        return count == 1 ? "1 match" : "\(count) matches"
    }
}

/// The system's own selection highlight, as drawn by sidebars and lists: a vibrant material that
/// is accent-colored when emphasized (focused) and grey otherwise, blended with the sidebar.
struct SelectionBackground: NSViewRepresentable {
    var emphasized: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .selection
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        view.wantsLayer = true
        view.layer?.cornerRadius = 5
        view.layer?.masksToBounds = true
        view.isEmphasized = emphasized
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.isEmphasized = emphasized
    }
}
