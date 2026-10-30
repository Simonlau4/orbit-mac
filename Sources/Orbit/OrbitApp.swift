import SwiftUI
import AppKit
import Darwin
import OrbitCore

@main
struct OrbitApp: App {
    @NSApplicationDelegateAdaptor(OrbitDelegate.self) var delegate
    @StateObject private var state = AppState()
    @StateObject private var updates = OrbitUpdateMonitor()

    var body: some Scene {
        Window("Orbit", id: "main") {
            RootView().environmentObject(state).environmentObject(state.monitoring).environmentObject(updates)
                .ignoresSafeArea(.container, edges: .top)
                .frame(minWidth: 960, minHeight: 680)
                .preferredColorScheme(.dark)
                .onAppear { delegate.state = state; delegate.updates = updates; state.start(); updates.start(); runSmokeIfRequested() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 772)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(updates.isChecking ? "正在检查更新…" : "检查更新…") { Task { await updates.checkManually() } }.disabled(updates.isChecking)
            }
            CommandGroup(after: .newItem) {
                Button("扫描可清理文件") { state.tab = .clean; state.scanCleanup() }.keyboardShortcut("r")
                Button("清理记录") { state.openHistory() }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("AI 工具清理") { if !state.modalNotice { state.showAI = true } }
            }
            CommandMenu("显示") {
                Button("清理") { state.tab = .clean }.keyboardShortcut("1")
                Button("软件") { state.tab = .software }.keyboardShortcut("2")
                Button("优化") { state.tab = .optimize }.keyboardShortcut("3")
                Button("分析") { state.tab = .analyze }.keyboardShortcut("4")
                Button("状态") { state.tab = .status }.keyboardShortcut("5")
            }
        }
        Settings {
            SettingsView().environmentObject(state).environmentObject(updates)
        }.windowResizability(.contentMinSize)
        MenuBarExtra {
            OrbitMenuContent(monitoring: state.monitoring).environmentObject(state).environmentObject(updates)
        } label: {
            OrbitMenuLabel(monitoring: state.monitoring)
        }.menuBarExtraStyle(.window)
    }

    private func runSmokeIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--ui-smoke"), args.indices.contains(index + 1), !delegate.smokeStarted else { return }
        delegate.smokeStarted = true
        let output = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            if let fixture = args.firstIndex(of: "--disk-fixture"), args.indices.contains(fixture + 1) {
                state.diskRoot = URL(fileURLWithPath: args[fixture + 1], isDirectory: true)
            }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            for tab in OrbitTab.allCases {
                state.tab = tab
                if tab == .analyze {
                    state.scanDisk()
                    for _ in 0..<200 {
                        if !state.diskScanning { break }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let content = NSApp.windows.first(where: { $0.title == "Orbit" })?.contentView,
                   let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: output.appendingPathComponent("\(tab.id).png")) }
                }
            }
            state.tab = .clean
            state.scanCleanup()
            for _ in 0..<1_200 {
                if !state.scanning { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !state.scanning, state.scan != nil, state.unifiedScan != nil else {
                try? "UI smoke incomplete: unified scan did not finish or was invalidated.\n".write(to: output.appendingPathComponent("smoke-incomplete.txt"), atomically: true, encoding: .utf8)
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let result = state.scan { writeCleanupReport(result, to: output.appendingPathComponent("cleanup-summary.json"), includeRecent: state.includeRecentCaches) }
            if let unified = state.unifiedScan {
                ScanDiagnostics.write(unified, to: output.appendingPathComponent("unified-scan-summary.json"))
                if let index = args.firstIndex(of: "--compare-scope"), args.indices.contains(index + 1) {
                    await ScanDiagnostics.compare(unified, manifest: URL(fileURLWithPath: args[index + 1]), output: output.appendingPathComponent("same-scope-comparison.json"))
                }
            }
            state.checkReadAccess()
            for _ in 0..<100 {
                if !state.checkingReadAccess { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            ScanDiagnostics.writeAccess(state.readAccessEntries, to: output.appendingPathComponent("read-access.json"))
            if args.contains("--scan-compare-recent") {
                let result = await CleanupScanner(policy: .production(includeRecentCaches: true, categories: state.cleanupCategories)).scan(runningBundleIDs: state.runningIDs)
                writeCleanupReport(result, to: output.appendingPathComponent("cleanup-recent-summary.json"), includeRecent: true)
            }
            if args.contains("--scan-cache-permissions") {
                let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
                let result = await CleanupScanner(policy: CleanupPolicy(roots: [CleanupRoot(url: root, category: .appCache, minimumAgeDays: 7)])).scan(runningBundleIDs: state.runningIDs)
                writeCleanupReport(result, to: output.appendingPathComponent("cleanup-cache-permissions.json"), includeRecent: false, categories: [.appCache], scope: "Library/Caches only")
            }
            if let content = NSApp.windows.first(where: { $0.title == "Orbit" })?.contentView,
               let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: output.appendingPathComponent("清理结果.png")) }
                func scrollViews(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews) }
                if let scroll = scrollViews(content).max(by: { $0.frame.height < $1.frame.height }), let document = scroll.documentView {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if let bottom = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                        content.cacheDisplay(in: content.bounds, to: bottom)
                        if let data = bottom.representation(using: .png, properties: [:]) { try? data.write(to: output.appendingPathComponent("清理结果-底部.png")) }
                    }
                }
            }
            if let snapshot = state.monitoring.snapshot, let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: output.appendingPathComponent("metrics.json")) }
            state.showResults = false
            if args.contains("--ui-smoke-features") {
                @MainActor func captureFeature(_ name: String) {
                    let window = NSApp.windows.first(where: { $0.isVisible && $0.isSheet }) ?? NSApp.windows.first(where: { $0.title == "Orbit" })
                    if let content = window?.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                        content.cacheDisplay(in: content.bounds, to: rep)
                        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: output.appendingPathComponent(name + ".png")) }
                    }
                }
                state.tab = .status
                try? await Task.sleep(nanoseconds: 500_000_000)
                captureFeature("温度与风扇")
                state.showAI = true; state.scanAI()
                for _ in 0..<350 { if !state.aiScanning { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
                try? await Task.sleep(nanoseconds: 500_000_000)
                captureFeature("AI工具清理")
                state.showAI = false; state.tab = .optimize
                try? await Task.sleep(nanoseconds: 500_000_000)
                state.previewMaintenance(.cleanSavedState)
                for _ in 0..<250 { if !state.maintenanceChecking { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
                try? await Task.sleep(nanoseconds: 500_000_000)
                captureFeature("维护预览")
                state.showMaintenanceReview = false
                state.softwareSection = .updates; state.tab = .software
                try? await Task.sleep(nanoseconds: 500_000_000)
                captureFeature("自动更新")
                state.tab = .clean
                let featureReport = "Thermal CPU: \(state.monitoring.thermalSnapshot?.cpuTemperatureCelsius != nil)\nFans: \(state.monitoring.thermalSnapshot?.fans.count ?? 0)\nAI scan: \(state.aiScan != nil)\nAI selected: \(state.aiSelection.count)\nMaintenance selected: \(state.maintenanceSelection.count)\nAutomatic opt-ins: \(state.automaticUpdateIDs.count)\nHost cleanup performed: false\n"
                try? featureReport.write(to: output.appendingPathComponent("feature-smoke.txt"), atomically: true, encoding: .utf8)
            }
            if let window = NSApp.windows.first(where: { $0.title == "Orbit" }) {
                window.setContentSize(NSSize(width: 960, height: 680))
                try? await Task.sleep(nanoseconds: 350_000_000)
                if let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: output.appendingPathComponent("最小窗口.png")) }
                }
                window.setContentSize(NSSize(width: 1200, height: 772))
            }
            let report = "UI smoke completed: \(OrbitTab.allCases.map(\.rawValue).joined(separator: ", "))\nLive metrics: \(state.monitoring.snapshot != nil)\nInstalled apps: \(state.apps.count)\n"
            try? report.write(to: output.appendingPathComponent("smoke.txt"), atomically: true, encoding: .utf8)
        }
    }

    private func writeCleanupReport(_ scan: CleanupScan, to url: URL, includeRecent: Bool, categories: Set<CleanupCategory>? = nil, scope: String = "production") {
        let issues: [[String: Any]] = scan.issues.map { issue in
            ["kind": String(describing: issue.kind), "path": issue.path, "message": issue.message,
             "errorDomain": issue.errorDomain.map { $0 as Any } ?? NSNull(),
             "errorCode": issue.errorCode.map { $0 as Any } ?? NSNull(),
             "underlyingPOSIXCode": issue.underlyingPOSIXCode.map { $0 as Any } ?? NSNull()]
        }
        let retained: [[String: Any]] = scan.retained.map { entry in
            ["reason": String(describing: entry.reason), "category": entry.category.rawValue,
             "root": entry.rootURL.path, "count": entry.count, "bytes": entry.bytes,
             "isPartial": entry.isPartial,
             "ownerBundleID": entry.ownerBundleID.map { $0 as Any } ?? NSNull()]
        }
        let groups: [[String: Any]] = scan.groups.map { group in
            ["name": group.name, "category": group.category.rawValue, "bytes": group.bytes,
             "fileCount": group.items.count, "samplePaths": Array(group.items.prefix(3).map(\.url.path))]
        }
        let report: [String: Any] = ["capturedAt": ISO8601DateFormatter().string(from: Date()),
            "pid": ProcessInfo.processInfo.processIdentifier, "uid": getuid(),
            "bundleID": Bundle.main.bundleIdentifier ?? "", "bundlePath": Bundle.main.bundleURL.path,
            "includeRecentCaches": includeRecent, "categories": (categories ?? state.cleanupCategories).map(\.rawValue).sorted(), "scope": scope,
            "candidateBytes": scan.totalBytes, "candidateFiles": scan.items.count,
            "scannedBytes": scan.scannedBytes, "scannedFiles": scan.scannedFiles, "visitedEntries": scan.visitedEntries,
            "isPartial": scan.isPartial, "blockedCount": scan.blockedCount, "warnings": scan.warnings,
            "issues": issues, "retained": retained, "groups": groups, "selectedItems": state.selection.count,
            "cleanupPerformed": false]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: .atomic) }
    }
}

private struct OrbitMenuContent: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var updates: OrbitUpdateMonitor
    @ObservedObject var monitoring: LiveMonitoring
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Orbit").font(.headline)
            if let s = monitoring.snapshot {
                Text("CPU  \(s.cpuUsage, specifier: "%.1f")%")
                Text("内存  \(prettyBytes(s.memoryUsed)) / \(prettyBytes(s.memoryTotal))")
                Text("磁盘可用  \(prettyBytes(s.diskAvailable))")
                if let temperature = s.temperatureCelsius { Text("CPU 温度  \(temperature, specifier: "%.1f")°C") }
            } else { Text("正在读取系统状态…") }
            Divider()
            Button(state.keepingAwake ? "关闭屏幕常亮" : "保持屏幕常亮") { state.toggleAwake() }
            Menu("风扇降温") {
                ForEach(FanCoolingMode.allCases) { mode in Button(mode.title) { openWindow(id: "main"); state.tab = .status; NSApp.activate(ignoringOtherApps: true); if mode == .automatic && state.fanControl.isRunning { state.changeFan(mode) } else { state.pendingFanMode = mode } } }
            }
            Button("AI 工具清理") { openWindow(id: "main"); if !state.modalNotice { state.showAI = true }; NSApp.activate(ignoringOtherApps: true) }
            Button("打开 Orbit") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            if let release = updates.availableRelease { Link("更新至 Orbit " + release.version, destination: release.url) }
            else { Button(updates.isChecking ? "正在检查更新…" : "检查更新…") { Task { await updates.checkManually() } }.disabled(updates.isChecking) }
            Button("退出 Orbit") { NSApp.terminate(nil) }
        }.padding(16).frame(width: 260)
    }
}

private struct OrbitMenuLabel: View {
    @ObservedObject var monitoring: LiveMonitoring
    var body: some View {
        HStack(spacing: 3) { Image(systemName: "circle.dotted.circle"); Text(monitoring.menuLabel) }
            .accessibilityLabel("Orbit，\(monitoring.menuMetric)，\(monitoring.menuLabel)")
    }
}

final class OrbitDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?
    weak var updates: OrbitUpdateMonitor?
    var smokeStarted = false
    private var confirmingFanExit = false
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.activate(ignoringOtherApps: true) }
    func applicationWillTerminate(_ notification: Notification) { state?.stop(); updates?.stop() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state, state.fanControl.isRunning || !state.fanControl.lastRestoreConfirmed else { return .terminateNow }
        guard !confirmingFanExit else { return .terminateLater }
        confirmingFanExit = true
        Task { @MainActor in
            let restored = await state.fanControl.confirmAutomaticBeforeExit()
            if restored { sender.reply(toApplicationShouldTerminate: true) }
            else {
                let alert = NSAlert()
                alert.messageText = "无法确认风扇已经恢复自动"
                alert.informativeText = "请保留 Orbit 并重试恢复自动调节。若仍无法恢复，重启 Mac 会交回系统控制。"
                alert.addButton(withTitle: "保留 Orbit")
                alert.addButton(withTitle: "仍然退出")
                sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
            }
            confirmingFanExit = false
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
