import SwiftUI
import OrbitCore

struct AIPackageList: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if let scan = state.aiPackageScan {
            DisclosureGroup("工具程序包 · \(scan.candidates.count) 项可审阅") {
                ForEach(scan.candidates) { candidate in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(candidate.name + " · " + candidate.version).font(.system(size: 11, weight: .medium))
                            Text(shortPath(candidate.packageURL)).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).lineLimit(1).truncationMode(.middle).help(candidate.packageURL.path)
                        }
                        Spacer()
                        Text(prettyBytes(candidate.bytes)).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                        Button("审阅卸载") { state.aiPackageReview = candidate }.buttonStyle(QuietButton()).disabled(state.working || state.aiScanning)
                    }.padding(.vertical, 9)
                }
                if scan.candidates.isEmpty { Text("未发现可确认独立归属且未运行的程序包").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).padding(.vertical, 8) }
                if !scan.retained.isEmpty {
                    DisclosureGroup("程序包已保留 · \(scan.retained.count) 项") {
                        ForEach(scan.retained) { item in VStack(alignment: .leading, spacing: 4) { Text(item.name); Text(item.reason).foregroundStyle(OrbitTheme.amber) }.font(.system(size: 11)).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading) }
                    }.font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
                }
                if !scan.warnings.isEmpty { Text(scan.warnings.joined(separator: "\n")).font(.system(size: 11)).foregroundStyle(OrbitTheme.amber) }
            }.font(.system(size: 12))
        }
    }
}

struct AIPackageReviewView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    let candidate: AIPackageCandidate
    @State private var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { PageHeading(eyebrow: "", title: "卸载程序包", subtitle: candidate.name + " · " + candidate.version); Button("关闭") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction) }
            Text("只移走下列程序与所属链接；配置、会话和共享依赖保留。可在 AI 工具清理的程序包恢复记录中还原。").font(.system(size: 12)).foregroundStyle(OrbitTheme.secondary)
            HStack { Text(prettyBytes(candidate.bytes)); Spacer(); Text("程序文件更新于 " + candidate.modifiedAt.formatted(date: .abbreviated, time: .omitted)) }.font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
            if !candidate.dependencies.isEmpty { Text("保留依赖：" + candidate.dependencies.joined(separator: "、")).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(candidate.paths, id: \.path) { path in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(shortPath(path)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            if let target = candidate.linkTargets[path.path] { Text("链接目标：" + shortPath(URL(fileURLWithPath: target))).font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading).orbitCard()
                    }
                }
            }
            Text("文件更新时间仅供核对，不能证明工具已闲置。恢复副本仍占磁盘空间。").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary)
            HStack { if state.working { ProgressView().controlSize(.small) }; Spacer(); Button("卸载并保留恢复副本") { confirm = true }.buttonStyle(PrimaryButton()).disabled(state.working) }
        }.padding(26).frame(minWidth: 620, idealWidth: 680, maxWidth: .infinity, minHeight: 460, idealHeight: 540, maxHeight: .infinity).featureSheet()
            .confirmationDialog("卸载 \(candidate.name)？", isPresented: $confirm, titleVisibility: .visible) {
                Button("确认卸载程序包", role: .destructive) { state.removeAIPackage(candidate) }; Button("取消", role: .cancel) {}
            } message: { Text("程序与链接将移入恢复目录。执行前再次核对依赖、活动状态和文件，已有新内容时会停止。") }.featureNotice()
    }
}
