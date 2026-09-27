//
//  MarkdownListContinuationTests.swift
//  MarkdownEditorHy4Tests
//
//  回车键的列表续写：在列表项里按回车自动带出下一项的标记，在空列表项上按回车退出列表。
//
//  ### 这里守的判据（都是用户看得见的）
//  1. `- 已完成` 末尾回车 → 源码变成 `- 已完成\n- `，光标停在新项的正文起点；
//  2. 有序列表序号要 +1，任务列表的新一项必须是**未完成**；
//  3. 嵌套列表的缩进要跟着抄到下一行，不能掉回最外层；
//  4. 空项上回车是「退出列表」—— 标记被吃掉，留一个空行；
//  5. 代码块里的 `- xxx` 只是代码，在那儿回车绝不能自动加标记；
//  6. 改完照样「全选复制 === 源文件」。
//
//  ⚠️ 光标偏移量按 **UTF-16 单元** 数（和 `NSRange` 同一套坐标），中文一个字算 1 个。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownListContinuationTests: XCTestCase {

    // MARK: - 判定器（纯字符串，不开 UI）

    /// 续写时要插的前缀
    private func insertPrefix(in continuation: MarkdownListContinuation?) -> String? {
        guard let continuation, case .insertItem(let prefix) = continuation.action else { return nil }
        return prefix
    }

    /// 退出列表时要删掉的源码范围
    private func exitRange(in continuation: MarkdownListContinuation?) -> NSRange? {
        guard let continuation, case .exitList(let range) = continuation.action else { return nil }
        return range
    }

    func testBulletItemContinuesWithSameMarker() {
        let source = "- 已完成"
        XCTAssertEqual(insertPrefix(in: .parse(source: source, caret: 5)), "- ")
    }

    func testOrderedItemIncrementsNumber() {
        let source = "1. 第一项"
        XCTAssertEqual(insertPrefix(in: .parse(source: source, caret: 6)), "2. ")
    }

    func testOrderedItemKeepsZeroPadding() {
        XCTAssertEqual(insertPrefix(in: .parse(source: "01. 第一项", caret: 7)), "02. ")
    }

    func testOrderedItemWithParenthesisDelimiter() {
        XCTAssertEqual(insertPrefix(in: .parse(source: "3) 第三项", caret: 6)), "4) ")
    }

    func testCheckedTaskItemContinuesUnchecked() {
        // 上一项勾了，新的一项也该是未勾的 —— 刚敲的回车不该顺手把勾也打上
        XCTAssertEqual(insertPrefix(in: .parse(source: "- [x] 已完成", caret: 9)), "- [ ] ")
    }

    func testNestedItemKeepsItsIndent() {
        XCTAssertEqual(insertPrefix(in: .parse(source: "  - 子项", caret: 6)), "  - ")
    }

    func testEmptyItemExitsList() {
        let source = "- 已完成\n- "
        let continuation = MarkdownListContinuation.parse(source: source, caret: 8)
        XCTAssertTrue(continuation?.isEmptyItem == true, "标记后面什么都没有，应该判成空项")
        XCTAssertEqual(exitRange(in: continuation), NSRange(location: 6, length: 2),
                       "退出列表删掉的就是 `- ` 这两个字符（缩进也算在标记范围里）")
    }

    func testEmptyNestedItemExitsWithIndent() {
        XCTAssertEqual(exitRange(in: .parse(source: "  - ", caret: 4)), NSRange(location: 0, length: 4))
    }

    func testMarkerWithoutSpaceIsNotAList() {
        XCTAssertNil(MarkdownListContinuation.parse(source: "-abc", caret: 4), "`-abc` 只是普通文字，不是列表项")
    }

    func testNumberWithoutDelimiterIsNotAList() {
        XCTAssertNil(MarkdownListContinuation.parse(source: "1.5 不是列表", caret: 3))
    }

    func testPlainParagraphIsNotAList() {
        XCTAssertNil(MarkdownListContinuation.parse(source: "正文一段", caret: 4))
    }

    func testCaretInsideCheckboxLiteralDoesNotContinue() {
        // 光标停在 `[ ]` 里面：那只是想在标记中间换行，不该插出第二个标记
        XCTAssertNil(MarkdownListContinuation.parse(source: "- [ ] 未完成", caret: 3))
    }

    func testSecondLineOfMultiLineItemIsNotAList() {
        // 悬挂缩进的续行（`  continued`）没有标记，回车只该换行
        XCTAssertNil(MarkdownListContinuation.parse(source: "- 第一项\n  续行", caret: 10))
    }

    func testOnlyTheLineUnderTheCaretIsConsidered() {
        XCTAssertEqual(insertPrefix(in: .parse(source: "- 第一项\n* 第二项", caret: 11)), "* ")
    }

    // MARK: - 走完整条编辑管线

    /// 造一个挂在窗口上的编辑器（要真实布局才会走完整条编辑管线）
    private func makeEditor(_ markdown: String) -> MarkdownTextView {
        let textView = MarkdownTextView(markdown: markdown)
        textView.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        textView.layoutIfNeeded()
        return textView
    }

    /// 把光标放到源码 `offset` 处，然后模拟按一次回车（走的就是 delegate 里那条路）
    @discardableResult
    private func pressEnter(atSourceOffset offset: Int, in textView: MarkdownTextView) -> Bool {
        let caret = textView.documentStore.renderedCaret(forSourceOffset: offset)
        textView.selectedRange = NSRange(location: caret, length: 0)
        return textView.applyListContinuationForNewline(at: caret)
    }

    func testEnterAtListEndAppendsNextMarker() {
        let textView = makeEditor("- 已完成")
        let store = textView.documentStore

        XCTAssertTrue(pressEnter(atSourceOffset: 5, in: textView), "列表项末尾的回车应该被接管")
        XCTAssertEqual(store.sourceDocument, "- 已完成\n- ", "源码里要真的多一个换行和下一个标记")
        // ⚠️ 空项也必须画出圆点（占位符 ￼ + 源码标记 `- `）：
        // 圆点是渲染串里多出来的一个字符，空项不画的话，在里面打第一个字时圆点凭空出现，渲染串就会比用户敲进去的字符多长 1 个 —— 系统按字符数记的撤销账当场对不上。
        XCTAssertTrue(textView.text.contains("\n\u{FFFC}- "), "新起的一行要连圆点一起画出来")

        let restored = store.sourceText(forRenderedRange: NSRange(location: 0, length: store.renderedLength))
        XCTAssertEqual(restored, store.sourceDocument, "续写之后「全选复制 === 源文件」还得成立")
    }

    func testEnterInMiddleOfItemSplitsIt() {
        let textView = makeEditor("- abcd")
        XCTAssertTrue(pressEnter(atSourceOffset: 4, in: textView))
        XCTAssertEqual(textView.documentStore.sourceDocument, "- ab\n- cd", "在项中间回车是「把这一项劈成两项」")
    }

    func testEnterOnEmptyItemExitsList() {
        let textView = makeEditor("- 已完成\n- ")
        let store = textView.documentStore

        XCTAssertTrue(pressEnter(atSourceOffset: 8, in: textView), "空列表项上的回车应该被接管")
        XCTAssertEqual(store.sourceDocument, "- 已完成\n", "空项上回车 = 退出列表：标记被吃掉，留一个空行")
    }

    func testEnterInsideCodeBlockDoesNothing() {
        let textView = makeEditor("```\n- 参数\n```\n")
        let store = textView.documentStore
        let before = store.sourceDocument

        XCTAssertFalse(pressEnter(atSourceOffset: 8, in: textView), "代码块里不该续写列表")
        XCTAssertEqual(store.sourceDocument, before, "源码一个字符都不该变（在 shell 代码块里敲回车凭空多出 `- `，代码就废了）")
    }

    func testEnterInPlainParagraphIsNotIntercepted() {
        let textView = makeEditor("正文一段\n")
        XCTAssertFalse(pressEnter(atSourceOffset: 4, in: textView), "普通段落里的回车归系统管")
    }

    // MARK: - 撤销链（用户真实操作序列）

    /// 挂到**真实窗口**上的编辑器 —— `UndoManager` 是从响应者链上取的，游离的 view 拿不到。
    private func makeEditorInRealWindow(_ markdown: String) -> MarkdownTextView? {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow })
                ?? UIApplication.shared.windows.first else { return nil }
        let textView = MarkdownTextView(markdown: markdown)
        textView.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        window.addSubview(textView)
        textView.layoutIfNeeded()
        return textView
    }

    /// 连按 ⌘Z 要能**一步步**退回最初：`回车 → 3 → 回车 → 4` 四次编辑，四步撤销。
    ///
    /// ### 这里踩过什么坑（撤销链断裂的根因，别再犯）
    /// 空列表项以前**不画圆点**（`- ` 就渲染成 `- `），可一旦在里面打了第一个字，它就变成正经列表项、圆点凭空冒出来 —— **用户只敲了 1 个字符，渲染串却长了 2 个**。
    /// 系统替键盘输入记的撤销账是「按插入时的字符数」记的，插 1 个就撤销 1 个，于是 ⌘Z 从这个多出来的字符里删错了地方，撤销链从此错位，再也退不回最初。
    /// 修法是让空列表项也画出标记（`scannedMarkerRange`），**渲染长度必须稳定**：
    /// 打字时渲染串长多少，就必须正好等于用户敲进去几个字符。
    ///
    /// ### 测试里为什么要手动管撤销分组
    /// 真机上每敲一个键是一个独立的 UI 事件，UIKit 会在事件结束时关掉撤销组；
    /// 而 XCTest 不派发真实事件，组一直关不上，四次编辑会被并成一条记录（表现为「一次 ⌘Z 就退到底」），看不出逐步撤销对不对。
    /// 所以关掉自动分组、每次按键自己包一层组，把真机的撤销粒度还原出来。
    func testUndoWalksBackThroughContinuationAndTyping() throws {
        guard let textView = makeEditorInRealWindow("- 1\n- 2") else {
            throw XCTSkip("拿不到真实窗口，没法验证撤销")
        }
        defer { textView.removeFromSuperview() }
        guard let undoManager = textView.undoManager else {
            throw XCTSkip("响应者链上没有 UndoManager")
        }
        undoManager.groupsByEvent = false

        textView.selectedRange = NSRange(location: textView.documentStore.renderedLength, length: 0)

        /// 敲一个键，包成独立的一组（还原真机「一个事件一组」）
        func keystroke(_ typed: String) {
            undoManager.beginUndoGrouping()
            let range = NSRange(location: textView.selectedRange.location, length: 0)
            // ⚠️ 必须先问 delegate：列表续写就是在 `shouldChangeTextIn` 里接管回车的，直接 `insertText` 会绕过它（真实键盘是会问的）
            if textView.delegate?.textView?(textView, shouldChangeTextIn: range, replacementText: typed) == false {
                // 续写已经自己改好了
            } else {
                textView.insertText(typed)
            }
            undoManager.endUndoGrouping()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        keystroke("\n")
        keystroke("3")
        keystroke("\n")
        keystroke("4")
        XCTAssertEqual(textView.documentStore.sourceDocument, "- 1\n- 2\n- 3\n- 4", "四次按键之后的内容")

        // 一步步往回退：每按一次 ⌘Z 只该退掉刚刚那一次编辑
        let expected = ["- 1\n- 2\n- 3\n- ", "- 1\n- 2\n- 3", "- 1\n- 2\n- ", "- 1\n- 2"]
        for (step, expect) in expected.enumerated() {
            undoManager.undo()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(textView.documentStore.sourceDocument, expect,
                           "第 \(step + 1) 次 ⌘Z 之后的内容不对")
        }
    }
}
