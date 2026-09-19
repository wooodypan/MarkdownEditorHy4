//
//  MarkdownSearchContracts.swift
//  MarkdownEditorHy4
//
//  查找 / 替换的全部协议：查找算法、编辑器一侧、查找框 UI 一侧、往外报事件的出口
//
//  组件靠这一层的协议通信，互不持有引用 —— 和大纲（MarkdownOutlineContracts）是同一个套路。
//

import Foundation

// MARK: - 查找选项

/// 查找时的两个开关。
///
/// 当前**不做**正则表达式：先把朴素的串匹配跑通。
/// 将来要加时，新写一个遵循 `MarkdownSearching` 的实现塞给编辑器就行，编辑器 / 查找框都不用改 —— 这也是查找算法抽成协议的唯一理由。
struct SearchOptions: Equatable {

    /// 要不要区分大小写。默认**不区分** —— 用户敲「swift」时通常也想找出「Swift」。
    var caseSensitive: Bool = false

    /// 全字匹配：命中的左右两边都不能是字母 / 数字 / 下划线。
    ///
    /// 判据是按「字符」算而不是按「单词」算 —— 中文没有空格分词，所以「搜 mark 不许命中 markdown」这套对中英文都成立：搜「的」不会命中「目的」里那个「的」。
    var wholeWord: Bool = false
}

// MARK: - 查找算法

/// 查找算法。
///
/// ### 为什么要抽这层协议（和代码高亮那次是同一个判断）
/// 「怎么把匹配找出来」确实存在**多种可互换的实现**：今天的朴素子串、以后的正则。
/// 抽成协议之后，换算法时编辑器和查找框一行都不用动。
///
/// 反过来，「找到之后怎么上色」「怎么滚过去」「怎么替换」都只有一种合理做法（属于「把已有结果显示出来」和「复用已有的编辑管线」），**不做协议**，直接写在 `MarkdownTextView+Search.swift` 里 —— 详见 `doc/查找替换方案.md`。
///
/// ### 返回值为什么是 `NSRange`（UTF-16 偏移）而不是 `Range<String.Index>`
/// 下游全是 UTF-16 坐标系：源码 → 渲染的换算（`MarkdownDocumentStore.renderedRanges`）、画高亮要的 range、替换走的 `applyEdit` 都认 NSRange。用 `String.Index` 的话每一处都要再换算一次，白白多一堆易错代码 —— 和 `HighlightToken.range` 是同一个取舍。
protocol MarkdownSearching {

    /// 在 `source` 全文里找出所有匹配，**按位置递增**返回（上一个 / 下一个依赖这个顺序）。
    /// - returns: 命中区间，坐标系是 `source` 的 UTF-16 偏移；空串或者没命中都返回空数组。
    func find(query: String, in source: String, options: SearchOptions) -> [NSRange]
}

// MARK: - 编辑器一侧（数据源）

/// 编辑器需要实现的一侧：查找、翻到某一个、替换。
///
/// 编辑器穿上它之后就只是个「数据源」，协调者通过这个协议单向取数据 / 下指令，不需要知道它是什么类、内部怎么排版。
protocol MarkdownSearchDataSource: AnyObject {

    /// 跑一次查找：**换掉**当前的命中列表，并跳到第一个命中。
    /// - returns: 命中总数（0 表示没找到）
    @discardableResult
    func performSearch(query: String, options: SearchOptions) -> Int

    /// 现在是第几个 / 一共几个。`current` 为 -1 表示「当前没有查找，或者一个都没命中」。
    var searchMatchSummary: (current: Int, total: Int) { get }

    /// 上一个 / 下一个（`delta` 传 -1 / +1）。走到头会绕回另一头，和常见的查找框一致。
    func stepSearchMatch(by delta: Int)

    /// 替换当前这一处。
    /// - returns: 替换完之后还剩多少处命中。
    @discardableResult
    func replaceCurrentSearchMatch(with replacement: String) -> Int

    /// 全部替换。
    /// - returns: 一共替换了多少处。
    @discardableResult
    func replaceAllSearchMatches(with replacement: String) -> Int

    /// 收工：抹掉屏幕上的高亮块。
    func clearSearchHighlight()
}

// MARK: - 查找框 UI 一侧

/// 查找框需要实现的一侧：只要能显示「第几个 / 共几个」。
///
/// 任何想当「查找框」的 view 实现这一个方法就接入完成了 —— 不管它是顶部的横条，还是以后给 Mac 原生 AppKit 写的版本。
protocol MarkdownSearchBarDisplaying: AnyObject {

    /// 更新命中计数。
    /// - parameter current: 当前是第几个（从 0 开始）；-1 表示没有当前项
    /// - parameter total:   一共命中几个（0 表示没有结果）
    func updateSearchSummary(current: Int, total: Int)

    /// 请求把自己收起来（用户在查找框里按了 Esc / 点了关闭时会走到这里）。
    ///
    /// 真正「把它藏起来」的动作是持有它的容器做的（因为只有容器握着那条高度约束），这里只是把这个请求递出去 —— 于是「谁负责清编辑器的高亮」和「谁负责改布局」
    /// 两件事依然分得开。
    func dismissSearchBar()
}

/// 查找框通过它把「用户点了什么」报出去。
///
/// 实现方是 `SearchCoordinator`，不是编辑器 —— 查找框报事件时同样不知道编辑器存在。
protocol MarkdownFindBarDelegate: AnyObject {

    /// 输入框里的内容变了（要不要立刻搜、什么时候搜由协调者决定，它负责防抖）
    func findBar(_ bar: MarkdownFindBarView, didChangeQuery query: String, options: SearchOptions)

    /// 点了上一个 / 下一个（`delta` 是 -1 / +1）
    func findBar(_ bar: MarkdownFindBarView, didStepBy delta: Int)

    /// 点了「替换」
    func findBar(_ bar: MarkdownFindBarView, didTapReplaceWith replacement: String)

    /// 点了「全部替换」
    func findBar(_ bar: MarkdownFindBarView, didTapReplaceAllWith replacement: String)

    /// 点了关闭
    func findBarDidClose(_ bar: MarkdownFindBarView)
}

// MARK: - 编辑器往外报事件的出口

/// 编辑器只在文档内容变了时通过它「喊一声」，不关心外面是谁在听。
///
/// ### 为什么必须有这一条
/// 命中项记的是**源码偏移**。用户在文档里打一个字，后面的偏移整体平移，原先那些位置指向的文字就不对了 —— 不重新查一遍的话，用户看到的高亮块会停在错误的词上，「下一个」也会跳歪。
protocol MarkdownSearchEventSink: AnyObject {
    /// 文档内容刚被编辑过一次（查找命中的位置可能已经变了）
    func editorContentDidChange()
}
