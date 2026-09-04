import Foundation

// MARK: - 块级解析（HTML / 富文本两个序列化器共用）

/// 表格：表头、列对齐（0 无、1 左、2 中、3 右）、数据行
struct MDTable {
    var header: [String]
    var aligns: [Int]
    var rows: [[String]]
}

/// 列表：有序/无序、起始编号、条目（支持任务项与嵌套子列表）
struct MDList {
    struct Item {
        var text: [String] = []
        var task: Int? = nil      // 0 未勾选、1 已勾选
        var children: [MDList] = []
    }
    var ordered: Bool
    var start: Int
    var items: [Item] = []
}

enum MDBlock {
    case heading(level: Int, text: String)
    case paragraph([String])
    case code(lang: String?, lines: [String])
    case quote([MDBlock])
    case list(MDList)
    case table(MDTable)
    case hr
}

enum MDParser {

    static func blocks(from markdown: String) -> [MDBlock] {
        parseLines(markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
    }

    static func parseLines(_ lines: [String]) -> [MDBlock] {
        var out: [MDBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 空行
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // 围栏代码块（``` 或 ~~~，可带语言名）
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }
                out.append(.code(lang: lang.isEmpty ? nil : lang, lines: code))
                continue
            }

            // ATX 标题
            if let m = MarkdownRenderer.match(#"^(#{1,6})\s+(.+?)\s*#*\s*$"#, line) {
                out.append(.heading(level: m[0].count, text: m[1]))
                i += 1
                continue
            }

            // 表格：当前行含 |，且下一行是分隔行
            if trimmed.contains("|"), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) {
                let header = splitRow(trimmed)
                let aligns = parseAligns(lines[i + 1])
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, t.contains("|"), !isTableDelimiter(t) else { break }
                    rows.append(splitRow(t))
                    i += 1
                }
                out.append(.table(MDTable(header: header, aligns: aligns, rows: rows)))
                continue
            }

            // 列表（含嵌套、任务项）
            if isUnorderedItem(line) || isOrderedItem(line) {
                let (list, next) = parseListLevel(
                    lines, i: i,
                    ordered: isOrderedItem(line),
                    start: orderedNumber(line),
                    baseIndent: indentOf(line))
                out.append(.list(list))
                i = next
                continue
            }

            // 引用（去掉一层 > 后递归解析，支持引用内嵌段落/标题/列表/表格）
            if trimmed.hasPrefix(">") {
                var inner: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var rest = String(t.dropFirst())
                    if rest.hasPrefix(" ") { rest.removeFirst() }
                    inner.append(rest)
                    i += 1
                }
                out.append(.quote(parseLines(inner)))
                continue
            }

            // 水平线（独立成块时）
            if MarkdownRenderer.isHorizontalRule(trimmed) {
                out.append(.hr)
                i += 1
                continue
            }

            // 段落：连续普通行；行内出现 setext 下划线则升级为标题
            var para: [String] = [line]
            i += 1
            var consumed = false
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if isSetextUnderline(t) {
                    out.append(.heading(
                        level: t.allSatisfy { $0 == "=" } ? 1 : 2,
                        text: para.joined(separator: " ")))
                    i += 1
                    consumed = true
                    break
                }
                if t.hasPrefix("#") || t.hasPrefix(">") || t.hasPrefix("```") || t.hasPrefix("~~~")
                    || MarkdownRenderer.isHorizontalRule(t)
                    || isUnorderedItem(lines[i]) || isOrderedItem(lines[i]) {
                    break
                }
                // 表格可紧跟段落（GFM 语义）：当前行含 | 且下一行是分隔行
                if t.contains("|"), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) {
                    break
                }
                para.append(lines[i])
                i += 1
            }
            if !consumed {
                out.append(.paragraph(para))
            }
        }
        return out
    }

    // MARK: - 列表

    private static func parseListLevel(_ lines: [String], i: Int,
                                       ordered: Bool, start: Int,
                                       baseIndent: Int) -> (MDList, Int) {
        var list = MDList(ordered: ordered, start: start)
        var i = i
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { break }
            let indent = indentOf(line)
            if indent < baseIndent { break }

            if indent > baseIndent {
                // 更深缩进：子列表或条目续行
                if isUnorderedItem(line) || isOrderedItem(line) {
                    let (sub, next) = parseListLevel(
                        lines, i: i,
                        ordered: isOrderedItem(line),
                        start: orderedNumber(line),
                        baseIndent: indent)
                    if list.items.isEmpty { list.items.append(MDList.Item()) }
                    list.items[list.items.count - 1].children.append(sub)
                    i = next
                } else {
                    if !list.items.isEmpty {
                        list.items[list.items.count - 1].text.append(t)
                    }
                    i += 1
                }
                continue
            }

            // 同缩进：必须是同类型条目，否则列表结束
            let isItem = ordered ? MarkdownRenderer.isOrderedItem(line) : MarkdownRenderer.isUnorderedItem(line)
            guard isItem else { break }
            var item = MDList.Item()
            var content = MarkdownRenderer.listContent(line)
            if let m = MarkdownRenderer.match(#"^\[( |x|X)\]\s*(.*)$"#, content) {
                item.task = (m[0] == " ") ? 0 : 1
                content = m[1]
            }
            item.text = [content]
            list.items.append(item)
            i += 1
        }
        return (list, i)
    }

    // MARK: - 辅助

    static func isUnorderedItem(_ line: String) -> Bool {
        MarkdownRenderer.match(#"^\s*[-*+]\s+\S"#, line) != nil
    }

    static func isOrderedItem(_ line: String) -> Bool {
        MarkdownRenderer.match(#"^\s*\d+[.)]\s+\S"#, line) != nil
    }

    static func orderedNumber(_ line: String) -> Int {
        guard let m = MarkdownRenderer.match(#"^\s*(\d+)[.)]\s+"#, line) else { return 1 }
        return Int(m[0]) ?? 1
    }

    static func indentOf(_ line: String) -> Int {
        var n = 0
        for ch in line {
            if ch == " " { n += 1 }
            else if ch == "\t" { n += 4 }
            else { break }
        }
        return n
    }

    /// setext 下划线：整行 = 或 -
    static func isSetextUnderline(_ t: String) -> Bool {
        guard !t.isEmpty else { return false }
        return t.allSatisfy { $0 == "=" } || t.allSatisfy { $0 == "-" }
    }

    // MARK: - 表格

    /// 表格分隔行：每个单元格都是 - 与 : 的组合且至少含一个 -
    static func isTableDelimiter(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        let cells = splitRow(t)
        return !cells.isEmpty && cells.allSatisfy { c in
            let c2 = c.trimmingCharacters(in: .whitespaces)
            return !c2.isEmpty && c2.contains("-") && c2.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    static func splitRow(_ t: String) -> [String] {
        var s = t.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        // 按未转义的 | 切分；\| 作为字面竖线保留在单元格内
        var cells: [String] = []
        var cur = ""
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            let next = s.index(after: i)
            if ch == "\\" && next < s.endIndex && s[next] == "|" {
                cur.append("|")
                i = s.index(after: next)
                continue
            }
            if ch == "|" {
                cells.append(cur)
                cur = ""
                i = next
                continue
            }
            cur.append(ch)
            i = next
        }
        cells.append(cur)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func parseAligns(_ line: String) -> [Int] {
        splitRow(line).map { c in
            let t = c.trimmingCharacters(in: .whitespaces)
            let l = t.hasPrefix(":"), r = t.hasSuffix(":")
            if l && r { return 2 }
            if r { return 3 }
            if l { return 1 }
            return 0
        }
    }
}
