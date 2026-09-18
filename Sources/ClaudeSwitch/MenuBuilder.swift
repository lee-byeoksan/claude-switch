import AppKit
import SwitchUI

/// MenuModel을 NSMenu로 옮기는 UI 코드. 상태 판단은 하지 않는다.
final class MenuBuilder {
    private let handler: (MenuAction) -> Void

    init(handler: @escaping (MenuAction) -> Void) {
        self.handler = handler
    }

    func makeMenu(_ model: MenuModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in model.items {
            menu.addItem(makeItem(item))
        }
        return menu
    }

    private func makeItem(_ model: MenuItemModel) -> NSMenuItem {
        switch model.kind {
        case .separator:
            return .separator()
        case .info:
            let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .action(let action):
            let item = NSMenuItem(title: model.title, action: #selector(ActionTarget.invokeMenuAction(_:)), keyEquivalent: "")
            let target = ActionTarget(action: action, handler: handler)
            item.target = target
            item.representedObject = target
            item.isEnabled = model.enabled
            item.state = model.checked ? .on : .off
            return item
        case .submenu(let children):
            let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            item.isEnabled = model.enabled
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            if children.isEmpty {
                let empty = NSMenuItem(title: "없음", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                submenu.addItem(empty)
            }
            for child in children { submenu.addItem(makeItem(child)) }
            item.submenu = submenu
            return item
        }
    }
}

final class ActionTarget: NSObject {
    let action: MenuAction
    let handler: (MenuAction) -> Void

    init(action: MenuAction, handler: @escaping (MenuAction) -> Void) {
        self.action = action
        self.handler = handler
    }

    @objc func invokeMenuAction(_ sender: Any?) {
        handler(action)
    }
}
