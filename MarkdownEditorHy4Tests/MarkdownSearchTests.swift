//
//  MarkdownSearchTests.swift
//  MarkdownEditorHy4Tests
//
//  查找 / 替换的行为验收：
//  ① 找得对不对（数量、位置、大小写 / 全字）；② 上一个 / 下一个会不会绕回来；
//  ③ 替换替得对不对、能不能撤销；④ 查找框 UI 的计数是不是来自协调者；
//  ⑤ 查找条收起 / 展开时高度是不是真的跟着变（收起态必须一点高度都不占）。
//
//  ⚠️ 断言尽量打在**源码**（`markdownSource`）上：屏幕上的排版可以有Attachment、可以有省掉的标记，源码才是这一整套东西的唯一真源。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownSearchTests: XCTestCase {

    // MARK: - 小工具

    /// 挂到真实窗口上的编辑器。
    ///
    /// 只有「要撤销」「要真的排版出来」这一类测试才需要它 —— undoManager 和片段几何都只在挂上窗口之后才可用。
    private func makeWindowEditor(_ markdown: String) -> MarkdownTextView? {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow })
                ?? UIApplication.shared.windows.first else { return nil }

        let editor = MarkdownTextView(markdown: markdown)
        editor.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        window.addSubview(editor)
        editor.layoutIfNeeded()
        return editor
    }

    /// 命中在源码里的实际文字，用来确认坐标算得对不对
    private func matchedText(_ range: NSRange, in source: String) -> String {
        (source as NSString).substring(with: range)
    }

    // MARK: - 查找算法

    func testSearcherFindsEveryOccurrenceInDocumentOrder() {
        let found = PlainTextSearcher().find(query: "ab", in: "ab x ab abx", options: SearchOptions())
        XCTAssertEqual(found.map(\.location), [0, 5, 8], "应该按出现顺序返回全部命中（含重叠词里的那一处）")
    }

    func testSearcherIgnoresCaseByDefault() {
        let options = SearchOptions()
        XCTAssertEqual(PlainTextSearcher().find(query: "swift", in: "Swift / swift / SWIFT",
                                                options: options).count, 3)
    }

    func testSearcherHonorsCaseSensitiveSwitch() {
        let options = SearchOptions(caseSensitive: true)
        let found = PlainTextSearcher().find(query: "swift", in: "Swift / swift / SWIFT", options: options)
        XCTAssertEqual(found.count, 1, "区分大小写时只该命中一模一样的那一处")
        XCTAssertEqual(matchedText(found[0], in: "Swift / swift / SWIFT"), "swift")
    }

    func testSearcherHonorsWholeWordSwitch() {
        let source = "mark markdown bookmark Mark_token"
        let found = PlainTextSearcher().find(query: "mark", in: source,
                                             options: SearchOptions(wholeWord: true))
        XCTAssertEqual(found.map { matchedText($0, in: source) }, ["mark"],
                       "全字匹配要挡掉 markdown / bookmark 里的那些，且不影响句首的那一处")
    }

    func testSearcherReturnsNothingForEmptyQuery() {
        XCTAssertTrue(PlainTextSearcher().find(query: "", in: "anything", options: SearchOptions()).isEmpty)
    }

    // MARK: - 源码 → 渲染的换算

    func testRenderedRangesReturnsSeveralPiecesWhenSourceSpansBlocks() {
        let store = MarkdownDocumentStore()
        let source = "第一段\n\n第二段\n"
        store.load(markdown: source, containerWidth: 600)

        let whole = NSRange(location: 0, length: (source as NSString).length)
        XCTAssertGreaterThan(store.renderedRanges(forSourceRange: whole).count, 1,
                             "跨了块的源码区间应该换算成多段渲染区间")
    }

    // MARK: - 查找：命中列表与导航

    func testSearchCountsMatchesAndPointsToTheFirstOne() {
        let editor = MarkdownTextView(markdown: "hello world hello")
        let source = editor.markdownSource

        XCTAssertEqual(editor.performSearch(query: "hello", options: SearchOptions()), 2)
        XCTAssertEqual(editor.searchMatchSummary.total, 2)
        XCTAssertEqual(editor.searchMatchSummary.current, 0, "查完之后应该停在第一处")
        XCTAssertEqual(editor.searchState.renderedRanges.count, 2, "每个命中都要有对应的渲染区间")
        XCTAssertEqual(matchedText(editor.searchState.matches[1], in: source), "hello",
                       "第二个命中的源码坐标要指到第二个 hello 上")
    }

    func testStepWrapsAroundInBothDirections() {
        let editor = MarkdownTextView(markdown: "a a a")
        editor.performSearch(query: "a", options: SearchOptions())

        editor.stepSearchMatch(by: 1)
        XCTAssertEqual(editor.searchMatchSummary.current, 1)
        editor.stepSearchMatch(by: 1)
        XCTAssertEqual(editor.searchMatchSummary.current, 2)
        editor.stepSearchMatch(by: 1)
        XCTAssertEqual(editor.searchMatchSummary.current, 0, "下一个走到头要绕回第一个")
        editor.stepSearchMatch(by: -1)
        XCTAssertEqual(editor.searchMatchSummary.current, 2, "第一个再往前要绕到最后一个")
    }

    func testClearingSearchResetsEveryPieceOfState() {
        let editor = MarkdownTextView(markdown: "hello hello")
        editor.performSearch(query: "hello", options: SearchOptions())

        editor.clearSearchHighlight()
        XCTAssertEqual(editor.searchMatchSummary.total, 0)
        XCTAssertEqual(editor.searchMatchSummary.current, -1)
        XCTAssertTrue(editor.searchState.matchFrames.isEmpty, "高亮矩形也要一起丢掉")
    }

    // MARK: - 替换

    func testReplaceCurrentChangesOnlyThatOccurrence() {
        let editor = MarkdownTextView(markdown: "aaa bbb aaa")

        editor.performSearch(query: "aaa", options: SearchOptions())
        editor.replaceCurrentSearchMatch(with: "x")

        XCTAssertEqual(editor.markdownSource, "x bbb aaa", "只该替换当前那一处")
        XCTAssertEqual(editor.searchMatchSummary.total, 1)
        XCTAssertEqual(editor.searchMatchSummary.current, 0, "替换之后要停在刚刚那一处的后面")
    }

    func testReplaceAllRewritesEveryOccurrence() {
        let editor = MarkdownTextView(markdown: "aaa bbb aaa ccc aaa")

        editor.performSearch(query: "aaa", options: SearchOptions())
        XCTAssertEqual(editor.replaceAllSearchMatches(with: "z"), 3)
        XCTAssertEqual(editor.markdownSource, "z bbb z ccc z", "全部替换之后一处都不许留")
    }

    /// 全部替换最容易踩的坑：正序替换会让后面那些还没处理的坐标全体失效。
    /// 这里故意让**每一处长度都不一样**，倒序有任何偏差都会立刻体现成乱文。
    func testReplaceAllKeepsUntouchedPartsIntact() {
        let source = "# 标题 aaa\n\n开头 aaa 中间\n\n- 列表 aaa 项\n"
        let editor = MarkdownTextView(markdown: source)

        editor.performSearch(query: "aaa", options: SearchOptions())
        editor.replaceAllSearchMatches(with: "长一点的替换词")

        XCTAssertEqual(editor.markdownSource,
                       "# 标题 长一点的替换词\n\n开头 长一点的替换词 中间\n\n- 列表 长一点的替换词 项\n",
                       "三处都要换掉，其它文字一个字符都不许动")
    }

    func testReplaceInsideListItemKeepsTheListStructure() {
        let editor = MarkdownTextView(markdown: "- aaa\n- bbb\n")

        editor.performSearch(query: "aaa", options: SearchOptions())
        editor.replaceCurrentSearchMatch(with: "zzz")

        XCTAssertEqual(editor.markdownSource, "- zzz\n- bbb\n",
                       "列表项里的替换不能把 `- ` 标记吃掉（渲染里有圆点占位符，坐标最容易错位）")
    }

    func testReplaceAllCanBeUndone() throws {
        let original = "aaa bbb aaa"
        let editor = try XCTUnwrap(makeWindowEditor(original), "拿不到可用窗口，没法验证撤销")
        defer { editor.removeFromSuperview() }

        editor.performSearch(query: "aaa", options: SearchOptions())
        editor.replaceAllSearchMatches(with: "z")
        XCTAssertEqual(editor.markdownSource, "z bbb z")

        let manager = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(manager.canUndo, "替换是我们自己做的编辑，必须能撤销")
        manager.undo()
        XCTAssertEqual(editor.markdownSource, original, "撤销之后源码要逐字符回到原样")
    }

    // MARK: - 命中位置的时效性

    /// 文档一改，之前记的源码偏移就可能整体平移 —— 这时必须通知外面（协调者）重查。
    func testEditingNotifiesSearchSink() {
        let editor = MarkdownTextView(markdown: "hello")
        let spy = SearchSinkSpy()
        editor.searchEventSink = spy

        // 用「可撤销」那条入口：它内部会把这次编辑标成「程序自己发起的」，从而跳过 disable/enable undo 那对调用 —— 在没有系统替我们记账的时机调用它， _UITextUndoManager 会直接抛 invalid state（这是项目里已经踩过的坑）
        editor.insertMarkdownSourceUndoably("world")
        XCTAssertEqual(spy.changeCount, 1, "编辑之后要通知一次「内容变了」")
    }

    /// 反过来：替换自己就已经重查过了，不该再通知一遍 —— 否则协调者会在防抖之后又查一次，把当前项顶回第一个（表现为「一替换就跳回文首」）。
    func testReplacingDoesNotNotifySearchSink() {
        let editor = MarkdownTextView(markdown: "aaa bbb aaa")
        let spy = SearchSinkSpy()
        editor.searchEventSink = spy

        editor.performSearch(query: "aaa", options: SearchOptions())
        spy.changeCount = 0                       // 忽略上面那一次查找前无关的状态
        editor.replaceCurrentSearchMatch(with: "x")

        XCTAssertEqual(spy.changeCount, 0, "替换过程中的编辑不该再触发一轮外部重查")
    }

    /// 命中位置的坐标要靠重新查找来校准：全部替换之后如果替换文字里还有查找串，应该找得出来。
    func testSearchAfterReplaceAllFindsMatchesInsideTheReplacement() {
        let editor = MarkdownTextView(markdown: "aaa bbb aaa")

        editor.performSearch(query: "aaa", options: SearchOptions())
        editor.replaceAllSearchMatches(with: "aaa!")

        XCTAssertEqual(editor.searchMatchSummary.total, 2, "替换文字里那两处 aaa 应该被重新数出来")
        XCTAssertEqual(editor.markdownSource, "aaa! bbb aaa!")
    }
}

// MARK: - 测试替身

/// 记录「编辑器一共喊了几声文档变了」的出口
private final class SearchSinkSpy: MarkdownSearchEventSink {
    var changeCount = 0

    func editorContentDidChange() { changeCount += 1 }

    /// 原因见项目约定：非 UI 的 class 在 `MainActor` 默认隔离下必须写 `nonisolated deinit`，否则 Swift 6.2 运行时会在嵌套释放时 free 野指针。
    nonisolated deinit {}
}

// MARK: - 协调者 + 查找框 UI

@MainActor
final class MarkdownSearchBarFlowTests: XCTestCase {

    /// 假的编辑器：只数一下「协调者让我查了几次、查了什么」
    private final class FakeSearchDataSource: MarkdownSearchDataSource {
        var searchCount = 0
        var lastQuery = ""
        var clearCount = 0
        var stepTotal = 0
        var summary: (current: Int, total: Int) = (0, 3)

        func performSearch(query: String, options: SearchOptions) -> Int {
            searchCount += 1
            lastQuery = query
            return summary.total
        }
        var searchMatchSummary: (current: Int, total: Int) { summary }
        func stepSearchMatch(by delta: Int) { stepTotal += delta }
        func replaceCurrentSearchMatch(with replacement: String) -> Int { summary.total }
        func replaceAllSearchMatches(with replacement: String) -> Int { summary.total }
        func clearSearchHighlight() { clearCount += 1 }

        /// 原因见项目约定：非 UI 的 class 在 `MainActor` 默认隔离下必须写 `nonisolated deinit`，否则 Swift 6.2 运行时会在嵌套释放时 free 野指针。
        nonisolated deinit {}
    }

    /// 防抖：连续敲三个字要合并成一次查找
    func testCoordinatorDebouncesTypingIntoOneSearch() {
        let coordinator = SearchCoordinator()
        let dataSource = FakeSearchDataSource()
        let bar = MarkdownFindBarView()
        coordinator.searchDataSource = dataSource
        coordinator.findBar = bar

        coordinator.findBar(bar, didChangeQuery: "h", options: SearchOptions())
        coordinator.findBar(bar, didChangeQuery: "he", options: SearchOptions())
        coordinator.findBar(bar, didChangeQuery: "hel", options: SearchOptions())

        let done = expectation(description: "防抖窗口过去之后再验证")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            XCTAssertEqual(dataSource.searchCount, 1, "三个字只该触发一次真正的查找")
            XCTAssertEqual(dataSource.lastQuery, "hel", "要用最后一次的内容去查")
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    /// 查找框上的计数必须来自协调者回推的结果，而不是它自己算的。
    ///
    /// 走的是真实链路：`typeQuery` 写进输入框 → 内容变了 → 协调者 → 编辑器 → 计数回写。
    func testFindBarShowsSummaryFromCoordinator() {
        let coordinator = SearchCoordinator()
        let dataSource = FakeSearchDataSource()
        dataSource.summary = (current: 0, total: 3)
        let bar = MarkdownFindBarView()
        coordinator.searchDataSource = dataSource
        coordinator.findBar = bar
        bar.delegate = coordinator

        bar.typeQuery("abc")
        let searched = expectation(description: "等防抖窗口过去")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            coordinator.findBar(bar, didStepBy: 1)
            XCTAssertEqual(self.summaryText(in: bar), "1/3", "第 1 个（下标 0）要显示成 1/3")
            searched.fulfill()
        }
        wait(for: [searched], timeout: 2)
    }

    /// 没有命中时要写「无结果」，并且把导航按钮置灰（比点了没反应强）
    func testFindBarShowsNoResultAndDisablesNavigation() {
        let coordinator = SearchCoordinator()
        let dataSource = FakeSearchDataSource()
        dataSource.summary = (current: -1, total: 0)
        let bar = MarkdownFindBarView()
        coordinator.searchDataSource = dataSource
        coordinator.findBar = bar
        bar.delegate = coordinator

        bar.typeQuery("zzz")

        let done = expectation(description: "防抖窗口过去之后再验证界面")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            XCTAssertEqual(self.summaryText(in: bar), "无结果")
            XCTAssertFalse(self.nextStepButton(in: bar).isEnabled, "没有命中时「下一个」要点不动")
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    /// 关闭：编辑器那边的高亮要清掉、横条要请求把自己收起来
    func testClosingBarClearsHighlightAndAsksContainerToDismiss() {
        let coordinator = SearchCoordinator()
        let dataSource = FakeSearchDataSource()
        let bar = MarkdownFindBarView()
        coordinator.searchDataSource = dataSource
        coordinator.findBar = bar

        var dismissed = false
        bar.onDismiss = { dismissed = true }
        coordinator.findBarDidClose(bar)

        XCTAssertEqual(dataSource.clearCount, 1, "关掉之后屏幕上的黄块必须擦掉")
        XCTAssertTrue(dismissed, "要把「请把我收起来」递给真正握着高度约束的那一层")
    }

    // MARK: 视图树里捞东西

    /// 按 accessibilityIdentifier 找到命中计数那个 label 的当前文字
    private func summaryText(in root: UIView) -> String? {
        (firstView(in: root, where: { $0.accessibilityIdentifier == "查找命中计数" }) as? UILabel)?.text
    }

    private func nextStepButton(in root: UIView) -> UIButton {
        firstView(in: root, where: { $0.accessibilityLabel == "下一个匹配" }) as? UIButton ?? UIButton()
    }
}

// MARK: - 查找条的高度（收起时必须一点都不占）

@MainActor
final class MarkdownFindBarLayoutTests: XCTestCase {

    /// 收起态高度必须是 0：它头顶上就是菜单栏，占一点高度就会把正文顶下去
    func testCollapsedBarTakesNoHeight() {
        let bar = MarkdownFindBarView()
        XCTAssertTrue(bar.isCollapsed, "默认应该是收起来的")
        XCTAssertEqual(bar.systemLayoutSizeFitting(.zero).height, 0, accuracy: 0.5)
    }

    /// 展开之后高度由内容撑起来；加上替换行之后要更高
    func testExpandedHeightGrowsWithReplaceRow() {
        let bar = MarkdownFindBarView()
        bar.setCollapsed(false)
        let collapsed = bar.systemLayoutSizeFitting(.zero).height
        XCTAssertGreaterThan(collapsed, 40, "展开之后要能装下查找那一行")

        bar.toggleReplaceRow()
        let expanded = bar.systemLayoutSizeFitting(.zero).height
        XCTAssertGreaterThan(expanded, collapsed + 20, "展开替换行之后要更高")

        bar.setCollapsed(true)
        XCTAssertEqual(bar.systemLayoutSizeFitting(.zero).height, 0, accuracy: 0.5, "收回去要连替换行一起收掉")
    }

    /// 走真实那条收 / 放的链路（⌘F → 点关闭），横条的高度要真的跟着变。
    ///
    /// ### 这条用例存在的理由
    /// 高度是由横条自己那条 `heightAnchor` 约束独裁的，改完 constant **不会**自动把祖先标脏，上层那句 `layoutIfNeeded()` 于事无补地空转 —— 那版的表现是：约束已经是 50 了， frame 还是 0，查找条永远弹不出来。所以这条守的是「改完高度，布局真的跟着动」。
    func testBarHeightFollowsShowAndHideInContainer() {
        let controller = MarkdownDocumentViewController()
        controller.loadViewIfNeeded()
        guard let bar = firstView(in: controller.view, where: { $0 is MarkdownFindBarView }) as? MarkdownFindBarView else {
            return XCTFail("内容页里没找到查找条")
        }
        controller.view.layoutIfNeeded()
        XCTAssertEqual(bar.frame.height, 0, accuracy: 0.5, "默认收起，不能占高度")

        controller.perform(NSSelectorFromString("showFindBar"))
        controller.view.layoutIfNeeded()
        XCTAssertFalse(bar.isCollapsed)
        XCTAssertGreaterThan(bar.frame.height, 30, "⌘F 之后要真的展开")

        // 关闭走的是「按钮 → 协调者 → 请求容器收起」那条异步链路
        guard let closeButton = firstView(in: bar, where: { $0.accessibilityLabel == "关闭查找" }) as? UIButton else {
            return XCTFail("查找条里没找到关闭按钮")
        }
        let collapsed = expectation(description: "收回去")
        closeButton.sendActions(for: .touchUpInside)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertTrue(bar.isCollapsed, "点关闭之后要回到收起态")
            controller.view.layoutIfNeeded()
            XCTAssertEqual(bar.frame.height, 0, accuracy: 0.5, "收完之后高度要回到 0")
            collapsed.fulfill()
        }
        wait(for: [collapsed], timeout: 3)
    }
}

// MARK: - 视图树里捞东西

/// 在视图树里找第一个符合的视图（按深度优先）
private func firstView(in root: UIView, where matches: (UIView) -> Bool) -> UIView? {
    if matches(root) { return root }
    for subview in root.subviews {
        if let hit = firstView(in: subview, where: matches) { return hit }
    }
    return nil
}
