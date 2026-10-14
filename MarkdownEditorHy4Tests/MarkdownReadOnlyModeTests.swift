//
//  MarkdownReadOnlyModeTests.swift
//  MarkdownEditorHy4Tests
//
//  只读模式：看得见光标、能选中复制，但一个字都不许改。
//
//  ### 守的是哪几道闸门（漏一道就是「以为锁上了、其实还能改」）
//  1. 键盘输入 / 粘贴：由 delegate 的 `shouldChangeTextIn` 挡在**最前面** —— 字符压根进不了 `textStorage`；
//  2. 我们自己发起的编辑：`applyEdit` 是最后的总闸（格式化快捷键、快速操作面板、粘贴转 markdown 全走它）；
//  3. 任务列表复选框：改成「不可交互」，点了既不改源码，也不把这一下点击从正文手里抢走。
//
//  只读的实现就是 `isEditable = false`（系统因此不弹键盘、不让改），但 `isSelectable` 必须**留着** —— 能选中复制全靠它，两个一起关就成了「纯展示」，那是主题页预览的设定。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownReadOnlyModeTests: XCTestCase {

    private let markdown = """
    # 标题

    - [ ] 待办一项

    正文一段。
    """

    /// 造一个挂到窗口上、已经排好版的编辑器（装饰层要挂在窗口里才会真的摆出来）
    private func makeEditor() -> MarkdownTextView {
        let textView = MarkdownTextView(markdown: markdown)
        textView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)
        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        textView.layoutIfNeeded()
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        return textView
    }

    /// 这一轮摆出来的复选框按钮（按类型名认人，不去放宽层的可见性）
    private func checkboxButtons(in textView: MarkdownTextView) -> [UIButton] {
        textView.subviews.flatMap { container in
            container.subviews.compactMap { $0 as? UIButton }
        }
        .filter { String(describing: type(of: $0)) == "MarkdownCheckboxButton" }
    }

    /// 只读模式最基础的那条：`isEditable` 关掉（系统因此不弹键盘、不让改），但 `isSelectable` 得留着 —— 不然连选中复制都没了
    func testReadOnlyTurnsOffIsEditableButKeepsSelectable() {
        let tv = makeEditor()
        XCTAssertTrue(tv.isEditable, "默认是能编辑的")

        tv.isReadOnly = true
        XCTAssertFalse(tv.isEditable, "只读模式下 isEditable 必须是 false —— 系统这才不弹键盘、不放编辑菜单")
        XCTAssertTrue(tv.isSelectable, "只读模式下还得能选中复制（两个一起关就成了纯展示）")

        tv.isReadOnly = false
        XCTAssertTrue(tv.isEditable, "退出只读要恢复成能编辑")
    }

    /// 第一道闸：系统想把字符塞进来（键盘输入、粘贴、自动纠错）时要被挡回去
    func testShouldChangeTextInRejectsEditsWhenReadOnly() {
        let tv = makeEditor()
        let range = NSRange(location: 0, length: 0)

        // 没开只读：正常放行（这条同时防止「别的地方改坏了 → 平时也输入不了」）
        let allowedNormally = tv.delegate?.textView?(tv, shouldChangeTextIn: range, replacementText: "x")
        XCTAssertEqual(allowedNormally, true, "默认情况下该允许输入")

        tv.isReadOnly = true
        let allowedInReadOnly = tv.delegate?.textView?(tv, shouldChangeTextIn: range, replacementText: "x")
        XCTAssertEqual(allowedInReadOnly, false, "只读模式下输入必须被挡回去")
    }

    /// 最后的总闸：绕开 delegate 直接调 `applyEdit`（格式化快捷键、快速操作面板那条路），源码不许变。
    ///
    /// ⚠️ 裸调 `applyEdit` 会踩 `_UITextUndoManager invalid state` 崩溃（它内部那对
    /// disable/enable 只在「程序发起的编辑」这个时机才合法），所以这里照真实调用方那样套一层 `performUndoableModelEdit`。
    func testApplyEditKeepsSourceUnchangedWhenReadOnly() {
        let tv = makeEditor()
        let before = tv.markdownSource

        tv.isReadOnly = true
        tv.performUndoableModelEdit(actionName: "只读下的一次编辑") {
            tv.applyEdit(renderedRange: NSRange(location: 0, length: 0),
                         replacementText: "插一句试试",
                         alreadyAppliedToTextStorage: false)
        }

        XCTAssertEqual(tv.markdownSource, before, "只读模式下 applyEdit 必须什么都不做")
    }

    /// 对照组：没开只读时，同一次调用**确实**能改到源码 —— 防止上面那条因为「别的原因也改不动」而假通过
    func testApplyEditDoesChangeSourceWhenNotReadOnly() {
        let tv = makeEditor()
        let before = tv.markdownSource

        tv.performUndoableModelEdit(actionName: "一次编辑") {
            tv.applyEdit(renderedRange: NSRange(location: 0, length: 0),
                         replacementText: "标题前面加几个字",
                         alreadyAppliedToTextStorage: false)
        }

        XCTAssertNotEqual(tv.markdownSource, before, "没开只读时 applyEdit 应该照常生效")
    }

    /// 键盘已经弹着的时候切到只读：要把它收下去（还立一块键盘在屏幕下方，看着像「还能输入」）
    func testEnteringReadOnlyDismissesKeyboard() {
        let tv = makeEditor()
        // ⚠️ 模拟器里不一定真能抢到焦点；抢不到的话「不是第一响应者」本来就是成立的，这条用例不会假失败
        tv.becomeFirstResponder()

        tv.isReadOnly = true
        XCTAssertFalse(tv.isFirstResponder, "切到只读时，已经弹出的键盘必须收下去")
    }

    /// `isEditable = false` 之后系统不再弹键盘，但 textView 仍要能当第一响应者（选中、复制菜单都靠它）
    func testReadOnlyKeepsFirstResponderEligibility() {
        let tv = makeEditor()
        tv.isReadOnly = true

        XCTAssertTrue(tv.canBecomeFirstResponder, "只读模式下照样能当第一响应者 —— 不然长按选词、复制菜单全没了")
    }

    /// 复选框：只读时**照样画出来**（它反映的是源码状态），但变成「摸不着」
    func testCheckboxKeepsDisplayedButNotInteractiveWhenReadOnly() {
        let tv = makeEditor()

        let before = checkboxButtons(in: tv)
        XCTAssertFalse(before.isEmpty, "这份文档该摆出一个复选框")
        XCTAssertTrue(before.allSatisfy(\.isUserInteractionEnabled), "默认要能点")

        tv.isReadOnly = true
        tv.layoutIfNeeded()   // 开关变了要下一轮布局才会重摆按钮

        let after = checkboxButtons(in: tv)
        XCTAssertEqual(after.count, before.count, "只读模式下复选框还得照样显示")
        // ⚠️ 这里必须是「不可交互」而不是「不可启用」：前者的点击会穿透给正文，用户依然能在 `[x]` 那三个字上放光标、选中它
        XCTAssertTrue(after.allSatisfy { !$0.isUserInteractionEnabled }, "只读模式下复选框不许能点")
    }
}
