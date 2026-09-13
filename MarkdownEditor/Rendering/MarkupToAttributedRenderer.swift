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

    /// 样式表。用 `var` 是因为运行时可能要单独调某一项（比如代码块围栏行是否铺背景），
    /// 换主题也不用重建 renderer
    var theme: MarkdownTheme
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
    /// 当前所处的引用嵌套链（每进一层 BlockQuote 追加一项，见 QuoteChain 的注释）
    private var quoteChain: QuoteChain = QuoteChain(ids: [])
    /// 本次渲染的块在整篇文档里的起始偏移（给引用链 ID 加盐，见 render 的注释）
    private var blockOrigin: Int = 0

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
    /// - parameter blockOrigin: 该块在**整篇文档**里的起始偏移。引用块拿它给自己的
    ///   嵌套链 ID 加盐 —— 不同块里的引用都可能从块内位置 0 开始，不加盐的话
    ///   两个块的 ID 会撞车，UI 层会把两条竖条错误地合并成一条
    /// - returns: 富文本 + 每个字符位的源码映射
    func render(blockSource: String, blockOrigin: Int = 0) -> (text: NSAttributedString, mappings: [CharMapping]) {
        beginBlock(source: blockSource)
        // 注意：等号右边是同名参数（遮蔽了属性），这里只能这样写；重置在 endBlock 里做
        self.blockOrigin = blockOrigin
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
        self.quoteChain = QuoteChain(ids: [])
    }

    private func endBlock() {
        source = ""
        table = SourceLocationTable(source: "")
        fontStack = []
        indent = 0
        isInsideListItem = false
        quoteChain = QuoteChain(ids: [])
        blockOrigin = 0
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

    /// 引用块。
    ///
    /// ### 竖条怎么画（参考 doc/引用渲染方案.md 的思路）
    /// 竖条**不在文本流里**（旧版每行插一个 QuoteBarAttachment，段距处会断成虚线、
    /// 嵌套时两条挤在一起），改为渲染时只打 `.markdownQuoteChain` 标记、
    /// UI 层按链在 overlay 层画**连续竖条**：每层一条，外层贯穿整块（含内层占据的行），
    /// 内层只覆盖内层自己的行，x 坐标随嵌套深度往右错开 —— 详见
    /// `MarkdownTextView.computeQuoteBarFrames()`。
    ///
    /// ### 本方法只负责三件事
    /// 1. 把自己压进嵌套链（ID = 自己在块源码里的起始位置，重渲染也稳定）；
    /// 2. 让子内容（加粗、列表、代码块、表格……）走各自已有的 visit，正常渲染；
    /// 3. 补漏后给整块区间打上链标记 —— 用 add-if-absent，内层区间已有的
    ///    更长链（`[外层ID, 内层ID]`）不会被外层的短链覆盖。
    func visitBlockQuote(_ blockQuote: BlockQuote) -> RenderedFragment {
        let savedIndent = indent
        let savedColor = currentTextColor
        let savedChain = quoteChain
        let contentIndent = savedIndent + theme.quoteIndent

        indent = contentIndent
        currentTextColor = theme.quoteColor
        let quoteStyle = theme.paragraphStyle(indent: contentIndent)

        // 自己的 ID：块内起始位置 + 块在文档里的起始偏移。
        // 块区间两两不相交，所以不同块的 (origin + 块内位置) 不会撞车；
        // 同一块每次重渲染结果一致，UI 层的「矩形稳定才收手」循环靠它判断前后两轮是不是同一批竖条
        let ownID = blockOrigin &+ (localRange(of: blockQuote)?.location ?? savedChain.ids.count)
        // 先把「打了自己 ID 的新链」存下来 —— 下面恢复现场后还要用它打标记，
        // 直接读 quoteChain 的话拿到的是已经恢复的父链（踩过这个坑，外层竖条会整个消失）
        let newChain = QuoteChain(ids: savedChain.ids + [ownID])
        quoteChain = newChain

        var out = defaultVisit(blockQuote)

        currentTextColor = savedColor
        indent = savedIndent
        quoteChain = savedChain

        // 把 `>` 这些没被子节点覆盖的源码字符补进来，
        // 并且给它们和引用正文一样的段落样式，否则行首的 `>` 会把整段的缩进带跑偏
        var orphanAttributes = theme.markerAttributes
        orphanAttributes[.paragraphStyle] = quoteStyle
        out = out.reconciled(withSource: source,
                             in: localRange(of: blockQuote),
                             orphanAttributes: orphanAttributes)
        out.addAttributesIfAbsent([.paragraphStyle: quoteStyle])

        // 给整块打上嵌套链标记（含补漏进来的 `>` 和空行）。
        // add-if-absent：内层引用的区间已经带了自己的长链，不会被这里的短链覆盖 ——
        // 这样 UI 层才能算出「外层竖条贯穿整块、内层竖条只到内层结束」两种范围。
        out.addAttributesIfAbsent([.markdownQuoteChain: newChain])

        return out
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

        // 打上「这是一个代码块」的标记（**含**首尾的 ``` 行，这样首尾围栏也在同一段里，
        // UI 层算矩形时能精确认出哪两行是围栏、把它们从背景里抠掉——背景只罩代码正文）。
        // UI 层靠它算出矩形位置、画出背景并放复制按钮，详见 CodeBlockInfo 的注释。
        out.setAttributes([.markdownCodeBlock: CodeBlockInfo(code: code, language: codeBlock.language)])
        return out
    }

    // MARK: 表格

    /// 表格：上方画一张自绘表格图，下方保留**弱化显示**的源码文字（`| a | b |` 那几行）。
    ///
    /// ### 结构和 `visitImage` 是镜像的
    /// - 表格图是一个 attachment，**额外挂上去的**（`isAttachmentView`），只占 1 个字符位；
    /// - 下面的源码是**源码本身**（真实映射，浅灰只是样式），光标能停进去改；
    /// - 两者映射同一段源码，复制时靠 `lastSourceEnd` 去重，整段只输出一次。
    ///
    /// 所以「全选复制 === 源文件」不需要为表格新增任何逻辑。
    func visitTable(_ table: Table) -> RenderedFragment {
        guard let range = localRange(of: table) else {
            // 拿不到范围（手工构造的 AST）：退化成按普通块渲染，源码由补漏步骤兜底
            return defaultVisit(table)
        }

        let markdownSource = sourceText(in: range)
        let data = MarkdownTableData(table)
        let maxWidth = max(120, containerWidth - indent - 16)
        let attachment = MarkdownTableAttachment(markdownSource: markdownSource,
                                                 data: data,
                                                 theme: theme,
                                                 maxWidth: maxWidth)

        let style = theme.blockAttachmentParagraphStyle(indent: indent)
        var out = RenderedFragment.empty
        out.append(.attachment(attachment,
                               sourceStart: range.location,
                               sourceLength: range.length,
                               attributes: [.paragraphStyle: style, .font: theme.bodyFont]))
        // 表格下面弱化显示源码：等宽 + 浅灰，方便对照真实语法改内容。
        // 段落样式不能省：源码有好几行，没有它的话缩进（列表里的表格）和行距都不对
        var sourceAttributes = theme.tableSourceAttributes
        sourceAttributes[.paragraphStyle] = theme.paragraphStyle(indent: indent)
        out.append(.decoration("\n", attributes: sourceAttributes))
        out.append(.sourceHint(markdownSource,
                               sourceStart: range.location,
                               attributes: sourceAttributes))
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
                    let hintStart = out.text.length
                    out.append(.sourceHint(markerText,
                                           sourceStart: markerRange.location,
                                           isSyntaxMarker: true,
                                           attributes: theme.markerAttributes))
                    markCheckboxLiteral(in: &out,
                                        hintStart: hintStart,
                                        markerText: markerText,
                                        markerRange: markerRange,
                                        item: item)
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

    // MARK: 任务列表（`- [x] xxx`）

    /// 给列表标记里的 `[x]` / `[ ]` 这三个字符打上 `.markdownCheckbox` 标记。
    ///
    /// ### 为什么只在源码提示文字上打标记
    /// 这三个字符就是源码本身，本来就被 `sourceHint` 显示着（弱化灰色）。
    /// 在它上面挂一个自定义属性，**一个字符都不用增删** ——
    /// 「全选复制 === 源文件」这条不变量天然不受影响，UI 层扫到标记就在旁边放按钮。
    ///
    /// ### 为什么不用 `NSTextAttachmentViewProvider`（和 doc/任务列表渲染方案.md 的差异）
    /// 方案建议用 view provider 挂真正的 view，但本项目在图片上实测过它的坑：
    /// 整篇替换内容后 TextKit 2 会把 attachment 的 view 摘掉、却**不再回调 `loadView()`**，
    /// view 就永久消失了。所以复选框走的是和折叠三角同一条路 —— 文本流里只留标记，
    /// 真正的按钮由 UI 层按字符矩形**叠**上去（见 `MarkdownTextView.positionCheckboxes()`）。
    private func markCheckboxLiteral(in out: inout RenderedFragment,
                                     hintStart: Int,
                                     markerText: String,
                                     markerRange: NSRange,
                                     item: ListItem) {
        guard let checkbox = item.checkbox,
              let literal = checkboxLiteralRange(in: markerText, markerRange: markerRange) else { return }

        let info = CheckboxInfo(sourceStart: blockOrigin + literal.location,
                                isChecked: checkbox == .checked)
        // hint 的第 0 个字符对应 markerRange.location，所以块内偏移直接平移过去就行
        let offsetInHint = literal.location - markerRange.location
        let range = NSRange(location: hintStart + offsetInHint, length: literal.length)
        guard NSMaxRange(range) <= out.text.length else { return }
        out.text.addAttribute(.markdownCheckbox, value: info, range: range)
    }

    /// 在列表标记文本（`- [x] ` / `1. [ ] `）里找出 `[x]` / `[ ]` 这三个字符的源码范围。
    ///
    /// 标记文本的前导部分可能是 `- `、`* `、`1. `、`10. ` 等各种长度，
    /// 所以不能写死偏移量，要真的去找那个 `[`。
    private func checkboxLiteralRange(in markerText: String, markerRange: NSRange) -> NSRange? {
        let nsText = markerText as NSString
        // 从左往右扫到第一个 `[`
        for offset in 0..<nsText.length {
            guard nsText.character(at: offset) == 0x5B /* [ */ else { continue }
            // 后面至少还得有「一个状态字符 + 一个 ]」
            guard offset + 2 < nsText.length,
                  nsText.character(at: offset + 2) == 0x5D /* ] */ else { return nil }
            return NSRange(location: markerRange.location + offset, length: 3)
        }
        return nil
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
