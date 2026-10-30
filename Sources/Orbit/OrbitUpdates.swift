import SwiftUI
import AppKit
import OrbitCore

@MainActor
final class OrbitUpdateMonitor: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var availableRelease: OrbitRelease?
    @Published private(set) var message = ""
    private let version: String
    private let checker: OrbitReleaseChecker
    private var task: Task<Void, Never>?

    init(version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0", checker: OrbitReleaseChecker = OrbitReleaseChecker()) {
        self.version = version; self.checker = checker
    }
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                do { try await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000) }
                catch { return }
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let release = try await checker.availableRelease(after: version)
            guard !Task.isCancelled else { return }
            availableRelease = release
            message = release.map { "可更新至 Orbit " + $0.version } ?? "当前已是最新版本"
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { message = "检查更新失败，请稍后重试。" }
        }
    }
    func checkManually() async {
        guard !isChecking else { return }
        await check()
        let alert = NSAlert()
        alert.messageText = availableRelease.map { "Orbit " + $0.version + " 可以更新" } ?? "检查更新"
        alert.informativeText = availableRelease == nil ? message : "当前版本为 \(version)。查看新版说明并下载安装包。"
        alert.addButton(withTitle: availableRelease == nil ? "好" : "查看新版")
        if availableRelease != nil { alert.addButton(withTitle: "稍后").keyEquivalent = "\u{1b}" }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let release = availableRelease { NSWorkspace.shared.open(release.url) }
    }
}

struct OrbitUpdateBanner: View {
    @EnvironmentObject var updates: OrbitUpdateMonitor
    var body: some View {
        if let release = updates.availableRelease {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle").accessibilityHidden(true)
                Text("Orbit \(release.version) 可以更新")
                Spacer()
                Link("查看新版", destination: release.url)
            }.font(.system(size: 12)).foregroundStyle(OrbitTheme.blue)
                .orbitCard(padding: 12).padding(.horizontal, 36).padding(.bottom, 12)
        }
    }
}
