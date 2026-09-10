//
//  MarkupToAttributedRenderer.swift
//  MarkdownEditorHy4
//
//  AST → NSAttributedString（MarkupVisitor 实现）
//

import UIKit
import Markdown

/// 把 swift-markdown 的 AST 渲染成 `NSAttributedString`。
///
/// ### 两类渲染方式
/// - **简单节点（标题的 `#`、粗体的 `**`）**：纯属性区间。字符老老实实待在文本流里，
///   编辑、光标、复制行为全部原生正确，零额外成本。
/// - **复杂节点（图片、列表圆点、分隔线）**：`NSTextAttachment`，在文本流里占 1 个字符位。
///   好处是跟随文本自然排版，代价是这个字符不再是源码字符 —— 靠 `CharMapping` 补回来。
///
/// ### 源码覆盖率由构造保证
/// 每个块渲染完都会跑一次 `reconcile`：把 AST 没覆盖到的源码字符（引用块的 `>`、代码块的 ```，
/// 闭合式标题结尾的 `###`…）按原顺序补进渲染结果并弱化显示。
/// 这样「全选复制出来的文本 === 源文件」是**结构性成立**的，不用为每种语法单独维护映射。
final class MarkupToAttributedRenderer: MarkupVisitor {
    typealias Result = RenderedFragment

    // MARK: 配置

    let theme: MarkdownTheme
    /// 容器宽度，图片和分隔线要按它算尺寸
    var containerWidth: CGFloat
    /// 相对路径图片的基准目录
    var imageBaseURL: URL?
    /// 网络图片加载完尺寸变了，通过它通知 TextKit 重新排版
    weak var attachmentHost: MarkdownAttachmentHost?

    // MARK: 当前块的上下文（只在 render(blockSource:) 执行期间有效）

    private var source: String = ""
    private var table = SourceLocationTable(source: "")
    /// 字体栈：处理 `**粗体里的 *斜体***` 这种嵌套
    private var fontStack: [UIFont] = []
    private var currentTextColor: UIColor = .label
    /// 当前缩进（列表、引用块会累加）
    private var indent: CGFloat = 0
    /// 正在列表项内部：段落样式由列表项统一设置，段落自己不要重复设置
    private var isInsideListItem = false

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释：
    /// 隔离 deinit 一旦嵌套就会踩 Swift 6.2 运行时的野指针 free。
    nonisolated deinit {}

    init(theme: MarkdownTheme = .default, containerWidth: CGFloat = 600) {
        self.theme = theme
        self.containerWidth = containerWidth
    }

    // MARK: - 对外入口

    /// 渲染一个块。
    /// - parameter blockSource: 该块的 markdown 源码
    /// - returns: 富文本 + 每个字符位的源码映射
    func render(blockSource: String) -> (text: NSAttributedString, mappings: [CharMapping]) {
        beginBlock(source: blockSource)
        defer { endBlock() }

        let document = Document(parsing: blockSource)

        var fragment = RenderedFragment.empty
        for child in document.children {
            fragment.append(visit(child))
        }

        // 兜底 + 补漏：保证源码里每个字符都在渲染结果里有归宿
        let fixed = fragment.reconciled(
            withSource: blockSource,
            orphanAttributes: theme.orphanAttributes
        )
        return (fixed.text, fixed.mappings)
    }

    private func beginBlock(source: String) {
        self.source = source
        self.table = SourceLocationTable(source: source)
        self.fontStack = [theme.bodyFont]
        self.currentTextColor = theme.textColor
        self.indent = 0
        self.isInsideListItem = false
    }

    private func endBlock() {
        source = ""
        table = SourceLocationTable(source: "")
        fontStack = []
        indent = 0
        isInsideListItem = false
    }

    // MARK: - MarkupVisitor

    /// 统一的派发入口。
    ///
    /// `MarkupVisitor` 协议把 `visit(_:)` 声明成了 `mutating`，但类是引用类型、
    /// `self` 不可变，所以类实现时必须写成非 mutating 版本，这样才能满足协议要求。
    /// 实现里用一个局部可变副本去调用 `accept(&visitor)` —— 反正我们派发出去之后
    /// 不会再改动 visitor 自身的状态，副本和原对象是同一个实例，效果完全一样。
    func visit(_ markup: Markup) -> RenderedFragment {
        var visitor = self
        return markup.accept(&visitor)
    }

    func defaultVisit(_ markup: Markup) -> RenderedFragment {
        var out = RenderedFragment.empty
        for child in markup.children {
            out.append(visit(child))
        }
        return out
    }

    // MARK: 行内叶子节点

    func visitText(_ text: Text) -> RenderedFragment {
        // 优先用源码原文：这样 `\*` 这种转义会原样显示，也保证渲染串长度和源码范围严格一致
        if let range = localRange(of: text) {
            return .sourceSliced(sourceText(in: range), sourceStart: range.location, attributes: bodyAttributes)
        }
        return .sourceSliced(text.string, sourceStart: -1, attributes: bodyAttributes)
    }

    /// 段落里的软换行（`1\n这是…` 中间那个换行）。
    ///
    /// ### 拿不到范围时必须返回空，不能返回 `.decoration("\n")`（这里踩过坑，别改回去）
    /// cmark 经常不给软换行标 `range`。如果这时自己输出一个 `\n`，
    /// **补漏步骤（`reconciled`）并不知道这个源码字符已经被消费了**，
    /// 它会把源码里那个 `\n` 再补一遍 —— 于是用户按一次回车，屏幕上多出两个换行
    /// （「显示换了 2 行，复制出来却只有 1 行」就是这个现象）。
    /// 返回空，让补漏步骤用源码原文补，才是正好一个。
    func visitSoftBreak(_ softBreak: SoftBreak) -> RenderedFragment {
        guard let range = localRange(of: softBreak) else { return .empty }
        return .sourceSliced(sourceText(in: range), sourceStart: range.location, attributes: bodyAttributes)
    }

    /// 硬换行（行尾两个空格或反斜杠）。道理同软换行：拿不到范围就交给补漏步骤。
    func visitLineBreak(_ lineBreak: LineBreak) -> RenderedFragment {
        guard let range = localRange(of: lineBreak) else { return .empty }
        return .sourceSliced(sourceText(in: range), sourceStart: range.location, attributes: bodyAttributes)
    }

    func visitInlineCode(_ inlineCode: InlineCode) -> RenderedFragment {
        if let range = localRange(of: inlineCode) {
            // 连反引号一起显示，保持所见即源码
            return .sourceSliced(sourceText(in: range), sourceStart: range.location, attributes: theme.inlineCodeAttributes)
        }
        return .decoration("`\(inlineCode.code)`", attributes: theme.inlineCodeAttributes)
    }

    func visitInlineHTML(_ inlineHTML: InlineHTML) -> RenderedFragment {
        if let range = localRange(of: inlineHTML) {
            return .sourceSliced(sourceText(in: range), sourceStart: range.location, attributes: theme.markerAttributes)
        }
        return .decoration(inlineHTML.rawHTML, attributes: theme.markerAttributes)
    }

    // MARK: 行内容器节点

    func visitStrong(_ strong: Strong) -> RenderedFragment {
        pushFont(currentFont.adding(.traitBold))
        defer { popFont() }
        return defaultVisit(strong)
    }

    func visitEmphasis(_ emphasis: Emphasis) -> RenderedFragment {
        pushFont(currentFont.adding(.traitItalic))
        defer { popFont() }
        return defaultVisit(emphasis)
    }

    func visitStrikethrough(_ strikethrough: Strikethrough) -> RenderedFragment {
        var out = defaultVisit(strikethrough)
        out.addAttributesIfAbsent([.strikethroughStyle: NSUnderlineStyle.single.rawValue])
        return out
    }

    func visitLink(_ link: Link) -> RenderedFragment {
        var out = defaultVisit(link)
        // 链接正文上色；如果是能点开的 URL，顺便挂上 link 属性
        var attributes = theme.linkAttributes
        if let destination = link.destination, let url = URL(string: destination) {
            attributes[.link] = url
        }
        out.addAttributesIfAbsent(attributes)
        return out
    }

    func visitImage(_ image: Image) -> RenderedFragment {
        guard let range = localRange(of: image) else {
            // 拿不到范围（理论上是手工构造的 AST），退化成纯文本
            return .decoration("![](\(image.source ?? ""))", attributes: theme.markerAttributes)
        }

        let markdownSource = sourceText(in: range)
        guard let url = ImageLoader.resolve(source: image.source, baseURL: imageBaseURL) else {
            // 图片找不到，退化成源码原文显示
            return .sourceSliced(markdownSource, sourceStart: range.location, attributes: theme.markerAttributes)
        }

        let maxWidth = max(60, containerWidth - indent - 16)
        let attachment = ImageAttachment(
            markdownSource: markdownSource,
            imageURL: url,
            maxWidth: maxWidth,
            maxHeight: theme.imageMaxHeight
        )
        attachment.host = attachmentHost
        attachment.loadIfNeeded(host: attachmentHost)

        let style = theme.blockAttachmentParagraphStyle(indent: indent)
        var out = RenderedFragment.empty
        out.append(.attachment(attachment,
                               sourceStart: range.location,
                               sourceLength: range.length,
                               attributes: [.paragraphStyle: style, .font: theme.bodyFont]))
        // 在图片下方弱化显示源码 `![alt](url)`：方便用户对照看真实语法。
        // 这行字**就是源码本身**（真实映射），光标能停在里面正常编辑；
        // 图片那一个字符位是额外挂上去的，复制时两者靠去重逻辑只输出一次。
        if theme.showsSourceHints {
            out.append(.decoration("\n", attributes: [.paragraphStyle: style, .font: theme.bodyFont]))
            out.append(.sourceHint(markdownSource,
                                   sourceStart: range.location,
                                   attributes: theme.markerAttributes))
        }
        return out
    }

    // MARK: 块级节点

    func visitParagraph(_ paragraph: Paragraph) -> RenderedFragment {
        let wasInsideListItem = isInsideListItem
        isInsideListItem = false
        defer { isInsideListItem = wasInsideListItem }

        var out = defaultVisit(paragraph)
        // 列表项内部的段落样式由列表项统一设置，这里不要覆盖
        if !wasInsideListItem {
            out.addAttributesIfAbsent([.paragraphStyle: theme.paragraphStyle(indent: indent)])
        }
        return out
    }

    func visitHeading(_ heading: Heading) -> RenderedFragment {
        let headingFont = theme.headingFonts[heading.level] ?? theme.bodyFont
        pushFont(headingFont)
        defer { popFont() }

        var out = defaultVisit(heading)
        // `#` 标记弱化：它们不在任何子节点范围内，靠补漏步骤补进来，这里先把样式准备好
        out.addAttributesIfAbsent([.paragraphStyle: theme.headingParagraphStyle(indent: indent)])
        return out
    }

    func visitBlockQuote(_ blockQuote: BlockQuote) -> RenderedFragment {
        let savedIndent = indent
        let savedColor = currentTextColor
        let contentIndent = savedIndent + theme.quoteIndent

        indent = contentIndent
        currentTextColor = theme.quoteColor
        let quoteStyle = theme.paragraphStyle(indent: contentIndent)

        var out = defaultVisit(blockQuote)

        currentTextColor = savedColor
        indent = savedIndent

        // 把 `>` 这些没被子节点覆盖的源码字符补进来，
        // 并且给它们和引用正文一样的段落样式，否则行首的 `>` 会把整段的缩进带跑偏
        var orphanAttributes = theme.markerAttributes
        orphanAttributes[.paragraphStyle] = quoteStyle
        out = out.reconciled(withSource: source,
                             in: localRange(of: blockQuote),
                             orphanAttributes: orphanAttributes)
        out.addAttributesIfAbsent([.paragraphStyle: quoteStyle])

        // 引用块的「左侧绿条」：每行一个绿条 attachment，贴在行首 `>` 之前。
        // 这样绿条跟着该行 layout 走，零测量成本；行间留 6pt 段距不影响识别。
        insertQuoteBars(into: &out,
                        lineHeight: theme.bodyFont.lineHeight,
                        color: theme.quoteBarColor,
                        width: theme.quoteBarWidth)

        return out
    }

    /// 在引用块每行 `>` 字符之前插入一条绿条 attachment。
    ///
    /// reconciled 之后 textStorage 已经是「完整字符串 + 正确段落样式」，每行 `>` 都在位。
    /// 我们反向遍历每个 `>` 字符位置，在它前面塞一个绿条 attachment：
    ///   - attachment 跟随该行 layout（无需任何 fragment 测量）
    ///   - attachment 是装饰性，isAttachmentView=true，复制时跳过
    ///   - 退格选区如果选中绿条 attachment，整段一起删（`.markdownSyntaxMarker` 标记）
    ///
    /// 行间会留 ~6pt 段距缝隙（`paragraphSpacing` 不在 line height 内），
    /// 视觉上像断开的虚线绿条，足够识别「这是引用块」。
    private func insertQuoteBars(into out: inout RenderedFragment,
                                 lineHeight: CGFloat,
                                 color: UIColor,
                                 width: CGFloat) {
        // 找出所有 `>` 字符的位置
        let nsString = out.text.string as NSString
        var barPositions: [Int] = []
        var idx = 0
        while idx < nsString.length {
            if nsString.character(at: idx) == 0x3E /* > */ {
                barPositions.append(idx)
            }
            idx += 1
        }
        guard !barPositions.isEmpty else { return }

        // 反向插入（从末尾开始插，否则前面的偏移会被后面搞乱）
        let barFragment = RenderedFragment.decorationAttachment(
            QuoteBarAttachment(width: width, height: lineHeight, color: color),
            attributes: [:]
        )
        for pos in barPositions.reversed() {
            out.text.insert(barFragment.text, at: pos)
            out.mappings.insert(barFragment.mappings[0], at: pos)
        }
    }

    func visitCodeBlock(_ codeBlock: CodeBlock) -> RenderedFragment {
        let codeStyle = theme.codeParagraphStyle(indent: indent)
        let code = codeBlock.code
        var out = RenderedFragment.empty

        // 找到代码正文在源码里的位置：跳过第一行（``` 围栏那一行）
        var searchStart = 0
        if let firstNewline = source.nsRange(of: "\n", fromUTF16Offset: 0) {
            searchStart = NSMaxRange(firstNewline)
        }
        if let codeRange = source.nsRange(of: code, fromUTF16Offset: searchStart), !code.isEmpty {
            out.append(.sourceSliced(code, sourceStart: codeRange.location, attributes: theme.codeBlockAttributes))
        } else if !code.isEmpty {
            out.append(.decoration(code, attributes: theme.codeBlockAttributes))
        }

        // 首尾的 ``` 由补漏步骤补进来
        var orphanAttributes = theme.markerAttributes
        orphanAttributes[.paragraphStyle] = codeStyle
        out = out.reconciled(withSource: source,
                             in: localRange(of: codeBlock),
                             orphanAttributes: orphanAttributes)
        out.addAttributesIfAbsent([.paragraphStyle: codeStyle])

        // 打上「这是一个代码块」的标记（**含**首尾的 ``` 行，这样背景矩形能把围栏也包进去）。
        // UI 层靠它算出矩形位置、画出背景并放复制按钮，详见 CodeBlockInfo 的注释。
        out.setAttributes([.markdownCodeBlock: CodeBlockInfo(code: code, language: codeBlock.language)])
        return out
    }

    func visitThematicBreak(_ thematicBreak: ThematicBreak) -> RenderedFragment {
        guard let range = localRange(of: thematicBreak) else { return .empty }

        let separator = SeparatorAttachment(
            width: max(60, containerWidth - indent - 16),
            lineColor: theme.separatorColor,
            font: theme.bodyFont
        )
        let style = theme.blockAttachmentParagraphStyle(indent: indent)
        return .attachment(separator,
                           sourceStart: range.location,
                           sourceLength: range.length,
                           attributes: [.paragraphStyle: style, .font: theme.bodyFont])
    }

    func visitHTMLBlock(_ htmlBlock: HTMLBlock) -> RenderedFragment {
        // HTML 块是叶子节点，没有子节点；整块都靠补漏步骤原样显示
        var out = RenderedFragment.empty
        guard let range = localRange(of: htmlBlock) else { return out }
        out.append(.sourceSliced(sourceText(in: range),
                                 sourceStart: range.location,
                                 attributes: theme.markerAttributes))
        out.addAttributesIfAbsent([.paragraphStyle: theme.paragraphStyle(indent: indent)])
        return out
    }

    // MARK: 列表

    func visitUnorderedList(_ unorderedList: UnorderedList) -> RenderedFragment {
        var out = RenderedFragment.empty
        for item in unorderedList.listItems {
            out.append(renderListItem(item, ordered: false))
        }
        return out
    }

    func visitOrderedList(_ orderedList: OrderedList) -> RenderedFragment {
        var out = RenderedFragment.empty
        for item in orderedList.listItems {
            out.append(renderListItem(item, ordered: true))
        }
        return out
    }

    func visitListItem(_ listItem: ListItem) -> RenderedFragment {
        // 正常流程下列表项由父级列表统一渲染（父级要负责画圆点），
        // 万一被单独访问到（比如某些嵌套结构），这里退化成普通容器
        defaultVisit(listItem)
    }

    /// 渲染一个列表项：标记 + 内容，并给整段套上「悬挂缩进」的段落样式
    private func renderListItem(_ item: ListItem, ordered: Bool) -> RenderedFragment {
        let markerIndent = indent
        let contentIndent = indent + theme.listIndent

        var out = RenderedFragment.empty

        // 1) 列表标记：`- ` / `* ` / `1. `
        if let markerRange = markerRange(of: item) {
            let markerText = sourceText(in: markerRange)
            if ordered {
                // 有序列表直接显示源码里的 `1. `，编辑时能直接改，也不需要额外维护映射
                out.append(.sourceSliced(markerText, sourceStart: markerRange.location, attributes: theme.listMarkerAttributes))
            } else {
                // 无序列表：圆点 attachment 占 1 个字符位，但映射到源码里的 `- ` 这段，
                // 于是「复制还原」和「退格降级」两个行为自动就对了。
                let bullet = BulletAttachment(diameter: theme.bulletDiameter,
                                              color: theme.bulletColor,
                                              font: theme.bodyFont)
                out.append(.attachment(bullet,
                                       sourceStart: markerRange.location,
                                       sourceLength: markerRange.length,
                                       attributes: theme.bodyAttributes(font: theme.bodyFont)))
                // 圆点后面弱化显示 `- ` 源码：和有序列表的 `1. ` 视觉对称，又能看到真实语法。
                // 这 `- ` 就是源码本身（真实映射），所以光标停在它后面输入完全正常。
                if theme.showsSourceHints {
                    out.append(.sourceHint(markerText,
                                           sourceStart: markerRange.location,
                                           isSyntaxMarker: true,
                                           attributes: theme.markerAttributes))
                }
            }
        }

        // 2) 内容（可能是段落，也可能是嵌套列表）
        let savedInsideListItem = isInsideListItem
        indent = contentIndent
        isInsideListItem = true
        for child in item.children {
            out.append(visit(child))
        }
        isInsideListItem = savedInsideListItem
        indent = markerIndent

        // 3) 套悬挂缩进：首行（含标记）从 markerIndent 开始，换行后从 contentIndent 开始
        out.addAttributesIfAbsent([
            .paragraphStyle: theme.listItemParagraphStyle(markerIndent: markerIndent,
                                                          contentIndent: contentIndent)
        ])
        return out
    }

    // MARK: 折叠（顶层块左侧的展开 / 折叠按钮）

    /// 给一个块的**第一个字符**打上「折叠锚点」标记。
    ///
    /// 注意这里**不插入任何字符**：三角由 UI 层画在正文左边的装订线里
    /// （详见 `FoldAnchorInfo` 的注释）。占字符位的旧做法会把第一行往右推，
    /// 导致多行文字左边缘对不齐。
    ///
    /// - parameter blockID:    所属块（点三角时靠它反查要折叠哪一块）
    /// - parameter isCollapsed: 当前折叠状态（决定三角朝向）
    func markFoldAnchor(on fragment: inout RenderedFragment,
                        blockID: UUID,
                        isCollapsed: Bool) {
        guard fragment.text.length > 0 else { return }

        let index = firstNonWhitespaceIndex(in: fragment.text)
        let info = FoldAnchorInfo(blockID: blockID, isCollapsed: isCollapsed)
        fragment.text.addAttribute(.markdownFoldAnchor,
                                   value: info,
                                   range: NSRange(location: index, length: 1))
    }

    /// 折叠状态下整块的内容：**一个「⋯」占位符**（一个字符位代替整块）。
    ///
    /// 三角不在文本里 —— 和展开态一样，只在占位符上打个锚点标记，
    /// UI 层照样在装订线里画 ▶。
    ///
    /// ### 折叠了源码还在吗？在
    /// 折叠只是视图状态，`MarkdownBlock.sourceText` 一个字没动。
    /// 占位符映射到「整块源码」（`.attachmentView(start: 0, length: 整块长度)`），
    /// 所以复制时它这一个字符位会吐出整块源码 ——
    /// **「全选复制 === 源文件」在折叠状态下依然成立**（有测试守着）。
    func collapsedContent(blockID: UUID,
                          sourceText: String) -> (text: NSAttributedString, mappings: [CharMapping]) {
        let style = theme.paragraphStyle(indent: 0)
        var fragment = RenderedFragment.empty

        let placeholder = CollapsedBlockAttachment(width: theme.collapsedPlaceholderWidth,
                                                   color: theme.collapsedPlaceholderColor,
                                                   font: theme.bodyFont)
        fragment.append(.attachment(placeholder,
                                    sourceStart: 0,
                                    sourceLength: sourceText.utf16Length,
                                    attributes: [.font: theme.bodyFont, .paragraphStyle: style]))

        // 把块尾的换行补回来 —— 不补的话下一个块会直接贴在「⋯」后面，一行挤两块。
        // 这些换行是**装饰**：源码里那个换行已经由占位符（映射了整块源码）代表了，
        // 这里再映射一次会导致复制的时候多吐出一个空行。
        let breaks = trailingLineBreaks(of: sourceText)
        if breaks > 0 {
            fragment.append(.decoration(String(repeating: "\n", count: breaks),
                                        attributes: [.font: theme.bodyFont, .paragraphStyle: style]))
        }

        // 锚点打在占位符上（它就是这个块的第一个字符），UI 层据此画 ▶
        markFoldAnchor(on: &fragment, blockID: blockID, isCollapsed: true)
        return (fragment.text, fragment.mappings)
    }

    /// 源码结尾有几个连续的换行（最多数 2 个，再多也没必要留那么宽的空档）。
    ///
    /// markdown 里块与块之间通常是一个空行（`\n\n`），补回来视觉上才和展开时差不多。
    private func trailingLineBreaks(of text: String) -> Int {
        var count = 0
        for character in text.reversed() {
            if character == "\n" {
                count += 1
                if count >= 2 { break }
            } else if character == " " || character == "\t" {
                continue        // 行尾空格不算数
            } else {
                break
            }
        }
        return count
    }

    /// 第一个「不是换行 / 空格 / 制表符」的字符位置。
    ///
    /// 块源码开头偶尔会带着上一块留下的空行（`buildBlocks` 会让第一个块吃掉区域开头的空白），
    /// 按钮不能插到空行那一行去，否则屏幕上会出现一个孤零零的三角。
    private func firstNonWhitespaceIndex(in text: NSAttributedString) -> Int {
        let ns = text.string as NSString
        var index = 0
        while index < ns.length {
            let character = ns.character(at: index)
            if character == 0x0A || character == 0x0D || character == 0x20 || character == 0x09 {
                index += 1
            } else {
                break
            }
        }
        return index
    }

    // MARK: - 小工具

    /// 当前字体（栈顶）
    private var currentFont: UIFont { fontStack.last ?? theme.bodyFont }

    private func pushFont(_ font: UIFont) { fontStack.append(font) }
    private func popFont() { if fontStack.count > 1 { fontStack.removeLast() } }

    /// 当前正文属性（字体跟着嵌套层级走）
    private var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: currentFont, .foregroundColor: currentTextColor]
    }

    /// 把 AST 节点的源码范围换算成「块内偏移」
    private func localRange(of markup: Markup) -> NSRange? {
        guard let range = markup.range else { return nil }
        let converted = table.utf16Range(of: range)
        // 长度为 0 的范围没有意义（cmark 偶尔会给出退化范围），当没有处理
        return converted.length > 0 ? converted : nil
    }

    /// 取块内某段源码
    private func sourceText(in range: NSRange) -> String {
        source.substring(utf16Offset: range.location, length: range.length)
    }

    /// 列表项的标记范围：从列表项开头，到第一个子节点开头为止（`item.children` 不包含 `- ` 这几个字符）
    private func markerRange(of item: ListItem) -> NSRange? {
        guard let itemRange = localRange(of: item) else { return nil }
        // MarkupChildren 只是 Sequence，不是 Collection，没有 `.first` 属性，
        // 所以这里用迭代器取第一个子节点。
        var iterator = item.children.makeIterator()
        guard let firstChild = iterator.next(), let childRange = firstChild.range else { return nil }
        let firstChildStart = table.utf16Range(of: childRange).location
        let length = firstChildStart - itemRange.location
        guard length > 0, length < 12 else { return nil }   // 标记不该太长，防止算错时吃掉正文
        return NSRange(location: itemRange.location, length: length)
    }
}

// MARK: - Theme 补充

extension MarkdownTheme {
    /// 补漏字符（源码里没被任何 AST 节点覆盖的字符）的样式：弱化显示
    var orphanAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont,
         .foregroundColor: markerColor,
         .paragraphStyle: paragraphStyle(indent: 0)]
    }

    /// 列表项的悬挂缩进段落样式
    func listItemParagraphStyle(markerIndent: CGFloat, contentIndent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        // 第一行从标记位置开始（这样圆点能顶到外层缩进），换行后对齐到内容位置
        style.firstLineHeadIndent = markerIndent
        style.headIndent = contentIndent
        style.paragraphSpacing = 0
        return style
    }
}
