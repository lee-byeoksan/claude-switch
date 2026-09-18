import Foundation

/// 서비스 메뉴 단축키 표기 변환. macOS는 "@^s"처럼 수식키 기호와 소문자 키로 저장한다.
/// @ = Command, ^ = Control, ~ = Option, $ = Shift
public enum ServiceShortcut {
    static let modifierOrder: [(symbol: Character, names: [String], glyph: String)] = [
        ("^", ["ctrl", "control", "⌃"], "⌃"),
        ("~", ["opt", "option", "alt", "⌥"], "⌥"),
        ("$", ["shift", "⇧"], "⇧"),
        ("@", ["cmd", "command", "⌘"], "⌘"),
    ]

    /// "cmd+ctrl+s", "⌘⌃S" 같은 입력을 저장 형식("@^s")으로 바꾼다. 수식키가 없거나 키가 한 글자가 아니면 nil.
    public static func parse(_ text: String) -> String? {
        var modifiers = Set<Character>()
        var key: Character?
        let tokens = text.lowercased()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: " ", with: "")
            .split(separator: "+")
            .map(String.init)
        var remaining: [String] = []
        for token in tokens {
            if let modifier = modifierOrder.first(where: { $0.names.contains(token) }) {
                modifiers.insert(modifier.symbol)
            } else {
                remaining.append(token)
            }
        }
        // "⌘⌃s"처럼 기호가 붙어 있는 입력도 허용한다.
        for token in remaining {
            for character in token {
                if let modifier = modifierOrder.first(where: { $0.names.contains(String(character)) }) {
                    modifiers.insert(modifier.symbol)
                } else if key == nil, character.isLetter || character.isNumber {
                    key = character
                } else {
                    return nil
                }
            }
        }
        guard let key, modifiers.contains("@") || modifiers.contains("^") || modifiers.contains("~") else { return nil }
        let prefix = modifierOrder.filter { modifiers.contains($0.symbol) }.map { String($0.symbol) }.joined()
        return prefix + String(key)
    }

    /// 저장 형식을 사람이 읽는 표기("⌘⌃S")로 바꾼다.
    public static func display(_ stored: String) -> String {
        var glyphs = ""
        var key = ""
        for character in stored {
            if let modifier = modifierOrder.first(where: { $0.symbol == character }) {
                glyphs += modifier.glyph
            } else {
                key += String(character).uppercased()
            }
        }
        return glyphs + key
    }
}
