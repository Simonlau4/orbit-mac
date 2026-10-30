import SwiftUI
import AppKit

enum OrbitTheme {
    static let background = Color(red: 0.12, green: 0.14, blue: 0.21)
    static let raised = Color(red: 0.16, green: 0.19, blue: 0.28)
    static let surface = Color.white.opacity(0.045)
    static let border = Color.white.opacity(0.10)
    static let secondary = Color(red: 0.69, green: 0.74, blue: 0.82)
    static let mint = Color(red: 0.40, green: 0.88, blue: 0.76)
    static let blue = Color(red: 0.40, green: 0.67, blue: 1)
    static let amber = Color(red: 1, green: 0.77, blue: 0.42)
    static let gradientTop = Color(red: 0.15, green: 0.19, blue: 0.30)
    static let logoInk = Color(red: 0.18, green: 0.17, blue: 0.14)
    static let logoFill = Color(red: 0.96, green: 0.95, blue: 0.91)
    static let subtleSurface = Color.white.opacity(0.035)
    static let filterSurface = Color.white.opacity(0.04)
    static let tabSurface = Color.white.opacity(0.065)
    static let tabBorder = Color.white.opacity(0.06)
    static let contrastBorder = Color.white.opacity(0.3)
    static let selected = Color.white
    static let treemapColors: [Color] = [blue, mint, Color(red: 0.61, green: 0.53, blue: 0.90), amber, Color(red: 0.36, green: 0.65, blue: 0.76)]
    static let cardHeadingSize: CGFloat = 14
}

struct Surface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    var padding: CGFloat = 22
    func body(content: Content) -> some View {
        content.padding(padding)
            .background(OrbitTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(contrast == .increased ? OrbitTheme.contrastBorder : OrbitTheme.border, lineWidth: 1))
    }
}

extension View {
    func orbitCard(padding: CGFloat = 22) -> some View { modifier(Surface(padding: padding)) }
    func orbitSelection(_ selected: Bool) -> some View { modifier(SelectionCapsule(selected: selected)) }
    func fileContextMenu(_ url: URL, revealURL: URL? = nil) -> some View {
        contextMenu {
            Button("在 Finder 中显示") { reveal(revealURL ?? url) }
            Button("拷贝路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) }
        }
    }
}

private struct SelectionCapsule: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    let selected: Bool
    func body(content: Content) -> some View {
        content.foregroundStyle(selected ? OrbitTheme.background : OrbitTheme.secondary)
            .background(selected ? OrbitTheme.selected : OrbitTheme.filterSurface, in: Capsule())
            .overlay(Capsule().stroke(contrast == .increased ? OrbitTheme.contrastBorder : .clear))
    }
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold))
            .foregroundStyle(OrbitTheme.background)
            .padding(.horizontal, 28).padding(.vertical, 13)
            .background(Color.white.opacity(configuration.isPressed ? 0.78 : 1), in: Capsule())
            .opacity(enabled ? 1 : 0.35)
    }
}

struct QuietButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.6 : 0.9))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color.white.opacity(configuration.isPressed ? 0.12 : 0.06), in: Capsule())
            .overlay(Capsule().stroke(contrast == .increased ? OrbitTheme.contrastBorder : OrbitTheme.border))
            .opacity(enabled ? 1 : 0.35)
    }
}

struct CleanupGroupToggle: View {
    let ids: Set<String>
    @Binding var selection: Set<String>
    let title: String
    var body: some View {
        let value = GroupSelectionState(ids: ids, selection: selection)
        let sources = [Binding(get: { value != .none }, set: select), Binding(get: { value == .all }, set: select)]
        Toggle(sources: sources, isOn: \.self) { EmptyView() }.labelsHidden().toggleStyle(.checkbox).accessibilityLabel(title)
    }
    private func select(_ selected: Bool) {
        let next = GroupSelectionState.selecting(selected, ids: ids, in: selection)
        if next != selection { selection = next }
    }
}

struct Dot: View {
    var color = OrbitTheme.mint
    var body: some View { Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true) }
}

struct Sparkline: View {
    let values: [Double]
    var color = OrbitTheme.mint
    var ceiling: Double = 100
    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let top = max(ceiling, values.max() ?? 1, 1)
            let points = values.enumerated().map { index, value in
                CGPoint(x: size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1)), y: size.height * (1 - min(max(value / top, 0), 1)))
            }
            var stroke = Path(); stroke.addLines(points)
            var fill = stroke
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height)); fill.closeSubpath()
            context.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.2), color.opacity(0.01)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(stroke, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }.accessibilityHidden(true)
    }
}
