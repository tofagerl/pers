import SwiftUI

/// A saved HTTP request, filed under the repo it was made for.
struct APIRequest: Codable, Identifiable, Equatable {
    var id = UUID()
    var repo: String
    var name = ""
    var method = "GET"
    var url = ""
    /// `Name: value` lines. Values go through the shell when they contain `$`, so `$(secret …)` keeps tokens out of the save file.
    var headers = ""
    var body = ""

    static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    var title: String { name.trimmed.isEmpty ? (url.trimmed.isEmpty ? "Untitled request" : url.trimmed) : name.trimmed }
    var sendsBody: Bool { method != "GET" && method != "HEAD" }

    @MainActor
    func send() async -> APIResponse {
        guard let url = URL(string: url.trimmed), url.scheme != nil else { return APIResponse(error: "Not a valid URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for line in await expandedHeaders().split(separator: "\n") where !line.trimmed.hasPrefix("#") {
            let parts = line.split(separator: ":", maxSplits: 1).map(\.trimmed)
            if parts.count == 2 { request.setValue(parts[1], forHTTPHeaderField: parts[0]) }
        }
        if sendsBody, !body.isEmpty { request.httpBody = Data(body.utf8) }
        let start = ContinuousClock.now
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let headers = (http?.allHeaderFields ?? [:]).map { "\($0.key): \($0.value)" }.sorted()
            return APIResponse(status: http?.statusCode, duration: ContinuousClock.now - start, size: data.count,
                               headers: headers, body: String(decoding: data, as: UTF8.self))
        } catch {
            return APIResponse(duration: ContinuousClock.now - start, error: error.localizedDescription)
        }
    }

    @MainActor
    private func expandedHeaders() async -> String {
        guard headers.contains("$") else { return headers }
        let process = Session.shellProcess("cat <<__HEADERS__\n\(headers)\n__HEADERS__", in: repo)
        let out = Pipe()
        process.standardOutput = out
        return await Task.detached {
            guard (try? process.run()) != nil else { return "" }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

extension APIRequest {
    /// Claude writes these by hand and tends to leave out empty fields.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        repo = try container.decode(String.self, forKey: .repo)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        method = try container.decodeIfPresent(String.self, forKey: .method) ?? "GET"
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        headers = try container.decodeIfPresent(String.self, forKey: .headers) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
    }
}

/// Kept per request, on disk too, so the last response is still there after leaving the page or restarting.
struct APIResponse: Codable {
    var id = UUID()
    var status: Int?
    var duration: Duration = .zero
    var size = 0
    /// `Name: value` lines.
    var headers: [String] = []
    var body = ""
    var error: String?

    private enum CodingKeys: String, CodingKey { case status, duration, size, headers, body, error }

    var rows: [ResponseRow] { ResponseRow.make(from: body) }

    var color: Color {
        switch status ?? 0 {
        case 200..<300: Theme.green
        case 300..<400: Theme.cyan
        case 400..<500: Theme.gold
        default: Theme.red
        }
    }
}

extension AppStore {
    /// Repos with open tabs, folders made from the terminal and repos that only have saved requests, sorted by folder name.
    var requestFolders: [String] {
        (repos.map(\.path) + savedFolders + requests.map(\.repo)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .sorted { ($0 as NSString).lastPathComponent.localizedCaseInsensitiveCompare(($1 as NSString).lastPathComponent) == .orderedAscending }
    }

    func openFolder(_ path: String?) {
        requestFolder = path
        selectedRequestId = requests.first { $0.repo == path }?.id
    }

    func createFolder(_ path: String) {
        if !savedFolders.contains(path) { savedFolders.append(path) }
        openFolder(path)
    }

    /// Steps through requests across folders like ⌘1 2 step through tabs, stopping on empty folders too.
    func cycleRequest(by offset: Int) {
        let stops = requestFolders.flatMap { folder -> [(folder: String, request: UUID?)] in
            let ids = requests.filter { $0.repo == folder }.map(\.id)
            return ids.isEmpty ? [(folder, nil)] : ids.map { (folder, $0) }
        }
        guard !stops.isEmpty else { return }
        let index = stops.firstIndex { $0.folder == requestFolder && $0.request == selectedRequestId }
            ?? stops.firstIndex { $0.folder == requestFolder } ?? 0
        let stop = stops[(index + offset + stops.count) % stops.count]
        requestFolder = stop.folder
        selectedRequestId = stop.request
    }

    func cycleFolder(by offset: Int) {
        let folders = requestFolders
        guard !folders.isEmpty else { return }
        let index = folders.firstIndex { $0 == requestFolder } ?? 0
        openFolder(folders[(index + offset + folders.count) % folders.count])
    }

    /// A request that shows up in the file, usually one Claude just wrote, is opened.
    func loadRequests() {
        guard let data = try? Data(contentsOf: Self.requestsURL),
              let saved = try? JSONDecoder().decode([APIRequest].self, from: data),
              saved != requests else { return }
        let added = saved.last { request in !requests.contains { $0.id == request.id } }
        requests = saved
        if let added {
            requestFolder = added.repo
            selectedRequestId = added.id
        }
    }

    func loadResponses() {
        guard let data = try? Data(contentsOf: Self.responsesURL),
              let saved = try? JSONDecoder().decode([APIRequest.ID: APIResponse].self, from: data) else { return }
        responses = saved.filter { id, _ in requests.contains { $0.id == id } }
    }

    func saveResponses() {
        guard let data = try? JSONEncoder().encode(responses) else { return }
        try? data.write(to: Self.responsesURL, options: .atomic)
    }

    /// Pretty-printed so Claude can edit it a request at a time.
    func saveRequests() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(requests) else { return }
        try? data.write(to: Self.requestsURL, options: .atomic)
    }

    func setUpRequestSession() {
        requestSession.extraArguments = { [unowned self] in
            ["--add-dir", Self.requestsURL.deletingLastPathComponent().path, "--append-system-prompt", requestsPrompt]
        }
        // The save folder watcher only sees files that are replaced, and Claude may edit in place, so each finished turn reloads too.
        requestTurnSubscription = requestSession.$isBusy.removeDuplicates().filter { !$0 }.sink { [weak self] _ in self?.loadRequests() }
        // Opening the page moves the session to the last tab's repo, which is already the open folder and shouldn't be saved.
        requestFolderSubscription = requestSession.$git.compactMap { $0?.repoPath }.removeDuplicates().sink { [weak self] path in
            guard let self, path != requestFolder else { return }
            createFolder(path)
        }
    }

    private var requestsPrompt: String {
        """
        You're working in Pers's API tester. Its saved requests are in \(Self.requestsURL.path): a JSON array of \
        objects with "id" (a UUID string), "repo", "name", "method", "url", "headers" (newline-separated "Name: value" lines) \
        and "body" (a string). Requests are grouped into folders by "repo", the absolute path of a repo's main checkout; the \
        open folder is \(requestFolder ?? requestSession.repoPath). To create or change requests, edit that file and keep every \
        other entry; the app picks up the change as soon as the file is written. Read this repo's code to find endpoints, \
        ports and payloads. Never write secret values into headers: use a shell lookup such as $(secret get …), which the \
        app expands when sending.
        """
    }
}

enum RequestField: Hashable {
    case page, name, url, headers, body, search, ask
}

struct APITester: View {
    enum Pane { case requests, response }
    enum Yank { case selection, whole }

    @EnvironmentObject var store: AppStore
    @StateObject private var browser = ResponseBrowser()
    @ViewState private var sending: Set<APIRequest.ID> = []
    @ViewState private var pane = Pane.requests
    @ViewState private var deleteArmed = false
    @ViewState private var yankArmed: Yank?
    @ViewState private var askMode = ClaudeBar.Mode.claude
    @ViewState private var dismissedReply = 0
    @FocusState private var focused: RequestField?

    private var selectedIndex: Int? { store.requests.firstIndex { $0.id == store.selectedRequestId } }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            sidebar.frame(width: SessionOverview.width)
            VStack(spacing: 14) {
                if let index = selectedIndex {
                    let request = store.requests[index]
                    RequestEditor(request: $store.requests[index], sending: sending.contains(request.id),
                                  selected: pane == .requests, focus: $focused,
                                  send: { send(request) }, delete: { delete(request) })
                        .id(request.id)
                    if let response = store.responses[request.id] {
                        ResponseView(response: response, browser: browser, selected: pane == .response, yankArmed: yankArmed,
                                     focus: $focused, browse: { pane = .response; focused = .page })
                    } else {
                        Spacer(minLength: 0)
                    }
                } else {
                    Text(store.requestFolder == nil ? "Go to a repo in the terminal (\(KeyAction.askTerminal.label)) to make a folder for it." : "Pick a request, or make a new one.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(.top, 34)
        .padding(.horizontal, SessionOverview.leadingInset)
        .focusable()
        .focused($focused, equals: .page)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat], action: handle)
        .onExitCommand { if focused != .page { focused = .page } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ClaudeBar(session: store.requestSession, mode: askMode, focus: $focused, dismissed: $dismissedReply,
                      hints: hints, highlighted: armedKey)
        }
        .onAppear {
            store.requestSession.directory = store.selected?.directory ?? NSHomeDirectory()
            store.openFolder(store.selected?.repoPath ?? store.requestFolders.first)
            browser.show(selectedIndex.flatMap { store.responses[store.requests[$0].id] })
            dismissedReply = store.requestSession.messages.count
            focused = .page
        }
        .onChange(of: store.selectedRequestId) { browser.show(store.selectedRequestId.flatMap { store.responses[$0] }) }
    }

    private var armedKey: String? {
        if deleteArmed { return KeyAction.deleteRequest.label }
        return yankArmed.map { $0 == .selection ? KeyAction.copy.label : KeyAction.copyAll.label }
    }

    private var hints: [(key: String, action: String)] {
        switch focused {
        case .page where pane == .requests, nil where pane == .requests:
            return [(KeyAction.label(.down, .up), "request"), (KeyAction.label(.nextGroup, .previousGroup), "folder"), (KeyAction.select.label, "send"),
                    (KeyAction.editURL.label, "url"), (KeyAction.renameRequest.label, "name"), (KeyAction.editHeaders.label, "headers"),
                    (KeyAction.editBody.label, "body"), (KeyAction.cycleMethod.label, "method"), (KeyAction.newRequest.label, "new"),
                    (KeyAction.deleteRequest.label, deleteArmed ? "again to delete" : "delete"), (KeyAction.switchPane.label, "response")] + paneHints
        case .page, nil:
            let copy = KeyAction.copy.label, copyAll = KeyAction.copyAll.label
            return [(KeyAction.label(.down, .up), "row"), (KeyAction.label(.top, .bottom), "top/end"), (KeyAction.label(.select, .toggleNode), "expand"),
                    (KeyAction.label(.collapse, .expand), "fold"), (KeyAction.label(.expandAll, .collapseAll), "all"), (KeyAction.search.label, "search"),
                    (copy, yankArmed == .selection ? "press \(copy) again to yank selection" : "yank"),
                    (copyAll, yankArmed == .whole ? "press \(copyAll) again to yank all" : "yank all"),
                    (KeyAction.label(.nextMatch, .previousMatch), "match"), (KeyAction.toggleHeaders.label, "headers"),
                    (KeyAction.switchPane.label, "request")] + paneHints
        case .search:
            return [("⏎", "browse"), ("ESC", "back")]
        default:
            return [(KeyAction.sendRequest.label, "send"), ("ESC", "back")]
        }
    }

    private var paneHints: [(key: String, action: String)] {
        [(KeyAction.askClaude.label, "claude"), (KeyAction.askTerminal.label, "terminal"), (KeyAction.backToChat.label, "chat")]
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if let field = focused, field != .page {
            guard press.key == .escape else { return .ignored }
            focused = .page
            return .handled
        }
        let armed = deleteArmed
        let armedYank = yankArmed
        deleteArmed = false
        yankArmed = nil
        let initial = press.phase == .down
        let session = store.requestSession
        let permission = session.prompt.flatMap { $0.question == nil ? $0 : nil }
        switch press.action(in: .permission, .apiTester, .navigation) {
        case .allow where initial && permission != nil: session.answer(permission!, allow: true)
        case .allowAlways where initial && permission?.suggestions.isEmpty == false: session.answer(permission!, allow: true, always: true)
        case .deny where initial && permission != nil: session.answer(permission!, allow: false)
        case .back where initial:
            if pane == .response && !browser.query.isEmpty { browser.query = "" } else { dismissedReply = session.messages.count }
        case .switchPane where initial: pane = pane == .requests ? .response : .requests
        case .askClaude where initial: ask(.claude)
        case .askTerminal where initial: ask(.terminal)
        case .backToChat where initial: store.page = .sessions
        case .stop where initial && (session.isBusy || session.isRunningShell): session.stop()
        default: return pane == .requests ? requestKey(press, deleteArmed: armed) : responseKey(press, yankArmed: armedYank)
        }
        return .handled
    }

    private func requestKey(_ press: KeyPress, deleteArmed armed: Bool) -> KeyPress.Result {
        let initial = press.phase == .down
        let request = selectedIndex.map { store.requests[$0] }
        switch press.action(in: .navigation, .apiRequests) {
        case .down: store.cycleRequest(by: 1)
        case .up: store.cycleRequest(by: -1)
        case .nextGroup where initial: store.cycleFolder(by: 1)
        case .previousGroup where initial: store.cycleFolder(by: -1)
        case .select where initial: if let request { send(request) }
        case .editURL where initial: if request != nil { focused = .url }
        case .renameRequest where initial: if request != nil { focused = .name }
        case .editHeaders where initial: if request != nil { focused = .headers }
        case .editBody where initial: if request?.sendsBody == true { focused = .body }
        case .cycleMethod where initial:
            guard let index = selectedIndex, let method = APIRequest.methods.firstIndex(of: store.requests[index].method) else { break }
            store.requests[index].method = APIRequest.methods[(method + 1) % APIRequest.methods.count]
        case .newRequest where initial: if let folder = store.requestFolder { create(in: folder) }
        case .deleteRequest where initial:
            guard let request else { break }
            if armed { delete(request) } else { deleteArmed = true }
        default: return .ignored
        }
        return .handled
    }

    private func responseKey(_ press: KeyPress, yankArmed armed: Yank?) -> KeyPress.Result {
        let initial = press.phase == .down
        switch press.action(in: .navigation, .apiResponse) {
        case .down: browser.move(by: 1)
        case .up: browser.move(by: -1)
        case .top where initial: browser.moveToEdge(end: false)
        case .bottom where initial: browser.moveToEdge(end: true)
        case .select where initial, .toggleNode where initial: browser.toggle()
        case .expand: browser.expand()
        case .collapse: browser.collapse()
        case .expandAll where initial: browser.expandAll()
        case .collapseAll where initial: browser.collapseAll()
        case .search where initial: focused = .search
        case .nextMatch where initial: browser.nextMatch(by: 1)
        case .previousMatch where initial: browser.nextMatch(by: -1)
        case .toggleHeaders where initial: browser.showingHeaders.toggle()
        case .copy where initial: yank(.selection, armed: armed)
        case .copyAll where initial: yank(.whole, armed: armed)
        default: return .ignored
        }
        return .handled
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            KeyHints(hints: [(KeyAction.map.label, "map")])
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(store.requestFolders, id: \.self) { path in
                        let requests = store.requests.filter { $0.repo == path }
                        VStack(alignment: .leading, spacing: 4) {
                            Button { store.openFolder(path) } label: {
                                NamePlate(name: (path as NSString).lastPathComponent.uppercased() + (store.requestFolder == path ? "" : "  \(requests.count)"),
                                          color: store.requestFolder == path ? Theme.cyan : Theme.dim)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 4)
                            if store.requestFolder == path {
                                ForEach(requests) { request in
                                    RequestRow(request: request, selected: request.id == store.selectedRequestId) { store.selectedRequestId = request.id }
                                }
                                Button { create(in: path) } label: {
                                    Text("+ New request")
                                        .font(Theme.ui(13, weight: .bold))
                                        .foregroundStyle(Theme.cyan)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.trailing, 14)
            }
        }
    }

    /// Like yanking a message: the first press arms and the second copies.
    private func yank(_ kind: Yank, armed: Yank?) {
        guard armed == kind else { return yankArmed = kind }
        let response = selectedIndex.flatMap { store.responses[store.requests[$0].id] }
        guard let text = kind == .whole ? response?.body : browser.selectedText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func ask(_ mode: ClaudeBar.Mode) {
        askMode = mode
        focused = .ask
    }

    private func create(in path: String) {
        let request = APIRequest(repo: path)
        store.requests.append(request)
        store.selectedRequestId = request.id
    }

    private func delete(_ request: APIRequest) {
        store.requests.removeAll { $0.id == request.id }
        store.responses[request.id] = nil
        store.openFolder(request.repo)
    }

    private func send(_ request: APIRequest) {
        sending.insert(request.id)
        Task {
            let response = await request.send()
            store.responses[request.id] = response
            sending.remove(request.id)
            guard request.id == store.selectedRequestId else { return }
            browser.show(response)
            pane = .response
        }
    }
}

private struct RequestRow: View {
    var request: APIRequest
    var selected: Bool
    var select: () -> Void
    @ViewState private var hovered = false
    private var highlighted: Bool { hovered || selected }

    var body: some View {
        HStack(spacing: 6) {
            Text(request.method)
                .font(Theme.ui(10, weight: .black))
                .foregroundStyle(highlighted ? Theme.navy : request.method.methodColor)
            Text(request.title)
                .font(Theme.ui(14, weight: .bold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(highlighted ? Theme.navy : Theme.ice)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ActiveBackdrop(active: highlighted))
        .contentShape(Rectangle())
        .activeShift(highlighted)
        .onHover { hovered = $0 }
        .onTapGesture(perform: select)
    }
}

private struct RequestEditor: View {
    @Binding var request: APIRequest
    var sending: Bool
    var selected: Bool
    var focus: FocusState<RequestField?>.Binding
    var send: () -> Void
    var delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Request name", text: $request.name)
                    .focused(focus, equals: .name)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(16, weight: .black))
                    .foregroundStyle(Theme.ice)
                Button(action: delete) { Chip(color: Theme.red) { Text("DELETE") } }
                    .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Picker("", selection: $request.method) {
                    ForEach(APIRequest.methods, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                TextField("https://localhost:8080/api", text: $request.url)
                    .focused(focus, equals: .url)
                    .onSubmit(send)
                    .fieldStyle()
                Button(action: send) { Chip(active: true, color: Theme.green) { Text(sending ? "SENDING…" : "SEND") } }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.sendRequest)
                    .disabled(sending)
            }
            field("HEADERS", "Accept: application/json\nAuthorization: Bearer $(secret get …)", text: $request.headers, lines: 2...6, field: .headers)
            if request.sendsBody {
                field("BODY", "{ \"key\": \"value\" }", text: $request.body, lines: 4...12, field: .body)
            }
        }
        .panel(accent: Theme.cyan, padding: 18, selected: selected, opacity: 1)
    }

    private func field(_ title: String, _ placeholder: String, text: Binding<String>, lines: ClosedRange<Int>, field: RequestField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.ui(11, weight: .black)).foregroundStyle(Theme.dim)
            TextField(placeholder, text: text, axis: .vertical)
                .focused(focus, equals: field)
                .lineLimit(lines)
                .fieldStyle()
        }
    }
}

extension View {
    func fieldStyle() -> some View {
        textFieldStyle(.plain)
            .font(Theme.code)
            .foregroundStyle(Theme.ice)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.codeBackground)
    }
}

private extension String {
    var methodColor: Color {
        switch self {
        case "GET": Theme.green
        case "POST": Theme.gold
        case "PUT", "PATCH": Theme.cyan
        case "DELETE": Theme.red
        default: Theme.dim
        }
    }
}
