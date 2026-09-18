import Foundation

/// 용량 계산, 캐시·VM 이미지 정리, VM 이미지 복제.
extension ProfileManager {
    public func claudeIsRunning() -> Bool {
        control.isClaudeAppRunning() || !runningClaudeProcesses().isEmpty
    }

    // MARK: 용량

    public func computeUsage(profileID: String) throws -> ProfileUsage {
        let manifest = try store.loadManifest()
        guard let profile = manifest.profile(id: profileID) else { throw AccountError.profileNotFound }
        let dir = paths.profileDir(profile)
        var usage = ProfileUsage(profileID: profileID)
        guard try FileOps.kind(dir) == .directory else { return usage }
        for name in try FileOps.topLevelEntries(dir) {
            let item = dir.appendingPathComponent(name)
            let size = FileOps.allocatedSize(of: item)
            usage.total += size
            if ProfileUsage.cacheDirectoryNames.contains(name) {
                usage.caches += size
            } else if ProfileUsage.claudeCodeDirectoryNames.contains(name) {
                usage.claudeCode += size
            }
        }
        let bundle = VMBundle.bundleDir(profileDir: dir)
        if try FileOps.kind(bundle) == .directory {
            usage.hasVMBundle = true
            usage.vmMarker = VMBundle.marker(profileDir: dir)
            for image in VMBundle.imageNames {
                usage.vmImages += FileOps.allocatedSize(of: bundle.appendingPathComponent(image))
                usage.vmCompressed += FileOps.allocatedSize(of: bundle.appendingPathComponent(VMBundle.compressedName(image)))
            }
            usage.sessionData += FileOps.allocatedSize(of: bundle.appendingPathComponent("sessiondata.img"))
            usage.sessionData += FileOps.allocatedSize(of: bundle.appendingPathComponent("sessiondata.vhdx"))
        }
        return usage
    }

    // MARK: 정리

    /// Chromium 캐시 폴더 삭제. 현재 프로필은 Claude가 꺼져 있을 때만.
    @discardableResult
    public func cleanCaches(profileID: String) throws -> Int64 {
        let lock = try OperationLock(url: paths.lockURL)
        _ = lock
        let manifest = try store.loadManifest()
        guard let profile = manifest.profile(id: profileID) else { throw AccountError.profileNotFound }
        let layout = try LayoutInspector.inspect(paths: paths, manifest: manifest)
        if layout == .managed(profileID: profileID), claudeIsRunning() {
            throw AccountError.inUse("현재 프로필의 캐시는 Claude를 종료한 뒤 지울 수 있습니다.")
        }
        let dir = paths.profileDir(profile)
        var freed: Int64 = 0
        for name in ProfileUsage.cacheDirectoryNames {
            let item = dir.appendingPathComponent(name)
            guard try FileOps.kind(item) == .directory else { continue }
            freed += FileOps.allocatedSize(of: item)
            try FileOps.deleteItem(item)
        }
        store.appendLog("clean caches: profile=\(profileID) freed=\(freed)")
        return freed
    }

    /// VM 기본 이미지와 마커를 지운다. Claude 자체의 "재설치 파일 삭제"와 같은 범위이며 sessiondata는 보존한다.
    /// 현재 연결된 프로필은 거부한다. `includeCompressed`가 true면 압축 캐시도 지운다(다음 업데이트는 전체 다운로드).
    @discardableResult
    public func removeVMImages(profileID: String, includeCompressed: Bool) throws -> Int64 {
        let lock = try OperationLock(url: paths.lockURL)
        _ = lock
        let manifest = try store.loadManifest()
        guard let profile = manifest.profile(id: profileID) else { throw AccountError.profileNotFound }
        let layout = try LayoutInspector.inspect(paths: paths, manifest: manifest)
        if manifest.currentProfileID == profileID || layout == .managed(profileID: profileID) {
            throw AccountError.profileIsCurrent
        }
        let bundle = VMBundle.bundleDir(profileDir: paths.profileDir(profile))
        guard try FileOps.kind(bundle) == .directory else { return 0 }
        var names = VMBundle.imageNames + VMBundle.imageNames.map(VMBundle.originName)
        if includeCompressed {
            names += VMBundle.imageNames.map(VMBundle.compressedName) + VMBundle.imageNames.map(VMBundle.compressedOriginName)
        }
        var freed: Int64 = 0
        for name in names {
            let item = bundle.appendingPathComponent(name)
            guard try FileOps.kind(item) == .file else { continue }
            freed += FileOps.allocatedSize(of: item)
            try FileOps.deleteItem(item)
        }
        for name in try FileOps.topLevelEntries(bundle) where name.hasSuffix(".partial") || name.hasPrefix(".cs-tmp-") {
            try FileOps.deleteItem(bundle.appendingPathComponent(name))
        }
        store.appendLog("remove vm images: profile=\(profileID) compressed=\(includeCompressed) freed=\(freed)")
        return freed
    }

    /// manifest에 기록된 백업만 휴지통으로 옮긴다.
    public func trashBackup(path: String) throws {
        let lock = try OperationLock(url: paths.lockURL)
        _ = lock
        var manifest = try store.loadManifest()
        guard let index = manifest.backups.firstIndex(where: { $0.path == path }) else { throw AccountError.profileNotFound }
        let url = URL(fileURLWithPath: path)
        if try FileOps.kind(url) == .directory {
            _ = try trash(url)
        }
        manifest.backups.remove(at: index)
        try store.saveManifest(manifest)
        store.appendLog("trash backup: \(path)")
    }

    // MARK: VM 이미지 복제

    /// 원본은 현재 프로필에 완전한 번들이 있으면 그것, 없으면 마커 파일이 가장 최근에 바뀐 완전한 번들이다.
    /// 대상은 마커가 다르거나 번들이 없는 프로필이며, 현재 프로필은 Claude가 꺼져 있을 때만 대상에 넣는다.
    public func vmPropagationPlan() throws -> PropagationPlan? {
        let manifest = try store.loadManifest()
        let currentID: String? = {
            if case .managed(let id) = (try? LayoutInspector.inspect(paths: paths, manifest: manifest)) ?? .missing { return id }
            return nil
        }()
        let candidates = manifest.profiles.filter { VMBundle.isCompleteSource(profileDir: paths.profileDir($0)) && VMBundle.marker(profileDir: paths.profileDir($0)) != nil }
        guard !candidates.isEmpty else { return nil }
        let source: Profile
        if let currentID, let current = candidates.first(where: { $0.id == currentID }) {
            source = current
        } else {
            source = candidates.max { markerDate($0) < markerDate($1) }!
        }
        guard let marker = VMBundle.marker(profileDir: paths.profileDir(source)) else { return nil }
        let claudeRunning = claudeIsRunning()
        var targets: [PropagationPlan.Target] = []
        var deferred: [PropagationPlan.Target] = []
        var upToDate: [String] = []
        for profile in manifest.profiles where profile.id != source.id {
            let dir = paths.profileDir(profile)
            guard try FileOps.kind(dir) == .directory else { continue }
            let targetMarker = VMBundle.marker(profileDir: dir)
            let hasBundle = (try? FileOps.kind(VMBundle.bundleDir(profileDir: dir))) == .directory
            if targetMarker == marker && VMBundle.isCompleteSource(profileDir: dir) {
                upToDate.append(profile.id)
                continue
            }
            let target = PropagationPlan.Target(profileID: profile.id, currentMarker: targetMarker, hasBundle: hasBundle)
            if profile.id == currentID && claudeRunning {
                deferred.append(target)
            } else {
                targets.append(target)
            }
        }
        return PropagationPlan(sourceProfileID: source.id, sourceMarker: marker, targets: targets, deferred: deferred, upToDate: upToDate)
    }

    private func markerDate(_ profile: Profile) -> Date {
        let url = VMBundle.bundleDir(profileDir: paths.profileDir(profile)).appendingPathComponent(VMBundle.originName("rootfs.img"))
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }

    /// 계획된 대상에 이미지·압축 캐시·마커를 clone으로 복사한다. 원본 파일을 열고 있는 프로세스가 있으면 하지 않는다.
    public func propagateVMImages(onlyTo profileIDs: Set<String>? = nil) throws -> PropagationResult {
        let lock = try OperationLock(url: paths.lockURL)
        _ = lock
        var result = PropagationResult()
        guard let plan = try vmPropagationPlan() else {
            result.reason = "복제할 원본이 없습니다. 완전한 VM 이미지를 가진 프로필이 있어야 합니다."
            return result
        }
        let manifest = try store.loadManifest()
        guard let source = manifest.profile(id: plan.sourceProfileID) else { throw AccountError.profileNotFound }
        let sourceBundle = VMBundle.bundleDir(profileDir: paths.profileDir(source))
        let holders = scanner.processesHoldingFiles(underPaths: [sourceBundle.path], excludingNames: excludedProcessNames)
        if !holders.isEmpty {
            result.reason = "VM이 실행 중이라 미룹니다: " + holders.prefix(3).map(\.name).joined(separator: ", ")
            return result
        }
        for target in plan.targets {
            if let profileIDs, !profileIDs.contains(target.profileID) { continue }
            guard let profile = manifest.profile(id: target.profileID) else { continue }
            let targetBundle = VMBundle.bundleDir(profileDir: paths.profileDir(profile))
            do {
                try FileOps.ensurePrivateDirectory(targetBundle.deletingLastPathComponent())
                try FileOps.ensurePrivateDirectory(targetBundle)
                for name in VMBundle.propagatedNames {
                    let sourceFile = sourceBundle.appendingPathComponent(name)
                    let targetFile = targetBundle.appendingPathComponent(name)
                    guard try FileOps.kind(sourceFile) == .file else {
                        // 원본에 없는 파일(예: 압축 캐시)은 대상에서도 오래된 것을 지운다.
                        if try FileOps.kind(targetFile) == .file { try FileOps.deleteItem(targetFile) }
                        continue
                    }
                    try FileOps.cloneFileReplacing(from: sourceFile, to: targetFile)
                }
                for name in try FileOps.topLevelEntries(targetBundle) where name.hasSuffix(".partial") {
                    try FileOps.deleteItem(targetBundle.appendingPathComponent(name))
                }
                result.updated.append(target.profileID)
                store.appendLog("propagate: \(plan.sourceProfileID) -> \(target.profileID) marker=\(plan.sourceMarker.prefix(12))")
            } catch {
                result.skipped[target.profileID] = error.localizedDescription
                store.appendLog("propagate: \(target.profileID) skipped: \(error)")
            }
        }
        return result
    }
}

extension ProfileManager {
    /// 모든 프로필 폴더와 기록된 백업을 한 번에 스캔해 실제 점유를 계산한다. 수 초에서 수십 초가 걸리므로 백그라운드에서 호출한다.
    public func computePhysicalUsage() throws -> PhysicalUsage {
        let manifest = try store.loadManifest()
        var roots: [(id: String, url: URL)] = manifest.profiles.map { ($0.id, paths.profileDir($0)) }
        for backup in manifest.backups {
            roots.append((backup.path, URL(fileURLWithPath: backup.path)))
        }
        return PhysicalUsageScanner.scan(roots: roots)
    }
}
