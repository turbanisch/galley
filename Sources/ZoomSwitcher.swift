import SwiftUI

extension ZoomMode {
    var title: String {
        switch self {
        case .fitPage: return "Fit Page"
        case .readingSize: return "Reading Size"
        case .fitWidth: return "Fit Width"
        case .fitText: return "Fit Text Width"
        case .actualSize: return "Actual Size"
        case .custom: return "Custom Zoom"
        }
    }

    var symbol: String {
        switch self {
        case .fitPage: return "rectangle.portrait"
        case .readingSize: return "book"
        case .fitWidth: return "arrow.left.and.right"
        case .fitText: return "text.justify"
        case .actualSize: return "ruler"
        case .custom: return "plus.magnifyingglass"
        }
    }
}

/// Zoom modes in most-recently-used order, one per window (switching in one window doesn't
/// reorder another's).
struct ZoomHistory {
    var order: [ZoomMode] = [.readingSize, .fitPage, .fitWidth, .fitText, .actualSize]   // opens in Reading Size

    mutating func use(_ mode: ZoomMode) {
        guard mode != .custom else { return }
        order.removeAll { $0 == mode }
        order.insert(mode, at: 0)
    }
}

/// One entry in a switcher: a zoom mode (with its symbol) or a page colour (with a swatch).
struct SwitcherItem: Identifiable {
    enum Icon {
        case symbol(String)
        case swatch(Color)
    }

    let title: String
    let icon: Icon
    var id: String { title }
}

/// The ⌘0 and ⌘9 panels (zoom mode, page colour), in the style of the ⌘Tab app switcher.
struct SwitcherView: View {
    let items: [SwitcherItem]
    let selected: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let isSelected = index == selected
                HStack(spacing: 10) {
                    switch item.icon {
                    case .symbol(let name):
                        Image(systemName: name)
                            .frame(width: 20)
                    case .swatch(let color):
                        Circle()
                            .fill(color)
                            .frame(width: 14, height: 14)
                            .frame(width: 20)
                    }
                    // As wide as in bold, so the panel doesn't change width as the selection moves.
                    ZStack(alignment: .leading) {
                        Text(item.title).font(.body.weight(.semibold)).hidden()
                        Text(item.title)
                            .font(.body.weight(isSelected ? .semibold : .regular))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(8)
        .fixedSize()     // as wide as the longest title
    }
}

/// Brief confirmation shown when Reading Size is adjusted or reset.
struct NoticeView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.headline.monospacedDigit())
            if !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}
