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

    /// 代码高亮器。给 nil 就不做高亮（代码块按纯文本显示）。
    ///
    /// ### 为什么挂在这里而不是 `MarkdownTextView` 上
    /// 高亮发生在「AST → 富文本」这一步，而这一步是**这里**做的；
    /// `MarkdownTextView` 只负责把渲染结果显示出来，它不需要知道高亮这件事的存在。
    /// 所以这里只认 `CodeHighlighting` 这个协议类型：将来换成 tree-sitter 那种
    /// 精确解析器，只要实现同一个协议塞进来就行，UI 层一行都不用改。
    var codeHighlighter: CodeHighlighting? = SimpleCodeHighlighter()

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
        var out = defaultVisit(emphasis)
        // 中文字体没有真斜体（见 `MarkdownTheme.cjkItalicSlant` 的注释），
        // 光靠字体特征汉字不会歪 —— 这里给斜体范围内的汉字换上带仿斜矩阵的字体
        applySyntheticItalicToCJK(&out)
        return out
    }

    /// 给一段渲染结果里的**中文字符**逐个换成「仿斜体」字体。
    ///
    /// ### 为什么只挑中文、不整段换
    /// 英文已经换了真斜体字体（`.SFNS-Italic` 这类），再叠仿斜矩阵会歪过头；
    /// 中文换不到斜体字形，才需要「手动掰歪」。
    ///
    /// ### 为什么用字体矩阵而不是 `.obliqueness` 属性（这里踩过坑，别改回去）
    /// `.obliqueness` 是 TextKit 1 时代的属性，**TextKit 2 排版时直接忽略它**
    /// （实测：属性挂在 textStorage 上，画出来却纹丝不动）。字体描述符里的
    /// 矩阵是烘进字体本身的，CoreText 画字形时一定生效。
    ///
    /// ### 为什么逐字符挑而不是判断整段
    /// `*包含`中文`和 English 混排*` 很常见，一段里经常两种都有。
    /// 连续的中文合并成一个区间再换字体，属性数量也不会爆炸。
    private func applySyntheticItalicToCJK(_ fragment: inout RenderedFragment) {
        let slant = theme.cjkItalicSlant
        guard slant != 0, fragment.text.length > 0 else { return }

        // 先扫出所有「连续中文」的区间（unicodeScalars 自带 UTF-16 偏移可累加，
        // emoji 这类代理对也不会算错位置）
        var slantRanges: [NSRange] = []
        var pending: NSRange?
        var offset = 0
        for scalar in fragment.text.string.unicodeScalars {
            let length = String(scalar).utf16.count
            if Self.isCJK(scalar) {
                if pending == nil {
                    pending = NSRange(location: offset, length: length)
                } else {
                    pending!.length += length
                }
            } else if let range = pending {
                slantRanges.append(range)
                pending = nil
            }
            offset += length
        }
        if let range = pending { slantRanges.append(range) }

        for range in slantRanges {
            guard let font = fragment.text.attribute(.font,
                                                     at: range.location,
                                                     effectiveRange: nil) as? UIFont else { continue }
            fragment.text.addAttribute(.font, value: font.withSlant(slant), range: range)
        }
    }

    /// 这个字符属不属于「没有斜体字形、需要合成倾斜」的东亚文字。
    ///
    /// 覆盖：CJK 统一表意（含扩展区）、日文假名、韩文谚文、全角标点 / 字母。
    /// 拉丁字母、数字、半角标点都不在内（它们有真斜体）。
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF,       // 谚文字母
             0x2E80...0x9FFF,       // CJK 部首、注音、假名、CJK 统一表意
             0xAC00...0xD7AF,       // 谚文音节
             0xF900...0xFAFF,       // CJK 兼容表意
             0xFE30...0xFE4F,       // CJK 兼容形式
             0xFF00...0xFFEF,       // 全角形式（，。！等全角标点也在这一段）
             0x20000...0x2FA1F:     // CJK 扩展 A~F
            return true
        default:
            return false
        }
    }

    func visitStrikethrough(_ strikethrough: Strikethrough) -> RenderedFragment {
        var out = defaultVisit(strikethrough)
        out.addAttributesIfAbsent([.strikethroughStyle: NSUnderlineStyle.single.rawValue])
        return out
    }

    func visitLink(_ link: Link) -> RenderedFragment {
        var out = defaultVisit(link)

        // ⚠️ 这里必须用 `setAttributes`（强制覆盖），不能用 `addAttributesIfAbsent`。
        //
        // `addAttributesIfAbsent` 的语义是「**已有属性优先**，新属性只填空」，
        // 而链接里的文字在 `visitText` 阶段就已经拿到 `bodyAttributes` 了
        // （里面含 `.foregroundColor: textColor`）。也就是说 `foregroundColor` 早就存在，
        // 用 addAttributesIfAbsent 的话 linkColor 会被正文色挤掉 ——
        // 表现就是「在 MarkdownTheme 里改 linkColor 一点反应都没有」。
        //
        // 有这个坑是因为 addAttributesIfAbsent 本来是给 Emphasis / Strong 这类嵌套语法用的
        // （外层不该把内层行内代码的等宽字体盖掉），链接套用同一套逻辑就不对了。
        out.setAttributes(theme.linkAttributes)

        // 能点开的 URL 顺便挂上 link 属性（这是新 key，add / set 都一样）
        if let destination = link.destination, let url = URL(string: destination) {
            out.setAttributes([.link: url])
        }
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

        // 这一行能排多宽（列表、引用块缩进之后剩下的）
        let availableWidth = max(60, containerWidth - indent - 16)
        // 图片最大宽度：按比例算，或者用固定点数 —— 两者互斥，见 `ImageStyle`
        let requestedWidth = theme.image.maxWidthRatio.map { availableWidth * $0 }
            ?? theme.image.maxWidthPoints
        // 再夹一层：不管用户设的是哪种，都不能超过当前这一行实际能放下的宽度
        let maxWidth = max(60, min(availableWidth, requestedWidth))

        // 最大高度是主题里写死的点数，跟窗口多高无关（见 `ImageStyle.maxHeight` 的注释）
        let maxHeight = max(60, theme.image.maxHeight)

        // 一行正文有多高。图片加载不出来时占位块要按它来收缩（最多 2 行）。
        // 行高倍数大于 1 时才乘，<= 1 表示「用字体自带的自然行高」，别改变排版。
        let lineHeight = theme.bodyFont.lineHeight * max(1, theme.lineHeightMultiple)
        let attachment = ImageAttachment(
            markdownSource: markdownSource,
            imageURL: url,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            lineHeight: lineHeight,
            placeholderColor: theme.markerColor
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
            // 「段落首行缩进」只给**普通正文段落**，两种情况排除掉：
            // 1. 列表项里的段落 —— 第一行是圆点/序号，缩了会顶歪（上面那个分支已经跳过）；
            // 2. 引用块里的段落 —— 整块已经往右内缩了一道，左边还有一条竖条，
            //    再缩首行会让文字越过竖条、看着像没对齐。
            //    `quoteChain` 在 `visitBlockQuote` 里进块**之前**就已经挂上了，
            //    所以这里读到非空就说明自己在引用里。
            let wantsFirstLineIndent = quoteChain.ids.isEmpty
            out.addAttributesIfAbsent([.paragraphStyle: theme.paragraphStyle(
                indent: indent,
                firstLineIndentExtra: wantsFirstLineIndent ? theme.paragraphIndent : 0
            )])
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
        // 引用正文的颜色由 `quoteTextColor` 单独控制（默认和正文同色）。
        // 注意行首的 `>` 不走这里 —— 它属于「没被子节点覆盖的源码字符」，
        // 由下面的补漏步骤用 `theme.markerAttributes` 上成灰色。
        currentTextColor = theme.quoteTextColor
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

        // 给代码正文上语法色。要**在 reconciled 之前**做：此刻 out 里只有代码正文，
        // token 的偏移可以直接当 out 内部的偏移用，不用再换算一次
        applySyntaxHighlighting(to: &out, code: code, language: codeBlock.language)

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

    /// 给一段代码正文上语法色（不动文字、不动映射，**只改颜色属性**）。
    ///
    /// ### 为什么可以只改颜色
    /// 显示的文字是源码本身（`sourceSliced`），映射一个字都没动，
    /// 所以「全选复制 === 源文件」这条不变式自动成立，不需要为高亮补任何逻辑。
    ///
    /// - parameter fragment: 只装着这段代码的片段（调用点在 reconciled 之前，满足这个前提）
    /// - parameter code:     代码正文（**不含**首尾围栏行）
    /// - parameter language: 围栏后面写的语言标识，没写就 nil
    private func applySyntaxHighlighting(to fragment: inout RenderedFragment,
                                         code: String,
                                         language: String?) {
        guard theme.enablesCodeHighlighting,
              let language,
              let highlighter = codeHighlighter,
              highlighter.supportsLanguage(language) else { return }

        let tokens = highlighter.highlight(code, language: language)
        guard !tokens.isEmpty else { return }

        // token 的坐标原点就是这段代码的首字符，和 fragment 内部坐标一致。
        // 夹一段范围是防御：万一高亮器越界，也不能让 addAttribute 直接崩掉整篇渲染
        let limit = NSRange(location: 0, length: min(fragment.text.length, code.utf16Length))
        for token in tokens {
            let range = NSIntersectionRange(token.range, limit)
            guard range.length > 0 else { continue }
            // 注意用 addAttributes 而不是 addAttributesIfAbsent —— 代码正文早就带上
            // 了默认前景色，这里是要**盖掉**它（详见 RenderedFragment 那两个函数的注释）
            fragment.text.addAttribute(.foregroundColor,
                                       value: theme.color(for: token.role),
                                       range: range)
        }
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
        var contentIndent = indent + theme.listIndent

        var out = RenderedFragment.empty

        // 1) 列表标记：`- ` / `* ` / `1. `
        if let markerRange = markerRange(of: item) {
            let markerText = sourceText(in: markerRange)
            if ordered {
                // 有序列表直接显示源码里的 `1. `，编辑时能直接改，也不需要额外维护映射
                out.append(.sourceSliced(markerText, sourceStart: markerRange.location, attributes: theme.listMarkerAttributes))
            } else if let literal = taskListLiteral(of: item, in: markerText, markerRange: markerRange) {
                // 任务项：**不画圆点** —— 排布是「浅灰 `-` → 复选框 → `[x]` → 正文」
                appendTaskListMarker(to: &out, markerText: markerText,
                                     markerRange: markerRange, literal: literal)
                // 悬挂缩进：任务项的标记区比普通列表项宽（多了一整个复选框和 `[x]`），换行后得跟首行的**正文**起点对齐，否则第二行会缩回标记底下
                contentIndent = markerIndent + max(theme.listIndent, taskListMarkerWidth)
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

    // MARK: 任务列表（`- [x] xxx`）

    /// 这一行是不是任务项；是的话把 `[x]` / `[ ]` 这三个字符也找出来。
    ///
    /// ⚠️ `item.checkbox` 只用来判定「这一行是不是任务项」（这个判定在语法树上是准的，`- 正文里有 [x]` 不会被误判成任务项）；勾没勾**不能**看它 —— 原因见下面 `checkboxLiteral` 的注释。
    private func taskListLiteral(of item: ListItem,
                                 in markerText: String,
                                 markerRange: NSRange) -> (range: NSRange, isChecked: Bool)? {
        guard item.checkbox != nil else { return nil }
        return checkboxLiteral(in: markerText, markerRange: markerRange)
    }

    /// 渲染任务项的列表标记：**不画圆点**，排成「浅灰 `-` → 复选框座位 → `[x]` → 正文」。
    ///
    /// ### 文本流里的三段分别是什么
    /// | 片段 | 源码对应 | 为什么要有它 |
    /// |---|---|---|
    /// | `- `（弱化灰） | 真实源码字符 | 用户要的「浅灰 `-`」，替换掉原来的圆点 |
    /// | 座位（透明 attachment） | **不**消耗源码位置 | 在文本流里给复选框腾出位置，按钮才不会压住两边的字 |
    /// | `[x] `（弱化灰） | 真实源码字符 | 用户要的「`[ ]` / `[x]` 都显示出来」 |
    ///
    /// ### 为什么按钮不直接盖在 `[x]` 上（老做法的问题）
    /// 老做法（`coversCheckboxLiteral = true`）拿按钮盖住那三个字符，源码就看不见了；换成「并列」把按钮画到字面量左边，它又会挤到 `- ` 头上（实测）。让渲染层**先留一块空位**，按钮才有地方安安静静地站着。
    ///
    /// ### 为什么不用 `NSTextAttachmentViewProvider` 把按钮直接放进文本流
    /// 本项目在图片上实测过它的坑：整篇替换内容后 TextKit 2 会把 attachment 的 view 摘掉、却**不再回调 `loadView()`**，view 就永久消失了。所以这里只留一个**空的座位**，真正的按钮仍由 UI 层叠上去（见 `MarkdownTextView.positionCheckboxes()`）。
    private func appendTaskListMarker(to out: inout RenderedFragment,
                                      markerText: String,
                                      markerRange: NSRange,
                                      literal: (range: NSRange, isChecked: Bool)) {
        let nsText = markerText as NSString
        let literalOffset = literal.range.location - markerRange.location

        // 1) `- ` 照常显示（弱化灰）—— 只是不再画圆点
        if theme.showsSourceHints {
            out.append(.sourceHint(nsText.substring(to: literalOffset),
                                   sourceStart: markerRange.location,
                                   isSyntaxMarker: true,
                                   attributes: theme.markerAttributes))
        }

        // 2) 复选框座位：文本流里凭空留出的一块位置（纯装饰，复制时跳过）
        //
        // ⚠️ `isSyntaxMarker: false` 是必须的，别「统一」成 true：座位左边 `- `、右边 `[ ] ` 各自是一段独立的语法标记，座位一旦也带上 `.markdownSyntaxMarker`，两段就会被连成**一段连续标记** —— 于是光标停在 `]` 右边按一次退格，扩展逻辑会一路跨过座位吃掉整段 `- [ ] `，源码从 `- [ ] 未完成的项` 直接变成 `未完成的项`（实测）。不带标记的座位同时充当两段标记之间的**边界**，见 `MarkdownDocumentStore.expandedSyntaxMarkerRange`。
        let seatIndex = out.text.length
        let seat = CheckboxSeatAttachment(side: theme.taskList.checkboxSide,
                                          gap: theme.taskList.checkboxGap,
                                          font: theme.bodyFont)
        out.append(.decorationAttachment(seat, isSyntaxMarker: false, attributes: theme.bodyAttributes(font: theme.bodyFont)))

        let info = CheckboxInfo(sourceStart: blockOrigin + literal.range.location,
                                isChecked: literal.isChecked)

        // 3) `[x] ` 照常显示（弱化灰），并在这三个字符上挂复选框信息
        if theme.showsSourceHints {
            let literalStart = out.text.length
            out.append(.sourceHint(nsText.substring(from: literalOffset),
                                   sourceStart: literal.range.location,
                                   isSyntaxMarker: true,
                                   attributes: theme.markerAttributes))
            let literalRange = NSRange(location: literalStart, length: literal.range.length)
            if NSMaxRange(literalRange) <= out.text.length {
                out.text.addAttribute(.markdownCheckbox, value: info, range: literalRange)
            }
        }

        // 座位也带同一个 info：UI 层靠它把按钮摆在座位正中
        if seatIndex < out.text.length {
            out.text.addAttribute(.markdownCheckboxSeat,
                                  value: info,
                                  range: NSRange(location: seatIndex, length: 1))
        }
    }

    /// 任务项首行标记区的宽度（`- ` + 座位 + `[x] `），拿它当悬挂缩进用。
    ///
    /// 换行之后正文要跟**首行的正文起点**对齐，而任务项的标记区比普通列表项宽不少（多了整个复选框和一个 `[x]`），沿用 `listIndent` 会让第二行缩回标记底下。字面量取三种写法里最宽的，这样勾前勾后整行宽度都不变。
    private var taskListMarkerWidth: CGFloat {
        let font = theme.bodyFont
        func width(_ string: String) -> CGFloat {
            (string as NSString).size(withAttributes: [.font: font]).width
        }
        let seat = theme.taskList.checkboxSide + theme.taskList.checkboxGap * 2
        let widestLiteral = ["[ ] ", "[x] ", "[X] "].map(width).max() ?? 0
        return width("- ") + seat + widestLiteral
    }

    /// 在列表标记文本（`- [x] ` / `1. [ ] `）里找出 `[x]` / `[ ]` 这三个字符，并**直接从这三个字符本身**读出勾选状态。
    ///
    /// 标记文本的前导部分可能是 `- `、`* `、`1. `、`10. ` 等各种长度，所以不能写死偏移量，要真的去找那个 `[`。
    ///
    /// ### 为什么勾选状态不能取 `item.checkbox`（踩过的坑，别改回去）
    /// cmark-gfm 判定任务项勾没勾，靠的是这一句（`extensions/tasklist.c`）：
    /// ```c
    /// parent_container->as.list.checked = (strstr((char *)input, "[x]") || strstr((char *)input, "[X]"));
    /// ```
    /// `input` 是**整行**，`strstr` 又在整行里搜 —— 所以只要这一行**别处**还出现一个 `[x]` / `[X]`，整项就被报成「已勾选」，哪怕真正的标记是 `[ ]`。实测：
    ///
    /// | 源码 | 语法树给的 | 真相 |
    /// |---|---|---|
    /// | `- [ ] 未完成的项` | unchecked | `[ ]` |
    /// | `- [ ] 未完成的项，点一下变 [x]` | **checked** | `[ ]` |
    /// | `- [ ] 第一行`⏎`  续行有 [x]` | unchecked | 只看第一行，续行不算 |
    ///
    /// 后果不只是「画错了」：复选框会顶着「已勾选」的绿底盖在 `[ ]` 上，点它时 `toggleCheckbox` 又按「已勾选」写回 `[ ]` —— 源码本来就是 `[ ]`，等于什么都没干。用户看到的就是**点了没反应**。
    ///
    /// 「这一行是不是任务项」那个判定语法树是准的（`- 正文里有 [x]` 不会被误判成任务项），所以保留；但**状态一律以源码里那三个字符为准** —— 这个编辑器的老规矩：源码才是唯一真相。
    private func checkboxLiteral(in markerText: String,
                                 markerRange: NSRange) -> (range: NSRange, isChecked: Bool)? {
        let nsText = markerText as NSString
        // 从左往右扫到第一个 `[`
        for offset in 0..<nsText.length {
            guard nsText.character(at: offset) == 0x5B /* [ */ else { continue }
            // 后面至少还得有「一个状态字符 + 一个 ]」
            guard offset + 2 < nsText.length,
                  nsText.character(at: offset + 2) == 0x5D /* ] */ else { return nil }
            // 中间那个字符：`x` / `X` 算勾上，其余（正常是空格）算没勾
            let state = nsText.character(at: offset + 1)
            let isChecked = state == 0x78 /* x */ || state == 0x58 /* X */
            return (NSRange(location: markerRange.location + offset, length: 3), isChecked)
        }
        return nil
    }

    // MARK: 折叠（按标题层级：三角挂在标题左边，点它收起/展开下面一整节）

    /// 给一个块的**第一个字符**打上「折叠锚点」标记。
    ///
    /// 只有标题块会打这个标记 —— 折叠是按标题层级来的，正文块自己不折叠。
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

    /// 折叠状态下的**标题块**长什么样：标题文字 + 一个「⋯」占位符。
    ///
    /// 和老版本「整块变成一个 ⋯」的区别：标题自己照常显示（用户看得见折叠了哪一节、
    /// 还能点进去改标题），被收起来的只有它**下面那一节**。
    ///
    /// ### 折叠了源码还在吗？在
    /// 折叠只是视图状态，源码一个字没动。占位符那一个字符位映射的是
    /// 「从标题文字结束处一直到整节结束」的全部源码（标题尾部的换行也算在里面），
    /// 所以复制时它一个字符就把整节吐出来 ——
    /// **「全选复制 === 源文件」在折叠状态下依然成立**（有测试守着）。
    ///
    /// - parameter headingSource:     标题自己的源码（尾部换行已去掉）
    /// - parameter hiddenSourceLength: 「⋯」要代表的源码长度（**块内**偏移从
    ///                                  `headingSource` 结尾开始算）
    /// - parameter trailingBreaks:     要在末尾补几个换行（保持节与节之间的空档）
    func collapsedHeadingContent(blockID: UUID,
                                 headingSource: String,
                                 blockOrigin: Int,
                                 hiddenSourceLength: Int,
                                 trailingBreaks: Int) -> (text: NSAttributedString, mappings: [CharMapping]) {
        let (headingText, headingMappings) = render(blockSource: headingSource, blockOrigin: blockOrigin)
        var fragment = RenderedFragment(text: NSMutableAttributedString(attributedString: headingText),
                                        mappings: headingMappings)

        let placeholder = CollapsedBlockAttachment(width: theme.collapsedPlaceholderWidth,
                                                   color: theme.collapsedPlaceholderColor,
                                                   font: theme.bodyFont)
        // 占位符从「标题文字结束处」开始吃源码，一直吃到整节结束。
        // 标成 attachmentView：光标不会停在这个字符上（免得用户一敲键就把整节删了），
        // 但复制时照样能吐出源码。
        fragment.append(.attachment(placeholder,
                                    sourceStart: headingSource.utf16Length,
                                    sourceLength: hiddenSourceLength,
                                    attributes: [.font: theme.bodyFont]))
        // 打标记：UI 层靠它认出「这个 ⋯ 点一下能展开」
        fragment.text.addAttribute(.markdownCollapsedPlaceholder,
                                   value: CollapsedSectionInfo(blockID: blockID),
                                   range: NSRange(location: fragment.text.length - 1, length: 1))

        // 把换行补回来 —— 不补的话下一节会直接贴在「⋯」后面。
        // 这些换行是**装饰**：源码里那几个换行已经由占位符代表了，
        // 这里再映射一次会导致复制的时候多吐出空行。
        if trailingBreaks > 0 {
            fragment.append(.decoration(String(repeating: "\n", count: trailingBreaks),
                                        attributes: [.font: theme.bodyFont]))
        }
        return (fragment.text, fragment.mappings)
    }

    /// 源码结尾有几个连续的换行（最多数 2 个，再多也没必要留那么宽的空档）。
    ///
    /// markdown 里块与块之间通常是一个空行（`\n\n`），补回来视觉上才和展开时差不多。
    func trailingLineBreakCount(of text: String) -> Int {
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

    /// 列表项的悬挂缩进段落样式。
    ///
    /// 段落间距和行高都跟着主题走（和正文用同一套）—— 设置页上那个「段落间距」
    /// 是全局的，列表项要是不跟，调完就会看到「正文松了、列表还是挤的」。
    /// 首行缩进则**不给**：列表项第一行是圆点或序号，再往里缩会顶歪。
    func listItemParagraphStyle(markerIndent: CGFloat, contentIndent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        // 第一行从标记位置开始（这样圆点能顶到外层缩进），换行后对齐到内容位置
        style.firstLineHeadIndent = markerIndent
        style.headIndent = contentIndent
        style.paragraphSpacing = paragraphSpacing
        applyLineHeight(to: style)
        return style
    }
}
