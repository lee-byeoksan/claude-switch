import SwitchCore
import SwitchUI
import XCTest

final class PanelModelTests: XCTestCase {
    private func status(running: Bool, layout: LiveLayout, journal: Journal? = nil) -> ManagerStatus {
        let profiles = [Profile(id: "b", name: "개인", directoryName: "b", createdAt: Date(), state: .registered),
                        Profile(id: "a", name: "회사", directoryName: "a", createdAt: Date(), state: .registered),
                        Profile(id: "c", name: "보관", directoryName: "c", createdAt: Date(), state: .archived)]
        let manifest = Manifest(version: 1, profiles: profiles, currentProfileID: "a", backups: [BackupRecord(path: "/b/1", createdAt: Date(), method: "clonefile", entryCount: 3, profileID: "a")])
        return ManagerStatus(manifest: manifest, layout: layout, accountHint: "abcdef12", unknownDirectories: ["stray"], pendingJournal: journal, claudeRunning: running)
    }

    func testCurrentIsFirstAndOnlyCurrentCarriesAccountHint() {
        let model = PanelModel.build(status: status(running: true, layout: .managed(profileID: "a")), busy: nil, error: nil)
        XCTAssertEqual(model.active.map(\.name), ["회사", "개인"], "현재 프로필이 항상 맨 위")
        XCTAssertEqual(model.inactive.map(\.name), ["보관"])
        XCTAssertEqual(model.active[0].isCurrent, true)
        XCTAssertEqual(model.active[0].accountHint, "abcdef12")
        XCTAssertNil(model.active[1].accountHint)
        XCTAssertEqual(model.active[0].backupPath, "/b/1")
        XCTAssertEqual(model.currentName, "회사")
    }

    func testCurrentCannotBeArchivedOrTrashedAndNotSwitchableWhileRunning() {
        let model = PanelModel.build(status: status(running: true, layout: .managed(profileID: "a")), busy: nil, error: nil)
        let current = model.active[0]
        XCTAssertFalse(current.canSwitch)
        XCTAssertFalse(current.canArchive)
        XCTAssertFalse(current.canTrash)
        XCTAssertTrue(current.canEdit)
        let other = model.active[1]
        XCTAssertTrue(other.canSwitch)
        XCTAssertTrue(other.canArchive)
        XCTAssertTrue(other.canTrash)
    }

    func testCurrentIsSwitchableWhenClaudeNotRunning() {
        let model = PanelModel.build(status: status(running: false, layout: .managed(profileID: "a")), busy: nil, error: nil)
        XCTAssertTrue(model.active[0].canSwitch, "미실행이면 현재 프로필을 눌러 바로 실행")
        XCTAssertTrue(model.canAdd)
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.unknownDirectories, ["stray"])
    }

    func testInactiveRowsOfferReactivateAndTrashOnly() {
        let model = PanelModel.build(status: status(running: false, layout: .managed(profileID: "a")), busy: nil, error: nil)
        let row = model.inactive[0]
        XCTAssertTrue(row.canReactivate)
        XCTAssertTrue(row.canTrash)
        XCTAssertFalse(row.canSwitch)
        XCTAssertFalse(row.canArchive)
    }

    func testBusyDisablesEverything() {
        let model = PanelModel.build(status: status(running: false, layout: .managed(profileID: "a")), busy: "전환", error: nil)
        XCTAssertTrue((model.active + model.inactive).allSatisfy { !$0.canSwitch && !$0.canEdit && !$0.canArchive && !$0.canTrash && !$0.canReactivate })
        XCTAssertFalse(model.canAdd)
        XCTAssertEqual(model.busyText, "전환")
    }

    func testNotices() {
        XCTAssertEqual(PanelModel.build(status: status(running: false, layout: .plainDirectory), busy: nil, error: nil).notice, .needsAdoption)
        XCTAssertEqual(PanelModel.build(status: status(running: false, layout: .brokenLink(target: "/x")), busy: nil, error: nil).notice, .layoutProblem("끊어진 링크: /x"))
        let journal = Journal(kind: .adopt, step: "move", startedAt: Date(), profileID: "x", profileName: "x", directoryName: "x", previousProfileID: nil, backupPath: nil, retiredLinkPath: nil)
        XCTAssertEqual(PanelModel.build(status: status(running: false, layout: .managed(profileID: "a"), journal: journal), busy: nil, error: nil).notice, .pendingJournal("adopt"))
        XCTAssertEqual(PanelModel.build(status: nil, busy: nil, error: "읽기 실패").errorText, "읽기 실패")
    }
}
