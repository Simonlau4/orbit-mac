import SwiftUI
import AppKit
import OrbitCore

struct OrdinaryCleanupResultsView: View {
    @EnvironmentObject var state: AppState
    let onBack: () -> Void
    @State private var category: CleanupCategory?
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @FocusState private var searchFocused: Bool
    @State private var filtered = OrdinarySearchResults()
    @State private var searched = false
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                PageHeading(eyebrow: "", title: "可清理候选 " + prettyBytes(state.cleanupIndex.totalBytes), subtitle: "\(state.scan?.items.count ?? 0) 个候选文件 · 已选大小见下方，移入废纸篓后仍占空间")
                Button("统一结果") { onBack() }.buttonStyle(QuietButton())
                Button("AI 工具清理") { state.showAI = true }.buttonStyle(QuietButton())
                SettingsLink { Text("扫描选项") }.buttonStyle(QuietButton()).disabled(state.working)
                Button("重新扫描") { state.scanCleanup() }.buttonStyle(QuietButton()).disabled(state.scanning || state.working)
                Button { state.showResults = false } label: { Image(systemName: "xmark").padding(8) }.buttonStyle(.plain).accessibilityLabel("返回清理首页").help("返回清理首页")
            }
            HStack(spacing: 8) {
                filterButton("全部", nil)
                ForEach(CleanupCategory.allCases, id: \.rawValue) { filterButton($0.title, $0) }
                Spacer(minLength: 4)
                TextField("搜索", text: $query).textFieldStyle(.roundedBorder).frame(width: 130).focused($searchFocused).accessibilityLabel("搜索清理项目")
            }
            if let scan = state.scan { scanExplanation(scan) }
            HStack {
                Button("选择当前分组") { state.selection.formUnion(filtered.selectableIDs) }.buttonStyle(.link).foregroundStyle(OrbitTheme.blue)
                Button("取消全选") { state.selection = [] }.buttonStyle(.link).foregroundStyle(OrbitTheme.secondary)
                Spacer()
                Text("\(filtered.groups.count) 组 · 已检查 \(state.scan?.scannedFiles ?? 0) 个文件").foregroundStyle(OrbitTheme.secondary)
            }.font(.system(size: 11)).disabled(state.working)
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(filtered.groups) { group in
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(group.id) }, set: { if $0 { expanded.insert(group.id) } else { expanded.remove(group.id) } })) {
                            LazyVStack(spacing: 0) {
                                ForEach(filtered.itemsByGroup[group.id] ?? []) { item in
                                    HStack(spacing: 12) {
                                        Toggle(isOn: Binding(get: { state.selection.contains(item.id) }, set: { if $0 { state.selection.insert(item.id) } else { state.selection.remove(item.id) } })) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(item.name).lineLimit(1)
                                                Text(shortPath(item.url)).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).lineLimit(1).truncationMode(.middle).help(item.url.path)
                                            }
                                        }.toggleStyle(.checkbox)
                                        Spacer()
                                        Text(prettyBytes(item.bytes)).font(.system(size: 11, design: .monospaced)).foregroundStyle(OrbitTheme.secondary)
                                        Button { reveal(item.url) } label: { Image(systemName: "arrow.up.forward").padding(6) }.buttonStyle(.plain).accessibilityLabel("在 Finder 中显示").help("在 Finder 中显示")
                                    }.font(.system(size: 12)).padding(.vertical, 8).fileContextMenu(item.url)
                                }
                                if group.items.count > 300 && query.isEmpty {
                                    Text("显示前 300 个文件，组选择会包含此组全部 \(group.items.count) 个文件。可搜索具体路径。").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).padding(8)
                                }
                            }.padding(.leading, 12)
                        } label: {
                            HStack(spacing: 12) {
                                CleanupGroupToggle(ids: state.cleanupIndex.groupItemIDs[group.id] ?? [], selection: $state.selection, title: "选择 \(group.name) 的全部 \(group.items.count) 个文件")
                                Image(systemName: "folder.fill").foregroundStyle(OrbitTheme.blue)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(group.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text("\(group.category.title) · \(group.items.count) 个文件").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                                }
                                Spacer()
                                Text(prettyBytes(group.bytes)).font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                            }.padding(.vertical, 4)
                        }.orbitCard().disabled(state.working)
                    }
                }
                if searched && filtered.groups.isEmpty { Text("当前筛选没有可清理候选").foregroundStyle(OrbitTheme.secondary).padding(40) }
            }
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("已选 \(state.selection.count) 项 · \(prettyBytes(state.selectedBytes))").font(.system(size: 14, weight: .medium))
                    Text("移入废纸篓后可恢复；清空废纸篓后才释放空间。").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                }
                Spacer()
                Button("移入废纸篓") { state.confirmCleaning = true }.buttonStyle(PrimaryButton()).disabled(state.selection.isEmpty || state.working || state.scanning)
            }
        }.padding(.horizontal, 40).padding(.vertical, 14)
            .background { Button("搜索清理项目") { searchFocused = true }.keyboardShortcut("f").hidden().accessibilityHidden(true) }
            .task(id: CleanupSearchKey(scanID: state.cleanupResultsID, query: query, category: category)) {
                let index = state.cleanupIndex, query = query, category = category
                if !query.isEmpty { do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return } }
                let result = await Task.detached(priority: .userInitiated) { index.search(query, category: category) }.value
                guard !Task.isCancelled else { return }
                filtered = result; searched = true
                if !query.isEmpty { expanded.formUnion(result.groups.map(\.id)) }
            }
    }
    private func scanExplanation(_ scan: CleanupScan) -> some View {
        let index = state.cleanupIndex
        let permissionCount = index.permissionCount, unreadCount = index.unreadCount, limited = index.limited
        let runningEntries = index.runningEntries, runningBytes = index.runningBytes, runningPartial = index.runningPartial
        let recentBytes = index.recentBytes, recentPartial = index.recentPartial
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已统计文件大小 " + prettyBytes(scan.scannedBytes))
                if !runningEntries.isEmpty { Text(runningPartial && runningBytes == 0 ? "运行中缓存已保留 · 占用未统计" : "运行中保留 " + (runningPartial ? "至少 " : "") + prettyBytes(runningBytes)) }
                if recentBytes > 0 { Text("近期文件保留 " + (recentPartial ? "至少 " : "") + prettyBytes(recentBytes)) }
                Spacer()
            }.font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 9) {
                    Text("普通清理统计个人缓存、日志、构建缓存和旧安装包。AI 数据单独审阅；系统保护目录、聊天媒体和废纸篓不计入此候选合计。这里显示文件大小，不等于立即释放的磁盘空间。")
                        .foregroundStyle(OrbitTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(scan.issues.enumerated()), id: \.offset) { _, issue in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(issue.kind == .permission ? "macOS 拒绝读取此路径" : issue.message).foregroundStyle(OrbitTheme.amber)
                                    if !issue.path.isEmpty { Text(shortPath(URL(fileURLWithPath: issue.path))).textSelection(.enabled).foregroundStyle(OrbitTheme.secondary) }
                                }
                            }
                            if scan.issues.isEmpty {
                                ForEach(scan.warnings, id: \.self) { Text($0).foregroundStyle(OrbitTheme.amber) }
                            }
                            ForEach(Array(index.retained.enumerated()), id: \.offset) { _, entry in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(retainedTitle(entry.reason))
                                        Text(shortPath(entry.rootURL)).foregroundStyle(OrbitTheme.secondary).textSelection(.enabled)
                                    }
                                    Spacer()
                                    Text(entry.isPartial && entry.bytes == 0 ? "占用未统计" : "\(entry.count) 文件 · " + (entry.isPartial ? "至少 " : "") + prettyBytes(entry.bytes)).monospacedDigit()
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 125)
                    if permissionCount > 0 {
                        HStack {
                            Text("当前 Orbit 进程的读取受到限制。可检查系统访问权限后重扫；部分系统目录仍可能受保护。")
                                .foregroundStyle(OrbitTheme.secondary)
                            Spacer()
                            Button("检查读取权限") { state.openReadPermissions() }.buttonStyle(QuietButton())
                        }
                    }
                }.font(.system(size: 11)).padding(.top, 7)
            } label: {
                Text(limited ? "部分范围未完整统计" + (unreadCount > 0 ? " · \(unreadCount) 项读取未完成" : "") + " · 查看原因" : unreadCount > 0 ? "\(unreadCount) 处未计入 · 查看扫描范围与保留原因" : "扫描范围与保留原因")
                    .font(.system(size: 11)).foregroundStyle(limited || unreadCount > 0 ? OrbitTheme.amber : OrbitTheme.secondary)
            }
        }
    }
    private func retainedTitle(_ reason: CleanupRetainedReason) -> String {
        switch reason {
        case .runningApplication: return "运行中应用的缓存，退出后可重新扫描"
        case .recent: return "未达到当前保留天数"
        case .hardLink: return "硬链接文件，保留以保护共享数据"
        case .unknownOwner: return "共享缓存归属未核实，保留"
        case .protectedData: return "数据库或离线内容，仅统计占用并保留"
        }
    }
    private func filterButton(_ title: String, _ value: CleanupCategory?) -> some View {
        Button { category = value } label: { Text(title).font(.system(size: 11)).padding(.horizontal, 9).padding(.vertical, 8).orbitSelection(category == value) }.buttonStyle(.plain).accessibilityAddTraits(category == value ? .isSelected : [])
    }
}
func shortPath(_ url: URL) -> String { url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }
