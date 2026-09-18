import AppKit
import SwiftUI
import SwitchUI

/// 선택 창을 담는 NSPanel. 내용은 SwiftUI 뷰가 그린다.
final class ProfilePanelController: NSWindowController, NSWindowDelegate {
    let state = PanelState()
    private let onClose: () -> Void

    init(onAction: @escaping (MenuAction) -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "Claude Switch"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.level = .normal
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        super.init(window: panel)
        state.versionText = AppVersion.text
        panel.delegate = self
        let hosting = NSHostingView(rootView: ProfilePanelView(state: state, onAction: onAction))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting
        panel.backgroundColor = NSColor(Theme.background)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func render(_ model: PanelModel, settings: LauncherSettings) {
        state.model = model
        state.settings = settings
        if let hosting = window?.contentView as? NSHostingView<ProfilePanelView> {
            window?.setContentSize(hosting.fittingSize)
        }
    }

    func present() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose()
        return true
    }
}
