//
//  MarkdownDocumentStore+Outline.swift
//  MarkdownEditorHy4
//
//  文档模型 → 大纲条目的提取（放在 Outline 模块里，模型文件本身不出现「大纲」概念）
//

import Foundation

extension MarkdownDocumentStore {

    /// 当前文档的完整标题列表，按文档顺序排列（`sourceOffset` 递增）。
    ///
    /// ### 提取规则
    /// 只挑 `headingLevel != nil` 的块 —— 也就是 AST 里的 `Heading` 节点，
    /// 覆盖 `#` 到 `######` 全部六级。
    ///
    /// ### 产出为什么天然满足「`sourceOffset` 递增」
    /// `blocks` 本身就是文档顺序，而 `sourceRange.location` 是块在整篇源码里的起点，
    /// 块与块的源码首尾相接，所以按 `blocks` 顺序遍历出来的偏移一定单调递增。
    /// `OutlineCoordinator` 的二分查找依赖这个性质，改动本方法时别破坏它。
    var outlineItems: [OutlineItem] {
        blocks.compactMap { block in
            guard let level = block.headingLevel else { return nil }
            // `plainText` 一般不会带首尾空白，但空标题（源码里只有 `##`）会得到空串，
            // 空标题在目录里显示成一行空白会很怪，给个占位
            let title = (block.headingTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return OutlineItem(id: block.id,
                               // 防御一下：AST 理论上只给 1...6，越界了也按 1...6 夹住，
                               // 免得 UI 层算缩进时算出个负数或者超出屏幕
                               level: min(max(level, 1), 6),
                               title: title.isEmpty ? "（空标题）" : title,
                               sourceOffset: block.sourceRange.location)
        }
    }
}
