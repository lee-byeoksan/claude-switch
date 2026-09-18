import SwiftUI
import SwitchUI

/// 선택 창의 SwiftUI 뷰. 상태는 PanelState로 받고 판단은 하지 않으며 동작은 MenuAction으로 넘긴다.
final class PanelState: ObservableObject {
    @Published var model = PanelModel.build(status: nil, busy: nil, error: nil)
    @Published var settings = LauncherSettings()
    var versionText = ""
}

struct ProfilePanelView: View {
    @ObservedObject var state: PanelState
    let onAction: (MenuAction) -> Void

    @State private var tab: PanelModel.Tab = .active
    @State private var editingID: String?
    @State private var editingText = ""
    @State private var addingName: String?
    @State private var infoID: String?
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let notice = state.model.notice { noticeView(notice) }
            if let error = state.model.errorText { Text(error).foregroundColor(Theme.accent).font(.callout) }
            tabs
            rows
            footer
        }
        .padding(16)
        .frame(width: 420)
        .background(Theme.background)
        .foregroundColor(Theme.text)
    }

    // MARK: 머리글

    private var header: some View {
        HStack(alignment: .center) {
            Text("Claude Switch").font(Theme.titleFont)
            Circle().fill(state.model.claudeRunning ? Color.green : Theme.divider).frame(width: 8, height: 8)
            Text(state.model.claudeRunning ? "Claude 실행 중" : "Claude 꺼짐").font(.caption).foregroundColor(Theme.secondaryText)
            Spacer()
            if let busy = state.model.busyText {
                ProgressView().controlSize(.small)
                Text(busy).font(.caption).foregroundColor(Theme.secondaryText)
            }
            iconButton("gearshape", help: "설정") { showSettings.toggle() }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { settingsPopover }
        }
    }

    private func noticeView(_ notice: PanelModel.Notice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundColor(Theme.accent)
            switch notice {
            case .needsAdoption:
                Text("프로필 미등록. 기존 Claude 데이터를 첫 프로필로 등록하세요.").font(.callout)
                Spacer()
                Button("등록…") { onAction(.adoptExisting) }.tint(Theme.accent)
            case .layoutProblem(let text):
                Text("확인 필요: \(text)").font(.callout)
                Spacer()
                Button("상태 점검") { onAction(.checkStatus) }
            case .pendingJournal(let kind):
                Text("미완료 작업(\(kind))이 있습니다.").font(.callout)
                Spacer()
                Button("복구") { onAction(.checkStatus) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
    }

    // MARK: 탭과 목록

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(PanelModel.Tab.allCases, id: \.self) { candidate in
                let count = candidate == .active ? state.model.active.count : state.model.inactive.count
                HoverHighlight(enabled: tab != candidate) {
                    Button {
                        tab = candidate
                        editingID = nil
                    } label: {
                        Text("\(candidate.rawValue) \(count)")
                            .font(.callout.weight(tab == candidate ? .semibold : .regular))
                            .padding(.vertical, 5).padding(.horizontal, 12)
                            .background(RoundedRectangle(cornerRadius: 6).fill(tab == candidate ? Theme.accent.opacity(0.18) : .clear))
                            .foregroundColor(tab == candidate ? Theme.accent : Theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
    }

    private var rows: some View {
        let list = tab == .active ? state.model.active : state.model.inactive
        return VStack(spacing: 0) {
            if list.isEmpty {
                Text(tab == .active ? "Active 프로필이 없습니다" : "Inactive 프로필이 없습니다")
                    .font(.callout).foregroundColor(Theme.secondaryText).padding(12)
            }
            ForEach(list) { row in
                rowView(row)
                if row.id != list.last?.id { Divider().overlay(Theme.divider) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }

    private func rowView(_ row: PanelModel.Row) -> some View {
        HStack(spacing: 8) {
            if tab == .active {
                let mark = Image(systemName: row.isCurrent ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(row.isCurrent ? Theme.accent : Theme.secondaryText)
                if row.canSwitch {
                    Button { onAction(.switchTo(profileID: row.profileID)) } label: { mark }
                        .buttonStyle(.plain)
                        .help(row.isCurrent ? "현재 프로필로 Claude 실행" : "이 프로필로 전환")
                } else {
                    // 전환할 수 없는 상태라도 현재 표시는 흐려지지 않게 버튼 대신 아이콘만 둔다.
                    mark.help(row.isCurrent ? "현재 프로필" : "지금은 전환할 수 없습니다")
                }
            } else {
                Image(systemName: "archivebox").foregroundColor(Theme.secondaryText)
            }

            if editingID == row.profileID {
                TextField("프로필 이름", text: $editingText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(row) }
                    .onExitCommand { editingID = nil }
            } else {
                Text(row.name)
                    .font(row.isCurrent ? .body.weight(.bold) : .body)
                    .foregroundColor(tab == .inactive ? Theme.secondaryText : Theme.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)

            iconButton("info.circle", help: "자세히") { infoID = row.profileID }
                .popover(isPresented: Binding(get: { infoID == row.profileID }, set: { if !$0 { infoID = nil } }), arrowEdge: .bottom) { infoPopover(row) }
            if row.canEdit {
                iconButton(editingID == row.profileID ? "checkmark" : "pencil", help: "이름 변경") {
                    if editingID == row.profileID { commitRename(row) } else { editingID = row.profileID; editingText = row.name }
                }
            }
            if tab == .active {
                iconButton("archivebox", help: "Inactive로 전환 (데이터 보관)") { onAction(.unregister(profileID: row.profileID)) }
                    .disabled(!row.canArchive)
            } else {
                iconButton("arrow.uturn.backward.circle", help: "Active로 되돌리기") { onAction(.reregister(profileID: row.profileID)) }
                    .disabled(!row.canReactivate)
            }
            iconButton("trash", help: "휴지통으로 이동 (Removed)") { onAction(.moveToTrash(profileID: row.profileID)) }
                .disabled(!row.canTrash)
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
    }

    private func commitRename(_ row: PanelModel.Row) {
        let name = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingID = nil
        if !name.isEmpty, name != row.name { onAction(.renameTo(profileID: row.profileID, name: name)) }
    }

    private func infoPopover(_ row: PanelModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.name).font(.headline)
            infoLine("상태", row.isCurrent ? "현재 연결됨" : (tab == .active ? "Active" : "Inactive"))
            infoLine("폴더", row.directoryName)
            infoLine("만든 날짜", row.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let hint = row.accountHint {
                infoLine("계정 ID 힌트", "\(hint)…")
                Text("Claude가 기록한 마지막 계정 UUID 앞부분입니다. 프로필 이름과 별개이며 실제 계정은 Claude 설정에서 확인하세요.")
                    .font(.caption).foregroundColor(Theme.secondaryText)
            }
            if let backup = row.backupPath { infoLine("백업", backup) }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }

    private func infoLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundColor(Theme.secondaryText).frame(width: 72, alignment: .leading)
            Text(value).font(.caption).textSelection(.enabled)
        }
    }

    // MARK: 바닥글

    private var footer: some View {
        HStack {
            if let name = addingName {
                TextField("새 프로필 이름", text: Binding(get: { name }, set: { addingName = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit { commitAdd() }
                    .onExitCommand { addingName = nil }
                Button("추가") { commitAdd() }.tint(Theme.accent)
                Button("취소") { addingName = nil }
            } else {
                Button { addingName = "" } label: { Label("새 프로필", systemImage: "plus") }
                    .disabled(!state.model.canAdd)
            }
            Spacer()
            if !state.model.unknownDirectories.isEmpty {
                Menu("미등록 폴더 \(state.model.unknownDirectories.count)") {
                    ForEach(state.model.unknownDirectories, id: \.self) { name in
                        Button(name) { onAction(.importDirectory(name: name)) }
                    }
                }
                .frame(width: 130)
            }
        }
    }

    private func commitAdd() {
        let name = (addingName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        addingName = nil
        if !name.isEmpty { onAction(.addProfileNamed(name)) }
    }

    // MARK: 설정

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("설정").font(.headline)
            Toggle("메뉴 막대 아이콘 표시", isOn: Binding(get: { state.settings.showMenuBarIcon }, set: { _ in onAction(.toggleMenuBarIcon) }))
            Toggle("로그인 시 Claude Switch 실행", isOn: Binding(get: { state.settings.launchAtLogin }, set: { _ in onAction(.toggleLaunchAtLogin) }))
            Divider()
            Text("서비스 메뉴 단축키").font(.subheadline).foregroundColor(Theme.secondaryText)
            HStack(spacing: 8) {
                ShortcutRecorder(current: state.settings.serviceShortcut) { stored in onAction(.setServiceShortcut(ServiceShortcut.display(stored))) }
                    .fixedSize()
                Text("상자를 누르고 원하는 조합을 누르세요").font(.caption).foregroundColor(Theme.secondaryText)
            }
            Divider()
            Text("고급").font(.subheadline).foregroundColor(Theme.secondaryText)
            settingsRow("arrow.uturn.left", "현재 프로필을 일반 Claude 폴더로 되돌리기…") { showSettings = false; onAction(.restoreCurrent) }
            settingsRow("stethoscope", "상태 점검") { showSettings = false; onAction(.checkStatus) }
            settingsRow("internaldrive", "용량 정리…") { showSettings = false; onAction(.openStorage) }
            settingsRow("folder", "프로필 폴더 열기") { onAction(.openProfilesFolder) }
            settingsRow("power", "Claude 종료 요청", enabled: state.model.claudeRunning) { onAction(.quitClaude) }
            Divider()
            settingsRow("arrow.clockwise.circle", "Claude Switch 재실행") { onAction(.relaunchApp) }
            settingsRow("xmark.circle", "Claude Switch 종료") { onAction(.quitApp) }
            Text("Claude Switch \(state.versionText)").font(.caption).foregroundColor(Theme.secondaryText).textSelection(.enabled)
        }
        .toggleStyle(.switch)
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    /// 토글과 같은 줄 높이의 텍스트 행. 테두리 버튼 대신 메뉴 항목처럼 보이게 한다.
    private func settingsRow(_ symbol: String, _ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        HoverHighlight(enabled: enabled) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: symbol).frame(width: 16).foregroundColor(Theme.secondaryText)
                    Text(title)
                    Spacer()
                }
                .padding(.vertical, 4).padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .foregroundColor(enabled ? Theme.text : Theme.secondaryText)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        HoverHighlight(enabled: true) {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 14)).foregroundColor(Theme.secondaryText).frame(width: 22, height: 22)
                    .help(help)
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }
}

/// 마우스가 올라가면 배경을 살짝 칠해 눌러도 되는 항목임을 알린다.
struct HoverHighlight<Content: View>: View {
    let enabled: Bool
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering && enabled ? Theme.accent.opacity(0.14) : Color.clear))
            .onHover { hovering = $0 }
    }
}
