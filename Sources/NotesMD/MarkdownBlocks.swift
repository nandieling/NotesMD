import AppKit
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
        /// 条目正文行 / 条目内嵌的围栏代码块，按原文顺序排列（渲染顺序由此决定）
        enum Part {
            case text(String)
            case code(lang: String?, lines: [String])
        }
        var parts: [Part] = []
        var task: Int? = nil      // 0 未勾选、1 已勾选
        var children: [MDList] = []
    }
    var ordered: Bool
    var start: Int
    /// 有序列表用 `1)` 右括号标记（预览区据此显示 `1)` 而不是 `1.`）
    var parenthesized = false
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
    /// HTML 对齐标签块：<div align="center">…</div> / <p align="right">…</p> / <center>…</center>
    /// 块内按完整 Markdown 解析（标题、列表、表格等均可居中对齐）
    case aligned(align: NSTextAlignment, blocks: [MDBlock])
}

enum MDParser {

    static func blocks(from markdown: String) -> [MDBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return parseLines(resolveReferenceLinks(lines))
    }

    // MARK: - 引用式链接

    /// 参考定义行：`[标签]: URL "可选标题"`（行首最多三个空格，CommonMark）
    private static let refDefPattern =
        #"^\s{0,3}\[([^\]]+)\]:\s*(\S+)(?:\s+["'(][^"'()]*[)"'])?\s*$"#

    /// 收集并删掉参考定义行，同时把 [文本][标签]、[标签][]、[标签] 就地改写成内联链接。
    /// 定义可以写在文档任意位置；围栏代码块内的行原样保留。
    private static func resolveReferenceLinks(_ lines: [String]) -> [String] {
        var defs: [String: String] = [:]
        var isDef = [Bool](repeating: false, count: lines.count)
        var inFence = [Bool](repeating: false, count: lines.count)
        var fence: Character?
        for (idx, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let fc = fence {
                inFence[idx] = true
                if !t.isEmpty, t.allSatisfy({ $0 == fc }) { fence = nil }
                continue
            }
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                inFence[idx] = true
                fence = t[t.startIndex]
                continue
            }
            guard let m = MarkdownRenderer.match(refDefPattern, line) else { continue }
            let label = normalizeRefLabel(m[0])
            if !label.isEmpty, defs[label] == nil { defs[label] = m[1] }
            isDef[idx] = true
        }
        guard !defs.isEmpty else { return lines }
        var out: [String] = []
        for (idx, line) in lines.enumerated() {
            if isDef[idx] {
                out.append("")                        // 定义行本身不显示
            } else {
                out.append(inFence[idx] ? line : expandRefs(line, defs: defs))
            }
        }
        return out
    }

    /// 标签匹配忽略大小写与首尾、中间多余空白
    private static func normalizeRefLabel(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 展开一行内的引用式链接：完整式 [文本][标签]、折叠式 [标签][]、简写式 [标签]
    private static func expandRefs(_ line: String, defs: [String: String]) -> String {
        guard line.contains("]"),
              let re = try? NSRegularExpression(pattern: #"\[([^\[\]]+)\](\[([^\]]*)\])?"#)
        else { return line }
        let ns = line as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location < last { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = m.range.upperBound
            let text = ns.substring(with: m.range(at: 1))
            let hasSecond = m.range(at: 2).location != NSNotFound
            let second = hasSecond
                ? ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces) : ""
            let label = hasSecond ? (second.isEmpty ? text : second) : text
            // 紧跟 ( 的是内联链接 [文本](url)，不是引用式
            let next = last < ns.length ? ns.substring(with: NSRange(location: last, length: 1)) : ""
            if next != "(", let url = defs[normalizeRefLabel(label)] {
                out += "[\(text)](\(url))"
            } else {
                out += ns.substring(with: m.range)
            }
        }
        out += ns.substring(from: last)
        return out
    }

    static func parseLines(_ lines: [String]) -> [MDBlock] {
        var out: [MDBlock] = []
        var i = 0

        while i < lines.count {
            var line = lines[i]
            var trimmed = line.trimmingCharacters(in: .whitespaces)

            // 空行
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // HTML 注释 <!-- ... -->：跳过（可跨行；同行注释后可继续解析剩余内容）
            if trimmed.hasPrefix("<!--") {
                if let cr = trimmed.range(of: "-->") {
                    let restOfLine = String(trimmed[cr.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if restOfLine.isEmpty {
                        i += 1
                        continue
                    }
                    line = restOfLine
                    trimmed = restOfLine
                } else {
                    var j = i
                    while j < lines.count {
                        if lines[j].contains("-->") { j += 1; break }
                        j += 1
                    }
                    i = j
                    continue
                }
            }

            // 围栏代码块（``` 或 ~~~，可带语言名）
            if let (block, next) = parseFence(lines, from: i, stripIndent: 0) {
                out.append(block)
                i = next
                continue
            }

            // ATX 标题
            if let m = MarkdownRenderer.match(#"^(#{1,6})\s+(.+?)\s*#*\s*$"#, line) {
                out.append(.heading(level: m[0].count, text: m[1]))
                i += 1
                continue
            }

            // HTML 对齐标签块（居中/左/右）
            if let (align, first, closed) = parseAlignBlockStart(line) {
                var inner: [String] = []
                if !first.trimmingCharacters(in: .whitespaces).isEmpty { inner.append(first) }
                var j = i + 1
                if !closed {
                    while j < lines.count {
                        let t = lines[j].trimmingCharacters(in: .whitespaces)
                        if let closeIdx = Self.alignClosingIndex(in: t) {
                            let before = String(t[..<t.index(t.startIndex, offsetBy: closeIdx)])
                            if !before.trimmingCharacters(in: .whitespaces).isEmpty { inner.append(before) }
                            j += 1
                            break
                        }
                        inner.append(lines[j])
                        j += 1
                    }
                }
                out.append(.aligned(align: align, blocks: parseLines(inner)))
                i = max(j, i + 1)
                continue
            }

            // HTML 块标签（h1-h6 / hr / pre / blockquote / ul / ol / table / div / p 等）
            if trimmed.hasPrefix("<"),
               let tag = HtmlScanner.firstTag(in: trimmed), tag.range.location == 0,
               htmlBlockTagNames.contains(tag.name) {
                if tag.closing {
                    // 孤立的闭合标签行：忽略
                    i += 1
                    continue
                }
                let after = (trimmed as NSString).substring(from: tag.range.length)
                i = parseHTMLBlock(tag: tag, name: tag.name, after: after,
                                   lines: lines, i: i, out: &out)
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

            // 水平线：先于列表判定（`- - -`、`*  *  *` 既像列表项又是分隔线，CommonMark 取分隔线）
            if MarkdownRenderer.isHorizontalRule(trimmed) {
                out.append(.hr)
                i += 1
                continue
            }

            // 列表（含嵌套、任务项）
            if isUnorderedItem(line) || isOrderedItem(line) {
                let (list, next) = parseListLevel(
                    lines, i: i,
                    ordered: isOrderedItem(line),
                    start: orderedNumber(line),
                    baseIndent: indentOf(line),
                    parenthesized: orderedParen(line))
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

            // 缩进代码块：行首 4 空格或 Tab（CommonMark）；
            // 段落延续行、列表项内部缩进已在上面的分支处理，不会走到这里
            if indentOf(line) >= 4 {
                var code: [String] = []
                var blanks: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).isEmpty {
                        blanks.append("")
                        i += 1
                        continue
                    }
                    guard indentOf(l) >= 4 else { break }
                    code.append(contentsOf: blanks)     // 块内空行保留
                    blanks.removeAll(keepingCapacity: true)
                    code.append(dropIndent(l, 4))
                    i += 1
                }
                out.append(.code(lang: nil, lines: code))
                continue
            }

            // 段落：连续普通行；行内出现 setext 下划线则升级为标题
            var para: [String] = [stripLeading(line)]
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
                    || isUnorderedItem(lines[i]) || isOrderedItem(lines[i])
                    || parseAlignBlockStart(lines[i]) != nil
                    || isHTMLBlockStart(lines[i]) {
                    break
                }
                // 表格可紧跟段落（GFM 语义）：当前行含 | 且下一行是分隔行
                if t.contains("|"), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) {
                    break
                }
                para.append(stripLeading(lines[i]))      // 延续行行首空白不显示
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
                                       baseIndent: Int,
                                       parenthesized: Bool = false) -> (MDList, Int) {
        var list = MDList(ordered: ordered, start: start, parenthesized: parenthesized)
        var i = i
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                // 空行：松散列表里条目可以有多个段落，只要后面的行仍属于本列表
                // （缩进到条目正文位置，或同缩进的同类条目），否则列表结束
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                guard j < lines.count else { break }
                let nextLine = lines[j]
                let nextIsItem = isUnorderedItem(nextLine) || isOrderedItem(nextLine)
                guard indentOf(nextLine) >= baseIndent + 2
                    || (nextIsItem && indentOf(nextLine) == baseIndent) else { break }
                if !nextIsItem, !list.items.isEmpty {
                    list.items[list.items.count - 1].parts.append(.text(""))   // 条目内另起一段
                }
                i = j
                continue
            }
            let indent = indentOf(line)
            if indent < baseIndent { break }

            if indent > baseIndent {
                // 更深缩进：子列表、条目内的围栏代码块，或条目续行
                if isUnorderedItem(line) || isOrderedItem(line) {
                    let (sub, next) = parseListLevel(
                        lines, i: i,
                        ordered: isOrderedItem(line),
                        start: orderedNumber(line),
                        baseIndent: indent,
                        parenthesized: orderedParen(line))
                    if list.items.isEmpty { list.items.append(MDList.Item()) }
                    list.items[list.items.count - 1].children.append(sub)
                    i = next
                } else if let (block, next) = parseFence(lines, from: i, stripIndent: indent),
                          case let .code(lang, codeLines) = block {
                    if list.items.isEmpty { list.items.append(MDList.Item()) }
                    list.items[list.items.count - 1].parts.append(.code(lang: lang, lines: codeLines))
                    i = next
                } else {
                    if !list.items.isEmpty {
                        list.items[list.items.count - 1].parts.append(.text(t))
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
            item.parts = [.text(content)]
            list.items.append(item)
            i += 1
        }
        return (list, i)
    }

    // MARK: - HTML 对齐标签

    /// 识别行首的 <div align="…"> / <p align="…"> / <center|left|right> 起始标签。
    /// 返回 (对齐方式, 起始标签后的内容[已去掉同行闭合标签], 同一行内是否已闭合)。
    static func parseAlignBlockStart(_ line: String) -> (NSTextAlignment, String, Bool)? {
        var align: NSTextAlignment?
        var rest: String?
        if let m = MarkdownRenderer.match(#"^\s*<(div|p)\b[^>]*?\balign\s*=\s*["'"]?(center|right|left)["'"]?[^>]*>\s*(.*)$"#, line) {
            align = alignStyle(m[1])
            rest = m[2]
        } else if let m = MarkdownRenderer.match(#"^\s*<(center|left|right)>\s*(.*)$"#, line) {
            align = alignStyle(m[0])
            rest = m[1]
        }
        guard let a = align, let r0 = rest else { return nil }
        // 同行闭合：取第一个闭合标签之前的内容
        if let closeIdx = alignClosingIndex(in: r0) {
            return (a, String(r0[..<r0.index(r0.startIndex, offsetBy: closeIdx)]), true)
        }
        return (a, r0, false)
    }

    /// 行（去首尾空白后）以任一闭合标签结尾时，返回闭合标签在行内的起始下标
    static func alignClosingIndex(in t: String) -> Int? {
        let t = t.trimmingCharacters(in: .whitespaces)
        for tag in ["</div>", "</p>", "</center>", "</left>", "</right>"] {
            if t.hasSuffix(tag) { return t.count - tag.count }
        }
        return nil
    }

    static func alignStyle(_ s: String) -> NSTextAlignment {
        switch s.lowercased() {
        case "center": return .center
        case "right": return .right
        default: return .left
        }
    }

    // MARK: - HTML 块标签

    static let htmlBlockTagNames: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6", "hr", "pre", "blockquote",
        "ul", "ol", "table", "div", "section", "article", "main", "header", "footer", "p"
    ]

    /// 行是否以可识别的块级 HTML 标签开头（供段落提前结束判断）
    static func isHTMLBlockStart(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("<"), let tag = HtmlScanner.firstTag(in: t), tag.range.location == 0
        else { return false }
        return htmlBlockTagNames.contains(tag.name)
    }

    /// 解析 lines[i] 起始的 HTML 块，返回块结束后的行下标
    private static func parseHTMLBlock(tag: HtmlTag, name: String, after: String,
                                       lines: [String], i: Int,
                                       out: inout [MDBlock]) -> Int {
        // 同行已闭合：取闭合标签之前的内容
        func sameLineClose() -> (firstPart: String, next: Int)? {
            guard let idx = closingTagIndex(name, in: after) else { return nil }
            return ((after as NSString).substring(to: idx), i + 1)
        }
        func collect() -> (inner: [String], next: Int) {
            var inner: [String] = []
            if let close = sameLineClose() {
                if !close.firstPart.trimmingCharacters(in: .whitespaces).isEmpty { inner.append(close.firstPart) }
                return (inner, close.next)
            }
            let next = collectUntil(name, after: after, lines: lines, i: i, inner: &inner)
            return (inner, next)
        }
        switch name {
        case "hr":
            out.append(.hr)
            return i + 1
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let (inner, next) = collect()
            let text = inner.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                out.append(.heading(level: Int(name.suffix(1)) ?? 1, text: text))
            }
            return next
        case "pre":
            let (code0, next) = collect()
            var code = code0
            var lang: String?
            if let idx = code.firstIndex(where: { $0.range(of: "<code", options: .caseInsensitive) != nil }),
               let r = code[idx].range(of: "<code", options: .caseInsensitive),
               let gt = code[idx][r.upperBound...].firstIndex(of: ">") {
                let attrs = String(code[idx][r.upperBound..<gt])
                if let m = MarkdownRenderer.match(#"language-([a-zA-Z0-9#+-]+)"#, attrs) {
                    lang = m[0]
                }
                code[idx] = String(code[idx][code[idx].index(after: gt)...])
            }
            if let lastIdx = code.indices.last,
               let r = code[lastIdx].range(of: "</code>", options: .caseInsensitive) {
                code[lastIdx] = String(code[lastIdx][..<r.lowerBound])
            }
            if !code.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                out.append(.code(lang: lang, lines: code.map(HtmlStyle.unescapeEntities)))
            }
            return next
        case "blockquote":
            let (inner, next) = collect()
            if !inner.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                out.append(.quote(parseLines(inner)))
            }
            return next
        case "ul", "ol":
            let (innerLines, next) = collectBalanced(name, after: after, lines: lines, i: i)
            let start = Int(tag.attr("start") ?? "") ?? 1
            let md = htmlListToMarkdownLines(innerLines.joined(separator: "\n"),
                                             ordered: name == "ol", start: start, indent: 0)
            let (list, _) = parseListLevel(md, i: 0, ordered: name == "ol", start: start, baseIndent: 0)
            if !list.items.isEmpty { out.append(.list(list)) }
            return next
        case "table":
            let (innerLines, next) = collect()
            if let table = htmlTable(from: innerLines.joined(separator: "\n")) {
                out.append(.table(table))
            }
            return next
        case "p":
            let (inner, next) = collect()
            let body = inner.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !body.isEmpty { out.append(.paragraph(body)) }
            return next
        default:
            // div / section / article / main / header / footer：透明容器
            let (inner, next) = collect()
            out.append(contentsOf: parseLines(inner))
            return next
        }
    }

    /// 收集块内容（起始标签后的同行部分 + 后续行），直到含闭合标签的行（不含）
    private static func collectUntil(_ name: String, after: String,
                                     lines: [String], i: Int,
                                     inner: inout [String]) -> Int {
        if !after.trimmingCharacters(in: .whitespaces).isEmpty { inner.append(after) }
        if closingTagIndex(name, in: after) != nil { return i + 1 }
        var j = i + 1
        while j < lines.count {
            if let idx = closingTagIndex(name, in: lines[j]) {
                let before = (lines[j] as NSString).substring(to: idx)
                if !before.trimmingCharacters(in: .whitespaces).isEmpty { inner.append(before) }
                return j + 1
            }
            inner.append(lines[j])
            j += 1
        }
        return j
    }

    private static func closingTagIndex(_ name: String, in line: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: "</" + name + "\\s*>",
                                                options: [.caseInsensitive]) else { return nil }
        let ns = line as NSString
        guard let m = re.firstMatch(in: line,
                                    range: NSRange(location: 0, length: ns.length)) else { return nil }
        return m.range.location
    }

    /// 收集块内容，按同名标签嵌套计数（用于可嵌套的列表）。
    /// 除最终闭合标签外，行内的开/闭标签都原样保留在内容里。
    private static func collectBalanced(_ name: String, after: String,
                                        lines: [String], i: Int) -> (inner: [String], next: Int) {
        guard let openRe = try? NSRegularExpression(pattern: "<" + name + "\\b",
                                                    options: [.caseInsensitive]),
              let closeRe = try? NSRegularExpression(pattern: "</" + name + "\\s*>",
                                                     options: [.caseInsensitive]) else { return ([], i + 1) }
        var inner: [String] = []
        var depth = 1
        var text = after
        var j = i
        while true {
            var remaining = text
            while let ev = nextTagEvent(openRe, closeRe, in: remaining) {
                if ev.isClose {
                    depth -= 1
                    if depth == 0 {
                        let before = (remaining as NSString).substring(to: ev.start)
                        if !before.trimmingCharacters(in: .whitespaces).isEmpty { inner.append(before) }
                        return (inner, j + 1)
                    }
                } else {
                    depth += 1
                }
                // 嵌套的开/闭标签保留在内容中（整行稍后原样加入），扫描跳过该事件
                remaining = (remaining as NSString).substring(from: ev.end)
            }
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { inner.append(text) }
            j += 1
            guard j < lines.count else { break }
            text = lines[j]
        }
        return (inner, j)
    }

    private static func nextTagEvent(_ openRe: NSRegularExpression, _ closeRe: NSRegularExpression,
                                     in s: String) -> (isClose: Bool, start: Int, end: Int)? {
        let ns = s as NSString
        var best: (isClose: Bool, start: Int, end: Int)?
        func consider(_ re: NSRegularExpression, isClose: Bool) {
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length))
            else { return }
            if let b = best {
                if m.range.location < b.start {
                    best = (isClose, m.range.location, m.range.upperBound)
                }
            } else {
                best = (isClose, m.range.location, m.range.upperBound)
            }
        }
        consider(openRe, isClose: false)
        consider(closeRe, isClose: true)
        return best
    }

    /// 抽取 text 中指定标签的所有顶层块（按出现顺序）；同名嵌套整体消费
    static func topChunks(_ tags: [String], in text: String)
        -> [(name: String, attrs: [String: String], inner: String)] {
        let tagAlt = tags.joined(separator: "|")
        guard let openRe = try? NSRegularExpression(pattern: "<(" + tagAlt + ")\\b[^>]*>",
                                                   options: [.caseInsensitive]),
              let closeRe = try? NSRegularExpression(pattern: "</(" + tagAlt + ")\\s*>",
                                                     options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        var events: [(start: Int, end: Int, isClose: Bool, name: String, attrs: [String: String])] = []
        for m in openRe.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tagText = ns.substring(with: m.range)
            if let t = HtmlScanner.firstTag(in: tagText) {
                events.append((m.range.location, m.range.upperBound, false, t.name, t.attrs))
            }
        }
        for m in closeRe.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            events.append((m.range.location, m.range.upperBound, true, name, [:]))
        }
        events.sort { $0.start < $1.start }
        var out: [(name: String, attrs: [String: String], inner: String)] = []
        var depth = 0
        var curStart = 0
        var curName = ""
        var curAttrs: [String: String] = [:]
        for e in events {
            if !e.isClose {
                if depth == 0 {
                    curStart = e.end
                    curName = e.name
                    curAttrs = e.attrs
                }
                depth += 1
            } else {
                depth -= 1
                if depth == 0, curStart <= e.start {
                    let inner = ns.substring(with: NSRange(location: curStart, length: e.start - curStart))
                    out.append((curName, curAttrs, inner))
                }
            }
        }
        return out
    }

    /// HTML 列表内容 -> Markdown 列表行（复用既有 Markdown 列表解析，支持嵌套）
    private static func htmlListToMarkdownLines(_ text: String, ordered: Bool,
                                                start: Int, indent: Int) -> [String] {
        var out: [String] = []
        let pad = String(repeating: "    ", count: indent)
        var n = start
        for item in topChunks(["li"], in: text) {
            let (topLines, nested) = splitNestedLists(item.inner)
            let body = topLines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !body.isEmpty {
                out.append(pad + (ordered ? "\(n). " : "- ") + body[0])
                for extra in body.dropFirst() { out.append(pad + "    " + extra) }
            }
            n += 1
            for (childOrdered, childText) in nested {
                out += htmlListToMarkdownLines(childText, ordered: childOrdered,
                                               start: 1, indent: indent + 1)
            }
        }
        return out
    }

    /// 拆分条目内容：顶层文本（按行）+ 嵌套 ul/ol（按出现顺序）
    private static func splitNestedLists(_ text: String)
        -> (top: [String], nested: [(ordered: Bool, inner: String)]) {
        guard let openRe = try? NSRegularExpression(pattern: "<(ul|ol)\\b[^>]*>",
                                                   options: [.caseInsensitive]),
              let closeRe = try? NSRegularExpression(pattern: "</(ul|ol)\\s*>",
                                                     options: [.caseInsensitive])
        else { return (text.components(separatedBy: "\n"), []) }
        let ns = text as NSString
        var events: [(start: Int, end: Int, isClose: Bool, name: String)] = []
        for m in openRe.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            events.append((m.range.location, m.range.upperBound, false, name))
        }
        for m in closeRe.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            events.append((m.range.location, m.range.upperBound, true, name))
        }
        events.sort { $0.start < $1.start }
        var topParts: [String] = []
        var nested: [(ordered: Bool, inner: String)] = []
        var depth = 0
        var last = 0
        var openName = ""
        for e in events {
            if !e.isClose {
                if depth == 0 {
                    if e.start > last {
                        topParts.append(ns.substring(
                            with: NSRange(location: last, length: e.start - last)))
                    }
                    openName = e.name
                    last = e.end
                }
                depth += 1
            } else {
                depth -= 1
                if depth == 0 {
                    nested.append((openName == "ol",
                                   ns.substring(
                                       with: NSRange(location: last, length: e.start - last))))
                    last = e.end
                }
            }
        }
        if last < ns.length { topParts.append(ns.substring(from: last)) }
        return (topParts.flatMap { $0.components(separatedBy: "\n") }, nested)
    }

    /// 解析 <table>（tr/td/th，单元格可带 align）为 MDTable
    private static func htmlTable(from text: String) -> MDTable? {
        var cleaned = text
        for tag in ["thead", "tbody", "tfoot"] {
            cleaned = cleaned.replacingOccurrences(of: "<" + tag + "[^>]*>",
                                                   with: "", options: .caseInsensitive)
            cleaned = cleaned.replacingOccurrences(of: "</" + tag + ">",
                                                   with: "", options: .caseInsensitive)
        }
        let rows = topChunks(["tr"], in: cleaned)
        guard !rows.isEmpty else { return nil }
        var header: [String] = []
        var aligns: [Int] = []
        var dataRows: [[String]] = []
        var colCount = 0
        for (idx, row) in rows.enumerated() {
            let cells = topChunks(["td", "th"], in: row.inner)
            let rowCells = cells.map { HtmlStyle.unescapeEntities(htmlStripTags($0.inner)) }
            colCount = max(colCount, rowCells.count)
            if idx == 0 && header.isEmpty {
                header = rowCells
                aligns = cells.map { cellAlign($0.attrs) }
            } else {
                dataRows.append(rowCells)
            }
        }
        guard !header.isEmpty else { return nil }
        let pad = { (row: [String]) -> [String] in
            if row.count < header.count {
                return row + Array(repeating: "", count: header.count - row.count)
            }
            return Array(row.prefix(header.count))
        }
        return MDTable(header: header, aligns: aligns, rows: dataRows.map(pad))
    }

    private static func cellAlign(_ attrs: [String: String]) -> Int {
        switch (attrs["align"] ?? "").lowercased() {
        case "center": return 2
        case "right": return 3
        default: return 0
        }
    }

    /// 去掉所有 HTML 标签（<br> 换成空格），用于表格单元格纯文本
    static func htmlStripTags(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "<br\\s*/?>", with: " ", options: .caseInsensitive)
        while let r = t.range(of: "<[^>]+>", options: .regularExpression) {
            t.replaceSubrange(r, with: "")
        }
        return t
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

    /// 有序列表是否用 `1)` 右括号标记
    static func orderedParen(_ line: String) -> Bool {
        MarkdownRenderer.match(#"^\s*\d+[)]\s+"#, line) != nil
    }

    /// 去掉行首最多 width 列缩进（Tab 记 4 列）
    static func dropIndent(_ line: String, _ width: Int) -> String {
        var used = 0
        var idx = line.startIndex
        while idx < line.endIndex, used < width {
            let ch = line[idx]
            if ch == " " { used += 1 }
            else if ch == "\t" { used += 4 }
            else { break }
            idx = line.index(after: idx)
        }
        return String(line[idx...])
    }

    /// 从 from 行起读取围栏代码块（``` 或 ~~~，可带语言名）。
    /// stripIndent：块内每行最多去掉的缩进列数（列表项内的围栏要和条目内容对齐）。
    /// 返回代码块与围栏之后的下一行下标；围栏未闭合时读到文件末尾。
    static func parseFence(_ lines: [String], from: Int, stripIndent: Int) -> (MDBlock, Int)? {
        let trimmed = lines[from].trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
        let fenceChar = trimmed[trimmed.startIndex]
        var fenceLen = 0
        for ch in trimmed {
            if ch == fenceChar { fenceLen += 1 } else { break }
        }
        let lang = String(trimmed.dropFirst(fenceLen)).trimmingCharacters(in: .whitespaces)
        var code: [String] = []
        var i = from + 1
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            // 结束围栏：仅由同一字符组成且长度不小于开始围栏（CommonMark 语义）。
            // 代码内部“以 ``` 开头”的行（如内嵌示例、带语言名的行）不会提前结束块
            if !t.isEmpty, t.allSatisfy({ $0 == fenceChar }), t.count >= fenceLen { break }
            code.append(stripIndent == 0 ? lines[i] : dropIndent(lines[i], stripIndent))
            i += 1
        }
        if i < lines.count { i += 1 }
        return (.code(lang: lang.isEmpty ? nil : lang, lines: code), i)
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

    /// 去掉行首空白（段落首行与延续行的缩进按 CommonMark 不显示）
    static func stripLeading(_ line: String) -> String {
        String(line.drop(while: { $0 == " " || $0 == "\t" }))
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
