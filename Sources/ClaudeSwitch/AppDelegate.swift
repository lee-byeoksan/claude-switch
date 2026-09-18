import SwitchCore
import AppKit
import SwitchUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var manager: ProfileManager!
    private var builder: MenuBuilder!
    private var panel: ProfilePanelController!
    private var storage: StorageWindowController!
    private var usages: [ProfileUsage] = []
    private var physical: PhysicalUsage?
    private var storageLoading = false
    private var propagationTimer: Timer?
    private let propagationInterval: TimeInterval = 600
    private let settings = SettingsStore()
    private var policy = LauncherPolicy()
    private let queue = DispatchQueue(label: "claude-switch.operations")
    private var busy: String?
    private var lastError: String?
    private var testMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ensureSingleInstance() else { return }
        MainMenu.install()
        let environment = ProcessInfo.processInfo.environment
        let paths: Paths
        if let override = environment["CLAUDE_SWITCH_APP_SUPPORT_DIR"] {
            testMode = true
            paths = Paths(appSupportDir: URL(fileURLWithPath: override), claudeAppURL: URL(fileURLWithPath: "/Applications/Claude.app"))
            manager = ProfileManager(paths: paths, control: NoopClaudeControl(), scanner: NoopProcessScanner())
        } else {
            let standard = Paths.standard()
            let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Paths.claudeBundleIdentifier) ?? standard.claudeAppURL
            paths = Paths(appSupportDir: standard.appSupportDir, claudeAppURL: installed)
            manager = ProfileManager(paths: paths, control: WorkspaceClaudeControl(paths: paths), scanner: LibprocScanner())
        }
        builder = MenuBuilder { [weak self] action in self?.handle(action) }
        panel = ProfilePanelController(
            onAction: { [weak self] action in self?.handle(action) },
            onClose: { [weak self] in self?.apply(.panelClosedByUser) }
        )
        NSApp.servicesProvider = self
        storage = StorageWindowController { [weak self] action in self?.handle(action) }
        if !testMode { ServiceShortcutStore.ensureDefault() }
        observeClaude()
        schedulePropagation()
        updateStatusItemVisibility()
        runRecovery()
        refresh()
        let running = (try? manager.status())?.claudeRunning ?? false
        apply(.appStarted(claudeRunning: running))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        apply(.reopenRequested)
        return false
    }

    // MARK: - 서비스 메뉴 (Claude 메뉴 > 서비스 > Claude 프로필 전환…)

    @objc func switchProfile(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        apply(.serviceInvoked)
    }

    // MARK: - Claude 실행/종료 감시

    private func observeClaude() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard Self.isClaude(note) else { return }
            self?.apply(.claudeLaunched)
            self?.refresh()
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard Self.isClaude(note) else { return }
            self?.refresh()
            // Claude가 끝나면 VM도 멈추므로 미뤄 둔 복제를 시도하기 좋은 시점이다.
            self?.autoPropagateIfNeeded()
        }
    }

    // MARK: - VM 이미지 자동 복제

    private func schedulePropagation() {
        propagationTimer?.invalidate()
        propagationTimer = Timer.scheduledTimer(withTimeInterval: propagationInterval, repeats: true) { [weak self] _ in
            self?.autoPropagateIfNeeded()
        }
        autoPropagateIfNeeded()
    }

    /// 마커가 다른 프로필이 있고 원본이 사용 중이 아니면 조용히 복제한다. 실패는 로그에만 남긴다.
    private func autoPropagateIfNeeded() {
        guard settings.current.autoPropagateVMImages, busy == nil else { return }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard let plan = try self.manager.vmPropagationPlan(), !plan.targets.isEmpty else { return }
                let result = try self.manager.propagateVMImages()
                if !result.updated.isEmpty {
                    DispatchQueue.main.async { self.reloadStorage() }
                }
            } catch {
                self.manager.store.appendLog("auto propagate failed: \(error)")
            }
        }
    }

    // MARK: - 용량 정리 화면

    private func renderStorage() {
        let status = currentStatus()
        let plan = try? manager.vmPropagationPlan()
        storage.state.model = StorageModel.build(status: status, usages: usages, plan: plan, physical: physical, loading: storageLoading, busy: busy)
        storage.state.autoPropagate = settings.current.autoPropagateVMImages
        storage.resize()
    }

    private func reloadStorage() {
        guard let status = currentStatus() else { return }
        storageLoading = true
        physical = nil
        renderStorage()
        let ids = status.manifest.profiles.map(\.id)
        queue.async { [weak self] in
            guard let self else { return }
            let computed = ids.compactMap { try? self.manager.computeUsage(profileID: $0) }
            DispatchQueue.main.async {
                self.usages = computed
                self.renderStorage()
            }
            // 물리 블록 스캔은 더 오래 걸리므로 논리 크기를 먼저 보여 준 뒤 이어서 채운다.
            let physical = try? self.manager.computePhysicalUsage()
            DispatchQueue.main.async {
                self.physical = physical
                self.storageLoading = false
                self.renderStorage()
            }
        }
    }

    private static func isClaude(_ note: Notification) -> Bool {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier == Paths.claudeBundleIdentifier
    }

    private func apply(_ event: LauncherPolicy.Event) {
        for effect in policy.handle(event) {
            switch effect {
            case .showPanel:
                refresh()
                panel.present()
            case .hidePanel:
                panel.dismiss()
            }
        }
    }

    // MARK: - 화면 갱신

    private func currentStatus() -> ManagerStatus? {
        do {
            let status = try manager.status()
            lastError = nil
            return status
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func refresh() {
        let status = currentStatus()
        let model = MenuModel.build(status: status, busy: busy, error: lastError, settings: settings.current)
        if let statusItem {
            statusItem.button?.title = (testMode ? "[테스트] " : "") + model.statusBarTitle
            if let menu = statusItem.menu {
                let fresh = builder.makeMenu(model)
                let items = fresh.items
                fresh.removeAllItems()
                menu.removeAllItems()
                for item in items { menu.addItem(item) }
            }
        }
        panel.render(PanelModel.build(status: status, busy: busy, error: lastError), settings: settings.current)
        if storage?.window?.isVisible == true { renderStorage() }
    }

    private func updateStatusItemVisibility() {
        if settings.current.showMenuBarIcon {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "Claude 프로필")
            item.button?.imagePosition = .imageLeading
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - 동작 처리

    private func handle(_ action: MenuAction) {
        switch action {
        case .switchTo(let id):
            guard let profile = profile(id) else { return }
            let status = currentStatus()
            let running = status?.claudeRunning ?? false
            let isCurrent = status?.layout == .managed(profileID: id)
            var launch = true
            if isCurrent {
                guard !running else { return }
                guard Dialogs.confirm(title: "'\(profile.name)' 프로필로 Claude 실행",
                                      message: "이미 연결된 프로필입니다. Claude를 실행합니다.",
                                      confirmTitle: "실행") else { return }
                run("Claude 실행") { try self.manager.openClaude() } success: { nil }
                return
            }
            if running {
                guard Dialogs.confirm(title: "'\(profile.name)' 프로필로 전환",
                                      message: "Claude를 종료한 뒤 데이터 연결을 바꾸고 다시 실행합니다.\n\n" + Dialogs.coworkNotice,
                                      confirmTitle: "전환") else { return }
            } else {
                let choice = Dialogs.choose(title: "'\(profile.name)' 프로필로 전환",
                                            message: "Claude가 꺼져 있습니다.\n\n전환 후 실행: 데이터 연결을 바꾸고 Claude를 엽니다.\n전환만: 데이터 연결만 바꿉니다.",
                                            first: "전환 후 실행", second: "전환만")
                manager.store.appendLog("switch dialog: choice=\(choice)")
                switch choice {
                case .first: launch = true
                case .second: launch = false
                case .cancel: return
                }
            }
            apply(.switchStarted)
            run("프로필 전환", { try self.manager.switchTo(profileID: id, launchAfterSwitch: launch) }, success: { nil }, completion: { self.apply(.switchFinished) })
        case .addProfile:
            guard let name = Dialogs.askName(title: "새 프로필 추가", message: "빈 데이터 폴더가 만들어집니다. 전환하면 Claude 로그인 화면이 나타나며 직접 로그인하면 됩니다. VM 번들 등은 프로필별로 다시 내려받습니다.", initial: "") else { return }
            run("프로필 추가") {
                let profile = try self.manager.addProfile(name: name)
                DispatchQueue.main.async { self.offerSwitch(to: profile) }
            } success: { nil }
        case .addProfileNamed(let name):
            run("프로필 추가") {
                let profile = try self.manager.addProfile(name: name)
                DispatchQueue.main.async { self.offerSwitch(to: profile) }
            } success: { nil }
        case .renameTo(let id, let name):
            run("이름 변경") { try self.manager.rename(profileID: id, newName: name) } success: { nil }
        case .moveToTrash(let id):
            guard let profile = profile(id) else { return }
            guard Dialogs.confirm(title: "'\(profile.name)' 프로필을 제거 (Removed)",
                                  message: "프로필을 목록에서 제거하고 데이터 폴더를 macOS 휴지통으로 옮깁니다. 휴지통을 비우기 전까지는 Finder에서 되돌릴 수 있습니다. 백업 폴더는 그대로 둡니다.\n\n폴더: \(profile.directoryName)",
                                  confirmTitle: "휴지통으로 이동") else { return }
            run("프로필 제거") { try self.manager.moveToTrash(profileID: id) } success: { nil }
        case .rename(let id):
            guard let profile = profile(id), let name = Dialogs.askName(title: "프로필 이름 변경", message: "표시 이름만 바뀌고 데이터 폴더 이름은 유지됩니다.", initial: profile.name) else { return }
            run("이름 변경") { try self.manager.rename(profileID: id, newName: name) } success: { nil }
        case .unregister(let id):
            guard let profile = profile(id) else { return }
            _ = profile
            run("Inactive로 전환") { try self.manager.unregister(profileID: id) } success: { nil }
        case .reregister(let id):
            run("Active로 되돌리기") { try self.manager.reregister(profileID: id) } success: { nil }
        case .importDirectory(let dirName):
            guard let name = Dialogs.askName(title: "미등록 폴더 가져오기", message: "폴더 '\(dirName)'을 프로필로 등록합니다. 내용은 변경하지 않습니다.", initial: dirName) else { return }
            run("폴더 가져오기") { try self.manager.importDirectory(directoryName: dirName, name: name) } success: { nil }
        case .adoptExisting:
            guard let name = Dialogs.askName(title: "기존 Claude 데이터를 첫 프로필로 등록",
                                             message: "진행 순서: Claude 정상 종료 → 백업 복제 생성 → 데이터 폴더를 프로필 폴더로 이동 → 원래 경로에 링크 생성 → Claude 재실행.\n\n" + Dialogs.coworkNotice + "\n\n첫 프로필 이름을 입력하세요.",
                                             initial: "기본") else { return }
            apply(.switchStarted)
            run("첫 프로필 등록", { try self.manager.adoptExistingData(name: name) },
                success: { "등록을 완료했습니다. Claude를 실행합니다. 로그인이 유지되는지 확인하세요." },
                completion: { self.apply(.switchFinished) })
        case .restoreCurrent:
            guard Dialogs.confirm(title: "일반 Claude 폴더로 되돌리기",
                                  message: "현재 프로필의 데이터 폴더를 원래 경로로 옮기고 링크를 제거합니다. 다른 프로필은 보관 폴더에 남습니다.\n\n" + Dialogs.coworkNotice,
                                  confirmTitle: "되돌리기") else { return }
            apply(.switchStarted)
            run("되돌리기", { try self.manager.restoreCurrentToPlainFolder() },
                success: { "되돌리기를 완료했습니다. Claude를 실행합니다." },
                completion: { self.apply(.switchFinished) })
        case .openClaude:
            run("Claude 열기") { try self.manager.openClaude() } success: { nil }
        case .quitClaude:
            manager.requestClaudeQuit()
        case .openProfilesFolder:
            NSWorkspace.shared.activateFileViewerSelecting([manager.paths.profilesRoot])
        case .checkStatus:
            runRecovery()
            showStatus()
        case .showPanel:
            apply(.reopenRequested)
        case .toggleMenuBarIcon:
            settings.setShowMenuBarIcon(!settings.current.showMenuBarIcon)
            updateStatusItemVisibility()
            refresh()
        case .toggleLaunchAtLogin:
            do {
                try settings.setLaunchAtLogin(!settings.current.launchAtLogin)
            } catch {
                Dialogs.error(title: "로그인 항목 설정 실패", message: error.localizedDescription)
            }
            refresh()
        case .setServiceShortcut(let text):
            guard let stored = ServiceShortcut.parse(text) else {
                Dialogs.error(title: "단축키 형식 오류", message: "예: cmd+ctrl+s, ⌘⌃S. Command, Control, Option 중 하나 이상과 키 한 글자가 필요합니다.")
                return
            }
            do {
                try ServiceShortcutStore.write(stored)
                manager.store.appendLog("service shortcut: \(stored) (read back: \(ServiceShortcutStore.read() ?? "nil"))")
                refresh()
                let running = currentStatus()?.claudeRunning ?? false
                if running {
                    if Dialogs.confirm(title: "단축키 변경",
                                       message: "\(ServiceShortcut.display(stored))로 저장했습니다. 서비스 단축키는 Claude가 메뉴를 만들 때 읽으므로 실행 중인 Claude에는 재실행 후 반영됩니다. 지금 Claude를 재실행할까요?\n\n" + Dialogs.coworkNotice,
                                       confirmTitle: "Claude 재실행") {
                        run("Claude 재실행", { try self.manager.restartClaude() }, success: { nil })
                    }
                } else {
                    Dialogs.inform(title: "단축키 변경", message: "\(ServiceShortcut.display(stored))로 저장했습니다. 다음에 Claude를 실행하면 반영됩니다.")
                }
            } catch {
                Dialogs.error(title: "단축키 변경 실패", message: error.localizedDescription)
                refresh()
            }
        case .openStorage:
            storage.present()
            reloadStorage()
        case .refreshStorage:
            reloadStorage()
        case .toggleAutoPropagate:
            settings.setAutoPropagate(!settings.current.autoPropagateVMImages)
            refresh()
            renderStorage()
            autoPropagateIfNeeded()
        case .cleanCaches(let id):
            guard let profile = profile(id) else { return }
            run("캐시 삭제", { try self.manager.cleanCaches(profileID: id) }, success: { "'\(profile.name)' 프로필의 캐시를 지웠습니다. Claude가 다시 만듭니다." }, completion: { self.reloadStorage() })
        case .removeVMImages(let id, let includeCompressed):
            guard let profile = profile(id) else { return }
            let extra = includeCompressed ? "압축 캐시도 함께 지우므로 다음 업데이트는 전체 다운로드가 됩니다." : "압축 캐시는 남겨 두어 다음 업데이트를 delta로 받을 수 있습니다."
            guard Dialogs.confirm(title: "'\(profile.name)' 프로필의 VM 이미지 삭제",
                                  message: "rootfs, 커널, initrd와 해시 마커를 지웁니다. 세션 데이터(sessiondata.img)는 보존됩니다. 다음에 이 프로필에서 Cowork를 켜면 다시 내려받거나, 자동 복제가 켜져 있으면 다른 프로필에서 복사됩니다.\n\n\(extra)",
                                  confirmTitle: "삭제") else { return }
            run("VM 이미지 삭제", { try self.manager.removeVMImages(profileID: id, includeCompressed: includeCompressed) }, success: { nil }, completion: { self.reloadStorage() })
        case .propagateVMImages:
            run("VM 이미지 복제", {
                let result = try self.manager.propagateVMImages()
                if let reason = result.reason { throw AccountError.inUse(reason) }
                if !result.skipped.isEmpty {
                    throw AccountError.inconsistentState(result.skipped.map { "\($0.key.prefix(8)): \($0.value)" }.joined(separator: "\n"))
                }
            }, success: { "복제를 완료했습니다." }, completion: { self.reloadStorage() })
        case .trashBackup(let path):
            guard Dialogs.confirm(title: "백업을 휴지통으로 이동", message: "첫 등록 때 만든 백업 폴더를 휴지통으로 옮깁니다. 휴지통을 비우기 전까지는 되돌릴 수 있습니다.\n\n\(path)", confirmTitle: "휴지통으로 이동") else { return }
            run("백업 이동", { try self.manager.trashBackup(path: path) }, success: { nil }, completion: { self.reloadStorage() })
        case .relaunchApp:
            relaunch()
        case .quitApp:
            NSApp.terminate(nil)
        }
    }

    private func offerSwitch(to profile: Profile) {
        guard Dialogs.confirm(title: "'\(profile.name)' 프로필을 추가했습니다", message: "지금 이 프로필로 전환할까요? Claude가 실행 중이면 종료하고 다시 실행합니다.\n\n" + Dialogs.coworkNotice, confirmTitle: "지금 전환") else { return }
        apply(.switchStarted)
        run("프로필 전환", { try self.manager.switchTo(profileID: profile.id) },
            success: { "'\(profile.name)' 프로필로 전환했습니다. Claude 로그인 화면에서 직접 로그인하세요." },
            completion: { self.apply(.switchFinished) })
    }

    private func run(_ label: String, _ work: @escaping () throws -> Void, success: @escaping () -> String?, completion: @escaping () -> Void = {}) {
        busy = label
        refresh()
        queue.async {
            var failure: Error?
            do { try work() } catch { failure = error }
            DispatchQueue.main.async {
                self.busy = nil
                completion()
                self.refresh()
                if let failure {
                    Dialogs.error(title: "\(label) 실패", message: failure.localizedDescription)
                } else if let message = success() {
                    Dialogs.inform(title: "\(label) 완료", message: message)
                }
            }
        }
    }

    private func runRecovery() {
        do {
            if let report = try manager.recoverIfNeeded() {
                let title = report.resolved ? "이전 작업을 복구했습니다" : "수동 복구가 필요합니다"
                Dialogs.inform(title: title, message: report.notes.joined(separator: "\n"))
            }
        } catch {
            Dialogs.error(title: "복구 확인 실패", message: error.localizedDescription)
        }
    }

    private func showStatus() {
        do {
            let status = try manager.status()
            var lines = ["Claude 경로: \(manager.paths.liveLink.path)", "상태: \(status.layout.description)"]
            lines.append("등록 프로필: \(status.manifest.registered.count), 보관: \(status.manifest.archived.count)")
            if !status.unknownDirectories.isEmpty { lines.append("미등록 폴더: \(status.unknownDirectories.joined(separator: ", "))") }
            if let backup = status.manifest.backups.last { lines.append("최근 백업: \(backup.path)") }
            lines.append("Claude 실행 중: \(status.claudeRunning ? "예" : "아니오")")
            lines.append("로그인 시 실행: \(settings.current.launchAtLogin ? "켬" : "끔")")
            Dialogs.inform(title: "상태 점검", message: lines.joined(separator: "\n"))
        } catch {
            Dialogs.error(title: "상태 점검 실패", message: error.localizedDescription)
        }
    }

    private func profile(_ id: String) -> Profile? {
        currentStatus()?.manifest.profile(id: id)
    }

    static let showPanelNotification = Notification.Name("dev.claude-switch.show-panel")

    /// 이 프로세스가 끝난 뒤 같은 번들을 다시 여는 셸을 띄우고 종료한다.
    private func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; open \"\(bundlePath)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            Dialogs.error(title: "재실행 실패", message: error.localizedDescription)
        }
    }

    /// 이미 실행 중인 인스턴스가 있으면 그 인스턴스에 선택 창을 띄우라고 알리고 조용히 종료한다.
    private func ensureSingleInstance() -> Bool {
        let mine = Bundle.main.bundleIdentifier ?? ""
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: mine).filter { $0.processIdentifier != getpid() }
        if !mine.isEmpty, !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(Self.showPanelNotification, object: nil, userInfo: nil, deliverImmediately: true)
            others.first?.activate(options: [])
            NSApp.terminate(nil)
            return false
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.showPanelNotification, object: nil, queue: .main) { [weak self] _ in
            self?.apply(.reopenRequested)
        }
        return true
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        refresh()
    }
}
