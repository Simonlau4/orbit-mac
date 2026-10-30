import SwiftUI
import AppKit
import OrbitCore

struct StatusView: View {
    @EnvironmentObject var monitoring: LiveMonitoring
    @State private var sortByMemory = false
    private var processes: [ProcessSample] {
        let values = monitoring.snapshot?.processes ?? []
        return sortByMemory ? values.sorted { $0.memoryBytes > $1.memoryBytes } : values.sorted { $0.cpuPercent > $1.cpuPercent }
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    PageHeading(eyebrow: "", title: "系统状态", subtitle: "每 \(monitoring.sampleInterval) 秒更新 · " + (monitoring.snapshot?.thermalState ?? "正在采样"))
                    Text(monitoring.snapshot?.sampledAt.formatted(date: .omitted, time: .standard) ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(OrbitTheme.secondary)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    MetricChart(title: "CPU", value: monitoring.snapshot.map { String(format: "%.1f%%", $0.cpuUsage) } ?? "—", detail: "\(monitoring.snapshot?.cpuCount ?? 0) 个逻辑核心", color: OrbitTheme.blue, values: monitoring.samples.map(\.cpuUsage))
                    MetricChart(title: "内存", value: monitoring.snapshot.map { prettyBytes($0.memoryUsed) } ?? "—", detail: monitoring.snapshot.map { "总计 " + prettyBytes($0.memoryTotal) + " · 交换 " + prettyBytes($0.swapUsed) } ?? "", color: OrbitTheme.mint, values: monitoring.samples.map { Double($0.memoryUsed) / Double(max($0.memoryTotal, 1)) * 100 })
                    MetricChart(title: "磁盘可用", value: monitoring.snapshot.map { prettyBytes($0.diskAvailable) } ?? "—", detail: monitoring.snapshot.map { "总计 " + prettyBytes($0.diskTotal) } ?? "", color: OrbitTheme.amber, values: monitoring.samples.map { Double($0.diskAvailable) / Double(max($0.diskTotal, 1)) * 100 })
                    MetricChart(title: "网络下载", value: monitoring.snapshot.map { prettyBytes(Int64($0.networkReceivedPerSecond)) + "/s" } ?? "—", detail: monitoring.snapshot.map { "上传 " + prettyBytes(Int64($0.networkSentPerSecond)) + "/s · " + ($0.primaryInterface ?? "物理接口") } ?? "", color: OrbitTheme.blue, values: monitoring.samples.map(\.networkReceivedPerSecond), ceiling: 1)
                }
                HStack(spacing: 14) {
                    infoCard("磁盘读写", value: diskIO, detail: "物理磁盘采样")
                    infoCard("电池", value: batteryValue, detail: batteryDetail)
                    infoCard("系统负载", value: loadValue, detail: "1 / 5 / 15 分钟")
                }
                ThermalControlCard()
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("资源占用").font(.system(size: OrbitTheme.cardHeadingSize, weight: .semibold))
                        Spacer()
                        Picker("进程排序", selection: $sortByMemory) { Text("CPU").tag(false); Text("内存").tag(true) }.pickerStyle(.segmented).frame(width: 130)
                    }
                    HStack { Text("进程"); Spacer(); Text("CPU").frame(width: 85, alignment: .trailing); Text("内存").frame(width: 95, alignment: .trailing) }.font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                    ForEach(Array(processes.prefix(12))) { process in
                        HStack {
                            Text(process.name).font(.system(size: 12)).lineLimit(1)
                            Text("\(process.pid)").font(.system(size: 11, design: .monospaced)).foregroundStyle(OrbitTheme.secondary)
                            Spacer()
                            Text(String(format: "%.1f%%", process.cpuPercent)).frame(width: 85, alignment: .trailing)
                            Text(prettyBytes(process.memoryBytes)).frame(width: 95, alignment: .trailing)
                        }.font(.system(size: 11, design: .monospaced)).accessibilityElement(children: .combine)
                        Divider().overlay(OrbitTheme.border)
                    }
                    Text("进程约每 \(monitoring.sampleInterval * 3) 秒更新，单核 CPU 可以超过 100%。").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                }.orbitCard()
                HStack {
                    if let ip = monitoring.snapshot?.localIPv4Address { Text("本机 IP " + ip) }
                    Spacer()
                    Text("CPU 温度：" + (monitoring.snapshot?.temperatureCelsius.map { String(format: "%.1f°C", $0) } ?? "当前设备不可用"))
                        .help(monitoring.snapshot?.temperatureUnavailableReason ?? "")
                    Spacer()
                    Text("系统热状态：" + (monitoring.snapshot?.thermalState ?? "—"))
                }.font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                if let warnings = monitoring.snapshot?.warnings, !warnings.isEmpty { Text(warnings.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(OrbitTheme.amber) }
            }.padding(.horizontal, 40).padding(.vertical, 14)
        }
    }
    private var diskIO: String {
        guard let s = monitoring.snapshot, let read = s.diskReadBytesPerSecond, let write = s.diskWriteBytesPerSecond else { return "正在采样" }
        return "读 " + prettyBytes(Int64(read)) + "/s · 写 " + prettyBytes(Int64(write)) + "/s"
    }
    private var batteryValue: String {
        guard let battery = monitoring.snapshot?.battery else { return "无内置电池" }
        return (battery.chargePercent.map { String(format: "%.0f%%", $0) } ?? "—") + (battery.isCharging == true ? " · 充电中" : battery.externalPowerConnected == true ? " · 已接电" : " · 电池供电")
    }
    private var batteryDetail: String {
        guard let battery = monitoring.snapshot?.battery else { return "" }
        return (battery.cycleCount.map { "循环 \($0) 次" } ?? "") + (battery.healthPercent.map { String(format: " · 估算健康度 %.0f%%", $0) } ?? "")
    }
    private var loadValue: String { monitoring.snapshot?.loadAverages?.map { String(format: "%.2f", $0) }.joined(separator: " / ") ?? "—" }
    private func infoCard(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title).font(.system(size: OrbitTheme.cardHeadingSize, weight: .semibold)).foregroundStyle(OrbitTheme.secondary)
            Text(value).font(.system(size: 12, weight: .medium)).lineLimit(2)
            Text(detail).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, minHeight: 72, alignment: .leading).orbitCard().accessibilityElement(children: .combine)
    }
}

struct MetricChart: View {
    let title: String
    let value: String
    let detail: String
    let color: Color
    let values: [Double]
    var ceiling: Double = 100
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(title).font(.system(size: OrbitTheme.cardHeadingSize, weight: .semibold)).foregroundStyle(OrbitTheme.secondary); Spacer(); Dot(color: color) }
            HStack { Text(value).font(.system(size: 27, weight: .medium, design: .rounded)).monospacedDigit(); Spacer(); Sparkline(values: values, color: color, ceiling: ceiling).frame(width: 140, height: 44) }
            Text(detail).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
        }.orbitCard().accessibilityElement(children: .combine)
    }
}

struct OptimizeView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        ScrollView {
            VStack(spacing: 23) {
                PageHeading(eyebrow: "", title: "优化", subtitle: "按需执行维护与常用工具")
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 17) {
                        Label("保持常亮", systemImage: "sun.max").font(.system(size: OrbitTheme.cardHeadingSize, weight: .semibold))
                        Text(state.keepingAwake ? state.awakeUntil.map { "将在 " + $0.formatted(date: .omitted, time: .shortened) + " 自动结束" } ?? "持续到关闭开关或退出 Orbit" : "演示或长任务时暂停自动熄屏")
                            .font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                        HStack {
                            Picker("持续时间", selection: $state.awakeMinutes) { Text("15 分钟").tag(15); Text("30 分钟").tag(30); Text("1 小时").tag(60); Text("2 小时").tag(120); Text("持续开启").tag(0) }.labelsHidden().disabled(state.keepingAwake)
                            Toggle("常亮", isOn: Binding(get: { state.keepingAwake }, set: { _ in state.toggleAwake() })).labelsHidden().toggleStyle(.switch).tint(OrbitTheme.blue).accessibilityLabel("保持屏幕常亮")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).orbitCard()
                    VStack(alignment: .leading, spacing: 17) {
                        Label("清洁屏幕", systemImage: "hand.raised").font(.system(size: OrbitTheme.cardHeadingSize, weight: .semibold))
                        Text("显示黑色屏幕并暂时忽略按键和点击。按 Esc 退出，30 秒后自动结束。").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                        Button("开启清洁屏幕") { state.confirmCleanScreen = true }.buttonStyle(QuietButton())
                    }.frame(maxWidth: .infinity, alignment: .leading).orbitCard()
                }
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Text("系统维护").font(.system(size: OrbitTheme.cardHeadingSize, weight: .semibold))
                        Spacer()
                        if state.maintenanceChecking { ProgressView().controlSize(.mini) }
                        if state.maintenanceRunning { Button("查看维护进度") { state.showMaintenanceReview = true }.buttonStyle(QuietButton()) }
                        Button("恢复记录") { state.openMaintenanceHistory() }.buttonStyle(QuietButton())
                    }
                    ForEach(MaintenanceTask.allCases) { task in
                        HStack(spacing: 16) {
                            Image(systemName: task.requiresAdmin ? "lock.shield" : "sparkles").foregroundStyle(OrbitTheme.blue).frame(width: 27)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(task.title).font(.system(size: 13, weight: .medium))
                                Text(task.detail).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                                if let result = state.maintenanceResults[task.rawValue] { Text(result.message).font(.system(size: 11)).foregroundStyle(result.status == .success ? OrbitTheme.mint : OrbitTheme.amber) }
                            }
                            Spacer()
                            Button("检查并预览") { state.previewMaintenance(task) }.buttonStyle(QuietButton()).disabled(state.working || state.maintenanceChecking)
                        }.padding(.vertical, 9)
                    }
                    if state.maintenanceRunning { Button("取消当前维护") { state.cancelMaintenance() }.buttonStyle(.link).foregroundStyle(OrbitTheme.secondary) }
                }.orbitCard()
                HStack {
                    Button("打开活动监视器") { if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") { NSWorkspace.shared.open(url) } }.buttonStyle(QuietButton())
                    Button("管理登录项") { state.tab = .software; state.softwareSection = .startup; state.refreshStartup() }.buttonStyle(QuietButton())
                    Spacer()
                    MonitoringUptime()
                }
            }.padding(.horizontal, 40).padding(.vertical, 14)
        }
        .confirmationDialog("开启屏幕清洁模式？", isPresented: $state.confirmCleanScreen, titleVisibility: .visible) {
            Button("开启 30 秒") { state.cleanScreen.show() }; Button("取消", role: .cancel) {}
        } message: { Text("将覆盖所有屏幕。按 Esc 可随时退出。") }

    }
}

struct AnalyzeView: View {
    @EnvironmentObject var state: AppState
    private var entries: [DiskEntry] {
        guard let report = state.diskReport else { return [] }
        let values = state.diskShowsLargeFiles ? report.largeFiles : report.entries
        return state.diskSortByName ? values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : values.sorted { $0.bytes > $1.bytes }
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 12) {
                HStack {
                    Button { state.diskBack() } label: { Image(systemName: "chevron.left").padding(8) }.buttonStyle(QuietButton()).disabled(state.diskScanning || state.diskRoot.path == "/").accessibilityLabel("上一级文件夹").help("上一级文件夹")
                    PageHeading(eyebrow: "", title: "磁盘分析", subtitle: shortPath(state.diskRoot)).help(state.diskRoot.path)
                    Button("选择文件夹") { state.chooseDiskRoot() }.buttonStyle(QuietButton()).disabled(state.diskScanning)
                    Button(state.diskScanning ? "停止" : "重新扫描") { if state.diskScanning { state.cancelDiskScan() } else { state.scanDisk() } }.buttonStyle(PrimaryButton())
                }
                HStack {
                    Picker("列表内容", selection: $state.diskShowsLargeFiles) { Text("当前目录").tag(false); Text("大文件 ≥10 MB").tag(true) }.pickerStyle(.segmented).frame(width: 240)
                    Spacer()
                    Toggle("隐藏项目", isOn: $state.diskShowHidden).toggleStyle(.checkbox).disabled(state.diskScanning)
                    Picker("排序", selection: $state.diskSortByName) { Text("大小").tag(false); Text("名称").tag(true) }.labelsHidden().frame(width: 95)
                }.font(.system(size: 11))
                if state.diskScanning {
                    Spacer(); ProgressView("正在分析当前目录…"); Text("遇到权限或时间限制时会标记部分覆盖。").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary); Spacer()
                } else if let report = state.diskReport {
                    HStack {
                        Text(prettyBytes(report.totalBytes)).font(.system(size: 22, weight: .medium, design: .rounded))
                        Text("· \(report.scannedFiles) 个文件" + (report.isPartial ? " · 部分扫描" : "")).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                        Spacer()
                        Text("最大 30 项 · 点击文件夹继续查看").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                    }
                    if !report.warnings.isEmpty { Text(report.warnings.prefix(2).joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(OrbitTheme.amber).frame(maxWidth: .infinity, alignment: .leading) }
                    DiskTreemap(entries: Array(report.entries.filter { $0.bytes > 0 }.prefix(30)), onSelect: state.enterDisk).frame(height: min(205, max(110, geometry.size.height - 415)))
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                HStack(spacing: 13) {
                                    Button { state.enterDisk(entry) } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc").foregroundStyle(OrbitTheme.blue)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(entry.name).font(.system(size: 12)).lineLimit(1).help(entry.url.path)
                                                if entry.isDirectory { Text("\(entry.fileCount) 个文件").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary) }
                                            }
                                            Spacer()
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    Text(prettyBytes(entry.bytes)).font(.system(size: 11, design: .monospaced)).foregroundStyle(OrbitTheme.secondary)
                                    Button { reveal(entry.url) } label: { Image(systemName: "arrow.up.forward").padding(7) }.buttonStyle(.plain).accessibilityLabel("在 Finder 中显示").help("在 Finder 中显示")
                                    Button { state.askTrash(entry.url, root: report.root) } label: { Image(systemName: "trash").padding(7) }.buttonStyle(.plain).disabled(state.working).accessibilityLabel("将 \(entry.name) 移入废纸篓").help("将 \(entry.name) 移入废纸篓")
                                }.padding(.vertical, 8).fileContextMenu(entry.url)
                                Divider().overlay(OrbitTheme.border)
                            }
                        }
                        if entries.isEmpty { Text("当前范围没有符合条件的项目").foregroundStyle(OrbitTheme.secondary).padding(30) }
                    }.frame(minHeight: 216).layoutPriority(1)
                    Text("显示逻辑文件大小；APFS 共享数据、系统快照和不可读内容可能与磁盘占用不同。").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(); Image(systemName: "square.split.2x2").font(.system(size: 45, weight: .ultraLight)).foregroundStyle(OrbitTheme.blue)
                    Text("选择文件夹或点击扫描").font(.system(size: 19)); Spacer()
                }
            }
        }.padding(.horizontal, 40).padding(.vertical, 14)
            .onChange(of: state.diskShowHidden) { _, _ in state.scanDisk() }
    }
}
