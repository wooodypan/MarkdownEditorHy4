//
//  CollapsedSectionInfo.swift
//  MarkdownEditorHy4
//
//  折叠标题后面那个「⋯」占位符的标记：UI 层靠它认出「点这里能展开这一节」
//

import UIKit

/// 一个「⋯」占位符的身份信息。
///
/// ### 它和折叠三角（`.markdownFoldAnchor`）的分工
/// - 三角：画在标题左边的装订线里，负责**收起**；
/// - 「⋯」：折叠之后出现在标题文字后面，负责**展开**。
/// 两者都只是「给 UI 层看的记号」，不参与排版，也不占额外的字符位
/// （「⋯」本身就是一个 attachment，占 1 个字符位）。
final class CollapsedSectionInfo: NSObject {

    /// 这个占位符属于哪个标题块（点它时靠它反查要展开哪一节）
    let blockID: UUID

    init(blockID: UUID) {
        self.blockID = blockID
    }

    /// ### 为什么这里要显式写 `nonisolated deinit`
    /// 和 `FoldAnchorInfo` 同一个坑（详细堆栈见 `MarkdownBlock` 的注释）：
    /// 本类实例挂在 `NSAttributedString` 的属性上，随富文本一起销毁 —— 而富文本
    /// 什么时候销毁完全不受我们控制，隔离 deinit 会踩 Swift 6.2 运行时的野指针 free。
    /// 本类只有一个值类型字段，声明成 `nonisolated` 完全安全。
    nonisolated deinit {}
}

extension NSAttributedString.Key {
    /// 标记「这个字符是一个被折叠章节的「⋯」占位符」，值类型是 `CollapsedSectionInfo`。
    ///
    /// 渲染成纯文本（比如复制出去）时会被自动忽略。
    static let markdownCollapsedPlaceholder =
        NSAttributedString.Key("com.markdowneditor.collapsedPlaceholder")
}
