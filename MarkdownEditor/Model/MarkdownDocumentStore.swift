//
//  MarkdownDocumentStore.swift
//  MarkdownEditorHy4
//
//  文档模型层：分块源码存储 + 块级 AST 缓存 + 源码 ↔ 渲染位置映射表
//

import UIKit
import Markdown

/// 一次编辑的最终产物
struct MarkdownEditOutcome {
    /// 需要被替换掉的旧渲染范围（**旧**坐标系，也就是编辑发生前 textView 里的坐标）
    let replacedRange: NSRange
    /// 替换进去的新内容
    let newContent: NSAttributedString
    /// 编辑完成后光标应该落在的渲染偏移（**新**坐标系）
    let caretRenderedOffset: Int
}

/// 文档模型。
///
/// ### 三个职责
/// 1. **分块存储**：把整篇 markdown 切成若干顶层块，每个块的源码首尾相接等于整篇源码。
/// 2. **增量 parse**：一次编辑只重新解析「受影响的块」那一段源码，而不是整篇文档。
/// 3. **源码映射**：提供「渲染文本里的范围 → 源码文本」的查询，复制/粘贴全靠它。
final class MarkdownDocumentStore {
    /// 所有块，源码首尾相接、渲染范围首尾相接
    private(set) var blocks: [MarkdownBlock] = []
    /// 整篇源码（所有块 sourceText 的拼接）
    private(set) var fullSource: String = ""

    let renderer: MarkupToAttributedRenderer

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释：
    /// 隔离 deinit 一旦嵌套就会踩 Swift 6.2 运行时的野指针 free。
    nonisolated deinit {}

    init(renderer: MarkupToAttributedRenderer = MarkupToAttributedRenderer()) {
        self.renderer = renderer
    }

    // MARK: 只读信息

    /// 整篇渲染出来的纯文本。UITextView 的实际内容和它做 diff，就能知道用户改了哪一段。
    var renderedString: String {
        var result = ""
        result.reserveCapacity(blocks.reduce(0) { $0 + $1.renderedLength })
        for block in blocks { result += block.renderedContent.string }
        return result
    }

    /// 整篇渲染长度
    var renderedLength: Int { blocks.reduce(0) { $0 + $1.renderedLength } }

    /// 整篇 attributed string
    var attributedDocument: NSAttributedString {
        let result = NSMutableAttributedString()
        for block in blocks { result.append(block.renderedContent) }
        return result
    }

    // MARK: - 全量加载

    func load(markdown: String, containerWidth: CGFloat) {
        renderer.containerWidth = containerWidth
        fullSource = markdown
        blocks = buildBlocks(region: NSRange(location: 0, length: markdown.utf16Length), of: markdown)
        recomputeRanges()
    }

    // MARK: - 增量编辑

    /// 把一次「渲染文本里的编辑」翻译成源码编辑，然后只重新解析/渲染受影响的块。
    ///
    /// - parameter renderedRange:  发生变化的渲染范围（**旧**坐标系）
    /// - parameter text:           替换进去的文本（注意：这里传的是**渲染后的文本**，
    ///                             正常情况下它和源码一致；如果用户删掉了一个图片占位符，
    ///                             这里就少了一个 attachment 字符，映射表会自动把它对应的源码一起删掉）
    /// - parameter containerWidth: 容器宽度（图片要按它算尺寸）
    func applyEdit(inRenderedRange renderedRange: NSRange,
                   replacementText text: String,
                   containerWidth: CGFloat) -> MarkdownEditOutcome {
        renderer.containerWidth = containerWidth

        // 1) 渲染范围 → 源码范围。
        //    删除时先做一次「语法标记扩展」：退格删到 `- ` 里就整段删掉（见方法注释）
        let effectiveRange = text.isEmpty ? expandedSyntaxMarkerRange(renderedRange) : renderedRange
        let sourceStart = sourceCaret(forRenderedOffset: effectiveRange.location)
        let sourceEnd = sourceCaret(forRenderedOffset: NSMaxRange(effectiveRange))
        let editRange = NSRange(location: sourceStart, length: max(0, sourceEnd - sourceStart))

        // 2) 算出新的整篇源码
        let newSource = (fullSource as NSString).replacingCharacters(in: editRange, with: text)
        let replacementLength = (text as NSString).length

        // 3) 受影响的块
        let affected = affectedBlockIndices(forRenderedRange: effectiveRange, sourceEditRange: editRange)

        // 4) 需要重新 parse 的区域（先按旧源码取并集，再按增删量伸缩，最后保证包含编辑点）
        var reparseRange = unionSourceRange(of: affected)
        let delta = replacementLength - editRange.length
        reparseRange.length = max(0, reparseRange.length + delta)
        reparseRange = reparseRange.union(NSRange(location: editRange.location, length: replacementLength))
        reparseRange = clamp(reparseRange, to: newSource.utf16Length)

        // 5) 记下旧渲染范围，等下要按它做局部替换
        let oldRenderedRange = unionRenderedRange(of: affected)

        // 6) 重新 parse + 渲染这一小段，换掉旧块
        let newBlocks = buildBlocks(region: reparseRange, of: newSource)
        blocks.removeSubrange(affected)
        blocks.insert(contentsOf: newBlocks, at: affected.lowerBound)
        fullSource = newSource
        recomputeRanges()

        // 7) 拼出要替换进去的新内容
        let newContent = NSMutableAttributedString()
        for block in newBlocks { newContent.append(block.renderedContent) }

        // 8) 光标位置：源码里的插入点 → 渲染坐标
        let caretSource = editRange.location + replacementLength
        let caret = renderedCaret(forSourceOffset: caretSource)

        return MarkdownEditOutcome(replacedRange: oldRenderedRange,
                                   newContent: newContent,
                                   caretRenderedOffset: caret)
    }

    // MARK: - 源码映射（复制/粘贴用）

    /// 把「渲染文本里的范围」翻译回源码文本。
    ///
    /// 这是复制功能的全部秘密：**永远不指望从 attributed string 反推源码**，一律查映射表。
    func sourceText(forRenderedRange range: NSRange) -> String {
        guard range.length > 0 else { return "" }

        var result = ""

        for block in blocks {
            guard let intersection = block.renderedRange.intersection(range), intersection.length > 0 else { continue }
            let localStart = intersection.location - block.renderedRange.location

            // 用来去掉 emoji 这种「一个字符占 2 个 UTF-16 单元」造成的重复。
            // 注意：mapping.sourceStart 是 **块内** 偏移，所以这个游标必须每个块重置，
            // 否则第 2 个块开头那一段源码会因为「比上一个块的结束位置小」被整段跳过。
            var lastSourceEnd = -1

            for index in localStart..<(localStart + intersection.length) {
                guard let mapping = block.mapping(at: index), !mapping.isDecoration else { continue }
                guard mapping.sourceStart >= 0, mapping.sourceLength > 0 else { continue }
                // 同一个源码字符映射到了多个渲染字符位（emoji 的代理对），只输出一次
                guard mapping.sourceStart >= lastSourceEnd else { continue }
                result += block.sourceText.substring(utf16Offset: mapping.sourceStart, length: mapping.sourceLength)
                lastSourceEnd = mapping.sourceStart + mapping.sourceLength
            }
        }
        return result
    }

    /// 整篇源码（复制全部时的快捷方式）
    var sourceDocument: String { fullSource }

    // MARK: - 坐标换算

    /// 渲染偏移（光标位置）→ 源码偏移
    func sourceCaret(forRenderedOffset offset: Int) -> Int {
        for block in blocks {
            let range = block.renderedRange
            guard offset >= range.location, offset <= NSMaxRange(range) else { continue }

            let local = offset - range.location

            // 优先看当前位置这个字符的映射
            if let mapping = block.mapping(at: local), !mapping.isDecoration {
                return block.sourceRange.location + mapping.sourceStart
            }
            // 当前位置是装饰字符（或者正好在块末尾），就往前找最近一个有源码映射的字符，取它的结束位置
            var index = min(local, block.charMappings.count) - 1
            while index >= 0 {
                let mapping = block.charMappings[index]
                if !mapping.isDecoration {
                    return block.sourceRange.location + mapping.sourceStart + mapping.sourceLength
                }
                index -= 1
            }
            return block.sourceRange.location
        }
        // 越界：当作文末
        return fullSource.utf16Length
    }

    /// 源码偏移（光标位置）→ 渲染偏移
    func renderedCaret(forSourceOffset offset: Int) -> Int {
        for block in blocks {
            let range = block.sourceRange
            // 注意这里是 `<` 不是 `<=`：块与块的源码首尾相接，边界那个偏移同时属于
            // 「前一块的末尾」和「后一块的开头」。用 `<=` 会命中前一块，
            // 光标就落到了前一块的最后一个字符位上（比如列表块开头那个圆点里）。
            // 用 `<` 让边界归后一块，光标才能落在后一块真正的源码文本上。
            guard offset >= range.location, offset < NSMaxRange(range) else { continue }

            let local = offset - range.location
            // 第一遍：跳过图片、圆点这类「额外挂上去的视觉元素」，
            // 光标要落在真正的源码文本上（源码文本就在这些元素旁边）。
            // 否则光标会停进图片里，用户继续输入就成了「在图片里打字」。
            if let hit = searchCaret(in: block, local: local, skipAttachmentViews: true) { return hit }
            // 第二遍：这个块里只有视觉元素（比如分隔线 `---` 整块就一个 attachment），
            // 那就只能落在它身上。
            if let hit = searchCaret(in: block, local: local, skipAttachmentViews: false) { return hit }
            return block.renderedRange.location + block.renderedLength
        }
        return renderedLength
    }

    /// 在一个块里找「源码偏移 local」对应的渲染位置
    /// - parameter skipAttachmentViews: 是否跳过图片 / 圆点这类视觉元素
    private func searchCaret(in block: MarkdownBlock, local: Int, skipAttachmentViews: Bool) -> Int? {
        for (index, mapping) in block.charMappings.enumerated() {
            if mapping.isDecoration { continue }
            if skipAttachmentViews, mapping.isAttachmentView { continue }
            // 插在这个字符之前
            if mapping.sourceStart >= local {
                return block.renderedRange.location + index
            }
            // 落在这个字符（或 attachment）内部：插到它后面
            if local < mapping.sourceStart + mapping.sourceLength {
                return block.renderedRange.location + index + 1
            }
        }
        return nil
    }

    /// 退格删到「语法标记」（列表的 `- `）里时，把删除范围扩展到整个标记。
    ///
    /// 否则 `- ` 只删掉一个字符，会留下 `-一级列表项` 这种既不是列表、
    /// 行首又带着一个破折号的残片；整段删掉才是用户想要的「降级成段落」。
    private func expandedSyntaxMarkerRange(_ renderedRange: NSRange) -> NSRange {
        guard renderedRange.length > 0 else { return renderedRange }

        for block in blocks {
            guard block.renderedRange.intersects(renderedRange) else { continue }
            let length = block.renderedContent.length
            guard length > 0 else { continue }

            let local = min(max(0, renderedRange.location - block.renderedRange.location), length - 1)
            // 删除起点不在语法标记上 → 原样返回
            guard block.renderedContent.attribute(.markdownSyntaxMarker, at: local, effectiveRange: nil) != nil else {
                return renderedRange
            }

            // 往前往后扩，把一整段连续的标记圈出来
            var lower = local
            var upper = local + 1
            while lower - 1 >= 0,
                  block.renderedContent.attribute(.markdownSyntaxMarker, at: lower - 1, effectiveRange: nil) != nil {
                lower -= 1
            }
            while upper < length,
                  block.renderedContent.attribute(.markdownSyntaxMarker, at: upper, effectiveRange: nil) != nil {
                upper += 1
            }
            return NSRange(location: block.renderedRange.location + lower, length: upper - lower)
        }
        return renderedRange
    }

    // MARK: - 块的构建

    /// 解析并渲染 `source` 的某一小段，切成若干块。
    ///
    /// 切分约定：每个块的源码 = [本块起点, 下一个块起点)，也就是把中间的换行和空行都吃掉。
    /// 这样所有块的源码首尾相接正好等于整篇源码。
    private func buildBlocks(region: NSRange, of source: String) -> [MarkdownBlock] {
        let regionText = source.substring(utf16Offset: region.location, length: region.length)
        let document = Document(parsing: regionText)
        let table = SourceLocationTable(source: regionText)

        // 收集顶层块在 regionText 里的起点
        var entries: [(markup: BlockMarkup, start: Int)] = []
        for child in document.children {
            guard let block = child as? BlockMarkup, let range = child.range else { continue }
            entries.append((block, table.utf16Range(of: range).location))
        }
        entries.sort { $0.start < $1.start }

        // 整段都是空行（或者空文档）：退化成一个纯文本块
        guard !entries.isEmpty else {
            return [makeTextBlock(source: regionText, absoluteStart: region.location)]
        }

        var result: [MarkdownBlock] = []
        for (index, entry) in entries.enumerated() {
            // 第一个块要把区域开头的空白也吃掉，保证块与块之间不留缝
            let startOffset = index == 0 ? 0 : entry.start
            let endOffset = index + 1 < entries.count ? entries[index + 1].start : region.length
            guard endOffset > startOffset else { continue }

            let blockSource = regionText.substring(utf16Offset: startOffset, length: endOffset - startOffset)
            result.append(makeBlock(source: blockSource,
                                    absoluteStart: region.location + startOffset,
                                    ast: entry.markup))
        }
        return result
    }

    private func makeBlock(source blockSource: String, absoluteStart: Int, ast: BlockMarkup) -> MarkdownBlock {
        let (text, mappings) = renderer.render(blockSource: blockSource)
        return MarkdownBlock(
            sourceText: blockSource,
            sourceRange: NSRange(location: absoluteStart, length: blockSource.utf16Length),
            renderedContent: text,
            charMappings: mappings,
            kindDescription: MarkdownBlock.describe(ast)
        )
    }

    /// 整块都是空行/空白时，原样渲染（1 个字符对 1 个源码字符，天然保证复制还原）
    private func makeTextBlock(source blockSource: String, absoluteStart: Int) -> MarkdownBlock {
        let fragment = RenderedFragment.sourceSliced(blockSource,
                                                     sourceStart: 0,
                                                     attributes: renderer.theme.orphanAttributes)
        return MarkdownBlock(
            sourceText: blockSource,
            sourceRange: NSRange(location: absoluteStart, length: blockSource.utf16Length),
            renderedContent: fragment.text,
            charMappings: fragment.mappings,
            kindDescription: "RawText"
        )
    }

    /// 重新计算每一块的源码范围和渲染范围（块的源码首尾相接，渲染结果也是首尾相接）
    private func recomputeRanges() {
        var sourceLocation = 0
        var renderedLocation = 0
        for block in blocks {
            block.sourceRange = NSRange(location: sourceLocation, length: block.sourceText.utf16Length)
            block.renderedRange = NSRange(location: renderedLocation, length: block.renderedLength)
            sourceLocation += block.sourceText.utf16Length
            renderedLocation += block.renderedLength
        }
    }

    // MARK: - 受影响的块

    /// 找出这次编辑动到了哪些块。
    ///
    /// 除了「渲染范围和编辑范围相交」的块，还要额外处理一种情况：
    /// 编辑碰到了某个块**结尾的换行**（比如把两段之间的空行删掉），前后两块会被合并，
    /// 这时候必须把下一块也一起重新解析，否则块与块之间就会出现对不上的缝。
    private func affectedBlockIndices(forRenderedRange renderedRange: NSRange,
                                      sourceEditRange: NSRange) -> Range<Int> {
        guard !blocks.isEmpty else { return 0..<0 }

        var lower = Int.max
        var upper = Int.min

        for (index, block) in blocks.enumerated() {
            let range = block.renderedRange
            let hit: Bool
            if renderedRange.length == 0 {
                // 光标是一个点，落在块的闭区间里就算命中
                hit = renderedRange.location >= range.location && renderedRange.location <= NSMaxRange(range)
            } else {
                hit = range.intersects(renderedRange)
            }
            if hit {
                lower = min(lower, index)
                upper = max(upper, index + 1)
            }
        }

        if lower == Int.max {
            // 一个块都没命中（多半是空文档），拿最后一块兜底
            return (blocks.count - 1)..<blocks.count
        }

        // 尾部换行被改动了 → 把下一块也拉进来一起重排
        var end = upper
        for index in lower..<upper {
            guard index < blocks.count - 1 else { break }
            let tail = trailingWhitespaceRange(of: blocks[index])
            if rangesTouch(tail, sourceEditRange) {
                end = upper + 1
                break
            }
        }
        return lower..<end
    }

    /// 块源码结尾的那一段换行/空白，转成整篇源码的绝对范围
    private func trailingWhitespaceRange(of block: MarkdownBlock) -> NSRange {
        let text = block.sourceText
        var start = text.utf16Length
        var index = start - 1
        while index >= 0 {
            let character = text.substring(utf16Offset: index, length: 1)
            guard character == "\n" || character == " " || character == "\t" else { break }
            start = index
            index -= 1
        }
        return NSRange(location: block.sourceRange.location + start,
                       length: block.sourceRange.length - start)
    }

    private func unionSourceRange(of indices: Range<Int>) -> NSRange {
        guard !indices.isEmpty, indices.lowerBound < blocks.count else {
            return NSRange(location: 0, length: 0)
        }
        let from = max(0, indices.lowerBound)
        let to = min(blocks.count - 1, indices.upperBound - 1)
        let start = blocks[from].sourceRange.location
        let end = NSMaxRange(blocks[to].sourceRange)
        return NSRange(location: start, length: max(0, end - start))
    }

    private func unionRenderedRange(of indices: Range<Int>) -> NSRange {
        guard !indices.isEmpty, indices.lowerBound < blocks.count else {
            return NSRange(location: 0, length: 0)
        }
        let from = max(0, indices.lowerBound)
        let to = min(blocks.count - 1, indices.upperBound - 1)
        let start = blocks[from].renderedRange.location
        let end = NSMaxRange(blocks[to].renderedRange)
        return NSRange(location: start, length: max(0, end - start))
    }

    private func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        let end = min(max(location, NSMaxRange(range)), length)
        return NSRange(location: location, length: end - location)
    }

    /// 两个范围是否接触（含零长度范围落在对方内部的情况）
    private func rangesTouch(_ a: NSRange, _ b: NSRange) -> Bool {
        if a.length == 0 { return b.location <= a.location && a.location <= NSMaxRange(b) }
        if b.length == 0 { return a.location <= b.location && b.location <= NSMaxRange(a) }
        return a.intersects(b)
    }
}

// MARK: - NSRange 小工具

extension NSRange {
    func intersects(_ other: NSRange) -> Bool {
        NSIntersectionRange(self, other).length > 0
    }

    func intersection(_ other: NSRange) -> NSRange? {
        let result = NSIntersectionRange(self, other)
        return result.length > 0 || result.location == other.location ? result : nil
    }
}
