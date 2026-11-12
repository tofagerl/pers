import Foundation

extension ChatMessage {
    /// A tool message's text holds its name, detail and optional description, tab separated.
    var toolParts: (name: String, detail: String?, description: String?) {
        let parts = text.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let detail = parts.count > 1 ? parts[1] : nil
        let description = parts.count > 2 ? parts[2] : parts[0] == "Bash" ? detail.flatMap(CommandSummary.of) : nil
        return (parts[0], detail, description)
    }
}

/// Describes a shell command in plain words, for Bash calls Claude sent without a description.
enum CommandSummary {
    static func of(_ command: String) -> String? {
        var phrases: [String] = []
        for phrase in steps(in: withoutHeredocBodies(command)).compactMap(phrase) where !phrases.contains(phrase) {
            phrases.append(phrase)
        }
        guard let first = phrases.first else { return nil }
        let rest = phrases.dropFirst().prefix(2).map { $0.prefix(1).lowercased() + $0.dropFirst() }
        return ([first] + rest).joined(separator: ", then ") + (phrases.count > 3 ? "…" : "")
    }

    private static func withoutHeredocBodies(_ command: String) -> String {
        command.replacingOccurrences(of: #"<<-?\s*['"]?(\w+)['"]?[^\n]*\n[\s\S]*?\n\s*\1[ \t]*(?=\n|$)"#,
                                     with: "", options: .regularExpression)
    }

    /// The words of each command, keeping only the first command of a pipeline.
    private static func steps(in command: String) -> [[String]] {
        var steps: [[String]] = [[]]
        var word = ""
        var quote: Character?
        var piped = false
        func endWord() {
            if !word.isEmpty, !piped { steps[steps.count - 1].append(word) }
            word = ""
        }
        let chars = Array(command)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            if let open = quote {
                if c == open { quote = nil } else { word.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c
            } else if c == "\\", next == "\n" {
                i += 1
            } else if c == " " || c == "\t" {
                endWord()
            } else if c == "&", word.hasSuffix(">") || next == ">" {
                word.append(c)
            } else if "\n;&|".contains(c) {
                endWord()
                if c == "|", next != "|" {
                    piped = true
                } else {
                    piped = false
                    steps.append([])
                }
                if next == c { i += 1 }
            } else {
                word.append(c)
            }
            i += 1
        }
        endWord()
        return steps.filter { !$0.isEmpty }
    }

    private static let scripts = ["python": "Python", "python3": "Python", "node": "Node", "ruby": "Ruby",
                                  "perl": "Perl", "bash": "shell", "sh": "shell", "zsh": "shell"]
    private static let builders: Set = ["swift", "cargo", "go", "npm", "pnpm", "yarn", "bun", "make", "gradle", "gradlew", "mvn"]
    private static let gitVerbs = ["status": "Check git status", "diff": "Show the diff", "log": "Show git history",
                                   "show": "Show a commit", "add": "Stage changes", "commit": "Commit", "push": "Push",
                                   "pull": "Pull", "fetch": "Fetch from remote", "checkout": "Switch branch",
                                   "switch": "Switch branch", "branch": "List branches", "stash": "Stash changes",
                                   "rebase": "Rebase", "merge": "Merge", "ls-files": "List tracked files",
                                   "worktree": "Manage worktrees", "blame": "Show who changed each line"]

    private static func phrase(_ words: [String]) -> String? {
        let words = words.drop { $0.contains("=") && !$0.hasPrefix("-") }
        guard let program = words.first.map({ ($0 as NSString).lastPathComponent }) else { return nil }
        let operands = words.dropFirst().filter { !$0.hasPrefix("-") && !$0.contains(">") && !$0.hasPrefix("<") }
        let file = operands.last.map { ($0 as NSString).lastPathComponent }
        switch program {
        case "cd", "echo", "printf", "true", "sleep", "export", "set", "source", "wait":
            return nil
        case "git":
            guard let verb = operands.first else { return "Run git" }
            return gitVerbs[verb] ?? "Run git \(verb)"
        case "grep", "egrep", "rg", "ag":
            return operands.first.map { "Search for “\($0)”" } ?? "Search"
        case "cat", "head", "tail", "less", "bat", "wc":
            return file.map { "Read \($0)" } ?? "Read a file"
        case "sed", "awk":
            let verb = words.contains { $0.hasPrefix("-i") } ? "Edit" : "Read"
            return operands.count > 1 ? "\(verb) \(file!)" : "\(verb) text"
        case "ls", "tree":
            return "List files"
        case "find", "fd":
            return "Find files"
        case "mkdir":
            return file.map { "Create \($0)" }
        case "rm":
            return file.map { "Delete \($0)" }
        case "mv", "cp":
            return operands.first.map { "\(program == "mv" ? "Move" : "Copy") \(($0 as NSString).lastPathComponent)" }
        case "open":
            return file.map { "Open \($0)" }
        case "curl", "wget":
            let host = operands.lazy.compactMap { URL(string: $0)?.host }.first
            return host.map { "Fetch from \($0)" } ?? "Fetch a URL"
        case _ where scripts[program] != nil:
            return file.map { "Run \($0)" } ?? "Run a \(scripts[program]!) script"
        case _ where builders.contains(program):
            switch operands.first {
            case "build": return "Build"
            case "test": return "Run tests"
            case "install", "i": return "Install dependencies"
            case let task?: return "Run \(program) \(task)"
            case nil: return "Run \(program)"
            }
        default:
            return "Run \(program)"
        }
    }
}
