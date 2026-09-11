import AppKit
import Foundation

/// 轻量级 Markdown -> HTML / NSAttributedString 渲染器。
/// 支持：标题、加粗、斜体、删除线、行内代码、围栏代码块、
/// 无序/有序列表、引用、水平线、链接、段落换行。
enum MarkdownRenderer {

    // MARK: - Block level

    static func html(from markdown: String) -> String {
        let blocks = MDParser.blocks(from: markdown)
        // 块之间插入空行，备忘录里保留段落间距
        return blocks.map(htmlBlock).joined(separator: "<div><br></div>")
    }

    private static func htmlBlock(_ b: MDBlock) -> String {
        switch b {
        case .heading(let level, let text):
            return "<h\(level)>" + inline(text) + "</h\(level)>"
        case .paragraph(let lines):
            return "<p>" + lines.map(inline).joined(separator: "<br>") + "</p>"
        case .code(_, let code):
            return "<pre><code>" + code.map(escape).joined(separator: "\\n") + "</code></pre>"
        case .quote(let blocks):
            return "<blockquote>" + blocks.map(htmlBlock).joined(separator: "<br>") + "</blockquote>"
        case .list(let list):
            return htmlList(list)
        case .table(let table):
            return htmlTable(table)
        case .hr:
            return "<hr>"
        case .aligned(let align, let inner):
            let name: String
            switch align {
            case .center: name = "center"
            case .right: name = "right"
            default: name = "left"
            }
            // align 属性给备忘录，style 给标准渲染器，双保险；
            // 块内标题/列表/表格按对应标签输出，段落行用 <br> 连接
            var body: [String] = []
            var paraLines: [String] = []
            func flushPara() {
                if !paraLines.isEmpty {
                    body.append("<p>" + paraLines.map(inline).joined(separator: "<br>") + "</p>")
                    paraLines = []
                }
            }
            for b in inner {
                if case .paragraph(let ls) = b {
                    paraLines.append(contentsOf: ls)
                } else {
                    flushPara()
                    body.append(htmlBlock(b))
                }
            }
            flushPara()
            return "<div align=\"\(name)\" style=\"text-align: \(name)\">"
                + body.joined(separator: "<br>") + "</div>"
        }
    }

    private static func htmlList(_ list: MDList) -> String {
        let tag = list.ordered ? "ol" : "ul"
        let startAttr = (list.ordered && list.start != 1) ? " start=\"\(list.start)\"" : ""
        var out = "<\(tag)\(startAttr)>"
        for item in list.items {
            var content = ""
            if let task = item.task {
                content += task == 1 ? "☑ " : "☐ "
            }
            content += item.text.map(inline).joined(separator: "<br>")
            content += item.children.map(htmlList).joined()
            out += "<li>" + content + "</li>"
        }
        out += "</\(tag)>"
        return out
    }

    private static func htmlTable(_ table: MDTable) -> String {
        func alignAttr(_ i: Int) -> String {
            guard i < table.aligns.count else { return "" }
            switch table.aligns[i] {
            case 1: return " align=\"left\""
            case 2: return " align=\"center\""
            case 3: return " align=\"right\""
            default: return ""
            }
        }
        // border=1 让备忘录把它渲染成带框线的原生表格（border-collapse 合并单元格线）
        var out = "<table border=\"1\" cellpadding=\"5\" cellspacing=\"0\" style=\"border-collapse: collapse\">"
        out += "<tr>" + table.header.enumerated()
            .map { "<th scope=\"col\"\(alignAttr($0.offset))>\(inline($0.element))</th>" }.joined() + "</tr>"
        for row in table.rows {
            out += "<tr>"
            for (ci, cell) in row.enumerated() {
                out += "<td\(alignAttr(ci))>\(inline(cell))</td>"
            }
            out += "</tr>"
        }
        out += "</table>"
        return out
    }

// MARK: - Inline

    static func inline(_ raw: String) -> String {
        var stash: [String] = []

        func stashHTML(_ html: String) -> String {
            stash.append(html)
            return "\u{1}\(stash.count - 1)\u{1}"
        }

        // 自动链接 <https://...>（须在 escape 之前，避免 < > 变成 &lt; &gt;）
        var s = replaceRegex(#"<((?:https?|ftp)://[^<>\s]+)>"#, in: raw) { m in
            let url = (raw as NSString).substring(with: m.range(at: 1))
            return stashHTML("<a href=\"\(url)\">\(url)</a>")
        }
        s = escape(s)
        // 反斜杠转义：\\* \\` \\[ 等还原为普通字符（先保护，避免被再加格式）
        s = replaceRegex(#"(\\)([\\`*_{}\[\]()#+.!>~-])"#, in: s) { m in
            stashHTML(s.substring(m.range(at: 2)))
        }
        // 行内代码（先保护，避免内部被再加格式）
        s = replaceRegex(#"`([^`]+)`"#, in: s) { m in
            stashHTML("<code>" + s.substring(m.range(at: 1)) + "</code>")
        }
        // 图床图片 ![](url)（先于链接处理，避免被拆成 "!" + 空链接）
        s = replaceRegex(#"!\[([^\]]*)\]\(([^)\s]+)\)"#, in: s) { m in
            let alt = s.substring(m.range(at: 1))
            let url = s.substring(m.range(at: 2))
            return stashHTML("<img src=\"\(url)\" alt=\"\(alt)\">")
        }
        // 加粗
        s = replaceRegex(#"(\*\*|__)(.+?)\1"#, in: s) { m in
            stashHTML("<strong>" + s.substring(m.range(at: 2)) + "</strong>")
        }
        // 斜体
        s = replaceRegex(#"(\*|_)([^*_]+?)\1"#, in: s) { m in
            stashHTML("<em>" + s.substring(m.range(at: 2)) + "</em>")
        }
        // 删除线
        s = replaceRegex(#"~~(.+?)~~"#, in: s) { m in
            stashHTML("<del>" + s.substring(m.range(at: 1)) + "</del>")
        }
        // 链接
        s = replaceRegex(#"\[([^\]]+)\]\(([^)\s]+)\)"#, in: s) { m in
            let text = s.substring(m.range(at: 1))
            let url = s.substring(m.range(at: 2))
            return stashHTML("<a href=\"\(url)\">\(text)</a>")
        }
        // 还原占位符
        s = replaceRegex("\u{1}(\\d+)\u{1}", in: s) { m in
            if let idx = Int(s.substring(m.range(at: 1))), idx < stash.count {
                return stash[idx]
            }
            return ""
        }
        return s
    }

    /// 提取第一个 ATX 标题作为备忘录标题
    static func deriveTitle(from markdown: String) -> String? {
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let m = match(#"^#{1,6}\s+(.+?)\s*#*\s*$"#, line) {
                return m[0]
            }
            break // 只看第一个非空行
        }
        return nil
    }

    /// 推送备忘录用的 markdown：确保首个非空行是最终标题 H1。
    /// 实验确认：Notes 会把正文首行渲染为 24px 加粗并用作笔记名，
    /// 因此不再显式设置 name（显式 name 行是普通字重，且会与正文 H1 重复）。
    /// - explicitTitle 非空时：已有首标题则替换其文本，否则在首行前插入新标题；
    ///   为空时：保持原文不变。
    static func noteMarkdown(_ markdown: String, explicitTitle: String) -> String {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else {
            // 正文为空但有标题时，输出仅含标题的 markdown（预览/推送一致）
            return explicitTitle.isEmpty ? markdown : "# " + explicitTitle
        }
        var result = lines
        if let m = match(#"^(#{1,6})\s+(.+?)\s*#*\s*$"#, lines[idx]) {
            result[idx] = "# " + (explicitTitle.isEmpty ? m[1] : explicitTitle)
        } else if !explicitTitle.isEmpty {
            result.insert("# " + explicitTitle, at: idx)
        }
        return result.joined(separator: "\n")
    }

    /// 若第一个非空行是 ATX 标题，返回 (标题文本, 去掉该行后的 markdown)；否则 nil。
    /// 供 CLI/测试使用：推送路径现在改用 noteMarkdown（保留首标题 H1 作加粗主标题）。
    static func splitFirstHeading(_ markdown: String) -> (title: String, body: String)? {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        for (idx, line) in lines.enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let m = match(#"^(#{1,6})\s+(.+?)\s*#*\s*$"#, line) {
                var rest = lines
                rest.remove(at: idx)
                return (m[1], rest.joined(separator: "\n"))
            }
            return nil
        }
        return nil
    }

    // MARK: - HTML -> NSAttributedString

    static func attributed(fromHTML html: String) -> NSAttributedString {
        let full = "<html><head><meta charset=\"utf-8\"></head><body>\(html)</body></html>"
        if let data = full.data(using: .utf8),
           let attr = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil) {
            return attr
        } else if ProcessInfo.processInfo.environment["NOTESMD_DEBUG"] != nil {
            do {
                _ = try NSAttributedString(
                    data: full.data(using: .utf8)!,
                    options: [
                        .documentType: NSAttributedString.DocumentType.html,
                        .characterEncoding: String.Encoding.utf8.rawValue
                    ],
                    documentAttributes: nil)
            } catch {
                FileHandle.standardError.write(Data("HTML 转换失败：\(error)\n".utf8))
            }
        }
        return NSAttributedString(string: html)
    }

    // MARK: - Helpers

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func isHorizontalRule(_ t: String) -> Bool {
        guard t.count >= 3 else { return false }
        let set = Set(t)
        return set.isSubset(of: Set("-")) || set.isSubset(of: Set("*")) || set.isSubset(of: Set("_"))
    }

    static func isUnorderedItem(_ line: String) -> Bool {
        match(#"^\s*[-*+]\s+\S"#, line) != nil
    }

    static func isOrderedItem(_ line: String) -> Bool {
        match(#"^\s*\d+[.)]\s+\S"#, line) != nil
    }

    static func listContent(_ line: String) -> String {
        if let m = match(#"^\s*[-*+]\s+(.*)$"#, line) { return m[0] }
        if let m = match(#"^\s*\d+[.)]\s+(.*)$"#, line) { return m[0] }
        return line
    }

    /// 返回分组捕获（不含整体匹配）
    static func match(_ pattern: String, _ input: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = input as NSString
        guard let m = re.firstMatch(in: input, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var groups: [String] = []
        for g in 1..<m.numberOfRanges {
            groups.append(ns.substring(with: m.range(at: g)))
        }
        return groups
    }

    private static func replaceRegex(_ pattern: String, in input: String,
                                     transform: (NSTextCheckingResult) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location < last { continue }
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            result += transform(m)
            last = m.range.upperBound
        }
        result += ns.substring(from: last)
        return result
    }
}

private extension String {
    func substring(_ range: NSRange) -> String {
        (self as NSString).substring(with: range)
    }
}
