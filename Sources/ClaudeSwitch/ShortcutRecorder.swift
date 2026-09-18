import AppKit
import SwiftUI
import SwitchUI

/// 키 입력을 직접 받아 단축키를 정하는 작은 상자. 클릭하면 녹화 상태가 되고 조합키+키를 누르면 끝난다. Esc는 취소.
struct ShortcutRecorder: NSViewRepresentable {
    var current: String?
    var onRecord: (String) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = onRecord
        view.current = current
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.current = current
        view.onRecord = onRecord
        view.needsDisplay = true
    }

    final class RecorderView: NSView {
        var current: String?
        var onRecord: ((String) -> Void)?
        private var recording = false { didSet { needsDisplay = true } }

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 26) }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            recording = true
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { return super.keyDown(with: event) }
            if event.keyCode == 53 { // Esc
                recording = false
                window?.makeFirstResponder(nil)
                return
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var parts: [String] = []
            if flags.contains(.control) { parts.append("ctrl") }
            if flags.contains(.option) { parts.append("opt") }
            if flags.contains(.shift) { parts.append("shift") }
            if flags.contains(.command) { parts.append("cmd") }
            guard let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1,
                  let character = key.first, character.isLetter || character.isNumber else {
                NSSound.beep()
                return
            }
            parts.append(key)
            guard let stored = ServiceShortcut.parse(parts.joined(separator: "+")) else {
                NSSound.beep() // Command, Control, Option 중 하나 이상이 필요
                return
            }
            recording = false
            window?.makeFirstResponder(nil)
            onRecord?(stored)
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            (recording ? NSColor(Theme.accent).withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (recording ? NSColor(Theme.accent) : NSColor.separatorColor).setStroke()
            path.stroke()
            let text = recording ? "키를 누르세요… (Esc 취소)" : (current.map(ServiceShortcut.display) ?? "⇧⌘S (기본)")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: recording ? NSColor(Theme.accent) : NSColor.labelColor,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        }
    }
}
