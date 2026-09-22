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

        // 其余背景（如有）仍交给原生填充
        super.drawBackground(forGlyphRange: glyphs, at: point)
        guard !blocks.isEmpty else { return }
        let base = boundingRect(forGlyphRange: glyphs, in: container)
        dbg("call glyphs=\(glyphs) charRange=\(charRange) point=\(point) base=\(base) blocks=\(blocks.count)")
        if ProcessInfo.processInfo.environment["NMD_LM_DEBUG"] == "1" {
            NSColor.red.setFill()
            NSRect(x: 0, y: 0, width: 2000, height: 2000).fill()
        }
        // point = glyphRange 整体 bounding rect 左上角（视图坐标）；
        // 容器坐标统一换算：view = point + (container - baseBounding.origin)
        func vx(_ x: CGFloat) -> CGFloat { point.x + (x - base.minX) }
        func vy(_ y: CGFloat) -> CGFloat { point.y + (y - base.minY) }

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
    }
}
