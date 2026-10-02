//
//  MarkdownUndoStackTests.swift
//  MarkdownEditorHy4Tests
//
//  撤销栈的四条边界：换文档、程序性编辑、命令类编辑（勾选）、栈上限。
//
//  ### 这里守的判据（都是用户看得见的）
//  1. **换文档之后，上一份文档留下的撤销记录必须全部作废** —— 否则在新文档里按 ⌘Z 会把旧账翻出来，
//     旧账的范围是按旧文本记的，套到新文本上直接越界（实测 `NSRangeException`，AppKit 把异常吞掉后表现就是「⌘Z 按了没反应」）；
//  2. **一次程序性编辑只该占一次 ⌘Z** —— 系统也会替我们自己发起的替换记一笔账，
//     两笔账不包成一组的话，用户按一次 ⌘Z 只退掉半步，按两次才退完；
//  3. **勾复选框必须能撤销** —— 那是程序自己发起的编辑，系统不记账，不补一笔的话 ⌘Z 撤的是更早的另一件事；
//  4. **撤销栈要有上限** —— 兜底路径每笔记两份整篇源码，不设上限大文档上能堆到上百 MB。
//
//  ⚠️ 测试里必须手动管撤销分组：XCTest 不派发真实键盘事件，`groupsByEvent` 那种「按事件自动分组」在这里不生效。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownUndoStackTests: XCTestCase {

    private func makeEditor(_ markdown: String) -> MarkdownTextView? {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow })
                ?? UIApplication.shared.windows.first else { return nil }
        let textView = MarkdownTextView(markdown: markdown)
        textView.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        window.addSubview(textView)
        textView.layoutIfNeeded()
        return textView
    }

    /// 敲一个键：先问 delegate（列表续写就是在那儿接管的），它不管再交给系统插。
    ///
    /// 外面套一层撤销组是为了还原真机「一个事件一组」：XCTest 不派发真实键盘事件，
    /// `groupsByEvent` 那种自动分组在这里不生效，不手动开组系统记账时会直接抛
    /// `must begin a group before registering undo`。
    private func keystroke(_ textView: MarkdownTextView, _ typed: String) {
        textView.undoManager?.beginUndoGrouping()
        let range = NSRange(location: textView.selectedRange.location, length: 0)
        if textView.delegate?.textView?(textView, shouldChangeTextIn: range, replacementText: typed) == false {
            // 续写已经自己改好了
        } else {
            textView.insertText(typed)
        }
        textView.undoManager?.endUndoGrouping()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    // MARK: - 1. 换文档要作废旧账

    /// 上一份文档里打过字 → 换到一份空文档 → 粘贴 + 续写 → 一路 ⌘Z 要能平安退到空白。
    ///
    /// ### 不修会怎样（实测，别再退回去）
    /// 换文档只调 `setMarkdown` 不清栈，栈底还压着按旧文本记的账。
    /// 一路撤销撤到底时会翻出它们：`*** -[NSBigMutableString substringWithRange:]: Range {8, …} out of bounds; string length 0`。
    /// 真机上这个异常被 AppKit 吞掉，用户看到的就是「第一次 ⌘Z 有反应，之后怎么按都没反应」。
    func testUndoAfterDocumentSwitchNeverResurrectsOldRecords() throws {
        guard let textView = makeEditor("# 旧文档\n正文") else { throw XCTSkip("拿不到真实窗口") }
        defer { textView.removeFromSuperview() }
        guard let undoManager = textView.undoManager else { throw XCTSkip("响应者链上没有 UndoManager") }
        undoManager.groupsByEvent = false

        // 在旧文档里制造几条撤销记录（它们必须随着换文档一起作废）
        textView.selectedRange = NSRange(location: textView.documentStore.renderedLength, length: 0)
        keystroke(textView, "X")
        keystroke(textView, "Y")

        // 换文档时 `MarkdownDocumentViewController.apply()` 做的事：先作废旧账，再整篇换掉
        textView.resetUndoHistory()
        textView.setMarkdown("")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(undoManager.canUndo, "刚换到新文档，撤销栈应该是空的 —— 旧文档的账不能跟着过来")

        textView.insertMarkdownSourceUndoably("- 1\n- 2")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        textView.selectedRange = NSRange(location: textView.documentStore.renderedLength, length: 0)
        keystroke(textView, "\n")
        keystroke(textView, "3")
        keystroke(textView, "\n")
        keystroke(textView, "4")
        XCTAssertEqual(textView.documentStore.sourceDocument, "- 1\n- 2\n- 3\n- 4")

        // 一路退到底：每一步都得是这份文档自己的内容，最后回到空文档
        let expected = ["- 1\n- 2\n- 3\n- ", "- 1\n- 2\n- 3", "- 1\n- 2\n- ", "- 1\n- 2", ""]
        for (step, expect) in expected.enumerated() {
            XCTAssertTrue(undoManager.canUndo, "第 \(step + 1) 次 ⌘Z 之前就该还能撤销")
            undoManager.undo()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(textView.documentStore.sourceDocument, expect, "第 \(step + 1) 次 ⌘Z 之后的内容不对")
        }
        XCTAssertFalse(undoManager.canUndo, "退到新文档的初始状态就该停住，不能再翻出别的文档的内容")
    }

    // MARK: - 2. 一次程序性编辑 = 一次 ⌘Z

    /// 一次粘贴只该占一次 ⌘Z —— 系统那笔账必须和我们的那笔在同一个撤销组里。
    func testOneUndoPerProgrammaticEdit() throws {
        guard let textView = makeEditor("") else { throw XCTSkip("拿不到真实窗口") }
        defer { textView.removeFromSuperview() }
        guard let undoManager = textView.undoManager else { throw XCTSkip("响应者链上没有 UndoManager") }
        undoManager.groupsByEvent = false

        textView.insertMarkdownSourceUndoably("- 1\n- 2")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(textView.documentStore.sourceDocument, "- 1\n- 2")

        undoManager.undo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(textView.documentStore.sourceDocument, "", "一次 ⌘Z 就该把整次粘贴退干净")
        XCTAssertFalse(undoManager.canUndo,
                       "两笔账（系统的 + 我们的）必须在同一个撤销组里 —— 还剩得下就说明用户得按两次 ⌘Z")
    }

    // MARK: - 3. 钉住系统的记账行为

    /// 我们自己发起的 storage 替换，系统**也会**替它记一笔账。
    ///
    /// 这条不测业务逻辑，只钉事实：以前 `applyEdit` / `toggleCollapse` / `insertMarkdownSourceUndoably`
    /// 三处注释对这件事的假设互相矛盾（有的说会记、有的按「不会记」写），照着错的那个改就会漏掉一半的账。
    func testSystemAlsoRecordsProgrammaticReplacement() throws {
        guard let textView = makeEditor("") else { throw XCTSkip("拿不到真实窗口") }
        defer { textView.removeFromSuperview() }
        guard let undoManager = textView.undoManager else { throw XCTSkip("响应者链上没有 UndoManager") }
        undoManager.groupsByEvent = false

        // `insertMarkdownSource` 是「只插入、不注册撤销」那一个 —— canUndo 要是 true，那笔账只能是系统记的
        undoManager.beginUndoGrouping()
        textView.insertMarkdownSource("- 1\n- 2")
        undoManager.endUndoGrouping()
        XCTAssertTrue(undoManager.canUndo, "系统确实会替程序性替换记账（这条要是红了，说明 UIKit 改了行为，`performUndoableModelEdit` 里那个撤销组可以去掉）")

        guard let whole = makeEditor("") else { throw XCTSkip("拿不到真实窗口") }
        defer { whole.removeFromSuperview() }
        guard let wholeUndo = whole.undoManager else { throw XCTSkip("响应者链上没有 UndoManager") }
        wholeUndo.groupsByEvent = false
        wholeUndo.beginUndoGrouping()
        whole.setMarkdown("abc")
        wholeUndo.endUndoGrouping()
        XCTAssertTrue(wholeUndo.canUndo, "整篇替换（`setMarkdown`）同样会被系统记账 —— 撤销 / 重做走 `restoreDocument` 时也躲不掉")
    }

    // MARK: - 3. 勾复选框必须能撤销

    /// 点一下复选框 → ⌘Z 要把勾退回去（而且只退这一步）。
    ///
    /// ### 不补那笔账会怎样
    /// 勾选是程序自己发起的编辑，系统不给它记账。以前 ⌘Z 撤的是**更早的另一件事**，
    /// 勾选纹丝不动 —— 用户连按几下想撤回勾选，结果把别处的编辑全撤了。
    func testCheckboxToggleIsUndoable() throws {
        guard let textView = makeEditor("- [ ] 待办") else { throw XCTSkip("拿不到真实窗口") }
        defer { textView.removeFromSuperview() }
        guard let undoManager = textView.undoManager else { throw XCTSkip("响应者链上没有 UndoManager") }
        undoManager.groupsByEvent = false

        // 复选框要等排版跑完才有位置（矩形是 TextKit 算的）
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let boxes = textView.computeCheckboxFrames().boxes
        guard let info = boxes.first?.info else { throw XCTSkip("这份文档里没扫到复选框") }
        XCTAssertFalse(info.isChecked, "起手应该是未勾选的 `[ ]`")

        textView.toggleCheckbox(info)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(textView.documentStore.sourceDocument, "- [x] 待办", "点一下复选框，源码里的 `[ ]` 要变成 `[x]`")

        undoManager.undo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(textView.documentStore.sourceDocument, "- [ ] 待办", "⌘Z 要把勾退回去")
        XCTAssertFalse(undoManager.canUndo, "一次勾选只该占一次 ⌘Z（系统的 + 我们的两笔账在同一个组里）")
    }

    // MARK: - 4. 撤销栈要有上限

    /// 撤销栈不能是无限的（默认 `levelsOfUndo = 0`）：兜底路径每笔记两份整篇源码，大文档上能堆到上百 MB。
    func testUndoStackHasALimit() throws {
        guard let textView = makeEditor("# 标题") else { throw XCTSkip("拿不到真实窗口") }
        defer { textView.removeFromSuperview() }
        guard let undoManager = textView.undoManager else { throw XCTSkip("响应者链上没有 UndoManager") }
        undoManager.groupsByEvent = false

        // 上限是在编辑流程里钉的（别挪到 view 挂载时，那会让 App 启动卡住），所以先做一次命令类编辑
        textView.insertMarkdownSourceUndoably("正文")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertGreaterThan(undoManager.levelsOfUndo, 0, "必须设一个上限，0 = 无限，内存会无界增长")
    }
}
