//
//  MarkdownQuickActionTests.swift
//  MarkdownEditorHy4Tests
//
//  悬浮编辑按钮上那几个动作**改完源码变成什么样**。
//
//  ### 为什么只测动作、不测圆点那套 UI
//  圆点能不能拖动、长按菜单弹在哪个位置，属于「屏幕上摆得对不对」，按项目惯例靠编译 + 手动冒烟；
//  而「点一下待办，源码里到底多了哪几个字符」是会静默坏掉的：
//  写错了不报错也不崩，只是用户拿到一份语法不对的文档。所以这一层必须有测试兜着。
//
//  ### 选区用的是渲染坐标
//  编辑器里 `selectedRange` 是**渲染**坐标（屏幕上看到的那个串），源码坐标是另一套 ——两者在 `- [ ]` 这种带复选框座位的行上并不相等（座位占一个渲染字符、不占源码字符）。
//  所以这里一律按 `(tv.text as NSString)` 取渲染长度来摆光标，交给编辑器自己去换算。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

final class MarkdownQuickActionTests: XCTestCase {

    // MARK: 工具

    /// 建一个挂在真实窗口里的编辑器（要在窗口里，TextKit 才会真正排版）
    private func makeEditor(_ markdown: String) -> MarkdownTextView {
        let textView = MarkdownTextView(markdown: markdown)
        textView.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        textView.layoutIfNeeded()
        return textView
    }

    /// 把光标放到渲染文本的第 `offset` 个字符前
    private func placeCaret(_ textView: MarkdownTextView, at offset: Int) {
        textView.selectedRange = NSRange(location: offset, length: 0)
    }

    /// 选中渲染文本的 `range` 这一段
    private func select(_ textView: MarkdownTextView, _ range: NSRange) {
        textView.selectedRange = range
    }

    /// 渲染文本的总长度（`selectedRange` 用的就是这套坐标）
    private func renderedLength(_ textView: MarkdownTextView) -> Int {
        (textView.text as NSString).length
    }

    /// 光标停到文档最末尾
    private func placeCaretAtEnd(_ textView: MarkdownTextView) {
        placeCaret(textView, at: renderedLength(textView))
    }

    // MARK: 没选中文字 → 插入占位符

    /// 没选中文字时点加粗：插入一对空标记 `****`，光标停在**两个标记中间**（接着打字就落在里面）。
    func testBoldInsertsEmptyPairAndCaretSitsBetween() {
        let tv = makeEditor("hello")
        placeCaret(tv, at: 0)

        MarkdownQuickAction.bold.apply(to: tv)

        XCTAssertEqual(tv.markdownSource, "****hello",
                       "没选东西时该只插入一对空标记，一个字都不动")
        XCTAssertEqual(tv.selectedRange.location, 2,
                       "光标该停在两个 `**` 中间，否则用户还得手动把光标挪进去")
    }

    /// 没选中文字时点行内代码：同样插入一对空的反引号。
    func testInlineCodeInsertsEmptyPair() {
        let tv = makeEditor("x")
        placeCaret(tv, at: 0)

        MarkdownQuickAction.inlineCode.apply(to: tv)

        XCTAssertEqual(tv.markdownSource, "``x")
        XCTAssertEqual(tv.selectedRange.location, 1)
    }

    // MARK: 选中了文字 → 给选中的那段套标记

    /// 选中「hello」再点加粗：`**hello**`。
    func testBoldWrapsSelection() {
        let tv = makeEditor("hello")
        select(tv, NSRange(location: 0, length: 5))

        MarkdownQuickAction.bold.apply(to: tv)

        XCTAssertEqual(tv.markdownSource, "**hello**")
    }

    /// 选中「删」再点删除线：`~~删~~`（删除线是 GFM 的 `~~`，不是 `~`）。
    func testStrikethroughWrapsSelection() {
        let tv = makeEditor("删")
        select(tv, NSRange(location: 0, length: 1))

        MarkdownQuickAction.strikethrough.apply(to: tv)

        XCTAssertEqual(tv.markdownSource, "~~删~~")
    }

    /// 已经套着标记再点一次 → 脱掉（工具栏按钮是**开关**，不该越点越厚）。
    func testBoldTogglesOffWhenAlreadyWrapped() {
        let tv = makeEditor("**hello**")
        select(tv, NSRange(location: 2, length: 5))

        MarkdownQuickAction.bold.apply(to: tv)

        XCTAssertEqual(tv.markdownSource, "hello")
    }

    // MARK: 整行的动作：标题

    /// 点 H1：当前行变成 `# 标题`。
    func testHeadingOnePrefixesCurrentLine() {
        let tv = makeEditor("标题")
        placeCaretAtEnd(tv)

        MarkdownQuickAction.heading(1).apply(to: tv)

        XCTAssertEqual(tv.markdownSource, "# 标题")
    }

    /// 长按 H1 弹出来的菜单里应该有 H1~H6 六项（主横条上只摆一个 H1，靠长按才能选到 H3）。
    func testHeadingMenuOffersAllSixLevels() {
        let alternatives = MarkdownQuickAction.heading(1).alternatives
        XCTAssertEqual(alternatives, (1...6).map { MarkdownQuickAction.heading($0) },
                       "长按 H1 要能把六个级别都列出来")
    }

    /// 菜单里选 H3：`### 标题`。
    func testHeadingThreeFromMenu() {
        let tv = makeEditor("标题")
        placeCaretAtEnd(tv)

        MarkdownQuickAction.heading(3).apply(to: tv)

        XCTAssertEqual(tv.markdownSource, "### 标题")
    }

    // MARK: 整行的动作：待办事项

    /// 点待办：行首补上 `- [ ] `（方括号里是空格 = 未完成）。
    func testTodoAddsCheckboxMarker() {
        let tv = makeEditor("买菜")
        placeCaretAtEnd(tv)

        MarkdownQuickAction.todo.apply(to: tv)

        XCTAssertEqual(tv.markdownSource, "- [ ] 买菜")
    }

    /// 已经是待办项再点一次 → 脱掉（回到普通文字）。
    func testTodoTogglesOff() {
        let tv = makeEditor("- [ ] 买菜")
        placeCaretAtEnd(tv)

        MarkdownQuickAction.todo.apply(to: tv)

        XCTAssertEqual(tv.markdownSource, "买菜",
                       "再点一次该把 `- [ ] ` 整段去掉，而不是再叠一层")
    }

    /// 在有序列表上点待办：换标记而不是叠加（`- [ ] 1. 买菜` 这种两个标记叠一起是错的）。
    func testTodoReplacesOrderedMarkerInsteadOfStacking() {
        let tv = makeEditor("1. 买菜")
        placeCaretAtEnd(tv)

        MarkdownQuickAction.todo.apply(to: tv)

        XCTAssertEqual(tv.markdownSource, "- [ ] 买菜")
    }

    /// 已完成的 `- [x]` 上点待办：变回未完成的 `- [ ] `（不是又叠一层）。
    func testTodoResetsCheckedItem() {
        let tv = makeEditor("- [x] 买菜")
        placeCaretAtEnd(tv)

        MarkdownQuickAction.todo.apply(to: tv)

        XCTAssertEqual(tv.markdownSource, "- [ ] 买菜")
    }

    // MARK: 整行的动作：列表

    /// 点列表：行首补上 `- `。
    func testBulletedListAddsDash() {
        let tv = makeEditor("第一条")
        placeCaretAtEnd(tv)

        MarkdownQuickAction.bulletedList.apply(to: tv)

        XCTAssertEqual(tv.markdownSource, "- 第一条")
    }

    /// 已经是列表项再点一次 → 脱掉。
    func testBulletedListTogglesOff() {
        let tv = makeEditor("- 第一条")
        placeCaretAtEnd(tv)

        MarkdownQuickAction.bulletedList.apply(to: tv)

        XCTAssertEqual(tv.markdownSource, "第一条")
    }

    /// 长按列表弹出来的菜单：无序 + 有序两项。
    func testBulletedListMenuOffersBothKinds() {
        XCTAssertEqual(MarkdownQuickAction.bulletedList.alternatives,
                       [.bulletedList, .orderedList])
    }

    /// 选中三行再点有序列表：依次编号 1. 2. 3.（不是三行都写 1.）。
    func testOrderedListNumbersEverySelectedLine() {
        let tv = makeEditor("a\nb\nc")
        select(tv, NSRange(location: 0, length: renderedLength(tv)))

        MarkdownQuickAction.orderedList.apply(to: tv)

        XCTAssertEqual(tv.markdownSource, "1. a\n2. b\n3. c")
    }

    /// 有序列表上再点一次 → 脱掉编号。
    func testOrderedListTogglesOff() {
        let tv = makeEditor("1. a\n2. b")
        select(tv, NSRange(location: 0, length: renderedLength(tv)))

        MarkdownQuickAction.orderedList.apply(to: tv)

        XCTAssertEqual(tv.markdownSource, "a\nb")
    }

    // MARK: 代码块

    /// 没选中文字时点代码块：新开一个空的围栏代码块，光标停在中间那一行。
    func testCodeBlockInsertsFence() {
        let tv = makeEditor("说明")
        placeCaretAtEnd(tv)

        MarkdownQuickAction.codeBlock.apply(to: tv)

        XCTAssertEqual(tv.markdownSource, "说明\n\n```\n\n```")
    }

    // MARK: 下划线

    /// 点下划线：`<u>文字</u>` —— markdown 没有下划线语法，通行做法是内联 HTML。
    func testUnderlineUsesInlineHTML() {
        let tv = makeEditor("重点")
        select(tv, NSRange(location: 0, length: 2))

        MarkdownQuickAction.underline.apply(to: tv)

        XCTAssertEqual(tv.markdownSource, "<u>重点</u>")
    }
}
