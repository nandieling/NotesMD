import AppKit

/// 代码块「整块底色」属性。
/// 原生 TextKit 的 .backgroundColor 只按行片段（line fragment）逐行填充，
/// 行距/段距处会出现空隙，视觉上像"每行一个背景条"。
/// 预览区改用 CodeBlockLayoutManager 对整个区块按行整体填充，
/// 且只填充到块内最宽一行的右缘（右侧无代码的空白不填充）；
/// .backgroundColor 保留给不走文本视图的路径（CLI --png），整行填充。
enum CodeBlockAttributes {
    static let background = NSAttributedString.Key("notesmd.codeBlock.background")
}

/// 引用块层级属性（值 Int，1 = 单层引用）。预览区按它画左侧竖线。
enum QuoteAttributes {
    static let depth = NSAttributedString.Key("notesmd.quote.depth")
}

final class CodeBlockLayoutManager: NSLayoutManager {

    /// 原生实现会一次性拿到整段可见 glyph 区间（而不是按背景属性 run 拆分），
    /// 所以这里自己枚举带代码块底色的区间，逐块按行片段整体填充
    override func drawBackground(forGlyphRange glyphs: NSRange, at point: NSPoint) {
        func dbg(_ s: String) {
            guard ProcessInfo.processInfo.environment["NMD_LM_DEBUG"] == "1" else { return }
            if let h = FileHandle(forWritingAtPath: "/tmp/lm-debug.log") {
                h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); h.closeFile()
            }
        }
        guard let storage = textStorage, storage.length > 0 else {
            return super.drawBackground(forGlyphRange: glyphs, at: point)
        }
        let charRange = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard charRange.location != NSNotFound, charRange.length > 0,
              charRange.location < storage.length else {
            return super.drawBackground(forGlyphRange: glyphs, at: point)
        }
        guard let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) else {
            return super.drawBackground(forGlyphRange: glyphs, at: point)
        }

        // 枚举区间内的代码块底色 run（保持顺序）
        var blocks: [(range: NSRange, color: NSColor)] = []
        storage.enumerateAttribute(CodeBlockAttributes.background,
                                   in: charRange, options: []) { value, range, _ in
            if let color = value as? NSColor { blocks.append((range, color)) }
        }

        // 引用块区间（相邻同层区间合并，段距处竖线才不会被切断）
        var quoteRuns: [(range: NSRange, depth: Int)] = []
        storage.enumerateAttribute(QuoteAttributes.depth, in: charRange, options: []) { value, range, _ in
            guard let depth = value as? Int, depth > 0 else { return }
            if let last = quoteRuns.last, last.depth == depth, last.range.upperBound == range.location {
                quoteRuns[quoteRuns.count - 1].range =
                    NSRange(location: last.range.location, length: range.upperBound - last.range.location)
            } else {
                quoteRuns.append((range, depth))
            }
        }

        // 其余背景（如有）仍交给原生填充
        super.drawBackground(forGlyphRange: glyphs, at: point)
        guard !blocks.isEmpty || !quoteRuns.isEmpty else { return }
        let base = boundingRect(forGlyphRange: glyphs, in: container)
        dbg("call glyphs=\(glyphs) charRange=\(charRange) point=\(point) base=\(base) blocks=\(blocks.count)")
        if ProcessInfo.processInfo.environment["NMD_LM_DEBUG"] == "1" {
            NSColor.red.setFill()
            NSRect(x: 0, y: 0, width: 2000, height: 2000).fill()
        }
        // point = 文本系统给出的文本容器原点（绘图坐标），与滚动位置无关；
        // 容器坐标 -> 绘图坐标只需加这一个固定偏移。
        // 不能拿本次区间的包围盒原点做基准：代码块比窗口高、块顶滚出可视区时，
        // 本次区间的起点就是可视区中部，减掉它会把整块底色往上平移同样多的距离，
        // 结果是长代码块滚到中间时底色完全看不见（或盖到块外上面的内容上）。
        func vx(_ x: CGFloat) -> CGFloat { point.x + x }
        func vy(_ y: CGFloat) -> CGFloat { point.y + y }

        let allRange = NSRange(location: 0, length: storage.length)
        for block in blocks {
            guard block.range.location < storage.length else { continue }
            if ProcessInfo.processInfo.environment["NMD_LM_DEBUG"] == "1" {
                NSColor.magenta.setFill(); NSRect(x: 0, y: 40, width: 200, height: 12).fill()   // P1 outer loop top
            }
            // 左缘 = 行片段左缘 + headIndent：空行（无字形）也能与非空行对齐，
            // 引用内的代码块不会向左凸出缩进
            let headIndent = (storage.attribute(.paragraphStyle, at: block.range.location,
                                                longestEffectiveRange: nil, in: allRange)
                              as? NSParagraphStyle)?.headIndent ?? 0
            let subGlyphRange = glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
            guard subGlyphRange.location != NSNotFound else { continue }
            if ProcessInfo.processInfo.environment["NMD_LM_DEBUG"] == "1" {
                NSColor.magenta.setFill(); NSRect(x: 0, y: 60, width: 200, height: 12).fill()   // P2 after glyphRange
            }
            // 逐行片段收集：行片段矩形 + 该行实际内容右缘。
            // 注意 boundingRect(forGlyphRange:in:) 实测返回整行容器宽度（非紧致包围盒），
            // 这里用 lineFragmentUsedRect（容器坐标系、紧贴实际文本）取每行右缘
            var fragments: [(rect: NSRect, maxX: CGFloat)] = []
            var glyphIndex = subGlyphRange.location
            while glyphIndex < NSMaxRange(subGlyphRange) {
                var fragGlyphRange = NSRange()
                let rect = lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &fragGlyphRange)
                let used = lineFragmentUsedRect(forGlyphAt: fragGlyphRange.location, effectiveRange: nil)
                fragments.append((rect, used.maxX))
                glyphIndex = NSMaxRange(fragGlyphRange)
            }
            guard !fragments.isEmpty else { continue }
            // 以块内最宽一行为右边界：左边做背景填充，右边（无代码的空白）不填充
            let blockMaxX = fragments.map { $0.maxX }.max() ?? 0
            let firstFrag = fragments[0]
            dbg("block \(block.range) headIndent=\(headIndent) frags=\(fragments.count) firstFragRect=\(firstFrag.rect) blockMaxX=\(blockMaxX) fill0=[\(vx(firstFrag.rect.minX + headIndent)),\(vy(firstFrag.rect.minY)) w=\(min(firstFrag.rect.maxX, blockMaxX) - firstFrag.rect.minX - headIndent)]")
            block.color.setFill()
            for (i, frag) in fragments.enumerated() {
                let leftX = vx(frag.rect.minX + headIndent)
                let rightX = vx(min(frag.rect.maxX, blockMaxX))
                let topY = vy(frag.rect.minY)
                // 向下延伸到下一行片段顶缘，把 lineSpacing 一并填满，形成连续整块
                let bottomY = i + 1 < fragments.count
                    ? vy(fragments[i + 1].rect.minY)
                    : vy(frag.rect.maxY)
                guard bottomY > topY, rightX > leftX else { continue }
                let fillRect = NSRect(x: leftX, y: topY, width: rightX - leftX, height: bottomY - topY)
                dbg("fill rect=\(fillRect) flipped=\(NSGraphicsContext.current?.isFlipped ?? false)")
                if ProcessInfo.processInfo.environment["NMD_LM_DEBUG"] == "1" {
                    NSColor.blue.setFill()
                    NSColor.green.setFill()
                    NSRect(x: 0, y: 300, width: 2000, height: 100).fill()
                }
                fillRect.fill()
            }
        }

        // 引用块左侧竖线：每层一条，贴该行片段左缘，向下延伸到下一片段顶缘
        NSColor.separatorColor.setFill()
        for run in quoteRuns {
            let subRun = glyphRange(forCharacterRange: run.range, actualCharacterRange: nil)
            guard subRun.location != NSNotFound else { continue }
            var glyphIndex = subRun.location
            while glyphIndex < NSMaxRange(subRun) {
                var fragGlyphRange = NSRange()
                let rect = lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &fragGlyphRange)
                glyphIndex = NSMaxRange(fragGlyphRange)
                let bottomY: CGFloat
                if glyphIndex < NSMaxRange(subRun) {
                    var nextRange = NSRange()
                    bottomY = vy(lineFragmentRect(forGlyphAt: glyphIndex,
                                                  effectiveRange: &nextRange).minY)
                } else {
                    bottomY = vy(rect.maxY)
                }
                let topY = vy(rect.minY)
                guard bottomY > topY else { continue }
                for level in 1...run.depth {
                    // 引用每层固定缩进 18pt：竖线画在该层文字左缘前 8pt
                    NSRect(x: vx(rect.minX + CGFloat(level) * 18 - 11), y: topY,
                           width: 3, height: bottomY - topY).fill()
                }
            }
        }
    }
}
