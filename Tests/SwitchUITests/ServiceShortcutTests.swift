import SwitchUI
import XCTest

final class ServiceShortcutTests: XCTestCase {
    func testParsesNamesAndGlyphs() {
        XCTAssertEqual(ServiceShortcut.parse("cmd+ctrl+s"), "^@s")
        XCTAssertEqual(ServiceShortcut.parse("Command + Control + S"), "^@s")
        XCTAssertEqual(ServiceShortcut.parse("⌘⌃S"), "^@s")
        XCTAssertEqual(ServiceShortcut.parse("cmd+shift+s"), "$@s")
        XCTAssertEqual(ServiceShortcut.parse("ctrl-opt-1"), "^~1")
    }

    func testRejectsInvalid() {
        XCTAssertNil(ServiceShortcut.parse("s"), "수식키 없음")
        XCTAssertNil(ServiceShortcut.parse("shift+s"), "Shift만으로는 단축키가 되지 않음")
        XCTAssertNil(ServiceShortcut.parse("cmd+"))
        XCTAssertNil(ServiceShortcut.parse("cmd+ab"))
    }

    func testDisplayRoundTrip() {
        XCTAssertEqual(ServiceShortcut.display("^@s"), "⌃⌘S")
        XCTAssertEqual(ServiceShortcut.display("$@s"), "⇧⌘S")
        XCTAssertEqual(ServiceShortcut.parse(ServiceShortcut.display("^~@k")), "^~@k")
    }
}
