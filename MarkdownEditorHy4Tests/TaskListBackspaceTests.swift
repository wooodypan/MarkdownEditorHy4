//
//  TaskListBackspaceTests.swift
//  MarkdownEditorHy4Tests
//
//  任务列表项里按退格键的删除行为。
//
//  ### 任务项的文本流长什么样
//  `- [ ] 未完成的项` 渲染出来是：`- `（浅灰源码）+ 复选框座位（透明附件）+ `[ ] `（浅灰源码，含尾随空格）+ 正文。
//  其中座位是为复选框按钮专门留的一块空位（见 `CheckboxSeatAttachment`）。
//
//  ### 这里防的两个回归（同一天修的两件事）
//  1. 座位一旦也被打上 `.markdownSyntaxMarker`，就会把左边 `- ` 和右边 `[ ] ` 两段**独立**的语法标记粘成一段连续标记 —— 光标停在 `]` 右边按一次退格，扩展逻辑跨过座位把 `- [ ] ` 整段吃掉，源码从 `- [ ] 未完成的项` 直接变成 `未完成的项`（列表标记也没了）。
//  2. 删掉最后一个任务项之后，屏幕上那个复选框按钮必须**立刻**消失 —— 装饰层平时只在 `layoutSubviews` 里刷新，而 TextKit 改文本不保证触发一次布局，按钮会赖在屏幕上不走。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

final class TaskListBackspaceTests: XCTestCase {

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

    /// 从视图树里捞所有复选框按钮（屏幕上真实存在的控件）
    private func allCheckboxButtons(in view: UIView) -> [MarkdownCheckboxButton] {
        var result: [MarkdownCheckboxButton] = []
        for subview in view.subviews {
            if let button = subview as? MarkdownCheckboxButton {
                result.append(button)
            }
            result.append(contentsOf: allCheckboxButtons(in: subview))
        }
        return result
    }

    /// 光标停在 `]` 右边按一次退格：只该删掉复选框那三个字符（连带尾随空格），列表标记 `- ` 必须留着。
    func testBackspaceAfterBracketKeepsListMarker() {
        let tv = makeEditor("- [ ] 未完成的项\n")

        // 渲染坐标 6 就是 `]` 的右边：`- ` 占 0-1、座位占 2、`[ ]` 占 3-5
        tv.selectedRange = NSRange(location: 6, length: 0)
        tv.deleteBackward()

        XCTAssertEqual(tv.markdownSource, "- 未完成的项\n",
                       "退格只该删掉 `[ ] ` 这几个字符；列表标记 `- ` 被一起吃掉的话，整行就降级成普通段落了")
    }

    /// 光标正好停在**座位**上按退格：座位属于它右边那个 `[ ]`，所以结果应该和上面一样。
    ///
    /// 座位是「不消耗源码位置」的装饰附件，直接拿它去算源码范围会得到空范围 —— 不加处理的话用户按了退格会「什么都没发生」。
    func testBackspaceOnSeatDeletesCheckboxLiteral() {
        let tv = makeEditor("- [ ] 未完成的项\n")

        tv.selectedRange = NSRange(location: 3, length: 0)   // 座位右边（座位占第 2 格），退格删的就是座位
        tv.deleteBackward()

        XCTAssertEqual(tv.markdownSource, "- 未完成的项\n",
                       "座位上的退格要转成「删掉 `[ ] `」，不能变成空操作")
    }

    /// 光标在 `- ` 里按退格：整段 `- ` 一起删掉，这一行降级成普通段落（和普通列表项圆点的行为一致）。
    func testBackspaceOnListMarkerDegradesToParagraph() {
        let tv = makeEditor("- [ ] 未完成的项\n")

        tv.selectedRange = NSRange(location: 2, length: 0)   // `- ` 的右边（座位之前）
        tv.deleteBackward()

        XCTAssertEqual(tv.markdownSource, "[ ] 未完成的项\n",
                       "在列表标记里退格要整段删掉 `- `；删一半会留下 `-一级` 这种残片")
    }

    /// 删掉文档里最后一个任务项之后，屏幕上那个复选框按钮必须**立刻**消失。
    ///
    /// 老 bug 的现场：渲染文本里座位已经没了，按钮却还留在原地 —— 用户看到的就是「只剩一个没勾选的空方框和一行文字」，一直等到下次滚动（那时才走 layout）才恢复。
    func testCheckboxButtonDisappearsImmediatelyAfterDelete() {
        let tv = makeEditor("- [ ] 未完成的项\n")
        XCTAssertEqual(allCheckboxButtons(in: tv).count, 1, "前置条件：一开始应该有一个复选框按钮")

        tv.selectedRange = NSRange(location: 6, length: 0)
        tv.deleteBackward()

        XCTAssertEqual(allCheckboxButtons(in: tv).count, 0,
                       "任务项已经删没了，按钮不能在屏幕上留着（别靠下一次滚动来清）")
    }

    /// 座位是「两段语法标记之间的边界」，它自己**不能**带 `.markdownSyntaxMarker`。
    ///
    /// 这条是上面几条的「机制层」护栏：座位一带标记，`- ` 和 `[ ] ` 就被连成一段，于是任何落在复选框里的退格都会顺手把列表标记也吃掉。
    func testCheckboxSeatIsNotSyntaxMarker() {
        let tv = makeEditor("- [ ] 未完成的项\n")

        var seatRange: NSRange?
        tv.textStorage.enumerateAttribute(.markdownCheckboxSeat,
                                          in: NSRange(location: 0, length: tv.textStorage.length),
                                          options: []) { value, range, _ in
            if value is CheckboxInfo { seatRange = range }
        }

        guard let seatRange else { return XCTFail("任务项里应该有一个复选框座位") }
        XCTAssertNil(tv.textStorage.attribute(.markdownSyntaxMarker, at: seatRange.location, effectiveRange: nil),
                     "座位带语法标记会把 `- ` 和 `[ ] ` 粘成一段，退格一次连列表标记一起删")
    }
}
