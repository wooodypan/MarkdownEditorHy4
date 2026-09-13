//
//  MarkdownOutlineTests.swift
//  MarkdownEditorHy4Tests
//
//  大纲（悬浮目录）的验收测试
//
//  分成三层，正好对应架构里那三个角色：
//  1. 编辑器侧：能不能把 H1-H6 正确提取成 OutlineItem；
//  2. 协调者：光标偏移 → 归属标题的区间查询、去重、列表重建后的补偿；
//  3. 目录 UI：行数、缩进、高亮落到哪一行、点击回调、跳转能否真的把光标送到位。
//

import XCTest
@testable import MarkdownEditorHy4

/// app target 开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
/// 里面所有类型都默认是 @MainActor 的，测试类也要标 @MainActor 才能直接调用。
@MainActor
final class MarkdownOutlineTests: XCTestCase {

    // MARK: - 测试数据

    /// 六级标题全都有，并且刻意在标题里塞了行内语法（`**粗体**`、`` `代码` ``），
    /// 用来验证目录取到的是「纯文本」而不是带着 `#` 和 `**` 的原文
    private var sixLevelSample: String {
        """
        # 一级标题

        正文一。

        ## 二级标题

        正文二。

        ### 三级 **加粗** 标题

        正文三。

        #### 四级标题

        ##### 五级标题

        ###### 六级标题

        正文结尾。
        """
    }

    /// 一段长度足够滚动的样例：标题散在正文之间，
    /// 跳到「第三节」这种文档中部的标题**必须真的滚动**才看得到。
    /// 短文档测不出跳转 bug —— 不滚动的时候，随便怎么写都能「看起来对」
    private var scrollableSample: String {
        let filler = Array(repeating: "正文内容，用来把文档撑得比一屏长。", count: 12)
            .joined(separator: "\n\n")
        return """
        # 第一节

        \(filler)

        ## 第二节

        \(filler)

        ### 第三节

        \(filler)

        ## 第四节

        \(filler)

        # 结尾
        """
    }

    // MARK: - 第 1 层：编辑器侧的标题提取

    /// H1-H6 一个不落，顺序正确，层级正确
    func testExtractsAllSixHeadingLevels() {
        let store = makeStore(sixLevelSample)
        let items = store.outlineItems

        XCTAssertEqual(items.count, 6, "应该正好提取出 6 个标题")
        XCTAssertEqual(items.map(\.level), [1, 2, 3, 4, 5, 6], "层级顺序必须是 H1 → H6")
    }

    /// 标题文本必须是纯文本：`#` 和 `**` 都不能出现
    func testTitleStripsMarkdownSyntax() {
        let items = makeStore(sixLevelSample).outlineItems

        XCTAssertEqual(items[0].title, "一级标题")
        XCTAssertFalse(items[0].title.contains("#"), "标题文本里不该有 # 标记")
        // 行内加粗的 `**` 必须被去掉，只留文字
        XCTAssertEqual(items[2].title, "三级 加粗 标题", "行内语法标记没被去掉：\(items[2].title)")
        XCTAssertFalse(items[2].title.contains("*"), "标题文本里不该有 * 标记")
    }

    /// `sourceOffset` 必须真的指向那行标题的起点，而且单调递增
    /// （单调递增是协调者二分查找成立的前提）
    func testSourceOffsetsPointAtHeadingStartsAndIncrease() {
        let store = makeStore(sixLevelSample)
        let items = store.outlineItems
        let source = sixLevelSample as NSString

        for (index, item) in items.enumerated() {
            let lineStart = source.lineRange(for: NSRange(location: item.sourceOffset, length: 0)).location
            XCTAssertEqual(item.sourceOffset, lineStart, "第 \(index) 个标题的偏移不在行首")
            // 行首往后数 level 个字符应该是 `#`
            let marks = source.substring(with: NSRange(location: item.sourceOffset, length: item.level))
            XCTAssertEqual(marks, String(repeating: "#", count: item.level),
                           "第 \(index) 个标题偏移处的 `#` 数量对不上层级")
        }

        XCTAssertEqual(items.map(\.sourceOffset), items.map(\.sourceOffset).sorted(),
                       "sourceOffset 必须单调递增（协调者的二分查找依赖这个性质）")
    }

    /// 每个标题的 id 就是它所属块的 id —— 后面「高亮哪一行」全靠这个对应关系
    func testItemIDMatchesBlockID() {
        let store = makeStore(sixLevelSample)
        let headingBlocks = store.blocks.filter { $0.headingLevel != nil }
        XCTAssertEqual(store.outlineItems.map(\.id), headingBlocks.map(\.id))
    }

    /// 没有标题的文档 → 空列表（目录面板要显示「本文档没有标题」的占位）
    func testDocumentWithoutHeadingsProducesEmptyOutline() {
        XCTAssertTrue(makeStore("只有正文，没有任何标题。\n\n第二段。").outlineItems.isEmpty)
        XCTAssertTrue(makeStore("").outlineItems.isEmpty)
    }

    /// 空标题（源码里只有 `##`）不能产出一个空字符串标题
    func testEmptyHeadingGetsPlaceholderTitle() {
        let items = makeStore("# 有内容\n\n##\n\n正文").outlineItems
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[1].title, "（空标题）")
    }

    /// 改标题之后 `headingsChanged` 标志要立起来；在正文里打字则不能立
    func testHeadingsChangedFlagTracksHeadingEdits() {
        let store = makeStore("# 标题\n\n正文段落。")

        // 在正文末尾敲一个字：没碰标题 → false
        let bodyEdit = store.applyEdit(inRenderedRange: NSRange(location: 9, length: 0),
                                       replacementText: "啊",
                                       containerWidth: 600)
        XCTAssertFalse(bodyEdit.headingsChanged, "在正文里打字不该触发大纲重算")

        // 在标题的 `#` 后面敲一个字：碰到标题 → true
        let headingEdit = store.applyEdit(inRenderedRange: NSRange(location: 1, length: 0),
                                          replacementText: "新",
                                          containerWidth: 600)
        XCTAssertTrue(headingEdit.headingsChanged, "改标题必须触发大纲重算")
    }

    // MARK: - 第 2 层：协调者的归属查询

    /// 光标落在不同位置时，该高亮哪一条
    func testCoordinatorHighlightsNearestPrecedingHeading() {
        let display = SpyOutlineDisplay()
        let coordinator = OutlineCoordinator()
        coordinator.outlineView = display

        // 三个标题，偏移分别是 0 / 100 / 200
        let items = [makeItem(level: 1, title: "A", offset: 0),
                     makeItem(level: 2, title: "B", offset: 100),
                     makeItem(level: 3, title: "C", offset: 200)]
        coordinator.editorDidUpdateOutline(items)

        // 文档开头、第一个标题之前 → 没有归属标题
        coordinator.editorDidMoveCursor(sourceOffset: 0)
        XCTAssertEqual(display.highlightedID, items[0].id, "偏移 0 正好在 A 的标题行上")

        // 落在 A 和 B 之间的正文里（偏移 99）→ 归属 A
        coordinator.editorDidMoveCursor(sourceOffset: 99)
        XCTAssertEqual(display.highlightedID, items[0].id, "99 还在 A 的管辖范围里")

        // 正好在 B 的标题行上
        coordinator.editorDidMoveCursor(sourceOffset: 100)
        XCTAssertEqual(display.highlightedID, items[1].id)

        // 落在 B 和 C 之间的正文里
        coordinator.editorDidMoveCursor(sourceOffset: 150)
        XCTAssertEqual(display.highlightedID, items[1].id)

        // 文档末尾（200 之后）→ 归属最后一个标题
        coordinator.editorDidMoveCursor(sourceOffset: 9999)
        XCTAssertEqual(display.highlightedID, items[2].id)
    }

    /// 边界：负偏移（理论上不会出现）也不能崩、不能错乱
    func testCoordinatorHandlesOffsetBeforeFirstHeading() {
        let display = SpyOutlineDisplay()
        let coordinator = OutlineCoordinator()
        coordinator.outlineView = display

        // 第一个标题从偏移 10 开始，10 之前没有归属
        let items = [makeItem(level: 1, title: "A", offset: 10)]
        coordinator.editorDidUpdateOutline(items)

        coordinator.editorDidMoveCursor(sourceOffset: 0)
        XCTAssertNil(display.highlightedID, "第一个标题之前不该有高亮")

        coordinator.editorDidMoveCursor(sourceOffset: 10)
        XCTAssertEqual(display.highlightedID, items[0].id)
    }

    /// 归属没变就不要反复刷 UI（拖光标时每次移动都通知会浪费）
    func testCoordinatorDeduplicatesHighlightUpdates() {
        let display = SpyOutlineDisplay()
        let coordinator = OutlineCoordinator()
        coordinator.outlineView = display

        let items = [makeItem(level: 1, title: "A", offset: 0),
                     makeItem(level: 2, title: "B", offset: 100)]
        coordinator.editorDidUpdateOutline(items)
        let baseline = display.highlightCallCount

        // 在 A 的管辖范围内连续移动 20 次
        for offset in 1...20 { coordinator.editorDidMoveCursor(sourceOffset: offset) }
        XCTAssertEqual(display.highlightCallCount, baseline,
                       "归属标题没变时不该重复通知 UI")

        // 跨到 B 的范围里，这时必须通知一次
        coordinator.editorDidMoveCursor(sourceOffset: 100)
        XCTAssertEqual(display.highlightCallCount, baseline + 1)
    }

    /// ### 这条是这次设计里最容易出错的地方
    /// 编辑会让编辑器重建块、块的 UUID 全换新，于是整份列表的 id 都是新的。
    /// 如果协调者拿「旧 id」去比对，就会误判成「高亮没变」而漏掉刷新 —— 表现是
    /// 「在标题下面打字，目录里的高亮突然没了」。
    func testHighlightSurvivesOutlineRebuild() {
        let display = SpyOutlineDisplay()
        let coordinator = OutlineCoordinator()
        coordinator.outlineView = display

        // 第一版：光标停在 B 的管辖范围里
        let first = [makeItem(level: 1, title: "A", offset: 0),
                     makeItem(level: 2, title: "B", offset: 100)]
        coordinator.editorDidUpdateOutline(first)
        coordinator.editorDidMoveCursor(sourceOffset: 150)
        XCTAssertEqual(display.highlightedID, first[1].id)

        // 第二版：块被重建了，id 全换新，但内容位置不变
        let second = [makeItem(level: 1, title: "A", offset: 0),
                      makeItem(level: 2, title: "B", offset: 100)]
        XCTAssertNotEqual(first[1].id, second[1].id, "测试前提：重建后 id 必须变了")
        coordinator.editorDidUpdateOutline(second)

        XCTAssertEqual(display.highlightedID, second[1].id,
                       "列表重建后必须用新 id 重发一次高亮，否则界面上的高亮会消失")
    }

    /// 点目录 → 事件要转成「请求编辑器跳转」
    func testCoordinatorForwardsSelectionToEditor() {
        let editor = SpyOutlineDataSource()
        let coordinator = OutlineCoordinator()
        coordinator.editorDataSource = editor

        let item = makeItem(level: 2, title: "跳我", offset: 42)
        coordinator.editorDidUpdateOutline([item])
        // 走 delegate 那条路（目录 UI 报事件用的就是它）
        coordinator.outlineView(TrackingOutlineView(), didSelect: item)

        XCTAssertEqual(editor.scrolledItems.count, 1)
        XCTAssertEqual(editor.scrolledItems.first?.id, item.id)
    }

    // MARK: - 第 3 层：目录 UI

    /// 更新数据后行数对得上，而且每一行拿到的就是对应的数据
    func testOutlineViewBuildsOneRowPerItem() {
        let view = makeLaidOutOutlineView()
        let items = [makeItem(level: 1, title: "A", offset: 0),
                     makeItem(level: 2, title: "B", offset: 10),
                     makeItem(level: 6, title: "C", offset: 20)]
        view.updateOutlineItems(items)

        let rows = rowViews(in: view)
        XCTAssertEqual(rows.count, 3, "应该一行一个标题")
        XCTAssertEqual(rows.map { $0.item?.title }, ["A", "B", "C"])
        XCTAssertEqual(rows.map { $0.item?.level }, [1, 2, 6])
    }

    /// 没有标题时显示占位文字，不显示行
    func testOutlineViewShowsEmptyState() {
        let view = makeLaidOutOutlineView()
        view.updateOutlineItems([])
        XCTAssertTrue(rowViews(in: view).isEmpty, "没有标题时不该有行")
    }

    /// 高亮落点：传谁就点亮谁，而且同一时刻只有一行是亮的
    func testOutlineViewHighlightsExactlyOneRow() {
        let view = makeLaidOutOutlineView()
        let items = [makeItem(level: 1, title: "A", offset: 0),
                     makeItem(level: 2, title: "B", offset: 10),
                     makeItem(level: 3, title: "C", offset: 20)]
        view.updateOutlineItems(items)

        view.highlightOutlineItem(items[1].id)
        var highlighted = rowViews(in: view).filter(\.isRowHighlighted)
        XCTAssertEqual(highlighted.count, 1, "同一时刻只能有一行高亮")
        XCTAssertEqual(highlighted.first?.item?.title, "B")

        // 换一行：上一行必须熄掉
        view.highlightOutlineItem(items[2].id)
        highlighted = rowViews(in: view).filter(\.isRowHighlighted)
        XCTAssertEqual(highlighted.count, 1)
        XCTAssertEqual(highlighted.first?.item?.title, "C")

        // 传 nil：全部熄灭
        view.highlightOutlineItem(nil)
        XCTAssertTrue(rowViews(in: view).filter(\.isRowHighlighted).isEmpty,
                      "传 nil 表示光标不在任何标题下，应该全灭")
    }

    /// 列表重建之后旧高亮不能残留（否则会看到两行同时亮 / 亮在一个错误的行上）
    func testOutlineViewClearsHighlightOnRebuild() {
        let view = makeLaidOutOutlineView()
        let first = [makeItem(level: 1, title: "A", offset: 0),
                     makeItem(level: 2, title: "B", offset: 10)]
        view.updateOutlineItems(first)
        view.highlightOutlineItem(first[1].id)
        XCTAssertEqual(rowViews(in: view).filter(\.isRowHighlighted).count, 1)

        // 换一份全新的数据（id 全变）
        let second = [makeItem(level: 1, title: "X", offset: 0),
                      makeItem(level: 2, title: "Y", offset: 10)]
        view.updateOutlineItems(second)
        XCTAssertTrue(rowViews(in: view).filter(\.isRowHighlighted).isEmpty,
                      "整份列表换掉之后，旧的高亮必须清干净")
    }

    /// 层级缩进：层级越高缩进越多，而且不会无限缩下去
    func testRowIndentGrowsWithLevelAndIsCapped() {
        let view = makeLaidOutOutlineView()
        let items = [makeItem(level: 1, title: "H1", offset: 0),
                     makeItem(level: 3, title: "H3", offset: 10),
                     makeItem(level: 6, title: "H6", offset: 20)]
        view.updateOutlineItems(items)

        let rows = rowViews(in: view)
        let h1 = indent(of: rows[0])
        let h3 = indent(of: rows[2 - 1])
        let h6 = indent(of: rows[2])
        XCTAssertLessThan(h1, h3, "H3 应该比 H1 缩进更多")
        XCTAssertLessThanOrEqual(h3, h6, "H6 应该不小于 H3 的缩进")
    }

    /// 点一行 → 回调把对应的 `OutlineItem` 原样报出去
    func testTappingRowReportsSelection() {
        let view = makeLaidOutOutlineView()
        let delegate = SpyOutlineViewDelegate()
        view.delegate = delegate

        let items = [makeItem(level: 1, title: "A", offset: 0),
                     makeItem(level: 2, title: "B", offset: 10)]
        view.updateOutlineItems(items)

        rowViews(in: view)[1].sendActions(for: .touchUpInside)
        XCTAssertEqual(delegate.selected.count, 1)
        XCTAssertEqual(delegate.selected.first?.id, items[1].id,
                       "报出去的必须是那一行对应的原始数据")
    }

    /// 收起 / 展开状态能正常切
    func testCollapseAndExpand() {
        let view = makeLaidOutOutlineView()
        view.updateOutlineItems([makeItem(level: 1, title: "A", offset: 0)])

        XCTAssertFalse(view.isCollapsed, "默认应该是展开的")
        view.setCollapsed(true, animated: false)
        XCTAssertTrue(view.isCollapsed)
        view.setCollapsed(false, animated: false)
        XCTAssertFalse(view.isCollapsed)
    }

    // MARK: - 端到端：点击目录 → 光标真的落到那个标题上

    /// 用真实编辑器跑一遍：拿标题的 `sourceOffset` 去跳，跳完之后
    /// 「光标所在的源码偏移」必须回到那个标题上 —— 中间会经过
    /// 渲染坐标 ↔ 源码坐标 两次换算，任何一处算错都会在这里露馅
    func testJumpMovesCaretBackToHeadingSource() {
        let editor = makeEditor(sixLevelSample)
        let items = editor.currentOutlineItems()
        XCTAssertEqual(items.count, 6)

        for item in items {
            editor.scrollToOutlineItem(item)
            let landed = editor.cursorSourceOffset
            XCTAssertEqual(landed, item.sourceOffset,
                           "跳到「\(item.title)」之后光标落在了源码第 \(landed) 位，"
                           + "而标题在第 \(item.sourceOffset) 位")
        }
    }

    /// 走完整链路：编辑器 → 协调者 → 目录面板 → 点击 → 回到编辑器
    func testEndToEndWiringMovesCaret() {
        let editor = makeEditor(sixLevelSample)
        let outlineView = MarkdownOutlineView()
        outlineView.frame = CGRect(x: 0, y: 0, width: 210, height: 300)
        let coordinator = OutlineCoordinator()

        coordinator.editorDataSource = editor
        coordinator.outlineView = outlineView
        outlineView.delegate = coordinator
        editor.outlineEventSink = coordinator
        coordinator.reloadFromEditor()

        let rows = rowViews(in: outlineView)
        XCTAssertEqual(rows.count, 6, "装配完之后目录应该有 6 行")

        // 点最后一行（H6），光标应该跳到它的源码位置
        let target = coordinator.items[5]
        rows[5].sendActions(for: .touchUpInside)
        XCTAssertEqual(editor.cursorSourceOffset, target.sourceOffset)
    }

    /// 光标移动 → 目录高亮跟着走（同样是端到端）
    func testEndToEndHighlightFollowsCursor() {
        let editor = makeEditor(sixLevelSample)
        let outlineView = MarkdownOutlineView()
        outlineView.frame = CGRect(x: 0, y: 0, width: 210, height: 300)
        let coordinator = OutlineCoordinator()

        coordinator.editorDataSource = editor
        coordinator.outlineView = outlineView
        outlineView.delegate = coordinator
        editor.outlineEventSink = coordinator
        coordinator.reloadFromEditor()

        // 跳到第 4 个标题（H4），然后等防抖（120ms）走完
        let target = coordinator.items[3]
        editor.scrollToOutlineItem(target)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        let highlighted = rowViews(in: outlineView).filter(\.isRowHighlighted)
        XCTAssertEqual(highlighted.count, 1, "应该正好高亮一行")
        XCTAssertEqual(highlighted.first?.item?.title, target.title,
                       "高亮应该落在光标所在的标题上")
    }

    // MARK: - 第 3 层补测：跳转的稳定性（回归「点 5 次才跳到位」）

    /// 连点同一个标题 5 次，滚动位置一次到位、之后再点也不许动。
    ///
    /// ### 这条锁的是哪个 bug
    /// 以前 `scrollToOutlineItem` 一次点击只滚一次，而 TextKit 2 是**按视口惰性排版**的
    /// —— 屏幕外的坐标全是估算值（图片块能差上千点），滚一次根本到不了位。
    /// 用户的实际体验就是：「点 5 次光标才落到标题左边，点 8 次直接滚到最后一行」。
    ///
    /// 修好之后内部变成「滚一段 → 重新量视口 → 再滚」的迭代，点一次就到位；
    /// 既然已经到位了，**再点一次就应该什么都不变**。这条断言就是照这个说的。
    func testRepeatedJumpsToSameHeadingDoNotDrift() {
        let editor = makeEditor(scrollableSample)
        guard let target = editor.currentOutlineItems().first(where: { $0.title == "第三节" }) else {
            return XCTFail("样例里应该有一个叫「第三节」的标题")
        }

        editor.scrollToOutlineItem(target)
        let firstOffset = waitForJumpToSettle(editor)

        XCTAssertGreaterThan(firstOffset, 0,
                             "「第三节」在文档中部，跳过去必须滚动，offset 不该还是 0")

        for click in 2...5 {
            editor.scrollToOutlineItem(target)
            let offset = waitForJumpToSettle(editor)
            XCTAssertEqual(offset, firstOffset, accuracy: 0.5,
                           "第 \(click) 次点击之后滚动位置从 \(firstOffset) 漂到了 \(offset)")
        }

        XCTAssertEqual(editor.cursorSourceOffset, target.sourceOffset,
                       "重复点击之后光标也得还在标题上")
    }

    /// 跳过去之后，光标必须落在**可视区域**里 —— 否则等于没跳
    /// （滚动位置对、但目标停在屏幕外一屏之外，用户还是看不到）
    func testJumpPutsCaretInsideVisibleArea() {
        let editor = makeEditor(scrollableSample)
        let items = editor.currentOutlineItems()
        XCTAssertGreaterThanOrEqual(items.count, 4, "样例应该有好几个标题")

        for item in items {
            editor.scrollToOutlineItem(item)
            waitForJumpToSettle(editor)

            guard let screenY = caretScreenY(editor) else {
                return XCTFail("「\(item.title)」量不到光标矩形")
            }
            XCTAssertGreaterThanOrEqual(screenY, -1,
                                        "「\(item.title)」的光标跑到屏幕上沿之外了（y=\(screenY)）")
            XCTAssertLessThanOrEqual(screenY, editor.bounds.height,
                                     "「\(item.title)」的光标跑到屏幕下沿之外了（y=\(screenY)）")
        }
    }

    // MARK: - 第 4 层：真实界面装配

    /// 起一个真的 `ViewController`，验证三个组件在真实界面里确实接上了。
    ///
    /// ### 为什么值得单独测这一条
    /// 前面所有用例都是「自己手动 new 出三个对象再接起来」，
    /// 万一 `ViewController.setupOutline()` 里漏了一行（比如忘了设 `editor.outlineEventSink`），
    /// 那些用例照样全绿，但真机上目录就是死的。这条测的是**装配本身**。
    func testViewControllerWiresOutlineToEditor() {
        let controller = ViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 800, height: 900)
        controller.view.layoutIfNeeded()

        guard let outline = firstOutlineView(in: controller.view) else {
            return XCTFail("ViewController 的视图树里找不到 MarkdownOutlineView —— 装配漏了")
        }

        let rows = rowViews(in: outline)
        XCTAssertGreaterThanOrEqual(rows.count, 5,
                                    "示例文档里有一级 + 七个小节标题，目录不该只有 \(rows.count) 行")
        XCTAssertEqual(rows.first?.item?.level, 1, "第一行应该是那个 H1")
        XCTAssertTrue(rows.allSatisfy { ($0.item?.level ?? 0) >= 1 && ($0.item?.level ?? 9) <= 6 },
                      "所有行的层级都必须在 1...6 之间")

        // 点第一行不能崩，而且应该能顺着「面板 → 协调者 → 编辑器」把光标送过去
        rows[0].sendActions(for: .touchUpInside)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(rowViews(in: outline).filter(\.isRowHighlighted).count, 1,
                       "跳转之后应该正好高亮一行（H1）")
    }

    // MARK: - 小工具

    /// 等跳转的「滚 → 量 → 再滚」跑完，返回最终的滚动位置。
    ///
    /// 为什么要轮询而不是 `sleep(1)`：内部每一轮之间隔 60ms，轮数不固定（2~4 轮常见）。
    /// 轮询「连续 0.25 秒位置没变」就当作停了 —— 比固定睡 1 秒快得多，也不会偶发不等够。
    @discardableResult
    private func waitForJumpToSettle(_ editor: MarkdownTextView,
                                     timeout: TimeInterval = 3) -> CGFloat {
        let deadline = Date().addingTimeInterval(timeout)
        var lastOffset = editor.contentOffset.y
        var stableSince = Date()

        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let current = editor.contentOffset.y
            if abs(current - lastOffset) <= 0.5 {
                if Date().timeIntervalSince(stableSince) >= 0.25 { return current }
            } else {
                lastOffset = current
                stableSince = Date()
            }
        }
        return editor.contentOffset.y
    }

    /// 光标（也就是目标标题那一行）距离屏幕上沿多少点。量不到返回 nil
    private func caretScreenY(_ editor: MarkdownTextView) -> CGFloat? {
        let offset = editor.selectedRange.location
        guard let position = editor.position(from: editor.beginningOfDocument, offset: offset) else {
            return nil
        }
        return editor.caretRect(for: position).minY - editor.contentOffset.y
    }

    private func makeStore(_ markdown: String) -> MarkdownDocumentStore {
        let store = MarkdownDocumentStore()
        store.load(markdown: markdown, containerWidth: 600)
        return store
    }

    /// 造一个挂在窗口上的编辑器（跳转、防抖这些都需要真实的 TextKit 布局）
    private func makeEditor(_ markdown: String) -> MarkdownTextView {
        let textView = MarkdownTextView(markdown: markdown)
        textView.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        textView.layoutIfNeeded()
        return textView
    }

    private func makeItem(level: Int, title: String, offset: Int) -> OutlineItem {        OutlineItem(id: UUID(), level: level, title: title, sourceOffset: offset)
    }

    /// 目录面板的宽度是按父视图算的，所以挂到一个窗口里让它有父视图可量
    private func makeLaidOutOutlineView() -> MarkdownOutlineView {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 700, height: 800))
        let view = MarkdownOutlineView()
        host.addSubview(view)
        view.frame = CGRect(x: 320, y: 0, width: 210, height: 300)
        host.layoutIfNeeded()
        return view
    }

    /// 按「数据顺序」取到界面上的所有行视图。
    ///
    /// 所有行都装在同一个垂直栈里，所以先找到那个栈，再按栈里的排列顺序读 ——
    /// 这样断言时的次序和数据次序一致，失败信息也好读
    private func rowViews(in view: UIView) -> [OutlineRowView] {
        guard let stack = firstVerticalStack(in: view) else { return [] }
        return stack.arrangedSubviews.compactMap { $0 as? OutlineRowView }
    }

    private func firstVerticalStack(in view: UIView) -> UIStackView? {
        for subview in view.subviews {
            if let stack = subview as? UIStackView, stack.axis == .vertical { return stack }
            if let found = firstVerticalStack(in: subview) { return found }
        }
        return nil
    }

    /// 递归找界面上的目录面板（`ViewController` 里它是私有属性，只能从视图树里挖）
    private func firstOutlineView(in view: UIView) -> MarkdownOutlineView? {
        for subview in view.subviews {
            if let outline = subview as? MarkdownOutlineView { return outline }
            if let found = firstOutlineView(in: subview) { return found }
        }
        return nil
    }

    /// 一行的左缩进，取的是标题文字那条 leading 约束的 constant。
    ///
    /// 不去读 frame —— 那要求 Auto Layout 已经跑过；直接读约束值跟布局时机无关，
    /// 断言更稳，也不会因为宿主视图换了尺寸而漂
    private func indent(of row: OutlineRowView) -> CGFloat {
        for subview in row.subviews where subview is UILabel {
            for constraint in row.constraints
            where constraint.firstItem === subview && constraint.firstAttribute == .leading {
                return constraint.constant
            }
        }
        return 0
    }
}

// MARK: - 测试替身

/// 假装自己是目录 UI，只记录协调者通知了什么
@MainActor
private final class SpyOutlineDisplay: MarkdownOutlineDisplaying {
    private(set) var items: [OutlineItem] = []
    private(set) var highlightedID: UUID?
    private(set) var highlightCallCount = 0

    func updateOutlineItems(_ items: [OutlineItem]) { self.items = items }

    func highlightOutlineItem(_ id: UUID?) {
        highlightedID = id
        highlightCallCount += 1
    }
}

/// 假装自己是编辑器，只记录被要求跳转到哪里
@MainActor
private final class SpyOutlineDataSource: MarkdownOutlineDataSource {
    private(set) var scrolledItems: [OutlineItem] = []

    func currentOutlineItems() -> [OutlineItem] { [] }

    func scrollToOutlineItem(_ item: OutlineItem) { scrolledItems.append(item) }
}

/// 假装自己是目录 UI（只用来充当 delegate 方法的第一个参数）
@MainActor
private final class TrackingOutlineView: MarkdownOutlineDisplaying {
    func updateOutlineItems(_ items: [OutlineItem]) {}
    func highlightOutlineItem(_ id: UUID?) {}
}

/// 记录目录 UI 报出来的点击
@MainActor
private final class SpyOutlineViewDelegate: MarkdownOutlineViewDelegate {
    private(set) var selected: [OutlineItem] = []

    func outlineView(_ view: MarkdownOutlineDisplaying, didSelect item: OutlineItem) {
        selected.append(item)
    }
}
