import AppKit
import Foundation

/// 轻量级 Markdown -> HTML / NSAttributedString 渲染器。
/// 支持：标题、加粗、斜体、删除线、行内代码、围栏代码块、
/// 无序/有序列表、引用、水平线、链接、段落换行。
enum MarkdownRenderer {

    // MARK: - Block level

    static func html(from markdown: String) -> String {
        var out: [String] = []
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append("<p>" + paragraph.map(inline).joined(separator: "<br>") + "</p>")
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 围栏代码块
            if trimmed.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                i += 1
                while i < lines.count &&
                    !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // 跳过收尾围栏
                out.append("<pre><code>" + code.map(escape).joined(separator: "\n") + "</code></pre>")
                continue
            }

            // 标题
            if let m = match(#"^(#{1,6})\s+(.+?)\s*#*\s*$"#, line) {
                flushParagraph()
                let level = m[0].count
                out.append("<h\(level)>" + inline(m[1]) + "</h\(level)>")
                i += 1
                continue
            }

            // 水平线
            if isHorizontalRule(trimmed) {
                flushParagraph()
                out.append("<hr>")
                i += 1
                continue
            }

            // 引用
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out.append("<blockquote>" + quote.map(inline).joined(separator: "<br>") + "</blockquote>")
                continue
            }

            // 无序列表
            if isUnorderedItem(line) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count && isUnorderedItem(lines[i]) {
                    items.append(listContent(lines[i]))
                    i += 1
                }
                out.append("<ul>" + items.map { "<li>" + inline($0) + "</li>" }.joined() + "</ul>")
                continue
            }

            // 有序列表
            if isOrderedItem(line) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count && isOrderedItem(lines[i]) {
                    items.append(listContent(lines[i]))
                    i += 1
                }
                out.append("<ol>" + items.map { "<li>" + inline($0) + "</li>" }.joined() + "</ol>")
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return out.joined(separator: "\n")
    }

    // MARK: - Inline

    static func inline(_ raw: String) -> String {
        var s = escape(raw)
        var stash: [String] = []

        func stashHTML(_ html: String) -> String {
            stash.append(html)
            return "\u{1}\(stash.count - 1)\u{1}"
        }

        // 行内代码（先保护，避免内部被再加格式）
        s = replaceRegex(#"`([^`]+)`"#, in: s) { m in
            stashHTML("<code>" + s.substring(m.range(at: 1)) + "</code>")
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
                return m[1]
            }
            break // 只看第一个非空行
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

    private static func isHorizontalRule(_ t: String) -> Bool {
        guard t.count >= 3 else { return false }
        let set = Set(t)
        return set.isSubset(of: Set("-")) || set.isSubset(of: Set("*")) || set.isSubset(of: Set("_"))
    }

    private static func isUnorderedItem(_ line: String) -> Bool {
        match(#"^\s*[-*+]\s+\S"#, line) != nil
    }

    private static func isOrderedItem(_ line: String) -> Bool {
        match(#"^\s*\d+[.)]\s+\S"#, line) != nil
    }

    private static func listContent(_ line: String) -> String {
        if let m = match(#"^\s*[-*+]\s+(.*)$"#, line) { return m[0] }
        if let m = match(#"^\s*\d+[.)]\s+(.*)$"#, line) { return m[0] }
        return line
    }

    /// 返回分组捕获（不含整体匹配）
    private static func match(_ pattern: String, _ input: String) -> [String]? {
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
