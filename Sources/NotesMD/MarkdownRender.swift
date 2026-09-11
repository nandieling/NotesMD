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
                let codeBg = NSColor(white: 0.93, alpha: 1)
                // 逐行成段：代码中间的空行会成为同属性的空段落，行间无段距，
                // 整块背景连续不断开；块间距只加在首行前 / 末行后。
                // .backgroundColor 保留给不走文本视图的路径（--png）；
                // CodeBlockAttributes 供 CodeBlockLayoutManager 做整块填充
                for (idx, line) in code.enumerated() {
                    let p = paraStyle(head: indent,
                                      before: idx == 0 ? 8 : 0,
                                      after: idx == code.count - 1 ? 8 : 0,
                                      line: 2)
                    let base: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                        .foregroundColor: textColor,
                        .backgroundColor: codeBg,
                        CodeBlockAttributes.background: codeBg,
                        .paragraphStyle: p
                    ]
                    out.append(NSAttributedString(string: line + "\n", attributes: base))
                }

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

            case .aligned(let align, let inner):
                renderAlignedBlocks(inner, align: align, into: out, indent: indent,
                                    quoteDepth: quoteDepth,
                                    contentWidth: contentWidth, onImageLoaded: onImageLoaded)
            }
        }
    }

    /// 对齐标签块内：标题/段落按指定对齐渲染（保留加粗与字号），其余块类型走通用渲染
    private static func renderAlignedBlocks(_ blocks: [MDBlock], align: NSTextAlignment,
                                            into out: NSMutableAttributedString,
                                            indent: CGFloat, quoteDepth: Int,
                                            contentWidth: CGFloat, onImageLoaded: (() -> Void)?) {
        let textColor: NSColor = quoteDepth > 0 ? .secondaryLabelColor : .labelColor
        let paraSize: CGFloat = quoteDepth > 0 ? 13 : 14

        func alignStyle(head: CGFloat, before: CGFloat = 0, after: CGFloat = 0, line: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.headIndent = head
            p.paragraphSpacingBefore = before
            p.paragraphSpacing = after
            p.lineSpacing = line
            p.alignment = align
            return p
        }

        for block in blocks {
            switch block {
            case .heading(let level, let text):
                let size = headingSizes[min(max(level, 1), 6) - 1]
                let base: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: size),
                    .foregroundColor: textColor,
                    .paragraphStyle: alignStyle(head: indent, before: 12, after: 4)
                ]
                out.append(attributedInline(text, base: base,
                                            contentWidth: contentWidth, onImageLoaded: onImageLoaded))
                out.append(NSAttributedString(string: "\n", attributes: base))

            case .paragraph(let lines):
                let base: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: paraSize),
                    .foregroundColor: textColor,
                    .paragraphStyle: alignStyle(head: indent, after: 8, line: 4)
                ]
                let text = lines.isEmpty ? [""] : lines
                for line in text {
                    out.append(attributedInline(line, base: base,
                                                contentWidth: contentWidth, onImageLoaded: onImageLoaded))
                    out.append(NSAttributedString(string: "\n", attributes: base))
                }

            default:
                appendBlocks([block], to: out, indent: indent, quoteDepth: quoteDepth,
                              contentWidth: contentWidth, onImageLoaded: onImageLoaded)
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
        guard contentWidth >= 80, !table.header.isEmpty else { return }
        let img = makeTableImage(table: table, contentWidth: contentWidth, quoteDepth: quoteDepth)
        let att = NSTextAttachment()
        att.image = img
        out.append(NSAttributedString(attachment: att))
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 6
        p.paragraphSpacing = 10
        out.append(NSAttributedString(string: "\n",
                                       attributes: [.paragraphStyle: p, .font: NSFont.systemFont(ofSize: 12)]))
    }

    /// 把表格渲染成一张带完整框线的图片（表头加粗带底色、支持左/中/右对齐、自动换行），
    /// 再以文本附件插入预览。纯文本流式排版画不出竖线，所以用离屏绘制。
    static func makeTableImage(table: MDTable, contentWidth: CGFloat, quoteDepth: Int) -> NSImage {
        let font = NSFont.systemFont(ofSize: 12)
        let headFont = NSFont.boldSystemFont(ofSize: 12)
        let textColor = quoteDepth > 0 ? NSColor.secondaryLabelColor : NSColor.labelColor
        let colCount = max(table.header.count, table.rows.map { $0.count }.max() ?? 1)
        guard colCount > 0 else { return NSImage(size: NSSize(width: 2, height: 2)) }
        let rows = [table.header] + table.rows
        let norm: [[String]] = rows.map { row in
            var r = row
            while r.count < colCount { r.append("") }
            return Array(r.prefix(colCount))
        }
        let padX: CGFloat = 8, padY: CGFloat = 6

        // 1) 列宽：按单元格单行自然宽度取列最大值，限制上限后整体压缩/拉伸到 contentWidth
        var natural = [CGFloat](repeating: 24, count: colCount)
        for (ri, row) in norm.enumerated() {
            let f = ri == 0 ? headFont : font
            for (c, cell) in row.enumerated() {
                let plain = NSAttributedString(string: cell, attributes: [.font: f])
                natural[c] = max(natural[c], plain.size().width)
            }
        }
        let maxCol = contentWidth * 0.6
        var colW = natural.map { min(max($0 + padX * 2, 32), maxCol) }
        let avail = max(contentWidth, CGFloat(colCount) * 36)
        var total = colW.reduce(0, +)
        if total > avail {
            let scale = avail / total
            colW = colW.map { max($0 * scale, 20) }
            total = colW.reduce(0, +)
        }
        if total < avail {
            let scale = avail / total
            colW = colW.map { $0 * scale }
        }

        // 2) 行高：按最终列宽对每个单元格做换行测量（对齐交给段落样式，多行也正确）
        func cellAttr(_ text: String, _ f: NSFont, width: CGFloat, align: Int) -> NSAttributedString {
            attributedInline(text, base: [.font: f, .foregroundColor: textColor,
                                          .paragraphStyle: tableParaStyle(align: align)],
                             contentWidth: width, onImageLoaded: nil)
        }
        func alignOf(_ c: Int) -> Int { c < table.aligns.count ? table.aligns[c] : 0 }
        var rowHs: [CGFloat] = []
        for (ri, row) in norm.enumerated() {
            let f = ri == 0 ? headFont : font
            var h: CGFloat = 16
            for (c, cell) in row.enumerated() {
                let w = max(colW[c] - padX * 2, 8)
                let attr = cellAttr(cell, f, width: w, align: alignOf(c))
                let rect = attr.boundingRect(
                    with: NSSize(width: w, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin], context: nil)
                h = max(h, rect.height)
            }
            rowHs.append(h + padY * 2)
        }

        let tableW = colW.reduce(0, +)
        let tableH = rowHs.reduce(0, +)
        let size = NSSize(width: ceil(tableW), height: ceil(tableH))
        let image = NSImage(size: size)
        image.lockFocus()

        // 3) 表头底色
        NSColor.quaternaryLabelColor.setFill()
        NSRect(x: 0, y: size.height - rowHs[0], width: size.width, height: rowHs[0]).fill()

        // 4) 单元格文字（段落样式控制对齐，顶端对齐）
        var yTop = size.height
        for (ri, row) in norm.enumerated() {
            let rowH = rowHs[ri]
            yTop -= rowH
            let f = ri == 0 ? headFont : font
            var x: CGFloat = 0
            for (c, cell) in row.enumerated() {
                let w = colW[c]
                let textW = max(w - padX * 2, 1)
                let align = alignOf(c)
                let attr = cellAttr(cell, f, width: textW, align: align)
                let rect = attr.boundingRect(
                    with: NSSize(width: textW, height: rowH),
                    options: [.usesLineFragmentOrigin], context: nil)
                attr.draw(with: NSRect(x: x + padX, y: yTop + rowH - padY - rect.height,
                                       width: textW, height: rect.height),
                          options: [.usesLineFragmentOrigin], context: nil)
                x += w
            }
        }

        // 5) 框线：外框 + 内部竖线 + 行间横线（表头下横线加粗）
        NSColor.tertiaryLabelColor.setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 1
        grid.appendRect(NSRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1))
        var vx: CGFloat = 0
        for c in 0..<(colCount - 1) {
            vx += colW[c]
            let xx = (vx + 0.5).rounded()
            grid.move(to: NSPoint(x: xx, y: 0))
            grid.line(to: NSPoint(x: xx, y: size.height))
        }
        var hy: CGFloat = size.height
        for ri in 0..<(norm.count - 1) {
            hy -= rowHs[ri]
            grid.move(to: NSPoint(x: 0, y: hy.rounded()))
            grid.line(to: NSPoint(x: size.width, y: hy.rounded()))
        }
        grid.stroke()
        let headLine = NSBezierPath()
        headLine.lineWidth = 1.5
        let hyHead = (size.height - rowHs[0]).rounded()
        headLine.move(to: NSPoint(x: 0, y: hyHead))
        headLine.line(to: NSPoint(x: size.width, y: hyHead))
        headLine.stroke()

        image.unlockFocus()
        return image
    }

    private static func tableParaStyle(align: Int) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        switch align {
        case 1: p.alignment = .left
        case 2: p.alignment = .center
        case 3: p.alignment = .right
        default: p.alignment = .left
        }
        p.lineSpacing = 2
        return p
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
                // 行内代码只换等宽字体，不加背景填充；背景底色只属于三引号（围栏）代码块
                if let f = attrs[.font] as? NSFont {
                    attrs[.font] = NSFont.monospacedSystemFont(ofSize: max(f.pointSize - 1.5, 10), weight: .regular)
                }
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
