import SwiftUI
import OrbitCore

struct DiskTreemap: View {
    let entries: [DiskEntry]
    var onSelect: (DiskEntry) -> Void
    private let colors = OrbitTheme.treemapColors
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(rectangles(in: CGRect(origin: .zero, size: geometry.size)), id: \.entry.id) { item in
                    TreemapTile(entry: item.entry, size: item.rect.size, color: colors[item.index % colors.count], action: { onSelect(item.entry) })
                        .offset(x: item.rect.minX + 2, y: item.rect.minY + 2)
                }
            }
        }
    }

    private struct Tile { let entry: DiskEntry; let rect: CGRect; let index: Int }

    private func rectangles(in bounds: CGRect) -> [Tile] {
        func split(_ values: [(Int, DiskEntry)], _ rect: CGRect) -> [Tile] {
            guard let first = values.first else { return [] }
            if values.count == 1 { return [Tile(entry: first.1, rect: rect, index: first.0)] }
            let total = values.reduce(0.0) { $0 + Double(max(1, $1.1.bytes)) }
            var sum = 0.0
            var cut = 1
            for i in 0..<(values.count - 1) {
                sum += Double(max(1, values[i].1.bytes)); cut = i + 1
                if sum >= total / 2 { break }
            }
            let ratio = CGFloat(sum / total)
            let a: CGRect; let b: CGRect
            if rect.width > rect.height {
                a = CGRect(x: rect.minX, y: rect.minY, width: rect.width * ratio, height: rect.height)
                b = CGRect(x: a.maxX, y: rect.minY, width: rect.width - a.width, height: rect.height)
            } else {
                a = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * ratio)
                b = CGRect(x: rect.minX, y: a.maxY, width: rect.width, height: rect.height - a.height)
            }
            return split(Array(values.prefix(cut)), a) + split(Array(values.dropFirst(cut)), b)
        }
        return split(Array(entries.enumerated()).map { ($0.offset, $0.element) }, bounds)
    }
}

private struct TreemapTile: View {
    let entry: DiskEntry
    let size: CGSize
    let color: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                if size.width > 65 && size.height > 36 {
                    Text(entry.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if size.height > 63 { Text(prettyBytes(entry.bytes)).font(.system(size: 11)).opacity(0.75) }
                }
                Spacer(minLength: 0)
            }
            .padding(13)
            .frame(width: max(0, size.width - 4), height: max(0, size.height - 4), alignment: .topLeading)
            .background(color.opacity(0.32), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .help(entry.name + " · " + prettyBytes(entry.bytes))
        .accessibilityLabel(entry.name + "，" + prettyBytes(entry.bytes) + "，打开此项目")
    }
}
