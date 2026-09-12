//
//  QuoteChain.swift
//  MarkdownEditorHy4
//
//  引用块的「嵌套链」标记：渲染层打标、UI 层按链画竖条
//

import UIKit

/// 引用块字符上挂的「嵌套链」，值类型是 `[Int]`（每一层 BlockQuote 一个 ID，从外到内排列）。
///
/// ### 为什么要数组而不是单个深度数字
/// 嵌套引用要求**每层竖条独立计算覆盖范围**：外层竖条要贯穿整个引用块
/// （包括内层引用占据的行），内层竖条只覆盖内层自己那几行。
/// 只存深度的话，UI 层没法区分「同一深度、不同位置」的两条竖条。
///
/// ### ID 用节点源码起始位置，不用 UUID
/// 同一块源码每次重渲染，同一个引用块算出的 ID 相同 —— 增量渲染时竖条矩形
/// 对比稳定（渲染器的「结果稳定才收手」循环靠前后两轮比对判断排版是否结束，
/// ID 每轮都变的话永远收不了手）。UUID 做不到这点。
///
/// ### 叠加规则（和 `.paragraphStyle` 一致）
/// 内层引用先渲染、先打上 `[外层ID, 内层ID]`；外层收尾时用 add-if-absent 补
/// `[外层ID]`，已有链的内层区间保持不动。所以一个字符上拿到的链一定是
/// 「包含它的所有引用层，从外到内」。
struct QuoteChain: Equatable {
    /// 从外到内排列的每层引用 ID（值 = 该层 BlockQuote 节点在块源码里的 UTF-16 起始位置）
    let ids: [Int]

    /// 第 level 层竖条应该画的 x 偏移：第 0 层在最左边，每深一层往右挪一个缩进单位
    func levelIndex(of id: Int) -> Int? { ids.firstIndex(of: id) }
}

extension NSAttributedString.Key {
    /// 标记「这段字符处在哪些引用层里」，值类型是 `QuoteChain`。
    ///
    /// 和 `.markdownCodeBlock` 一样只是给 UI 层留的记号，不参与排版，
    /// 渲染成纯文本（比如复制出去）时会被自动忽略。
    static let markdownQuoteChain = NSAttributedString.Key("com.markdowneditor.quoteChain")
}
