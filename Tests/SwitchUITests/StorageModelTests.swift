import SwitchCore
import SwitchUI
import XCTest

final class StorageModelTests: XCTestCase {
    private func status(running: Bool) -> ManagerStatus {
        let profiles = [Profile(id: "a", name: "회사", directoryName: "a", createdAt: Date(), state: .registered),
                        Profile(id: "b", name: "개인", directoryName: "b", createdAt: Date(), state: .registered),
                        Profile(id: "c", name: "보관", directoryName: "c", createdAt: Date(), state: .archived)]
        let manifest = Manifest(version: 1, profiles: profiles, currentProfileID: "a",
                                backups: [BackupRecord(path: "/backups/1", createdAt: Date(), method: "clonefile", entryCount: 3, profileID: "a")])
        return ManagerStatus(manifest: manifest, layout: .managed(profileID: "a"), accountHint: nil, unknownDirectories: [], pendingJournal: nil, claudeRunning: running)
    }

    private func usage(_ id: String, caches: Int64, vm: Int64) -> ProfileUsage {
        var usage = ProfileUsage(profileID: id)
        usage.total = caches + vm + 100
        usage.caches = caches
        usage.vmImages = vm
        usage.hasVMBundle = vm > 0
        return usage
    }

    func testRowsOrderFlagsAndTotals() {
        let plan = PropagationPlan(sourceProfileID: "a", sourceMarker: "abcdef123456789", targets: [.init(profileID: "c", currentMarker: nil, hasBundle: false)], deferred: [], upToDate: ["b"])
        let model = StorageModel.build(status: status(running: true), usages: [usage("a", caches: 500, vm: 1000), usage("b", caches: 0, vm: 800), usage("c", caches: 50, vm: 0)], plan: plan, loading: false, busy: nil)
        XCTAssertEqual(model.rows.map(\.name), ["회사", "개인", "보관"], "현재, Active, Inactive 순")
        let current = model.rows[0]
        XCTAssertFalse(current.canCleanCaches, "Claude 실행 중에는 현재 프로필 캐시를 지우지 않는다")
        XCTAssertFalse(current.canRemoveVMImages)
        XCTAssertFalse(model.rows[1].canCleanCaches, "캐시가 없으면 비활성")
        XCTAssertTrue(model.rows[1].canRemoveVMImages)
        XCTAssertTrue(model.rows[2].canCleanCaches)
        XCTAssertTrue(model.rows[2].needsPropagation)
        XCTAssertFalse(model.rows[1].needsPropagation)
        XCTAssertEqual(model.totalBytes, 1600 + 900 + 150)
        XCTAssertEqual(model.propagationSource, "회사")
        XCTAssertEqual(model.propagationTargets, ["보관"])
        XCTAssertEqual(model.propagationUpToDate, ["개인"])
        XCTAssertTrue(model.propagationNote.contains("회사 프로필의 VM 이미지"))
        XCTAssertEqual(model.backups.first?.profileName, "회사")
    }

    func testCurrentCachesCleanableWhenClaudeOffAndBusyDisablesAll() {
        let off = StorageModel.build(status: status(running: false), usages: [usage("a", caches: 5, vm: 0)], plan: nil, loading: false, busy: nil)
        XCTAssertTrue(off.rows[0].canCleanCaches)
        XCTAssertTrue(off.propagationNote.contains("복제할 원본이 없습니다"))
        let busy = StorageModel.build(status: status(running: false), usages: [usage("a", caches: 5, vm: 0), usage("b", caches: 5, vm: 5)], plan: nil, loading: false, busy: "정리")
        XCTAssertTrue(busy.rows.allSatisfy { !$0.canCleanCaches && !$0.canRemoveVMImages })
    }

    func testPhysicalUsageIsAttached() {
        let physical = PhysicalUsage(roots: [PhysicalUsage.Root(id: "a", logical: 1000, exclusive: 300), PhysicalUsage.Root(id: "/backups/1", logical: 900, exclusive: 50)], union: 1200)
        let model = StorageModel.build(status: status(running: false), usages: [usage("a", caches: 0, vm: 900)], plan: nil, physical: physical, loading: false, busy: nil)
        XCTAssertEqual(model.rows.first { $0.profileID == "a" }?.exclusive, 300)
        XCTAssertNil(model.rows.first { $0.profileID == "b" }?.exclusive)
        XCTAssertEqual(model.physicalTotal, 1200)
        XCTAssertEqual(model.backupExclusive["/backups/1"], 50)
    }

    func testFormat() {
        XCTAssertEqual(StorageModel.format(0), "-")
        XCTAssertFalse(StorageModel.format(10_000_000_000).isEmpty)
    }
}
