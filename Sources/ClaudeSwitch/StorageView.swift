import SwiftUI
import SwitchUI

final class StorageState: ObservableObject {
    @Published var model = StorageModel.build(status: nil, usages: [], plan: nil, loading: true, busy: nil)
    @Published var autoPropagate = true
}

/// 용량 정리 화면. 계산과 삭제는 AppDelegate가 core로 수행하고 여기서는 표시와 동작 전달만 한다.
struct StorageView: View {
    @ObservedObject var state: StorageState
    let onAction: (MenuAction) -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                header
                propagationCard
                table
                backupsCard
                Text("논리는 파일별 할당 블록의 합으로 clone 공유 블록이 중복 계산됩니다. 고유는 그 프로필만 가리키는 블록이고, 실제 점유는 프로필과 백업 전체가 차지하는 블록의 합집합입니다.")
                    .font(.caption).foregroundColor(Theme.secondaryText)
            }
            .padding(16)
            .frame(width: 720, alignment: .topLeading)
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .background(Theme.background)
        .foregroundColor(Theme.text)
    }

    private var header: some View {
        HStack {
            Text("용량 정리").font(Theme.titleFont)
            if state.model.loading {
                ProgressView().controlSize(.small)
                Text("계산 중…").font(.caption).foregroundColor(Theme.secondaryText)
            } else {
                Text("논리 합계 \(StorageModel.format(state.model.totalBytes))").font(.callout).foregroundColor(Theme.secondaryText)
                if let physical = state.model.physicalTotal {
                    Text("· 실제 점유 \(StorageModel.format(physical))").font(.callout.weight(.semibold)).foregroundColor(Theme.accent)
                }
            }
            if let busy = state.model.busyText {
                ProgressView().controlSize(.small)
                Text(busy).font(.caption).foregroundColor(Theme.accent)
            }
            Spacer()
            Button { onAction(.refreshStorage) } label: { Label("다시 계산", systemImage: "arrow.clockwise") }
                .disabled(state.model.loading || state.model.busyText != nil)
        }
    }

    private var propagationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "square.on.square").foregroundColor(Theme.accent)
                Text("VM 이미지 복제 (APFS clone)").font(.headline)
                Spacer()
                Toggle("자동", isOn: Binding(get: { state.autoPropagate }, set: { _ in onAction(.toggleAutoPropagate) }))
                    .toggleStyle(.switch).controlSize(.small)
            }
            Text(state.model.propagationNote).font(.callout)
            if let source = state.model.propagationSource {
                VStack(alignment: .leading, spacing: 2) {
                    statusLine("원본", [source])
                    statusLine("복제 완료", state.model.propagationUpToDate)
                    statusLine("복제 대상", state.model.propagationTargets)
                    statusLine("보류 (Claude 종료 후 복제)", state.model.propagationDeferred)
                }
            }
            if !state.model.propagationTargets.isEmpty {
                HStack {
                    Spacer()
                    Button("지금 복제") { onAction(.propagateVMImages) }
                        .tint(Theme.accent)
                        .disabled(state.model.busyText != nil)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                cell("프로필", width: 140, alignment: .leading).font(.caption.weight(.semibold))
                cell("논리", width: 75).font(.caption.weight(.semibold))
                cell("고유", width: 75).font(.caption.weight(.semibold)).help("이 프로필만 가리키는 블록. 지우면 회수되는 양")
                cell("캐시", width: 70).font(.caption.weight(.semibold))
                cell("VM 이미지", width: 85).font(.caption.weight(.semibold))
                cell("VM 압축", width: 75).font(.caption.weight(.semibold))
                cell("세션", width: 75).font(.caption.weight(.semibold))
                cell("작업", width: 140).font(.caption.weight(.semibold))
            }
            .foregroundColor(Theme.secondaryText)
            .padding(.vertical, 6).padding(.horizontal, 8)
            Divider().overlay(Theme.divider)
            ForEach(state.model.rows) { row in
                HStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Text(row.name).font(.body).lineLimit(1)
                            .foregroundColor(row.isActive ? Theme.text : Theme.secondaryText)
                        if row.needsPropagation { Image(systemName: "arrow.down.circle").foregroundColor(Theme.accent).font(.caption).help("VM 이미지 복제 대상") }
                    }
                    .frame(width: 140, alignment: .leading)
                    cell(StorageModel.format(row.total), width: 75)
                    cell(row.exclusive.map(StorageModel.format) ?? "…", width: 75)
                    cell(StorageModel.format(row.caches), width: 70)
                    cell(StorageModel.format(row.vmImages), width: 85)
                    cell(StorageModel.format(row.vmCompressed), width: 75)
                    cell(StorageModel.format(row.sessionData), width: 75)
                    HStack(spacing: 6) {
                        actionButton("trash.slash", help: "캐시 삭제 (재생성됨)", enabled: row.canCleanCaches) { onAction(.cleanCaches(profileID: row.profileID)) }
                        actionButton("externaldrive.badge.minus", help: "VM 이미지 삭제 (세션·압축 캐시 보존, 다음 Cowork 때 재다운로드 또는 복제)", enabled: row.canRemoveVMImages) { onAction(.removeVMImages(profileID: row.profileID, includeCompressed: false)) }
                        actionButton("externaldrive.badge.xmark", help: "VM 이미지와 압축 캐시 모두 삭제 (다음 업데이트는 전체 다운로드)", enabled: row.canRemoveVMImages) { onAction(.removeVMImages(profileID: row.profileID, includeCompressed: true)) }
                    }
                    .frame(width: 140, alignment: .leading)
                }
                .padding(.vertical, 6).padding(.horizontal, 8)
                if row.id != state.model.rows.last?.id { Divider().overlay(Theme.divider) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }

    private var backupsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("백업").font(.headline)
            if state.model.backups.isEmpty {
                Text("기록된 백업이 없습니다").font(.callout).foregroundColor(Theme.secondaryText)
            }
            ForEach(state.model.backups) { backup in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(backup.profileName) 등록 시 백업 · \(backup.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.callout)
                        Text(backup.path).font(.caption).foregroundColor(Theme.secondaryText).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if let exclusive = state.model.backupExclusive[backup.path] {
                        Text("고유 \(StorageModel.format(exclusive))").font(.caption).foregroundColor(Theme.secondaryText)
                    }
                    Button("휴지통으로") { onAction(.trashBackup(path: backup.path)) }.disabled(state.model.busyText != nil)
                }
            }
            Text("첫 등록 백업은 clone이라 고유 블록만큼만 회수됩니다.").font(.caption).foregroundColor(Theme.secondaryText)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }

    private func statusLine(_ label: String, _ names: [String]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).font(.caption).foregroundColor(Theme.secondaryText).frame(width: 150, alignment: .leading)
            Text(names.isEmpty ? "없음" : names.joined(separator: ", ")).font(.caption)
        }
    }

    private func cell(_ text: String, width: CGFloat, alignment: Alignment = .trailing) -> some View {
        Text(text).font(.callout.monospacedDigit()).frame(width: width, alignment: alignment).lineLimit(1)
    }

    private func actionButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HoverHighlight(enabled: enabled) {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 14)).foregroundColor(enabled ? Theme.secondaryText : Theme.divider).frame(width: 24, height: 22)
                    .help(help)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .help(help)
        }
    }

}

final class StorageWindowController: NSWindowController {
    let state = StorageState()

    init(onAction: @escaping (MenuAction) -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Claude Switch 용량 정리"
        window.minSize = NSSize(width: 720, height: 320)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        super.init(window: window)
        let hosting = NSHostingView(rootView: StorageView(state: state, onAction: onAction))
        window.contentView = hosting
        window.backgroundColor = NSColor(Theme.background)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func present() {
        guard let window else { return }
        if !window.isVisible {
            fitToContent()
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 내용이 늘어나면 화면의 85% 높이까지만 키운다. 사용자가 줄인 창은 다시 키우지 않는다.
    func resize() {
        guard let window, window.isVisible else { return }
        fitToContent(growOnly: true)
    }

    private func fitToContent(growOnly: Bool = false) {
        guard let window, let hosting = window.contentView as? NSHostingView<StorageView> else { return }
        let content = hosting.fittingSize
        let limit = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        var height = min(content.height, limit * 0.85)
        if growOnly { height = max(height, window.contentView?.frame.height ?? 0) }
        window.setContentSize(NSSize(width: max(720, window.contentView?.frame.width ?? 720), height: height))
    }
}
