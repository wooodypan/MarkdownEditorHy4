//
//  MarkdownRenderFidelityTests.swift
//  MarkdownEditorHy4Tests
//
//  渲染保真度：渲染出来的字符必须和源码一一对应（「全选复制 === 源文件」的底线），以及它牵出来的「⌘Z 撤销 / ⇧⌘Z 重做」在各种语法下都不能失效。
//
//  ### 为什么要专门守「长度」
//  系统替键盘输入记的撤销是**按插入时的字符数**记账的：插入 1 个字符，撤销时就删 1 个。
//  而我们会在系统记完账之后，用模型重新渲染的结果把整段文本换掉。
//  只要渲染串的长度变化 ≠ 用户实际敲进去的字符数，系统的那笔账就对不上 ——撤销会删错位置，表现为「撤销没反应」或者「撤销完源码缺斤少两」。
//  所以**渲染长度必须可预测**，这组测试就是钉住这件事。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownRenderFidelityTests: XCTestCase {

    // MARK: - 辅助

    private func render(_ source: String) -> String {
        let store = MarkdownDocumentStore()
        store.load(markdown: source, containerWidth: 600)
        return store.renderedString
    }

    /// 无序列表每个列表项会多一个圆点占位符（设计如此），算期望长度时要算进去
    private func expectedLength(of source: String) -> Int {
        let bullets = source.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count
        return (source as NSString).length + bullets
    }

    /// 断言渲染长度符合预期（多出来的只能是有据可查的占位符，不能凭空膨胀）
    private func assertFidelity(_ source: String, file: StaticString = #filePath, line: UInt = #line) {
        let rendered = render(source)
        XCTAssertEqual((rendered as NSString).length,
                       expectedLength(of: source),
                       "渲染串长度失控：源码「\(source)」渲染成「\(rendered)」",
                       file: file, line: line)
    }

    // MARK: 保真度

    /// 懒惰延续（lazy continuation）：上一行的块把下一行「顺便收进来」。
    ///
    /// ### 这里踩过什么坑
    /// cmark 给延续进来的文字标的 range 是**退化的**（长度换算成 0）。
    /// 老写法拿不到范围时仍然把文字输出了，于是补漏步骤又补一遍 ——屏幕上同一个字符出现两次，渲染串平白变长，撤销当场失效。
    func testLazyContinuationIsNotDuplicated() {
        assertFidelity("- 1\n- 2\n3")        // 列表项被下一行续上
        assertFidelity("- 1\n- 2\n3\n")
        assertFidelity("> 引用\n懒惰延续")     // 引用块
        assertFidelity("# 标题\n懒惰延续")     // 标题
        assertFidelity("段落一\n懒惰延续")     // 普通段落（软换行）
    }

    /// 未闭合的代码围栏：源码结尾既没有闭合的 ```、也没有换行。
    ///
    /// ### 这里踩过什么坑
    /// 这种情况下 cmark 给 `codeBlock.code` **补了一个源码里不存在的尾巴换行**，拿整段去源码里搜必然搜不到，老写法就退化成「不带源码映射的装饰文字」——补漏步骤照样把整块源码再补一遍，代码整段出现两次。
    /// 这正是「刚敲到一半的代码块」的状态，不是什么罕见的边角。
    func testUnclosedCodeFenceIsNotDuplicated() {
        assertFidelity("```")
        assertFidelity("```\n")
        assertFidelity("```\ncode")           // 正在敲，还没闭合
        assertFidelity("```\ncode\n")
        assertFidelity("```\ncode\n``")       // 闭合围栏只敲了两个反引号
        assertFidelity("```\ncode\n```")      // 正常闭合
        assertFidelity("```\ncode\n```3")     // 闭合围栏后面又多打了字，围栏因此失效
        assertFidelity("```\ncode\n```x\n")
    }

    // MARK: 撤销 / 重做

    /// 造一个「能撤销」的编辑器。
    ///
    /// `UndoManager` 是从响应者链上取的（view → superview → window → …），游离的 view 根本拿不到它，所以必须挂到 app 真实的窗口上。
    /// 用完请 `removeFromSuperview()`，别留在窗口上干扰别的用例。
    private func makeEditor(_ markdown: String) -> MarkdownTextView? {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow })
                ?? UIApplication.shared.windows.first else { return nil }
        let textView = MarkdownTextView(markdown: markdown)
        textView.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        window.addSubview(textView)
        textView.layoutIfNeeded()
        return textView
    }

    /// 在 `caret` 处敲入 `typed`，然后撤销、重做，各验一次源码。
    ///
    /// - parameter caret: 渲染串里的光标位置，默认文末（用户最常干的事：接着往下打字）
    private func assertTypingIsUndoable(_ source: String,
                                        caret: Int? = nil,
                                        typed: String,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) throws {
        // 拿不到窗口时跳过而不是判失败：这条用例验的是编辑管线的行为，不是窗口有没有
        guard let textView = makeEditor(source) else {
            throw XCTSkip("拿不到可用窗口，没法验证撤销")
        }
        defer { textView.removeFromSuperview() }

        let at = caret ?? textView.documentStore.renderedLength
        textView.selectedRange = NSRange(location: at, length: 0)

        // ⚠️ 先问一遍 delegate，再决定要不要真插字符（别直接 `insertText`）。
        // 列表续写是**在 `shouldChangeTextIn` 里接管回车**的，而 `UITextView.insertText` 实测不会问 delegate ——不走这一趟的话，「打字」走的是系统那条路、「撤销后重做」却走了续写那条路，两边结果不一样，用例会因为这种假象红掉（真实键盘输入是会问 delegate 的）。
        let range = NSRange(location: at, length: 0)
        if textView.delegate?.textView?(textView, shouldChangeTextIn: range, replacementText: typed) == false {
            // 编辑器已经自己接管了这次输入（列表续写 / 退出列表），不用再插
        } else {
            textView.insertText(typed)
        }
        let afterTyping = textView.documentStore.sourceDocument

        textView.undoManager?.undo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let afterUndo = textView.documentStore.sourceDocument
        XCTAssertEqual(afterUndo, source,
                       "撤销没回到原样：源码「\(source)」在 \(at) 处输入「\(typed)」后撤销成了「\(afterUndo)」",
                       file: file, line: line)

        textView.undoManager?.redo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let afterRedo = textView.documentStore.sourceDocument
        XCTAssertEqual(afterRedo, afterTyping,
                       "重做没回到刚输入完的样子：期望「\(afterTyping)」，实际「\(afterRedo)」",
                       file: file, line: line)
    }

    /// 无序列表：用户报的就是这个 —— 在列表项后面打字，⌘Z 完全没反应。
    func testTypingInUnorderedListCanBeUndone() throws {
        try assertTypingIsUndoable("- 1\n- 2\n", caret: 8, typed: "3")   // 光标在「2」后面
        try assertTypingIsUndoable("- 1\n- 2\n", typed: "3")             // 文末 → 懒惰延续
        try assertTypingIsUndoable("- 1\n- 2\n", caret: 9, typed: "\n")  // 列表中间回车
    }

    /// 代码块：闭合围栏后面接着打字会让围栏失效，整块重新解析 —— 最容易把长度搞崩的地方。
    func testTypingAroundCodeFenceCanBeUndone() throws {
        try assertTypingIsUndoable("```\ncode\n```", typed: "3")     // 紧贴闭合围栏后面
        try assertTypingIsUndoable("```\ncode\n```\n", typed: "3")   // 围栏后面已有换行
        try assertTypingIsUndoable("```\ncode", typed: "3")          // 还没闭合，正在敲
        try assertTypingIsUndoable("```\ncode\n```", caret: 6, typed: "3")  // 代码正文中间
    }

    /// 其它常见语法扫一遍，确保没有别的地方把长度搞崩。
    func testTypingInOtherSyntaxCanBeUndone() throws {
        try assertTypingIsUndoable("> 引用\n", typed: "3")
        try assertTypingIsUndoable("# 标题\n", typed: "3")
        try assertTypingIsUndoable("---\n", typed: "3")
        try assertTypingIsUndoable("**粗体** 正文", typed: "3")
        try assertTypingIsUndoable("| a | b |\n| - | - |\n| 1 | 2 |\n", typed: "3")
        try assertTypingIsUndoable("段落一\n\n段落二", typed: "3")
    }
}
