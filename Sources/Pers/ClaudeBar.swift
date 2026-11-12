import SwiftUI

/// The API tester's own chat box: one line to ask Claude about requests or run a shell command, and a panel for what comes back.
struct ClaudeBar: View {
    enum Mode {
        case claude, terminal

        var color: Color { self == .claude ? Theme.cyan : Theme.green }
    }

    @ObservedObject var session: Session
    var mode: Mode
    var focus: FocusState<RequestField?>.Binding
    @Binding var dismissed: Int
    var hints: [(key: String, action: String)]
    var highlighted: String?
    @ViewState private var draft = ""

    private var typing: Bool { focus.wrappedValue == .ask }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let prompt = session.prompt {
                promptPanel(prompt)
            } else if !replies.isEmpty && session.messages.count > dismissed {
                replyPanel
            }
            QueuedMessages(session: session)
            inputRow
            KeyHints(hints: shownHints, highlighted: highlighted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(LinearGradient(colors: [.clear, Theme.deep.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        .onChange(of: session.prompt?.requestId) {
            guard let prompt = session.prompt else { return }
            focus.wrappedValue = prompt.question == nil ? .page : .ask
        }
    }

    private var shownHints: [(key: String, action: String)] {
        if let prompt = session.prompt, prompt.question == nil {
            return [(KeyAction.allow.label, "allow")] + (prompt.suggestions.isEmpty ? [] : [(KeyAction.allowAlways.label, "always")])
                + [(KeyAction.deny.label, "deny")]
        }
        if typing { return [("⏎", "send"), ("ESC", "back")] }
        return hints + (session.isBusy || session.isRunningShell ? [(KeyAction.stop.label, "stop")] : [])
    }

    /// What Claude or the shell said since the last thing the user sent.
    private var replies: [ChatMessage] {
        let start = (session.messages.lastIndex { $0.speaker == .user } ?? -1) + 1
        return session.messages[start...].filter { [.claude, .shell, .system].contains($0.speaker) }
    }

    private var activity: String {
        guard session.isBusy, let tool = session.messages.last(where: { $0.speaker == .tool }) else { return "thinking" }
        let parts = tool.toolParts
        return [parts.name, parts.description ?? parts.detail].compactMap { $0 }.joined(separator: " ")
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Group {
                if session.isBusy {
                    Text("◈ \(activity)").foregroundStyle(Theme.aqua).lineLimit(1)
                } else if mode == .terminal {
                    Text((session.directory as NSString).abbreviatingWithTildeInPath + " ❯").foregroundStyle(Theme.green)
                } else {
                    Text("CLAUDE ›").foregroundStyle(Theme.cyan)
                }
            }
            .font(Theme.ui(12, weight: .black))
            .frame(maxWidth: 260, alignment: .leading)
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .foregroundStyle(Theme.ice)
                .focused(focus, equals: .ask)
                .onSubmit(send)
                .onKeyPress(.escape) {
                    focus.wrappedValue = .page
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    guard let suggestion else { return .ignored }
                    draft += suggestion
                    return .handled
                }
                .background(alignment: .leading) {
                    if let suggestion {
                        (Text(draft).foregroundStyle(.clear) + Text(suggestion).foregroundStyle(Theme.dim))
                            .font(Theme.body)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                }
            if session.isBusy || session.isRunningShell {
                Button { session.stop() } label: { Chip(color: Theme.red) { Text("STOP") } }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .panel(accent: mode.color, dark: true, padding: 8, selected: typing, opacity: 1)
    }

    private var suggestion: String? {
        guard session.prompt?.question == nil else { return nil }
        return session.suggestion(for: draft, inTerminal: mode == .terminal)
    }

    private var placeholder: String {
        if session.prompt?.question != nil { return "Answer Claude…" }
        return mode == .claude ? "Ask Claude to create or change requests…" : "z repo · cd .. · any shell command"
    }

    private var replyPanel: some View {
        HStack(alignment: .top, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(replies) { message in
                        switch message.speaker {
                        case .shell: Text(message.text).font(Theme.code).foregroundStyle(Theme.text)
                        case .system: Text(message.text).foregroundStyle(Theme.red)
                        default: MarkdownView(text: message.text)
                        }
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 150)
            Button { dismissed = session.messages.count } label: { Text("×").foregroundStyle(Theme.dim) }
                .buttonStyle(.plain)
                .help("Dismiss")
        }
        .padding(12)
        .panel(accent: Theme.cyan, dark: true, padding: 0, opacity: 1)
    }

    @ViewBuilder
    private func promptPanel(_ prompt: PermissionPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let question = prompt.question {
                MarkdownView(text: question.markdown)
            } else {
                Text("Claude wants to use \(prompt.tool)").font(Theme.ui(13, weight: .bold)).foregroundStyle(Theme.gold)
                if !prompt.detail.isEmpty {
                    Text(prompt.detail).font(Theme.code).foregroundStyle(Theme.dim).lineLimit(3)
                }
                HStack(spacing: 8) {
                    Button { session.answer(prompt, allow: true) } label: { Chip(active: true, color: Theme.green) { Text("ALLOW") } }
                    if !prompt.suggestions.isEmpty {
                        Button { session.answer(prompt, allow: true, always: true) } label: { Chip(color: Theme.aqua) { Text("ALWAYS") } }
                    }
                    Button { session.answer(prompt, allow: false) } label: { Chip(color: Theme.red) { Text("DENY") } }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .panel(accent: Theme.gold, dark: true, padding: 0, opacity: 1)
    }

    private func send() {
        if session.isRunningShell && mode == .terminal {
            session.sendInput(draft)
            draft = ""
            return
        }
        let text = draft.trimmed
        guard !text.isEmpty else { return }
        if session.prompt?.question != nil {
            session.reply(text)
        } else if !session.send(mode == .terminal ? Session.terminalMarker + text : text) {
            return
        }
        draft = ""
    }
}
