import SwiftUI
import AppKit
import OrbitCore

struct ThermalControlCard: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitoring: LiveMonitoring
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("温度与风扇", systemImage: "fan").font(.system(size: OrbitTheme.cardHeadingSize, weight: .semibold))
                Spacer()
                Text(monitoring.thermalSnapshot?.cpuTemperatureCelsius.map { String(format: "CPU %.1f°C", $0) } ?? "CPU 温度不可用")
                    .font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).fixedSize()
                Picker("风扇模式", selection: Binding(get: { state.fanMode }, set: { mode in
                    if mode == .automatic && state.fanControl.isRunning { state.changeFan(mode) } else { state.pendingFanMode = mode }
                })) { ForEach(FanCoolingMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("风扇模式").frame(width: 195).disabled(monitoring.thermalSnapshot?.fans.isEmpty != false)
            }
            HStack(spacing: 30) {
                ForEach(monitoring.thermalSnapshot?.fans ?? []) { fan in
                    HStack(spacing: 10) {
                        Image(systemName: "fanblades").foregroundStyle(OrbitTheme.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("风扇 \(fan.id + 1) · \(Int(fan.actualRPM)) RPM").monospacedDigit()
                            Text("\(Int(fan.minimumRPM))–\(Int(fan.maximumRPM)) · " + (fan.mode == .manual ? "手动" : "系统调节")).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                        }
                    }.font(.system(size: 12))
                }
                Spacer()
                Text(state.fanMessage).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).lineLimit(2).frame(maxWidth: 270, alignment: .trailing)
            }
            DisclosureGroup("传感器 · " + (monitoring.thermalSnapshot?.temperatureSource ?? "未取得读数")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155))], alignment: .leading, spacing: 12) {
                    ForEach(monitoring.thermalSnapshot?.temperatureSensors ?? []) { sensor in
                        HStack { Text(sensor.name).foregroundStyle(OrbitTheme.secondary); Text(String(format: "%.1f°C", sensor.celsius)).monospacedDigit() }.font(.system(size: 11))
                    }
                }.padding(.top, 12)
            }.font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
        }.orbitCard()
            .alert("更改风扇模式？", isPresented: Binding(get: { state.pendingFanMode != nil }, set: { if !$0 { state.pendingFanMode = nil } }), presenting: state.pendingFanMode) { mode in
                Button("继续系统认证") { state.pendingFanMode = nil; state.changeFan(mode) }; Button("取消", role: .cancel) {}
            } message: { mode in
                Text(mode == .automatic ? "将风扇交回系统自动调节。" : "\(mode.title)会提高风扇转速。系统会请求管理员认证；降温结束、睡眠、退出或连接中断时交回系统，最长持续 30 分钟。")
            }
    }
}

struct AICleanupView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var confirm = false
    @State private var confirmationRequestID: UUID?
    @State private var recoveryID: UUID?
    @State private var packageRecoveryID: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                PageHeading(eyebrow: "", title: "AI 工具清理", subtitle: "缓存、旧版本、历史对话、worktree 与本地模型")
                Button("关闭") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker("对话保留", selection: $state.aiRetentionDays) { Text("保留全部对话").tag(0); Text("30 天前").tag(30); Text("90 天前").tag(90); Text("180 天前").tag(180) }.frame(width: 210).disabled(state.aiScanning || state.working)
                Spacer()
                Button(state.aiScanning ? "停止扫描" : "扫描 AI 数据") { if state.aiScanning { state.aiTask?.cancel() } else { state.scanAI() } }.buttonStyle(PrimaryButton()).disabled(state.working)
            }
            if state.aiScanning { ProgressView("正在核对工具活动与文件…").frame(maxWidth: .infinity, minHeight: 100) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    if let scan = state.aiScan {
                        Text("已核对 \(scan.scannedFiles) 个文件 · 候选 \(prettyBytes(state.aiIndex.totalBytes))" + (scan.isPartial ? " · 部分覆盖" : "")).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                        ForEach(AICleanupKind.allCases, id: \.rawValue) { kind in
                            let items = state.aiIndex.itemsByKind[kind] ?? []
                            if !items.isEmpty { DisclosureGroup("\(kind.title) · \(items.count) 项") { LazyVStack { ForEach(items) { item in aiRow(item) } } }.font(.system(size: 13)).padding(14).background(OrbitTheme.subtleSurface, in: RoundedRectangle(cornerRadius: 12)) }
                        }
                        if scan.items.isEmpty { Text("当前没有符合条件的候选。正在运行的工具需要退出后重新扫描。").foregroundStyle(OrbitTheme.secondary).padding(.vertical, 20) }
                        if !scan.retained.isEmpty {
                            DisclosureGroup("已保留 · \(scan.retained.count) 项") {
                                LazyVStack(alignment: .leading) { ForEach(scan.retained) { item in VStack(alignment: .leading, spacing: 4) { Text(item.tool.title + " · " + item.url.lastPathComponent); Text(item.reason).foregroundStyle(OrbitTheme.amber) }.font(.system(size: 11)).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine) } }
                            }.font(.system(size: 12)).foregroundStyle(OrbitTheme.secondary)
                        }
                        if !scan.warnings.isEmpty { Text(scan.warnings.joined(separator: "\n")).font(.system(size: 11)).foregroundStyle(OrbitTheme.amber) }
                    }
                    AIPackageList()
                    DisclosureGroup("数据恢复记录 · \(state.aiHistory.count)") {
                        ForEach(state.aiHistory) { record in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) { Text(record.createdAt.formatted() + " · \(record.items.count) 项"); Text(record.message).foregroundStyle(OrbitTheme.secondary).lineLimit(3) }.font(.system(size: 11)).accessibilityElement(children: .combine)
                                Spacer()
                                if record.state != .restored { Button("恢复") { recoveryID = record.id }.buttonStyle(QuietButton()).disabled(state.working) }
                                else { Text("已恢复").font(.system(size: 11)).foregroundStyle(OrbitTheme.mint) }
                            }.padding(.vertical, 9)
                        }
                        Button("在 Finder 查看恢复副本") { reveal(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Orbit/AIRecovery")) }.buttonStyle(.link).font(.system(size: 11)).foregroundStyle(OrbitTheme.blue)
                    }.font(.system(size: 12))
                    DisclosureGroup("程序包恢复记录 · \(state.aiPackageHistory.count)") {
                        ForEach(state.aiPackageHistory) { record in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) { Text(record.candidate.name + " · " + record.candidate.version); Text(record.message).foregroundStyle(OrbitTheme.secondary) }.font(.system(size: 11)).accessibilityElement(children: .combine)
                                Spacer()
                                if record.isRestored { Text("已恢复").font(.system(size: 11)).foregroundStyle(OrbitTheme.mint) }
                                else { Button("恢复程序") { packageRecoveryID = record.id }.buttonStyle(QuietButton()).disabled(state.working) }
                            }.padding(.vertical, 9)
                        }
                    }.font(.system(size: 12))
                }
            }
            Text("记忆、计划、技能与正在使用的数据会保留。恢复副本仍占磁盘空间；模型最近使用时间需人工核对。").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
            HStack {
                if state.working { ProgressView().controlSize(.small) }
                Text(state.working ? "正在处理，请稍候…" : "已选 \(state.aiSelection.count) 项 · \(prettyBytes(state.selectedAIBytes))").foregroundStyle(OrbitTheme.secondary)
                Spacer()
                Button("清理并保留恢复副本") { confirmationRequestID = state.aiScanRequestID; confirm = true }.buttonStyle(PrimaryButton()).disabled(state.working || !state.aiResultsAreCurrent || state.aiSelection.isEmpty)
            }.font(.system(size: 12))
        }.padding(28).frame(minWidth: 680, idealWidth: 790, maxWidth: .infinity, minHeight: 500, idealHeight: 560, maxHeight: .infinity).featureSheet()
            .task { await state.refreshAIHistory() }
            .onChange(of: state.aiScanRequestID) { _, _ in confirm = false; confirmationRequestID = nil }
            .confirmationDialog("处理已选的 AI 数据？", isPresented: $confirm, titleVisibility: .visible) {
                Button("确认处理 \(state.aiSelection.count) 项", role: .destructive) { if let id = confirmationRequestID { state.cleanAI(expectedRequestID: id) }; confirmationRequestID = nil }; Button("取消", role: .cancel) {}
            } message: { Text("历史对话将暂时无法在工具中继续，worktree 工作目录会移走。执行前再次核对活动状态与文件；可在本页恢复。") }
            .alert("恢复 AI 数据？", isPresented: Binding(get: { recoveryID != nil }, set: { if !$0 { recoveryID = nil } })) {
                Button("恢复") { if let id = recoveryID { state.restoreAI(id) }; recoveryID = nil }; Button("取消", role: .cancel) { recoveryID = nil }
            } message: { Text("先退出对应工具。原位置已有文件或数据库变化时会停止，保留恢复副本。") }
            .confirmationDialog("恢复此程序包？", isPresented: Binding(get: { packageRecoveryID != nil }, set: { if !$0 { packageRecoveryID = nil } }), titleVisibility: .visible) {
                Button("恢复程序包与链接") { if let id = packageRecoveryID { state.restoreAIPackage(id) }; packageRecoveryID = nil }; Button("取消", role: .cancel) { packageRecoveryID = nil }
            } message: { Text("请先退出对应工具。原位置有新程序或共享依赖发生变化时会保留现状。") }
            .sheet(item: $state.aiPackageReview) { candidate in AIPackageReviewView(candidate: candidate).environmentObject(state) }
            .featureNotice(enabled: state.aiPackageReview == nil)
    }
    private func aiRow(_ item: AICleanupCandidate) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: Binding(get: { state.aiSelection.contains(item.id) }, set: {
                guard !state.working, state.aiResultsAreCurrent else { return }
                if $0 { state.aiSelection.insert(item.id) } else { state.aiSelection.remove(item.id) }
            })) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(item.tool.title + " · " + item.title).lineLimit(1); Spacer(); Text(prettyBytes(item.bytes)).foregroundStyle(OrbitTheme.secondary) }
                    Text(item.detail).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                    Text(shortPath(item.url)).font(.system(size: 11, design: .monospaced)).foregroundStyle(OrbitTheme.secondary).lineLimit(1).truncationMode(.middle).help(item.url.path)
                }.font(.system(size: 11))
            }.toggleStyle(.checkbox).disabled(state.working || !state.aiResultsAreCurrent)
            if !item.relatedConversationIDs.isEmpty {
                HStack {
                    Text("需核对 \(max(0, (state.aiIndex.relatedIDs[item.id]?.count ?? 0) - 1)) 个关联会话").foregroundStyle(OrbitTheme.amber)
                    Button("选择关联会话") { state.selectRelatedAISessions(item) }.buttonStyle(.link).foregroundStyle(OrbitTheme.blue).disabled(state.working || !state.aiResultsAreCurrent)
                }.font(.system(size: 11)).padding(.leading, 20)
            }
        }.padding(.vertical, 9).fileContextMenu(item.url)
    }
}

struct MaintenanceReviewView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { PageHeading(eyebrow: "", title: state.maintenancePlan?.task.title ?? "维护预览", subtitle: state.maintenancePlan?.summary ?? ""); Button("关闭") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction) }
            if let plan = state.maintenancePlan {
                Text(plan.task.detail).font(.system(size: 12)).foregroundStyle(OrbitTheme.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 13) {
                        ForEach(plan.candidates) { item in
                            Toggle(isOn: Binding(get: { state.maintenanceSelection.contains(item.id) }, set: { if $0 { state.maintenanceSelection.insert(item.id) } else { state.maintenanceSelection.remove(item.id) } })) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.name).font(.system(size: 12, weight: .medium))
                                    Text(item.detail).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                                    Text(shortPath(item.url)).font(.system(size: 11, design: .monospaced)).foregroundStyle(OrbitTheme.secondary)
                                }
                            }.toggleStyle(.checkbox).orbitCard().disabled(state.working)
                        }
                        ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.system(size: 11)).foregroundStyle(OrbitTheme.amber) }
                        ForEach(Array(plan.findings.enumerated()), id: \.offset) { _, finding in Text(finding).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    if plan.task == .auditLoginItems {
                        Button("授权读取系统登录项") { state.authorizeLoginAudit() }.buttonStyle(QuietButton()).disabled(state.working)
                        Button("系统登录项设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }.buttonStyle(QuietButton())
                    }
                    if state.working { ProgressView().controlSize(.small) }
                    if state.maintenanceRunning { Button("取消当前维护") { state.cancelMaintenance() }.buttonStyle(QuietButton()) }
                    Spacer()
                    Button(plan.task.requiresAdmin ? "授权后执行" : "执行已审阅的变更") { confirm = true }.buttonStyle(PrimaryButton()).disabled(state.working || (!plan.canRunCommand && state.maintenanceSelection.isEmpty))
                }
            }
        }.padding(28).frame(minWidth: 660, idealWidth: 720, maxWidth: .infinity, minHeight: 480, idealHeight: 550, maxHeight: .infinity).featureSheet()
            .confirmationDialog("执行本次维护？", isPresented: $confirm, titleVisibility: .visible) {
                Button("执行") { state.executeMaintenancePlan() }; Button("取消", role: .cancel) {}
            } message: { Text(state.maintenancePlan?.task.detail ?? "") }
            .featureNotice()
    }
}

struct MaintenanceHistoryView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var restoreID: UUID?
    var body: some View {
        VStack(spacing: 20) {
            HStack { PageHeading(eyebrow: "", title: "维护恢复记录", subtitle: "恢复副本保存在本机；后续发生变化时保留现有文件"); Button("完成") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction) }
            ScrollView {
                ForEach(state.maintenanceHistory) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 6) { Text(record.task.title).font(.system(size: 13)); Text(record.createdAt.formatted() + " · \(record.entries.count) 项").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary); Text(record.message).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary) }.accessibilityElement(children: .combine)
                        Spacer()
                        if record.isRestored { Text("已恢复").font(.system(size: 11)).foregroundStyle(OrbitTheme.mint) }
                        else if !record.entries.isEmpty { Button("恢复") { restoreID = record.id }.buttonStyle(QuietButton()).disabled(state.working) }
                    }.orbitCard()
                }
                if state.maintenanceHistory.isEmpty { Text("还没有维护变更记录").foregroundStyle(OrbitTheme.secondary).padding(40) }
            }
        }.padding(28).frame(minWidth: 620, idealWidth: 720, maxWidth: .infinity, minHeight: 440, idealHeight: 530, maxHeight: .infinity).featureSheet()
            .alert("恢复此维护？", isPresented: Binding(get: { restoreID != nil }, set: { if !$0 { restoreID = nil } })) {
                Button("恢复") { if let id = restoreID { state.restoreMaintenance(id) }; restoreID = nil }; Button("取消", role: .cancel) { restoreID = nil }
            } message: { Text("请先退出对应应用。恢复不会覆盖之后改变的文件。") }.featureNotice()
    }
}

struct UpdateReviewView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { PageHeading(eyebrow: "", title: "安装更新", subtitle: state.preparedUpdate?.appName ?? ""); Button("关闭") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction) }
            if let plan = state.preparedUpdate {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(plan.oldVersion + " → " + plan.newVersion).font(.system(size: 26, weight: .medium, design: .rounded))
                        Text(plan.verification).font(.system(size: 12)).foregroundStyle(OrbitTheme.mint)
                        Text(shortPath(plan.appURL)).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                        Text(plan.requiresSystemInstaller ? "安装包已验证。继续后打开系统安装器，结果由系统报告。" : "请先保存工作。Orbit 会正常请求应用退出，保留旧版后安装，并重新打开原先运行的应用。退出被拒绝时会停止。").font(.system(size: 12)).foregroundStyle(OrbitTheme.secondary)
                        if plan.requiresAdministrator { Text("此应用目录需要管理员认证。系统组件会重新核对应用身份，保留旧版后安装。").font(.system(size: 11)).foregroundStyle(OrbitTheme.amber) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { if state.installingUpdate { ProgressView().controlSize(.small); Text("正在安装…").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary) }; Text(prettyBytes(plan.bytes)).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary); Spacer(); Button(plan.requiresSystemInstaller ? "打开系统安装器" : plan.requiresAdministrator ? "授权安装并保留旧版" : "安装并保留旧版") { confirm = true }.buttonStyle(PrimaryButton()).disabled(state.working) }
            } else { Spacer(); Text("安装处理已结束，可关闭此窗口。").foregroundStyle(OrbitTheme.secondary); Spacer() }
        }.padding(28).frame(minWidth: 600, idealWidth: 640, maxWidth: .infinity, minHeight: 400, idealHeight: 440, maxHeight: .infinity).featureSheet()
            .confirmationDialog("继续安装？", isPresented: $confirm, titleVisibility: .visible) { Button("安装") { state.installPreparedUpdate() }; Button("取消", role: .cancel) {} } message: { Text("保存应用中的工作后继续。不会强制结束正在运行的应用。") }.featureNotice()
    }
}

struct UpdateHistoryView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var restoreID: UUID?
    var body: some View {
        VStack(spacing: 20) {
            HStack { PageHeading(eyebrow: "", title: "安装与旧版恢复", subtitle: "只恢复身份与文件均未改变的备份"); Button("完成") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction) }
            ScrollView {
                ForEach(state.updateHistory) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) { Text(record.appName + " · " + record.oldVersion + " → " + record.newVersion).font(.system(size: 13)); Text(record.message).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary); Text(record.createdAt.formatted()).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary) }.accessibilityElement(children: .combine)
                        Spacer()
                        if record.state == .installed || (record.requiresAdministrator && record.state == .restoring) { Button(record.state == .restoring ? "重试恢复" : "恢复旧版") { restoreID = record.id }.buttonStyle(QuietButton()).disabled(state.working) }
                        else if record.state == .prepared || (record.requiresAdministrator && record.state == .installing) { Button("继续安装") { state.resumePreparedUpdate(record.id) }.buttonStyle(QuietButton()).disabled(state.working || state.preparingUpdate) }
                    }.orbitCard()
                }
                if state.updateHistory.isEmpty { Text("还没有更新安装记录").foregroundStyle(OrbitTheme.secondary).padding(40) }
            }
        }.padding(28).frame(minWidth: 620, idealWidth: 720, maxWidth: .infinity, minHeight: 440, idealHeight: 520, maxHeight: .infinity).featureSheet()
            .alert("恢复旧版应用？", isPresented: Binding(get: { restoreID != nil }, set: { if !$0 { restoreID = nil } })) {
                Button("恢复旧版") { if let id = restoreID { state.restoreUpdate(id) }; restoreID = nil }; Button("取消", role: .cancel) { restoreID = nil }
            } message: { Text("请保存工作。Orbit 会请求应用正常退出，核对备份身份后交换应用。") }.featureNotice()
    }
}

private struct FeatureNotice: ViewModifier {
    @EnvironmentObject var state: AppState
    var enabled = true
    func body(content: Content) -> some View { content.alert(item: Binding(get: { enabled ? state.notice : nil }, set: { state.notice = $0 })) { item in Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("好"))) } }
}
extension View {
    func featureSheet() -> some View { background(OrbitTheme.background).foregroundStyle(.white).preferredColorScheme(.dark) }
    func featureNotice(enabled: Bool = true) -> some View { modifier(FeatureNotice(enabled: enabled)) }
}
