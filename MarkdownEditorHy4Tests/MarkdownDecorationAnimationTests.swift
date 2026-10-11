//
//  MarkdownDecorationAnimationTests.swift
//  MarkdownEditorHy4Tests
//
//  装饰摆位不许带动画。
//
//  ### 守的是哪个 bug
//  iPhone 上弹出 / 收起键盘时，左侧装订线的折叠三角和代码块右上角的复制按钮会**从左上角「嗖」地飞到正确位置**。
//  根因是：UIKit 改键盘高度时是包在一个动画事务里的，`keyboardWillChangeFrame` → `layoutIfNeeded()` 于是也跑在动画事务里。
//  而这些装饰**每一轮布局都整批重建**（新 view 的 `frame` 先是左上角的 `(0,0)`，紧接着才被赋成真位置），那一下赋值就被 UIKit 配上了补间。
//  于是「从 (0,0) 挪到目标位置」成了一次真的属性动画。
//
//  摆位是跟着滚动 / 布局走的定位，本来就该瞬时对齐。
//  这里用「在一个动画事务里走一轮布局」复现键盘那条路径，断言谁都不许被挂上 `position` / `bounds.size` 动画。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownDecorationAnimationTests: XCTestCase {

    private let markdown = """
    # 标题一

    正文一段。

    ```swift
    let document = Document(parsing: markdown)
    print(document)
    ```

    - [ ] 待办一项

    > 引用一段
    """

    /// 造一个「已经排好版、装饰也摆好了」的编辑器（和 CodeBlockBackgroundClearanceTests 同一套路数）
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

    /// 找出这一轮摆位摆出来的装饰按钮（复制按钮 / 折叠三角 / 复选框）。
    ///
    /// 按类型名认人而不是按私有属性取：这几个层是 `private`，测试不该为了取它们去放宽可见性。
    private func decorationButtons(in textView: MarkdownTextView) -> [UIView] {
        let wanted: Set<String> = ["CodeBlockCopyButton", "FoldDisclosureButton", "MarkdownCheckboxButton"]
        return textView.subviews.flatMap { container in
            container.subviews.filter { wanted.contains(String(describing: type(of: $0))) }
        }
    }

    /// 核心用例：布局落在动画事务里（= 键盘弹出 / 收起那一刻）时，摆位不许被配上补间。
    func testDecorationButtonsAreNotAnimatedWhenLayoutRunsInsideAnimation() throws {
        let tv = makeEditor()

        // 复现键盘那条路径：在一个动画事务里走一轮布局
        UIView.animate(withDuration: 0.5) {
            tv.setNeedsLayout()
            tv.layoutIfNeeded()
        }

        let buttons = decorationButtons(in: tv)
        // 先守住「用例不是空的」：没摆出来任何按钮的话，下面的断言就成了自欺欺人
        XCTAssertGreaterThanOrEqual(buttons.count, 3, "这份文档该摆出复制按钮 + 折叠三角 + 复选框")

        for button in buttons {
            let name = String(describing: type(of: button))
            let keys = button.layer.animationKeys() ?? []
            XCTAssertFalse(keys.contains("position"),
                           "\(name) 被挂上了 position 动画 —— 键盘弹出那一下它会从左上角飞过来")
            XCTAssertFalse(keys.contains("bounds.size"),
                           "\(name) 被挂上了 bounds.size 动画 —— 它会从 0 尺寸「长」出来")
            // 顺带守住「位置确实摆对了」：关动画不能把关成摆错位置
            XCTAssertNotEqual(button.frame.origin, .zero, "\(name) 没被摆到位置上")
        }
    }

    /// 平时（不在动画事务里）本来就没动画 —— 这条钉住「关动画那两行没有副作用」。
    func testDecorationButtonsArePlacedCorrectlyWithoutAnimation() {
        let tv = makeEditor()
        let buttons = decorationButtons(in: tv)
        XCTAssertFalse(buttons.isEmpty, "该摆出装饰按钮")
        for button in buttons {
            XCTAssertTrue(button.layer.animationKeys()?.isEmpty ?? true,
                          "\(type(of: button)) 不该带动画")
            XCTAssertNotEqual(button.frame.origin, .zero)
        }
    }
}
