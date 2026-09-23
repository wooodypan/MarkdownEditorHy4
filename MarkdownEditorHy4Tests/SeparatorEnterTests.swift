//
//  SeparatorEnterTests.swift
//  MarkdownEditorHy4Tests
//
//  分隔线（`---`）末尾按回车的行为。
//
//  ### 这个 bug 长什么样（2026-09-20 修）
//  光标停在 sample.md 第 49 行那根 `---` 的末尾按回车：**什么都没发生**。
//  源码里其实多了一个换行，但屏幕上不多一行、光标也不往下走，用户看到的就是「按了没反应」。
//
//  ### 根因（一句话）
//  分隔线在渲染串里只占 1 个字符位（一条横线 attachment），可 cmark 给它的源码 range 会把后面的空行一起圈进来；attachment 照着 range 全认领，多出来的换行就既没有渲染字符、也不会被补漏步骤补上 —— 在屏幕上凭空消失了。
//
//  ### 这里守的判据（都是用户看得见的）
//  1. 按一次回车，源码 +1 个换行，**屏幕上也要 +1 行**；
//  2. 连按两次就真的多两行（不能只有第一次有效）；
//  3. 光标要停到新那一行上，不然后面再按回车又「没反应」；
//  4. `---` 后只有一个空行这种最常见的老写法，渲染结果不变（别顺手把老文档的间距改了）；
//  5. 改完照样「全选复制 === 源文件」。
//
//  ⚠️ 「光标停在 `---` 末尾」= 源码里那一行 `---` 的**右边界**（`---` 后面那个偏移），别拿搜索串的长度当偏移量 —— 搜索串里多带一个 `\n\n正` 的话，光标就跑到别的行去了，测试会假绿（这条踩过）。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

final class SeparatorEnterTests: XCTestCase {

    /// 样例文档里那段：表格、空行、`---`、空行、标题（等价于 sample.md 第 49 行）
    private let sampleLike = "| 姓名 | 年龄 |\n| --- | --- |\n| 张三 | 18 |\n\n---\n\n## 七、动手试一下\n\n正文。\n"

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

    /// 渲染串里有几个换行（屏幕上的行数就靠它）
    private func newlineCount(_ textView: MarkdownTextView) -> Int {
        (textView.text ?? "").filter { $0 == "\n" }.count
    }

    /// 把光标放到源码 `offset` 对应的渲染位置，并返回那个渲染位置（用户就是用鼠标点那儿）
    @discardableResult
    private func placeCaret(atSourceOffset offset: Int, in textView: MarkdownTextView) -> Int {
        let caret = textView.documentStore.renderedCaret(forSourceOffset: offset)
        textView.selectedRange = NSRange(location: caret, length: 0)
        return caret
    }

    /// 核心回归：样例文档里在分隔线末尾按一次回车，屏幕上必须真的多出一行。
    func testEnterAtSeparatorLineEndAddsVisibleLine() {
        let textView = makeEditor(sampleLike)
        let store = textView.documentStore

        // 表格分隔行里的 `---` 不算，`\n\n---\n` 只匹配到第 49 行那一根；`+ 5` 就是它右边那个偏移
        let separator = (sampleLike as NSString).range(of: "\n\n---\n")
        XCTAssertNotEqual(separator.location, NSNotFound, "测试文档里应该能找到那根独立的分隔线")
        let separatorEnd = separator.location + 2 + 3

        let sourceNewlinesBefore = sampleLike.filter { $0 == "\n" }.count
        let renderedNewlinesBefore = newlineCount(textView)
        let caret = placeCaret(atSourceOffset: separatorEnd, in: textView)

        textView.insertText("\n")

        XCTAssertEqual(store.sourceDocument.filter { $0 == "\n" }.count, sourceNewlinesBefore + 1,
                       "按一次回车，源码只该多 1 个换行")
        XCTAssertEqual(newlineCount(textView), renderedNewlinesBefore + 1,
                       "屏幕上必须真的多出 1 行。源码多了换行、画面却一动不动，就是这个 bug 的全部症状")
        XCTAssertEqual(textView.selectedRange.location, caret + 1,
                       "光标要跟着往下走一行；不动的话用户第二次按回车还是「没反应」")
    }

    /// 连按两次回车：要真的多两行（防「只有第一次有效」这种修法）
    func testEnterTwiceAtSeparatorLineEndAddsTwoLines() {
        let markdown = "---\n\n正文。\n"
        let textView = makeEditor(markdown)
        let sourceNewlinesBefore = markdown.filter { $0 == "\n" }.count
        let renderedNewlinesBefore = newlineCount(textView)

        placeCaret(atSourceOffset: 3, in: textView)      // `---` 的右边界
        textView.insertText("\n")
        textView.insertText("\n")

        XCTAssertEqual(textView.documentStore.sourceDocument.filter { $0 == "\n" }.count, sourceNewlinesBefore + 2,
                       "连按两次回车，源码该多 2 个换行")
        XCTAssertEqual(newlineCount(textView), renderedNewlinesBefore + 2,
                       "连按两次回车，屏幕上该多 2 行")
    }

    /// `---` 后面只跟一个空行（最常见的老写法）：横线和下文之间还是只空一行。
    ///
    /// 这条是防「修 bug 顺手把版面改了」—— 只要分隔线块渲染出的换行数变了，所有老文档里分隔线上下的间距都会跟着变。
    func testSeparatorKeepsSingleBlankLineBelow() throws {
        let store = MarkdownDocumentStore()
        store.load(markdown: "---\n\n正文。\n", containerWidth: 600)

        let separator = try XCTUnwrap(store.blocks.first { $0.kindDescription.contains("Thematic") },
                                      "文档里应该切出一个分隔线块")
        XCTAssertEqual(separator.renderedContent.string.filter { $0 == "\n" }.count, 1,
                       "横线和下面正文之间应该只空一行（老文档的间距不能变）")
    }

    /// 在分隔线末尾按完回车，「全选复制 === 源文件」这条不变量还得成立。
    func testCopyStillMatchesSourceAfterEnterAtSeparator() {
        let textView = makeEditor("---\n\n正文。\n")
        let store = textView.documentStore

        placeCaret(atSourceOffset: 3, in: textView)
        textView.insertText("\n")

        let restored = store.sourceText(forRenderedRange: NSRange(location: 0, length: store.renderedLength))
        XCTAssertEqual(restored, store.sourceDocument,
                       "回车之后全选复制出来的还是源码本身（附件认领范围一改，这里最容易漏字符）")
    }
}
