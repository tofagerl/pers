import SwiftUI
import AppKit

struct MarkdownView: View {
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(of: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let styled):
                    Self.prose(styled)
                case .segment(.code(let language, let code)):
                    CodeBlock(language: language, code: code)
                case .segment(.table(let rows)):
                    MarkdownTable(rows: rows)
                case .segment(.quote(let quote)):
                    HStack(spacing: 0) {
                        Rectangle().fill(Theme.cyan).frame(width: 3)
                        MarkdownView(text: quote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .background(Theme.cyan.opacity(0.08))
                    .fixedSize(horizontal: false, vertical: true)
                case .segment(.prose), .segment(.list):
                    EmptyView()
                }
            }
        }
        .textSelection(.enabled)
    }

    static func prose(_ text: AttributedString) -> some View {
        Text(text)
            .font(Theme.body)
            .foregroundStyle(Theme.text)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private enum Block {
        case text(AttributedString)
        case segment(Segment)
    }

    /// Runs of prose and lists become one Text, since a selection can't span separate Texts.
    private static func blocks(of text: String) -> [Block] {
        segments(of: text).reduce(into: []) { blocks, segment in
            let styled: AttributedString
            switch segment {
            case .prose(let prose): styled = inline(prose)
            case .list(let items): styled = list(items)
            default: blocks.append(.segment(segment)); return
            }
            if case .text(let previous) = blocks.last {
                blocks[blocks.count - 1] = .text(previous + AttributedString("\n\n") + styled)
            } else {
                blocks.append(.text(styled))
            }
        }
    }

    // shortcut: wrapped list lines start at the left edge instead of under the item's text; fix with a hanging indent if long items read badly.
    private static func list(_ items: [ListItem]) -> AttributedString {
        items.enumerated().reduce(into: AttributedString()) { result, entry in
            var marker = AttributedString((entry.offset == 0 ? "" : "\n") + String(repeating: "    ", count: entry.element.level) + entry.element.marker + " ")
            marker.font = Theme.body.weight(.heavy)
            marker.foregroundColor = Theme.cyan
            result += marker + inline(entry.element.text)
        }
    }

    enum Segment {
        case prose(String)
        case code(language: String, code: String)
        case list([ListItem])
        case table([[String]])
        case quote(String)
    }

    struct ListItem {
        var level: Int
        var marker: String
        var text: String
    }

    /// Splits on ``` fences; an unterminated fence (mid-typewriter) still renders as code.
    static func segments(of text: String) -> [Segment] {
        var result: [Segment] = []
        var prose: [Substring] = []
        var code: [Substring]?
        var language = ""

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmed
            if !joined.isEmpty { result.append(.prose(joined)) }
            prose = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let content = line.trimmingCharacters(in: .whitespaces)
            if content.hasPrefix("```") {
                if let lines = code {
                    result.append(.code(language: language, code: lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushProse()
                    language = content.dropFirst(3).trimmed
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else if content.hasPrefix(">") {
                let quoted = String(content.dropFirst().drop { $0 == " " })
                let continuesQuote = prose.isEmpty
                flushProse()
                if continuesQuote, case .quote(let quote) = result.last {
                    result[result.count - 1] = .quote(quote + "\n" + quoted)
                } else {
                    result.append(.quote(quoted))
                }
            } else if content.hasPrefix("|") {
                let cells = content.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .split(separator: "|", omittingEmptySubsequences: false).map(\.trimmed)
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy(":-".contains) }) { continue }
                let continuesTable = prose.isEmpty
                flushProse()
                if continuesTable, case .table(let rows) = result.last {
                    result[result.count - 1] = .table(rows + [cells])
                } else {
                    result.append(.table([cells]))
                }
            } else if let item = listItem(line) {
                // Blank lines between items keep a loose list together.
                let continuesList = prose.allSatisfy { $0.trimmed.isEmpty }
                flushProse()
                if continuesList, case .list(let items) = result.last {
                    result[result.count - 1] = .list(items + [item])
                } else {
                    result.append(.list([item]))
                }
            } else if line.first?.isWhitespace == true, !content.isEmpty, prose.isEmpty, case .list(var items) = result.last {
                items[items.count - 1].text += " " + content
                result[result.count - 1] = .list(items)
            } else {
                prose.append(line)
            }
        }
        if let code { result.append(.code(language: language, code: code.joined(separator: "\n"))) }
        flushProse()
        return result
    }

    private static func listItem(_ line: Substring) -> ListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(indent.count)
        guard let space = rest.firstIndex(of: " ") else { return nil }
        let marker = rest[..<space]
        let isBullet = ["-", "*", "+"].contains(marker)
        let isNumbered = marker.count > 1 && marker.dropLast().allSatisfy(\.isNumber) && ".)".contains(marker.last!)
        guard isBullet || isNumbered else { return nil }
        return ListItem(level: indent.count / 2, marker: isBullet ? "•" : String(marker), text: rest[space...].trimmed)
    }

    static func inline(_ prose: String) -> AttributedString {
        let headed = prose.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.hasPrefix("#") else { return String(line) }
            return "**\(line.drop { $0 == "#" }.trimmed)**"
        }.joined(separator: "\n")
        var attributed = (try? AttributedString(markdown: headed, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(prose)
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].foregroundColor = Theme.cyan
            attributed[run.range].font = Theme.code
        }
        for run in attributed.runs where run.link != nil {
            attributed[run.range].foregroundColor = Theme.gold
        }
        return attributed
    }
}

private struct MarkdownTable: View {
    var rows: [[String]]

    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(MarkdownView.inline(column < row.count ? row[column] : ""))
                            .font(index == 0 ? Theme.body.weight(.heavy) : Theme.body)
                            .foregroundStyle(index == 0 ? Theme.cyan : Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index == 0 ? Theme.cyan.opacity(0.15) : Theme.cyan.opacity(index.isMultiple(of: 2) ? 0.05 : 0))
                    }
                }
            }
        }
        .overlay(Rectangle().strokeBorder(Theme.cyan.opacity(0.35), lineWidth: 1.5))
    }
}

struct CodeBlock: View {
    var language: String
    var code: String
    var selected = false
    var status: String?
    /// Terminal output, which can run to hundreds of lines and keeps growing while the command runs.
    var isOutput = false
    var colors: [ColorRun]?
    @ViewState private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "CODE" : language.uppercased())
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.dim)
                if let status {
                    Text("● " + status.uppercased())
                        .font(Theme.ui(10, weight: .bold))
                        .foregroundStyle(Theme.green)
                }
                Spacer()
                Button(copied ? "COPIED!" : "COPY") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                .buttonStyle(.plain)
                .font(Theme.ui(10))
                .foregroundStyle(copied ? Theme.aqua : Theme.cyan)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.cyan.opacity(0.08))

            if isOutput {
                TerminalOutput(text: code, colors: colors ?? [])
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(SyntaxHighlighter.highlight(code))
                        .font(Theme.code)
                        .lineSpacing(2)
                        .padding(10)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
        }
        .background(Theme.codeBackground)
        .overlay(Rectangle().strokeBorder(selected ? Theme.gold : Theme.cyan.opacity(0.35), lineWidth: selected ? 2 : 1.5))
    }
}

/// Coloured text in a box of limited height that follows the end of the output unless scrolled up.
private struct TerminalOutput: View {
    var text: String
    var colors: [ColorRun]
    @StateObject private var scroller = LogScroller()
    private static let maxHeight: CGFloat = 320
    private static let lineHeight = NSLayoutManager().defaultLineHeight(for: .monospacedSystemFont(ofSize: 12.5, weight: .regular)) + 2

    var body: some View {
        // Sized from the line count instead of measured, so the box has its final height on first layout
        // and doesn't shift the chat around it.
        let lines = CGFloat(text.utf8.lazy.filter { $0 == 10 }.count + 1)
        ScrollView([.vertical, .horizontal], showsIndicators: false) {
            Text(styled)
                .font(Theme.code)
                .lineSpacing(2)
                .padding(10)
                .fixedSize()
        }
        .frame(height: min(lines * Self.lineHeight + 20, Self.maxHeight))
        .defaultScrollAnchor(.topLeading, for: .alignment)
        .scrollBounceBehavior(.basedOnSize)
        .scrollPosition($scroller.position)
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { scroller.track($1) }
        .onChange(of: text) { if scroller.followsBottom { scroller.position.scrollTo(edge: .bottom) } }
    }

    private var styled: AttributedString {
        var styled = AttributedString()
        var start = text.startIndex
        for run in colors {
            let end = text.index(start, offsetBy: run.length, limitedBy: text.endIndex) ?? text.endIndex
            var part = AttributedString(text[start..<end])
            part.foregroundColor = run.style.color
            if run.style.bold { part.font = Theme.code.bold() }
            styled += part
            start = end
        }
        return styled + AttributedString(text[start...])
    }
}

private extension ColorRun.Style {
    var color: Color? {
        if let rgb { return Color(hex: rgb) }
        guard let ansi else { return nil }
        switch ansi {
        case 0..<16:
            return Theme.ansi[Int(ansi % 8)]
        case 16..<232:
            let index = Int(ansi) - 16
            let level = { (value: Int) in UInt32(value == 0 ? 0 : 55 + value * 40) }
            return Color(hex: level(index / 36) << 16 | level(index / 6 % 6) << 8 | level(index % 6))
        default:
            let gray = UInt32(8 + (Int(ansi) - 232) * 10)
            return Color(hex: gray << 16 | gray << 8 | gray)
        }
    }
}

/// Language-agnostic highlighting: good enough for a chat log, not a parser.
enum SyntaxHighlighter {
    private static let keywords = Set("""
    func let var if else for while return import class struct enum case switch break continue in guard
    def elif try except finally with as from lambda yield async await const function new this self
    public private protected static final void int long bool boolean string fn mut pub use impl match
    interface type package extends implements throws throw true false nil null None True False do then fi
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    private static let pattern = try! NSRegularExpression(pattern: #"""
    (?<comment>//[^\n]*|#(?![!{])[^\n]*|/\*[\s\S]*?\*/)|(?<string>"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`[^`]*`)|(?<number>\b\d+(?:\.\d+)?\b)|(?<word>\b[A-Za-z_][A-Za-z0-9_]*\b)
    """#)

    static func highlight(lines: [String]) -> [AttributedString] {
        let result = highlight(lines.joined(separator: "\n"))
        var start = result.startIndex
        return lines.map { line in
            let end = result.index(start, offsetByCharacters: line.count)
            defer { if end < result.endIndex { start = result.index(end, offsetByCharacters: 1) } }
            return AttributedString(result[start..<end])
        }
    }

    static func highlight(_ code: String) -> AttributedString {
        var result = AttributedString(code)
        result.foregroundColor = Color(hex: 0xD6E8FF)
        let ns = code as NSString
        for match in pattern.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            let color: Color
            if match.range(withName: "comment").location != NSNotFound {
                color = Color(hex: 0x5B78A8)
            } else if match.range(withName: "string").location != NSNotFound {
                color = Theme.aqua
            } else if match.range(withName: "number").location != NSNotFound {
                color = Theme.gold
            } else {
                let word = ns.substring(with: match.range)
                if keywords.contains(word) { color = Theme.pink }
                else if word.first?.isUppercase == true { color = Theme.cyan }
                else { continue }
            }
            if let range = Range(match.range, in: code), let attributedRange = Range(range, in: result) {
                result[attributedRange].foregroundColor = color
            }
        }
        return result
    }
}
