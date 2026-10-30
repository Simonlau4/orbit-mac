import SwiftUI
import AppKit
import OrbitCore

struct RootView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        VStack(spacing: 0) {
            header
            OrbitUpdateBanner()
            Group {
                switch state.tab {
                case .clean:
                    if state.showResults, state.scan != nil { CleanupResultsView() } else { CleanLandingView() }
                case .software: SoftwareView()
                case .optimize: OptimizeView()
                case .analyze: AnalyzeView()
                case .status: StatusView()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if state.tab != .clean || state.showResults { footer }
        }
        .background(LinearGradient(colors: [OrbitTheme.gradientTop, OrbitTheme.background], startPoint: .top, endPoint: .bottom))
        .foregroundStyle(.white).font(.system(size: 13))
        .sheet(isPresented: $state.showHistory) { HistoryView().environmentObject(state) }
        .sheet(isPresented: $state.showReadPermissions) { ReadPermissionsView().environmentObject(state) }
        .sheet(isPresented: $state.showAppReview) { AppReviewView().environmentObject(state) }
        .sheet(isPresented: $state.showAI) { AICleanupView().environmentObject(state) }
        .sheet(isPresented: $state.showMaintenanceReview) { MaintenanceReviewView().environmentObject(state) }
        .sheet(isPresented: $state.showMaintenanceRecovery) { MaintenanceHistoryView().environmentObject(state) }
        .sheet(isPresented: $state.showUpdateReview) { UpdateReviewView().environmentObject(state) }
        .sheet(isPresented: $state.showUpdateHistory) { UpdateHistoryView().environmentObject(state) }
        .confirmationDialog("将选中的 \(state.selection.count) 个文件移入废纸篓？", isPresented: $state.confirmCleaning, titleVisibility: .visible) {
            Button("移入废纸篓 · \(prettyBytes(state.selectedBytes))", role: .destructive) { state.cleanSelection() }
            Button("取消", role: .cancel) {}
        } message: { Text("执行前复核文件；恢复入口在清理记录中。清空废纸篓后无法恢复。") }
        .alert("移入废纸篓？", isPresented: Binding(get: { state.pendingTrash != nil }, set: { if !$0 { state.pendingTrash = nil } }), presenting: state.pendingTrash) { url in
            Button("移入废纸篓", role: .destructive) { state.pendingTrash = url; state.trashPending() }
            Button("取消", role: .cancel) { state.pendingTrashRoot = nil }
        } message: { url in Text(url.path + "\n\n可在清理记录中恢复。") }
        .overlay {
            Color.clear.frame(width: 0, height: 0).alert(item: Binding(get: { state.modalNotice ? nil : state.notice }, set: { state.notice = $0 })) { notice in
                Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("好")))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.dotted.circle.fill").font(.system(size: 20)).foregroundStyle(OrbitTheme.logoInk)
                .frame(width: 31, height: 31).background(OrbitTheme.logoFill, in: Circle()).padding(.trailing, 3)
                .accessibilityLabel("Orbit")
            ForEach(OrbitTab.allCases) { tab in
                Button { state.tab = tab } label: {
                    Text(tab.rawValue).font(.system(size: 13, weight: .semibold))
                        .frame(width: 65, height: 35).orbitSelection(state.tab == tab)
                }.buttonStyle(.plain).accessibilityLabel(tab.rawValue).accessibilityAddTraits(state.tab == tab ? .isSelected : [])
            }
        }.padding(5).background(OrbitTheme.tabSurface, in: Capsule()).overlay(Capsule().stroke(contrast == .increased ? OrbitTheme.contrastBorder : OrbitTheme.tabBorder))
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                HStack(spacing: 7) {
                    Button { state.openHistory() } label: { Image(systemName: "clock.arrow.circlepath").padding(7) }.buttonStyle(.plain).accessibilityLabel("清理记录与恢复").help("清理记录与恢复")
                    SettingsLink {
                        HStack(spacing: 5) { Dot(); Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"); Image(systemName: "gearshape").font(.system(size: 11)) }
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(OrbitTheme.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(OrbitTheme.subtleSurface, in: Capsule()).overlay(Capsule().stroke(OrbitTheme.mint.opacity(0.12)))
                    }.buttonStyle(.plain).accessibilityLabel("设置").help("设置")
                }.padding(.trailing, 24)
            }.padding(.top, 40).padding(.bottom, 18)
    }
    private var footer: some View {
        HStack {
            if state.working { ProgressView().controlSize(.mini); Text("正在处理…") }
            else { Image(systemName: "lock.shield"); Text("本地处理") }
            Spacer()
        }.font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary).padding(.horizontal, 36).padding(.vertical, 12)
    }
}

struct CleanLandingView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 570
            let diameter: CGFloat = compact ? 220 : 246
            ZStack {
                PlanetView(spinning: state.scanning).frame(width: diameter, height: diameter)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.357)
                    .accessibilityHidden(true)
                PlanetView(moon: true).frame(width: 41, height: 41)
                    .position(x: geometry.size.width * 0.785, y: geometry.size.height * 0.109)
                    .accessibilityHidden(true)
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        if state.scanning { ProgressView().controlSize(.small) }
                        Text(title).font(.system(size: 30, weight: .semibold)).monospacedDigit()
                    }
                    HStack(spacing: 5) {
                        if state.scan != nil && !state.scanning {
                            Text("已选 " + prettyBytes(state.selectedBytes)).fontWeight(.semibold)
                        } else { Text(subtitle).foregroundStyle(OrbitTheme.secondary) }
                        if state.scan != nil && !state.scanning {
                            Text("·").foregroundStyle(OrbitTheme.secondary)
                            Button("重新扫描") { state.scanCleanup() }.buttonStyle(.link).foregroundStyle(OrbitTheme.blue).disabled(state.working)
                        }
                    }.font(.system(size: 12, weight: .medium))
                    Button {
                        if state.scanning { state.cancelScan() }
                        else if state.scan != nil { state.showResults = true }
                        else { state.scanCleanup() }
                    } label: {
                        Text(state.scanning ? "停止扫描" : state.scan == nil ? "开始扫描" : "查看结果").frame(width: 180, height: 21)
                    }.buttonStyle(PrimaryButton()).frame(width: 236, height: 47).padding(.top, 4).disabled(state.working)
                }.position(x: geometry.size.width / 2, y: geometry.size.height * (compact ? 0.72 : 0.731))
                Button { state.showAI = true } label: { Label("AI 工具清理", systemImage: "sparkles").font(.system(size: 11)).foregroundStyle(OrbitTheme.secondary) }.buttonStyle(.link)
                    .position(x: geometry.size.width - 88, y: geometry.size.height - 27)

            }
        }
    }
    private var title: String {
        if state.scanning { return "正在扫描" }
        guard state.scan != nil else { return "给 Mac 腾出空间" }
        return "可以释放 " + prettyBytes(state.cleanupIndex.totalBytes)
    }
    private var subtitle: String {
        if state.scanning { return "检查应用、开发与 AI 工具、系统缓存和废纸篓" }
        return "扫描后查看结果，再选择清理内容"
    }
}

struct PageHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 25, weight: .semibold))
            if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(OrbitTheme.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
