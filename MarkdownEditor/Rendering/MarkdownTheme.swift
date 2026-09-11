//
//  MarkdownTheme.swift
//  MarkdownEditorHy4
//
//  样式表：所有渲染样式的唯一出处
//

import UIKit

/// 编辑器的样式表。
///
/// 改外观只需要动这里，渲染层不写死任何颜色 / 字号。
struct MarkdownTheme {
    // MARK: 字体

    /// 正文字体
    var bodyFont: UIFont
    /// 等宽字体（行内代码、代码块）
    var codeFont: UIFont
    /// 各级标题字体，key 是标题级别（1~6）
    var headingFonts: [Int: UIFont]

    // MARK: 颜色

    var textColor: UIColor
    /// 语法标记（`#`、`**`、`-`、`>` 这些）的弱化色
    var markerColor: UIColor
    var linkColor: UIColor
    var inlineCodeColor: UIColor
    var inlineCodeBackground: UIColor
    var codeBlockBackground: UIColor
    var quoteColor: UIColor
    var bulletColor: UIColor
    var separatorColor: UIColor

    // MARK: 尺寸

    /// 圆点直径
    var bulletDiameter: CGFloat
    /// 每一级列表的缩进
    var listIndent: CGFloat
    /// 引用块的缩进
    var quoteIndent: CGFloat
    /// 段落之间的间距
    var paragraphSpacing: CGFloat
    /// 标题上方的额外间距
    var headingSpacing: CGFloat
    /// 图片最大高度（防止一张长图撑爆屏幕）
    var imageMaxHeight: CGFloat
    /// 代码块矩形背景的圆角
    var codeBlockCornerRadius: CGFloat
    /// 代码块矩形比文字上下各多出来的留白
    var codeBlockVerticalPadding: CGFloat
    /// 代码文字相对矩形左边的缩进
    var codeBlockTextInset: CGFloat
    /// 引用块左侧绿条的颜色
    var quoteBarColor: UIColor
    /// 引用块左侧绿条的宽度（相当于 CSS 里的 border-left-width）
    var quoteBarWidth: CGFloat
    /// 折叠按钮（小三角）的边长，同时也是点击热区大小
    var foldButtonSide: CGFloat
    /// 折叠按钮和正文之间的间距
    var foldButtonGap: CGFloat
    /// 正文左边专门留给折叠三角的「装订线」宽度。
    ///
    /// 三角浮在这条带子里，不占正文的字符位，多行文字的左边缘才对得齐。
    /// 这个值会额外加到 `UITextView.textContainerInset.left` 上。
    var foldGutterWidth: CGFloat
    /// 折叠后占位符「⋯」的宽度
    var collapsedPlaceholderWidth: CGFloat
    /// 折叠后占位符「⋯」的颜色
    var collapsedPlaceholderColor: UIColor
    /// 是否显示「源码提示」：图片下面那行 `![alt](url)`、圆点后面的 `- `
    var showsSourceHints: Bool = true
    /// 代码块的 **``` 围栏行**（第一行 ```lang 和最后一行 ```）要不要跟着正文一起铺淡灰背景。
    ///
    /// - `false`（默认）：只有代码正文有背景，围栏行留白，看起来是「一段被高亮的代码」；
    /// - `true`：首尾围栏也罩进背景，整块糊成一个灰方块。
    ///
    /// 想切换效果只改这一个值即可，详见 `MarkdownTextView.computeCodeBlockFrames`。
    var showsCodeBlockFenceBackground: Bool = false

    /// 表格的样式（表头底色、边框、单元格内边距…）
    ///
    /// ### 为什么叫 `TableStyle` 而不是 `Table`
    /// `Markdown` 模块里已经有一个 `Table`（swift-markdown 的表格 AST 节点），
    /// 同名会让代码里到处要写 `Markdown.Table`，容易看错。
    var table = TableStyle()

    // MARK: 默认样式

    static var `default`: MarkdownTheme {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let code = UIFont.monospacedSystemFont(ofSize: body.pointSize - 1, weight: .regular)

        return MarkdownTheme(
            bodyFont: body,
            codeFont: code,
            headingFonts: Self.makeHeadingFonts(base: body),
            textColor: .label,
            markerColor: .tertiaryLabel,
            linkColor: .systemBlue,
            inlineCodeColor: .systemPink,
            inlineCodeBackground: UIColor.systemPink.withAlphaComponent(0.10),
            codeBlockBackground: UIColor.secondarySystemBackground,
            quoteColor: .secondaryLabel,
            bulletColor: .label,
            separatorColor: .separator,
            bulletDiameter: 5,
            listIndent: 22,
            quoteIndent: 16,
            paragraphSpacing: 6,
            headingSpacing: 14,
            imageMaxHeight: 420,
            codeBlockCornerRadius: 8,
            codeBlockVerticalPadding: 6,
            codeBlockTextInset: 10,
            quoteBarColor: UIColor(red: 0.27, green: 0.68, blue: 0.49, alpha: 1.00),
            quoteBarWidth: 3,
            foldButtonSide: 20,
            foldButtonGap: 2,
            foldGutterWidth: 22,
            collapsedPlaceholderWidth: 20,
            collapsedPlaceholderColor: .tertiaryLabel
        )
    }

    /// 生成 1~6 级标题字体：级别越高字越大，统一加粗
    private static func makeHeadingFonts(base: UIFont) -> [Int: UIFont] {
        let baseSize = base.pointSize
        // 依次是 H1 ~ H6 的字号增量
        let deltas: [CGFloat] = [10, 6, 3, 1, 0, -1]
        var result: [Int: UIFont] = [:]
        for (index, delta) in deltas.enumerated() {
            let level = index + 1
            result[level] = UIFont.boldSystemFont(ofSize: baseSize + delta)
        }
        return result
    }

    // MARK: 派生的属性字典

    /// 正文属性（不含段落样式，段落样式由块级节点统一设置）
    func bodyAttributes(font: UIFont? = nil, color: UIColor? = nil) -> [NSAttributedString.Key: Any] {
        [.font: font ?? bodyFont, .foregroundColor: color ?? textColor]
    }

    /// 语法标记的弱化属性
    var markerAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: markerColor]
    }

    /// 行内代码
    var inlineCodeAttributes: [NSAttributedString.Key: Any] {
        [.font: codeFont,
         .foregroundColor: inlineCodeColor,
         .backgroundColor: inlineCodeBackground]
    }

    /// 代码块正文。
    ///
    /// 注意这里**没有** backgroundColor —— 整块的背景是由 `MarkdownTextView` 画的一个
    /// 圆角矩形（`codeBlockBackground`），逐字符加背景会变成一条条的色带，块与块之间还断开。
    var codeBlockAttributes: [NSAttributedString.Key: Any] {
        [.font: codeFont,
         .foregroundColor: textColor]
    }

    /// 链接正文
    var linkAttributes: [NSAttributedString.Key: Any] {
        [.foregroundColor: linkColor]
    }

    /// 列表标记（有序列表的 `1.` 这类）
    var listMarkerAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: markerColor]
    }

    /// 表格下方那几行**表格源码**的样式：等宽字体 + 浅灰。
    ///
    /// 表格本体已经画成一张图了，源码留在这里只是为了「所见即所编辑」
    /// （光标能停进去改），所以颜色压到很淡，不抢视觉焦点。
    var tableSourceAttributes: [NSAttributedString.Key: Any] {
        [.font: codeFont, .foregroundColor: table.sourceTextColor]
    }

    // MARK: 段落样式

    /// 普通段落
    func paragraphStyle(indent: CGFloat, extraSpacingBefore: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        style.paragraphSpacingBefore = extraSpacingBefore
        style.paragraphSpacing = paragraphSpacing
        return style
    }

    /// 标题段落
    func headingParagraphStyle(indent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        style.paragraphSpacingBefore = headingSpacing
        style.paragraphSpacing = paragraphSpacing
        return style
    }

    /// 代码块段落：文字相对背景矩形往里缩一点，右边也留出对称的间距
    func codeParagraphStyle(indent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = indent + codeBlockTextInset
        style.firstLineHeadIndent = indent + codeBlockTextInset
        style.tailIndent = -codeBlockTextInset
        style.paragraphSpacingBefore = paragraphSpacing
        style.paragraphSpacing = paragraphSpacing
        return style
    }

    /// 图片 / 分隔线独占一行的段落样式
    func blockAttachmentParagraphStyle(indent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        style.paragraphSpacingBefore = paragraphSpacing
        style.paragraphSpacing = paragraphSpacing + 4
        return style
    }
}

// MARK: - 表格样式

extension MarkdownTheme {
    /// 表格的绘制参数。
    ///
    /// 表格是**自绘成一张图片**再当 attachment 塞进文本流的（原因见 `MarkdownTableView`），
    /// 所以颜色、边距这些只能在绘制时读，套不到 UIKit 的 view 层级上去。
    struct TableStyle {
        /// 表头行的底色
        var headerBackground: UIColor = .secondarySystemBackground
        /// 表格线和外框的颜色
        var borderColor: UIColor = .separator
        /// 表格线宽度（1 就是一条细线）
        var borderWidth: CGFloat = 1
        /// 单元格文字到左右边框的距离
        var cellPaddingHorizontal: CGFloat = 12
        /// 单元格文字到上下边框的距离
        var cellPaddingVertical: CGFloat = 8
        /// 一列最窄多少（内容再短也不再压缩）
        var minColumnWidth: CGFloat = 64
        /// 一列最宽多少（防止某一列内容特别长，把别的列挤没了）
        var maxColumnWidth: CGFloat = 280
        /// 表格外框圆角
        var cornerRadius: CGFloat = 8
        /// 表格源码文字的颜色（浅灰）
        var sourceTextColor: UIColor = .tertiaryLabel
    }
}

// MARK: - UIFont 的字形变体（粗体 / 斜体）

extension UIFont {
    /// 在现有字体基础上叠加一个字形特征（粗体、斜体…），并保留原有特征。
    /// - parameter trait: 要叠加的特征，比如 `.traitBold`、`.traitItalic`
    func adding(_ trait: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let merged = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(trait))
        return UIFont(descriptor: merged ?? fontDescriptor, size: pointSize)
    }
}
