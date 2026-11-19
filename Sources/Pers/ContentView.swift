import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var scroller = LogScroller()
    @StateObject private var navigator = Navigator()
    @AppStorage(Theme.styleKey) private var style = ThemeStyle.neutral
    @AppStorage(DialogueBox.showSpriteKey) private var showSprite = false

    var body: some View {
        Group {
            if store.showingMap {
                MapView()
            } else if store.page == .apiTester {
                APITester()
            } else if store.page == .keybindings {
                KeybindingsPage()
            } else if store.page == .settings {
                SettingsPage()
            } else {
                sessions
            }
        }
        .background {
            if Theme.isQuest {
                MoonlitBackground()
            } else if Theme.isPhantom {
                PhantomBackground()
            } else {
                Theme.deep
            }
        }
        .ignoresSafeArea(edges: .top)
        .preferredColorScheme(.dark)
        .frame(minWidth: 820, minHeight: 600)
        .id(style)
    }

    private var sessions: some View {
        VStack(spacing: 0) {
            if let session = store.selected {
                StatusHUD(session: session)
                MainPanel(session: session, scroller: scroller, navigator: navigator)
                    .zIndex(1)
                DialogueBox(session: session, scroller: scroller, navigator: navigator)
                    .id(session.id)
            }
        }
        .onChange(of: navigator.newMessage) { store.selected?.unseenAbove = navigator.newMessage }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 14) {
                if Theme.isQuest { DayPanel() }
                SessionOverview(navigator: navigator)
            }
            .frame(width: SessionOverview.width, alignment: .topLeading)
            .padding(.top, 34)
            .padding(.leading, SessionOverview.leadingInset)
            .padding(.bottom, 250)
        }
        .overlay(alignment: .topTrailing) {
            if let session = store.selected {
                Group {
                    if store.showingActions { ActionPanel(session: session) } else { BackgroundPanel(session: session) }
                }
                .padding(.top, 90)
                .padding(.trailing, 18)
                .padding(.bottom, 250)
            }
        }
        .overlay {
            if let pending = store.pendingClose { WorktreeCleanupPopup(pending: pending) }
            if store.creatingWorktree { NewWorktreePopup() }
            if let image = store.previewImage {
                Popup(title: "IMAGE", width: 720, dismiss: { store.previewImage = nil }) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 480)
                }
            }
        }
        .background {
            Button("") { showSprite.toggle() }
                .keyboardShortcut(.sprite)
                .opacity(0)
                .allowsHitTesting(false)
            Button("") { store.showingActions.toggle() }
                .keyboardShortcut(.actions)
                .opacity(0)
                .allowsHitTesting(false)
            Button("") { openDiffFileInIntelliJ() }
                .keyboardShortcut(.openInIntelliJ)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    private func openDiffFileInIntelliJ() {
        guard let session = store.selected, session.showingDiff, let root = session.git?.root,
              let file = navigator.file(in: session.diff),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.jetbrains.intellij") else { return }
        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/MacOS/idea")
        process.arguments = [root, (root as NSString).appendingPathComponent(file.path)]
        try? process.run()
    }
}

private struct MainPanel: View {
    @ObservedObject var session: Session
    var scroller: LogScroller
    var navigator: Navigator

    var body: some View {
        content.background {
            if session.shell != nil {
                Button("", action: toggleTerminal)
                    .keyboardShortcut(.terminal)
                    .hidden()
            }
        }
    }

    /// Leaves the terminal only from inside it; from the chat input it goes in, even when the terminal is already open.
    private func toggleTerminal() {
        guard let terminal = session.shell else { return }
        if !session.showingTerminal {
            session.openTerminal()
        } else if terminal.isFocused {
            session.showingTerminal = false
        } else {
            terminal.focus()
        }
    }

    @ViewBuilder
    private var content: some View {
        if session.showingTerminal, let terminal = session.shell {
            let running = session.isRunningShell
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("TERMINAL").font(Theme.ui(12, weight: .black)).foregroundStyle(Theme.navy)
                        .padding(.horizontal, 10)
                        .background(Slant(amount: 6).fill(Theme.green))
                    Text("● " + (running ? session.terminalStatus : "ready").uppercased())
                        .font(Theme.ui(10, weight: .bold)).foregroundStyle(Theme.green)
                    Spacer()
                    KeyHints(hints: (running ? [("⌃c", "interrupt")] : []) + [(KeyAction.terminal.label, "back to chat")])
                }
                .padding(8)
                TerminalPane(terminal: terminal)
            }
            .overlay(Rectangle().strokeBorder(Theme.green, lineWidth: 1.5))
            .padding(.leading, SessionOverview.reservedWidth)
        } else if session.showingLog && session.openedCommit == nil {
            CommitLog(commits: session.commits, navigator: navigator)
        } else if session.showingDiff || session.openedCommit != nil {
            DiffView(session: session, scroller: scroller, navigator: navigator)
        } else {
            MessageLog(session: session, scroller: scroller, navigator: navigator)
                .id(session.logIdentity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CommitLog: View {
    var commits: [Commit]
    @ObservedObject var navigator: Navigator

    var body: some View {
        let cursor = navigator.commit(in: commits)
        HStack(spacing: 0) {
            Color.clear.frame(width: SessionOverview.reservedWidth)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                            HStack(spacing: 12) {
                                Text(commit.id).foregroundStyle(Theme.gold)
                                Text(commit.subject).foregroundStyle(Theme.text).lineLimit(1)
                                Spacer(minLength: 12)
                                Text("\(commit.author) · \(commit.age)").foregroundStyle(Theme.dim)
                            }
                            .font(Theme.code)
                            .padding(.vertical, 3)
                            .background(navigator.active && index == cursor ? Theme.cyan.opacity(0.2) : .clear)
                            .overlay(alignment: .trailing) {
                                if navigator.active && index == cursor {
                                    KeyHints(hints: [(KeyAction.label(.down, .up), "commit"), (KeyAction.label(.top, .bottom), "top/end"), (KeyAction.select.label, "view"),
                                                     (KeyAction.copy.label, navigator.yankArmed ? "again to copy hash" : "copy hash")],
                                             highlighted: navigator.armedKey)
                                        .padding(.horizontal, 10)
                                        .background(Slant(amount: 6).fill(Theme.deep.opacity(0.9)))
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: navigator.commitIndex) { proxy.scrollTo(commits[cursor].id) }
            }
            .defaultScrollAnchor(.top)
            .background(Theme.codeBackground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusHUD: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var session: Session
    @AppStorage(Theme.styleKey) private var style = ThemeStyle.neutral

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Spacer(minLength: 8)
            HStack(spacing: 8) { settingsRow }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(LinearGradient(colors: [Theme.deep.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
        .background {
            Button("") { promptForWorktree() }
                .keyboardShortcut(.newWorktree)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var settingsRow: some View {
        Button { session.advising.toggle() } label: { Chip(active: session.advising, color: Theme.gold) { Text("ADVISOR") } }
            .buttonStyle(.plain)
            .help("A second model (Sonnet) reviews each finished turn; its notes go to Claude with your next message")

        Menu {
            Picker("Theme", selection: $style) {
                ForEach(ThemeStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Chip(color: Theme.ice) { Text("THEME") }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    static func compact(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
        return tokens < 1000 ? "\(tokens)" : String(format: "%.1fk", Double(tokens) / 1000)
    }

    private func promptForWorktree() {
        guard session.git != nil else { return }
        store.creatingWorktree = true
    }
}

/// The session at a glance beside the input: model and effort, mode, git state and how full the context window is.
struct StatusLine: View {
    @ObservedObject var session: Session

    var body: some View {
        HStack(spacing: 10) {
            Text(session.model.label + (session.effort.map { " · \($0.label)" } ?? "")).foregroundStyle(Theme.ice)
            separator
            Text(session.mode.label).foregroundStyle(session.mode.color)
            if let git = session.git {
                separator
                gitStatus(git)
            }
            if let used = session.contextTokens {
                separator
                context(used)
            }
        }
        .font(Theme.ui(12, weight: .bold))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .background(Slant(amount: 6).fill(Theme.deep.opacity(0.9)))
    }

    private var separator: some View { Text("│").foregroundStyle(Theme.dim) }

    private func gitStatus(_ git: GitInfo) -> some View {
        HStack(spacing: 6) {
            Text("⎇ \(git.branch)").foregroundStyle(git.changedFiles > 0 ? Theme.gold : Theme.green)
            if git.unstaged > 0 { Text("*\(git.unstaged)").foregroundStyle(Theme.gold) }
            if git.staged > 0 { Text("+\(git.staged)").foregroundStyle(Theme.green) }
            if git.untracked > 0 { Text("?\(git.untracked)").foregroundStyle(Theme.pink) }
            if git.ahead > 0 { Text("↑\(git.ahead)").foregroundStyle(Theme.cyan) }
            if git.behind > 0 { Text("↓\(git.behind)").foregroundStyle(Theme.cyan) }
        }
        .help("* unstaged  + staged  ? untracked  ↑ ahead  ↓ behind")
    }

    @ViewBuilder
    private func context(_ used: Int) -> some View {
        if let window = session.contextWindow, window > 0 {
            let percent = used * 100 / window
            HStack(spacing: 4) {
                Text("◔ \(percent)%").foregroundStyle(percent >= 80 ? Theme.red : percent >= 50 ? Theme.gold : Theme.green)
                Text("of \(StatusHUD.compact(window))").foregroundStyle(Theme.dim)
            }
            .help("\(StatusHUD.compact(used)) of \(StatusHUD.compact(window)) context tokens used")
        } else {
            Text("◔ \(StatusHUD.compact(used))").foregroundStyle(Theme.dim)
                .help("Context tokens used; the window size shows after the next reply")
        }
    }
}

extension PermissionMode {
    var color: Color {
        switch self {
        case .bypassPermissions, .dontAsk: Theme.red
        case .plan: Theme.cyan
        case .auto, .acceptEdits: Theme.aqua
        case .manual: Theme.text
        }
    }
}
