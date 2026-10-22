//
//  MarkdownTypewriterModeTests.swift
//  MarkdownEditorHy4Tests
//
//  打字机模式：输入时光标要留在屏幕中间，正文持续往上滚。
//
//  ### 守的五件事
//  1. **开关本身**：开的时候给底部留半屏空白（不留的话文档最后几行永远滚不到中间）；
//  2. **光标走到哪儿跟到哪儿**：往下打字、往上按方向键、跨行点击，三种都得把光标拉回中线；
//  3. **有选区时不跟**：拖选由系统自己滚，我们再插一脚会打架；
//  4. **跳转也停在中间**：查找下一个、脚注跳转不能停在屏幕上沿，跳完光标还得在中线附近；
//  5. **关掉之后一次都不许滚**。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownTypewriterModeTests: XCTestCase {

    // MARK: - 小工具

    /// 一篇够长的文档（60 行，远超视口高度）
    private var longMarkdown: String {
        (1...60).map { "第 \($0) 行正文内容，用来撑出可滚动的长度。" }.joined(separator: "\n")
    }

    /// 建一台挂在真实窗口里的编辑器（不在窗口里 TextKit 不会真正排版）
    /// - parameter markdown: 不传就用那篇 60 行的通用长文；脚注那类要专门构造文档时才传
    private func makeEditor(markdown: String? = nil,
                            height: CGFloat = 500) -> (editor: MarkdownTextView, window: UIWindow) {
        let editor = MarkdownTextView(markdown: markdown ?? longMarkdown)
        editor.frame = CGRect(x: 0, y: 0, width: 600, height: height)
        let window = UIWindow(frame: editor.frame)
        window.addSubview(editor)
        window.makeKeyAndVisible()
        editor.layoutIfNeeded()
        editor.setNeedsLayout()
        editor.layoutIfNeeded()
        return (editor, window)
    }

    /// 等排版 / 滚动都落定（`keepCaretNearScreenCenterIfNeeded` 内部排到了下一拍）
    private func waitOneBeat(_ seconds: Double = 0.08) {
        let done = expectation(description: "等一拍")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    /// 等跳转收敛：连续 0.25 秒滚动位置几乎不变就算停了。
    /// 跳转本身是「滚一轮 → 等 0.06s 重排 → 再滚」的循环（见 `jumpStep`），不能用固定时长去猜。
    @discardableResult
    private func waitForScrollToSettle(_ editor: MarkdownTextView,
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

    /// 某个**渲染偏移**处的光标在屏幕上的纵坐标（屏幕上沿为 0）。
    /// 查找不挪光标，量不了 `selectedRange`，所以按偏移直接问 TextKit 要矩形。
    private func screenY(ofRenderedOffset offset: Int, in editor: MarkdownTextView) -> CGFloat {
        guard let position = editor.position(from: editor.beginningOfDocument, offset: offset) else { return .nan }
        return editor.caretRect(for: position).midY - editor.contentOffset.y
    }

    /// 光标在**屏幕上**的纵坐标（屏幕上沿为 0）
    private func caretScreenY(_ editor: MarkdownTextView) -> CGFloat {
        screenY(ofRenderedOffset: editor.selectedRange.location, in: editor)
    }

    /// 一篇带脚注的长文档：定义在文末，跳过去要跨过大半篇，才看得出「停在顶部还是中间」
    private var footnoteMarkdown: String {
        let body = (1...40).map { "第 \($0) 行正文内容，把脚注定义顶到很下面。" }.joined(separator: "\n")
        return body + "\n\n正文里引用了[^1]这条脚注。\n\n[^1]: 脚注定义排在文末，跳过来时该停在屏幕中间。\n"
    }

    private func moveCaretToEnd(_ editor: MarkdownTextView) {
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
    }

    // MARK: - 开关本身

    /// 开模式给半屏底部留白，关掉归零
    func testTypewriterModeReservesHalfScreenAtTheBottom() {
        let (editor, _) = makeEditor(height: 500)

        editor.isTypewriterMode = true
        XCTAssertEqual(editor.contentInset.bottom, 250, accuracy: 1,
                       "底部至少要留半屏，否则文档最后一行永远滚不到中间")

        editor.isTypewriterMode = false
        XCTAssertEqual(editor.contentInset.bottom, 0, accuracy: 0.5, "关掉之后不该还占着那块空白")
    }

    /// 视口高度变了（转屏 / 拉窗口），留白要跟着重算
    func testTypewriterInsetFollowsViewportHeight() {
        let (editor, _) = makeEditor(height: 500)
        editor.isTypewriterMode = true

        editor.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        editor.layoutIfNeeded()

        XCTAssertEqual(editor.contentInset.bottom, 400, accuracy: 1, "留白该按新的视口高度重算")
    }

    // MARK: - 往下越界就居中

    /// 光标在文末（远在中线以下）→ 滚到中线
    func testCaretIsCenteredWhenItIsBelowTheMiddle() {
        let (editor, _) = makeEditor(height: 500)
        editor.isTypewriterMode = true
        moveCaretToEnd(editor)

        editor.keepCaretNearScreenCenterIfNeeded()
        waitOneBeat()

        XCTAssertEqual(caretScreenY(editor), 250, accuracy: 8, "光标没被拉到屏幕中间")
    }

    /// 连续敲字：每敲一下，光标都还在中线附近（这就是「正文往上滚」的观感）
    func testCaretStaysNearTheMiddleWhileTyping() {
        let (editor, _) = makeEditor(height: 500)
        editor.isTypewriterMode = true
        moveCaretToEnd(editor)

        for index in 0..<5 {
            editor.insertText("\n下一行")
            waitOneBeat()

            XCTAssertEqual(caretScreenY(editor), 250, accuracy: 8,
                           "敲到第 \(index + 1) 下，光标已经离开屏幕中线了")
        }
    }

    /// 光标被手动滚到屏幕上方之外，回来一敲字要被拉回中线（不能打在看不见的地方）
    func testCaretIsCenteredWhenItWasScrolledAboveTheViewport() {
        let (editor, _) = makeEditor(height: 500)
        editor.isTypewriterMode = true
        // 光标放文档中部（第 30 行），再往下翻很远，让它彻底离开屏幕
        let plain = editor.text as NSString
        let needle = plain.range(of: "第 30 行")
        XCTAssertNotEqual(needle.location, NSNotFound)
        editor.selectedRange = NSRange(location: needle.location, length: 0)
        editor.contentOffset = CGPoint(x: 0, y: 1100)

        editor.keepCaretNearScreenCenterIfNeeded()
        waitOneBeat()

        XCTAssertEqual(caretScreenY(editor), 250, accuracy: 8, "光标在屏幕外时该被拉回中间")
    }

    // MARK: - 光标走到哪儿就跟到哪儿

    /// 鼠标点上面那一行（光标跳到中线以上）→ 也要把它滚到中线
    func testCaretIsCenteredWhenItJumpsAboveTheMiddle() {
        let (editor, _) = makeEditor(height: 500)
        editor.isTypewriterMode = true
        // 先把视口往下挪，让第 20 行落在屏幕上半部分
        editor.contentOffset = CGPoint(x: 0, y: 500)

        let plain = editor.text as NSString
        let needle = plain.range(of: "第 20 行")
        XCTAssertNotEqual(needle.location, NSNotFound)
        editor.selectedRange = NSRange(location: needle.location, length: 0)

        editor.keepCaretNearScreenCenterIfNeeded()
        waitOneBeat()

        XCTAssertEqual(caretScreenY(editor), 250, accuracy: 8, "点上面那一行也该把光标滚到中间")
    }

    /// 按住 ↑ 一行行往上挪：每挪一次光标都还停在中线附近（正文跟着往下走）
    func testCaretStaysNearTheMiddleWhileMovingUp() {
        let (editor, _) = makeEditor(height: 500)
        editor.isTypewriterMode = true
        moveCaretToEnd(editor)
        editor.keepCaretNearScreenCenterIfNeeded()
        waitOneBeat()

        let plain = editor.text as NSString
        for step in 1...3 {
            editor.selectedRange = NSRange(location: max(0, plain.length - step * 14), length: 0)
            editor.keepCaretNearScreenCenterIfNeeded()
            waitOneBeat()

            XCTAssertEqual(caretScreenY(editor), 250, accuracy: 8,
                           "往上挪第 \(step) 次，光标已经离开中线了")
        }
    }

    /// 真的走一遍 UIKit 那条路：光标一变，`textViewDidChangeSelection` 自己会把居中做完（不是测试手动调的）
    func testSelectionChangeFromUIKitTriggersCentering() {
        let (editor, _) = makeEditor(height: 500)
        // 只有成了第一响应者，UIKit 才会把选区变化报给 delegate
        _ = editor.becomeFirstResponder()
        editor.isTypewriterMode = true
        waitOneBeat()

        // 先把视口翻到远处，再让光标跳到屏幕上方那一行
        editor.contentOffset = CGPoint(x: 0, y: 900)
        let plain = editor.text as NSString
        let needle = plain.range(of: "第 10 行")
        XCTAssertNotEqual(needle.location, NSNotFound)
        editor.selectedRange = NSRange(location: needle.location, length: 0)
        waitOneBeat()

        XCTAssertEqual(caretScreenY(editor), 250, accuracy: 8, "UIKit 报来的光标变化没触发居中")
    }

    /// 拖着选一段的时候不动画面：系统自己会把选区末端滚进视野，两边一起滚会打架
    func testSelectionDoesNotGetCentered() {
        let (editor, _) = makeEditor(height: 500)
        editor.isTypewriterMode = true
        editor.contentOffset = CGPoint(x: 0, y: 0)
        let before = editor.contentOffset.y

        editor.selectedRange = NSRange(location: 0, length: 60)
        editor.keepCaretNearScreenCenterIfNeeded()
        waitOneBeat()

        XCTAssertEqual(editor.contentOffset.y, before, accuracy: 0.5, "有选区时不该动画面")
    }

    // MARK: - 跳转也停在中间

    /// 查找下一个：命中远在屏幕外，跳完该停在屏幕中间（老行为是贴到屏幕上沿）
    func testTypewriterModeCentersSearchJump() {
        let (editor, _) = makeEditor(height: 500)
        editor.isTypewriterMode = true
        waitOneBeat()

        let needle = "第 50 行"
        XCTAssertEqual(editor.performSearch(query: needle, options: SearchOptions()), 1,
                       "样例里这个记号应该只出现一次，不然没法确定跳到了哪一处")
        waitForScrollToSettle(editor)

        // 查找不挪光标，所以按命中的渲染偏移直接量
        let rendered = (editor.text as NSString).range(of: needle)
        XCTAssertNotEqual(rendered.location, NSNotFound, "渲染文本里找不到这个记号")
        let middle = editor.bounds.height / 2
        let y = screenY(ofRenderedOffset: rendered.location, in: editor)
        XCTAssertEqual(y, middle, accuracy: 8,
                       "打字机模式下「查找下一个」该把命中停在中间（y≈\(middle)），实际 y=\(y)")

        editor.clearSearchHighlight()
        editor.isTypewriterMode = false
    }

    /// 脚注跳转：点正文里的引用跳到文末定义，跳完定义那行该停在屏幕中间
    func testTypewriterModeCentersFootnoteJump() {
        let (editor, _) = makeEditor(markdown: footnoteMarkdown, height: 500)
        editor.isTypewriterMode = true
        waitOneBeat()

        editor.jumpToFootnoteDefinition("1")
        waitForScrollToSettle(editor)

        let middle = editor.bounds.height / 2
        let y = caretScreenY(editor)
        XCTAssertEqual(y, middle, accuracy: 8,
                       "打字机模式下脚注跳转该停在中间（y≈\(middle)），实际 y=\(y)")

        editor.isTypewriterMode = false
    }

    /// 关着开关：什么都没发生
    func testNothingMovesWhenTypewriterModeIsOff() {
        let (editor, _) = makeEditor(height: 500)
        moveCaretToEnd(editor)
        let before = editor.contentOffset.y

        editor.keepCaretNearScreenCenterIfNeeded()
        waitOneBeat()

        XCTAssertEqual(editor.contentOffset.y, before, accuracy: 0.5, "没开打字机模式却滚了")
        XCTAssertEqual(editor.contentInset.bottom, 0, accuracy: 0.5, "没开打字机模式却留了底部空白")
    }
}
