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
final class MarkdownTableAttachment: NSTextAttachment {
    /// 对应的整段表格源码（`| a | b |\n|---|---|\n| 1 | 2 |`）
    let markdownSource: String
    /// 表格内容
    let data: MarkdownTableData

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释
    nonisolated deinit {}

    init(markdownSource: String,
         data: MarkdownTableData,
         theme: MarkdownTheme,
         maxWidth: CGFloat) {
        self.markdownSource = markdownSource
        self.data = data
        super.init(data: nil, ofType: nil)

        // `availableWidth` 只是「最多能用多宽」，表格按内容算出来可能比它窄得多
        // （列宽受 `TableStyle.min/maxColumnWidth` 限制，不再撑满容器）。
        // 所以 bounds 用**画出来的图片**的尺寸，而不是拿容器宽度当表格宽度
        let availableWidth = max(120, maxWidth)
        image = MarkdownTableView.image(data: data,
                                        style: theme.table,
                                        bodyFont: theme.bodyFont,
                                        textColor: theme.textColor,
                                        availableWidth: availableWidth)
        let size = image?.size ?? .zero
        bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
    }

    required init?(coder: NSCoder) {
        fatalError("MarkdownTableAttachment 不支持从 coder 解档")
    }
}
