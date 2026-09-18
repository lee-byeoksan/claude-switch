import AppKit

/// NSAlert 래퍼. 반환값만 넘기고 로직은 갖지 않는다.
enum Dialogs {
    static func confirm(title: String, message: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    enum Choice { case first, second, cancel }

    /// 두 가지 선택과 취소를 제공한다.
    static func choose(title: String, message: String, first: String, second: String) -> Choice {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: first)
        alert.addButton(withTitle: second)
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .first
        case .alertSecondButtonReturn: return .second
        default: return .cancel
        }
    }

    static func inform(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func error(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "확인")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func askName(title: String, message: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    static let coworkNotice = "Cowork 작업이 진행 중인지 이 앱은 정확히 감지하지 못합니다. Claude 창에서 진행 중인 작업이 없는지 직접 확인한 뒤 계속하세요. Claude에 정상 종료를 요청하고, 종료가 확인되지 않으면 아무것도 바꾸지 않습니다."
}
