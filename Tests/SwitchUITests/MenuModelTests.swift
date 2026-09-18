import SwitchCore
import SwitchUI
import XCTest

final class SwitchUITests: XCTestCase {
    private func profile(_ id: String, _ name: String, state: Profile.State = .registered) -> Profile {
        Profile(id: id, name: name, directoryName: "\(id)-dir", createdAt: Date(), state: state)
    }

    private func actions(_ model: MenuModel) -> [MenuAction] {
        model.items.flatMap { item -> [MenuAction] in
            switch item.kind {
            case .action(let action): return [action]
            case .submenu(let children): return children.compactMap { if case .action(let a) = $0.kind { return a } else { return nil } }
            default: return []
            }
        }
    }

    private func item(_ model: MenuModel, _ action: MenuAction) -> MenuItemModel? {
        for item in model.items {
            if case .action(let a) = item.kind, a == action { return item }
            if case .submenu(let children) = item.kind, let found = children.first(where: { if case .action(let a) = $0.kind { return a == action } else { return false } }) { return found }
        }
        return nil
    }

    func testManagedStateShowsProfilesWithCurrentChecked() {
        let manifest = Manifest(version: 1, profiles: [profile("a", "회사"), profile("b", "개인"), profile("c", "옛날", state: .archived)], currentProfileID: "a", backups: [])
        let status = ManagerStatus(manifest: manifest, layout: .managed(profileID: "a"), accountHint: "12345678", unknownDirectories: [], pendingJournal: nil, claudeRunning: true)
        let model = MenuModel.build(status: status, busy: nil, error: nil)

        XCTAssertEqual(model.statusBarTitle, "회사")
        XCTAssertEqual(model.items.first?.title, "현재 프로필: 회사")
        XCTAssertTrue(model.items[1].title.contains("12345678"))
        XCTAssertTrue(model.items[1].title.contains("프로필 이름과 별개"))
        let current = item(model, .switchTo(profileID: "a"))
        XCTAssertEqual(current?.checked, true)
        XCTAssertEqual(current?.enabled, false)
        XCTAssertEqual(item(model, .switchTo(profileID: "b"))?.enabled, true)
        XCTAssertEqual(item(model, .unregister(profileID: "a"))?.enabled, false, "현재 프로필은 등록 해제 불가")
        XCTAssertEqual(item(model, .unregister(profileID: "b"))?.enabled, true)
        XCTAssertEqual(item(model, .reregister(profileID: "c"))?.enabled, true)
        XCTAssertTrue(actions(model).contains(.restoreCurrent))
        XCTAssertFalse(actions(model).contains(.adoptExisting))
        XCTAssertTrue(actions(model).contains(.openClaude))
        XCTAssertTrue(actions(model).contains(.quitApp))
    }

    func testPlainDirectoryOffersAdoptOnly() {
        let status = ManagerStatus(manifest: .empty, layout: .plainDirectory, accountHint: nil, unknownDirectories: [], pendingJournal: nil, claudeRunning: false)
        let model = MenuModel.build(status: status, busy: nil, error: nil)
        XCTAssertEqual(model.statusBarTitle, "미등록")
        XCTAssertTrue(actions(model).contains(.adoptExisting))
        XCTAssertFalse(actions(model).contains(.restoreCurrent))
        XCTAssertEqual(item(model, .addProfile)?.enabled, false)
        XCTAssertEqual(item(model, .quitClaude)?.enabled, false)
        XCTAssertTrue(model.items[1].title.contains("Claude 앱 설정에서 확인"))
    }

    func testBusyDisablesMutatingActions() {
        let manifest = Manifest(version: 1, profiles: [profile("a", "A"), profile("b", "B")], currentProfileID: "a", backups: [])
        let status = ManagerStatus(manifest: manifest, layout: .managed(profileID: "a"), accountHint: nil, unknownDirectories: [], pendingJournal: nil, claudeRunning: true)
        let model = MenuModel.build(status: status, busy: "프로필 전환", error: nil)
        XCTAssertEqual(model.statusBarTitle, "작업 중")
        XCTAssertEqual(item(model, .switchTo(profileID: "b"))?.enabled, false)
        XCTAssertEqual(item(model, .addProfile)?.enabled, false)
        XCTAssertEqual(item(model, .quitApp)?.enabled, false)
        XCTAssertNil(item(model, .toggleMenuBarIcon).flatMap { $0.enabled ? nil : $0 })
        XCTAssertTrue(model.items.contains { $0.title == "작업 중: 프로필 전환" })
    }

    func testUnknownDirectoriesAndPendingJournalAreSurfaced() {
        let journal = Journal(kind: .adopt, step: "move", startedAt: Date(), profileID: "x", profileName: "x", directoryName: "x", previousProfileID: nil, backupPath: nil, retiredLinkPath: nil)
        let status = ManagerStatus(manifest: .empty, layout: .brokenLink(target: "/gone"), accountHint: nil, unknownDirectories: ["stray"], pendingJournal: journal, claudeRunning: false)
        let model = MenuModel.build(status: status, busy: nil, error: nil)
        XCTAssertEqual(model.statusBarTitle, "확인 필요")
        XCTAssertTrue(actions(model).contains(.importDirectory(name: "stray")))
        XCTAssertTrue(model.items.contains { $0.title.contains("미완료 작업") })
    }

    func testErrorStateStillOffersQuit() {
        let model = MenuModel.build(status: nil, busy: nil, error: "읽기 실패")
        XCTAssertEqual(model.statusBarTitle, "오류")
        XCTAssertTrue(actions(model).contains(.quitApp))
        XCTAssertTrue(model.items.contains { $0.title == "읽기 실패" })
    }

    func testLongProfileNameIsTruncatedInStatusBar() {
        let manifest = Manifest(version: 1, profiles: [profile("a", String(repeating: "가", count: 30))], currentProfileID: "a", backups: [])
        let status = ManagerStatus(manifest: manifest, layout: .managed(profileID: "a"), accountHint: nil, unknownDirectories: [], pendingJournal: nil, claudeRunning: false)
        let model = MenuModel.build(status: status, busy: nil, error: nil)
        XCTAssertEqual(model.statusBarTitle.count, MenuModel.maxStatusTitleLength + 1)
    }
}

final class MenuModelSettingsTests: XCTestCase {
    func testManagementOnlyMenuOmitsProfileRowsAndShowsSettings() {
        let profiles = [Profile(id: "a", name: "A", directoryName: "a", createdAt: Date(), state: .registered)]
        let manifest = Manifest(version: 1, profiles: profiles, currentProfileID: "a", backups: [])
        let status = ManagerStatus(manifest: manifest, layout: .managed(profileID: "a"), accountHint: nil, unknownDirectories: [], pendingJournal: nil, claudeRunning: false)
        let settings = LauncherSettings(showMenuBarIcon: false, launchAtLogin: true)
        let model = MenuModel.build(status: status, busy: nil, error: nil, settings: settings, includeProfiles: false)
        let titles = model.items.map(\.title)
        XCTAssertFalse(titles.contains("A"))
        XCTAssertFalse(titles.contains("프로필 선택 창 열기"))
        guard let settingsItem = model.items.first(where: { $0.title == "설정" }), case .submenu(let children) = settingsItem.kind else {
            return XCTFail("설정 하위 메뉴 없음")
        }
        XCTAssertEqual(children.map(\.checked), [false, true, true])
        let full = MenuModel.build(status: status, busy: nil, error: nil, settings: settings)
        XCTAssertTrue(full.items.map(\.title).contains("프로필 선택 창 열기"))
    }
}
