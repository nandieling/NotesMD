import AppKit
import Foundation

/// 进程内 Markdown -> NSAttributedString 渲染。
/// 不依赖 com.apple.textkit.nsattributedstringagent XPC 服务，
/// 因此即使在受限沙箱环境（如代理子进程）下也能正常渲染预览。
extension MarkdownRenderer {

    static func render(_ markdown: String) -> NSAttributedString {
        render(markdown, contentWidth: 720, onImageLoaded: nil)
    }

    /// - contentWidth: 预览区内容宽度（pt），用于约束图床图片展示尺寸
    /// - onImageLoaded: 某张图床图片下载完成后回调（用于重新渲染）
    static func render(_ markdown: String,
                       contentWidth: CGFloat,
                       onImageLoaded: (() -> Void)? = nil) -> NSAttributedString {
        let out = NSMutableAttributedString()
        appendBlocks(MDParser.blocks(from: markdown), to: out, indent: 0, quoteDepth: 0,
                     contentWidth: contentWidth, onImageLoaded: onImageLoaded)
        return out
    }

    // MARK: - 块级序列化

    private static let headingSizes: [CGFloat] = [24, 20, 17, 15, 14, 13]

    static func appendBlocks(_ blocks: [MDBlock], to out: NSMutableAttributedString,
                             indent: CGFloat, quoteDepth: Int,
                             contentWidth: CGFloat, onImageLoaded: (() -> Void)?) {
        let textColor: NSColor = quoteDepth > 0 ? .secondaryLabelColor : .labelColor
        let paraSize: CGFloat = quoteDepth > 0 ? 13 : 14

        func paraStyle(head: CGFloat, first: CGFloat? = nil,
                       before: CGFloat = 0, after: CGFloat = 0, line: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.headIndent = head
            if let first { p.firstLineHeadIndent = first }
            p.paragraphSpacingBefore = before
            p.paragraphSpacing = after
            p.lineSpacing = line
            return p
        }

        for block in blocks {
            switch block {
            case .heading(let level, let text):
                let size = headingSizes[min(max(level, 1), 6) - 1]
                let p = paraStyle(head: indent, before: 12, after: 4)
                let base: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: size),
                    .foregroundColor: textColor,
                    .paragraphStyle: p
                ]
                out.append(attributedInline(text, base: base,
                                            contentWidth: contentWidth, onImageLoaded: onImageLoaded))
                out.append(NSAttributedString(string: "\n", attributes: base))

            case .paragraph(let lines):
                let p = paraStyle(head: indent, after: 8, line: 4)
                let base: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: paraSize),
                    .foregroundColor: textColor,
                    .paragraphStyle: p
                ]
                for line in lines {
                    out.append(attributedInline(line, base: base,
                                                contentWidth: contentWidth, onImageLoaded: onImageLoaded))
                    out.append(NSAttributedString(string: "\n", attributes: base))
                }

            case .code(_, let code):
                let p = paraStyle(head: indent, before: 8, after: 8, line: 2)
                let base: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: textColor,
                    .backgroundColor: NSColor(white: 0.93, alpha: 1),
                    .paragraphStyle: p
                ]
                out.append(NSAttributedString(string: code.joined(separator: "\n") + "\n", attributes: base))

            case .quote(let inner):
                appendBlocks(inner, to: out, indent: indent + 18, quoteDepth: quoteDepth + 1,
                             contentWidth: max(contentWidth - 18, 60), onImageLoaded: onImageLoaded)

            case .list(let list):
                renderListInto(list, level: 0, into: out,
                               indent: indent, quoteDepth: quoteDepth,
                               contentWidth: contentWidth, onImageLoaded: onImageLoaded)

            case .table(let table):
                renderTable(table, into: out, quoteDepth: quoteDepth, contentWidth: contentWidth)

            case .hr:
                let p = paraStyle(head: indent, before: 6, after: 6)
                let base: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor(white: 0.7, alpha: 1),
                    .paragraphStyle: p
                ]
                out.append(NSAttributedString(string: String(repeating: "─", count: 36) + "\n", attributes: base))
            }
        }
    }

    private static func renderListInto(_ list: MDList, level: Int,
                                       into out: NSMutableAttributedString,
                                       indent: CGFloat, quoteDepth: Int,
                                       contentWidth: CGFloat, onImageLoaded: (() -> Void)?) {
        let textColor: NSColor = quoteDepth > 0 ? .secondaryLabelColor : .labelColor
        let size: CGFloat = quoteDepth > 0 ? 13 : 14
        var number = list.ordered ? list.start - 1 : 0

        for item in list.items {
            if list.ordered { number += 1 }
            var head = indent + CGFloat(level) * 18
            var firstLine: CGFloat?
            var bullet = ""
            if item.task != nil {
                head += 16
                firstLine = indent + CGFloat(level) * 18
                bullet = (item.task == 1) ? "☑  " : "☐  "
            } else if list.ordered {
                head += 24
                firstLine = indent + CGFloat(level) * 18 + 4
                bullet = "\(number).  "
            } else {
                head += 20
                firstLine = indent + CGFloat(level) * 18
                bullet = "\u{2022}  "
            }
            let p = NSMutableParagraphStyle()
            p.headIndent = head
            if let fl = firstLine { p.firstLineHeadIndent = fl }
            p.paragraphSpacing = 2
            p.lineSpacing = 3
            let base: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: textColor,
                .paragraphStyle: p
            ]
            out.append(NSAttributedString(string: bullet, attributes: base))
            let textLines = item.text.isEmpty ? [""] : item.text
            for (li, line) in textLines.enumerated() {
                out.append(attributedInline(line, base: base,
                                            contentWidth: contentWidth, onImageLoaded: onImageLoaded))
                if li < textLines.count - 1 {
                    out.append(NSAttributedString(string: "\n", attributes: base))
                }
            }
            out.append(NSAttributedString(string: "\n", attributes: base))
            for sub in item.children {
                renderListInto(sub, level: level + 1, into: out,
                               indent: indent, quoteDepth: quoteDepth,
                               contentWidth: contentWidth, onImageLoaded: onImageLoaded)
            }
        }
    }

    private static func renderTable(_ table: MDTable, into out: NSMutableAttributedString,
                                    quoteDepth: Int, contentWidth: CGFloat) {
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let rows = [table.header] + table.rows
        let colCount = max(table.header.count, rows.map { $0.count }.max() ?? 1)

        // 列宽：按最宽单元格计算（等宽字体下 CJK 记 2 个字符宽），超宽时整体压缩
        var widths = [Int](repeating: 4, count: colCount)
        for row in rows {
            for (c, cell) in row.enumerated() where c < colCount {
                widths[c] = max(widths[c], displayWidth(cell))
            }
        }
        let budget = max(Int(contentWidth) / 7, colCount * 2)
        if widths.reduce(0, +) + (colCount - 1) * 2 > budget {
            let scale = Double(budget) / Double(widths.reduce(0, +) + (colCount - 1) * 2)
            widths = widths.map { max(2, Int(Double($0) * scale)) }
        }

        let textColor = quoteDepth > 0 ? NSColor.secondaryLabelColor : NSColor.labelColor
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 4
        p.paragraphSpacing = 4
        for (ri, row) in rows.enumerated() {
            var cells: [String] = []
            for c in 0..<colCount {
                let raw = c < row.count ? row[c] : ""
                cells.append(padCell(raw, to: widths[c]))
            }
            var base: [NSAttributedString.Key: Any] = [
                .font: mono,
                .foregroundColor: textColor,
                .paragraphStyle: p
            ]
            if ri == 0 {
                base[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            }
            out.append(NSAttributedString(string: cells.joined(separator: "  ") + "\n", attributes: base))
        }
    }

    /// 等宽字体下的显示宽度（CJK 全角记 2）
    static func displayWidth(_ s: String) -> Int {
        var w = 0
        for ch in s {
            let v = Int(ch.unicodeScalars.first?.value ?? 0)
            w += isWide(v) ? 2 : 1
        }
        return w
    }

    static func isWide(_ v: Int) -> Bool {
        (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v)
            || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0x20000...0x3FFFD).contains(v)
    }

    static func padCell(_ s: String, to width: Int) -> String {
        let w = displayWidth(s)
        if w <= width {
            return s + String(repeating: " ", count: width - w)
        }
        var chars: [Character] = []
        var cw = 0
        for ch in s {
            let v = Int(ch.unicodeScalars.first?.value ?? 0)
            let cw2 = isWide(v) ? 2 : 1
            if cw + cw2 > width - 1 { break }
            chars.append(ch)
            cw += cw2
        }
        return String(chars) + "…"
    }

    /// 内联语法 -> 富文本：行内代码 > 图片 > 加粗 > 斜体 > 删除线 > 链接
    static func attributedInline(_ raw: String, base: [NSAttributedString.Key: Any],
                                 contentWidth: CGFloat = 720,
                                 onImageLoaded: (() -> Void)? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var rest = raw

        while true {
            var best: (loc: Int, end: Int, kind: Int, groups: [String])?
            func consider(_ pattern: String, kind: Int) {
                guard let re = try? NSRegularExpression(pattern: pattern),
                      let m = re.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)),
                      m.range.location != NSNotFound else { return }
                var groups: [String] = []
                for g in 1..<m.numberOfRanges {
                    groups.append((rest as NSString).substring(with: m.range(at: g)))
                }
                if let cur = best {
                    if m.range.location < cur.loc || (m.range.location == cur.loc && kind < cur.kind) {
                        best = (m.range.location, m.range.upperBound, kind, groups)
                    }
                } else {
                    best = (m.range.location, m.range.upperBound, kind, groups)
                }
            }
            consider(#"(\\)([\\`*_{}\[\]()#+.!>~-])"#, kind: 0)
            consider(#"`([^`]+)`"#, kind: 1)
            consider(#"!\[([^\]]*)\]\(([^)\s]+)\)"#, kind: 2)
            consider(#"(\*\*|__)(.+?)\1"#, kind: 3)
            consider(#"(\*|_)([^*_]+?)\1"#, kind: 4)
            consider(#"~~(.+?)~~"#, kind: 5)
            consider(#"<((?:https?|ftp)://[^<>\s]+)>"#, kind: 6)
            consider(#"\[([^\]]+)\]\(([^)\s]+)\)"#, kind: 7)

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
                // 反斜杠转义：输出被转义字符本身（纯文本）
                result.append(NSAttributedString(string: b.groups[1], attributes: base))
            case 1:
                if let f = attrs[.font] as? NSFont {
                    attrs[.font] = NSFont.monospacedSystemFont(ofSize: max(f.pointSize - 1.5, 10), weight: .regular)
                }
                attrs[.backgroundColor] = NSColor(white: 0.93, alpha: 1)
                result.append(NSAttributedString(string: b.groups[0], attributes: attrs))
            case 2:
                // 图床图片：以文本附件插入；未命中缓存时先放占位图，下载完成后整体重渲染
                let alt = b.groups[0]
                if let url = ImageStore.url(from: b.groups[1]) {
                    let maxWidth = max(contentWidth, 120)
                    let attachment = NSTextAttachment()
                    if let img = ImageStore.shared.cached(url) {
                        attachment.image = ImageStore.scaled(
                            img, toSize: ImageStore.fitSize(img.size, maxWidth: maxWidth, maxHeight: 560))
                    } else {
                        attachment.image = ImageStore.placeholder(
                            size: NSSize(width: min(240, maxWidth), height: 120))
                        ImageStore.shared.image(for: url) { img in
                            if img != nil { onImageLoaded?() }
                        }
                    }
                    result.append(NSAttributedString(attachment: attachment))
                    if !alt.isEmpty {
                        var caption = attrs
                        if let f = caption[.font] as? NSFont {
                            caption[.font] = NSFont.systemFont(ofSize: max(f.pointSize - 3, 10))
                        }
                        caption[.foregroundColor] = NSColor.secondaryLabelColor
                        result.append(NSAttributedString(string: "\n" + alt, attributes: caption))
                    }
                } else {
                    result.append(NSAttributedString(string: "![](" + b.groups[1] + ")", attributes: attrs))
                }
            case 3:
                if let f = attrs[.font] as? NSFont {
                    attrs[.font] = NSFont.boldSystemFont(ofSize: f.pointSize)
                }
                result.append(attributedInline(b.groups[1], base: attrs,
                                               contentWidth: contentWidth, onImageLoaded: onImageLoaded))
            case 4:
                if let f = attrs[.font] as? NSFont {
                    attrs[.font] = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask)
                }
                result.append(attributedInline(b.groups[1], base: attrs,
                                               contentWidth: contentWidth, onImageLoaded: onImageLoaded))
            case 5:
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                result.append(attributedInline(b.groups[0], base: attrs,
                                               contentWidth: contentWidth, onImageLoaded: onImageLoaded))
            case 6:
                // 自动链接 <url>
                attrs[.foregroundColor] = NSColor.linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                result.append(NSAttributedString(string: b.groups[0], attributes: attrs))
            default:
                attrs[.foregroundColor] = NSColor.linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                result.append(NSAttributedString(string: b.groups[0], attributes: attrs))
            }
            rest = (rest as NSString).substring(from: b.end)
        }
        return result
    }
}
