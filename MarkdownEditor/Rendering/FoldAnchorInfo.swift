//
//  FoldAnchorInfo.swift
//  MarkdownEditorHy4
//
//  顶层块「折叠锚点」：打在块第一个字符上的标记，UI 层靠它知道在哪画折叠三角
//

import UIKit

/// 一个可折叠块的锚点信息。
///
/// ### 为什么是「标记」而不是「插一个 attachment」
/// 早期版本是在块首插一个 `NSTextAttachment` 画三角，**它占一个字符位**，
/// 于是块的第一行被这个三角往右推，第二行、第三行却按原来的缩进排版 ——
/// 多行文字的左边缘就对不齐了（用户报的就是这个问题）。
///
/// 改成锚点标记之后：文本流里一个多余字符都没有，多行**天然左对齐**，
/// 三角由 UI 层画在正文左边的「装订线（gutter）」里，和代码块复制按钮同一套机制。
///
/// ### 三角的位置怎么算（TextKit 2 的坑）
/// `NSTextLayoutFragment.layoutFragmentFrame` 对 **viewport 之外**的 fragment 永远是
/// **估算值**（`state` 含 `.estimatedUsageBounds`），差几百像素，外部 API 拿不到真值。
/// 解决办法是不去硬算，而是**只画已经真实排版过的 fragment**：
/// 三角只在块首那一行滚进 viewport 之后才出现，此时 fragment 是真的，位置就准。
/// 滚动时 `contentOffset` KVO 会反复触发重画，所以滚到哪儿三角就跟到哪儿。
final class FoldAnchorInfo: NSObject {

    /// 这个锚点属于哪个顶层块（点三角时靠它反查要折叠哪一块）
    let blockID: UUID

    /// 当前是不是折叠状态：折叠画 ▶，展开画 ▼
    let isCollapsed: Bool

    init(blockID: UUID, isCollapsed: Bool) {
        self.blockID = blockID
        self.isCollapsed = isCollapsed
    }
}

extension NSAttributedString.Key {
    /// 标记「这个字符是一个可折叠块的第一个字符」，值类型是 `FoldAnchorInfo`。
    ///
    /// 和 `.markdownCodeBlock` 一样只是给 UI 层留的记号，不参与排版，
    /// 渲染成纯文本（比如复制出去）时会被自动忽略。
    static let markdownFoldAnchor = NSAttributedString.Key("com.markdowneditor.foldAnchor")
}
