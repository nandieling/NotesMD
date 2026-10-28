import AppKit
import Foundation

// MARK: - HTML 标签扫描（预览富文本与备忘录 HTML 输出共用）

/// 一个 HTML 标签（含 < 与 > 的完整标签）
struct HtmlTag {
    var name: String                  // 小写标签名
    var raw: String                   // 原始标签文本
    var attrs: [String: String]       // 小写属性名 -> 值（去引号）
    var selfClosing: Bool             // > 前带 /
    var closing: Bool                 // 是否闭合标签
    var range: NSRange                // 在源字符串中的区间

    func attr(_ n: String) -> String? { attrs[n.lowercased()] }
}

enum HtmlScanner {
    // 注意：所有位置均按 UTF-16 计（与 NSRange 一致，避免 CJK/emoji 下错位）

    /// 找 s 中第一个合法 HTML 标签；非标签的 <（如 a < b、<3）返回 nil
    static func firstTag(in s: String) -> HtmlTag? {
        let u = Array(s.utf16)
        let n = u.count
        var i = 0
        while i < n {
            guard u[i] == 60 else { i += 1; continue } // "<"
            if let t = parseTag(at: i, u: u) {
                let len = t.end - i + 1
                let raw = (s as NSString).substring(with: NSRange(location: i, length: len))
                return HtmlTag(name: t.name, raw: raw, attrs: t.attrs,
                               selfClosing: t.selfClosing, closing: t.closing,
                               range: NSRange(location: i, length: len))
            }
            i += 1
        }
        return nil
    }

    private static func parseTag(at start: Int, u: [UInt16])
        -> (name: String, attrs: [String: String], selfClosing: Bool, closing: Bool, end: Int)? {
        let n = u.count
        func isAlpha(_ v: UInt16) -> Bool { (v >= 65 && v <= 90) || (v >= 97 && v <= 122) }
        func isAlnum(_ v: UInt16) -> Bool { isAlpha(v) || (v >= 48 && v <= 57) }
        func isWs(_ v: UInt16) -> Bool { v == 32 || v == 9 || v == 10 || v == 13 }
        func isAttrStart(_ v: UInt16) -> Bool { isAlpha(v) || v == 95 || v == 45 }
        func isAttrChar(_ v: UInt16) -> Bool { isAlnum(v) || v == 95 || v == 45 || v == 58 || v == 46 }
        func str(_ from: Int, _ to: Int) -> String {
            String(utf16CodeUnits: Array(u[from..<to]), count: to - from)
        }
        var i = start + 1
        var closing = false
        if i < n, u[i] == 47 { closing = true; i += 1 }
        guard i < n, isAlpha(u[i]) else { return nil }
        var j = i
        while j < n, isAlnum(u[j]) { j += 1 }
        let name = str(i, j).lowercased()
        var attrs: [String: String] = [:]
        if !closing {
            while j < n {
                let v = u[j]
                if isWs(v) { j += 1; continue }
                if v == 47 {
                    j += 1
                    while j < n, isWs(u[j]) { j += 1 }
                    guard j < n, u[j] == 62 else { return nil }
                    return (name, attrs, true, false, j)
                }
                if v == 62 { return (name, attrs, false, false, j) }
                guard isAttrStart(v) else { return nil }
                var k = j
                while k < n, isAttrChar(u[k]) { k += 1 }
                let aname = str(j, k).lowercased()
                j = k
                while j < n, isWs(u[j]) { j += 1 }
                if j < n, u[j] == 61 {
                    j += 1
                    while j < n, isWs(u[j]) { j += 1 }
                    if j < n, u[j] == 34 || u[j] == 39 {
                        let q = u[j]
                        j += 1
                        var buf: [UInt16] = []
                        while j < n, u[j] != q { buf.append(u[j]); j += 1 }
                        guard j < n else { return nil }
                        j += 1
                        attrs[aname] = String(utf16CodeUnits: buf, count: buf.count)
                    } else {
                        var k2 = j
                        while k2 < n, !isWs(u[k2]), u[k2] != 62 { k2 += 1 }
                        attrs[aname] = str(j, k2)
                        j = k2
                    }
                } else {
                    attrs[aname] = ""
                }
            }
            return nil
        }
        while j < n, isWs(u[j]) { j += 1 }
        guard j < n, u[j] == 62 else { return nil }
        return (name, attrs, false, true, j)
    }

    /// from 起找第一个闭合标签 </name>，返回 (start, end+1)
    static func firstClosingTag(named name: String, in s: String, from: Int) -> (start: Int, end: Int)? {
        let u = Array(s.utf16)
        let n = u.count
        let target = Array(("</" + name.lowercased()).utf16)
        let tLen = target.count
        guard tLen <= n else { return nil }
        var i = max(0, min(from, n - tLen))
        while i + tLen <= n {
            guard u[i] == 60 else { i += 1; continue }
            var ok = true
            for k in 1..<tLen where u[i + k] != target[k] { ok = false; break }
            guard ok else { i += 1; continue }
            var j = i + tLen
            while j < n, u[j] == 32 || u[j] == 9 || u[j] == 10 || u[j] == 13 { j += 1 }
            guard j < n, u[j] == 62 else { i += 1; continue }
            return (i, j + 1)
        }
        return nil
    }
}

// MARK: - 内联样式解析

enum HtmlStyle {

    private static let named: [String: NSColor] = [
        "black": .black, "white": .white, "gray": .gray, "grey": .gray,
        "silver": NSColor(white: 0.75, alpha: 1),
        "red": .red, "darkred": NSColor(red: 0.55, green: 0, blue: 0, alpha: 1),
        "blue": .blue, "darkblue": NSColor(red: 0, green: 0, blue: 0.55, alpha: 1),
        "navy": NSColor(red: 0, green: 0, blue: 0.5, alpha: 1),
        "green": NSColor(red: 0, green: 0.5, blue: 0, alpha: 1),
        "darkgreen": NSColor(red: 0, green: 0.39, blue: 0, alpha: 1),
        "lime": NSColor(red: 0, green: 1, blue: 0, alpha: 1),
        "lightgreen": NSColor(red: 0.56, green: 0.93, blue: 0.56, alpha: 1),
        "yellow": .yellow, "gold": NSColor(red: 1, green: 0.84, blue: 0, alpha: 1),
        "olive": NSColor(red: 0.5, green: 0.5, blue: 0, alpha: 1),
        "orange": .orange, "brown": NSColor(red: 0.65, green: 0.16, blue: 0.16, alpha: 1),
        "purple": .purple, "violet": NSColor(red: 0.9, green: 0.51, blue: 0.9, alpha: 1),
        "magenta": .magenta, "fuchsia": .magenta,
        "pink": NSColor(red: 1, green: 0.75, blue: 0.79, alpha: 1), "plum": NSColor(red: 0.85, green: 0.44, blue: 0.87, alpha: 1),
        "teal": NSColor(red: 0, green: 0.5, blue: 0.5, alpha: 1),
        "cyan": .cyan, "aqua": .cyan,
        "skyblue": NSColor(red: 0.53, green: 0.81, blue: 0.92, alpha: 1),
        "lightblue": NSColor(red: 0.68, green: 0.85, blue: 0.9, alpha: 1),
        "steelblue": NSColor(red: 0.27, green: 0.51, blue: 0.71, alpha: 1),
        "tomato": NSColor(red: 1, green: 0.39, blue: 0.25, alpha: 1),
        "crimson": NSColor(red: 0.86, green: 0.08, blue: 0.24, alpha: 1),
        "salmon": NSColor(red: 0.98, green: 0.5, blue: 0.5, alpha: 1),
        "coral": NSColor(red: 1, green: 0.5, blue: 0.31, alpha: 1),
        "khaki": NSColor(red: 0.74, green: 0.72, blue: 0.42, alpha: 1),
        "indigo": NSColor(red: 0.29, green: 0, blue: 0.51, alpha: 1),
        "maroon": NSColor(red: 0.5, green: 0, blue: 0, alpha: 1),
    ]

    /// 解析颜色：#abc / #aabbcc / rgb() / rgba() / 常见颜色名
    static func color(_ s: String) -> NSColor? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        if let c = named[t] { return c }
        if t.hasPrefix("#") {
            let chars = Array(t.dropFirst())
            func hv(_ c: Character) -> Int? { Int(String(c), radix: 16) }
            if chars.count == 3, let r = hv(chars[0]), let g = hv(chars[1]), let b = hv(chars[2]) {
                return NSColor(red: CGFloat(r * 17) / 255, green: CGFloat(g * 17) / 255,
                               blue: CGFloat(b * 17) / 255, alpha: 1)
            }
            if chars.count == 6,
               let r = Int(String(chars[0...1]), radix: 16),
               let g = Int(String(chars[2...3]), radix: 16),
               let b = Int(String(chars[4...5]), radix: 16) {
                return NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                               blue: CGFloat(b) / 255, alpha: 1)
            }
            return nil
        }
        if t.hasPrefix("rgb") {
            let m = MarkdownRenderer.match(
                #"rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(?:,\s*([0-9.]+))?\s*\)"#, t)
            guard let m, let r = Int(m[0]), let g = Int(m[1]), let b = Int(m[2]) else { return nil }
            let a: CGFloat = m.count > 3 ? CGFloat(Double(m[3]) ?? 1) : 1
            return NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                           blue: CGFloat(b) / 255, alpha: min(max(a, 0), 1))
        }
        return nil
    }

    /// 解析 font-size（px/pt/em/rem/%/纯数字），返回绝对 pt
    static func fontSize(_ s: String, base: CGFloat) -> CGFloat? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        if t.hasSuffix("%"), let v = Double(t.dropLast()) { return base * v / 100 }
        if t.hasSuffix("em"), let v = Double(t.dropLast(2)) { return base * v }
        if t.hasSuffix("rem"), let v = Double(t.dropLast(3)) { return v * 12 }
        if t.hasSuffix("px"), let v = Double(t.dropLast(2)) { return v * 0.75 }
        if t.hasSuffix("pt"), let v = Double(t.dropLast(2)) { return v }
        if let v = Double(t) { return v }
        return nil
    }

    /// 把 CSS style 串解析为文本属性（字号相对 baseFont 换算）
    static func attributes(fromCSS css: String, baseFont: NSFont?) -> [NSAttributedString.Key: Any] {
        var out: [NSAttributedString.Key: Any] = [:]
        for part in css.components(separatedBy: ";") {
            let kv = part.components(separatedBy: ":")
            guard kv.count >= 2 else { continue }
            let k = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let v = kv[1].trimmingCharacters(in: .whitespaces)
            switch k {
            case "color":
                if let c = color(v) { out[.foregroundColor] = c }
            case "background-color", "background":
                if let c = color(v) { out[.backgroundColor] = c }
            case "font-size", "fontsize":
                if let f = baseFont, let s = fontSize(v, base: f.pointSize) {
                    out[.font] = withSize(f, s)
                }
            case "text-decoration", "text-decoration-line":
                let d = v.lowercased()
                if d.contains("underline") { out[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if d.contains("line-through") || d.contains("strikethrough") {
                    out[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            default:
                break
            }
        }
        return out
    }

    /// 换字号，保留字体其他特征
    static func withSize(_ f: NSFont, _ size: CGFloat) -> NSFont {
        let s = max(size, 6)
        return NSFont(descriptor: f.fontDescriptor.withSize(s), size: s) ?? f
    }

    /// HTML 表格 / 列表 / Markdown 正文共用：把实体转回普通字符。
    /// 覆盖常见命名实体与数字实体（&#39; / &#x27;）；未知实体原样保留。
    static func unescapeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        guard let re = try? NSRegularExpression(
            pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,10});") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = m.range.upperBound
            let body = ns.substring(with: m.range(at: 1))
            let whole = ns.substring(with: m.range)
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let code = (digits.first == "x" || digits.first == "X")
                    ? Int(digits.dropFirst(), radix: 16) : Int(digits)
                if let c = code, c > 0, c < 0x110000, !((0xD800...0xDFFF).contains(c)),
                   let scalar = Unicode.Scalar(c) {
                    out.append(String(scalar))
                } else {
                    out += whole
                }
            } else {
                out += namedEntities[body.lowercased()] ?? whole
            }
        }
        out += ns.substring(from: last)
        return out
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "hellip": "\u{2026}", "mdash": "\u{2014}", "ndash": "\u{2013}",
        "middot": "\u{00B7}", "bull": "\u{2022}", "laquo": "\u{00AB}", "raquo": "\u{00BB}",
        "times": "\u{00D7}", "divide": "\u{00F7}", "deg": "\u{00B0}", "sect": "\u{00A7}",
        "para": "\u{00B6}", "dagger": "\u{2020}", "euro": "\u{20AC}", "pound": "\u{00A3}",
        "yen": "\u{00A5}", "cent": "\u{00A2}", "larr": "\u{2190}", "rarr": "\u{2192}",
        "uarr": "\u{2191}", "darr": "\u{2193}", "harr": "\u{2194}", "ne": "\u{2260}",
        "le": "\u{2264}", "ge": "\u{2265}", "equiv": "\u{2261}", "plusmn": "\u{00B1}"
    ]
}

// MARK: - 图片属性  ![](url){align=center width=70%}

struct ImageAttributes {
    var align: NSTextAlignment?
    var width: CGFloat?
    var widthIsPercent = false
    var height: CGFloat?
    var heightIsPercent = false
    var isEmpty: Bool { align == nil && width == nil && height == nil }
}

enum ImageAttrParser {

    /// 解析 {align=center width=70% height=200px} 内容
    static func parse(_ text: String) -> ImageAttributes {
        var a = ImageAttributes()
        for pair in text.components(separatedBy: " ") {
            let kv = pair.components(separatedBy: "=")
            guard kv.count == 2 else { continue }
            let k = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let v = kv[1].trimmingCharacters(in: .whitespaces)
            switch k {
            case "align":
                switch v.lowercased() {
                case "center": a.align = .center
                case "right": a.align = .right
                case "left": a.align = .left
                default: break
                }
            case "width":
                if let (val, pct) = parseSize(v) { a.width = val; a.widthIsPercent = pct }
            case "height":
                if let (val, pct) = parseSize(v) { a.height = val; a.heightIsPercent = pct }
            default:
                break
            }
        }
        return a
    }

    /// 解析尺寸：70% / 200px / 200pt / 200（按 pt）；返回 (值, 是否百分比)
    static func parseSize(_ v: String) -> (CGFloat, Bool)? {
        let t = v.lowercased()
        if t.hasSuffix("%"), let d = Double(t.dropLast()) { return (CGFloat(d) / 100, true) }
        if t.hasSuffix("px"), let d = Double(t.dropLast(2)) { return (CGFloat(d) * 0.75, false) }
        if t.hasSuffix("pt"), let d = Double(t.dropLast(2)) { return (CGFloat(d), false) }
        if let d = Double(t) { return (CGFloat(d), false) }
        return nil
    }

    /// 展示尺寸：未指定 → 限宽限高不放大；指定 width/height → 按约束等比缩放
    ///（百分比相对内容宽度 / 560pt 高度基准；显式尺寸允许放大）
    static func displaySize(imgSize: NSSize, contentMax: CGFloat, imageAttrs: ImageAttributes?) -> NSSize {
        guard imgSize.width > 0, imgSize.height > 0 else {
            return NSSize(width: min(contentMax, 320), height: 100)
        }
        guard let a = imageAttrs, a.width != nil || a.height != nil else {
            let scale = min(1, contentMax / imgSize.width, 560 / imgSize.height)
            return NSSize(width: imgSize.width * scale, height: imgSize.height * scale)
        }
        var scales: [CGFloat] = []
        if let w = a.width {
            let target = a.widthIsPercent ? contentMax * w : w
            if target > 0 { scales.append(target / imgSize.width) }
        }
        if let h = a.height {
            let target = a.heightIsPercent ? 560 * h : h
            if target > 0 { scales.append(target / imgSize.height) }
        }
        guard let scale = scales.min() else {
            return NSSize(width: imgSize.width, height: imgSize.height)
        }
        return NSSize(width: imgSize.width * scale, height: imgSize.height * scale)
    }
}
