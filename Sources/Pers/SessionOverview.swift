import SwiftUI

struct SessionOverview: View {
    static let width: CGFloat = 232
    static let leadingInset: CGFloat = 18
    static let reservedWidth = leadingInset + width

    @EnvironmentObject var store: AppStore
    var navigator: Navigator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            KeyHints(hints: [(KeyAction.label(.previousTab, .nextTab), "tab"), (KeyAction.newTab.label, "new"), (KeyAction.newWorktree.label, "worktree"),
                             (KeyAction.closeTab.label, "close"), (KeyAction.actions.label, "actions"), (KeyAction.map.label, "map")])
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(store.overviewRepos) { repo in
                        VStack(alignment: .leading, spacing: 4) {
                            // Repos kept for being used often have no tabs; clicking the name opens one there.
                            NamePlate(name: repo.name.uppercased(), color: Theme.cyan)
                                .lineLimit(1)
                                .padding(.leading, 4)
                                .opacity(repo.sessions.isEmpty ? 0.5 : 1)
                                .onTapGesture { if repo.sessions.isEmpty { store.newTab(directory: repo.path) } }
                            ForEach(repo.sessions) { session in
                                OverviewRow(session: session, selected: session.id == store.selectedId, navigator: navigator)
                            }
                        }
                    }
                }
                .padding(.trailing, 14)
            }
        }
    }
}

private struct OverviewRow: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var session: Session
    var selected: Bool
    var navigator: Navigator
    @ViewState private var hovered = false
    @ViewState private var tabTitle: String?
    private var highlighted: Bool { hovered || selected }

    var body: some View {
        HStack(spacing: 8) {
            Text(session.isBusy ? "◈" : "◆")
            VStack(alignment: .leading, spacing: 0) {
                Text(tabTitle ?? session.title)
                    .font(Theme.ui(15, weight: .bold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let branch = session.git?.branch {
                        Text(branch)
                            .font(Theme.ui(12))
                            .opacity(0.7)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if session.hasUnread { tag("NEW") }
                    if session.forkedFrom != nil { tag("FORK") }
                }
                if let command = session.runningCommand {
                    RunLine(name: "❯ \(command)", status: session.terminalStatus.uppercased(), color: Theme.green,
                            highlighted: highlighted, isActive: true, stopOrDismiss: session.stopTerminal)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: showTerminalMessage)
                }
                ForEach(store.runs.filter { $0.directory == session.directory }) { run in
                    RunLine(name: "▸ \(run.action.name)", status: run.state.label(readyMarker: run.action.readyMarker), color: run.state.color,
                            highlighted: highlighted, isActive: run.isActive) {
                        if run.isActive { run.stop() } else { store.dismiss(run) }
                    }
                }
            }
            Spacer(minLength: 0)
            if hovered {
                Button { store.close(session) } label: { Text("×") }
                    .buttonStyle(.plain)
            }
        }
        .foregroundStyle(highlighted ? Theme.navy : session.isBusy ? Theme.aqua : Theme.ice)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ActiveBackdrop(active: highlighted))
        .contentShape(Rectangle())
        .activeShift(highlighted)
        .onHover { hovered = $0 }
        .task(id: "\(session.sessionId ?? "")\(session.isBusy)") {
            guard let sessionId = session.sessionId else { tabTitle = nil; return }
            tabTitle = await Task.detached { SaveData.title(ofSession: sessionId) }.value
        }
        .onTapGesture { store.selectedId = session.id }
    }

    /// Selects the command's message in navigation mode, where ⏎ opens its terminal.
    private func showTerminalMessage() {
        guard let id = session.terminalMessageId else { return }
        store.selectedId = session.id
        session.showChat()
        navigator.messageId = id
        navigator.active = true
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(10, weight: .black))
            .foregroundStyle(Theme.navy)
            .padding(.horizontal, 6)
            .background(Slant(amount: 4).fill(Theme.gold))
    }
}
