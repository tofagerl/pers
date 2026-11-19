import SwiftUI

/// What's still running for the tab beside the chat: Claude's background tasks and the actions started in its folder.
struct BackgroundPanel: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var session: Session

    private var runs: [ActionRun] { store.runs.filter { $0.directory == session.directory && $0.isActive } }

    var body: some View {
        if !session.backgroundTasks.isEmpty || !runs.isEmpty {
            VStack(alignment: .leading, spacing: -8) {
                NamePlate(name: "BACKGROUND", color: Theme.aqua, shadowColor: Theme.ocean)
                    .padding(.horizontal, 14)
                    .zIndex(1)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(session.backgroundTasks) { task in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.command.map { "❯ \($0)" } ?? "◇ \(task.description)")
                                .font(task.command == nil ? Theme.ui(11, weight: .bold) : Theme.code)
                                .foregroundStyle(Theme.text)
                                .lineLimit(3)
                            if task.command != nil, !task.description.isEmpty {
                                Text(task.description).font(Theme.ui(11)).foregroundStyle(Theme.dim).lineLimit(1)
                            }
                        }
                    }
                    ForEach(runs) { run in
                        RunLine(name: "▸ \(run.action.name)", status: run.state.label(readyMarker: run.action.readyMarker),
                                color: run.state.color, highlighted: false, isActive: true) { run.stop() }
                            .foregroundStyle(Theme.ice)
                    }
                }
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel(accent: Theme.aqua, padding: 14)
            }
            .frame(width: 280)
        }
    }
}
