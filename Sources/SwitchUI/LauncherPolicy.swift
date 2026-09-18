import Foundation

/// 프로필 선택 창을 언제 보여 주고 숨길지 정하는 순수 상태 기계. AppKit에 의존하지 않는다.
public struct LauncherPolicy: Equatable {
    public enum Event: Equatable {
        case appStarted(claudeRunning: Bool)
        case claudeLaunched
        case reopenRequested
        case serviceInvoked
        case switchStarted
        case switchFinished
        case panelClosedByUser
    }

    public enum Effect: Equatable {
        case showPanel
        case hidePanel
    }

    public private(set) var switching = false
    public private(set) var panelVisible = false

    public init() {}

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .appStarted(let running):
            return running ? [] : show()
        case .claudeLaunched:
            return switching ? [] : hide()
        case .reopenRequested, .serviceInvoked:
            return show()
        case .switchStarted:
            switching = true
            return []
        case .switchFinished:
            switching = false
            return []
        case .panelClosedByUser:
            panelVisible = false
            return []
        }
    }

    private mutating func show() -> [Effect] {
        panelVisible = true
        return [.showPanel]
    }

    private mutating func hide() -> [Effect] {
        guard panelVisible else { return [] }
        panelVisible = false
        return [.hidePanel]
    }
}
