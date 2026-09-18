@testable import SwitchCore
import XCTest

final class StorageTests: XCTestCase {
    var sandbox: Sandbox!
    var manager: ProfileManager!

    override func setUpWithError() throws {
        sandbox = try Sandbox()
        manager = sandbox.makeManager()
    }

    override func tearDown() {
        sandbox.cleanup()
    }

    private func adopt() throws -> Profile {
        try sandbox.createLiveDirectory(files: ["marker.txt": "A"])
        return try manager.adoptExistingData(name: "A")
    }

    /// 실제 구성과 같은 이름으로 작은 VM 번들을 만든다.
    private func makeBundle(in profileDir: URL, marker: String, withCompressed: Bool = true, session: String = "session") throws -> URL {
        let bundle = VMBundle.bundleDir(profileDir: profileDir)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for image in VMBundle.imageNames {
            try "image-\(image)-\(marker)".write(to: bundle.appendingPathComponent(image), atomically: true, encoding: .utf8)
            try marker.write(to: bundle.appendingPathComponent(VMBundle.originName(image)), atomically: true, encoding: .utf8)
            if withCompressed {
                try "zst-\(image)-\(marker)".write(to: bundle.appendingPathComponent(VMBundle.compressedName(image)), atomically: true, encoding: .utf8)
                try marker.write(to: bundle.appendingPathComponent(VMBundle.compressedOriginName(image)), atomically: true, encoding: .utf8)
            }
        }
        try session.write(to: bundle.appendingPathComponent("sessiondata.img"), atomically: true, encoding: .utf8)
        try "id".write(to: bundle.appendingPathComponent("machineIdentifier"), atomically: true, encoding: .utf8)
        return bundle
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    func testPlanTargetsProfilesWithDifferentOrMissingMarkers() throws {
        let a = try adopt()
        let b = try manager.addProfile(name: "B")
        let c = try manager.addProfile(name: "C")
        let d = try manager.addProfile(name: "D")
        _ = try makeBundle(in: sandbox.paths.profileDir(a), marker: "sha-new")
        _ = try makeBundle(in: sandbox.paths.profileDir(b), marker: "sha-old")
        _ = try makeBundle(in: sandbox.paths.profileDir(c), marker: "sha-new")

        let plan = try XCTUnwrap(try manager.vmPropagationPlan())
        XCTAssertEqual(plan.sourceProfileID, a.id)
        XCTAssertEqual(plan.sourceMarker, "sha-new")
        XCTAssertEqual(Set(plan.targets.map(\.profileID)), [b.id, d.id], "같은 마커인 C는 제외, 번들 없는 D는 포함")
        XCTAssertEqual(plan.upToDate, [c.id])
        XCTAssertEqual(plan.targets.first { $0.profileID == b.id }?.currentMarker, "sha-old")
        XCTAssertEqual(plan.targets.first { $0.profileID == d.id }?.hasBundle, false)
    }

    func testSourceFallsBackToNewestBundleWhenCurrentHasNone() throws {
        let a = try adopt()
        let b = try manager.addProfile(name: "B")
        let c = try manager.addProfile(name: "C")
        _ = try makeBundle(in: sandbox.paths.profileDir(c), marker: "sha-old")
        let cMarker = VMBundle.bundleDir(profileDir: sandbox.paths.profileDir(c)).appendingPathComponent(VMBundle.originName("rootfs.img"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: cMarker.path)
        _ = try makeBundle(in: sandbox.paths.profileDir(b), marker: "sha-new")

        sandbox.control.running = true
        var plan = try XCTUnwrap(try manager.vmPropagationPlan())
        XCTAssertEqual(plan.sourceProfileID, b.id, "마커가 가장 최근인 번들이 원본")
        XCTAssertEqual(plan.targets.map(\.profileID), [c.id], "Claude 실행 중에는 현재 프로필(A)을 보류")
        XCTAssertEqual(plan.deferred.map(\.profileID), [a.id])

        sandbox.control.running = false
        plan = try XCTUnwrap(try manager.vmPropagationPlan())
        XCTAssertEqual(Set(plan.targets.map(\.profileID)), [a.id, c.id])
        let result = try manager.propagateVMImages()
        XCTAssertEqual(Set(result.updated), [a.id, c.id])
        XCTAssertEqual(VMBundle.marker(profileDir: sandbox.paths.profileDir(a)), "sha-new")
    }

    func testPlanIsNilWithoutCompleteSource() throws {
        let a = try adopt()
        _ = try manager.addProfile(name: "B")
        XCTAssertNil(try manager.vmPropagationPlan())
        let bundle = try makeBundle(in: sandbox.paths.profileDir(a), marker: "sha")
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("vmlinuz"))
        XCTAssertNil(try manager.vmPropagationPlan(), "이미지가 하나라도 없으면 원본이 아니다")
    }

    func testPropagateCopiesImagesAndMarkersButNotPrivateFiles() throws {
        let a = try adopt()
        let b = try manager.addProfile(name: "B")
        let d = try manager.addProfile(name: "D")
        _ = try makeBundle(in: sandbox.paths.profileDir(a), marker: "sha-new")
        let bBundle = try makeBundle(in: sandbox.paths.profileDir(b), marker: "sha-old", session: "b-session")
        try "stale".write(to: bBundle.appendingPathComponent("rootfs.img.partial"), atomically: true, encoding: .utf8)

        let result = try manager.propagateVMImages()
        XCTAssertEqual(Set(result.updated), [b.id, d.id])
        XCTAssertTrue(result.skipped.isEmpty)

        XCTAssertEqual(read(bBundle.appendingPathComponent("rootfs.img")), "image-rootfs.img-sha-new")
        XCTAssertEqual(read(bBundle.appendingPathComponent("rootfs.img.zst")), "zst-rootfs.img-sha-new")
        XCTAssertEqual(VMBundle.marker(profileDir: sandbox.paths.profileDir(b)), "sha-new")
        XCTAssertEqual(read(bBundle.appendingPathComponent("sessiondata.img")), "b-session", "세션 데이터는 보존")
        XCTAssertEqual(read(bBundle.appendingPathComponent("machineIdentifier")), "id")
        XCTAssertEqual(try FileOps.kind(bBundle.appendingPathComponent("rootfs.img.partial")), .missing)

        let dBundle = VMBundle.bundleDir(profileDir: sandbox.paths.profileDir(d))
        XCTAssertEqual(read(dBundle.appendingPathComponent("vmlinuz")), "image-vmlinuz-sha-new")
        XCTAssertEqual(try FileOps.kind(dBundle.appendingPathComponent("sessiondata.img")), .missing, "세션 파일은 만들지 않는다")
        XCTAssertEqual(try manager.vmPropagationPlan()?.targets, [], "전파 후에는 대상이 없다")

        // 원본을 바꿔도 대상은 영향을 받지 않는다 (clone).
        try "changed".write(to: VMBundle.bundleDir(profileDir: sandbox.paths.profileDir(a)).appendingPathComponent("rootfs.img"), atomically: true, encoding: .utf8)
        XCTAssertEqual(read(bBundle.appendingPathComponent("rootfs.img")), "image-rootfs.img-sha-new")
    }

    func testPropagateDefersWhileSourceFilesAreOpen() throws {
        let a = try adopt()
        let b = try manager.addProfile(name: "B")
        _ = try makeBundle(in: sandbox.paths.profileDir(a), marker: "sha-new")
        sandbox.scanner.holders = [RunningProcess(pid: 1, path: "/Applications/Claude.app/Contents/MacOS/Claude", startTime: nil)]
        let result = try manager.propagateVMImages()
        XCTAssertEqual(result.updated, [])
        XCTAssertNotNil(result.reason)
        XCTAssertEqual(try FileOps.kind(VMBundle.bundleDir(profileDir: sandbox.paths.profileDir(b))), .missing)
    }

    func testPropagateOnlyToSelectedProfiles() throws {
        let a = try adopt()
        let b = try manager.addProfile(name: "B")
        let c = try manager.addProfile(name: "C")
        _ = try makeBundle(in: sandbox.paths.profileDir(a), marker: "sha")
        let result = try manager.propagateVMImages(onlyTo: [b.id])
        XCTAssertEqual(result.updated, [b.id])
        XCTAssertEqual(try FileOps.kind(VMBundle.bundleDir(profileDir: sandbox.paths.profileDir(c))), .missing)
    }

    func testUsageCategorizesTopLevelEntries() throws {
        let a = try adopt()
        let dir = sandbox.paths.profileDir(a)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Cache"), withIntermediateDirectories: true)
        try String(repeating: "x", count: 5000).write(to: dir.appendingPathComponent("Cache/data"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("claude-code"), withIntermediateDirectories: true)
        try String(repeating: "y", count: 3000).write(to: dir.appendingPathComponent("claude-code/bin"), atomically: true, encoding: .utf8)
        _ = try makeBundle(in: dir, marker: "sha")

        let usage = try manager.computeUsage(profileID: a.id)
        XCTAssertGreaterThan(usage.caches, 0)
        XCTAssertGreaterThan(usage.claudeCode, 0)
        XCTAssertGreaterThan(usage.vmImages, 0)
        XCTAssertGreaterThan(usage.vmCompressed, 0)
        XCTAssertGreaterThan(usage.sessionData, 0)
        XCTAssertTrue(usage.hasVMBundle)
        XCTAssertEqual(usage.vmMarker, "sha")
        XCTAssertGreaterThanOrEqual(usage.total, usage.caches + usage.claudeCode + usage.vmImages + usage.vmCompressed + usage.sessionData)
    }

    func testCleanCachesRequiresClaudeOffForCurrentProfile() throws {
        let a = try adopt()
        let dir = sandbox.paths.profileDir(a)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Code Cache"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("Code Cache/f"), atomically: true, encoding: .utf8)
        sandbox.control.running = true
        XCTAssertThrowsError(try manager.cleanCaches(profileID: a.id)) { error in
            guard case AccountError.inUse = error else { return XCTFail("\(error)") }
        }
        sandbox.control.running = false
        _ = try manager.cleanCaches(profileID: a.id)
        XCTAssertEqual(try FileOps.kind(dir.appendingPathComponent("Code Cache")), .missing)
        XCTAssertEqual(sandbox.readLive("marker.txt"), "A", "다른 파일은 그대로")
    }

    func testRemoveVMImagesKeepsSessionAndCompressedByDefaultAndBlocksCurrent() throws {
        let a = try adopt()
        let b = try manager.addProfile(name: "B")
        _ = try makeBundle(in: sandbox.paths.profileDir(a), marker: "sha")
        let bBundle = try makeBundle(in: sandbox.paths.profileDir(b), marker: "sha")

        XCTAssertThrowsError(try manager.removeVMImages(profileID: a.id, includeCompressed: false)) { error in
            XCTAssertEqual(error as? AccountError, .profileIsCurrent)
        }
        _ = try manager.removeVMImages(profileID: b.id, includeCompressed: false)
        XCTAssertEqual(try FileOps.kind(bBundle.appendingPathComponent("rootfs.img")), .missing)
        XCTAssertEqual(try FileOps.kind(bBundle.appendingPathComponent(VMBundle.originName("rootfs.img"))), .missing)
        XCTAssertEqual(try FileOps.kind(bBundle.appendingPathComponent("rootfs.img.zst")), .file, "압축 캐시 보존")
        XCTAssertEqual(try FileOps.kind(bBundle.appendingPathComponent("sessiondata.img")), .file, "세션 보존")

        _ = try manager.removeVMImages(profileID: b.id, includeCompressed: true)
        XCTAssertEqual(try FileOps.kind(bBundle.appendingPathComponent("rootfs.img.zst")), .missing)
        XCTAssertEqual(try FileOps.kind(bBundle.appendingPathComponent("sessiondata.img")), .file)
    }

    func testTrashBackupOnlyForRecordedPaths() throws {
        _ = try adopt()
        let backup = try XCTUnwrap(try manager.status().manifest.backups.first)
        XCTAssertThrowsError(try manager.trashBackup(path: sandbox.root.appendingPathComponent("not-a-backup").path))
        try manager.trashBackup(path: backup.path)
        XCTAssertEqual(try FileOps.kind(URL(fileURLWithPath: backup.path)), .missing)
        XCTAssertEqual(try manager.status().manifest.backups, [])
    }
}

final class PhysicalUsageTests: XCTestCase {
    func testClonedFilesShareBlocks() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("phys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b"), c = root.appendingPathComponent("c")
        for dir in [a, b, c] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let payload = Data(repeating: 0x5A, count: 4 * 1024 * 1024)
        try payload.write(to: a.appendingPathComponent("big.bin"))
        try FileOps.cloneFile(from: a.appendingPathComponent("big.bin"), to: b.appendingPathComponent("big.bin"))
        try Data(repeating: 0x11, count: 4 * 1024 * 1024).write(to: c.appendingPathComponent("other.bin"))

        let usage = PhysicalUsageScanner.scan(roots: [("a", a), ("b", b), ("c", c)])
        let mb = Int64(4 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(usage.root("a")!.logical, mb)
        XCTAssertGreaterThanOrEqual(usage.root("b")!.logical, mb)
        XCTAssertLessThan(usage.root("a")!.exclusive, mb / 4, "clone 원본은 고유 블록이 거의 없다")
        XCTAssertLessThan(usage.root("b")!.exclusive, mb / 4)
        XCTAssertGreaterThanOrEqual(usage.root("c")!.exclusive, mb)
        XCTAssertLessThan(usage.union, mb * 3, "합집합은 공유 블록을 한 번만 센다")
        XCTAssertGreaterThanOrEqual(usage.union, mb * 2)
    }

    func testEmptyRootsProduceZero() {
        let usage = PhysicalUsageScanner.scan(roots: [("x", URL(fileURLWithPath: "/nonexistent/path"))])
        XCTAssertEqual(usage.union, 0)
        XCTAssertEqual(usage.root("x")?.exclusive, 0)
    }
}
