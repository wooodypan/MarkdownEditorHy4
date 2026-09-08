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
    /// 是否显示「源码提示」：图片下面那行 `![alt](url)`、圆点后面的 `- `
    var showsSourceHints: Bool = true

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
            codeBlockTextInset: 10
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

// MARK: - UIFont 的字形变体（粗体 / 斜体）

extension UIFont {
    /// 在现有字体基础上叠加一个字形特征（粗体、斜体…），并保留原有特征。
    /// - parameter trait: 要叠加的特征，比如 `.traitBold`、`.traitItalic`
    func adding(_ trait: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let merged = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(trait))
        return UIFont(descriptor: merged ?? fontDescriptor, size: pointSize)
    }
}
