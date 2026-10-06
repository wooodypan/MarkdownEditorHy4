//
//  MarkdownTableAttachment.swift
//  MarkdownEditorHy4
//
//  表格 attachment：在文本流里占 1 个字符位，显示的是一张画好的表格图
//

import UIKit

/// 一个 markdown 表格。
///
/// 和图片完全同构：**在文本流里只占 1 个字符位**（`NSAttachmentCharacter`），
/// 背后记着整段表格源码，复制时由文档模型的映射表还原出来。
/// 真正的源码字符由紧跟其后的几行弱化源码承载，光标能停进去正常编辑。
///
/// ### 显示的是图片而不是 view
/// 见 `MarkdownTableView` 的注释：TextKit 2 的 view provider 在整篇替换后会漏掉
/// `loadView()`，这里统一画成 `UIImage` 交给 TextKit 自己绘制。
///
/// ### 唯一的例外：列太多装不下
/// 每列都保持最小宽度还是超出容器时（判据见 `MarkdownTablePresentation`），文本流里只留一张**透明占位图**占住位置，真正的表格由 `MarkdownTableScrollView` 浮在上面横向滚动（`needsHorizontalScroll` 为真）。
final class MarkdownTableAttachment: NSTextAttachment {
    /// 对应的整段表格源码（`| a | b |\n|---|---|\n| 1 | 2 |`）
    let markdownSource: String
    /// 表格内容
    let data: MarkdownTableData
    /// 表格怎么呈现：画多宽、露多宽、要不要横向滚动
    let presentation: MarkdownTablePresentation
    /// 绘制参数（浮层滚动视图要照着同一份样式重画一遍）
    let style: MarkdownTheme.TableStyle
    /// 单元格字体（同上）
    let bodyFont: UIFont
    /// 文字颜色（同上）
    let textColor: UIColor

    /// 列多到「每列最小宽度」都塞不进容器 → 交给浮层横向滚动
    var needsHorizontalScroll: Bool { presentation.isScrollable }

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释
    nonisolated deinit {}

    init(markdownSource: String,
         data: MarkdownTableData,
         theme: MarkdownTheme,
         maxWidth: CGFloat) {
        self.markdownSource = markdownSource
        self.data = data
        self.style = theme.table
        self.bodyFont = theme.bodyFont
        self.textColor = theme.textColor
        // `availableWidth` 只是「最多能用多宽」，表格按内容算出来可能比它窄得多
        // （列宽受 `TableStyle.min/maxColumnWidth` 限制，不再撑满容器）
        self.presentation = MarkdownTableView.presentation(data: data,
                                                          style: theme.table,
                                                          bodyFont: theme.bodyFont,
                                                          availableWidth: max(120, maxWidth))
        super.init(data: nil, ofType: nil)

        let height = presentation.layout.totalHeight
        if presentation.isScrollable {
            // 横向滚动：文本流里只占位，表格由浮层画 —— 底下留透明而不是留「最左边那一块」，否则浮层和它差一两个点就能看出重影（理由见 transparentPlaceholder 的注释）
            image = MarkdownTableView.transparentPlaceholder(width: presentation.visibleWidth,
                                                             height: height)
            bounds = CGRect(x: 0, y: 0, width: presentation.visibleWidth, height: height)
        } else {
            // 装得下：整张画成图片，bounds 用**画出来的图片**的尺寸，而不是拿容器宽度当表格宽度
            image = MarkdownTableView.image(data: data,
                                            style: theme.table,
                                            bodyFont: theme.bodyFont,
                                            textColor: theme.textColor,
                                            layout: presentation.layout)
            let size = image?.size ?? .zero
            bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("MarkdownTableAttachment 不支持从 coder 解档")
    }
}
