import Foundation

/// 프로필 등록·전환·복구의 실제 로직. UI에 의존하지 않으며 백그라운드 큐에서 호출된다.
public final class ProfileManager {
    public let paths: Paths
    public let store: Store
    public var quitTimeout: TimeInterval = 45
    public var pollInterval: TimeInterval = 0.5
    /// Claude.app 안에 있지만 Claude가 아니라 Chrome이 띄우는 프로세스. 데이터 폴더를 열지 않는다.
    public var excludedProcessNames: Set<String> = ["chrome-native-host"]

    let control: ClaudeAppControlling
    let scanner: ProcessScanning
    private let sleep: (TimeInterval) -> Void
    private let now: () -> Date
    let trash: (URL) throws -> URL?

    public init(paths: Paths,
                control: ClaudeAppControlling,
                scanner: ProcessScanning,
                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                now: @escaping () -> Date = Date.init,
                trash: @escaping (URL) throws -> URL? = ProfileManager.systemTrash) {
        self.paths = paths
        self.store = Store(paths: paths)
        self.control = control
        self.scanner = scanner
        self.sleep = sleep
        self.now = now
        self.trash = trash
    }

    /// macOS 휴지통으로 옮긴다. 영구 삭제가 아니므로 Finder에서 되돌릴 수 있다.
    public static func systemTrash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    // MARK: - 조회

    public func status() throws -> ManagerStatus {
        let manifest = try store.loadManifest()
        let layout = try LayoutInspector.inspect(paths: paths, manifest: manifest)
        return ManagerStatus(
            manifest: manifest,
            layout: layout,
            accountHint: AccountHint.read(paths: paths),
            unknownDirectories: LayoutInspector.unknownDirectories(paths: paths, manifest: manifest),
            pendingJournal: try store.loadJournal(),
            claudeRunning: control.isClaudeAppRunning() || !runningClaudeProcesses().isEmpty
        )
    }

    public func openClaude() throws {
        try control.launchClaude()
    }

    public func requestClaudeQuit() {
        control.requestClaudeQuit()
    }

    /// Claude를 정상 종료한 뒤 다시 실행한다. 종료가 확인되지 않으면 실행하지 않는다.
    public func restartClaude() throws {
        let lock = try OperationLock(url: paths.lockURL)
        _ = lock
        try ensureClaudeStopped()
        try control.launchClaude()
    }

    // MARK: - 기존 데이터를 첫 프로필로 등록

    @discardableResult
    public func adoptExistingData(name: String) throws -> Profile {
        let lock = try OperationLock(url: paths.lockURL)
        _ = lock
        let cleanName = try Self.validated(name: name)
        var manifest = try store.loadManifest()
        try ensureNoPendingJournal()
        let layout = try LayoutInspector.inspect(paths: paths, manifest: manifest)
        guard layout == .plainDirectory else {
            throw AccountError.unexpectedLayout("등록은 Claude 폴더가 일반 폴더일 때만 가능합니다. 현재: \(layout.description)")
        }
        guard manifest.currentProfileID == nil else {
            throw AccountError.inconsistentState("기록상 현재 프로필이 있는데 Claude 폴더가 일반 폴더입니다. 상태 점검을 실행하세요.")
        }
        guard try FileOps.isOwnedByCurrentUser(paths.liveLink) else { throw AccountError.notOwnedByUser(paths.liveLink.path) }

        try ensureClaudeStopped()
        try FileOps.ensurePrivateDirectory(paths.profilesRoot)
        try FileOps.ensurePrivateDirectory(paths.profilesDir)
        try FileOps.ensurePrivateDirectory(paths.backupsDir)

        let profile = Self.makeProfile(name: cleanName, now: now())
        let profileDir = paths.profileDir(profile)
        guard try FileOps.kind(profileDir) == .missing else { throw AccountError.directoryAlreadyExists(profileDir.path) }
        let backupURL = paths.backupsDir.appendingPathComponent("Claude-\(Self.stamp(now()))", isDirectory: true)

        var journal = Journal(kind: .adopt, step: "backup", startedAt: now(), profileID: profile.id, profileName: profile.name,
                              directoryName: profile.directoryName, previousProfileID: nil, backupPath: backupURL.path, retiredLinkPath: nil)
        try store.saveJournal(journal)
        store.appendLog("adopt: backup start -> \(backupURL.path)")

        let sourceEntries = try FileOps.topLevelEntries(paths.liveLink)
        let method = try FileOps.cloneDirectory(from: paths.liveLink, to: backupURL)
        try FileOps.tightenPermissions(backupURL)
        let backupEntries = try FileOps.topLevelEntries(backupURL)
        guard backupEntries == sourceEntries else {
            try store.clearJournal()
            throw AccountError.backupVerificationFailed("항목 수 원본 \(sourceEntries.count), 백업 \(backupEntries.count). 백업 폴더: \(backupURL.path)")
        }
        store.appendLog("adopt: backup done (\(method), \(backupEntries.count) entries)")

        journal.step = "move"
        try store.saveJournal(journal)
        try ensureClaudeStopped()
        try FileOps.moveNoClobber(from: paths.liveLink, to: profileDir)
        try FileOps.tightenPermissions(profileDir)
        store.appendLog("adopt: moved Claude -> \(profileDir.lastPathComponent)")

        journal.step = "link"
        try store.saveJournal(journal)
        do {
            try FileOps.replaceSymlink(at: paths.liveLink, target: profileDir, tempDir: paths.profilesRoot)
        } catch {
            store.appendLog("adopt: link failed, rolling back move: \(error)")
            try FileOps.moveNoClobber(from: profileDir, to: paths.liveLink)
            try store.clearJournal()
            throw error
        }

        manifest.update(profile)
        manifest.currentProfileID = profile.id
        manifest.backups.append(BackupRecord(path: backupURL.path, createdAt: now(), method: method, entryCount: backupEntries.count, profileID: profile.id))
        try store.saveManifest(manifest)
        try store.clearJournal()
        store.appendLog("adopt: complete profile=\(profile.id)")
        try control.launchClaude()
        return profile
    }

    // MARK: - 프로필 추가/이름 변경/등록 해제/재등록/가져오기

    @discardableResult
    public func addProfile(name: String) throws -> Profile {
        let lock = try OperationLock(url: paths.lockURL)
        _ = lock
        let cleanName = try Self.validated(name: name)
        var manifest = try store.loadManifest()
        try ensureNoPendingJournal()
        try FileOps.ensurePrivateDirectory(paths.profilesRoot)
        try FileOps.ensurePrivateDirectory(paths.profilesDir)
        let profile = Self.makeProfile(name: cleanName, now: now())
        let dir = paths.profileDir(profile)
        guard try FileOps.kind(dir) == .missing else { throw AccountError.directoryAlreadyExists(dir.path) }
        try FileOps.ensurePrivateDirectory(dir)
        manifest.update(profile)
        try store.saveManifest(manifest)
        store.appendLog("add: profile=\(profile.id) dir=\(profile.directoryName)")
        return profile
    }

    public func rename(profileID: String, newName: String) throws {
        let lock = try OperationLock(url: paths.lockURL)
        _ = lock
        let cleanName = try Self.validated(name: newName)
        var manifest = try store.loadManifest()
        guard var profile = manifest.profile(id: profileID) else { throw AccountError.profileNotFound }
        profile.name = cleanName
        manifest.update(profile)
        try store.saveManifest(manifest)
    }

    /// 메뉴에서만 제외한다. 데이터 폴더는 그대로 둔다.
    public func unregister(profileID: String) throws {
        let lock = try OperationLock(url: paths.lockURL)
        _ = lock
        var manifest = try store.loadManifest()
        guard var profile = manifest.profile(id: profileID), profile.state == .registered else { throw AccountError.profileNotFound }
        let layout = try LayoutInspector.inspect(paths: paths, manifest: manifest)
        if manifest.currentProfileID == profileID || layout == .managed(profileID: profileID) {
            throw AccountError.profileIsCurrent
        }
        profile.state = .archived
        manifest.update(profile)
        try store.saveManifest(manifest)
        store.appendLog("unregister: profile=\(profileID)")
    }

    public func reregister(profileID: String) throws {
        let lock = try OperationLock(url: paths.lockURL)
        _ = lock
        var manifest = try store.loadManifest()
        guard var profile = manifest.profile(id: profileID), profile.state == .archived else { throw AccountError.profileNotFound }
        guard try FileOps.kind(paths.profileDir(profile)) == .directory else {
            throw AccountError.profileDirectoryMissing(paths.profileDir(profile).path)
        }
        profile.state = .registered
        manifest.update(profile)
        try store.saveManifest(manifest)
        store.appendLog("reregister: profile=\(profileID)")
    }

    /// 프로필을 목록에서 제거하고 데이터 폴더를 휴지통으로 옮긴다. 현재 연결된 프로필은 거부한다. 백업 폴더는 건드리지 않는다.
    @discardableResult
    public func moveToTrash(profileID: String) throws -> URL? {
        let lock = try OperationLock(url: paths.lockURL)
        _ = lock
        var manifest = try store.loadManifest()
        try ensureNoPendingJournal()
        guard let profile = manifest.profile(id: profileID) else { throw AccountError.profileNotFound }
        let layout = try LayoutInspector.inspect(paths: paths, manifest: manifest)
        if manifest.currentProfileID == profileID || layout == .managed(profileID: profileID) {
            throw AccountError.profileIsCurrent
        }
        let dir = paths.profileDir(profile)
        var trashed: URL?
        switch try FileOps.kind(dir) {
        case .directory:
            trashed = try trash(dir)
        case .missing:
            break
        default:
            throw AccountError.unexpectedLayout("프로필 경로가 폴더가 아닙니다: \(dir.path)")
        }
        manifest.profiles.removeAll { $0.id == profileID }
        try store.saveManifest(manifest)
        store.appendLog("trash: profile=\(profileID) dir=\(profile.directoryName) -> \(trashed?.path ?? "(폴더 없음)")")
        return trashed
    }

    /// profiles 폴더에 있지만 manifest에 없는 폴더를 프로필로 등록한다. 폴더 내용은 건드리지 않는다.
    @discardableResult
    public func importDirectory(directoryName: String, name: String) throws -> Profile {
        let lock = try OperationLock(url: paths.lockURL)
        _ = lock
        let cleanName = try Self.validated(name: name)
        var manifest = try store.loadManifest()
        guard !manifest.profiles.contains(where: { $0.directoryName == directoryName }) else {
            throw AccountError.inconsistentState("이미 등록된 폴더입니다: \(directoryName)")
        }
        let dir = paths.profileDir(directoryName: directoryName)
        guard try FileOps.kind(dir) == .directory else { throw AccountError.profileDirectoryMissing(dir.path) }
        let profile = Profile(id: UUID().uuidString, name: cleanName, directoryName: directoryName, createdAt: now(), state: .registered)
        manifest.update(profile)
        try store.saveManifest(manifest)
        store.appendLog("import: dir=\(directoryName) profile=\(profile.id)")
        return profile
    }

    // MARK: - 전환

    /// `launchAfterSwitch`가 false면 링크만 바꾸고 Claude를 실행하지 않는다.
    public func switchTo(profileID: String, launchAfterSwitch: Bool = true) throws {
        let lock = try OperationLock(url: paths.lockURL)
        _ = lock
        var manifest = try store.loadManifest()
        try ensureNoPendingJournal()
        guard let target = manifest.profile(id: profileID), target.state == .registered else { throw AccountError.profileNotFound }
        let targetDir = paths.profileDir(target)
        guard try FileOps.kind(targetDir) == .directory else { throw AccountError.profileDirectoryMissing(targetDir.path) }

        let layout = try LayoutInspector.inspect(paths: paths, manifest: manifest)
        switch layout {
        case .managed(let currentID) where currentID == profileID:
            // 이미 연결된 프로필이면 기록만 맞추고, 요청이 있으면 Claude를 실행한다.
            if manifest.currentProfileID != profileID {
                manifest.currentProfileID = profileID
                try store.saveManifest(manifest)
            }
            if launchAfterSwitch && !control.isClaudeAppRunning() && runningClaudeProcesses().isEmpty {
                try control.launchClaude()
            }
            return
        case .managed, .brokenLink, .missing:
            break
        default:
            throw AccountError.unexpectedLayout("전환은 Claude 폴더가 프로필 링크일 때만 가능합니다. 현재: \(layout.description)")
        }

        try ensureClaudeStopped()

        let previousID: String? = {
            if case .managed(let id) = layout { return id }
            return nil
        }()
        let journal = Journal(kind: .switchProfile, step: "link", startedAt: now(), profileID: profileID, profileName: target.name,
                              directoryName: target.directoryName, previousProfileID: previousID, backupPath: nil, retiredLinkPath: nil)
        try store.saveJournal(journal)
        store.appendLog("switch: \(previousID ?? "-") -> \(profileID)")

        let swapTime = now()
        try FileOps.replaceSymlink(at: paths.liveLink, target: targetDir, tempDir: paths.profilesRoot) {
            let running = runningClaudeProcesses()
            if !running.isEmpty || control.isClaudeAppRunning() {
                try store.clearJournal()
                throw AccountError.raceDetected("링크 교체 직전에 Claude 프로세스가 감지됨")
            }
        }

        // 교체 직후 다시 확인한다. 교체 전에 시작된 프로세스가 있으면 이전 프로필에서 시작한 것이므로 되돌린다.
        let running = runningClaudeProcesses()
        let startedBeforeSwap = running.filter { ($0.startTime ?? .distantPast) < swapTime }
        if !startedBeforeSwap.isEmpty || (control.isClaudeAppRunning() && running.isEmpty) {
            if let previousID, let previous = manifest.profile(id: previousID) {
                try FileOps.replaceSymlink(at: paths.liveLink, target: paths.profileDir(previous), tempDir: paths.profilesRoot)
            }
            try store.clearJournal()
            store.appendLog("switch: race detected, rolled back")
            throw AccountError.raceDetected(startedBeforeSwap.map(\.name).joined(separator: ", "))
        }

        manifest.currentProfileID = profileID
        try store.saveManifest(manifest)
        try store.clearJournal()
        store.appendLog("switch: complete -> \(profileID) launch=\(launchAfterSwitch)")
        if running.isEmpty && launchAfterSwitch {
            try control.launchClaude()
        }
    }

    // MARK: - 일반 폴더로 되돌리기

    public func restoreCurrentToPlainFolder() throws {
        let lock = try OperationLock(url: paths.lockURL)
        _ = lock
        var manifest = try store.loadManifest()
        try ensureNoPendingJournal()
        let layout = try LayoutInspector.inspect(paths: paths, manifest: manifest)
        guard case .managed(let currentID) = layout, let profile = manifest.profile(id: currentID) else {
            throw AccountError.unexpectedLayout("되돌리기는 Claude 폴더가 프로필 링크일 때만 가능합니다. 현재: \(layout.description)")
        }
        let profileDir = paths.profileDir(profile)
        try ensureClaudeStopped()

        let retired = paths.profilesRoot.appendingPathComponent(".retired-link-\(Self.stamp(now()))", isDirectory: false)
        var journal = Journal(kind: .restore, step: "unlink", startedAt: now(), profileID: profile.id, profileName: profile.name,
                              directoryName: profile.directoryName, previousProfileID: nil, backupPath: nil, retiredLinkPath: retired.path)
        try store.saveJournal(journal)
        store.appendLog("restore: profile=\(profile.id)")

        try FileOps.moveNoClobber(from: paths.liveLink, to: retired)
        journal.step = "move"
        try store.saveJournal(journal)
        do {
            try FileOps.moveNoClobber(from: profileDir, to: paths.liveLink)
        } catch {
            try FileOps.moveNoClobber(from: retired, to: paths.liveLink)
            try store.clearJournal()
            store.appendLog("restore: move failed, link restored: \(error)")
            throw error
        }
        try FileOps.removeSymlinkOnly(retired)

        manifest.profiles.removeAll { $0.id == profile.id }
        manifest.currentProfileID = nil
        try store.saveManifest(manifest)
        try store.clearJournal()
        store.appendLog("restore: complete")
        try control.launchClaude()
    }

    // MARK: - 복구

    /// 완료되지 않은 journal이 있으면 실제 상태를 보고 마무리한다. 알 수 없는 폴더는 건드리지 않는다.
    public func recoverIfNeeded() throws -> RecoveryReport? {
        let lock = try OperationLock(url: paths.lockURL)
        _ = lock
        cleanupStaleTempLinks()
        guard let journal = try store.loadJournal() else { return nil }
        var manifest = try store.loadManifest()
        var notes: [String] = ["완료되지 않은 작업 발견: \(journal.kind.rawValue) (\(journal.step) 단계, \(journal.startedAt))"]
        let profileDir = paths.profileDir(directoryName: journal.directoryName)
        let liveKind = try FileOps.kind(paths.liveLink)
        let dirKind = try FileOps.kind(profileDir)

        func finishManifest(current: String?, add profile: Profile?) throws {
            if let profile { manifest.update(profile) }
            manifest.currentProfileID = current
            try store.saveManifest(manifest)
        }

        switch journal.kind {
        case .adopt:
            let profile = Profile(id: journal.profileID, name: journal.profileName, directoryName: journal.directoryName, createdAt: journal.startedAt, state: .registered)
            switch (liveKind, dirKind) {
            case (.directory, .missing):
                notes.append("데이터는 이동되지 않았습니다. 원본 Claude 폴더가 그대로 있습니다.")
                if let backup = journal.backupPath, (try? FileOps.kind(URL(fileURLWithPath: backup))) == .directory {
                    notes.append("불완전할 수 있는 백업 폴더가 남아 있습니다. 확인 후 직접 정리하세요: \(backup)")
                }
                try store.clearJournal()
            case (.missing, .directory):
                try FileOps.replaceSymlink(at: paths.liveLink, target: profileDir, tempDir: paths.profilesRoot)
                try finishManifest(current: profile.id, add: profile)
                if let backup = journal.backupPath {
                    manifest.backups.append(BackupRecord(path: backup, createdAt: journal.startedAt, method: "unknown", entryCount: 0, profileID: profile.id))
                    try store.saveManifest(manifest)
                }
                try store.clearJournal()
                notes.append("이동은 끝났지만 링크가 없어 링크를 다시 만들었습니다.")
            case (.symlink, .directory):
                try finishManifest(current: profile.id, add: profile)
                try store.clearJournal()
                notes.append("링크까지 완료된 상태라 기록만 마무리했습니다.")
            default:
                notes.append("자동으로 판단할 수 없는 상태입니다. 복구 안내 문서를 참고하세요. (Claude: \(liveKind), 프로필 폴더: \(dirKind))")
                return RecoveryReport(notes: notes, resolved: false)
            }
        case .switchProfile:
            switch liveKind {
            case .symlink:
                let layout = try LayoutInspector.inspect(paths: paths, manifest: manifest)
                if case .managed(let id) = layout {
                    try finishManifest(current: id, add: nil)
                    notes.append("현재 링크 대상에 맞춰 현재 프로필 기록을 갱신했습니다.")
                } else {
                    notes.append("링크가 등록된 프로필을 가리키지 않습니다: \(layout.description)")
                }
                try store.clearJournal()
            case .missing:
                if dirKind == .directory {
                    try FileOps.replaceSymlink(at: paths.liveLink, target: profileDir, tempDir: paths.profilesRoot)
                    try finishManifest(current: journal.profileID, add: nil)
                    notes.append("링크가 없어 대상 프로필로 다시 연결했습니다.")
                    try store.clearJournal()
                } else {
                    notes.append("링크도 프로필 폴더도 없습니다. 복구 안내 문서를 참고하세요.")
                    return RecoveryReport(notes: notes, resolved: false)
                }
            default:
                notes.append("Claude 경로가 링크가 아닙니다: \(liveKind). 기록만 정리합니다.")
                try store.clearJournal()
            }
        case .restore:
            let retired = journal.retiredLinkPath.map { URL(fileURLWithPath: $0) }
            switch (liveKind, dirKind) {
            case (.missing, .directory):
                try FileOps.moveNoClobber(from: profileDir, to: paths.liveLink)
                manifest.profiles.removeAll { $0.id == journal.profileID }
                try finishManifest(current: nil, add: nil)
                notes.append("프로필 폴더를 일반 Claude 폴더로 옮겨 되돌리기를 마무리했습니다.")
            case (.directory, .missing):
                manifest.profiles.removeAll { $0.id == journal.profileID }
                try finishManifest(current: nil, add: nil)
                notes.append("되돌리기는 이미 끝난 상태라 기록만 마무리했습니다.")
            case (.symlink, .directory):
                notes.append("되돌리기가 시작되기 전 상태입니다. 변경 없음.")
            default:
                notes.append("자동으로 판단할 수 없는 상태입니다. 복구 안내 문서를 참고하세요. (Claude: \(liveKind), 프로필 폴더: \(dirKind))")
                return RecoveryReport(notes: notes, resolved: false)
            }
            if let retired { try FileOps.removeSymlinkOnly(retired) }
            try store.clearJournal()
        }
        store.appendLog("recover: \(notes.joined(separator: " | "))")
        return RecoveryReport(notes: notes, resolved: true)
    }

    // MARK: - 내부

    private func ensureNoPendingJournal() throws {
        if let journal = try store.loadJournal() {
            throw AccountError.journalPending("\(journal.kind.rawValue)/\(journal.step)")
        }
    }

    private func cleanupStaleTempLinks() {
        guard let entries = try? FileOps.topLevelEntries(paths.profilesRoot) else { return }
        for name in entries where name.hasPrefix(".link-tmp-") {
            try? FileOps.removeSymlinkOnly(paths.profilesRoot.appendingPathComponent(name))
        }
    }

    private func dataPathPrefixes() -> [String] {
        var prefixes = [paths.liveLink.path]
        if let real = try? FileManager.default.destinationOfSymbolicLink(atPath: paths.liveLink.path) {
            prefixes.append(FileOps.resolveLinkTarget(real, relativeTo: paths.liveLink).path)
        }
        return prefixes
    }

    public func runningClaudeProcesses() -> [RunningProcess] {
        scanner.processes(underPaths: [paths.claudeAppURL.path] + dataPathPrefixes(), excludingNames: excludedProcessNames)
    }

    /// Claude에 정상 종료를 요청하고 관련 프로세스가 모두 사라질 때까지 기다린다. 강제 종료는 하지 않는다.
    private func ensureClaudeStopped() throws {
        var running = runningClaudeProcesses()
        if !running.isEmpty || control.isClaudeAppRunning() {
            control.requestClaudeQuit()
            let deadline = now().addingTimeInterval(quitTimeout)
            repeat {
                sleep(pollInterval)
                running = runningClaudeProcesses()
                if running.isEmpty && !control.isClaudeAppRunning() { break }
            } while now() < deadline
            if !running.isEmpty || control.isClaudeAppRunning() {
                throw AccountError.claudeStillRunning(running)
            }
        }
        let holders = scanner.processesHoldingFiles(underPaths: dataPathPrefixes(), excludingNames: excludedProcessNames)
        if !holders.isEmpty {
            throw AccountError.claudeStillRunning(holders)
        }
    }

    static func validated(name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40, !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.contains("\0") else {
            throw AccountError.invalidName
        }
        return trimmed
    }

    static func makeProfile(name: String, now: Date) -> Profile {
        let id = UUID().uuidString
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var slug = String(name.unicodeScalars.filter { allowed.contains($0) && $0.isASCII }).lowercased()
        if slug.isEmpty { slug = "profile" }
        let directoryName = "\(slug.prefix(24))-\(id.prefix(8).lowercased())"
        return Profile(id: id, name: name, directoryName: directoryName, createdAt: now, state: .registered)
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
