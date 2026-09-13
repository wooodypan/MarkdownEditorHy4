//
//  MarkdownOutlineFoldTests.swift
//  MarkdownEditorHy4Tests
//
//  大纲「展开 / 折叠」的验收测试
//
//  分成三层：
//  1. 树本身（OutlineTree）：层级关系怎么建、折叠之后哪些行还看得见；
//  2. 折叠状态跨重建怎么继承（OutlineCollapseState）：编辑之后不能把用户折好的又弹开；
//  3. 目录面板的交互：三角只在有子标题的行上、点它真的折、高亮要往上找可见祖先、
//     列表滚动位置该记的记、该回顶部的回顶部。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownOutlineFoldTests: XCTestCase {

    // MARK: - 测试数据

    /// 一棵典型的三层树：
    /// ```
    /// A(H1)
    ///   A1(H2)
    ///   A2(H2)
    ///     A2a(H3)
    /// B(H1)
    ///   B1(H2)
    /// ```
    private let treeSpecs: [(level: Int, title: String)] = [
        (1, "第一章"), (2, "第一章第一节"), (2, "第一章第二节"), (3, "第一章第二节之一"),
        (1, "第二章"), (2, "第二章第一节")
    ]

    /// 按「层级 + 标题文字」造条目。偏移默认按 100 递增，一眼能看出有没有被顶移
    private func makeItems(_ specs: [(level: Int, title: String)],
                           offsetStep: Int = 100) -> [OutlineItem] {
        specs.enumerated().map { index, spec in
            OutlineItem(id: UUID(),
                        level: spec.level,
                        title: spec.title,
                        sourceOffset: index * offsetStep)
        }
    }

    /// 造一串「够长、能滚」的标题：`count` 个 H1（没有子标题）。
    ///
    /// ⚠️ 用它的用例里行数别给太小：面板高度是会变的（默认「父视图高度的 70%」，
    /// 宿主 800 高就是 560），行数不够时列表根本滚不动，用它测「要保住滚动位置」
    /// 就会读到被夹住的值（120 点设进去只剩 84）—— 那不是 bug，是可滚范围本来就那么点
    private func makeLongList(_ count: Int) -> [OutlineItem] {
        (1...count).map { index in
            OutlineItem(id: UUID(), level: 1, title: "第 \(index) 节", sourceOffset: index * 100)
        }
    }

    // MARK: - 第 1 层：树

    /// 层级关系：谁是谁的子标题、谁没有父节点
    func testTreeNestsHeadingsByLevel() {
        let items = makeItems(treeSpecs)
        let tree = OutlineTree(items: items)

        XCTAssertEqual(tree.roots, [0, 4], "A 和 B 是两个 H1，各自开一棵树")
        XCTAssertEqual(tree.children[0], [1, 2], "A 底下挂着 A1 和 A2")
        XCTAssertEqual(tree.children[2], [3], "A2a 挂在 A2 底下（H3 是 H2 的子节点）")
        XCTAssertEqual(tree.children[4], [5], "B1 挂在 B 底下")
        XCTAssertTrue(tree.children[1].isEmpty, "A1 底下没有东西")
        XCTAssertEqual(tree.parents[3], 2)
        XCTAssertNil(tree.parents[0], "A 是根，没有父节点")
    }

    /// 折叠一层会把它的**整棵子树**藏起来，而不是只藏下一层
    func testVisibleIndicesHidesWholeSubtree() {
        let items = makeItems(treeSpecs)
        let tree = OutlineTree(items: items)

        XCTAssertEqual(tree.visibleIndices(collapsedIDs: []), [0, 1, 2, 3, 4, 5],
                       "默认全展开：六行都在")

        XCTAssertEqual(tree.visibleIndices(collapsedIDs: [items[0].id]), [0, 4, 5],
                       "折了 A：A1 / A2 / A2a 一起消失")

        XCTAssertEqual(tree.visibleIndices(collapsedIDs: [items[2].id]), [0, 1, 2, 4, 5],
                       "折了 A2：只藏 A2a，A1 照旧")

        XCTAssertEqual(tree.visibleIndices(collapsedIDs: [items[0].id, items[4].id]), [0, 4],
                       "两棵树各折一个：只剩根节点")
    }

    /// 叶子行（没有子标题）就算带着折叠标记也必须显示 —— 否则那一行会永久消失
    func testVisibleIndicesKeepsLeafRow() {
        let items = makeItems(treeSpecs)
        let tree = OutlineTree(items: items)

        // 「折叠 A1」在 UI 上是做不到的（没三角），但数据上可能出现残留标记
        let visible = tree.visibleIndices(collapsedIDs: [items[1].id])
        XCTAssertTrue(visible.contains(1), "没有子标题的行折了也不该消失")
        XCTAssertEqual(visible, [0, 1, 2, 3, 4, 5])
    }

    /// 高亮往上找「最外层那个被折叠的祖先」
    func testRepresentativeIndexFindsOutermostCollapsedAncestor() {
        let items = makeItems(treeSpecs)
        let tree = OutlineTree(items: items)

        XCTAssertEqual(tree.representativeIndex(of: 3, collapsedIDs: []), 3,
                       "没折任何东西时，代表就是自己")

        XCTAssertEqual(tree.representativeIndex(of: 3, collapsedIDs: [items[2].id]), 2,
                       "折了 A2：A2a 的代表是 A2")

        XCTAssertEqual(tree.representativeIndex(of: 3, collapsedIDs: [items[0].id, items[2].id]), 0,
                       "A 和 A2 连着折：真正显示着的是最外面的 A（A2 自己也藏起来了）")
    }

    // MARK: - 第 2 层：折叠状态跨「列表重建」的继承

    /// 原地改标题文字（位置不动）→ 折叠状态要认得出来
    func testCollapseStateInheritedWhenHeadingRenamedInPlace() {
        let old = makeItems(treeSpecs)
        var renamed = treeSpecs
        renamed[0] = (1, "第一章改了个名")
        let new = makeItems(renamed)

        let inherited = OutlineCollapseState.inherit(from: old,
                                                    collapsedIDs: [old[0].id],
                                                    to: new)
        XCTAssertEqual(inherited, [new[0].id], "原地改标题文字不该让折叠状态失效")
    }

    /// 标题被上面的编辑整体顶移 → 位置变了但文字没变，也要认得出来
    func testCollapseStateInheritedWhenHeadingShifted() {
        let old = makeItems(treeSpecs)
        // 模拟「在第一个标题上面打了 13 个字」：所有偏移整体后移 13
        let shifted = treeSpecs.enumerated().map { index, spec in
            OutlineItem(id: UUID(),
                        level: spec.level,
                        title: spec.title,
                        sourceOffset: index * 100 + 13)
        }

        let inherited = OutlineCollapseState.inherit(from: old,
                                                    collapsedIDs: [old[4].id],
                                                    to: shifted)
        XCTAssertEqual(inherited, [shifted[4].id], "标题被顶移了，折叠状态要跟着走")
    }

    /// 标题被删掉了 → 折叠状态也得丢掉（否则会在别的标题上冒出来）
    func testCollapseStateDroppedWhenHeadingDeleted() {
        let old = makeItems(treeSpecs)
        let remaining = makeItems([(1, "第一章"), (2, "第一章第一节"),
                                   (2, "第一章第二节"), (3, "第一章第二节之一")])

        let inherited = OutlineCollapseState.inherit(from: old,
                                                    collapsedIDs: [old[4].id],
                                                    to: remaining)
        XCTAssertTrue(inherited.isEmpty, "B 已经被删了，它的折叠状态不该留给别人")
    }

    /// 既改了名又被顶移 → 两条规则都认不出来，宁可丢掉也不要认错
    func testCollapseStateDroppedWhenHeadingRenamedAndShifted() {
        let old = makeItems(treeSpecs)
        let changed = treeSpecs.enumerated().map { index, spec in
            OutlineItem(id: UUID(),
                        level: spec.level,
                        title: index == 4 ? "换了个完全不同的标题" : spec.title,
                        sourceOffset: index * 100 + 7)
        }

        let inherited = OutlineCollapseState.inherit(from: old,
                                                    collapsedIDs: [old[4].id],
                                                    to: changed)
        XCTAssertTrue(inherited.isEmpty,
                      "认不出来时清理掉即可；认错了会让折叠状态跑到别的标题上，更烦人")
    }

    // MARK: - 第 3 层：目录面板的交互

    /// 三角只出现在「还有子标题的 H1-H5」上；叶子行和 H6 都没有
    func testDisclosureOnlyOnRowsThatHaveChildren() {
        let (view, host) = makeOutlineView()
        view.updateOutlineItems(makeItems([(1, "甲"), (2, "甲一"), (3, "甲一一"), (1, "乙")]))
        host.layoutIfNeeded()

        let rows = rowViews(in: view)
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows[0].isDisclosureVisible, "H1 底下有 H2，该有三角")
        XCTAssertTrue(rows[1].isDisclosureVisible, "H2 底下有 H3，该有三角")
        XCTAssertFalse(rows[2].isDisclosureVisible, "H3 是叶子，折起来什么都不会变")
        XCTAssertFalse(rows[3].isDisclosureVisible, "「乙」底下没有子标题")
    }

    /// H6 是最深一层，永远不该有三角（需求里的「H1-H5 才折叠」在这里锁住）
    func testH6NeverShowsDisclosure() {
        let (view, host) = makeOutlineView()
        view.updateOutlineItems(makeItems([(5, "五级"), (6, "六级")]))
        host.layoutIfNeeded()

        let rows = rowViews(in: view)
        XCTAssertTrue(rows[0].isDisclosureVisible, "H5 底下有 H6，该有三角")
        XCTAssertFalse(rows[1].isDisclosureVisible, "H6 不可能有子标题")
    }

    /// 点三角 → 折起整棵子树；再点一下 → 又回来了
    func testTappingDisclosureFoldsAndUnfolds() {
        let (view, host) = makeOutlineView()
        let items = makeItems(treeSpecs)
        view.updateOutlineItems(items)
        host.layoutIfNeeded()
        XCTAssertEqual(rowViews(in: view).count, 6)

        rowViews(in: view)[0].tapDisclosure()
        host.layoutIfNeeded()
        XCTAssertEqual(rowViews(in: view).map { $0.item?.title },
                       ["第一章", "第二章", "第二章第一节"],
                       "折了 A 之后 A1 / A2 / A2a 都该消失")
        XCTAssertTrue(view.isCollapsed(id: items[0].id))

        rowViews(in: view)[0].tapDisclosure()
        host.layoutIfNeeded()
        XCTAssertEqual(rowViews(in: view).count, 6, "再点一下应该全部展开回来")
        XCTAssertFalse(view.isCollapsed(id: items[0].id))
    }

    /// 点三角是「折叠」，不是「跳到这个标题」—— 两个热区要分得开
    func testTappingDisclosureDoesNotSelectRow() {
        let (view, host) = makeOutlineView()
        let delegate = SpyOutlineViewDelegate()
        view.delegate = delegate
        view.updateOutlineItems(makeItems(treeSpecs))
        host.layoutIfNeeded()

        rowViews(in: view)[0].tapDisclosure()
        XCTAssertTrue(delegate.selected.isEmpty, "点折叠三角不该触发跳转")

        // 而点整行仍然是跳转（别顺手把原来的功能弄坏了）
        rowViews(in: view)[0].sendActions(for: .touchUpInside)
        XCTAssertEqual(delegate.selected.map(\.title), ["第一章"])
    }

    /// 折叠之后卡片要跟着变矮 —— 行少了高度还算原来那么多的话，
    /// 下面会多出一大片空白（而且面板会盖住正文）
    func testPanelShrinksAfterFolding() {
        let (view, host) = makeOutlineView()
        let items = makeItems(treeSpecs)
        view.updateOutlineItems(items)
        host.layoutIfNeeded()

        let before = view.panelHeight
        view.toggleCollapse(id: items[0].id)
        host.layoutIfNeeded()
        let after = view.panelHeight

        XCTAssertGreaterThan(before, 0, "测试前提：应该能读到卡片高度")
        XCTAssertLessThan(after, before,
                          "折了 3 行之后卡片还是 \(after) 点高（原来 \(before)），高度没跟着行数走")
    }

    /// 当前高亮的行被折叠藏起来时，高亮要往上跑到那个可见的祖先行上
    func testHighlightFallsBackToVisibleAncestor() {
        let (view, host) = makeOutlineView()
        let items = makeItems(treeSpecs)
        view.updateOutlineItems(items)
        host.layoutIfNeeded()

        view.highlightOutlineItem(items[3].id)      // 光标在 A2a 这一节
        XCTAssertEqual(highlightedTitles(in: view), ["第一章第二节之一"])

        view.toggleCollapse(id: items[2].id)        // 把 A2 折起来
        host.layoutIfNeeded()
        XCTAssertEqual(highlightedTitles(in: view), ["第一章第二节"],
                       "目标行藏起来了，该点亮它上面那个可见的祖先")

        view.toggleCollapse(id: items[0].id)        // 连着把 A 也折起来
        host.layoutIfNeeded()
        XCTAssertEqual(highlightedTitles(in: view), ["第一章"],
                       "连着折两层时，真正显示着的是最外面那个")
    }

    /// 折叠之后高亮不能凭空消失（行是整批重建的，得自己补回来）
    func testHighlightSurvivesFolding() {
        let (view, host) = makeOutlineView()
        let items = makeItems(treeSpecs)
        view.updateOutlineItems(items)
        host.layoutIfNeeded()

        view.highlightOutlineItem(items[1].id)      // A1，和折叠的那支无关
        view.toggleCollapse(id: items[2].id)        // 折 A2
        host.layoutIfNeeded()

        XCTAssertEqual(highlightedTitles(in: view), ["第一章第一节"],
                       "折别人的时候，当前章节的底色不该跟着掉")
    }

    /// 编辑之后列表整份换新（条目全是新实例、新 UUID），折叠状态要活下来
    func testFoldSurvivesListRebuildWithNewIDs() {
        let (view, host) = makeOutlineView()
        let first = makeItems(treeSpecs)
        view.updateOutlineItems(first)
        host.layoutIfNeeded()
        view.toggleCollapse(id: first[0].id)
        host.layoutIfNeeded()
        XCTAssertEqual(rowViews(in: view).map { $0.item?.title },
                       ["第一章", "第二章", "第二章第一节"])

        let rebuilt = makeItems(treeSpecs)
        XCTAssertNotEqual(rebuilt.map(\.id), first.map(\.id), "测试前提：重建后 id 必须变了")
        view.updateOutlineItems(rebuilt)
        host.layoutIfNeeded()

        XCTAssertEqual(rowViews(in: view).map { $0.item?.title },
                       ["第一章", "第二章", "第二章第一节"],
                       "列表重建后折叠丢了 —— 用户会觉得「我折好的又自己弹开了」")
    }

    /// 换文档时要能一把清干净（否则上一份文档的折叠会落到新文档同位置的标题上）
    func testResetFoldingClearsEverything() {
        let (view, host) = makeOutlineView()
        let items = makeItems(treeSpecs)
        view.updateOutlineItems(items)
        host.layoutIfNeeded()
        view.toggleCollapse(id: items[0].id)
        host.layoutIfNeeded()
        XCTAssertEqual(rowViews(in: view).count, 3)

        view.resetFolding()
        view.updateOutlineItems(makeItems(treeSpecs))
        host.layoutIfNeeded()

        XCTAssertEqual(rowViews(in: view).count, 6, "清空之后应该全部展开")
    }

    /// 造一串「够长、又能折」的标题：每节一个 H1 带一个 H2
    private func makeLongFoldableList(_ sections: Int) -> [OutlineItem] {
        var specs: [(level: Int, title: String)] = []
        for index in 1...sections {
            specs.append((1, "第 \(index) 节"))
            specs.append((2, "第 \(index) 节的正文段"))
        }
        return makeItems(specs)
    }

    // MARK: - 第 3 层补测：列表滚动位置

    /// 列表被换掉之后要保持滚动位置（「记住滚动位置」打开时，默认就是开的）
    func testScrollOffsetSurvivesUpdateWhenRemembering() throws {
        let (view, host) = makeOutlineView()
        view.updateOutlineItems(makeLongList(40))
        host.layoutIfNeeded()

        let scrollView = try XCTUnwrap(firstScrollView(in: view), "视图树里找不到列表的滚动视图")
        XCTAssertGreaterThan(scrollView.contentSize.height, scrollView.bounds.height,
                             "测试前提：列表得真的能滚")

        scrollView.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        XCTAssertEqual(scrollView.contentOffset.y, 120, accuracy: 0.5, "测试前提：偏移得设得进去")

        view.updateOutlineItems(makeLongList(40))
        host.layoutIfNeeded()

        XCTAssertEqual(scrollView.contentOffset.y, 120, accuracy: 0.5,
                       "列表刷新之后位置被甩回顶部了")
    }

    /// 关掉「记住滚动位置」→ 列表刷新后回到顶部
    func testScrollOffsetResetsWhenNotRemembering() throws {
        let (view, host) = makeOutlineView()
        view.remembersScrollPosition = false
        view.updateOutlineItems(makeLongList(40))
        host.layoutIfNeeded()

        let scrollView = try XCTUnwrap(firstScrollView(in: view), "视图树里找不到列表的滚动视图")
        scrollView.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        XCTAssertEqual(scrollView.contentOffset.y, 120, accuracy: 0.5, "测试前提：偏移得设得进去")

        view.updateOutlineItems(makeLongList(40))
        host.layoutIfNeeded()

        XCTAssertEqual(scrollView.contentOffset.y, 0, accuracy: 0.5,
                       "关掉「记住位置」之后，列表刷新应该回到顶部")
    }

    /// 但「我自己在列表里折叠」永远不能把位置甩走 —— 手指刚点的地方不能跑
    func testFoldingKeepsScrollPositionEvenWhenNotRemembering() throws {
        let (view, host) = makeOutlineView()
        view.remembersScrollPosition = false
        let items = makeLongFoldableList(15)
        view.updateOutlineItems(items)
        host.layoutIfNeeded()

        let scrollView = try XCTUnwrap(firstScrollView(in: view), "视图树里找不到列表的滚动视图")
        XCTAssertGreaterThan(scrollView.contentSize.height, scrollView.bounds.height,
                             "测试前提：列表得真的能滚")
        scrollView.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        XCTAssertEqual(scrollView.contentOffset.y, 120, accuracy: 0.5, "测试前提：偏移得设得进去")

        view.toggleCollapse(id: items[0].id)     // 折掉第一节
        host.layoutIfNeeded()

        XCTAssertEqual(scrollView.contentOffset.y, 120, accuracy: 0.5,
                       "折叠是用户自己在操作列表，不该把列表甩回顶部")
    }

    /// 三角真的能吃到手点的那些点击。
    ///
    /// ### 为什么单测里 `sendActions` 还不够
    /// `sendActions(for: .touchUpInside)` 是**直接**把事件发给那个按钮，绕过了命中测试。
    /// 所以就算三角被什么挡住、或者热区其实是整行在吃点击，那些用例照样绿。
    /// 这条改成直接问 `hitTest`：「按在这个坐标上，事件会落到谁手里」——
    /// 落到按钮上才是真的能点。
    func testDisclosureButtonActuallyReceivesTaps() throws {
        let (view, host) = makeOutlineView()
        view.updateOutlineItems(makeItems(treeSpecs))
        host.layoutIfNeeded()

        let row = try XCTUnwrap(rowViews(in: view).first)
        XCTAssertGreaterThan(row.bounds.width, 0, "测试前提：行得真的排过版")

        // 右边那一条（三角所在的 24pt 热区）→ 不该落到整行上
        for offset in [6.0, 14.0] {
            let point = CGPoint(x: row.bounds.maxX - offset, y: row.bounds.midY)
            let hit = row.hitTest(point, with: nil)
            XCTAssertFalse(hit === row,
                           "点 x=\(point.x) 落到了整行上（走的是「跳转」那条路），三角点不到")
        }

        // 左边那块（标题文字一带）→ 仍然要落到整行上，跳转功能别被挤掉
        let titlePoint = CGPoint(x: 20, y: row.bounds.midY)
        XCTAssertTrue(row.hitTest(titlePoint, with: nil) === row,
                      "标题那一段应该还是整行吃点击（点了要能跳转）")
    }

    // MARK: - 小工具

    /// 把一个目录面板按**和 App 里一样的约束**挂到一个真实窗口上。
    ///
    /// ### 为什么要挂到 `UIWindow` 而不是普通 `UIView`
    /// 要断言滚动位置、内容尺寸这些**真实几何**的用例，必须有一次真正的布局。
    /// 只挂在一个普通视图上时，`layoutIfNeeded()` 未必会把整棵子树的尺寸都算出来，
    /// 读到的 `contentSize` 是「只剩内边距」的假值（踩过一次）。
    /// 挂到窗口上就和真实运行时一致了 —— 编辑器那边的测试也是这么挂的。
    ///
    /// ### 为什么不给它设一个固定 frame
    /// 这个面板的尺寸反过来由它自己那条宽高约束决定（外层视图是被面板「撑」出来的）：
    /// 面板四边钉在 `MarkdownOutlineView` 上，面板自己又带宽高约束。
    /// 硬给外层视图设一个 300 高的 frame，等于再加一条「高度必须 300」的硬约束
    /// 去跟面板的约束打架，Auto Layout 会丢掉一条 —— 于是出现「折叠之后卡片高度不变」
    /// 这种像是 bug 的现象，其实是测试挂法不对
    /// （真实界面里 `ViewController.setupOutline` 也只给它定位、不给尺寸）。
    private func makeOutlineView() -> (view: MarkdownOutlineView, host: UIWindow) {
        let host = UIWindow(frame: CGRect(x: 0, y: 0, width: 700, height: 800))
        let view = MarkdownOutlineView()
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor)
        ])
        host.makeKeyAndVisible()
        host.layoutIfNeeded()
        return (view, host)
    }

    /// 按显示顺序取出界面上的所有行
    private func rowViews(in view: UIView) -> [OutlineRowView] {
        guard let stack = firstVerticalStack(in: view) else { return [] }
        return stack.arrangedSubviews.compactMap { $0 as? OutlineRowView }
    }

    /// 当前高亮的那几行（正常应该正好 0 或 1 行）的标题
    private func highlightedTitles(in view: UIView) -> [String] {
        rowViews(in: view).filter(\.isRowHighlighted).compactMap { $0.item?.title }
    }

    private func firstVerticalStack(in view: UIView) -> UIStackView? {
        for subview in view.subviews {
            if let stack = subview as? UIStackView, stack.axis == .vertical { return stack }
            if let found = firstVerticalStack(in: subview) { return found }
        }
        return nil
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        for subview in view.subviews {
            if let scroll = subview as? UIScrollView { return scroll }
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

}

// MARK: - 测试替身

/// 记录目录报出来的点击
@MainActor
private final class SpyOutlineViewDelegate: MarkdownOutlineViewDelegate {
    private(set) var selected: [OutlineItem] = []

    func outlineView(_ view: MarkdownOutlineDisplaying, didSelect item: OutlineItem) {
        selected.append(item)
    }
}
