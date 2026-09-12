//
//  OutlineCoordinator.swift
//  MarkdownEditorHy4
//
//  大纲协调者：编辑器和目录 UI 之间的第三方，双方都只跟它通信、互不认识
//

import Foundation

/// 大纲协调者。
///
/// ### 它是什么、不是什么
/// 它是**纯数据 / 事件层**：
/// - 不 import UIKit，不 import TextKit，不 import swift-markdown；
/// - 不认识 `MarkdownTextView`，也不认识任何具体的目录 UI 类；
/// - 两边都是 `weak` 引用（自己也不拥有它们，生命周期由上层容器管）。
///
/// 它身上唯一的「业务逻辑」有两条，都很小：
/// 1. **区间归属查询**：光标现在落在哪个标题的管辖范围里（`ownerIndex`，二分查找）；
/// 2. **高亮去重**：归属标题没变就不通知 UI，避免每次光标移动都刷一遍界面。
///
/// ### 数据流
/// ```
/// 编辑器 ──editorDidMoveCursor / editorDidUpdateOutline──▶ 协调者
///                                                          │
///                                             highlightOutlineItem / updateOutlineItems
///                                                          ▼
///                                                      目录 UI
/// 目录 UI ──outlineView(_:didSelect:)──▶ 协调者 ──scrollToOutlineItem──▶ 编辑器
/// ```
///
/// 两个角色它都扮演：对编辑器来说是「事件出口」（`MarkdownOutlineEventSink`），
/// 对目录 UI 来说是「事件接收方」（`MarkdownOutlineViewDelegate`）。
final class OutlineCoordinator: MarkdownOutlineEventSink {

    // MARK: 两端（都是弱引用）

    /// 数据源那一侧：通常是编辑器
    weak var editorDataSource: MarkdownOutlineDataSource?
    /// 展示那一侧：通常是悬浮目录面板。存的是协议类型，所以换成别的 UI 也不用改这里
    weak var outlineView: MarkdownOutlineDisplaying?

    // MARK: 状态

    /// 最近一次拿到的完整标题列表，按文档顺序排列（`sourceOffset` 递增）。
    /// 递增这个性质是下面二分查找成立的前提。
    private(set) var items: [OutlineItem] = []

    /// 当前高亮的条目 id。用来做「没变就不刷 UI」的去重
    private var currentHighlightedID: UUID?

    /// 最近一次光标所在的源码偏移。
    ///
    /// ### 为什么必须记着它
    /// 编辑会让编辑器**重建**受影响的块，块的 UUID 跟着换新 —— 于是整份 `items` 里
    /// 所有 id 都是新的，`currentHighlightedID` 立刻变成一条失效的旧 id。
    /// 如果这时候拿它去和高亮结果比「有没有变」，就会误判成「没变」而漏掉刷新。
    /// 记着光标偏移，就能在列表重建后用最新的 id 重算一次高亮。
    private var lastCursorSourceOffset: Int = 0

    /// ### 为什么这里要显式写 `nonisolated deinit`（很重要，别删）
    /// app target 开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，本类默认跑在主线程上，
    /// 连隐式的 deinit 也是「actor 隔离的 deinit」。Swift 6.2 运行时对它的处理是：
    /// 释放时先切回 MainActor 执行器（`swift_task_deinitOnExecutorImpl`），
    /// 而这个函数会维护一个 task-local 作用域；一旦出现嵌套释放
    /// （隔离对象里套着另一个隔离对象），内层作用域析构时会 free 一个野指针，
    /// 直接 `malloc: pointer being freed was not allocated` 崩掉。
    ///
    /// 实测表现：单元测试里只要新建一次本类，进程就 SIGABRT（详情见
    /// `~/.workbuddy/skills/ios-xctest-crash-diagnosis`）。同类问题的既有修法见
    /// `MarkdownBlock` / `MarkdownDocumentStore`。
    ///
    /// 本类只持有值类型和弱引用，销毁时不需要任何主线程状态，
    /// 所以声明成 `nonisolated` 不走执行器切换，从根上避免嵌套。
    nonisolated deinit {}

    // MARK: - 编辑器 → 协调者 → 目录 UI

    /// 初次装配 / 手动刷新：主动向编辑器要一次完整列表。
    ///
    /// 用在上层容器刚刚把三者连起来的时候 —— 那时文档早就加载完了，
    /// 编辑器不会再发「标题变了」的通知，得主动要一次。
    func reloadFromEditor() {
        guard let editorDataSource else { return }
        editorDidUpdateOutline(editorDataSource.currentOutlineItems())
    }

    /// 编辑器报告「标题结构变了」。
    func editorDidUpdateOutline(_ items: [OutlineItem]) {
        self.items = items
        outlineView?.updateOutlineItems(items)

        // 列表换了（id 全变），旧高亮一定失效，用最近一次光标位置重算一个
        applyHighlight(forSourceOffset: lastCursorSourceOffset, force: true)
    }

    /// 编辑器报告「光标移动了」。
    ///
    /// 调用方（编辑器）负责防抖，这里只做归属查询和去重。
    func editorDidMoveCursor(sourceOffset: Int) {
        lastCursorSourceOffset = sourceOffset
        applyHighlight(forSourceOffset: sourceOffset, force: false)
    }

    // MARK: - 目录 UI → 协调者 → 编辑器

    /// 目录 UI 点了某一行。需要单独暴露成公开方法，方便测试和不走 delegate 的调用方
    func outlineDidSelectItem(_ item: OutlineItem) {
        editorDataSource?.scrollToOutlineItem(item)
    }

    // MARK: - 归属查询

    /// 算出「光标在 offset 这个位置时，应该高亮哪一条」，然后通知 UI。
    ///
    /// - parameter force: true 表示无条件通知（列表刚重建时必须这样）
    private func applyHighlight(forSourceOffset offset: Int, force: Bool) {
        let owner = ownerIndex(forSourceOffset: offset).map { items[$0].id }
        guard force || owner != currentHighlightedID else { return }
        currentHighlightedID = owner
        outlineView?.highlightOutlineItem(owner)
    }

    /// 区间归属查询：找到「起始偏移 <= offset 的**最后**一个标题」。
    ///
    /// 这就是「用户光标在哪个标题下的内容里」的全部实现 —— 光标前面的最近一个标题，
    /// 就是它所在章节的标题。注意这里刻意**不做多级嵌套高亮**
    /// （比如光标在 H3 里时把它的 H1、H2 祖先也一起点亮），按需求先做单项高亮。
    ///
    /// `items` 按 `sourceOffset` 递增，所以二分查找到 `nil` 或者目标下标都是 O(log n)。
    /// 文档开头（第一个标题之前）没有归属标题，返回 nil。
    func ownerIndex(forSourceOffset offset: Int) -> Int? {
        var low = 0
        var high = items.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if items[mid].sourceOffset <= offset {
                found = mid
                low = mid + 1        // 还能更靠后，继续往右找
            } else {
                high = mid - 1       // 这个标题在光标之后，往左找
            }
        }
        return found
    }
}

// MARK: - 目录 UI 的事件出口

extension OutlineCoordinator: MarkdownOutlineViewDelegate {

    func outlineView(_ view: MarkdownOutlineDisplaying, didSelect item: OutlineItem) {
        outlineDidSelectItem(item)
    }
}
