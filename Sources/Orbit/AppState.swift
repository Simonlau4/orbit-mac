import SwiftUI
import AppKit
import IOKit.pwr_mgt
import OrbitCore

enum OrbitTab: String, CaseIterable, Identifiable {
    case clean = "清理", software = "软件", optimize = "优化", analyze = "分析", status = "状态"
    var id: String { rawValue }
}

enum SoftwareSection: String, CaseIterable { case apps = "已安装", updates = "更新", startup = "启动项", remnants = "残留" }
struct Notice: Identifiable { let id = UUID(); let title: String; let message: String }

@MainActor
final class AppState: ObservableObject {
    @Published var tab: OrbitTab = .clean
    let monitoring = LiveMonitoring()
    private(set) var cleanupIndex = CleanupResultsIndex()
    private(set) var aiIndex = AIResultsIndex()
    private(set) var cleanupResultsID = UUID()
    private(set) var selectedBytes: Int64 = 0
    private(set) var selectedAIBytes: Int64 = 0
    @Published var scan: CleanupScan? {
        didSet { cleanupIndex = CleanupResultsIndex(scan); selectedBytes = cleanupIndex.selectedBytes(selection); cleanupResultsID = UUID() }
    }
    @Published var unifiedScan: UnifiedCleanupScan? {
        didSet { cleanupResultsID = UUID() }
    }
    @Published var selection: Set<String> = [] {
        didSet { selectedBytes = cleanupIndex.selectedBytes(selection) }
    }
    @Published var scanning = false
    @Published var working = false
    @Published var showResults = false
    @Published var showHistory = false
    @Published var showReadPermissions = false
    @Published var readAccessEntries: [ReadAccessEntry] = []
    @Published var checkingReadAccess = false
    @Published var history: [TrashRecord] = []
    @Published var notice: Notice?
    @Published var apps: [AppDescriptor] = []
    @Published var loadingApps = false
    @Published var appWarnings: [String] = []
    @Published var appSearch = ""
    @Published var softwareSection: SoftwareSection = .apps
    @Published var appReview: AppDescriptor?
    @Published var showAppReview = false
    @Published var reviewingApp = false
    @Published var reviewIncludesApp = true
    @Published var reviewSize: Int64?
    @Published var remnantScan: RemnantScan?
    @Published var remnantSelection: Set<String> = []
    @Published var orphanScan: RemnantScan?
    @Published var orphanScanning = false
    @Published var orphanSelection: Set<String> = []
    @Published var appUpdates: [String: AppUpdateResult] = [:]
    @Published var checkingUpdates = false
    @Published var startupScan: StartupScan?
    @Published var startupScanning = false
    @Published var pendingStartup: StartupItem?
    @Published var diskReport: DiskReport?
    @Published var diskScanning = false
    @Published var diskRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    @Published var diskHistory: [URL] = []
    @Published var diskShowHidden = false
    @Published var diskSortByName = false
    @Published var diskShowsLargeFiles = false
    @Published var keepingAwake = false
    @Published var awakeMinutes = 60
    @Published var awakeUntil: Date?
    @Published var maintenanceResults: [String: MaintenanceResult] = [:]
    @Published var maintenanceRunning = false
    @Published var confirmCleaning = false
    @Published var confirmUninstall = false
    @Published var confirmOrphans = false
    @Published var confirmCleanScreen = false
    @Published var pendingTrash: URL?
    @Published var pendingTrashRoot: URL?
    @Published var lastCleanedBytes: Int64 = 0
    @Published var includeRecentCaches = UserDefaults.standard.bool(forKey: "includeRecentCaches") {
        didSet {
            UserDefaults.standard.set(includeRecentCaches, forKey: "includeRecentCaches")
            if includeRecentCaches != oldValue { invalidateCleanupResults() }
        }
    }
    @Published var cleanupCategories: Set<CleanupCategory> = Set(CleanupCategory.allCases) {
        didSet { if cleanupCategories != oldValue { invalidateCleanupResults() } }
    }
    @Published var fanMode: FanCoolingMode = .automatic
    @Published var pendingFanMode: FanCoolingMode?
    @Published var fanMessage = "由系统自动调节"
    @Published var showAI = false
    @Published var aiScan: AICleanupScan? {
        didSet { aiIndex = AIResultsIndex(aiScan?.items ?? []); selectedAIBytes = aiSelection.reduce(0) { $0 + (aiIndex.itemsByID[$1]?.bytes ?? 0) } }
    }
    @Published var aiScanning = false
    @Published var aiRetentionDays = 0 {
        didSet { if aiRetentionDays != oldValue { invalidateAIScanResults() } }
    }
    @Published var aiScanRequestID = UUID()
    var aiScanPolicyDays: Int?
    @Published var aiSelection: Set<String> = [] {
        didSet { selectedAIBytes = aiSelection.reduce(0) { $0 + (aiIndex.itemsByID[$1]?.bytes ?? 0) } }
    }
    @Published var aiHistory: [AIRecoveryRecord] = []
    @Published var aiPackageScan: AIPackageScan?
    @Published var aiPackageReview: AIPackageCandidate?
    @Published var aiPackageHistory: [AIPackageRecord] = []
    @Published var maintenanceChecking = false
    @Published var maintenancePlan: MaintenancePlan?
    @Published var maintenanceSelection: Set<String> = []
    @Published var showMaintenanceReview = false
    @Published var showMaintenanceRecovery = false
    @Published var maintenanceHistory: [MaintenanceRecoveryRecord] = []
    @Published var preparedUpdate: PreparedAppUpdate?
    @Published var showUpdateReview = false
    @Published var preparingUpdate = false
    @Published var installingUpdate = false
    @Published var updateHistory: [AppUpdateInstallation] = []
    @Published var showUpdateHistory = false
    @Published var automaticUpdateIDs = Set(UserDefaults.standard.stringArray(forKey: "automaticUpdateIDs") ?? []) {
        didSet { UserDefaults.standard.set(Array(automaticUpdateIDs), forKey: "automaticUpdateIDs") }
    }
    @Published var updateActivity = ""

    let fanControl = FanControlClient()
    let aiStore: AICleanupStore
    let aiPackageStore: AIPackageStore
    let maintenanceEngine = MaintenanceEngine()
    let updateInstaller = AppUpdateInstaller()
    var aiTask: Task<Void, Never>?
    var automaticUpdatesTask: Task<Void, Never>?
    var automaticExitTask: Task<Void, Never>?
    var automaticExitObserver: NSObjectProtocol?
    var pendingAutomaticUpdates: Set<String> = []
    var automaticUpdatesInFlight: Set<String> = []
    var installTask: Task<Void, Never>?

    let cleanScreen = CleanScreenController()
    private let analyzer = DiskAnalyzer()
    private let inventory = ApplicationInventory()
    private let remnants = AppRemnantScanner()
    private let startup = StartupItemsService()
    private var scanTask: Task<Void, Never>?
    private var cleanupScanRequestID = UUID()
    private(set) var diskTask: Task<Void, Never>?
    private var appsRequestID = UUID()
    private var updatesTask: Task<Void, Never>?
    private var awakeTask: Task<Void, Never>?
    var maintenanceTask: Task<Void, Never>?
    private var assertionID = IOPMAssertionID(0)

    var sampleInterval: Int {
        get { monitoring.sampleInterval }
        set { objectWillChange.send(); monitoring.sampleInterval = newValue }
    }
    var menuMetric: String {
        get { monitoring.menuMetric }
        set { objectWillChange.send(); monitoring.menuMetric = newValue }
    }
    var selectedItems: [CleanupItem] { cleanupIndex.selectedItems(selection) }
    var runningIDs: Set<String> { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
    var filteredApps: [AppDescriptor] { apps.filter { appSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(appSearch) || $0.bundleID.localizedCaseInsensitiveContains(appSearch) } }
    var modalNotice: Bool { showHistory || showReadPermissions || showAppReview || showAI || showMaintenanceReview || showMaintenanceRecovery || showUpdateReview || showUpdateHistory }

    init(aiStore: AICleanupStore = AICleanupStore(), aiPackageStore: AIPackageStore = AIPackageStore()) {
        self.aiStore = aiStore; self.aiPackageStore = aiPackageStore
    }

    func start() {
        guard !monitoring.isRunning else { return }
        monitoring.start()
        loadApps()
        startAutomaticUpdates()
    }

    func stop() {
        monitoring.stop(); scanTask?.cancel(); diskTask?.cancel(); updatesTask?.cancel()
        maintenanceTask?.cancel(); awakeTask?.cancel()
        cleanScreen.stop()
        fanControl.stop(); aiTask?.cancel(); automaticUpdatesTask?.cancel(); installTask?.cancel()
        automaticExitTask?.cancel()
        if let observer = automaticExitObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer); automaticExitObserver = nil }
        if keepingAwake { releaseAwake() }
    }

    func invalidateCleanupResults() {
        cleanupScanRequestID = UUID(); scanTask?.cancel()
        scan = nil; unifiedScan = nil; selection = []; scanning = false; showResults = false; confirmCleaning = false
    }
    func beginCleanupScanRequest() -> UUID? {
        guard !scanning && !working else { return nil }
        invalidateCleanupResults(); scanning = true
        return cleanupScanRequestID
    }
    @discardableResult
    func completeCleanupScanRequest(_ result: CleanupScan, id: UUID, unified: UnifiedCleanupScan? = nil) -> Bool {
        guard id == cleanupScanRequestID else { return false }
        scan = result; unifiedScan = unified; selection = cleanupIndex.recommendedIDs; scanning = false; showResults = true
        return true
    }
    func scanCleanup() {
        guard let requestID = beginCleanupScanRequest() else { return }
        let ids = runningIDs
        let recent = includeRecentCaches, categories = cleanupCategories
        scanTask = Task {
            let result = await UnifiedCleanupScanner(includeRecentCaches: recent, categories: categories).scan(runningBundleIDs: ids)
            completeCleanupScanRequest(result.ordinary, id: requestID, unified: result)
        }
    }
    func cancelScan() { scanTask?.cancel() }

    func checkReadAccess() {
        guard !checkingReadAccess else { return }
        checkingReadAccess = true
        let additional = (unifiedScan?.issues ?? scan?.issues ?? []).filter { $0.kind == .permission }.prefix(120)
            .map { ReadAccessTarget(title: URL(fileURLWithPath: $0.path).lastPathComponent, url: URL(fileURLWithPath: $0.path)) }
        Task {
            readAccessEntries = await ReadAccessProbe().check(ReadAccessProbe.targets() + additional)
            checkingReadAccess = false
        }
    }

    func openReadPermissions() { showReadPermissions = true; checkReadAccess() }

    func cleanSelection() {
        guard !working && !scanning && !selectedItems.isEmpty else { return }
        let items = selectedItems
        let requestID = cleanupScanRequestID
        working = true
        Task {
            let (policy, builds) = await Task.detached(priority: .utility) { (CleanupPolicy.production(), UnifiedCleanupScanner.buildOutputRoots()) }.value
            guard requestID == cleanupScanRequestID else { working = false; return }
            let protection = CleanupRunningProtection(runningBundleIDs: runningIDs, roots: policy.roots)
            let running = items.filter { protection.protects($0.url) }
            guard running.isEmpty else {
                selection.subtract(running.map(\.id))
                notice = Notice(title: "应用已开始运行", message: "已取消选择这些应用的缓存。请先退出应用，再重新扫描。")
                working = false; return
            }
            let folders = items.filter { $0.contents != nil }, directories = BuildOutputs.workingDirectories()
            let busy = folders.filter { item in directories.map { BuildOutputs.inUse(item.url, workingDirectories: $0) } ?? true }
            guard busy.isEmpty else {
                selection.subtract(busy.map(\.id))
                notice = Notice(title: "项目正在使用", message: "已取消选择这些项目的构建产物。关闭在项目里打开的终端或开发服务后，再重新扫描。")
                working = false; return
            }
            let projects = builds.filter { url in folders.contains { $0.url.path == url.path } }.map { $0.deletingLastPathComponent() }
            do {
                let store = await Task.detached(priority: .utility) { TrashStore(allowedRoots: policy.writableRoots.map(\.url) + projects) }.value
                guard requestID == cleanupScanRequestID else { working = false; return }
                report(try await store.moveToTrash(items)); await refreshHistory()
            } catch { fail("清理未完成", error) }
            working = false; scan = nil; unifiedScan = nil; showResults = false; selection = []
        }
    }

    func openHistory() { Task { await refreshHistory(); showHistory = true } }
    private func refreshHistory() async {
        do {
            let store = await Task.detached(priority: .utility) { TrashStore() }.value
            history = try await store.history()
        } catch { fail("无法读取记录", error) }
    }
    func restore(_ record: TrashRecord) {
        guard !working else { return }; working = true
        Task {
            do {
                let store = await Task.detached(priority: .utility) { TrashStore() }.value
                try await store.restore(record.id); invalidateCleanupResults(); await refreshHistory(); loadApps()
            } catch { fail("无法恢复", error) }
            working = false
        }
    }

    func loadApps() {
        let requestID = UUID(); appsRequestID = requestID; loadingApps = true
        Task {
            let result = await inventory.scan()
            guard appsRequestID == requestID else { return }
            let ids = runningIDs
            apps = result.apps.sorted { a, b in
                if ids.contains(a.bundleID) != ids.contains(b.bundleID) { return ids.contains(a.bundleID) }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            appWarnings = result.warnings; loadingApps = false
            migrateAutomaticUpdateTargets()
        }
    }

    func reviewApp(_ app: AppDescriptor) {
        guard !working else { return }
        appReview = app; remnantScan = nil; remnantSelection = []; reviewSize = nil
        reviewIncludesApp = true; reviewingApp = true; showAppReview = true
        let installed = Set(apps.map(\.bundleID))
        Task {
            let result = await remnants.scan(for: app, installedBundleIDs: installed)
            let size = try? await inventory.size(of: app.url)
            guard appReview?.id == app.id else { return }
            remnantScan = result; reviewSize = size; reviewingApp = false
        }
    }

    func uninstallReviewed() {
        guard !working, let app = appReview, let review = remnantScan else { return }
        let chosen = review.items.filter { remnantSelection.contains($0.id) }
        let urls = (reviewIncludesApp ? [app.url] : []) + chosen.map(\.url)
        guard !urls.isEmpty else { return }
        guard !app.isSystem, app.bundleID != Bundle.main.bundleIdentifier, !runningIDs.contains(app.bundleID) else {
            notice = Notice(title: "请先退出应用", message: "系统应用、Orbit 和正在运行的应用不会被移除。")
            return
        }
        working = true
        let roots = review.allowedRoots + [app.url.deletingLastPathComponent()]
        Task {
            do {
                let prepared = try await Task.detached(priority: .utility) { try urls.map { try CleanupItem.prepare(at: $0) } }.value
                guard !runningIDs.contains(app.bundleID) else { throw userError("应用已开始运行，请先退出后重试。") }
                report(try await TrashStore(allowedRoots: roots).moveToTrash(prepared))
                showAppReview = false; loadApps(); await refreshHistory()
            } catch { fail("操作未完成", error) }
            working = false
        }
    }

    func scanOrphans() {
        guard !orphanScanning else { return }; orphanScanning = true; orphanSelection = []; orphanScan = nil
        let ids = Set(apps.map(\.bundleID))
        Task { orphanScan = await remnants.scanOrphans(installedBundleIDs: ids); orphanScanning = false }
    }
    func cleanOrphans() {
        guard !working, let result = orphanScan else { return }
        let chosen = result.items.filter { orphanSelection.contains($0.id) }
        guard !chosen.isEmpty else { return }; working = true
        Task {
            do {
                try await validateOrphanOwnership(chosen)
                let items = try await Task.detached { try chosen.map { try CleanupItem.prepare(at: $0.url) } }.value
                try await validateOrphanOwnership(chosen)
                report(try await TrashStore(allowedRoots: result.allowedRoots).moveToTrash(items))
                await refreshHistory(); orphanScan = nil; orphanSelection = []
            } catch { fail("操作未完成", error) }
            working = false
        }
    }

    func checkUpdates() {
        guard !checkingUpdates else { return }; checkingUpdates = true
        let candidates = apps.filter { $0.appcastURL != nil }
        updatesTask = Task {
            for app in candidates {
                if Task.isCancelled { break }
                appUpdates[app.id] = await AppUpdateChecker().check(app)
            }
            checkingUpdates = false
        }
    }
    func cancelUpdates() { updatesTask?.cancel() }
    func refreshStartup() {
        guard !startupScanning else { return }; startupScanning = true
        Task { startupScan = await startup.scan(); startupScanning = false }
    }
    func changeStartup(_ item: StartupItem) {
        guard !working else { return }; working = true
        Task {
            do {
                try await startup.setEnabled(!item.isEnabled, item: item)
                startupScan = await startup.scan()
                notice = Notice(title: item.isEnabled ? "已停用启动项" : "已启用启动项", message: item.isEnabled ? "\(item.label) 不再自动载入，可在此恢复。" : "\(item.label) 的启动配置已载入。")
            } catch { fail("无法更改启动项", error) }
            working = false
        }
    }

    func chooseDiskRoot() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.message = "选择要分析的文件夹"; panel.directoryURL = diskRoot
        if panel.runModal() == .OK, let url = panel.url { diskHistory = []; diskRoot = url; scanDisk() }
    }
    func enterDisk(_ entry: DiskEntry) {
        guard entry.isDirectory, !diskScanning else { reveal(entry.url); return }
        diskHistory.append(diskRoot); diskRoot = entry.url; scanDisk()
    }
    func diskBack() {
        guard !diskScanning else { return }
        if let previous = diskHistory.popLast() { diskRoot = previous }
        else { diskRoot = diskRoot.deletingLastPathComponent() }
        scanDisk()
    }
    func scanDisk() {
        guard !diskScanning else { return }; diskScanning = true
        let root = diskRoot, hidden = diskShowHidden
        diskTask = Task { diskReport = await analyzer.scan(root, includeHidden: hidden); diskScanning = false }
    }
    func cancelDiskScan() { diskTask?.cancel() }
    func askTrash(_ url: URL, root: URL) { guard !working else { return }; pendingTrashRoot = root; pendingTrash = url }
    func trashPending() {
        guard !working, let url = pendingTrash, let root = pendingTrashRoot else { return }
        pendingTrash = nil; pendingTrashRoot = nil; working = true
        Task {
            do {
                try assertMovableApplication(url)
                let item = try await Task.detached { try CleanupItem.prepare(at: url) }.value
                try assertMovableApplication(url)
                let batch = try await TrashStore(allowedRoots: [root]).moveToTrash([item])
                report(batch)
                await refreshHistory(); refreshDiskAfterTrash(movedItems: batch.records.count)
            } catch { fail("操作未完成", error) }
            working = false
        }
    }

    func refreshDiskAfterTrash(movedItems: Int) { if movedItems > 0 { scanDisk() } }

    func cancelMaintenance() { maintenanceTask?.cancel() }
    func toggleAwake() {
        if keepingAwake { releaseAwake(); return }
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Orbit Keep Awake" as CFString, &assertionID)
        guard result == kIOReturnSuccess else { notice = Notice(title: "无法保持常亮", message: "未能阻止屏幕自动熄灭，请稍后重试；若仍失败，请退出并重新打开 Orbit。（\(result)）"); return }
        keepingAwake = true
        if awakeMinutes > 0 {
            let duration = awakeMinutes
            awakeUntil = Date().addingTimeInterval(Double(duration) * 60)
            awakeTask = Task { try? await Task.sleep(nanoseconds: UInt64(duration) * 60_000_000_000); if !Task.isCancelled { releaseAwake() } }
        } else { awakeUntil = nil }
    }
    private func releaseAwake() {
        awakeTask?.cancel(); awakeTask = nil
        let result = IOPMAssertionRelease(assertionID)
        if result == kIOReturnSuccess { keepingAwake = false; awakeUntil = nil }
        else { notice = Notice(title: "无法关闭常亮", message: "请退出 Orbit 释放电源请求。") }
    }
    private func report(_ batch: TrashBatch) {
        lastCleanedBytes = batch.totalBytes
        let details = batch.failures.prefix(3).map { "\($0.url.lastPathComponent)：\($0.message)" }.joined(separator: "\n")
        notice = Notice(title: batch.records.isEmpty ? "未移动任何文件" : "已移入废纸篓", message: "处理 \(batch.records.count) 项，共 \(prettyBytes(batch.totalBytes))。" + (batch.failures.isEmpty ? "可在清理记录中恢复。" : "\n\(batch.failures.count) 项未处理：\n\(details)"))
    }
    private func fail(_ title: String, _ error: Error) { notice = Notice(title: title, message: error.localizedDescription) }
    private func assertMovableApplication(_ url: URL) throws {
        guard url.pathExtension.lowercased() == "app" else { return }
        let id = Bundle(url: url)?.bundleIdentifier ?? ""
        if id.hasPrefix("com.apple.") || id == Bundle.main.bundleIdentifier || runningIDs.contains(id) {
            throw userError("系统应用、Orbit 或正在运行的应用不能移入废纸篓。请先退出应用。")
        }
    }
    private func validateOrphanOwnership(_ items: [RemnantCandidate]) async throws {
        let current = await inventory.scan()
        let ids = Set(current.apps.map(\.bundleID)).union(runningIDs).filter { !$0.isEmpty }
        if items.contains(where: { item in ids.contains { id in
            id == item.bundleID || id.hasPrefix(item.bundleID + ".") || item.bundleID.hasPrefix(id + ".")
        } }) { throw userError("相关应用已安装或正在运行。请重新查找残留，当前选择不会被移除。") }
    }
}

private let byteCountFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter(); formatter.countStyle = .file; formatter.allowsNonnumericFormatting = false
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB, .usePB]
    return formatter
}()
func prettyBytes<T: BinaryInteger>(_ value: T) -> String { byteCountFormatter.string(fromByteCount: Int64(clamping: value)) }
func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
func userError(_ message: String) -> NSError { NSError(domain: "Orbit", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
