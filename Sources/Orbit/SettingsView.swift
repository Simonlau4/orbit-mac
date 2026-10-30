import SwiftUI
import OrbitCore

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var updates: OrbitUpdateMonitor
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                Text("设置").font(.system(size: 23, weight: .semibold))
                VStack(alignment: .leading, spacing: 13) {
                    Text("清理范围").font(.headline)
                    ForEach(CleanupCategory.allCases, id: \.rawValue) { category in
                        Toggle(category.title, isOn: Binding(get: { state.cleanupCategories.contains(category) }, set: { if $0 { state.cleanupCategories.insert(category) } else { state.cleanupCategories.remove(category) } })).toggleStyle(.checkbox)
                    }
                    Toggle("包含近期生成的可重建缓存", isOn: $state.includeRecentCaches).toggleStyle(.switch).tint(OrbitTheme.blue)
                    Text("默认缓存保留 7 天、日志 14 天、构建产物和安装包 30 天。包含近期缓存时，应用之后可能需要重新下载或生成内容；运行中应用的缓存仍保留。更改范围后需重新扫描。").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("系统缓存、AI 工具和废纸篓始终一并统计，各自单独审阅。上方选项只改变普通候选。").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }.orbitCard().disabled(state.working)
                HStack {
                    Text("监测刷新")
                    Spacer()
                    Picker("刷新频率", selection: $state.sampleInterval) { Text("2 秒").tag(2); Text("5 秒").tag(5); Text("10 秒").tag(10) }.labelsHidden().frame(width: 130)
                }
                HStack {
                    Text("菜单栏指标")
                    Spacer()
                    Picker("菜单栏指标", selection: $state.menuMetric) { ForEach(["CPU", "内存", "网络", "磁盘"], id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 130)
                }
                HStack {
                    Text("Orbit " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                    Spacer()
                    if updates.isChecking { ProgressView().controlSize(.mini) }
                    Button("检查更新") { Task { await updates.check() } }.disabled(updates.isChecking).font(.system(size: 11))
                    Button("纹理来源") { if let url = Bundle.module.url(forResource: "CREDITS", withExtension: "md", subdirectory: "Assets") { reveal(url) } }.buttonStyle(.link).font(.system(size: 11)).foregroundStyle(OrbitTheme.blue)
                }
                if !updates.message.isEmpty {
                    HStack {
                        Text(updates.message).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                        if let release = updates.availableRelease { Link("查看新版", destination: release.url).font(.system(size: 11)) }
                    }
                }
            }.padding(28)
        }.frame(minWidth: 470, idealWidth: 500, maxWidth: .infinity, minHeight: 500, idealHeight: 560, maxHeight: .infinity).featureSheet()
    }
}
