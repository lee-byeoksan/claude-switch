import SwitchCore
import Foundation

/// 메뉴에서 발생할 수 있는 동작. UI는 이 값만 AppDelegate로 넘긴다.
public enum MenuAction: Equatable {
    case switchTo(profileID: String)
    case addProfile
    case rename(profileID: String)
    case unregister(profileID: String)
    case reregister(profileID: String)
    case importDirectory(name: String)
    case adoptExisting
    case restoreCurrent
    case openClaude
    case quitClaude
    case openProfilesFolder
    case checkStatus
    case quitApp
    case showPanel
    case moveToTrash(profileID: String)
    case renameTo(profileID: String, name: String)
    case addProfileNamed(String)
    case toggleMenuBarIcon
    case toggleLaunchAtLogin
    case setServiceShortcut(String)
    case openStorage
    case refreshStorage
    case cleanCaches(profileID: String)
    case removeVMImages(profileID: String, includeCompressed: Bool)
    case propagateVMImages
    case trashBackup(path: String)
    case toggleAutoPropagate
    case relaunchApp
}

/// 런처 동작 설정. 저장은 앱이 담당한다.
public struct LauncherSettings: Equatable {
    public var showMenuBarIcon: Bool
    public var launchAtLogin: Bool
    /// 서비스 메뉴 단축키의 저장 형식("^@s"). 없으면 Info.plist 기본값(Cmd+Shift+S)이 쓰인다.
    public var serviceShortcut: String?
    /// 현재 프로필의 VM 이미지가 바뀌면 다른 프로필로 자동 전파한다.
    public var autoPropagateVMImages: Bool

    public init(showMenuBarIcon: Bool = true, launchAtLogin: Bool = false, serviceShortcut: String? = nil, autoPropagateVMImages: Bool = true) {
        self.showMenuBarIcon = showMenuBarIcon
        self.launchAtLogin = launchAtLogin
        self.serviceShortcut = serviceShortcut
        self.autoPropagateVMImages = autoPropagateVMImages
    }
}

public struct MenuItemModel: Equatable {
    public enum Kind: Equatable {
        case action(MenuAction)
        case separator
        case info
        case submenu([MenuItemModel])
    }

    public var title: String
    public var kind: Kind
    public var enabled: Bool
    public var checked: Bool

    public static func separator() -> MenuItemModel {
        MenuItemModel(title: "", kind: .separator, enabled: false, checked: false)
    }

    public static func info(_ title: String) -> MenuItemModel {
        MenuItemModel(title: title, kind: .info, enabled: false, checked: false)
    }

    public static func action(_ title: String, _ action: MenuAction, enabled: Bool = true, checked: Bool = false) -> MenuItemModel {
        MenuItemModel(title: title, kind: .action(action), enabled: enabled, checked: checked)
    }

    public static func submenu(_ title: String, _ items: [MenuItemModel], enabled: Bool = true) -> MenuItemModel {
        MenuItemModel(title: title, kind: .submenu(items), enabled: enabled, checked: false)
    }
}

/// 상태를 메뉴 구조로 바꾸는 순수 함수. 로직을 실행하지 않고도 테스트할 수 있다.
public struct MenuModel: Equatable {
    public var statusBarTitle: String
    public var items: [MenuItemModel]

    public static let maxStatusTitleLength = 14

    public static func build(status: ManagerStatus?, busy: String?, error: String?,
                             settings: LauncherSettings = LauncherSettings(), includeProfiles: Bool = true) -> MenuModel {
        guard let status else {
            return MenuModel(statusBarTitle: "오류", items: [
                .info("상태를 읽을 수 없습니다"),
                .info(error ?? "알 수 없는 오류"),
                .separator(),
                .action("상태 점검", .checkStatus),
                .action("계정 메뉴 종료", .quitApp),
            ])
        }

        let manifest = status.manifest
        let currentID: String? = {
            if case .managed(let id) = status.layout { return id }
            return nil
        }()
        let current = currentID.flatMap(manifest.profile(id:))
        let locked = busy != nil

        var items: [MenuItemModel] = []
        let registered = manifest.registered
        if includeProfiles {
            items.append(.info(headline(status: status, current: current)))
            if let hint = status.accountHint {
                items.append(.info("Claude 기록상 마지막 계정 ID: \(hint)… (프로필 이름과 별개)"))
            } else {
                items.append(.info("실제 로그인 계정은 Claude 앱 설정에서 확인하세요"))
            }
            if let busy {
                items.append(.info("작업 중: \(busy)"))
            }
            if let journal = status.pendingJournal {
                items.append(.info("미완료 작업 있음: \(journal.kind.rawValue). 상태 점검을 실행하세요"))
            }
            items.append(.separator())
            if registered.isEmpty {
                items.append(.info("등록된 프로필 없음"))
            }
            for profile in registered {
                let isCurrent = profile.id == currentID
                items.append(.action(profile.name, .switchTo(profileID: profile.id), enabled: !locked && !isCurrent && status.layout != .plainDirectory, checked: isCurrent))
            }
            items.append(.separator())
            items.append(.action("프로필 선택 창 열기", .showPanel))
        }

        let managed = currentID != nil
        items.append(.action("프로필 추가…", .addProfile, enabled: !locked && status.layout != .plainDirectory))
        items.append(.submenu("이름 변경", registered.map { .action($0.name, .rename(profileID: $0.id), enabled: !locked) }, enabled: !registered.isEmpty))
        items.append(.submenu("Inactive로 전환 (데이터 보관)", registered.map {
            .action($0.name, .unregister(profileID: $0.id), enabled: !locked && $0.id != currentID)
        }, enabled: !registered.isEmpty))
        let archived = manifest.archived
        items.append(.submenu("Inactive 프로필 다시 Active로", archived.map { .action($0.name, .reregister(profileID: $0.id), enabled: !locked) }, enabled: !archived.isEmpty))
        items.append(.submenu("휴지통으로 이동 (Removed)", manifest.profiles.map {
            .action($0.name, .moveToTrash(profileID: $0.id), enabled: !locked && $0.id != currentID)
        }, enabled: !manifest.profiles.isEmpty))
        if !status.unknownDirectories.isEmpty {
            items.append(.submenu("미등록 폴더 가져오기", status.unknownDirectories.map { .action($0, .importDirectory(name: $0), enabled: !locked) }))
        }
        items.append(.separator())

        items.append(.action("Claude 열기", .openClaude, enabled: !locked))
        items.append(.action("Claude 종료 요청", .quitClaude, enabled: !locked && status.claudeRunning))
        items.append(.separator())

        if status.layout == .plainDirectory {
            items.append(.action("기존 Claude 데이터를 첫 프로필로 등록…", .adoptExisting, enabled: !locked))
        }
        if managed {
            items.append(.action("현재 프로필을 일반 Claude 폴더로 되돌리기…", .restoreCurrent, enabled: !locked))
        }
        items.append(.action("용량 정리…", .openStorage, enabled: !locked))
        items.append(.action("프로필 폴더 열기", .openProfilesFolder))
        items.append(.action("상태 점검", .checkStatus, enabled: !locked))
        items.append(.separator())
        items.append(.submenu("설정", [
            .action("메뉴 막대 아이콘 표시", .toggleMenuBarIcon, checked: settings.showMenuBarIcon),
            .action("로그인 시 런처 실행", .toggleLaunchAtLogin, checked: settings.launchAtLogin),
            .action("VM 이미지 자동 복제", .toggleAutoPropagate, checked: settings.autoPropagateVMImages),
        ]))
        items.append(.action("Claude Switch 재실행", .relaunchApp, enabled: !locked))
        items.append(.action("Claude Switch 종료", .quitApp, enabled: !locked))

        return MenuModel(statusBarTitle: statusTitle(status: status, current: current, busy: busy), items: items)
    }

    static func headline(status: ManagerStatus, current: Profile?) -> String {
        switch status.layout {
        case .managed:
            return "현재 프로필: \(current?.name ?? "?")"
        case .plainDirectory:
            return "프로필 미등록 (Claude 기본 폴더 사용 중)"
        case .missing:
            return "Claude 데이터 폴더 없음 (프로필을 선택하면 연결)"
        case .brokenLink:
            return "연결 끊김: 프로필을 선택해 다시 연결하세요"
        case .linkedToUnknown, .other:
            return "확인 필요: \(status.layout.description)"
        }
    }

    static func statusTitle(status: ManagerStatus, current: Profile?, busy: String?) -> String {
        if busy != nil { return "작업 중" }
        switch status.layout {
        case .managed:
            let name = current?.name ?? "?"
            return name.count > maxStatusTitleLength ? String(name.prefix(maxStatusTitleLength)) + "…" : name
        case .plainDirectory:
            return "미등록"
        default:
            return "확인 필요"
        }
    }
}
