import Foundation

enum ClaudeModel: String, CaseIterable, Codable, Identifiable {
    case opus, sonnet, haiku
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }

    /// Saved tabs from when Fable was an option still decode instead of discarding the whole save.
    init(from decoder: Decoder) throws {
        self = ClaudeModel(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .sonnet
    }
}

enum PermissionMode: String, CaseIterable, Codable, Identifiable {
    case manual, acceptEdits, plan, auto, dontAsk, bypassPermissions
    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: "MANUAL"
        case .acceptEdits: "ACCEPT EDITS"
        case .plan: "PLAN"
        case .auto: "AUTO"
        case .dontAsk: "DON'T ASK"
        case .bypassPermissions: "BYPASS"
        }
    }

    /// What Claude Code itself would start in: `permissions.defaultMode` from the user's settings, else manual ("default" in the CLI).
    static var claudeDefault: PermissionMode {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")
        let name = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            .flatMap { ($0["permissions"] as? [String: Any])?["defaultMode"] as? String }
        return name.flatMap(PermissionMode.init(rawValue:)) ?? .manual
    }
}

enum Effort: String, CaseIterable, Codable, Identifiable {
    case low, medium, high, xhigh, max
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum Speaker: String, Codable {
    case user, claude, tool, shell, system, advisor
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var speaker: Speaker
    var text: String
    var images: [Data]?
    var edits: [Edit]?
    /// Terminal output's colours, covering `text` in order.
    var colors: [ColorRun]?

    struct Edit: Codable, Equatable {
        var old: String
        var new: String
    }
}

struct ColorRun: Codable, Equatable {
    var length: Int
    var style: Style

    struct Style: Codable, Equatable {
        /// An xterm 256-colour palette index.
        var ansi: UInt8?
        var rgb: UInt32?
        var bold = false
    }
}

struct SessionSnapshot: Codable {
    var id: UUID
    var directory: String
    var sessionId: String?
    var model: ClaudeModel
    var mode: PermissionMode
    var effort: Effort?
    var advising: Bool?
    var tokens: Int?
    var contextTokens: Int?
    var contextWindow: Int?
    var messages: [ChatMessage]
    var outfit: Int?
    var draft: String?
    var pastes: [Int: String]?
    var inputHistory: [String]?
    var forkedFrom: UUID?
    var forkAt: String?
}

struct PermissionPrompt {
    var requestId: String
    var tool: String
    var detail: String
    var input: [String: Any]
    var suggestions: [[String: Any]]
    var questions: [Question]
    var answers: [String: String] = [:]
    var selected: [String] = []

    /// The first question still waiting for an answer, when the prompt is an AskUserQuestion call.
    var question: Question? { questions.first { answers[$0.text] == nil } }
    var step: String { "\(requestId)/\(answers.count)" }

    struct Question {
        var text: String
        var header: String
        var multiSelect: Bool
        var options: [(label: String, description: String)]

        var markdown: String {
            let list = options.map { $0.description.isEmpty ? "- **\($0.label)**" : "- **\($0.label)** — \($0.description)" }
            return ([text, ""] + list).joined(separator: "\n")
        }

        init(json: [String: Any]) {
            text = json["question"] as? String ?? ""
            header = json["header"] as? String ?? ""
            multiSelect = json["multiSelect"] as? Bool ?? false
            options = (json["options"] as? [[String: Any]] ?? []).map {
                ($0["label"] as? String ?? "", $0["description"] as? String ?? "")
            }
        }
    }
}
