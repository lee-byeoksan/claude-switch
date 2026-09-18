import Foundation

/// Claude 앱 실행 상태 확인, 정상 종료 요청, 실행. AppKit 의존 구현은 앱 타깃에 있다.
public protocol ClaudeAppControlling {
    func isClaudeAppRunning() -> Bool
    func requestClaudeQuit()
    func launchClaude() throws
}
