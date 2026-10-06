//
//  MarkupToAttributedRenderer+Footnote.swift
//  MarkdownEditorHy4
//
//  脚注的渲染：正文里的 `[^1]` 画成上标，行首的 `[^1]:` 认成定义块。
//
//  ### 为什么这段逻辑单独一个文件
//  主文件 `MarkupToAttributedRenderer.swift` 里只多了三处调用（引用样式、定义识别、定义样式），脚注自己的规矩全在这儿 —— 和 `MarkdownTextView+Outline.swift` 那套分法一样。
//
//  ### 一条底线：一个字符都不许加
//  脚注是**纯属性**语法：认出 `[^1]` 之后只改字体、颜色、baselineOffset，不插占位字符、不改文本长度。所以「全选复制 === 源文件」和「撤销按插入字符数记账」两条不变式不需要为脚注补任何逻辑（这也是它比图片、表格省事的地方）。
//

import UIKit

extension NSAttributedString.Key {
    /// 这几个字符是一个脚注**引用**（`[^1]`），值是它的 ID。
    ///
    /// 点击跳转靠它认出「点到了哪个脚注」，再拿 ID 去 `FootnoteIndex` 查定义在哪儿。
    static let markdownFootnoteReference = NSAttributedString.Key("com.markdowneditor.footnoteReference")

    /// 这一整段是某个脚注的**定义**（`[^1]: …`），值是它的 ID。
    static let markdownFootnoteDefinition = NSAttributedString.Key("com.markdowneditor.footnoteDefinition")
}

extension MarkupToAttributedRenderer {

    // MARK: 引用（`[^1]`）

    /// 给一段渲染结果里的脚注引用套上「上标 + 强调色」的样式。
    ///
    /// ### 定位方式：靠映射表反查，不靠字符下标
    /// 扫描器给的是**源码**里的范围，而渲染串里前面可能已经混进了别的片段（比如同一段里的公式被换成了图），所以拿字符下标直接去 attributed string 里切是不对的。这里遍历 `mappings` 找出「源码起点落在标记范围内」
    /// 的那几个字符位，它们天然是连续的 —— 和 `MarkdownDocumentStore.renderedRanges` 是同一套算法。
    ///
    /// - parameter fragment:     这段文字原本的渲染结果（调用方已经按正文样式渲染好）
    /// - parameter rawText:      这段渲染结果对应的**源码原文**
    /// - parameter sourceRange:  `rawText` 在块源码里的起始位置
    /// - parameter baseFont:     当前字号（脚注字体由它派生）
    func stylingFootnoteReferences(in fragment: RenderedFragment,
                                   rawText: String,
                                   sourceRange: NSRange,
                                   baseFont: UIFont) -> RenderedFragment {
        // 绝大多数正文里没有 `[^`，先挡一道，省掉整段扫描
        guard rawText.contains("[^") else { return fragment }

        // ⚠️ 用 `let`：`text` 是类（NSMutableAttributedString），改它不属于「改这个结构体」
        let out = fragment
        for match in FootnoteIndex.references(in: rawText) {
            let source = NSRange(location: sourceRange.location + match.range.location,
                                 length: match.range.length)
            guard let rendered = renderedRange(in: out, forSourceRange: source) else { continue }

            let hasDefinition = footnoteDefinitionIDs.contains(match.id)
            // 整段 `[^1]` 一起挂 ID：点击命中判定按整块算，点方括号也算点中这个脚注
            out.text.addAttribute(.markdownFootnoteReference, value: match.id, range: rendered)

            // 整段 `[^1]` 一起画成上标：方括号和编号同一个字号、同一个颜色、同一个抬升量。
            // ⚠️ 方括号是**画出来**的，不是被替换掉的 —— 字符一个不动，改的只有画笔（理由见 `footnoteReferenceAttributes` 那条注释）。
            out.text.addAttributes(theme.footnoteReferenceAttributes(hasDefinition: hasDefinition),
                                   range: rendered)
        }
        return out
    }

    // MARK: 定义（`[^1]: …`）

    /// 把**块里出现的每一条**脚注定义标出来：挂上 ID、整条缩进一档，并把开头那个 `[^1]:` 抹成弱化色。
    ///
    /// ### 为什么是「每一条」而不是「块开头那一条」
    /// cmark 会把 `[^1]: 说明` 当成 CommonMark 的**链接引用定义**吃掉；被吃掉之后它不产生节点，于是常常被并进**前一个块**的尾巴（实测源码 `这里有一个…[^note]。\n\n[^1]: 普通脚注。` 整个就是一块）。只认块开头那条的话，这种定义一条都认不出来 ——既没有缩进、也没有弱化色，⌘+ 点它还跳不回正文（因为它身上压根没有「我是定义」这个属性）。
    ///
    /// ### 为什么要顺手摘掉引用标记
    /// 定义开头那个 `[^1]:` 也会被引用扫描认出来（它确实长得一样）。不摘的话，点定义自己的开头会「跳到自己身上」—— 所以整段重新上色时把它删掉最干净。
    func stylingFootnoteDefinitions(_ fragment: inout RenderedFragment,
                                    in blockSource: String,
                                    indent: CGFloat) {
        let markers = FootnoteIndex.definitionMarkers(in: blockSource)
        guard !markers.isEmpty, fragment.text.length > 0 else { return }

        let ns = blockSource as NSString
        let style = theme.footnoteDefinitionParagraphStyle(indent: indent)

        for marker in markers {
            let start = marker.range.location
            let end = min(FootnoteIndex.definitionEnd(startingAt: start, in: blockSource), ns.length)
            guard let body = renderedRange(in: fragment,
                                           forSourceRange: NSRange(location: start, length: max(1, end - start))) else {
                continue
            }

            fragment.text.addAttribute(.markdownFootnoteDefinition, value: marker.id, range: body)
            fragment.text.addAttribute(.paragraphStyle, value: style, range: body)

            guard let head = renderedRange(in: fragment, forSourceRange: marker.range) else { continue }
            fragment.text.removeAttribute(.markdownFootnoteReference, range: head)
            fragment.text.addAttributes(theme.footnoteDefinitionMarkerAttributes, range: head)
        }
    }

    // MARK: 内部

    /// 在一段渲染结果里找出「源码起点落在 `range` 内」的那几个字符位（它们天然连成一段）。
    ///
    /// 找不到就返回 nil：那段源码当前没有对应的渲染字符（比如被折叠了），跳过比写越界范围安全。
    private func renderedRange(in fragment: RenderedFragment, forSourceRange range: NSRange) -> NSRange? {
        var first: Int?
        var last: Int?

        for (index, mapping) in fragment.mappings.enumerated() {
            guard !mapping.isDecoration,
                  mapping.sourceStart >= range.location,
                  mapping.sourceStart < NSMaxRange(range) else { continue }
            if first == nil { first = index }
            last = index
        }

        guard let first, let last else { return nil }
        return NSRange(location: first, length: last - first + 1)
    }
}
