//
//  MarkdownOutlineContracts.swift
//  MarkdownEditorHy4
//
//  大纲功能的全部协议：编辑器一侧、目录 UI 一侧、以及目录 UI 往外报事件的出口
//

import Foundation

// MARK: - 编辑器一侧（数据源）

/// 编辑器需要实现的一侧：产出标题列表、接受跳转指令。
///
/// 编辑器实现它之后就被当成「数据源」，协调者通过这个协议单向取数据 / 下指令，
/// 不需要知道编辑器是什么类、内部怎么渲染。
protocol MarkdownOutlineDataSource: AnyObject {

    /// 把当前文档的完整标题列表报告给协调者。
    ///
    /// 只在「标题结构可能变化」时调用 —— 不是每次敲键盘都调用，
    /// 具体触发时机见 `MarkdownDocumentStore.applyEdit` 返回的 `headingsChanged`。
    func currentOutlineItems() -> [OutlineItem]

    /// 请求编辑器把光标 / 视口定位到指定标题。
    func scrollToOutlineItem(_ item: OutlineItem)
}

// MARK: - 编辑器往外报事件的出口

/// 编辑器只管往这个出口「喊一声」，不关心外面是谁在听。
///
/// ### 为什么不直接让编辑器持有 `OutlineCoordinator`
/// 那样编辑器和协调者就互相认识了，将来想换一个协调者策略（比如多个编辑器共享一个目录、
/// 或者把目录事件转发到日志/埋点），编辑器也要跟着改。留一层协议只多写 6 行，
/// 换来的是编辑器对「谁来消费这些事件」完全无知。
protocol MarkdownOutlineEventSink: AnyObject {

    /// 标题结构变了：新增 / 删除 / 改名 / 升降级，都要报一次完整的新列表
    func editorDidUpdateOutline(_ items: [OutlineItem])

    /// 光标移动了（调用方已经做过防抖）。
    /// - parameter sourceOffset: 光标所在的**源码偏移**（UTF-16），不是渲染坐标
    func editorDidMoveCursor(sourceOffset: Int)
}

// MARK: - 目录 UI 一侧

/// 目录 UI 需要实现的一侧：接受数据更新、接受高亮指令。
///
/// 任何想当「目录」的 view 实现这三个方法就接入完成了 ——
/// 不管是侧边栏、底部抽屉，还是以后给 Mac 原生写的 AppKit 版本。
protocol MarkdownOutlineDisplaying: AnyObject {

    /// 整份标题列表变了，重建 UI
    func updateOutlineItems(_ items: [OutlineItem])

    /// 高亮某一行。
    /// - parameter id: 要高亮的条目 id；传 `nil` 表示「光标不在任何标题下」（文档开头、
    ///   或者文档里压根没有标题），此时所有行都取消高亮
    func highlightOutlineItem(_ id: UUID?)
}

/// 目录 UI 通过它把「用户点了某一行」报出去。
///
/// 注意实现方是 `OutlineCoordinator`，不是编辑器 —— 目录 UI 报事件时
/// 同样不知道编辑器存在。
protocol MarkdownOutlineViewDelegate: AnyObject {
    func outlineView(_ view: MarkdownOutlineDisplaying, didSelect item: OutlineItem)
}
