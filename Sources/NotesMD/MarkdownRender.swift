import AppKit
import Foundation

/// 进程内 Markdown -> NSAttributedString 渲染。
/// 不依赖 com.apple.textkit.nsattributedstringagent XPC 服务，
/// 因此即使在受限沙箱环境（如代理子进程）下也能正常渲染预览。
extension MarkdownRenderer {

    static func render(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var paragraph: [String] = []
        var i = 0

        func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
            bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        }

        func style(head: CGFloat = 0, first: CGFloat? = nil,
                   before: CGFloat = 0, after: CGFloat = 0, line: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.headIndent = head
            if let first { p.firstLineHeadIndent = first }
            p.paragraphSpacingBefore = before
            p.paragraphSpacing = after
            p.lineSpacing = line
            return p
        }

        func append(_ s: String, _ attrs: [NSAttributedString.Key: Any]) {
            out.append(NSAttributedString(string: s, attributes: attrs))
        }

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font(14),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style(after: 8, line: 4)
            ]
            for (idx, line) in paragraph.enumerated() {
                out.append(attributedInline(line, base: attrs))
                if idx < paragraph.count - 1 { append("\n", attrs) }
            }
            paragraph = []
        }

        let headingSizes: [CGFloat] = [24, 20, 17, 15, 14, 13]

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
                if i < lines.count { i += 1 }
                append(code.joined(separator: "\n") + "\n", [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor(white: 0.93, alpha: 1),
                    .paragraphStyle: style(before: 8, after: 8, line: 2)
                ])
                continue
            }

            // 标题
            if let m = match(#"^(#{1,6})\s+(.+?)\s*#*\s*$"#, line) {
                flushParagraph()
                append(m[1] + "\n", [
                    .font: font(headingSizes[m[0].count - 1], bold: true),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: style(before: 12, after: 4)
                ])
                i += 1
                continue
            }

            // 水平线
            if isHorizontalRule(trimmed) {
                flushParagraph()
                append(String(repeating: "─", count: 36) + "\n", [
                    .font: font(12),
                    .foregroundColor: NSColor(white: 0.7, alpha: 1),
                    .paragraphStyle: style(before: 6, after: 6)
                ])
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
                for (idx, q) in quote.enumerated() {
                    let last = idx == quote.count - 1
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font(13),
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .paragraphStyle: style(head: 18, first: 18,
                                               before: idx == 0 ? 4 : 0, after: last ? 8 : 2)
                    ]
                    out.append(attributedInline(q, base: attrs))
                    if !last { append("\n", attrs) }
                }
                continue
            }

            // 无序列表
            if isUnorderedItem(line) {
                flushParagraph()
                var n = 0
                while i < lines.count && isUnorderedItem(lines[i]) { n += 1; i += 1 }
                for idx in 0..<n {
                    let k = i - n + idx
                    let last = idx == n - 1
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font(14),
                        .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: style(head: 20, first: 0, after: last ? 8 : 2, line: 3)
                    ]
                    append("\u{2022}  ", attrs)
                    out.append(attributedInline(listContent(lines[k]), base: attrs))
                    if !last { append("\n", attrs) }
                }
                continue
            }

            // 有序列表
            if isOrderedItem(line) {
                flushParagraph()
                var n = 0
                while i < lines.count && isOrderedItem(lines[i]) { n += 1; i += 1 }
                for idx in 0..<n {
                    let k = i - n + idx
                    let last = idx == n - 1
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font(14),
                        .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: style(head: 24, first: 4, after: last ? 8 : 2, line: 3)
                    ]
                    append("\(idx + 1).  ", attrs)
                    out.append(attributedInline(listContent(lines[k]), base: attrs))
                    if !last { append("\n", attrs) }
                }
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
        return out
    }

    /// 内联语法 -> 富文本：行内代码 > 加粗 > 斜体 > 删除线 > 链接
    static func attributedInline(_ raw: String, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var rest = raw

        while true {
            var best: (loc: Int, end: Int, kind: Int, inner: String)?
            func consider(_ pattern: String, kind: Int, group: Int) {
                guard let re = try? NSRegularExpression(pattern: pattern),
                      let m = re.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)),
                      m.range.location != NSNotFound else { return }
                let inner = (rest as NSString).substring(with: m.range(at: group))
                if let cur = best {
                    if m.range.location < cur.loc || (m.range.location == cur.loc && kind < cur.kind) {
                        best = (m.range.location, m.range.upperBound, kind, inner)
                    }
                } else {
                    best = (m.range.location, m.range.upperBound, kind, inner)
                }
            }
            consider(#"`([^`]+)`"#, kind: 0, group: 1)
            consider(#"(\*\*|__)(.+?)\1"#, kind: 1, group: 2)
            consider(#"(\*|_)([^*_]+?)\1"#, kind: 2, group: 2)
            consider(#"~~(.+?)~~"#, kind: 3, group: 1)
            consider(#"\[([^\]]+)\]\(([^)\s]+)\)"#, kind: 4, group: 1)

            guard let b = best else {
                if !rest.isEmpty {
                    result.append(NSAttributedString(string: rest, attributes: base))
                }
                break
            }

            let prefix = (rest as NSString).substring(to: b.loc)
            if !prefix.isEmpty {
                result.append(NSAttributedString(string: prefix, attributes: base))
            }

            var attrs = base
            switch b.kind {
            case 0:
                if let f = attrs[.font] as? NSFont {
                    attrs[.font] = NSFont.monospacedSystemFont(ofSize: max(f.pointSize - 1.5, 10), weight: .regular)
                }
                attrs[.backgroundColor] = NSColor(white: 0.93, alpha: 1)
                result.append(NSAttributedString(string: b.inner, attributes: attrs))
            case 1:
                if let f = attrs[.font] as? NSFont {
                    attrs[.font] = NSFont.boldSystemFont(ofSize: f.pointSize)
                }
                result.append(attributedInline(b.inner, base: attrs))
            case 2:
                if let f = attrs[.font] as? NSFont {
                    attrs[.font] = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask)
                }
                result.append(attributedInline(b.inner, base: attrs))
            case 3:
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                result.append(attributedInline(b.inner, base: attrs))
            default:
                attrs[.foregroundColor] = NSColor.linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                result.append(NSAttributedString(string: b.inner, attributes: attrs))
            }
            rest = (rest as NSString).substring(from: b.end)
        }
        return result
    }
}
