import SwiftUI

/// Lets the input field page the message log, since the log never has keyboard focus.
@MainActor
final class LogScroller: ObservableObject {
    @Published var position = ScrollPosition(edge: .bottom)
    // Not published: it changes on every scroll frame and only matters when paging.
    var geometry: ScrollGeometry?
    var followsBottom = true

    func track(_ new: ScrollGeometry) {
        let old = geometry
        geometry = new
        // Only an upward move counts as leaving the bottom, since growing content also pushes the bottom away.
        if new.visibleRect.maxY >= new.contentSize.height - 48 {
            followsBottom = true
        } else if let old, new.contentOffset.y < old.contentOffset.y - 1 {
            followsBottom = false
        }
    }

    func page(_ direction: CGFloat, horizontal: Bool = false) {
        guard let geometry else { return }
        let size = horizontal ? geometry.containerSize.width : geometry.containerSize.height
        let content = horizontal ? geometry.contentSize.width : geometry.contentSize.height
        let offset = horizontal ? geometry.contentOffset.x : geometry.contentOffset.y
        let target = min(max(offset + direction * size / 2, 0), max(content - size, 0))
        withAnimation(.easeOut(duration: 0.15)) {
            if horizontal { position.scrollTo(x: target) } else { position.scrollTo(y: target) }
        }
    }
}

struct MessageLog: View {
    @ObservedObject var session: Session
    @ObservedObject var scroller: LogScroller
    @ObservedObject var navigator: Navigator

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if session.messages.isEmpty { EmptyQuest() }
                    let selectedId = navigator.active ? navigator.message(in: session.boxedMessages)?.id : nil
                    ForEach(session.messages) { message in
                        let hovered = message.id == selectedId
                        let running = message.id == session.terminalMessageId
                        MessageRow(message: message, text: session.visibleText(of: message),
                                   hovered: hovered, armedKey: hovered ? navigator.armedKey : nil,
                                   hints: hovered ? navigationHints + (session.hasTerminal(message) ? [(KeyAction.select.label, "open terminal")] : []) : [],
                                   status: running ? session.terminalStatus + " · \(KeyAction.terminal.label) to open" : nil,
                                   toolRunning: session.runningTools.values.contains(message.id))
                            .id(message.id)
                    }
                    if let prompt = session.prompt {
                        PermissionBox(session: session, navigator: navigator, prompt: prompt)
                            .id(prompt.step)
                            .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 32)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition($scroller.position)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) {
                scroller.track($1)
                if scroller.followsBottom && !navigator.active { navigator.newMessage = false }
            }
            .onChange(of: session.messages.count) {
                let userInitiated = session.messages.last.map { [.user, .shell].contains($0.speaker) } ?? false
                if !navigator.active && (userInitiated || scroller.followsBottom) { scrollDown(proxy) }
            }
            .onChange(of: session.prompt?.step) { if !navigator.active { scrollDown(proxy) } }
            .onChange(of: session.revealed) { if !navigator.active && scroller.followsBottom { scrollDown(proxy, animated: false) } }
            .onChange(of: session.messages.last?.text) { if !navigator.active && scroller.followsBottom { scrollDown(proxy, animated: false) } }
            .onChange(of: session.boxedMessages.count) {
                let userInitiated = session.boxedMessages.last.map { [.user, .shell].contains($0.speaker) } ?? false
                if !userInitiated && (navigator.active || !scroller.followsBottom) { navigator.newMessage = true }
            }
            .onChange(of: navigator.messageId) {
                if navigator.message(in: session.boxedMessages)?.id == session.boxedMessages.last?.id { navigator.newMessage = false }
                centerSelection(proxy)
            }
            .onChange(of: navigator.active) { if navigator.active { centerSoon(proxy) } }
            .onAppear {
                scrollDown(proxy, animated: false)
                // Opened on a message picked from the overview.
                if navigator.active { centerSoon(proxy) }
            }
        }
        .overlay(alignment: .bottom) {
            if navigator.newMessage {
                Button(action: showLatest) {
                    HStack(spacing: 8) {
                        Text("NEW MESSAGE RECEIVED").foregroundStyle(Theme.navy)
                        if navigator.active { KeyHints(hints: [(KeyAction.bottom.label, "scroll down to see latest")]) }
                    }
                    .font(Theme.ui(13, weight: .black))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 4)
                    .background(Slant(amount: 8).fill(Theme.gold))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: navigator.newMessage)
    }

    private func showLatest() {
        if navigator.active {
            navigator.jumpToLatest(in: session.boxedMessages)
        } else {
            withAnimation(.easeOut(duration: 0.2)) { scroller.position.scrollTo(edge: .bottom) }
        }
    }

    /// The dialogue box shrinks as navigation starts, so centre once the log has its final height.
    private func centerSoon(_ proxy: ScrollViewProxy) {
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            centerSelection(proxy)
        }
    }

    private func centerSelection(_ proxy: ScrollViewProxy) {
        guard let id = navigator.message(in: session.boxedMessages)?.id else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .top) }
    }

    private var navigationHints: [(key: String, action: String)] {
        [(KeyAction.label(.down, .up), "message"), (KeyAction.label(.top, .bottom), "first/last"),
         (KeyAction.fork.label, navigator.forkArmed ? "again to fork from this message" : "fork"),
         (KeyAction.copy.label, navigator.yankArmed ? "again to copy this message" : "copy")]
    }

    private func scrollDown(_ proxy: ScrollViewProxy, animated: Bool = true) {
        withAnimation(animated ? .easeOut(duration: 0.2) : nil) { proxy.scrollTo("bottom", anchor: .bottom) }
    }
}

private struct EmptyQuest: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("A NEW DAY BEGINS")
                .font(Theme.display(64))
                .foregroundStyle(Theme.ice)
                .shadow(color: Theme.cyan.opacity(0.7), radius: 0, x: 5, y: 5)
            Text("Claude has joined your party.")
                .font(Theme.ui(18, weight: .bold))
                .foregroundStyle(Theme.navy)
                .padding(.horizontal, 18)
                .padding(.vertical, 2)
                .background(Slant(amount: 10).fill(Theme.cyan))
        }
        .rotationEffect(.degrees(Theme.isStylized ? -4 : 0))
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }
}

extension Session {
    /// The messages drawn as boxes, which are the ones vim navigation steps through.
    var boxedMessages: [ChatMessage] {
        messages.filter { message in
            let text = visibleText(of: message)
            switch message.speaker {
            case .user: return !text.hasPrefix("!")
            case .claude, .shell: return true
            default: return false
            }
        }
    }

    func isTerminal(_ message: ChatMessage) -> Bool {
        message.speaker == .shell || (message.speaker == .user && message.text.hasPrefix(Session.terminalMarker))
    }

    func copyText(of message: ChatMessage) -> String {
        message.speaker == .user && isTerminal(message) ? String(message.text.dropFirst()) : message.text
    }
}

private struct EditDiff: View {
    var edits: [ChatMessage.Edit]
    private static let maxLines = 40

    var body: some View {
        let rows = edits.flatMap { Git.rows(replacing: $0.old, with: $0.new) }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.prefix(Self.maxLines).enumerated()), id: \.offset) { _, row in
                DiffLine(row: row, numbered: false, selected: false, pinned: false) {}
            }
            if rows.count > Self.maxLines {
                Text("\u{2026} \(rows.count - Self.maxLines) more lines")
                    .font(Theme.code)
                    .foregroundStyle(Theme.dim)
                    .padding(8)
            }
        }
        .background(Theme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .textSelection(.enabled)
    }
}

struct MessageRow: View {
    @EnvironmentObject var store: AppStore
    var message: ChatMessage
    var text: String
    var hovered = false
    var armedKey: String?
    var hints: [(key: String, action: String)] = []
    /// What a running terminal command is doing.
    var status: String?
    var toolRunning = false

    private var forking: Bool { armedKey != nil }

    var body: some View {
        switch message.speaker {
        case .user where text.hasPrefix(Session.terminalMarker):
            selectable(toolRow(name: "TERMINAL", detail: text.dropFirst().trimmed, trailing: true, color: Theme.green))
        case .user where text.hasPrefix("!"):
            toolRow(name: "BASH", detail: text.dropFirst().trimmed, trailing: true)
        case .user:
            HStack {
                Spacer(minLength: 100)
                bubble(name: "YOU", plate: forking ? Theme.gold : Theme.cyan, light: Theme.isStylized, alignment: .trailing) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array((message.images ?? []).enumerated()), id: \.offset) { _, data in
                            if let image = NSImage(data: data) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 320, maxHeight: 220, alignment: .leading)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .onTapGesture { store.previewImage = image }
                            }
                        }
                        if !text.isEmpty {
                            Text(text)
                                .font(Theme.body)
                                .foregroundStyle(Theme.isStylized ? Theme.navy : Theme.text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        case .claude:
            HStack {
                bubble(name: "CLAUDE", plate: Theme.ice, light: false, alignment: .leading) {
                    MarkdownView(text: text)
                }
                Spacer(minLength: 40)
            }
        case .advisor:
            HStack {
                bubble(name: "ADVISOR", plate: Theme.gold, light: false, alignment: .leading) {
                    MarkdownView(text: text)
                }
                Spacer(minLength: 120)
            }
        case .tool:
            let tool = message.toolParts
            VStack(alignment: .leading, spacing: 6) {
                toolRow(name: tool.name.uppercased(), detail: tool.detail, description: tool.description, running: toolRunning)
                if let edits = message.edits { EditDiff(edits: edits).padding(.leading, 18) }
            }
        case .shell:
            selectable(CodeBlock(language: "shell", code: text, selected: hovered, status: status, isOutput: true, colors: message.colors)
                .padding(.leading, 18)
                .textSelection(.enabled), highlighted: false)
        case .system:
            Text(text)
                .font(Theme.ui(13, weight: .bold))
                .foregroundStyle(Theme.ice)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .background(Slant(amount: 8).fill(Theme.red.opacity(0.85)))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
        }
    }

    private func selectable<Content: View>(_ content: Content, highlighted: Bool = true) -> some View {
        content
            .padding(.bottom, hovered ? 14 : 0)
            .background(hovered && highlighted ? Theme.gold.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .bottomTrailing) {
                if hovered {
                    KeyHints(hints: hints.filter { $0.key != KeyAction.fork.label }, highlighted: armedKey)
                        .padding(.horizontal, 10)
                        .background(Slant(amount: 6).fill(Theme.deep.opacity(0.9)))
                        .padding(.trailing, 18)
                }
            }
    }

    private func toolRow(name: String, detail: String?, description: String? = nil, running: Bool = false,
                         trailing: Bool = false, color: Color = Theme.cyan) -> some View {
        let tag = TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            Text(running ? "\(Self.spinner(at: timeline.date)) \(name)" : name)
        }
            .font(Theme.ui(13, weight: .black))
            .foregroundStyle(Theme.navy)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .background(Slant(amount: 7).fill(color))
        let command = detail.map {
            Text($0)
                .font(description == nil ? Theme.code : .system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        return HStack(alignment: description == nil ? .center : .firstTextBaseline, spacing: 10) {
            if trailing {
                Spacer(minLength: 100)
                command
                tag
            } else if let description {
                tag
                VStack(alignment: .leading, spacing: 2) {
                    Text(description).font(Theme.body).foregroundStyle(Theme.text).lineLimit(2)
                    command
                }
            } else {
                tag
                command
            }
        }
        .padding(trailing ? .trailing : .leading, 18)
        .textSelection(.enabled)
    }

    private static func spinner(at date: Date) -> Character {
        let frames = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
        return frames[Int(date.timeIntervalSinceReferenceDate * 10) % frames.count]
    }

    private func bubble<Content: View>(name: String, plate: Color, light: Bool, alignment: HorizontalAlignment,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: alignment, spacing: -8) {
            NamePlate(name: name, color: plate, shadowColor: forking ? Theme.amber : Theme.cyan, morphing: hovered)
                .padding(.horizontal, 18)
                .zIndex(1)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
                .panel(light: light, accent: forking || (hovered && !Theme.isStylized) ? Theme.gold : Theme.cyan, padding: 18, morphing: hovered, selected: hovered,
                       colors: forking ? [Theme.amberTop, Theme.amberBottom] : nil)
                .overlay(alignment: .bottomTrailing) {
                    KeyHints(hints: hints, highlighted: armedKey)
                        .padding(.horizontal, 10)
                        .background(Slant(amount: 6).fill(Theme.deep.opacity(0.9)))
                        .padding(.trailing, 18)
                        .offset(y: 10)
                }
                .fixedSize(horizontal: false, vertical: true)
        }
        .offset(x: forking ? (alignment == .trailing ? -24 : 24) : 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: forking)
    }
}

struct DialogueBox: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var session: Session
    var scroller: LogScroller
    @ObservedObject var navigator: Navigator
    @ViewState private var loading = false
    @FocusState private var focused: Bool
    @ViewState private var draftHeight: CGFloat = 0
    @ViewState private var historyIndex: Int?
    @ViewState private var stashedDraft = ""
    @ViewState private var mode = ClaudeBar.Mode.claude
    @ViewState private var exitArmed = false
    @AppStorage(Self.showSpriteKey) private var showSprite = false
    @ObservedObject private var sprites = SpriteSettings.shared

    static let showSpriteKey = "showSprite"
    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            if showSprite {
                VStack(spacing: -6) {
                    // The bust is taller than its layout slot so it rises over the log, like a VN character.
                    Portrait(mood: mood, outfit: session.outfit, model: session.model, pack: sprites.pack(for: session.model))
                        .frame(width: 210, height: 248)
                        .frame(width: 210, height: navigator.active ? 56 : 150, alignment: .bottom)
                        .allowsHitTesting(false)
                    NamePlate(name: "CLAUDE", morphing: true)
                }
                .frame(width: 210)
            } else {
                Color.clear.frame(width: 210, height: 0)
            }

            VStack(alignment: .leading, spacing: -8) {
                QueuedMessages(session: session)
                    .padding(.horizontal, 18)
                HStack(spacing: 10) {
                    HStack(spacing: 0) {
                        TimelineView(.periodic(from: .now, by: 0.4)) { timeline in
                            NamePlate(name: heading(at: timeline.date), color: plateColor, shadowColor: inTerminal ? .black : Theme.ocean,
                                      textColor: inTerminal ? .black : Theme.navy, morphing: true)
                        }
                        StatusLine(session: session)
                    }
                    attachments
                }
                .padding(.horizontal, 18)
                .zIndex(1)
                ZStack(alignment: .topLeading) {
                    if session.draft.isEmpty {
                        Text(placeholder)
                            .font(Theme.body)
                            .foregroundStyle(Theme.dim)
                            .padding(.leading, 5)
                    }
                    if let suggestion {
                        (Text(session.draft).foregroundStyle(.clear) + Text(suggestion).foregroundStyle(Theme.dim))
                            .font(draftFont)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    if session.awaitingSecret && inTerminal {
                        SecureField("", text: $session.draft)
                            .textFieldStyle(.plain)
                            .font(draftFont)
                            .foregroundStyle(plateColor)
                            .padding(.leading, 5)
                            .focused($focused)
                            .onSubmit(send)
                            .onAppear { focused = true }
                    } else {
                        TextEditor(text: $session.draft)
                            .font(draftFont)
                            .foregroundStyle(isShell ? plateColor : Theme.text)
                            .scrollContentBackground(.hidden)
                            .focused($focused)
                            .background(DraftKeys(session: session, onImagePaste: pasteImages, onBack: closeCommit))
                            .background(DraftFormatting(text: session.draft))
                            .onKeyPress(phases: [.down, .repeat], action: navigate)
                            .onKeyPress(phases: [.down, .repeat], action: choose)
                            .onKeyPress(phases: [.down, .repeat], action: input)
                            .onChange(of: session.prompt?.step) {
                                navigator.promptIndex = 0
                                navigator.typingAnswer = false
                            }
                            .onChange(of: session.draft) {
                                if let historyIndex, shownEntry != session.inputHistory[historyIndex] { self.historyIndex = nil }
                            }
                    }
                }
                .background(alignment: .topLeading) {
                    Text(session.draft + " ")
                        .font(draftFont)
                        .padding(.horizontal, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { draftHeight = $0 }
                }
                .padding(.top, 8)
                .frame(height: navigator.active ? 28 : min(max(draftHeight + 24, 112), 300))
                .clipped()
                .animation(.easeOut(duration: 0.15), value: navigator.active)
                .background(Theme.codeBackground.opacity(isShell && !inTerminal ? 0.9 : 0))
                .panel(accent: plateColor, dark: inTerminal, padding: 16, morphing: true)
                .overlay(alignment: .bottomTrailing) {
                    KeyHints(hints: navigationHints + [(KeyAction.label(.previousModel, .nextModel), "model"), (KeyAction.nextMode.label, "mode"),
                                                       (KeyAction.nextEffort.label, "effort"), (KeyAction.reset.label, "reset"), (KeyAction.load.label, "load")])
                        .padding(.horizontal, 10)
                        .background(Slant(amount: 6).fill(Theme.deep.opacity(0.9)))
                        .padding(.trailing, 18)
                        .offset(y: 10)
                }
                .animation(.easeOut(duration: 0.15), value: isShell)
            }

            CommandMenu(entries: menuEntries, compact: navigator.active)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .padding(.top, 6)
        .animation(.easeOut(duration: 0.15), value: navigator.active)
        .background(LinearGradient(colors: [.clear, Theme.deep.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        .onAppear { focused = true }
        .onChange(of: store.showingActions) { if !store.showingActions { focused = true } }
        // A focused input would take the keyboard back from the terminal.
        .onChange(of: session.showingTerminal) { focused = !session.showingTerminal }
        .onTapGesture { if session.isTalking { session.skipTyping() } }
        .sheet(isPresented: $loading) {
            LoadData(session: session)
                .environmentObject(store)
        }
    }

    private var navigationHints: [(key: String, action: String)] {
        let diffToggle = (KeyAction.toggleDiff.label, session.showingDiff ? "close diff" : "diff")
        let logToggle = (KeyAction.toggleLog.label, session.showingLog ? "close log" : "log")
        let diffControls = [(KeyAction.toggleDiffBase.label, session.diffBase == .unstaged ? "vs main" : "unstaged"), diffToggle, logToggle]
        let terminal = session.shell == nil ? [] : [(KeyAction.terminal.label, session.showingTerminal ? "type in terminal" : "terminal")]
            + (session.isRunningShell ? [(KeyAction.interrupt.label, "stop")] : [])
        let toggles = terminal + (session.showingDiff ? diffControls : [diffToggle, logToggle])
        if !navigator.active && isAnswering && navigator.typingAnswer { return [(KeyAction.navigate.label, "back to options")] + toggles }
        return toggles
    }

    private func closeCommit() -> Bool {
        guard navigator.active, session.openedCommit != nil else { return false }
        session.closeCommit()
        return true
    }

    private var menuEntries: [MenuEntry] {
        var entries: [MenuEntry] = []
        if session.isBusy {
            // The terminal key opens a running terminal command instead; the interrupt key still stops it.
            entries.append(MenuEntry(title: "STOP", index: session.prompt?.question != nil ? 1 : 0, color: Theme.red,
                                     shortcut: session.shell == nil ? KeyAction.terminal.keyboardShortcut : nil, action: session.stopClaude))
        }
        if session.isTalking {
            entries.append(MenuEntry(title: "SKIP", index: 1, action: session.skipTyping))
        }
        return entries
    }

    /// While the options of a prompt are focused they own the keyboard, so the input field neither types nor browses history.
    private var choosing: Bool { session.prompt != nil && !navigator.typingAnswer && !navigator.active }

    private func choose(_ press: KeyPress) -> KeyPress.Result {
        guard choosing, let prompt = session.prompt, !press.matches(.navigate), press.isPlain else { return .ignored }
        let entries = promptEntries(prompt, session: session, navigator: navigator)
        let index = min(navigator.promptIndex, entries.count - 1)
        switch press.action(in: .navigation) {
        case .up: navigator.promptIndex = max(index - 1, 0)
        case .down: navigator.promptIndex = min(index + 1, entries.count - 1)
        case .select: entries[index].action()
        default: break
        }
        return .handled
    }

    private func input(_ press: KeyPress) -> KeyPress.Result {
        let initial = press.phase == .down
        let browsing = choosing || navigator.active
        switch press.action(in: .chatInput) {
        case .send where initial && !browsing: send()
        case .interrupt where initial: interrupt()
        case .reset where initial: session.reset()
        case .load where initial: if !session.isBusy { loading = true }
        case .switchInput where initial && navigator.active:
            navigator.active = false
            mode = .terminal
        case .switchInput where initial && session.draft.isEmpty && !isAnswering: mode = mode == .claude ? .terminal : .claude
        case .scrollLeft: scroller.page(-1, horizontal: true)
        case .scrollRight: scroller.page(1, horizontal: true)
        case .acceptSuggestion where initial && !navigator.active:
            guard let suggestion else { return .ignored }
            session.draft += suggestion
        case .pageUp where !browsing: scroller.page(-1)
        case .pageDown where !browsing: scroller.page(1)
        case .olderHistory where !browsing: return olderHistory()
        case .newerHistory where !browsing: return newerHistory()
        default: return .ignored
        }
        return .handled
    }

    /// The navigate key toggles a mode where keys move a cursor over the diff and the message log instead of typing.
    private func navigate(_ press: KeyPress) -> KeyPress.Result {
        guard navigator.active else {
            guard press.matches(.navigate) else { return .ignored }
            if isAnswering && navigator.typingAnswer {
                navigator.typingAnswer = false
                return .handled
            }
            navigator.setMessage(session.boxedMessages.count - 1, in: session.boxedMessages)
            navigator.active = true
            return .handled
        }
        guard press.isPlain else { return .ignored }
        if press.matches(.back) || press.matches(.type) {
            navigator.active = false
            return .handled
        }
        if session.showingDiff || session.openedCommit != nil {
            _ = navigator.navigateDiff(press, in: session)
            return .handled
        }
        if session.showingLog {
            navigator.navigateLog(press, in: session)
            return .handled
        }
        let messages = session.boxedMessages
        switch press.action(in: .navigation, .messages) {
        case .down: navigator.moveMessage(by: 1, in: messages)
        case .up: navigator.moveMessage(by: -1, in: messages)
        case .top: navigator.setMessage(0, in: messages)
        case .bottom: navigator.jumpToLatest(in: messages)
        case .select:
            guard let message = navigator.message(in: messages), session.hasTerminal(message) else { break }
            navigator.active = false
            session.openTerminal(at: message.id)
        case .fork where press.phase == .down:
            guard let message = navigator.message(in: messages), !session.isTerminal(message) else { break }
            if navigator.forkArmed {
                store.fork(session, at: message)
                navigator.active = false
            } else {
                navigator.disarm()
                navigator.forkArmed = true
            }
        case .copy where press.phase == .down:
            guard let message = navigator.message(in: messages) else { break }
            if navigator.yankArmed {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.copyText(of: message), forType: .string)
                navigator.disarm()
            } else {
                navigator.disarm()
                navigator.yankArmed = true
            }
        default: break
        }
        return .handled
    }

    private func heading(at date: Date) -> String {
        if navigator.active { return "NAVIGATE" }
        if isAnswering { return "YOUR ANSWER" }
        if session.isBusy {
            let dots = Int(date.timeIntervalSinceReferenceDate / 0.4) % 4
            return "CLAUDE IS THINKING" + String(repeating: ".", count: dots) + String(repeating: "\u{2007}", count: 3 - dots)
        }
        if let historyIndex {
            return (inTerminal ? "TERMINAL " : "") + "HISTORY \(historyIndex + 1)/\(session.inputHistory.count)"
        }
        if inTerminal { return "TERMINAL" }
        return isShell ? "SHELL COMMAND" : "WHAT WILL YOU DO?"
    }

    private var placeholder: String {
        if exitArmed { return "Press ⌃c again to exit" }
        if session.showingTerminal { return "The terminal is open above  (⌘. to type in it)" }
        if navigator.active { return "Press i or escape to type (⇥ terminal)" }
        if session.awaitingSecret && inTerminal { return "Type the password…  (⏎ send · ⌃c stop)" }
        if session.isRunningShell && inTerminal { return "Type input for the running command…  (⏎ send · ⌃c stop · ⌘. open terminal)" }
        if session.isRunningShell { return "Speak to Claude while the command runs…  (⇥ to type into it · ⌘. open terminal · ⌃c stop)" }
        if inTerminal { return "Run a command in the terminal…  (⇥ back to Claude)" }
        return "Speak to Claude…  (⏎ send · ⇧⏎ newline · ! shell · ⇥ terminal · esc navigate)"
    }

    private var plateColor: Color {
        if inTerminal { return Theme.green }
        return isShell ? Theme.gold : Theme.cyan
    }

    /// Arrow keys only recall history while they'd have nowhere to move the cursor: a single-line draft,
    /// or an untouched recalled entry.
    private var canBrowseHistory: Bool {
        historyIndex != nil || !session.draft.contains("\n")
    }

    private func olderHistory() -> KeyPress.Result {
        let history = session.inputHistory
        guard canBrowseHistory, !history.isEmpty else { return .ignored }
        if let historyIndex {
            self.historyIndex = max(historyIndex - 1, 0)
        } else {
            stashedDraft = shownEntry
            historyIndex = history.count - 1
        }
        show(history[historyIndex!])
        return .handled
    }

    private func newerHistory() -> KeyPress.Result {
        guard let historyIndex else { return .ignored }
        if historyIndex < session.inputHistory.count - 1 {
            self.historyIndex = historyIndex + 1
            show(session.inputHistory[historyIndex + 1])
        } else {
            self.historyIndex = nil
            show(stashedDraft)
        }
        return .handled
    }

    /// The draft as it would be sent, so a recalled terminal command comes back in terminal mode.
    private var shownEntry: String {
        (mode == .terminal ? Session.terminalMarker : "") + session.expandedDraft
    }

    private func show(_ entry: String) {
        mode = entry.hasPrefix(Session.terminalMarker) ? .terminal : .claude
        session.draft = mode == .terminal ? String(entry.dropFirst()) : entry
    }

    private var suggestion: String? {
        guard !isAnswering, historyIndex == nil else { return nil }
        return session.suggestion(for: session.draft, inTerminal: mode == .terminal)
    }

    private var draftFont: Font { isShell ? .system(size: 14, design: .monospaced) : Theme.body }

    private var inTerminal: Bool { mode == .terminal && !isAnswering }
    private var isShell: Bool { inTerminal || session.draft.hasPrefix("!") }
    private var isAnswering: Bool { session.prompt?.question != nil }

    private var mood: Mood {
        if session.isTalking { return .talking }
        if session.isBusy { return .thinking }
        return session.messages.last?.speaker == .system ? .worried : .idle
    }

    /// Stops what the input is aimed at: the command from terminal mode, otherwise Claude, falling back to whichever is running.
    private func interrupt() {
        if session.isRunningShell && (inTerminal || !session.isBusy) {
            session.stopTerminal()
        } else if session.isBusy {
            session.stopClaude()
        } else if !session.draft.isEmpty {
            session.draft = ""
        } else if exitArmed {
            NSApplication.shared.terminate(nil)
        } else {
            exitArmed = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                exitArmed = false
            }
            return
        }
        exitArmed = false
    }

    private var attachments: some View {
        HStack(spacing: 6) {
            ForEach(Array(session.images.enumerated()), id: \.offset) { index, data in
                if let image = NSImage(data: data) {
                    AttachmentThumbnail(image: image, preview: { store.previewImage = image }, remove: { session.images.remove(at: index) })
                }
            }
        }
    }

    private func pasteImages() {
        guard let images = NSPasteboard.general.readObjects(forClasses: [NSImage.self]) as? [NSImage] else { return }
        session.images += images.compactMap { image in
            image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
        }
    }

    private func send() {
        if session.isRunningShell && inTerminal {
            session.sendInput(session.expandedDraft)
            session.draft = ""
            return
        }
        guard !session.draft.trimmed.isEmpty || (!session.images.isEmpty && !inTerminal) else { return }
        if isAnswering {
            guard !session.draft.trimmed.isEmpty else { return }
            session.reply(session.expandedDraft.trimmed)
        } else if !session.send(inTerminal ? shownEntry : session.expandedDraft) {
            return
        }
        session.draft = ""
    }
}

/// Messages waiting for the current turn to finish. The oldest, or all of them, can be sent into the turn now, and
/// each can be cancelled.
struct QueuedMessages: View {
    @ObservedObject var session: Session

    var body: some View {
        ForEach(Array(session.queued.enumerated()), id: \.element.id) { index, message in
            HStack(spacing: 8) {
                Text("QUEUED").font(Theme.ui(11, weight: .black)).foregroundStyle(Theme.gold)
                Text(message.text).lineLimit(1).foregroundStyle(Theme.dim)
                Spacer(minLength: 0)
                if index == 0 {
                    Button { session.sendQueuedNow(all: false) } label: { Text("SEND NOW").foregroundStyle(Theme.gold) }
                        .buttonStyle(.plain)
                        .help("Send into the current turn")
                    if session.queued.count > 1 {
                        Button { session.sendQueuedNow(all: true) } label: { Text("SEND ALL").foregroundStyle(Theme.gold) }
                            .buttonStyle(.plain)
                            .help("Send every queued message into the current turn")
                    }
                }
                Button { session.cancelQueued(message.id) } label: { Text("×").foregroundStyle(Theme.dim) }
                    .buttonStyle(.plain)
                    .help("Cancel")
            }
        }
    }
}

struct KeyHints: View {
    var hints: [(key: String, action: String)]
    var highlighted: String?

    var body: some View {
        FlowLayout(spacing: 10, lineSpacing: 4) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                HStack(spacing: 4) {
                    Text(hint.key)
                        .foregroundStyle(Theme.navy)
                        .padding(.horizontal, 5)
                        .background(hint.key == highlighted ? Theme.gold : Theme.ice, in: RoundedRectangle(cornerRadius: 3))
                    Text(hint.action).foregroundStyle(hint.key == highlighted ? Theme.gold : Theme.dim)
                }
            }
        }
        .font(Theme.ui(11, weight: .bold))
        .allowsHitTesting(false)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrange(in: bounds.width, subviews).origins
        for (subview, origin) in zip(subviews, origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(in width: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width
            maxX = max(maxX, x)
            x += spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (origins, CGSize(width: maxX, height: y + lineHeight))
    }
}

private struct MenuEntry: Identifiable {
    var title: String
    var index: Int
    var color: Color = Theme.ice
    var shortcut: KeyboardShortcut?
    var help = ""
    var checked: Bool?
    var action: () -> Void
    var id: String { title }
}

private struct MenuList: View {
    var entries: [MenuEntry]
    var highlighted: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { position, entry in
                MenuItem(title: entry.title, index: entry.index, color: entry.color, shortcut: entry.shortcut,
                         highlighted: position == highlighted.map { min($0, entries.count - 1) }, action: entry.action)
                    .help(entry.help)
            }
        }
    }
}

private struct CommandMenu: View {
    var entries: [MenuEntry]
    var compact = false

    var body: some View {
        MenuList(entries: entries)
            .frame(width: 150, alignment: .leading)
            .frame(minHeight: compact ? 0 : 128, alignment: .center)
    }
}

@MainActor
private func promptEntries(_ prompt: PermissionPrompt, session: Session, navigator: Navigator) -> [MenuEntry] {
    if let question = prompt.question {
        var entries = question.options.enumerated().map { index, option in
            MenuEntry(title: option.label, index: index, help: option.description,
                      checked: question.multiSelect ? prompt.selected.contains(option.label) : nil) {
                if question.multiSelect { session.toggle(option.label) } else { session.reply(option.label) }
            }
        }
        if question.multiSelect {
            entries.append(MenuEntry(title: "Submit", index: entries.count, color: Theme.green,
                                     help: "Send the checked options") { session.submitSelection() })
        }
        return entries + [MenuEntry(title: "Type your own answer", index: entries.count, color: Theme.aqua,
                                    help: "Write your own answer in the input field") { navigator.typingAnswer = true }]
    }
    var entries = [MenuEntry(title: "Allow", index: 0) { session.answer(prompt, allow: true) }]
    if !prompt.suggestions.isEmpty {
        entries.append(MenuEntry(title: "Always allow", index: 1, color: Theme.aqua, help: "Allow and remember this rule") {
            session.answer(prompt, allow: true, always: true)
        })
    }
    return entries + [MenuEntry(title: "Deny", index: 2, color: Theme.red) { session.answer(prompt, allow: false) }]
}

private struct LoadData: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var session: Session
    @ViewState private var saves: [SavedSession]?
    @ViewState private var selected = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: -8) {
            NamePlate(name: "LOAD DATA", color: Theme.cyan)
                .padding(.horizontal, 18)
                .zIndex(1)
            Group {
                if let saves, saves.isEmpty {
                    Text("No saved sessions found.")
                        .foregroundStyle(Theme.dim)
                } else if let saves {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(saves) { save in
                                    Button { load(save) } label: {
                                        SaveRow(save: save, isCurrent: save.id == session.sessionId, isSelected: save.id == selectedSave?.id)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .onChange(of: selected) {
                            if let id = selectedSave?.id { proxy.scrollTo(id) }
                        }
                    }
                } else {
                    ProgressView("Reading save data…")
                }
            }
            .font(Theme.body)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 6)
            .panel(padding: 18, opacity: 1)
            .overlay(alignment: .bottomTrailing) {
                KeyHints(hints: [(KeyAction.label(.down, .up), "choose"), (KeyAction.select.label, "load"), ("ESC", "close")])
                    .padding(.horizontal, 10)
                    .background(Slant(amount: 6).fill(Theme.deep.opacity(0.9)))
                    .padding(.trailing, 18)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .background(Theme.deep)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: { Chip { Text("CLOSE") } }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .padding(24)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat], action: select)
        .task {
            focused = true
            saves = await Task.detached { SaveData.list() }.value
        }
    }

    private var selectedSave: SavedSession? {
        guard let saves, !saves.isEmpty else { return nil }
        return saves[min(selected, saves.count - 1)]
    }

    private func select(_ press: KeyPress) -> KeyPress.Result {
        guard let saves, let save = selectedSave else { return .ignored }
        switch press.action(in: .navigation) {
        case .up: selected = max(selected - 1, 0)
        case .down: selected = min(selected + 1, saves.count - 1)
        case .select: load(save)
        default: return .ignored
        }
        return .handled
    }

    /// A session already open in another tab is switched to rather than duplicated.
    private func load(_ save: SavedSession) {
        SaveData.markOpened(save.id)
        if let open = store.sessions.first(where: { $0.sessionId == save.id }) {
            store.selectedId = open.id
        } else {
            session.load(save)
        }
        dismiss()
    }
}

private struct SaveRow: View {
    var save: SavedSession
    var isCurrent: Bool
    var isSelected: Bool
    @ViewState private var isHovered = false
    private var isHighlighted: Bool { isHovered || isSelected }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(save.title)
                .font(Theme.ui(15, weight: .bold))
                .foregroundStyle(isHighlighted ? Theme.navy : Theme.ice)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(save.directory.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                if isCurrent { Text("▶ THIS TAB") }
                Text(save.updated, format: .relative(presentation: .named))
            }
            .font(Theme.ui(12))
            .foregroundStyle(isHighlighted ? Theme.navy.opacity(0.7) : Theme.dim)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Slant(amount: 8).fill(isHighlighted ? Theme.ice : .clear))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

private struct PermissionBox: View {
    @ObservedObject var session: Session
    @ObservedObject var navigator: Navigator
    var prompt: PermissionPrompt

    private var highlighted: Int? {
        !navigator.typingAnswer && !navigator.active ? navigator.promptIndex : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: -8) {
            NamePlate(name: title, color: accent, shadowColor: Theme.ocean)
                .padding(.horizontal, 18)
                .zIndex(1)
            VStack(alignment: .leading, spacing: 12) {
                if let question = prompt.question {
                    questionBody(question)
                } else {
                    permissionBody
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .panel(accent: accent, padding: 18)
            .overlay(alignment: .bottomTrailing) {
                if highlighted != nil {
                    KeyHints(hints: [(KeyAction.label(.down, .up), "choose"), (KeyAction.select.label, prompt.question?.multiSelect == true ? "check" : "select")])
                        .padding(.horizontal, 10)
                        .background(Slant(amount: 6).fill(Theme.deep.opacity(0.9)))
                        .padding(.trailing, 18)
                        .offset(y: 10)
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .animation(Theme.isTerminal ? nil : .easeInOut(duration: Theme.isStylized ? 0.35 : 0.15), value: navigator.active)
    }

    private var accent: Color { navigator.active ? Theme.cyan : Theme.gold }

    private var title: String {
        guard let question = prompt.question else { return "USE \(prompt.tool.uppercased())?" }
        let progress = prompt.questions.count > 1 ? "  \(prompt.answers.count + 1)/\(prompt.questions.count)" : ""
        return (question.header.isEmpty ? "QUESTION" : question.header.uppercased()) + progress
    }

    @ViewBuilder
    private func questionBody(_ question: PermissionPrompt.Question) -> some View {
        Text(question.text)
            .font(Theme.body)
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
        OptionList(entries: promptEntries(prompt, session: session, navigator: navigator), highlighted: highlighted)
    }

    @ViewBuilder
    private var permissionBody: some View {
        if !prompt.detail.isEmpty {
            Text(prompt.detail)
                .font(Theme.code)
                .foregroundStyle(Theme.dim)
                .lineLimit(4)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        OptionList(entries: promptEntries(prompt, session: session, navigator: navigator), highlighted: highlighted)
    }
}

private struct OptionList: View {
    var entries: [MenuEntry]
    var highlighted: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { position, entry in
                OptionRow(entry: entry, highlighted: position == highlighted.map { min($0, entries.count - 1) })
            }
        }
    }
}

private struct OptionRow: View {
    var entry: MenuEntry
    var highlighted: Bool
    @ViewState private var hovered = false
    private var isActive: Bool { hovered || highlighted }

    var body: some View {
        Button(action: entry.action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.checked.map { $0 ? "☑" : "☐" } ?? (isActive ? "▶" : "○"))
                    .foregroundStyle(isActive ? Theme.gold : Theme.dim)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .foregroundStyle(isActive ? Theme.gold : entry.color)
                    if !entry.help.isEmpty {
                        Text(entry.help)
                            .font(Theme.ui(12, weight: .regular))
                            .foregroundStyle(Theme.dim)
                    }
                }
            }
            .font(Theme.body)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Items step rightward down the list, and the hovered one flips to a solid bar that slides out.
private struct MenuItem: View {
    var title: String
    var index: Int
    var color: Color = Theme.ice
    var shortcut: KeyboardShortcut?
    var highlighted = false
    var action: () -> Void
    @ViewState private var hovered = false
    private var isHovered: Bool { hovered || highlighted }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.display(26))
                .foregroundStyle(isHovered ? Theme.navy : color)
                .padding(.horizontal, 14)
                .background(ActiveBackdrop(active: isHovered, amount: 10))
                .shadow(color: Theme.cyan.opacity(isHovered ? 0 : 0.5), radius: 0, x: 2, y: 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .activeShift(isHovered, offset: 8)
        .offset(x: CGFloat(index) * 10)
        .onHover { hovered = $0 }
        .keyboardShortcut(shortcut)
    }
}

private struct AttachmentThumbnail: View {
    var image: NSImage
    var preview: () -> Void
    var remove: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .onTapGesture(perform: preview)
            .overlay(alignment: .bottom) {
                if hovered {
                    Button("Remove", action: remove)
                        .buttonStyle(.plain)
                        .font(Theme.ui(9, weight: .black))
                        .foregroundStyle(Theme.ice)
                        .frame(maxWidth: .infinity)
                        .background(Theme.deep.opacity(0.9))
                }
            }
            .onHover { hovered = $0 }
    }
}

/// TextEditor wraps an NSTextView that handles its keys itself, so onPasteCommand and onKeyPress never see these; catch them first.
/// ⌘V with an image and no text attaches it, and with long text pastes a placeholder. The placeholder then acts as one character
/// for ⌫, ⌦ and the arrow keys.
private struct DraftKeys: NSViewRepresentable {
    var session: Session
    var onImagePaste: () -> Void
    var onBack: () -> Bool

    func makeNSView(context: Context) -> NSView { Probe() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Probe)?.session = session
        (view as? Probe)?.onImagePaste = onImagePaste
        (view as? Probe)?.onBack = onBack
    }

    private final class Probe: NSView {
        var session: Session?
        var onImagePaste: () -> Void = {}
        var onBack: () -> Bool = { false }
        private var monitor: Any?

        deinit { monitor.map(NSEvent.removeMonitor) }

        override func viewDidMoveToWindow() {
            monitor.map(NSEvent.removeMonitor)
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === window else { return event }
                return MainActor.assumeIsolated { self.handle(event) ? nil : event }
            }
        }

        @MainActor
        private func handle(_ event: NSEvent) -> Bool {
            guard let session, let view = window?.firstResponder as? NSTextView, view.string == session.draft else { return false }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers == .command, event.charactersIgnoringModifiers == "v" { return paste(into: view, session) }
            if let shortcut = Shortcut(event), Keymap.shared.shortcuts(for: .backToLog).contains(shortcut), onBack() { return true }
            let cursor = view.selectedRange()
            guard cursor.length == 0 else { return false }
            let placeholders = Session.placeholderPattern.matches(in: view.string, range: NSRange(location: 0, length: (view.string as NSString).length)).map(\.range)
            switch event.keyCode {
            case 51:
                guard let range = placeholders.first(where: { $0.location < cursor.location && cursor.location <= NSMaxRange($0) }) else { return false }
                view.insertText("", replacementRange: range)
            case 117:
                guard let range = placeholders.first(where: { $0.location <= cursor.location && cursor.location < NSMaxRange($0) }) else { return false }
                view.insertText("", replacementRange: range)
            case 123 where modifiers.subtracting([.function, .numericPad]).isEmpty:
                guard let range = placeholders.first(where: { $0.location < cursor.location && cursor.location <= NSMaxRange($0) }) else { return false }
                view.setSelectedRange(NSRange(location: range.location, length: 0))
            case 124 where modifiers.subtracting([.function, .numericPad]).isEmpty:
                guard let range = placeholders.first(where: { $0.location <= cursor.location && cursor.location < NSMaxRange($0) }) else { return false }
                view.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
            default:
                return false
            }
            return true
        }

        @MainActor
        private func paste(into view: NSTextView, _ session: Session) -> Bool {
            let pasteboard = NSPasteboard.general
            guard let text = pasteboard.string(forType: .string) else {
                guard pasteboard.canReadObject(forClasses: [NSImage.self]) else { return false }
                onImagePaste()
                return true
            }
            let shown = session.pasted(text)
            guard shown != text else { return false }
            view.insertText(shown, replacementRange: view.selectedRange())
            return true
        }
    }
}

/// SwiftUI's TextEditor has no switch for smart quotes and dashes, so reach the NSTextViews in the window.
private struct DraftFormatting: NSViewRepresentable {
    // Unused, but changing it makes SwiftUI call updateNSView when the draft is set programmatically.
    var text: String

    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.apply() }

    private final class Probe: NSView {
        private static let styled = NSAttributedString.Key("draftStyled")
        private static let patterns: [(regex: NSRegularExpression, code: Bool, bold: Bool)] = [
            ("^#+ .*", false, true), ("\\*\\*[^*\\n]+\\*\\*", false, true),
            ("`[^`\\n]+`", true, false), ("```[\\s\\S]*?(```|$)", true, false),
        ].map { (try! NSRegularExpression(pattern: $0.0, options: .anchorsMatchLines), $0.1, $0.2) }

        private var observer: NSObjectProtocol?
        private var base: (font: NSFont, color: NSColor)?

        deinit { observer.map(NotificationCenter.default.removeObserver) }

        override func viewDidMoveToWindow() {
            observer = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: nil, queue: .main) { [weak self] note in
                guard let view = note.object as? NSTextView, view.window === self?.window else { return }
                self?.format(view)
            }
            apply()
        }

        func apply() {
            DispatchQueue.main.async { [weak self] in
                self?.window?.contentView?.textViews.forEach {
                    $0.isAutomaticQuoteSubstitutionEnabled = false
                    $0.isAutomaticDashSubstitutionEnabled = false
                    self?.format($0)
                }
            }
        }

        private func format(_ view: NSTextView) {
            guard let storage = view.textStorage, storage.length > 0 else { return }
            let all = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(Self.styled, in: all) { value, range, stop in
                guard value == nil, let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont,
                      let color = storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor else { return }
                base = (font, color)
                stop.pointee = true
            }
            guard let base else { return }
            let code = NSFont.monospacedSystemFont(ofSize: base.font.pointSize - 2, weight: .regular)
            let bold = NSFontManager.shared.convert(base.font, toHaveTrait: .boldFontMask)
            storage.beginEditing()
            storage.removeAttribute(Self.styled, range: all)
            storage.addAttributes([.font: base.font, .foregroundColor: base.color], range: all)
            for pattern in Self.patterns {
                for match in pattern.regex.matches(in: storage.string, range: all) {
                    var attributes: [NSAttributedString.Key: Any] = [Self.styled: true]
                    if pattern.bold { attributes[.font] = bold }
                    if pattern.code { attributes[.font] = code; attributes[.foregroundColor] = NSColor(Theme.cyan) }
                    storage.addAttributes(attributes, range: match.range)
                }
            }
            storage.endEditing()
        }
    }
}

private extension NSView {
    var textViews: [NSTextView] {
        (self as? NSTextView).map { [$0] } ?? subviews.flatMap(\.textViews)
    }
}
