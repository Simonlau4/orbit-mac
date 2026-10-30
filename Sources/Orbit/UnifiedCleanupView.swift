import SwiftUI
import OrbitCore

struct CleanupResultsView: View {
    @EnvironmentObject var state: AppState
    @State private var query = ""
    @State private var showOrdinary = false
    @State private var expandedFolds: Set<CleanupTier> = []
    @FocusState private var searchFocused: Bool
    @State private var tiers: [CleanupTierSection] = []
    @State private var searched = false

    var body: some View {
        if showOrdinary {
            OrdinaryCleanupResultsView(onBack: { showOrdinary = false })
        } else {
            let index = state.cleanupIndex, ai = aiBytes
            VStack(spacing: 14) {
                HStack {
                    PageHeading(eyebrow: "", title: "可以释放 " + prettyBytes(index.totalBytes), subtitle: "推荐清理已默认勾选 · 移入废纸篓后可在清理记录中恢复")
                    Button("重新扫描") { state.scanCleanup() }.buttonStyle(QuietButton()).disabled(state.scanning || state.working)
                    Button { state.showResults = false } label: { Image(systemName: "xmark").padding(8) }.buttonStyle(.plain).accessibilityLabel("返回清理首页").help("返回清理首页")
                }
                HStack {
                    if let scan = state.unifiedScan, scan.isPartial {
                        Label("部分目录没有扫描完，可清理的可能比显示的多", systemImage: "exclamationmark.circle").foregroundStyle(OrbitTheme.amber)
                        Button("检查读取权限") { state.openReadPermissions() }.buttonStyle(.link).foregroundStyle(OrbitTheme.blue)
                    }
                    Spacer()
                    Button("逐个文件查看") { showOrdinary = true }.buttonStyle(.link).foregroundStyle(OrbitTheme.blue)
                    TextField("搜索", text: $query).textFieldStyle(.roundedBorder).frame(width: 150).focused($searchFocused).accessibilityLabel("搜索可清理项目")
                }.font(.system(size: 11))
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(tiers) { tierCard($0) }
                        if query.isEmpty, ai != nil, !tiers.contains(where: { $0.tier == .decide }) {
                            VStack(alignment: .leading, spacing: 0) { tierHeading(.decide, ids: [], bytes: nil); aiRow }.orbitCard(padding: 18)
                        }
                        if query.isEmpty { holdNotes(index) }
                    }
                }.overlay {
                    if searched && tiers.isEmpty && (ai == nil || !query.isEmpty) {
                        Text(query.isEmpty ? "没有发现可以清理的内容" : "没有匹配 “\(query)” 的项目").foregroundStyle(OrbitTheme.secondary)
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("已选 " + prettyBytes(state.selectedBytes) + " · \(state.selection.count.formatted()) 个文件").font(.system(size: 14, weight: .medium))
                        Text("移入废纸篓后仍占空间，清空废纸篓才会释放。").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                    }
                    Spacer()
                    Button("移入废纸篓") { state.confirmCleaning = true }.buttonStyle(PrimaryButton()).disabled(state.selection.isEmpty || state.scanning || state.working)
                }
            }.padding(.horizontal, 40).padding(.vertical, 14)
                .background { Button("搜索可清理项目") { searchFocused = true }.keyboardShortcut("f").hidden().accessibilityHidden(true) }
                .task(id: CleanupSearchKey(scanID: state.cleanupResultsID, query: query)) {
                    let index = state.cleanupIndex, query = query
                    if !query.isEmpty { do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return } }
                    let result = await Task.detached(priority: .userInitiated) { index.tiers(query) }.value
                    guard !Task.isCancelled else { return }
                    tiers = result; searched = true
                }
        }
    }

    private var aiBytes: Int64? {
        guard let scan = state.unifiedScan, !scan.ai.items.isEmpty || scan.bytes(in: .ai) > 0 else { return nil }
        return scan.bytes(in: .ai)
    }

    private func tierHeading(_ tier: CleanupTier, ids: Set<String>, bytes: Int64?) -> some View {
        HStack(spacing: 12) {
            if !ids.isEmpty { CleanupGroupToggle(ids: ids, selection: $state.selection, title: "选择全部" + tier.title) }
            Text(tier.title).font(.system(size: 14, weight: .semibold))
            Text(tier.note).font(.system(size: 11)).foregroundStyle(tier == .recommended ? OrbitTheme.mint : OrbitTheme.amber)
            Spacer()
            if let bytes { Text(prettyBytes(bytes)).font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(OrbitTheme.blue) }
        }.padding(.bottom, 6)
    }

    private func tierCard(_ section: CleanupTierSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            tierHeading(section.tier, ids: section.ids, bytes: section.bytes)
            ForEach(section.rows) { row($0) }
            if !section.folded.isEmpty {
                DisclosureGroup(isExpanded: Binding(get: { expandedFolds.contains(section.tier) }, set: { if $0 { expandedFolds.insert(section.tier) } else { expandedFolds.remove(section.tier) } })) {
                    ForEach(section.folded) { row($0) }
                } label: {
                    let ids = section.folded.reduce(into: Set<String>()) { $0.formUnion($1.ids) }
                    HStack(spacing: 12) {
                        CleanupGroupToggle(ids: ids, selection: $state.selection, title: "选择其他 \(section.folded.count) 项")
                        VStack(alignment: .leading, spacing: 3) {
                            Text("其他 \(section.folded.count) 项").font(.system(size: 13, weight: .medium))
                            Text(section.folded.prefix(3).map(\.advice.title).joined(separator: "、") + " 等较小的项目").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        Text(prettyBytes(section.folded.reduce(0) { $0 + $1.bytes })).font(.system(size: 12, design: .monospaced)).foregroundStyle(OrbitTheme.secondary)
                    }.padding(.vertical, 8)
                }.overlay(alignment: .top) { Divider().opacity(0.4) }
            }
            if section.tier == .decide, query.isEmpty, aiBytes != nil { aiRow }
        }.orbitCard(padding: 18).disabled(state.working)
    }

    private func row(_ row: CleanupRow) -> some View {
        HStack(spacing: 12) {
            CleanupGroupToggle(ids: row.ids, selection: $state.selection, title: "选择 " + row.advice.title)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.advice.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(row.advice.detail).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).lineLimit(1)
            }.help(shortPath(row.location))
            Spacer(minLength: 12)
            Text(prettyBytes(row.bytes)).font(.system(size: 12, design: .monospaced)).foregroundStyle(OrbitTheme.secondary)
            Button { reveal(row.location) } label: { Image(systemName: "arrow.up.forward").padding(6) }.buttonStyle(.plain).accessibilityLabel("在 Finder 中显示").help(shortPath(row.location))
        }.padding(.vertical, 8).overlay(alignment: .top) { Divider().opacity(0.4) }.fileContextMenu(row.location)
    }

    private var aiRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").foregroundStyle(OrbitTheme.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text("AI 工具的缓存和旧版本").font(.system(size: 13, weight: .medium))
                Text("对话、记忆和技能不会动，在 AI 清理里逐项挑选").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
            }
            Spacer(minLength: 12)
            if let bytes = aiBytes, bytes > 0 { Text("占用 " + prettyBytes(bytes)).font(.system(size: 12, design: .monospaced)).foregroundStyle(OrbitTheme.secondary) }
            Button("去审阅") { state.showAI = true }.buttonStyle(QuietButton())
        }.padding(.vertical, 8).overlay(alignment: .top) { Divider().opacity(0.4) }
    }

    @ViewBuilder private func holdNotes(_ index: CleanupResultsIndex) -> some View {
        if !index.runningApps.isEmpty {
            let names = index.runningApps.prefix(4).joined(separator: "、") + (index.runningApps.count > 4 ? " 等 \(index.runningApps.count) 个 App" : "")
            note("pause.circle", names + " 正在运行，缓存约 " + (index.runningPartial ? "至少 " : "") + prettyBytes(index.runningBytes) + " 暂不清理。退出后重新扫描，可清理其中的旧缓存。") {
                Button("重新扫描") { state.scanCleanup() }.buttonStyle(QuietButton()).disabled(state.scanning || state.working)
            }
        }
        if index.recentBytes > 0 && !state.includeRecentCaches {
            note("clock", "最近生成的缓存约 " + (index.recentPartial ? "至少 " : "") + prettyBytes(index.recentBytes) + " 暂不清理，它们多半还会被用到。") {
                SettingsLink { Text("在设置中包含") }.buttonStyle(QuietButton())
            }
        }
    }

    private func note<Action: View>(_ icon: String, _ text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(OrbitTheme.secondary)
            Text(text).font(.system(size: 12)).foregroundStyle(OrbitTheme.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            action()
        }.padding(14).background(OrbitTheme.subtleSurface, in: RoundedRectangle(cornerRadius: 12))
    }
}
