import SwiftUI
import AppKit
import OrbitCore

struct ReadPermissionsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                PageHeading(eyebrow: "", title: "读取权限", subtitle: "由当前 Orbit 进程实际尝试读取")
                Button("完成") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("在系统设置的“完全磁盘访问权限”中开启 Orbit；列表里没有时，用“＋”添加此应用。按 macOS 提示重新打开 Orbit 后，再次扫描。")
                Text(Bundle.main.bundleURL.path).font(.system(size: 11)).textSelection(.enabled).foregroundStyle(OrbitTheme.secondary)
                HStack {
                    Button("打开系统权限设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                    }.buttonStyle(QuietButton())
                    Button("在 Finder 显示 Orbit") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }.buttonStyle(QuietButton())
                }
            }.font(.system(size: 12)).orbitCard()
            HStack {
                Text(state.checkingReadAccess ? "正在检测…" : "可读取 \(state.readAccessEntries.filter { $0.status == .readable }.count) 处 · 受限 \(state.readAccessEntries.filter { $0.status == .denied }.count) 处")
                Spacer()
                Button("重新检测") { state.checkReadAccess() }.buttonStyle(QuietButton()).disabled(state.checkingReadAccess)
            }.font(.system(size: 12))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    ForEach(state.readAccessEntries) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: entry.status == .readable ? "checkmark.circle" : entry.status == .denied ? "lock.circle" : "minus.circle")
                                .foregroundStyle(entry.status == .readable ? OrbitTheme.mint : OrbitTheme.amber)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.target.title)
                                Text(shortPath(entry.target.url)).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Text(statusTitle(entry.status)).foregroundStyle(OrbitTheme.secondary)
                        }.font(.system(size: 12))
                    }
                }.padding(.vertical, 8)
            }.frame(minHeight: 100, idealHeight: 180, maxHeight: .infinity)
            Text("这里显示路径的实际读取结果，不推断系统权限开关。缺失目录无需授权；受系统保护的内容可能仍不可读。")
                .font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
            HStack {
                Spacer()
                Button("重新扫描全部范围") { dismiss(); state.scanCleanup() }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction).disabled(state.scanning || state.working)
            }
        }.padding(28).frame(minWidth: 600, idealWidth: 650, maxWidth: .infinity, minHeight: 500, idealHeight: 560, maxHeight: .infinity).featureSheet()
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in state.checkReadAccess() }
    }

    private func statusTitle(_ status: ReadAccessStatus) -> String {
        switch status {
        case .readable: return "可读取"
        case .denied: return "macOS 拒绝读取"
        case .missing: return "目录不存在"
        case .unavailable: return "暂时无法读取"
        }
    }
}
