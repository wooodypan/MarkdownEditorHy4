//
//  SearchCoordinator.swift
//  MarkdownEditorHy4
//
//  查找协调者：编辑器和查找框 UI 之间的第三方，双方都只跟它通信、互不认识
//

import Foundation

/// 查找协调者。
///
/// ### 它是什么、不是什么
/// 和 `OutlineCoordinator` 完全同构：不碰 UIKit、不认识 `MarkdownTextView`、也不认识查找框具体是哪个类；两端都是 `weak` 引用，生命周期由上层容器管。
///
/// 它身上唯一的「逻辑」是**防抖**：查找框每敲一个字都会喊一次，落在这一层合并成一次（上次 query 和这次一样就省掉），避免打字时每键都全文重算一遍。
///
/// ### 数据流
/// ```
/// 查找框 ──didChangeQuery / didStepBy / didTapReplace…──▶ 协调者 ──▶ 编辑器（数据源）
///                                                          │
///                                              searchMatchSummary
///                                                          ▼
///                                                       查找框
/// 编辑器 ──editorContentDidChange──▶ 协调者（命中位置可能失效了，重查一次）
/// ```
final class SearchCoordinator: MarkdownFindBarDelegate, MarkdownSearchEventSink {

    // MARK: 两端（都是弱引用）

    /// 数据源那一侧：通常是编辑器
    weak var searchDataSource: MarkdownSearchDataSource?
    /// 展示那一侧：通常是顶部那条查找框。存的是协议类型，所以换成别的 UI 也不用改这里
    weak var findBar: MarkdownSearchBarDisplaying?

    // MARK: 状态

    /// 最近一次真正发起的查找（内容被编辑后要靠它重查一遍）
    private var lastQuery = ""
    private var lastOptions = SearchOptions()
    /// 防抖任务
    private var pendingWork: DispatchWorkItem?
    /// ⚠️ 别把这个数调得太小：查找要「阻塞地过一遍全文 + 换算所有命中的渲染坐标」，用户连续打字时每键一次会很亏。120ms 是「手指已经在下一个键上了」的典型间隔，感知上依然是实时的。
    private static let debounceInterval: TimeInterval = 0.12

    /// 原因见 `OutlineCoordinator` 里 `nonisolated deinit` 的长注释：
    /// 本类是纯数据 / 事件层，销毁时不需要任何主线程状态，写成「非隔离」的 deinit 是为了绕开 Swift 6.2 运行时的那个野指针 free。
    nonisolated deinit {}

    // MARK: - 查找框 → 协调者 → 编辑器

    func findBar(_ bar: MarkdownFindBarView, didChangeQuery query: String, options: SearchOptions) {
        lastQuery = query
        lastOptions = options

        pendingWork?.cancel()
        guard !query.isEmpty else {
            // 清空了：立刻擦干净屏幕上的高亮和计数，别等到防抖结束
            searchDataSource?.clearSearchHighlight()
            publishSummary()
            return
        }
        scheduleSearch()
    }

    func findBar(_ bar: MarkdownFindBarView, didStepBy delta: Int) {
        searchDataSource?.stepSearchMatch(by: delta)
        publishSummary()
    }

    func findBar(_ bar: MarkdownFindBarView, didTapReplaceWith replacement: String) {
        searchDataSource?.replaceCurrentSearchMatch(with: replacement)
        publishSummary()
    }

    func findBar(_ bar: MarkdownFindBarView, didTapReplaceAllWith replacement: String) {
        searchDataSource?.replaceAllSearchMatches(with: replacement)
        publishSummary()
    }

    func findBarDidClose(_ bar: MarkdownFindBarView) {
        pendingWork?.cancel()
        searchDataSource?.clearSearchHighlight()
        lastQuery = ""
        // 让容器把横条收起来（协调者自己握不住高度约束，那是布局层的事）
        findBar?.dismissSearchBar()
    }

    // MARK: - 上层容器 → 协调者（换文档）

    /// 文档被整篇换掉之后（比如切换 Tab），按原来那个词在新文档里重查一遍。
    ///
    /// 编辑器 `setMarkdown` 时不会通知「内容变了」（那是「换文档」不是「编辑」），少这一句的话，查找横条会一直显示上一份文档的命中数。
    func rerunIfNeeded() {
        guard !lastQuery.isEmpty else { return }
        scheduleSearch()
    }

    // MARK: - 编辑器 → 协调者

    /// 文档改过 → 命中记的那些源码偏移可能整片失效，按最新的 query 重查一遍。
    ///
    /// 同样走防抖：一次 `applyEdit` 内部的多次属性回调、以及用户连着打字，都只会在最后一次触发一遍查找。
    func editorContentDidChange() {
        guard !lastQuery.isEmpty else { return }
        scheduleSearch()
    }

    // MARK: - 内部

    /// 排一次查找任务（同一个时刻只留最后一份）
    private func scheduleSearch() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.searchDataSource?.performSearch(query: self.lastQuery, options: self.lastOptions)
            self.publishSummary()
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    /// 把「第几个 / 共几个」回写给查找框。
    ///
    /// 每次都主动拉一次（而不是让编辑器在操作之后回调）：数据源是唯一的真相来源，由它说了算，这里不缓存计数 —— 缓存一份只会多一处可能对不上的状态。
    private func publishSummary() {
        guard let summary = searchDataSource?.searchMatchSummary else { return }
        findBar?.updateSearchSummary(current: summary.current, total: summary.total)
    }
}
