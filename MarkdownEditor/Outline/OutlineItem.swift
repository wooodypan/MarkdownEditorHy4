//
//  OutlineItem.swift
//  MarkdownEditorHy4
//
//  大纲条目：编辑器和目录 UI 之间传递的唯一数据结构
//

import Foundation

/// 大纲里的一个条目。
///
/// ### 这个类型刻意「什么都不懂」
/// 它不含 `NSRange` 以外的任何编辑/渲染概念，不含 `NSAttributedString`、
/// 不含 TextKit 的类型、不含 swift-markdown 的类型，只有「目录 UI 渲染一行需要的最小信息」。
///
/// 目录 UI 只认识这个结构，所以：
/// - 想换一套目录外观（侧边栏、底部抽屉、SwiftUI 列表）→ 只写新的 UI，编辑器和协调者一行不改；
/// - 想让编辑器换个渲染引擎 → 只要还能产出 `OutlineItem`，目录 UI 一行不改。
struct OutlineItem: Identifiable, Equatable {

    /// 稳定且唯一的标识。
    ///
    /// 直接复用编辑器里 `MarkdownBlock.id`（一个 UUID），这样「同一行 = 同一个块」
    /// 天然成立，UI 层拿它就能做高亮定位，不需要额外维护一套 id 映射。
    ///
    /// 注意：块在编辑后会被**重新创建**（`buildBlocks` 生成新实例），id 也会变。
    /// 所以「打字时高亮不能闪掉」这件事由 `OutlineCoordinator` 负责兜底，见那边的注释。
    let id: UUID

    /// 标题级别：1...6，对应源码里的 `#` 到 `######`
    let level: Int

    /// 标题的纯文本内容。已经去掉 `#`、`**`、`*` 这些语法符号，只留用户看得懂的字
    let title: String

    /// 该标题在**整篇源码**里的起始偏移（UTF-16 单元数）。
    ///
    /// ### 为什么是 Int 而不是 String.Index
    /// 整套编辑器（`MarkdownBlock.sourceRange`、`CharMapping`、`NSRange`）统一用
    /// UTF-16 偏移做源码坐标，这里跟着用 Int，两边可以直接换算，不用来回转。
    /// 点击跳转时编辑器拿它去查「源码偏移 → 渲染位置」的映射表。
    let sourceOffset: Int
}
