@testable import SwitchCore
import XCTest

final class ProfileManagerTests: XCTestCase {
    var sandbox: Sandbox!
    var manager: ProfileManager!

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        manager = sandbox.makeManager()
    }

    override func tearDown() {
        sandbox.cleanup()
    }

    private func adopt(name: String = "기본") throws -> Profile {
        try sandbox.createLiveDirectory(files: ["config.json": "{\"lastKnownAccountUuid\":\"aaaabbbb-1111-2222-3333-444455556666\"}", "marker.txt": "A"])
        return try manager.adoptExistingData(name: name)
    }

    private func permissions(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int
    }

    // MARK: 등록

    func testAdoptMovesDataCreatesBackupAndLink() throws {
        sandbox.control.running = true
        let profile = try adopt()
        let status = try manager.status()

        XCTAssertEqual(status.layout, .managed(profileID: profile.id))
        XCTAssertEqual(status.manifest.currentProfileID, profile.id)
        XCTAssertEqual(sandbox.readLive("marker.txt"), "A")
        XCTAssertEqual(status.accountHint, "aaaabbbb")
        XCTAssertEqual(sandbox.control.quitRequests, 1)
        XCTAssertEqual(sandbox.control.launches, 1)

        let backup = try XCTUnwrap(status.manifest.backups.first)
        XCTAssertEqual(try FileOps.topLevelEntries(URL(fileURLWithPath: backup.path)), ["Local Storage", "config.json", "marker.txt"])
        XCTAssertEqual(try permissions(sandbox.paths.profilesRoot), 0o700)
        XCTAssertEqual(try permissions(sandbox.paths.profileDir(profile)), 0o700)
        XCTAssertEqual(try permissions(URL(fileURLWithPath: backup.path)), 0o700)
        XCTAssertNil(try manager.store.loadJournal())
    }

    func testAdoptRefusedWhenAlreadyManaged() throws {
        _ = try adopt()
        XCTAssertThrowsError(try manager.adoptExistingData(name: "다시")) { error in
            guard case AccountError.unexpectedLayout = error else { return XCTFail("\(error)") }
        }
    }

    func testAdoptRefusedWhenClaudeWillNotQuit() throws {
        try sandbox.createLiveDirectory(files: ["marker.txt": "A"])
        sandbox.control.running = true
        sandbox.control.refuseToQuit = true
        XCTAssertThrowsError(try manager.adoptExistingData(name: "기본")) { error in
            guard case AccountError.claudeStillRunning = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try FileOps.kind(sandbox.paths.liveLink), .directory)
        XCTAssertEqual(try FileOps.kind(sandbox.paths.backupsDir), .missing)
    }

    // MARK: 전환과 데이터 분리

    func testSwitchBetweenProfilesKeepsDataSeparate() throws {
        let a = try adopt(name: "A")
        let b = try manager.addProfile(name: "B")
        XCTAssertEqual(try FileOps.kind(sandbox.paths.profileDir(b)), .directory)

        sandbox.control.running = true
        sandbox.control.pollsUntilQuit = 3
        try manager.switchTo(profileID: b.id)
        XCTAssertEqual(try manager.status().layout, .managed(profileID: b.id))
        XCTAssertNil(sandbox.readLive("marker.txt"))
        try sandbox.writeLive("marker.txt", "B")
        XCTAssertEqual(sandbox.control.launches, 2)

        try manager.switchTo(profileID: a.id)
        XCTAssertEqual(sandbox.readLive("marker.txt"), "A")
        XCTAssertEqual(try manager.status().manifest.currentProfileID, a.id)

        try manager.switchTo(profileID: b.id)
        XCTAssertEqual(sandbox.readLive("marker.txt"), "B")
        XCTAssertEqual(try String(contentsOf: sandbox.paths.profileDir(a).appendingPathComponent("marker.txt"), encoding: .utf8), "A")
    }

    func testSwitchToCurrentProfileLaunchesWhenClaudeIsOff() throws {
        let a = try adopt(name: "A")
        sandbox.control.running = false
        let before = sandbox.control.launches
        try manager.switchTo(profileID: a.id)
        XCTAssertEqual(sandbox.control.launches, before + 1)
        sandbox.control.running = true
        try manager.switchTo(profileID: a.id)
        XCTAssertEqual(sandbox.control.launches, before + 1, "실행 중이면 다시 실행하지 않는다")
    }

    func testSwitchWithoutLaunchOnlyRelinks() throws {
        _ = try adopt(name: "A")
        let b = try manager.addProfile(name: "B")
        let launchesBefore = sandbox.control.launches
        try manager.switchTo(profileID: b.id, launchAfterSwitch: false)
        XCTAssertEqual(try manager.status().layout, .managed(profileID: b.id))
        XCTAssertEqual(sandbox.control.launches, launchesBefore)
    }

    func testSwitchRefusedWhenProcessesRemain() throws {
        let a = try adopt(name: "A")
        let b = try manager.addProfile(name: "B")
        sandbox.scanner.processes = [RunningProcess(pid: 42, path: "/Applications/Claude.app/Contents/MacOS/Claude", startTime: nil)]
        XCTAssertThrowsError(try manager.switchTo(profileID: b.id)) { error in
            guard case AccountError.claudeStillRunning(let procs) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(procs.map(\.pid), [42])
        }
        XCTAssertEqual(try manager.status().layout, .managed(profileID: a.id))
        XCTAssertNil(try manager.store.loadJournal())
    }

    func testSwitchIgnoresExcludedProcessNames() throws {
        _ = try adopt(name: "A")
        let b = try manager.addProfile(name: "B")
        sandbox.scanner.processes = [RunningProcess(pid: 7, path: "/Applications/Claude.app/Contents/Helpers/chrome-native-host", startTime: nil)]
        try manager.switchTo(profileID: b.id)
        XCTAssertEqual(try manager.status().layout, .managed(profileID: b.id))
    }

    func testSwitchRefusedWhenFilesStillHeld() throws {
        _ = try adopt(name: "A")
        let b = try manager.addProfile(name: "B")
        sandbox.scanner.holders = [RunningProcess(pid: 99, path: "/usr/bin/node", startTime: nil)]
        XCTAssertThrowsError(try manager.switchTo(profileID: b.id))
        XCTAssertEqual(try manager.status().manifest.currentProfileID, try manager.status().manifest.registered.first?.id)
    }

    func testSwitchRollsBackWhenClaudeRelaunchesDuringSwap() throws {
        let a = try adopt(name: "A")
        let b = try manager.addProfile(name: "B")
        let scanner = sandbox.scanner
        let earlyStart = sandbox.clock.addingTimeInterval(-60)
        scanner.resetCount()
        scanner.afterScan = { count in
            // 첫 스캔(종료 확인)은 비어 있고, 링크 교체 직전 검사 이후에 프로세스가 나타난다.
            if count == 2 {
                scanner.processes = [RunningProcess(pid: 5, path: "/Applications/Claude.app/Contents/MacOS/Claude", startTime: earlyStart)]
            }
        }
        XCTAssertThrowsError(try manager.switchTo(profileID: b.id)) { error in
            guard case AccountError.raceDetected = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try manager.status().layout, .managed(profileID: a.id))
        XCTAssertEqual(try manager.status().manifest.currentProfileID, a.id)
        XCTAssertNil(try manager.store.loadJournal())
    }

    func testSwitchRefusedWhenLiveIsPlainDirectory() throws {
        try sandbox.createLiveDirectory(files: [:])
        let b = try manager.addProfile(name: "B")
        XCTAssertThrowsError(try manager.switchTo(profileID: b.id)) { error in
            guard case AccountError.unexpectedLayout = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try FileOps.kind(sandbox.paths.liveLink), .directory)
    }

    func testSwitchRelinksBrokenLink() throws {
        let a = try adopt(name: "A")
        let b = try manager.addProfile(name: "B")
        try FileOps.removeSymlinkOnly(sandbox.paths.liveLink)
        try FileManager.default.createSymbolicLink(atPath: sandbox.paths.liveLink.path, withDestinationPath: sandbox.root.appendingPathComponent("gone").path)
        guard case .brokenLink = try manager.status().layout else { return XCTFail("expected broken link") }
        try manager.switchTo(profileID: b.id)
        XCTAssertEqual(try manager.status().layout, .managed(profileID: b.id))
        _ = a
    }

    func testSwitchRefusedWhenLinkedToUnknownTarget() throws {
        _ = try adopt(name: "A")
        let b = try manager.addProfile(name: "B")
        let foreign = sandbox.root.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        try FileOps.removeSymlinkOnly(sandbox.paths.liveLink)
        try FileManager.default.createSymbolicLink(atPath: sandbox.paths.liveLink.path, withDestinationPath: foreign.path)
        XCTAssertThrowsError(try manager.switchTo(profileID: b.id))
        XCTAssertEqual(try FileOps.kind(sandbox.paths.liveLink), .symlink(target: foreign.path))
    }

    // MARK: 등록 해제, 재등록, 이름 변경, 가져오기

    func testUnregisterKeepsFolderAndBlocksCurrent() throws {
        let a = try adopt(name: "A")
        let b = try manager.addProfile(name: "B")
        XCTAssertThrowsError(try manager.unregister(profileID: a.id)) { error in
            XCTAssertEqual(error as? AccountError, .profileIsCurrent)
        }
        try manager.unregister(profileID: b.id)
        var status = try manager.status()
        XCTAssertEqual(status.manifest.archived.map(\.id), [b.id])
        XCTAssertEqual(try FileOps.kind(sandbox.paths.profileDir(b)), .directory)
        XCTAssertThrowsError(try manager.switchTo(profileID: b.id))

        try manager.reregister(profileID: b.id)
        status = try manager.status()
        XCTAssertEqual(status.manifest.registered.map(\.id), [a.id, b.id])
    }

    func testRenameChangesOnlyDisplayName() throws {
        let a = try adopt(name: "A")
        try manager.rename(profileID: a.id, newName: "회사")
        let renamed = try XCTUnwrap(try manager.status().manifest.profile(id: a.id))
        XCTAssertEqual(renamed.name, "회사")
        XCTAssertEqual(renamed.directoryName, a.directoryName)
        XCTAssertThrowsError(try manager.rename(profileID: a.id, newName: "  "))
        XCTAssertThrowsError(try manager.rename(profileID: a.id, newName: "a/b"))
    }

    func testUnknownDirectoryIsListedAndImportable() throws {
        _ = try adopt(name: "A")
        let stray = sandbox.paths.profileDir(directoryName: "stray-folder")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: false)
        try "x".write(to: stray.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try manager.status().unknownDirectories, ["stray-folder"])
        let imported = try manager.importDirectory(directoryName: "stray-folder", name: "가져온 프로필")
        XCTAssertEqual(imported.directoryName, "stray-folder")
        XCTAssertEqual(try manager.status().unknownDirectories, [])
        XCTAssertEqual(try String(contentsOf: stray.appendingPathComponent("keep.txt"), encoding: .utf8), "x")
    }

    func testMoveToTrashRemovesEntryAndMovesFolderButBlocksCurrent() throws {
        let a = try adopt(name: "A")
        let b = try manager.addProfile(name: "B")
        try "x".write(to: sandbox.paths.profileDir(b).appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try manager.moveToTrash(profileID: a.id)) { error in
            XCTAssertEqual(error as? AccountError, .profileIsCurrent)
        }
        let trashed = try XCTUnwrap(try manager.moveToTrash(profileID: b.id))
        XCTAssertEqual(try FileOps.kind(sandbox.paths.profileDir(b)), .missing)
        XCTAssertEqual(try String(contentsOf: trashed.appendingPathComponent("keep.txt"), encoding: .utf8), "x", "휴지통으로 이동만 하고 내용은 유지")
        XCTAssertNil(try manager.status().manifest.profile(id: b.id))
        XCTAssertEqual(try manager.status().manifest.backups.count, 1, "백업은 건드리지 않는다")
        XCTAssertEqual(try FileOps.kind(URL(fileURLWithPath: try XCTUnwrap(try manager.status().manifest.backups.first).path)), .directory)
    }

    func testMoveToTrashWorksForArchivedProfile() throws {
        _ = try adopt(name: "A")
        let b = try manager.addProfile(name: "B")
        try manager.unregister(profileID: b.id)
        XCTAssertNotNil(try manager.moveToTrash(profileID: b.id))
        XCTAssertEqual(try manager.status().manifest.archived, [])
    }

    // MARK: 되돌리기

    func testRestoreMovesCurrentProfileBackToPlainFolder() throws {
        let a = try adopt(name: "A")
        let b = try manager.addProfile(name: "B")
        sandbox.control.running = true
        try manager.restoreCurrentToPlainFolder()
        let status = try manager.status()
        XCTAssertEqual(status.layout, .plainDirectory)
        XCTAssertNil(status.manifest.currentProfileID)
        XCTAssertNil(status.manifest.profile(id: a.id))
        XCTAssertEqual(status.manifest.profile(id: b.id)?.state, .registered)
        XCTAssertEqual(sandbox.readLive("marker.txt"), "A")
        XCTAssertEqual(try FileOps.kind(sandbox.paths.profileDir(a)), .missing)
        XCTAssertFalse(try FileOps.topLevelEntries(sandbox.paths.profilesRoot).contains { $0.hasPrefix(".retired-link") })
        XCTAssertEqual(sandbox.control.launches, 2)
    }

    // MARK: 잠금과 복구

    func testLockPreventsConcurrentOperation() throws {
        _ = try adopt(name: "A")
        let lock = try OperationLock(url: sandbox.paths.lockURL)
        XCTAssertThrowsError(try manager.addProfile(name: "B")) { error in
            XCTAssertEqual(error as? AccountError, .locked)
        }
        _ = lock
    }

    func testPendingJournalBlocksOperations() throws {
        _ = try adopt(name: "A")
        let b = try manager.addProfile(name: "B")
        try manager.store.saveJournal(Journal(kind: .switchProfile, step: "link", startedAt: Date(), profileID: b.id, profileName: "B", directoryName: b.directoryName, previousProfileID: nil, backupPath: nil, retiredLinkPath: nil))
        XCTAssertThrowsError(try manager.switchTo(profileID: b.id)) { error in
            guard case AccountError.journalPending = error else { return XCTFail("\(error)") }
        }
    }

    func testRecoveryCompletesAdoptInterruptedBeforeLink() throws {
        // 상황: 백업과 이동까지 끝났고 링크를 만들기 전에 앱이 종료됨.
        try sandbox.createLiveDirectory(files: ["marker.txt": "A"])
        let profile = ProfileManager.makeProfile(name: "기본", now: Date())
        try FileOps.ensurePrivateDirectory(sandbox.paths.profilesRoot)
        try FileOps.ensurePrivateDirectory(sandbox.paths.profilesDir)
        try FileOps.moveNoClobber(from: sandbox.paths.liveLink, to: sandbox.paths.profileDir(profile))
        try manager.store.saveJournal(Journal(kind: .adopt, step: "link", startedAt: Date(), profileID: profile.id, profileName: profile.name, directoryName: profile.directoryName, previousProfileID: nil, backupPath: nil, retiredLinkPath: nil))

        let report = try XCTUnwrap(try manager.recoverIfNeeded())
        XCTAssertTrue(report.resolved)
        let status = try manager.status()
        XCTAssertEqual(status.layout, .managed(profileID: profile.id))
        XCTAssertEqual(status.manifest.currentProfileID, profile.id)
        XCTAssertEqual(sandbox.readLive("marker.txt"), "A")
        XCTAssertNil(try manager.store.loadJournal())
    }

    func testRecoveryLeavesUntouchedAdoptAndReportsPartialBackup() throws {
        try sandbox.createLiveDirectory(files: ["marker.txt": "A"])
        try FileOps.ensurePrivateDirectory(sandbox.paths.profilesRoot)
        try FileOps.ensurePrivateDirectory(sandbox.paths.backupsDir)
        let partial = sandbox.paths.backupsDir.appendingPathComponent("Claude-partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false)
        try manager.store.saveJournal(Journal(kind: .adopt, step: "backup", startedAt: Date(), profileID: "x", profileName: "기본", directoryName: "profile-x", previousProfileID: nil, backupPath: partial.path, retiredLinkPath: nil))

        let report = try XCTUnwrap(try manager.recoverIfNeeded())
        XCTAssertTrue(report.resolved)
        XCTAssertTrue(report.notes.contains { $0.contains(partial.path) })
        XCTAssertEqual(try FileOps.kind(partial), .directory, "불완전 백업은 삭제하지 않는다")
        XCTAssertEqual(try FileOps.kind(sandbox.paths.liveLink), .directory)
    }

    func testRecoverySyncsManifestAfterInterruptedSwitch() throws {
        let a = try adopt(name: "A")
        let b = try manager.addProfile(name: "B")
        // 링크는 B로 바뀌었지만 manifest 갱신 전에 종료된 상황.
        try FileOps.replaceSymlink(at: sandbox.paths.liveLink, target: sandbox.paths.profileDir(b), tempDir: sandbox.paths.profilesRoot)
        try manager.store.saveJournal(Journal(kind: .switchProfile, step: "link", startedAt: Date(), profileID: b.id, profileName: "B", directoryName: b.directoryName, previousProfileID: a.id, backupPath: nil, retiredLinkPath: nil))
        try FileManager.default.createSymbolicLink(atPath: sandbox.paths.profilesRoot.appendingPathComponent(".link-tmp-stale").path, withDestinationPath: "/nonexistent")

        let report = try XCTUnwrap(try manager.recoverIfNeeded())
        XCTAssertTrue(report.resolved)
        XCTAssertEqual(try manager.status().manifest.currentProfileID, b.id)
        XCTAssertFalse(try FileOps.topLevelEntries(sandbox.paths.profilesRoot).contains(".link-tmp-stale"))
    }

    func testRecoveryCompletesInterruptedRestore() throws {
        let a = try adopt(name: "A")
        let retired = sandbox.paths.profilesRoot.appendingPathComponent(".retired-link-test")
        try FileOps.moveNoClobber(from: sandbox.paths.liveLink, to: retired)
        try manager.store.saveJournal(Journal(kind: .restore, step: "move", startedAt: Date(), profileID: a.id, profileName: "A", directoryName: a.directoryName, previousProfileID: nil, backupPath: nil, retiredLinkPath: retired.path))

        let report = try XCTUnwrap(try manager.recoverIfNeeded())
        XCTAssertTrue(report.resolved)
        XCTAssertEqual(try manager.status().layout, .plainDirectory)
        XCTAssertEqual(sandbox.readLive("marker.txt"), "A")
        XCTAssertEqual(try FileOps.kind(retired), .missing)
        XCTAssertNil(try manager.status().manifest.profile(id: a.id))
    }

    func testNoRecoveryWhenNothingPending() throws {
        _ = try adopt(name: "A")
        XCTAssertNil(try manager.recoverIfNeeded())
    }

    // MARK: 파일 조작 안전성

    func testReplaceSymlinkNeverOverwritesRealDirectory() throws {
        try sandbox.createLiveDirectory(files: ["marker.txt": "A"])
        try FileOps.ensurePrivateDirectory(sandbox.paths.profilesRoot)
        XCTAssertThrowsError(try FileOps.replaceSymlink(at: sandbox.paths.liveLink, target: sandbox.root, tempDir: sandbox.paths.profilesRoot))
        XCTAssertEqual(try FileOps.kind(sandbox.paths.liveLink), .directory)
        XCTAssertFalse(try FileOps.topLevelEntries(sandbox.paths.profilesRoot).contains { $0.hasPrefix(".link-tmp-") }, "임시 링크가 남지 않아야 한다")
    }

    func testMoveNoClobberRefusesExistingDestination() throws {
        try sandbox.createLiveDirectory(files: [:])
        let other = sandbox.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        XCTAssertThrowsError(try FileOps.moveNoClobber(from: sandbox.paths.liveLink, to: other)) { error in
            guard case AccountError.directoryAlreadyExists = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try FileOps.kind(sandbox.paths.liveLink), .directory)
    }

    func testCloneDirectoryProducesIndependentCopy() throws {
        try sandbox.createLiveDirectory(files: ["marker.txt": "A"])
        let copy = sandbox.root.appendingPathComponent("copy")
        let method = try FileOps.cloneDirectory(from: sandbox.paths.liveLink, to: copy)
        XCTAssertTrue(["clonefile", "copyfile"].contains(method))
        try sandbox.writeLive("marker.txt", "changed")
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent("marker.txt"), encoding: .utf8), "A")
    }

    func testAccountHintIgnoresMissingOrMalformedConfig() throws {
        try sandbox.createLiveDirectory(files: ["config.json": "not json"])
        XCTAssertNil(AccountHint.read(paths: sandbox.paths))
    }
}
