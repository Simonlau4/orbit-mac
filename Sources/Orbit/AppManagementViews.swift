import SwiftUI
import AppKit
import OrbitCore

struct SoftwareView: View {
    @EnvironmentObject var state: AppState
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                PageHeading(eyebrow: "", title: "软件", subtitle: "\(state.apps.count) 个应用")
                Picker("软件页面", selection: $state.softwareSection) { ForEach(SoftwareSection.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 330)
            }
            if state.softwareSection == .apps || state.softwareSection == .updates {
                HStack {
                    TextField("搜索应用", text: $state.appSearch).textFieldStyle(.roundedBorder).focused($searchFocused)
                    Button("刷新") { state.loadApps() }.buttonStyle(QuietButton()).disabled(state.loadingApps)
                    if state.softwareSection == .updates {
                        Button(state.checkingUpdates ? "停止检查" : "检查更新") { if state.checkingUpdates { state.cancelUpdates() } else { state.checkUpdates() } }.buttonStyle(PrimaryButton())
                    }
                }
                if state.softwareSection == .updates {
                    HStack {
                        Text(state.updateActivity.isEmpty ? "官方更新源 · 验签安装 · 保留旧版。自动更新按应用单独开启，每 6 小时检查，等待应用退出后安装。" : state.updateActivity)
                            .font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                        Spacer()
                        if state.preparingUpdate { ProgressView().controlSize(.small) }
                        if state.installingUpdate { Button("查看安装进度") { state.showUpdateReview = true }.buttonStyle(QuietButton()) }
                        Button("安装与恢复记录") { state.showUpdateHistory = true; Task { await state.refreshUpdateHistory() } }.buttonStyle(QuietButton())
                    }
                }
                let apps = state.filteredApps
                if state.loadingApps { HStack { ProgressView().controlSize(.small); Text("正在读取应用…").foregroundStyle(OrbitTheme.secondary) } }
                ScrollView {
                    LazyVStack(spacing: 8) { ForEach(apps) { app in applicationRow(app) } }
                    if !state.loadingApps && apps.isEmpty { Text("没有匹配的应用").foregroundStyle(OrbitTheme.secondary).padding(40) }
                }
                if !state.appWarnings.isEmpty { Text(state.appWarnings.prefix(2).joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(OrbitTheme.amber) }
            } else if state.softwareSection == .startup { StartupView() }
            else { OrphansView() }
        }.padding(.horizontal, 40).padding(.vertical, 14)
            .background {
                Button("搜索应用") { searchFocused = true }.keyboardShortcut("f").hidden().accessibilityHidden(true)
                    .disabled(state.softwareSection != .apps && state.softwareSection != .updates)
            }
            .onChange(of: state.softwareSection) { _, section in if section == .startup { state.refreshStartup() } }
    }
    private func applicationRow(_ app: AppDescriptor) -> some View {
        HStack(spacing: 15) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().aspectRatio(contentMode: .fit).frame(width: 37, height: 37).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if state.runningIDs.contains(app.bundleID) { Text("运行中").font(.system(size: 11)).foregroundStyle(OrbitTheme.mint) }
                    if app.isSystem { Text("系统").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary) }
                }
                Text(app.version + " · " + shortPath(app.url)).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).lineLimit(1).truncationMode(.middle).help(app.url.path)
                if state.softwareSection == .updates {
                    if let update = state.appUpdates[app.id] { updateDescription(update) }
                    else { Text(app.appcastURL == nil ? "需在应用内或 App Store 检查" : "等待检查").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary) }
                }
            }.accessibilityElement(children: .combine)
            Spacer()
            if state.softwareSection == .updates {
                if app.appcastURL != nil && !app.isSystem && app.bundleID != Bundle.main.bundleIdentifier {
                    Toggle("自动", isOn: Binding(get: { state.automaticUpdateIDs.contains(app.id) }, set: { state.setAutomaticUpdate($0, for: app) }))
                        .toggleStyle(.checkbox).font(.system(size: 11)).help("退出应用后自动安装经过签名验证的更新，并保留旧版")
                }
                if let update = state.appUpdates[app.id], update.state == .updateAvailable {
                    Button("下载并验证") { state.prepareUpdate(app) }.buttonStyle(QuietButton()).disabled(state.preparingUpdate || state.working)
                }
            } else {
                Button { reveal(app.url) } label: { Image(systemName: "arrow.up.forward").padding(7) }.buttonStyle(.plain).accessibilityLabel("在 Finder 中显示").help("在 Finder 中显示")
                Button("卸载与残留") { state.reviewApp(app) }.buttonStyle(QuietButton()).disabled(state.working || app.isSystem || app.bundleID == Bundle.main.bundleIdentifier)
            }
        }.orbitCard()
    }
    private func updateDescription(_ result: AppUpdateResult) -> some View {
        Text(result.message).font(.system(size: 11)).foregroundStyle(result.state == .updateAvailable ? OrbitTheme.mint : result.state == .failed ? OrbitTheme.amber : OrbitTheme.secondary).lineLimit(2)
    }
}

struct AppReviewView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    private var selectedCount: Int { (state.reviewIncludesApp ? 1 : 0) + state.remnantSelection.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                PageHeading(eyebrow: "", title: state.appReview?.name ?? "应用", subtitle: "审阅应用与它的关联数据")
                Button("关闭") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
            }
            if let app = state.appReview {
                Toggle(isOn: $state.reviewIncludesApp) {
                    HStack { Text(app.name); Spacer(); Text(state.reviewSize.map { prettyBytes($0) } ?? "计算中…").foregroundStyle(OrbitTheme.secondary) }
                }.toggleStyle(.checkbox).orbitCard().fileContextMenu(app.url)
                if state.runningIDs.contains(app.bundleID) { Text("应用正在运行，退出后才可移除。").foregroundStyle(OrbitTheme.amber).font(.system(size: 12)) }
            }
            Text("关联数据默认保留，勾选后会与应用一起移入废纸篓。").font(.system(size: 12)).foregroundStyle(OrbitTheme.secondary)
            if state.reviewingApp { ProgressView("正在查找关联文件…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(state.remnantScan?.items ?? []) { item in
                            Toggle(isOn: Binding(get: { state.remnantSelection.contains(item.id) }, set: { if $0 { state.remnantSelection.insert(item.id) } else { state.remnantSelection.remove(item.id) } })) {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack { Text(item.url.lastPathComponent).lineLimit(1); Spacer(); Text(prettyBytes(item.bytes)).foregroundStyle(OrbitTheme.secondary) }
                                    Text(item.reason).font(.system(size: 11)).foregroundStyle(item.sharedRisk ? OrbitTheme.amber : OrbitTheme.blue)
                                    Text(shortPath(item.url)).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).lineLimit(1).truncationMode(.middle).help(item.url.path)
                                }
                            }.toggleStyle(.checkbox).orbitCard().fileContextMenu(item.url)
                        }
                    }
                    if state.remnantScan?.items.isEmpty == true { Text("没有发现可明确归属的关联数据").foregroundStyle(OrbitTheme.secondary).padding(30) }
                }
            }
            if let warnings = state.remnantScan?.warnings, !warnings.isEmpty { Text(warnings.prefix(2).joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(OrbitTheme.amber) }
            HStack {
                Text("已选 \(selectedCount) 项").foregroundStyle(OrbitTheme.secondary)
                Spacer()
                Button("移入废纸篓") { state.confirmUninstall = true }.buttonStyle(PrimaryButton())
                    .disabled(state.working || state.reviewingApp || selectedCount == 0 || state.runningIDs.contains(state.appReview?.bundleID ?? ""))
            }
        }.padding(28).frame(minWidth: 620, idealWidth: 690, maxWidth: .infinity, minHeight: 480, idealHeight: 560, maxHeight: .infinity).featureSheet()
            .confirmationDialog("将选中的应用和关联文件移入废纸篓？", isPresented: $state.confirmUninstall, titleVisibility: .visible) {
                Button("移入废纸篓 · \(selectedCount) 项", role: .destructive) { state.uninstallReviewed() }; Button("取消", role: .cancel) {}
            } message: { Text("未勾选的个人数据会保留。已处理的项目可在清理记录恢复。") }
            .alert(item: $state.notice) { item in Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("好"))) }
    }
}

struct StartupView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 15) {
            HStack {
                Text("个人启动代理可在这里停用和恢复；系统启动项仅供查看。").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                Spacer()
                Button("系统登录项") { if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) } }.buttonStyle(QuietButton())
                Button("刷新") { state.refreshStartup() }.buttonStyle(QuietButton()).disabled(state.startupScanning)
            }
            if state.startupScanning { HStack { ProgressView().controlSize(.small); Text("正在读取启动项…").foregroundStyle(OrbitTheme.secondary) } }
            let items = state.startupScan?.items ?? []
            let systemItems = items.filter { $0.scope != .userAgent }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items.filter { $0.scope == .userAgent }) { item in startupRow(item) }
                    if !systemItems.isEmpty {
                        DisclosureGroup("系统启动项（只读）") { ForEach(systemItems) { item in startupRow(item) } }.padding(.top, 12)
                    }
                    if !state.startupScanning && state.startupScan != nil && items.isEmpty { Text("没有可显示的启动项").foregroundStyle(OrbitTheme.secondary).padding(40) }
                }
            }
            if let warnings = state.startupScan?.warnings, !warnings.isEmpty { Text(warnings.prefix(3).joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(OrbitTheme.amber) }
            Text("“已启用”表示配置可随登录载入，不表示该进程此刻正在运行。").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear { if state.startupScan == nil { state.refreshStartup() } }
            .alert("更改启动项？", isPresented: Binding(get: { state.pendingStartup != nil }, set: { if !$0 { state.pendingStartup = nil } }), presenting: state.pendingStartup) { item in
                Button(item.isEnabled ? "停用" : "启用") { state.pendingStartup = nil; state.changeStartup(item) }
                Button("取消", role: .cancel) {}
            } message: { item in Text(item.label + (item.isEnabled ? "\n将卸载此启动任务并保留配置，可在此恢复。" : "\n将重新载入此配置，相关程序可能开始运行。")) }
    }
    private func startupRow(_ item: StartupItem) -> some View {
        HStack(spacing: 14) {
            Image(systemName: item.isEnabled ? "power.circle" : "pause.circle").foregroundStyle(item.isEnabled ? OrbitTheme.mint : OrbitTheme.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) { Text(item.label).font(.system(size: 12, weight: .medium)).lineLimit(1); Text(item.scope.title + " · " + item.program).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).lineLimit(1).truncationMode(.middle) }
            Spacer()
            Text(item.isEnabled ? "已启用" : "已停用").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
            Button { reveal(item.url) } label: { Image(systemName: "arrow.up.forward").padding(7) }.buttonStyle(.plain).accessibilityLabel("显示启动配置 \(item.label)").help("显示启动配置 \(item.label)")
            if item.canToggle { Button(item.isEnabled ? "停用" : "启用") { state.pendingStartup = item }.buttonStyle(QuietButton()).disabled(state.working) }
        }.orbitCard()
    }
}

struct OrphansView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 17) {
            HStack {
                Text("这里列出可能属于已移除软件的文件。辅助程序或其他用户仍可能使用，需自行确认。").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                Spacer()
                Button("查找残留") { state.scanOrphans() }.buttonStyle(QuietButton()).disabled(state.orphanScanning)
            }
            if state.orphanScanning { Spacer(); ProgressView("正在查找可能的残留…"); Spacer() }
            else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(state.orphanScan?.items ?? []) { item in
                            Toggle(isOn: Binding(get: { state.orphanSelection.contains(item.id) }, set: { if $0 { state.orphanSelection.insert(item.id) } else { state.orphanSelection.remove(item.id) } })) {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack { Text(item.bundleID).font(.system(size: 12, weight: .medium)); Spacer(); Text(prettyBytes(item.bytes)).foregroundStyle(OrbitTheme.secondary) }
                                    Text(shortPath(item.url)).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).lineLimit(1).truncationMode(.middle).help(item.url.path)
                                    Text(item.reason).font(.system(size: 11)).foregroundStyle(OrbitTheme.amber)
                                }
                            }.toggleStyle(.checkbox).orbitCard().fileContextMenu(item.url).disabled(state.working)
                        }
                    }
                    if state.orphanScan == nil { Text("点击“查找残留”开始检查").foregroundStyle(OrbitTheme.secondary).padding(60) }
                    else if state.orphanScan?.items.isEmpty == true { Text("没有发现可列出的候选残留").foregroundStyle(OrbitTheme.secondary).padding(60) }
                }
            }
            if let warnings = state.orphanScan?.warnings, !warnings.isEmpty { Text(warnings.prefix(2).joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(OrbitTheme.amber) }
            HStack {
                Text("已选 \(state.orphanSelection.count) 项").foregroundStyle(OrbitTheme.secondary)
                Spacer()
                Button("移入废纸篓") { state.confirmOrphans = true }.buttonStyle(PrimaryButton()).disabled(state.working || state.orphanSelection.isEmpty)
            }
        }.confirmationDialog("移除所选的可能残留？", isPresented: $state.confirmOrphans, titleVisibility: .visible) {
            Button("移入废纸篓", role: .destructive) { state.cleanOrphans() }; Button("取消", role: .cancel) {}
        } message: { Text("请先核对文件用途。已移入废纸篓的项目可在清理记录中恢复。") }
    }
}
