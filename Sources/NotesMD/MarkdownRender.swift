import AppKit
import Foundation

/// 进程内 Markdown -> NSAttributedString 渲染。
/// 不依赖 com.apple.textkit.nsattributedstringagent XPC 服务，
/// 因此即使在受限沙箱环境（如代理子进程）下也能正常渲染预览。
extension MarkdownRenderer {

    static func render(_ markdown: String) -> NSAttributedString {
        render(markdown, contentWidth: 720, onImageLoaded: nil)
    }

    /// 把 markdown 引用的本地图片同步读进 ImageStore 缓存，
    /// 使后续 render() 产出的富文本携带真实图片数据（粘贴进备忘录需要）。
    /// 远程图片仅用已有缓存，不阻塞。
    static func preloadLocalImages(in markdown: String) {
        let ns = markdown as NSString
        let full = NSRange(location: 0, length: ns.length)
        var seen = Set<String>()
        let patterns = [
            #"!\[[^\]]*\]\(([^)\s]+)\)"#,
            #"<img[^>]+src=[\"']([^\"']+)[\"']"#
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in re.matches(in: markdown, range: full) where m.numberOfRanges > 1 {
                let urlText = ns.substring(with: m.range(at: 1))
                let key = urlText.trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                if let url = ImageStore.url(from: key), url.isFileURL {
                    ImageStore.shared.loadLocalSync(url)
                }
            }
        }
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

    /// 行尾反斜杠是硬换行标记，渲染时不显示（行尾两个空格本身不产生可见字符）
    static func hardBreakMarkStripped(_ line: String) -> String {
        guard line.hasSuffix("\\"), !line.hasSuffix("\\\\") else { return line }
        return String(line.dropLast())
    }

    /// CommonMark 行内代码：N 个反引号开始、配对的 N 个反引号结束，
    /// 内容首尾各一个空格会被去掉（`` a ` b `` -> a ` b）
    static func scanCodeSpan(in s: String) -> (loc: Int, end: Int, text: String)? {
        let ns = s as NSString
        let units = Array(s.utf16)
        let backtick: UInt16 = 96
        var i = 0
        while i < units.count {
            guard units[i] == backtick else { i += 1; continue }
            var openLen = 0
            while i + openLen < units.count, units[i + openLen] == backtick { openLen += 1 }
            var j = i + openLen
            while j < units.count {
                if units[j] == backtick {
                    var closeLen = 0
                    while j + closeLen < units.count, units[j + closeLen] == backtick { closeLen += 1 }
                    if closeLen == openLen {
                        var text = ns.substring(with: NSRange(location: i + openLen,
                                                              length: j - i - openLen))
                        if text.count >= 2, text.hasPrefix(" "), text.hasSuffix(" "),
                           !text.allSatisfy({ $0 == " " }) {
                            text.removeFirst()
                            text.removeLast()
                        }
                        return (i, j + closeLen, text)
                    }
                    j += closeLen
                } else {
                    j += 1
                }
            }
            i += openLen            // 这一段反引号没有配对，继续往后找
        }
        return nil
    }

    /// 图片是否独占整行（只有独立成行的图片才在图下显示 alt 说明文字）
    static func isImageOnlyLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return MarkdownRenderer.match(#"^(?:!\[[^\]]*\]\([^)\s]+\)(?:\s*\{[^}]*\})?|<img[^>]*>)$"#, t) != nil
    }

    static func appendBlocks(_ blocks: [MDBlock], to out: NSMutableAttributedString,
                             indent: CGFloat, quoteDepth: Int,
                             contentWidth: CGFloat, onImageLoaded: (() -> Void)?) {
        let textColor: NSColor = quoteDepth > 0 ? .secondaryLabelColor : .labelColor
        let paraSize: CGFloat = quoteDepth > 0 ? 13 : 14

        func paraStyle(head: CGFloat, first: CGFloat? = nil,
                       before: CGFloat = 0, after: CGFloat = 0, line: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.headIndent = head
            // 默认首行也按 headIndent 缩进：否则引用块/对齐块内的首行不缩进，
            // 只有换行后的第二行起才有缩进（引用看起来像普通段落）
            p.firstLineHeadIndent = first ?? head
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
                // 每个源行各起一行（与写进备忘录的 <br> 语义一致），
                // 但段距只加在末行：否则多行段落的行距被拉成段落间距，看着像断成多段
                for (li, raw) in lines.enumerated() {
                    let p = paraStyle(head: indent,
                                      after: li == lines.count - 1 ? 8 : 0,
                                      line: 4)
                    let base: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: paraSize),
                        .foregroundColor: textColor,
                        .paragraphStyle: p
                    ]
                    out.append(attributedInline(hardBreakMarkStripped(raw), base: base,
                                                contentWidth: contentWidth,
                                                imageAlone: isImageOnlyLine(raw),
                                                onImageLoaded: onImageLoaded))
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
                // 先渲染引用内部，再整段补引用层级标记（已有的层级更深，保持不变）；
                // 预览区据此在左侧逐层绘制引用竖线
                let nested = NSMutableAttributedString()
                appendBlocks(inner, to: nested, indent: indent + 18, quoteDepth: quoteDepth + 1,
                             contentWidth: max(contentWidth - 18, 60), onImageLoaded: onImageLoaded)
                let full = NSRange(location: 0, length: nested.length)
                nested.enumerateAttribute(QuoteAttributes.depth, in: full, options: []) { v, r, _ in
                    if v == nil {
                        nested.addAttribute(QuoteAttributes.depth, value: quoteDepth + 1, range: r)
                    }
                }
                out.append(nested)

            case .list(let list):
                renderListInto(list, level: 0, into: out,
                               indent: indent, quoteDepth: quoteDepth,
                               contentWidth: contentWidth, onImageLoaded: onImageLoaded)

            case .table(let table):
                renderTable(table, into: out, quoteDepth: quoteDepth, contentWidth: contentWidth)

            case .hr:
                let p = paraStyle(head: indent, before: 6, after: 6)
                let ruleFont = NSFont.systemFont(ofSize: 12)
                let base: [NSAttributedString.Key: Any] = [
                    .font: ruleFont,
                    .foregroundColor: NSColor(white: 0.7, alpha: 1),
                    .paragraphStyle: p
                ]
                // 横线按内容宽度铺满（固定 36 个字符在宽窗口下只到半行，窄窗口下会溢出）
                let dashW = ("─" as NSString).size(withAttributes: [.font: ruleFont]).width
                let count = max(1, Int((contentWidth - indent) / max(dashW, 1)))
                out.append(NSAttributedString(string: String(repeating: "─", count: count) + "\n",
                                              attributes: base))

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
            p.firstLineHeadIndent = head
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
                for (li, line) in text.enumerated() {
                    var perLine = base
                    perLine[.paragraphStyle] = alignStyle(head: indent,
                                                          after: li == text.count - 1 ? 8 : 0, line: 4)
                    out.append(attributedInline(hardBreakMarkStripped(line), base: perLine,
                                                contentWidth: contentWidth,
                                                imageAlone: isImageOnlyLine(line),
                                                onImageLoaded: onImageLoaded))
                    out.append(NSAttributedString(string: "\n", attributes: perLine))
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
                bullet = "\(number)" + (list.parenthesized ? ")  " : ".  ")
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
            // 正文行与条目内嵌的围栏代码块按原文顺序输出（正文行为同段软换行，
            // 代码块按条目正文缩进整块填充底色）
            let parts: [MDList.Item.Part] = item.parts.isEmpty ? [.text("")] : item.parts
            // 代码块之后的正文是新段落，首行也要缩进到条目正文位置（否则回到项目符号处）
            let contStyle: NSParagraphStyle = {
                let p2 = NSMutableParagraphStyle()
                p2.headIndent = p.headIndent
                p2.firstLineHeadIndent = p.headIndent
                p2.paragraphSpacing = p.paragraphSpacing
                p2.lineSpacing = p.lineSpacing
                return p2
            }()
            var firstTextPart = true
            for part in parts {
                switch part {
                case .text(let line):
                    var lineBase = base
                    if !firstTextPart { lineBase[.paragraphStyle] = contStyle }
                    firstTextPart = false
                    out.append(attributedInline(line, base: lineBase,
                                                contentWidth: contentWidth,
                                                imageAlone: isImageOnlyLine(line),
                                                onImageLoaded: onImageLoaded))
                    out.append(NSAttributedString(string: "\n", attributes: lineBase))
                case .code(let lang, let lines):
                    appendBlocks([.code(lang: lang, lines: lines)], to: out, indent: head,
                                 quoteDepth: quoteDepth, contentWidth: contentWidth,
                                 onImageLoaded: onImageLoaded)
                }
            }
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

        // 1) 列宽分配：
        //    natural[c] = 列内最宽单元格单行宽度（ceil+1pt 余量，避免临界宽度下被挤成两行）
        //    minUnit[c] = 列内最长不可断片段宽度（CJK/全角单字可断行，连续西文/数字不可断）
        //    超宽时不再等比压缩所有列（会把「序号」这类短列挤到换行）：
        //    第一阶段只压缩有「可换行余量」的宽列（文本宽 > 3 个汉字的不保护），
        //    短列（序号、数量等）保持单行；仍放不下时第二阶段连同短列一起压，
        //    最后 20pt 硬下限兜底。每列压到 minW 为止，压满一轮后重新分配。
        var natural = [CGFloat](repeating: 24, count: colCount)
        var minUnit = [CGFloat](repeating: 0, count: colCount)
        for (ri, row) in norm.enumerated() {
            let f = ri == 0 ? headFont : font
            for (c, cell) in row.enumerated() {
                let plain = NSAttributedString(string: cell, attributes: [.font: f])
                natural[c] = max(natural[c], ceil(plain.size().width) + 1)
                minUnit[c] = max(minUnit[c], minUnitWidth(cell, font: f))
            }
        }
        let maxCol = contentWidth * 0.6
        var colW = natural.map { min(max($0 + padX * 2, 32), maxCol) }
        let minW = minUnit.map { max($0 + padX * 2, 24) }
        let avail = max(contentWidth, CGFloat(colCount) * 36)
        var total = colW.reduce(0, +)
        if total > avail {
            // 短列保护：内容不超过 3 个汉字宽度的列优先保持单行（如「序号」）
            let protected = colW.map { $0 - padX * 2 <= 36 }
            var deficit = total - avail
            func shrink(_ flex: [Int]) {
                for _ in 0...colCount {
                    guard deficit > 0.25 else { return }
                    let slackSum = flex.reduce(0) { $0 + max(colW[$1] - minW[$1], 0) }
                    guard slackSum > 0.25 else { return }
                    let ratio = deficit / slackSum
                    for c in flex {
                        let s = max(colW[c] - minW[c], 0)
                        colW[c] = max(colW[c] - min(s * ratio, s), minW[c])
                    }
                    deficit = colW.reduce(0, +) - avail
                }
            }
            shrink((0..<colCount).filter { !protected[$0] })
            shrink(Array(0..<colCount))
            total = colW.reduce(0, +)
        }
        if total > avail + 0.25 {
            let scale = avail / total
            colW = colW.map { max($0 * scale, 20) }
        } else if total < avail {
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

    /// 列最小宽度依据：列内最长「不可断」片段。
    /// CJK/全角字符允许在字符间断行（单字即一个片段）；
    /// 连续的西文、数字、标点视为整体不可断（如 "Z41H-16C"、"100"）。
    static func minUnitWidth(_ text: String, font: NSFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var maxW: CGFloat = 0
        var run = ""
        func flush() {
            if run.isEmpty { return }
            maxW = max(maxW, NSAttributedString(string: run, attributes: attrs).size().width)
            run = ""
        }
        for s in text.unicodeScalars {
            if isBreakableCJK(s) {
                flush()
                maxW = max(maxW, NSAttributedString(string: String(s), attributes: attrs).size().width)
            } else {
                run.unicodeScalars.append(s)
            }
        }
        flush()
        return maxW
    }

    private static func isBreakableCJK(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x1100...0x115F).contains(v)      // 谚文 Jamo
            || (0x2E80...0x303E).contains(v)      // 部首/康熙部首/CJK 符号
            || (0x3041...0x33FF).contains(v)      // 平假名/片假名/注音/兼容符号
            || (0x3400...0x4DBF).contains(v)      // CJK 扩展 A
            || (0x4E00...0x9FFF).contains(v)      // CJK 统一汉字
            || (0xA000...0xA4CF).contains(v)      // 彝文
            || (0xAC00...0xD7A3).contains(v)      // 谚文音节
            || (0xF900...0xFAFF).contains(v)      // CJK 兼容汉字
            || (0xFE30...0xFE4F).contains(v)      // CJK 兼容形式
            || (0xFF00...0xFF60).contains(v)      // 全角字符
            || (0xFFE0...0xFFE6).contains(v)      // 全角符号
            || (0x20000...0x3FFFD).contains(v)    // CJK 扩展 B 及以后
    }

    /// 内联语法 -> 富文本：行内代码 > 图片 > 加粗 > 斜体 > 删除线 > 链接 > 内联 HTML 标签
    static func attributedInline(_ raw: String, base: [NSAttributedString.Key: Any],
                                 contentWidth: CGFloat = 720,
                                 imageAlone: Bool = false,
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
                    let r = m.range(at: g)
                    // 可选分组未命中时为 {NSNotFound, 0}，占位空串保持下标对齐
                    groups.append(r.location == NSNotFound ? "" : (rest as NSString).substring(with: r))
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
            consider(#"!\[([^\]]*)\]\(([^)\s]+)\)(\{[^}]*\})?"#, kind: 2)
            // 粗斜体优先于加粗：否则 ***x*** 会被切成 **x* 并残留一个星号
            consider(#"(\*\*\*|___)([^*_]+?)\1"#, kind: 3)
            consider(#"(\*\*|__)(.+?)\1"#, kind: 4)
            consider(#"\*([^*\n]+?)\*"#, kind: 5)
            // 下划线斜体：词内下划线（snake_case_name）不作强调
            consider(#"(?<![A-Za-z0-9_])_([^_\n]+?)_(?![A-Za-z0-9])"#, kind: 5)
            consider(#"~~(.+?)~~"#, kind: 6)
            consider(#"<((?:https?|ftp)://[^<>\s]+)>"#, kind: 7)
            // 链接允许可选标题：[文本](url "标题")
            consider(#"\[((?:[^\[\]]|\[[^\]]*\])+)\]\(([^)\s]+)(?:\s+["'][^"']*["'])?\)"#, kind: 8)

            // 行内代码单独扫描（正则处理不了变长反引号定界），按位置参与排序
            if let cs = scanCodeSpan(in: rest),
               best == nil || cs.loc < best!.loc || (cs.loc == best!.loc && best!.kind > 1) {
                best = (cs.loc, cs.end, 1, [cs.text])
            }

            let tag = HtmlScanner.firstTag(in: rest)

            // HTML 注释 <!-- ... -->：整段跳过
            let nsRest = rest as NSString
            let cOpen = nsRest.range(of: "<!--")
            if cOpen.location != NSNotFound {
                let cClose = nsRest.range(of: "-->", range: NSRange(
                    location: cOpen.location + 4, length: nsRest.length - cOpen.location - 4))
                if cClose.location != NSNotFound,
                   (best == nil || cOpen.location < best!.loc),
                   (tag == nil || cOpen.location < tag!.range.location) {
                    let prefix = nsRest.substring(to: cOpen.location)
                    if !prefix.isEmpty {
                        result.append(NSAttributedString(string: prefix, attributes: base))
                    }
                    rest = nsRest.substring(from: cClose.location + 3)
                    continue
                }
            }

            // 内联 HTML 标签：比任何 Markdown 语法更靠前时先处理
            if let tag = tag,
               best == nil || tag.range.location < best!.loc {
                let (out, next) = renderHTMLTag(tag, rest: rest, base: base,
                                                contentWidth: contentWidth,
                                                imageAlone: imageAlone,
                                                onImageLoaded: onImageLoaded)
                result.append(out)
                rest = next
                continue
            }

            guard let b = best else {
                if !rest.isEmpty {
                    result.append(NSAttributedString(string: HtmlStyle.unescapeEntities(rest),
                                                     attributes: base))
                }
                break
            }

            let prefix = (rest as NSString).substring(to: b.loc)
            if !prefix.isEmpty {
                result.append(NSAttributedString(string: HtmlStyle.unescapeEntities(prefix),
                                                 attributes: base))
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
                // 支持尾部属性 {align=center width=70%}
                let alt = HtmlStyle.unescapeEntities(b.groups[0])
                let imageAttrs: ImageAttributes? = b.groups.count >= 3 && !b.groups[2].isEmpty
                    ? ImageAttrParser.parse(String(b.groups[2].dropFirst().dropLast()))
                    : nil
                if let imgAttr = makeImage(urlText: b.groups[1], alt: alt, attrs: attrs,
                                           imageAttrs: imageAttrs, allowCaption: imageAlone,
                                           contentWidth: contentWidth, onImageLoaded: onImageLoaded) {
                    result.append(imgAttr)
                } else {
                    result.append(NSAttributedString(string: "![](" + b.groups[1] + ")", attributes: attrs))
                }
            case 3:
                // 粗斜体 ***x*** / ___x___：分组 1 是分隔符，分组 2 才是内容
                if let f = attrs[.font] as? NSFont {
                    let bold = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
                    attrs[.font] = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
                }
                result.append(attributedInline(b.groups[1], base: attrs,
                                               contentWidth: contentWidth, imageAlone: imageAlone,
                                               onImageLoaded: onImageLoaded))
            case 4:
                if let f = attrs[.font] as? NSFont {
                    attrs[.font] = NSFont.boldSystemFont(ofSize: f.pointSize)
                }
                result.append(attributedInline(b.groups[1], base: attrs,
                                               contentWidth: contentWidth, imageAlone: imageAlone,
                                               onImageLoaded: onImageLoaded))
            case 5:
                if let f = attrs[.font] as? NSFont {
                    attrs[.font] = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask)
                }
                result.append(attributedInline(b.groups[0], base: attrs,
                                               contentWidth: contentWidth, imageAlone: imageAlone,
                                               onImageLoaded: onImageLoaded))
            case 6:
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                result.append(attributedInline(b.groups[0], base: attrs,
                                               contentWidth: contentWidth, imageAlone: imageAlone,
                                               onImageLoaded: onImageLoaded))
            case 7:
                // 自动链接 <url>
                attrs[.foregroundColor] = NSColor.linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                result.append(NSAttributedString(string: b.groups[0], attributes: attrs))
            default:
                // 链接：链接文字继续按行内语法渲染（[**加粗**](url) 等）
                attrs[.foregroundColor] = NSColor.linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                result.append(attributedInline(b.groups[0], base: attrs,
                                               contentWidth: contentWidth, imageAlone: imageAlone,
                                               onImageLoaded: onImageLoaded))
            }
            rest = (rest as NSString).substring(from: b.end)
        }
        return result
    }

    /// 渲染一个内联 HTML 标签，返回 (rest 起点至标签结束处的渲染结果, 剩余 rest)
    private static func renderHTMLTag(_ tag: HtmlTag, rest: String,
                                      base: [NSAttributedString.Key: Any],
                                      contentWidth: CGFloat,
                                      imageAlone: Bool = false,
                                      onImageLoaded: (() -> Void)?) -> (NSAttributedString, String) {
        let ns = rest as NSString
        let tagEnd = tag.range.location + tag.range.length
        let out = NSMutableAttributedString()
        let prefix = ns.substring(to: tag.range.location)
        if !prefix.isEmpty {
            out.append(NSAttributedString(string: prefix, attributes: base))
        }
        let name = tag.name
        func closeRange() -> (start: Int, end: Int)? {
            HtmlScanner.firstClosingTag(named: name, in: rest, from: tagEnd)
        }
        func lit() -> (NSAttributedString, String) {
            (NSAttributedString(string: ns.substring(with: tag.range), attributes: base),
             ns.substring(from: tagEnd))
        }

        if tag.closing {
            // 无配对的孤立闭合标签：原样保留
            return lit()
        }
        switch name {
        case "br":
            out.append(NSAttributedString(string: "\n", attributes: base))
            return (out, ns.substring(from: tagEnd))
        case "wbr":
            return (out, ns.substring(from: tagEnd))
        case "img":
            guard let src = tag.attr("src") else { return lit() }
            var ia = ImageAttributes()
            if let al = tag.attr("align")?.lowercased() {
                switch al {
                case "center": ia.align = .center
                case "right": ia.align = .right
                case "left": ia.align = .left
                default: break
                }
            }
            if let w = tag.attr("width"), let (v, pct) = ImageAttrParser.parseSize(w) {
                ia.width = v; ia.widthIsPercent = pct
            }
            if let h = tag.attr("height"), let (v, pct) = ImageAttrParser.parseSize(h) {
                ia.height = v; ia.heightIsPercent = pct
            }
            if let imgAttr = makeImage(urlText: src, alt: tag.attr("alt") ?? "",
                                       attrs: base,
                                       imageAttrs: ia.isEmpty ? nil : ia,
                                       allowCaption: imageAlone,
                                       contentWidth: contentWidth,
                                       onImageLoaded: onImageLoaded) {
                out.append(imgAttr)
            }
            return (out, ns.substring(from: tagEnd))
        case "a":
            if let close = closeRange() {
                var la = base
                la[.foregroundColor] = NSColor.linkColor
                la[.underlineStyle] = NSUnderlineStyle.single.rawValue
                let inner = ns.substring(with: NSRange(location: tagEnd, length: close.start - tagEnd))
                out.append(attributedInline(inner, base: la, contentWidth: contentWidth,
                                            imageAlone: imageAlone, onImageLoaded: onImageLoaded))
                return (out, ns.substring(from: close.end))
            }
            return lit()
        case "script", "style", "head", "meta", "link", "title", "noscript":
            if let close = closeRange() {
                return (out, ns.substring(from: close.end))
            }
            return lit()
        default:
            break
        }

        // 计算修改后的属性；nil = 透明标签（p/div/section 等，不改样式）
        var styled: [NSAttributedString.Key: Any]?
        switch name {
        case "b", "strong":
            var a = base
            if let f = a[.font] as? NSFont {
                a[.font] = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
            }
            styled = a
        case "i", "em":
            var a = base
            if let f = a[.font] as? NSFont {
                a[.font] = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask)
            }
            styled = a
        case "u", "ins":
            var a = base
            a[.underlineStyle] = NSUnderlineStyle.single.rawValue
            styled = a
        case "s", "strike", "del":
            var a = base
            a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            styled = a
        case "sub":
            var a = base
            if let f = a[.font] as? NSFont {
                a[.font] = HtmlStyle.withSize(f, f.pointSize * 0.75)
                a[.baselineOffset] = -f.pointSize * 0.2
            }
            styled = a
        case "sup":
            var a = base
            if let f = a[.font] as? NSFont {
                a[.font] = HtmlStyle.withSize(f, f.pointSize * 0.75)
                a[.baselineOffset] = f.pointSize * 0.3
            }
            styled = a
        case "mark":
            var a = base
            a[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.45)
            styled = a
        case "code":
            var a = base
            if let f = a[.font] as? NSFont {
                a[.font] = NSFont.monospacedSystemFont(ofSize: max(f.pointSize - 1.5, 10), weight: .regular)
            }
            styled = a
        case "small":
            var a = base
            if let f = a[.font] as? NSFont { a[.font] = HtmlStyle.withSize(f, f.pointSize * 0.85) }
            styled = a
        case "span":
            if let style = tag.attr("style") {
                var a = base
                for (k, v) in HtmlStyle.attributes(fromCSS: style, baseFont: base[.font] as? NSFont) {
                    a[k] = v
                }
                styled = a
            }
        case "font":
            var a = base
            var changed = false
            if let c = tag.attr("color"), let col = HtmlStyle.color(c) {
                a[.foregroundColor] = col
                changed = true
            }
            if let sz = tag.attr("size"), let n = Int(sz), (1...7).contains(n) {
                let sizes: [CGFloat] = [12, 14, 16, 18, 20, 24, 32]
                if let f = a[.font] as? NSFont {
                    a[.font] = HtmlStyle.withSize(f, sizes[n - 1])
                    changed = true
                }
            }
            styled = changed ? a : base
        default:
            break
        }
        let effective = styled ?? base

        if let close = closeRange() {
            let inner = ns.substring(with: NSRange(location: tagEnd, length: close.start - tagEnd))
            out.append(attributedInline(inner, base: effective, contentWidth: contentWidth,
                                        imageAlone: imageAlone, onImageLoaded: onImageLoaded))
            return (out, ns.substring(from: close.end))
        }
        if styled != nil {
            // 没有闭合标签：样式应用到剩余文字
            out.append(attributedInline(ns.substring(from: tagEnd), base: effective,
                                        contentWidth: contentWidth,
                                        imageAlone: imageAlone, onImageLoaded: onImageLoaded))
            return (out, "")
        }
        return lit()
    }

    /// 插入图片附件（含 alt 说明文字）；地址无法解析时返回 nil。
    /// imageAttrs：{align=center width=70%} 样式属性（尺寸 / 对齐）
    private static func makeImage(urlText: String, alt: String,
                                  attrs: [NSAttributedString.Key: Any],
                                  imageAttrs: ImageAttributes? = nil,
                                  allowCaption: Bool = true,
                                  contentWidth: CGFloat,
                                  onImageLoaded: (() -> Void)?) -> NSAttributedString? {
        guard let url = ImageStore.url(from: urlText) else { return nil }
        let maxWidth = max(contentWidth, 120)
        let attachment = NSTextAttachment()
        if let img = ImageStore.shared.cached(url) {
            let size = imageAttrs == nil
                ? ImageStore.fitSize(img.size, maxWidth: maxWidth, maxHeight: 560)
                : ImageAttrParser.displaySize(imgSize: img.size, contentMax: maxWidth,
                                              imageAttrs: imageAttrs)
            attachment.image = ImageStore.scaled(img, toSize: size)
        } else {
            var phSize = NSSize(width: min(240, maxWidth), height: 120)
            if let w = imageAttrs?.width {
                let base: CGFloat = imageAttrs!.widthIsPercent ? maxWidth : 360
                phSize = NSSize(width: max(w > 0 && imageAttrs!.widthIsPercent ? base * w : w, 40),
                                height: 120)
            }
            attachment.image = ImageStore.placeholder(size: phSize)
            ImageStore.shared.image(for: url) { img in
                if img != nil { onImageLoaded?() }
            }
        }
        // 对齐：图片独占一行，给图片字符与说明文字所在段落设置对齐方式
        var alignStyle: NSMutableParagraphStyle?
        if let align = imageAttrs?.align {
            var ps: NSMutableParagraphStyle
            if let existing = (attrs[.paragraphStyle] as? NSParagraphStyle)?.copy() as? NSMutableParagraphStyle {
                ps = existing
            } else {
                ps = NSMutableParagraphStyle()
            }
            ps.alignment = align
            alignStyle = ps
        }
        var out = NSMutableAttributedString(attachment: attachment)
        if let ps = alignStyle {
            out.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: 1))
        }
        if allowCaption, !alt.isEmpty {
            var caption = attrs
            if let f = caption[.font] as? NSFont {
                caption[.font] = NSFont.systemFont(ofSize: max(f.pointSize - 3, 10))
            }
            caption[.foregroundColor] = NSColor.secondaryLabelColor
            if let ps = alignStyle { caption[.paragraphStyle] = ps }
            out.append(NSAttributedString(string: "\n" + alt, attributes: caption))
        }
        return out
    }
}
