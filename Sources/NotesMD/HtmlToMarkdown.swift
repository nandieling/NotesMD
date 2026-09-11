import Foundation

// MARK: - 轻量 HTML 解析（Notes 读回的正文用）

struct HTMLNode {
    enum Kind {
        case text(String)
        case br
        case element(name: String, attrs: [String: String], children: [HTMLNode])
    }
    let kind: Kind
}

enum HTMLParser {
    private static let tagRe: NSRegularExpression = {
        try! NSRegularExpression(pattern: "<(/?)([a-zA-Z][a-zA-Z0-9]*)((?:\"[^\"]*\"|'[^']*'|[^>\"])*)>")
    }()

    private static let attrRe: NSRegularExpression = {
        try! NSRegularExpression(pattern: "([a-zA-Z][a-zA-Z0-9-]*)\\s*=\\s*\"([^\"]*)\"")
    }()

    static func parse(_ html: String) -> [HTMLNode] {
        let ns = html as NSString
        let (nodes, _, _) = scan(html, ns: ns, from: 0, closing: nil)
        return nodes
    }

    /// 扫描直到 </closing>；返回 (节点, 结束位置, 是否被自己的结束标签闭合)。
    /// 容忍 Notes 的不闭合/错配标记：遇到“陌生结束标签”时当前块提前结束。
    private static func scan(_ s: String, ns: NSString, from start: Int,
                             closing: String?) -> ([HTMLNode], Int, Bool) {
        var nodes: [HTMLNode] = []
        var openTags: Set<String> = []
        var pos = start
        while pos < ns.length {
            let range = NSRange(location: pos, length: ns.length - pos)
            guard let m = tagRe.firstMatch(in: s, range: range) else {
                let rest = ns.substring(from: pos)
                if !rest.isEmpty { nodes.append(HTMLNode(kind: .text(rest))) }
                return (nodes, ns.length, closing == nil)
            }
            if m.range.location > pos {
                nodes.append(HTMLNode(kind: .text(ns.substring(
                    with: NSRange(location: pos, length: m.range.location - pos)))))
            }
            let isClosing = m.range(at: 1).length > 0
            let name = ns.substring(with: m.range(at: 2)).lowercased()
            let tagStart = m.range.location
            pos = m.range.upperBound
            if isClosing {
                if name == closing { return (nodes, pos, true) }
                if openTags.remove(name) != nil { continue }
                if closing == nil { continue }  // 顶层：忽略错配结束标签
                return (nodes, tagStart, false)
            }
            if name == "br" { nodes.append(HTMLNode(kind: .br)); continue }
            if name == "hr" {
                nodes.append(HTMLNode(kind: .element(name: "hr", attrs: [:], children: [])))
                continue
            }
            let attrs = m.range(at: 3).length > 0
                ? parseAttrs(ns.substring(with: m.range(at: 3))) : [:]
            if name == "img" || name == "meta" || name == "link" {
                nodes.append(HTMLNode(kind: .element(name: name, attrs: attrs, children: [])))
                continue
            }
            let (children, end, closed) = scan(s, ns: ns, from: pos, closing: name)
            if !closed { openTags.insert(name) }
            nodes.append(HTMLNode(kind: .element(name: name, attrs: attrs, children: children)))
            pos = end
        }
        return (nodes, pos, closing == nil)
    }

    private static func parseAttrs(_ s: String) -> [String: String] {
        let ns = s as NSString
        var out: [String: String] = [:]
        for m in attrRe.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out[ns.substring(with: m.range(at: 1)).lowercased()] =
                ns.substring(with: m.range(at: 2))
        }
        return out
    }
}

// MARK: - Notes HTML -> Markdown

/// 把备忘录正文（Notes 读回的 HTML）转成 Markdown。
/// 覆盖 Notes 实际产生的结构：24px/18px 标题、加粗/斜体/删除线/行内代码、
/// Courier 代码块、有序/无序/嵌套列表、☑☐ 任务项、表格、灰色横线、<br> 换行。
/// 已知不可逆（Notes 已丢失信息）：链接 href（只剩下划线文字）、引用样式。
/// 表格列对齐：Notes 读回的 HTML 不含对齐信息，由 NotePushCache 记住的
/// 最近一次推送内容恢复（restoreTableAlignments）；HTML 恰好带 align 时直接采用。
enum MarkdownFromHTML {

    static func convert(_ html: String) -> String {
        convertNodes(HTMLParser.parse(html))
    }

    /// Notes 读回的 HTML 丢失表格列对齐（align / text-align 均不保留）。
    /// 用 source（本软件最近一次写入该备忘录的 markdown）恢复各表的分隔行对齐：
    /// 匹配「列数相同且表头一致」的源表格，每个源表格最多用一次；匹配不上保持默认。
    /// 两轮匹配：先严格（仅忽略空白与格式符号），再宽松（仅比较字母数字，
    /// 容忍全角/半角括号等差异，如 「体重 (kg)」 与 「体重（kg）」）。
    static func restoreTableAlignments(_ loaded: String, from source: String) -> String {
        let srcTables = tableSpecs(source.components(separatedBy: "\n"))
        guard !srcTables.isEmpty else { return loaded }
        func strict(_ cell: String) -> String {
            cell.filter { !$0.isWhitespace && !"_*`~".contains($0) }
        }
        func loose(_ cell: String) -> String {
            cell.filter { $0.isLetter || $0.isNumber }
        }
        var lines = loaded.components(separatedBy: "\n")
        struct LT { let line: Int; let cols: Int; let hS: [String]; let hL: [String] }
        var loadedTables: [LT] = []
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard t.contains("|"), i + 1 < lines.count,
                  MDParser.isTableDelimiter(lines[i + 1]) else { continue }
            let cells = MDParser.splitRow(t)
            guard !cells.isEmpty else { continue }
            loadedTables.append(LT(line: i, cols: cells.count,
                                   hS: cells.map(strict), hL: cells.map(loose)))
        }
        var used = [Bool](repeating: false, count: srcTables.count)
        var done: Set<Int> = []
        for pass in 0...1 {
            for lt in loadedTables where !done.contains(lt.line) {
                let headerEmpty = lt.hS.allSatisfy { $0.isEmpty }
                guard !headerEmpty else { continue }
                for j in used.indices where !used[j] {
                    let spec = srcTables[j]
                    guard spec.header.count == lt.cols else { continue }
                    let ok = pass == 0
                        ? zip(spec.header.map(strict), lt.hS).allSatisfy { $0 == $1 }
                        : zip(spec.header.map(loose), lt.hL).allSatisfy { $0 == $1 }
                    guard ok else { continue }
                    lines[lt.line + 1] = "|" + (0..<lt.cols).map { c -> String in
                        let a = c < spec.aligns.count ? spec.aligns[c] : 0
                        switch a {
                        case 2: return " :---: "
                        case 3: return " ---: "
                        default: return " --- "
                        }
                    }.joined(separator: "|") + "|"
                    used[j] = true
                    done.insert(lt.line)
                    break
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 提取 markdown 中各表格的（表头, 列对齐），按文档顺序
    private static func tableSpecs(_ lines: [String]) -> [(header: [String], aligns: [Int])] {
        var out: [(header: [String], aligns: [Int])] = []
        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.contains("|"), i + 1 < lines.count, MDParser.isTableDelimiter(lines[i + 1]) {
                out.append((MDParser.splitRow(t), MDParser.parseAligns(lines[i + 1])))
                i += 2
                while i < lines.count {
                    let r = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !r.isEmpty, r.contains("|"), !MDParser.isTableDelimiter(r) else { break }
                    i += 1
                }
                continue
            }
            i += 1
        }
        return out
    }

    /// 核心：节点数组 → Markdown（顶层 html/body/object 包装自动解开）
    static func convertNodes(_ rawNodes: [HTMLNode]) -> String {
        let top = unwrapWrappers(rawNodes)
        var blocks: [String] = []
        var codeLines: [String] = []
        func flushCode() {
            guard !codeLines.isEmpty else { return }
            blocks.append("```\n" + codeLines.joined(separator: "\n") + "\n```")
            codeLines = []
        }
        for node in top {
            switch node.kind {
            case .text(let t):
                let t2 = decodeEntities(t).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t2.isEmpty { flushCode(); blocks.append(t2) }
            case .br:
                continue
            case .element(let name, _, let children):
                switch name {
                case "html", "head", "body":
                    continue
                case "div", "p":
                    // Notes 用 <div><br></div> 做块间隔，正文都在 div 里
                    handleDiv(children,
                              append: { blocks.append($0) },
                              addCodeLine: { codeLines.append($0) },
                              flushCode: flushCode)
                case "table":
                    let t = tableMarkdown(node)
                    if !t.isEmpty { flushCode(); blocks.append(t) }
                case "ul", "ol":
                    let lines = listMarkdown(node, ordered: name == "ol", indent: 0)
                    if !lines.isEmpty { flushCode(); blocks.append(lines.joined(separator: "\n")) }
                case "blockquote":
                    if let q = quoteLines(convertNodes(quoteChildren(children))) {
                        flushCode(); blocks.append(q)
                    }
                case "hr":
                    flushCode(); blocks.append("---")
                default:
                    let md = markdownFromNodes(children)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !md.isEmpty { flushCode(); blocks.append(md) }
                }
            }
        }
        flushCode()
        return blocks.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func quoteChildren(_ children: [HTMLNode]) -> [HTMLNode] {
        // blockquote 内的 <p> 解包成行
        var out: [HTMLNode] = []
        for n in children {
            if case .element(let name, _, let ch) = n.kind, name == "p" {
                out.append(contentsOf: ch)
                var lastIsBr = false
                if case .br? = out.last?.kind { lastIsBr = true }
                if !lastIsBr { out.append(HTMLNode(kind: .br)) }
            } else {
                out.append(n)
            }
        }
        return out
    }

    private static func quoteLines(_ inner: String) -> String? {
        let lines = inner.components(separatedBy: "\n")
            .map { $0.isEmpty ? ">" : "> " + $0 }
        guard lines.contains(where: { $0.hasPrefix("> ") }) else { return nil }
        return lines.joined(separator: "\n")
    }

    // div/p 内容分发：空行 / 灰色横线 / 表格 / 列表 / 代码行 / 标题 / 段落
    private static func handleDiv(_ sub: [HTMLNode], append: (String) -> Void,
                                  addCodeLine: (String) -> Void, flushCode: () -> Void) {
        if sub.allSatisfy({ onlyBr($0) }) { return }          // 块间隔
        if isGrayRule(sub) { flushCode(); append("---"); return }
        if let table = findElement(sub, names: ["table"]) {
            let t = tableMarkdown(table)
            if !t.isEmpty { flushCode(); append(t) }
            return
        }
        if let list = findElement(sub, names: ["ul", "ol"]) {
            let lines = listMarkdown(list, ordered: listIsOrdered(list), indent: 0)
            if !lines.isEmpty { flushCode(); append(lines.joined(separator: "\n")) }
            return
        }
        if let quote = findElement(sub, names: ["blockquote"]),
           case .element(_, _, let quoteKids) = quote.kind {
            if let q = quoteLines(convertNodes(quoteChildren(quoteKids))) {
                flushCode(); append(q)
            }
            return
        }
        let segs = inlineSegs(sub)
        let text = plainText(segs).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        if isAllCode(segs) {  // Notes 的 <pre> 是逐行 Courier div，连续合并成代码块
            addCodeLine(markdownFromSegs(segs).replacingOccurrences(of: "\n", with: " "))
            return
        }
        if isAllBold(segs) {
            if let size = fontSizeOf(sub) {
                let level: Int
                if size >= 23 { level = 1 } else if size >= 16 { level = 2 } else { level = 3 }
                flushCode()
                append(String(repeating: "#", count: level) + " " + text)
            } else {
                flushCode()
                append("**" + text + "**")
            }
            return
        }
        flushCode()
        append(markdownFromSegs(segs).trimmingCharacters(in: .newlines))
    }

    // MARK: - 列表

    private static func listMarkdown(_ node: HTMLNode, ordered: Bool, indent: Int) -> [String] {
        guard case .element(_, _, let children) = node.kind else { return [] }
        let pad = String(repeating: "  ", count: indent)
        var lines: [String] = []
        var itemLines: [String] = []
        var counter = 0
        func flush() {
            guard !itemLines.isEmpty else { return }
            counter += 1
            var first = itemLines[0]
            var task: Int?
            if first.hasPrefix("☑") { task = 1; first.removeFirst() }
            else if first.hasPrefix("☐") { task = 0; first.removeFirst() }
            if first.hasPrefix(" ") { first.removeFirst() }
            let marker: String
            if let task {
                marker = "- [\(task == 1 ? "x" : " ")] "
            } else {
                marker = ordered ? "\(counter). " : "- "
            }
            var line = pad + marker + first
            for extra in itemLines.dropFirst() {
                line += "\n" + pad + "  " + extra
            }
            lines.append(line)
            itemLines = []
        }
        for child in children {
            guard case .element(let name, _, let ch) = child.kind else { continue }
            if name == "li" {
                let md = markdownFromNodes(ch)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !md.isEmpty {
                    itemLines += md.components(separatedBy: "\n")
                }
            } else if name == "ul" || name == "ol" {
                // Notes 把嵌套列表放在外层列表里（前一个 li 之后）
                for l in listMarkdown(child, ordered: name == "ol", indent: indent + 1) {
                    if itemLines.isEmpty {
                        lines.append(l)
                    } else if l.hasPrefix(pad) {
                        itemLines.append(String(l.dropFirst(pad.count)))
                    } else {
                        itemLines.append(l)
                    }
                }
            }
        }
        flush()
        return lines
    }

    private static func listIsOrdered(_ node: HTMLNode) -> Bool {
        if case .element(let name, _, _) = node.kind { return name == "ol" }
        return false
    }

    // MARK: - 表格

    private static func tableMarkdown(_ table: HTMLNode) -> String {
        guard case .element(_, _, let children) = table.kind else { return "" }
        // Notes 的表格带 <thead>/<tbody> 包裹（可能还有 <object> 外层），先展平出所有 <tr>
        var trs: [HTMLNode] = []
        for n in children {
            guard case .element(let nName, _, let nCh) = n.kind else { continue }
            if nName == "tr" { trs.append(n) }
            else if nName == "thead" || nName == "tbody" || nName == "tfoot" {
                for c in nCh {
                    if case .element(let cName, _, _) = c.kind, cName == "tr" { trs.append(c) }
                }
            }
        }
        var rows: [[String]] = []
        var alignRows: [[Int]] = []   // 与 rows 平行：单元格 align 属性 / text-align 样式
        for tr in trs {
            guard case .element(let trName, _, let cells) = tr.kind, trName == "tr" else { continue }
            var row: [String] = []
            var alignRow: [Int] = []
            for td in cells {
                guard case .element(let tdName, let tdAttrs, let ch) = td.kind,
                      ["td", "th"].contains(tdName) else { continue }
                let md = markdownFromNodes(ch)
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "|", with: "\\|")
                    .trimmingCharacters(in: .whitespaces)
                row.append(md)
                alignRow.append(cellAlign(tdAttrs))
            }
            if !row.isEmpty {
                rows.append(row)
                alignRows.append(alignRow)
            }
        }
        guard !rows.isEmpty else { return "" }
        let colCount = rows.map { $0.count }.max() ?? 1
        // 列对齐：每列取首个非默认值（表头行优先）；无信息时保持默认
        var colAligns = [Int](repeating: 0, count: colCount)
        for (row, ar) in zip(rows, alignRows) {
            for (c, _) in row.enumerated() where c < ar.count && colAligns[c] == 0 && ar[c] != 0 {
                colAligns[c] = ar[c]
            }
        }
        var out: [String] = []
        out.append("| " + padRow(rows[0], colCount).joined(separator: " | ") + " |")
        out.append("|" + (0..<colCount).map { sepCell(colAligns[$0]) }.joined(separator: "|") + "|")
        for r in rows.dropFirst() {
            out.append("| " + padRow(r, colCount).joined(separator: " | ") + " |")
        }
        return out.joined(separator: "\n")
    }

    private static func sepCell(_ align: Int) -> String {
        switch align {
        case 2: return " :---: "
        case 3: return " ---: "
        default: return " --- "
        }
    }

    /// 单元格水平对齐：align 属性优先，其次 style 里的 text-align
    private static func cellAlign(_ attrs: [String: String]) -> Int {
        let a = (attrs["align"] ?? "").lowercased()
        if let style = attrs["style"], style.lowercased().contains("text-align") {
            let seg = style.lowercased()
            if seg.contains("center") { return 2 }
            if seg.contains("right") { return 3 }
            if seg.contains("left") { return 1 }
        }
        switch a {
        case "center": return 2
        case "right": return 3
        case "left": return 1
        default: return 0
        }
    }

    private static func padRow(_ r: [String], _ n: Int) -> [String] {
        var rr = r
        while rr.count < n { rr.append("") }
        return Array(rr.prefix(n))
    }

    // MARK: - 行内

    struct SegStyle: Equatable {
        var bold = false
        var italic = false
        var strike = false
        var code = false
    }
    typealias Seg = (text: String, style: SegStyle, br: Bool)

    /// 节点树 → 带样式的文本段（br 单独成段）
    static func inlineSegs(_ nodes: [HTMLNode]) -> [Seg] {
        var out: [Seg] = []
        var stack: [[Character]] = []
        func current() -> SegStyle {
            var s = SegStyle()
            for f in stack {
                if f.contains("b") { s.bold = true }
                if f.contains("i") { s.italic = true }
                if f.contains("s") { s.strike = true }
                if f.contains("c") { s.code = true }
            }
            return s
        }
        func walk(_ nodes: [HTMLNode]) {
            for n in nodes {
                switch n.kind {
                case .text(let t):
                    let dec = decodeEntities(t)
                    if !dec.isEmpty { out.append((dec, current(), false)) }
                case .br:
                    out.append(("", current(), true))
                case .element(let name, let attrs, let ch):
                    switch name {
                    case "b", "strong":
                        stack.append(["b"]); walk(ch); stack.removeLast()
                    case "i", "em":
                        stack.append(["i"]); walk(ch); stack.removeLast()
                    case "strike", "s", "del":
                        stack.append(["s"]); walk(ch); stack.removeLast()
                    case "tt", "code":
                        stack.append(["c"]); walk(ch); stack.removeLast()
                    case "font":
                        let face = (attrs["face"] ?? "").lowercased()
                        if face.contains("courier") {
                            stack.append(["c"]); walk(ch); stack.removeLast()
                        } else if face.contains("bold") {
                            stack.append(["b"]); walk(ch); stack.removeLast()
                        } else {
                            walk(ch)  // PingFang/AppleSymbols 等：按普通文本
                        }
                    case "img":
                        if let src = attrs["src"], !src.isEmpty {
                            out.append(("![](" + src + ")", current(), false))
                        }
                    default:
                        walk(ch)  // u / a / span / object / div / p 等：保留文字
                    }
                }
            }
        }
        walk(nodes)
        return out
    }

    /// 样式段 → Markdown（加粗/斜体/删除线/行内代码；br 换行）
    static func markdownFromSegs(_ segs: [Seg]) -> String {
        var merged: [(text: String, style: SegStyle)] = []
        var brs = 0
        for seg in segs {
            if seg.br { brs += 1; continue }
            if brs > 0 {
                for _ in 0..<brs { merged.append(("\n", SegStyle())) }
                brs = 0
            }
            if seg.text.isEmpty { continue }
            if let last = merged.last, last.style == seg.style {
                merged[merged.count - 1].text += seg.text
            } else {
                merged.append((seg.text, seg.style))
            }
        }
        var out = ""
        var prev = SegStyle()
        for (t, st) in merged {
            if t == "\n" { out += "\n"; continue }
            if prev.code && !st.code { out += "`" }
            if prev.strike && !st.strike { out += "~~" }
            if prev.italic && !st.italic { out += "*" }
            if prev.bold && !st.bold { out += "**" }
            if st.bold && !prev.bold { out += "**" }
            if st.italic && !prev.italic { out += "*" }
            if st.strike && !prev.strike { out += "~~" }
            if st.code && !prev.code { out += "`" }
            out += t
            prev = st
        }
        if prev.code { out += "`" }
        if prev.strike { out += "~~" }
        if prev.italic { out += "*" }
        if prev.bold { out += "**" }
        return out
    }

    static func markdownFromNodes(_ nodes: [HTMLNode]) -> String {
        markdownFromSegs(inlineSegs(nodes))
    }

    static func plainText(_ segs: [Seg]) -> String {
        segs.map { $0.text }.joined()
    }

    private static func isAllBold(_ segs: [Seg]) -> Bool {
        let nonEmpty = segs.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonEmpty.isEmpty else { return false }
        return nonEmpty.allSatisfy { $0.style.bold }
    }

    private static func isAllCode(_ segs: [Seg]) -> Bool {
        let nonEmpty = segs.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonEmpty.isEmpty else { return false }
        return nonEmpty.allSatisfy { $0.style.code }
    }

    private static func onlyBr(_ n: HTMLNode) -> Bool {
        switch n.kind {
        case .br: return true
        case .text(let t): return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .element(_, _, let ch): return ch.allSatisfy(onlyBr)
        }
    }

    /// Notes 的水平线读回是 <div><font color="#808080"><br></font></div>
    private static func isGrayRule(_ sub: [HTMLNode]) -> Bool {
        guard sub.count <= 3 else { return false }
        var hasGray = false
        for n in sub {
            switch n.kind {
            case .element(_, let attrs, let ch):
                let color = (attrs["color"] ?? "").lowercased()
                if ["#808080", "gray", "grey"].contains(color) {
                    if ch.allSatisfy(onlyBr) { hasGray = true }
                } else if !ch.allSatisfy(onlyBr) {
                    return false
                }
            case .br:
                break
            case .text(let t):
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            }
        }
        return hasGray
    }

    private static func findElement(_ nodes: [HTMLNode], names: [String]) -> HTMLNode? {
        for n in nodes {
            if case .element(let name, _, let ch) = n.kind {
                if names.contains(name) { return n }
                if let f = findElement(ch, names: names) { return f }
            }
        }
        return nil
    }

    private static func fontSizeOf(_ nodes: [HTMLNode]) -> CGFloat? {
        let re = try! NSRegularExpression(pattern: "font-size:\\s*([0-9]+)px")
        for n in nodes {
            if case .element(let name, let attrs, let ch) = n.kind {
                if name == "span", let style = attrs["style"] {
                    let ns = style as NSString
                    if let m = re.firstMatch(in: style, range: NSRange(location: 0, length: ns.length)) {
                        return CGFloat(Int(ns.substring(with: m.range(at: 1))) ?? 0)
                    }
                }
                if let f = fontSizeOf(ch) { return f }
            }
        }
        return nil
    }

    private static func unwrapWrappers(_ nodes: [HTMLNode]) -> [HTMLNode] {
        let wrappers = ["html", "head", "body", "object"]
        var out = nodes
        var changed = true
        while changed {
            changed = false
            var next: [HTMLNode] = []
            for n in out {
                if case .element(let name, _, let ch) = n.kind, wrappers.contains(name) {
                    next.append(contentsOf: ch)
                    changed = true
                } else {
                    next.append(n)
                }
            }
            out = next
        }
        return out
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        for (e, r) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#39;": "'", "&apos;": "'", "&nbsp;": " "] {
            out = out.replacingOccurrences(of: e, with: r)
        }
        if let re = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            let ns = out as NSString
            let matches = re.matches(in: out, range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                var result = ""
                var last = 0
                for m in matches {
                    result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                    let tok = ns.substring(with: m.range(at: 1))
                    let code = tok.lowercased().hasPrefix("x")
                        ? UInt32(tok.dropFirst(), radix: 16)
                        : UInt32(tok)
                    if let code, let scalar = UnicodeScalar(code) {
                        result.append(Character(scalar))
                    } else {
                        result += "?"
                    }
                    last = m.range.upperBound
                }
                result += ns.substring(from: last)
                out = result
            }
        }
        return out
    }
}
