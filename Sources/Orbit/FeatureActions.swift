import Foundation
import AppKit
import OrbitCore

extension AppState {
    var aiResultsAreCurrent: Bool { !aiScanning && aiScan != nil && aiScanPolicyDays == aiRetentionDays }
    var selectedAIItems: [AICleanupCandidate] {
        aiResultsAreCurrent ? aiSelection.compactMap { aiIndex.itemsByID[$0] }.sorted { (aiIndex.itemOrder[$0.id] ?? 0) < (aiIndex.itemOrder[$1.id] ?? 0) } : []
    }
    func relatedAISessions(for item: AICleanupCandidate) -> [AICleanupCandidate] {
        (aiIndex.relatedIDs[item.id] ?? []).compactMap { aiIndex.itemsByID[$0] }
    }

    func selectRelatedAISessions(_ item: AICleanupCandidate) {
        guard !working, aiResultsAreCurrent else { return }
        aiSelection.formUnion(relatedAISessions(for: item).map(\.id))
    }

    func changeFan(_ mode: FanCoolingMode) {
        if mode == .automatic && fanControl.isRunning { fanControl.stop(); fanMode = .automatic; fanMessage = "正在交回系统…"; return }
        do {
            fanControl.onFinish = { [weak self] message, restored in
                self?.fanMode = .automatic; self?.fanMessage = message
                if !restored { self?.notice = Notice(title: "风扇控制已结束", message: message) }
            }
            try fanControl.start(mode); fanMode = mode
            fanMessage = mode == .automatic ? "正在恢复自动调节…" : "等待系统认证与硬件读回…"
        } catch { notice = Notice(title: "风扇未更改", message: error.localizedDescription) }
    }
    func invalidateAIScanResults() {
        if aiScanning { aiTask?.cancel() }
        aiScanRequestID = UUID(); aiScanPolicyDays = nil
        aiScan = nil; aiPackageScan = nil; aiPackageReview = nil; aiSelection = []
        aiScanning = false
    }
    func beginAIScanRequest() -> (id: UUID, days: Int)? {
        guard !working && !aiScanning else { return nil }
        invalidateAIScanResults(); aiScanning = true
        return (aiScanRequestID, aiRetentionDays)
    }
    @discardableResult
    func completeAIScanRequest(_ scan: AICleanupScan, packages: AIPackageScan?, id: UUID, days: Int) -> Bool {
        guard id == aiScanRequestID, days == aiRetentionDays else { return false }
        aiScanPolicyDays = days; aiSelection = []
        aiScan = scan; aiPackageScan = packages; aiScanning = false
        return true
    }
    func scanAI() {
        guard let request = beginAIScanRequest() else { return }
        aiTask = Task {
            let result = await AICleanupScanner().scan(sessionRetentionDays: request.days > 0 ? request.days : nil)
            guard request.id == aiScanRequestID, request.days == aiRetentionDays else { return }
            let packages = Task.isCancelled ? nil : await AIPackageScanner().scan()
            guard completeAIScanRequest(result, packages: packages, id: request.id, days: request.days) else { return }
            await refreshAIHistory()
        }
    }
    private func aiPolicyAllows(_ items: [AICleanupCandidate], days: Int) -> Bool {
        let conversations: Set<AICleanupKind> = [.session, .databaseSession, .archive]
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        return items.allSatisfy { !conversations.contains($0.kind) || (days > 0 && $0.modifiedAt <= cutoff) }
    }
    func cleanAI(expectedRequestID: UUID) {
        guard !working else { return }
        guard expectedRequestID == aiScanRequestID, aiResultsAreCurrent else {
            notice = Notice(title: "扫描条件已变化", message: "请按当前保留策略重新扫描和选择，再确认处理。")
            return
        }
        let selected = selectedAIItems, days = aiRetentionDays
        guard !selected.isEmpty else { return }
        guard aiPolicyAllows(selected, days: days) else {
            aiSelection = []; notice = Notice(title: "对话已保留", message: "所选内容与当前对话保留策略不符，请重新扫描。")
            return
        }
        working = true
        aiTask = Task {
            guard !Task.isCancelled, expectedRequestID == aiScanRequestID, days == aiRetentionDays,
                  aiResultsAreCurrent, aiPolicyAllows(selected, days: days) else {
                notice = Notice(title: "扫描条件已变化", message: "未处理旧候选，请重新扫描和确认。")
                working = false; return
            }
            do {
                let record = try await aiStore.apply(selected)
                notice = Notice(title: "AI 数据已保存恢复副本", message: record.message + "\n恢复副本仍占用磁盘空间；可在本页恢复记录查看。")
                invalidateAIScanResults()
                invalidateCleanupResults()
            } catch { notice = Notice(title: "AI 清理未完成", message: error.localizedDescription) }
            await refreshAIHistory(); working = false
        }
    }
    func refreshAIHistory() async {
        do { aiHistory = try await aiStore.history().reversed(); aiPackageHistory = try await aiPackageStore.history() }
        catch { notice = Notice(title: "AI 恢复记录不可读", message: error.localizedDescription) }
    }
    func restoreAI(_ id: UUID) {
        guard !working else { return }; working = true
        Task {
            do { try await aiStore.restore(id); invalidateCleanupResults(); notice = Notice(title: "已恢复 AI 数据", message: "文件已还原；原位置已有内容时会停止并报告冲突。") }
            catch { notice = Notice(title: "AI 恢复未完成", message: error.localizedDescription) }
            await refreshAIHistory(); working = false
        }
    }
    func removeAIPackage(_ candidate: AIPackageCandidate) {
        guard !working else { return }; working = true
        aiTask = Task {
            do {
                let record = try await aiPackageStore.remove(candidate)
                aiPackageReview = nil; aiPackageScan = nil; aiScan = nil; aiSelection = []
                notice = Notice(title: "程序包已保留恢复副本", message: record.message + "\n配置与会话保留。恢复副本仍占磁盘空间。")
            } catch { notice = Notice(title: "程序包处理未完成", message: error.localizedDescription) }
            await refreshAIHistory(); working = false
        }
    }
    func restoreAIPackage(_ id: UUID) {
        guard !working else { return }; working = true
        aiTask = Task {
            do { try await aiPackageStore.restore(id); notice = Notice(title: "程序包已恢复", message: "程序和对应链接已还原；配置与会话未更改。") }
            catch { notice = Notice(title: "程序包恢复未完成", message: error.localizedDescription) }
            await refreshAIHistory(); working = false
        }
    }

    func previewMaintenance(_ task: MaintenanceTask) {
        guard !working && !maintenanceChecking else { return }
        maintenanceChecking = true; maintenanceSelection = []
        Task {
            maintenancePlan = await maintenanceEngine.preview(task, runningBundleIDs: runningIDs)
            maintenanceChecking = false; showMaintenanceReview = true
        }
    }
    func executeMaintenancePlan() {
        guard !working, let plan = maintenancePlan else { return }
        working = true; maintenanceRunning = true
        let selected = maintenanceSelection
        maintenanceTask = Task {
            let result = await maintenanceEngine.execute(plan, selectedIDs: selected)
            maintenanceResults[plan.task.rawValue] = result
            notice = Notice(title: plan.task.title, message: result.message)
            working = false; maintenanceRunning = false
            await refreshMaintenanceHistory()
        }
    }
    func authorizeLoginAudit() {
        guard !working else { return }; working = true
        maintenanceTask = Task { maintenancePlan = await maintenanceEngine.authorizedLoginAudit(); working = false }
    }
    func refreshMaintenanceHistory() async {
        do { maintenanceHistory = try await maintenanceEngine.history() }
        catch { notice = Notice(title: "维护恢复记录不可读", message: error.localizedDescription) }
    }
    func openMaintenanceHistory() {
        showMaintenanceRecovery = true
        Task { await refreshMaintenanceHistory() }
    }
    func restoreMaintenance(_ id: UUID) {
        guard !working else { return }; working = true
        Task {
            do { try await maintenanceEngine.restore(id); notice = Notice(title: "维护数据已恢复", message: "已还原未发生后续变化的文件和数据库。") }
            catch { notice = Notice(title: "维护恢复未完成", message: error.localizedDescription) }
            await refreshMaintenanceHistory(); working = false
        }
    }

    func prepareUpdate(_ app: AppDescriptor) {
        guard !working && !preparingUpdate, let result = appUpdates[app.id] else { return }
        preparingUpdate = true; updateActivity = "正在下载并验证 " + app.name
        installTask = Task {
            do { preparedUpdate = try await updateInstaller.prepare(app, update: result); showUpdateReview = true }
            catch { notice = Notice(title: "更新未准备完成", message: error.localizedDescription) }
            preparingUpdate = false; updateActivity = ""; await refreshUpdateHistory()
        }
    }
    func installPreparedUpdate() {
        guard !working, let plan = preparedUpdate else { return }
        working = true; installingUpdate = true
        installTask = Task {
            do {
                let result: AppUpdateInstallation
                if plan.requiresSystemInstaller { result = try await updateInstaller.openSystemInstaller(plan) }
                else if plan.requiresAdministrator {
                    let runner = try await updateAuthorizationRunner()
                    result = try await updateInstaller.installAuthorized(plan, runner: runner, quitIfRunning: true)
                } else { result = try await updateInstaller.install(plan, quitIfRunning: true) }
                notice = Notice(title: plan.requiresSystemInstaller ? "系统安装器已打开" : "更新完成", message: result.message)
                preparedUpdate = nil
                loadApps()
            } catch { notice = Notice(title: "安装未完成", message: error.localizedDescription) }
            working = false; installingUpdate = false; await refreshUpdateHistory()
        }
    }
    func refreshUpdateHistory() async {
        do { updateHistory = try await updateInstaller.history() }
        catch { notice = Notice(title: "更新记录不可读", message: error.localizedDescription) }
    }
    func restoreUpdate(_ id: UUID) {
        guard !working else { return }; working = true
        Task {
            do {
                let history = try await updateInstaller.history()
                let record: AppUpdateInstallation
                if history.first(where: { $0.id == id })?.requiresAdministrator == true {
                    record = try await updateInstaller.restoreAuthorized(id, runner: try await updateAuthorizationRunner(), quitIfRunning: true)
                } else { record = try await updateInstaller.restore(id, quitIfRunning: true) }
                notice = Notice(title: "旧版已恢复", message: record.message); loadApps()
            }
            catch { notice = Notice(title: "旧版恢复未完成", message: error.localizedDescription) }
            working = false; await refreshUpdateHistory()
        }
    }
    private func updateAuthorizationRunner() async throws -> UpdateAuthorizationRunner {
        let launcher = try await Task.detached(priority: .utility) { try PrivilegedToolLauncher(.update) }.value
        return { invocation in
            let result = await MaintenanceService.execute(try launcher.command(arguments: invocation.arguments, timeout: 600))
            if result.output.contains("(-128)") || result.output.localizedCaseInsensitiveContains("user canceled") { throw UpdateAuthorizationError.cancelled }
            if result.cancelled || result.timedOut { throw UpdateAuthorizationError.receiptUnavailable }
            guard result.exitCode == 0 else { throw UpdateAuthorizationError.io(String(result.output.prefix(600))) }
        }
    }
    func migrateAutomaticUpdateTargets() {
        // Preserve earlier settings, then use the exact installation path for new opt-ins.
        let legacy = automaticUpdateIDs.filter { !$0.hasPrefix("/") }
        guard !legacy.isEmpty else { return }
        automaticUpdateIDs.subtract(legacy)
        automaticUpdateIDs.formUnion(apps.filter { legacy.contains($0.bundleID) }.map(\.id))
    }
    func setAutomaticUpdate(_ enabled: Bool, for app: AppDescriptor) {
        if enabled {
            automaticUpdateIDs.insert(app.id)
            enqueueAutomaticUpdate(app.id)
        } else {
            automaticUpdateIDs.remove(app.id)
            pendingAutomaticUpdates.remove(app.id)
        }
    }
    func startAutomaticUpdates() {
        guard automaticUpdatesTask == nil else { return }
        automaticExitObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for app in self.apps where app.bundleID == bundleID && self.automaticUpdateIDs.contains(app.id) { self.enqueueAutomaticUpdate(app.id) }
            }
        }
        automaticUpdatesTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                await self.performAutomaticUpdates()
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
        }
    }
    func enqueueAutomaticUpdate(_ appID: String) {
        guard automaticUpdateIDs.contains(appID) else { return }
        pendingAutomaticUpdates.insert(appID)
        guard automaticExitTask == nil else { return }
        automaticExitTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let id = self.pendingAutomaticUpdates.sorted().first else { break }
                if self.working || self.preparingUpdate {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                self.pendingAutomaticUpdates.remove(id)
                await self.performAutomaticUpdates(only: id)
            }
            self?.automaticExitTask = nil
        }
    }
    func performAutomaticUpdates(only appID: String? = nil) async {
        guard !automaticUpdateIDs.isEmpty, !working && !preparingUpdate else { return }
        let candidates = apps.filter { automaticUpdateIDs.contains($0.id) && (appID == nil || $0.id == appID) && !$0.isSystem && $0.bundleID != Bundle.main.bundleIdentifier && $0.appcastURL != nil }
        for app in candidates {
            guard !Task.isCancelled else { return }
            await automaticallyUpdate(app)
        }
    }
    private func automaticallyUpdate(_ app: AppDescriptor) async {
        guard automaticUpdateIDs.contains(app.id), !automaticUpdatesInFlight.contains(app.id),
              !working && !preparingUpdate, !runningIDs.contains(app.bundleID) else { return }
        automaticUpdatesInFlight.insert(app.id)
        defer { automaticUpdatesInFlight.remove(app.id) }
        do {
            let result = await AppUpdateChecker().check(app)
            appUpdates[app.id] = result
            guard !Task.isCancelled, result.state == .updateAvailable, automaticUpdateIDs.contains(app.id), !working && !preparingUpdate else { return }
            preparingUpdate = true; updateActivity = "自动更新 " + app.name
            defer { preparingUpdate = false }
            let history = try await updateInstaller.history()
            let ready = history.first { $0.state == .prepared && $0.appURL == app.url && $0.oldVersion == app.version && $0.newVersion == result.availableVersion }
            let plan: PreparedAppUpdate
            if let ready { plan = try await updateInstaller.preparedUpdate(ready.id) }
            else { plan = try await updateInstaller.prepare(app, update: result) }
            guard !Task.isCancelled, automaticUpdateIDs.contains(app.id) else { return }
            guard !working else { enqueueAutomaticUpdate(app.id); return }
            guard !plan.requiresAdministrator && !plan.requiresSystemInstaller else { updateActivity = "\(app.name) 更新已验证，需要确认授权安装"; return }
            guard !runningIDs.contains(app.bundleID) else { updateActivity = "\(app.name) 退出后将继续安装"; return }
            let installed = try await updateInstaller.install(plan)
            updateActivity = installed.message
            await refreshUpdateHistory(); loadApps()
        } catch { updateActivity = app.name + "：" + error.localizedDescription }
    }
    func resumePreparedUpdate(_ id: UUID) {
        guard !working && !preparingUpdate else { return }
        showUpdateHistory = false
        installTask = Task {
            do {
                preparedUpdate = try await updateInstaller.preparedUpdate(id)
                try? await Task.sleep(nanoseconds: 300_000_000)
                showUpdateReview = true
            } catch { notice = Notice(title: "更新预览不可用", message: error.localizedDescription) }
        }
    }
}
