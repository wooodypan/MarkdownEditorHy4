//
//  MarkdownIncrementalSyncTests.swift
//  MarkdownEditorHy4Tests
//
//  每次编辑那条「记账」链路的验收测试 —— 它只该碰改动点那一小块。
//
//  ### 背景
//  早先每敲一个字都会把整篇文档走好几遍：把所有块的渲染文本重新拼成一个整篇字符串、把所有块的范围重算一遍、把所有标题拍一次指纹、从头扫一遍找光标落在哪个块。
//  这些地方现在都改成了增量（局部替换 / 从受影响处往后算 / 二分定位），行为必须和原来**完全一样**，否则症状是「改一个字，别处冒出乱码」——很难复现，所以专门守在这里。
//
//  ### 这里守的三条
//  1. **同步串不漂移**：增量维护出来的「模型认为的渲染文本」要和整篇重建的结果始终一致；
//  2. **落点不错块**：在中间某一块、以及折叠区之后打字，都要落进正确的块（二分定位的边界）；
//  3. **源码不乱**：连续输入 + 删除之后，源码还是「原来那些段落 + 改动」。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownIncrementalSyncTests: XCTestCase {

    // MARK: 小工具

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

    /// 把光标挪到渲染文本里某段文字的末尾
    private func putCaretAfter(_ needle: String, in textView: MarkdownTextView, file: StaticString = #filePath, line: UInt = #line) {
        let plain = textView.text as NSString
        let range = plain.range(of: needle)
        guard range.location != NSNotFound else {
            XCTFail("渲染文本里找不到「\(needle)」", file: file, line: line)
            return
        }
        textView.selectedRange = NSRange(location: NSMaxRange(range), length: 0)
    }

    // MARK: 同步串不漂移

    /// 连续敲一串字，每敲一个都要和「模型整篇重建」的结果对得上。
    ///
    /// 局部替换要是漏了哪一段，下一轮 diff 会把这点偏差当成用户输入写回源码 ——症状是「改一个字，别处冒出乱码」，所以每敲一个字都核一遍。
    func testSyncedStringMatchesModelAfterEveryKeystroke() {
        let tv = makeEditor("# 标题\n第一段\n\n第二段\n")
        putCaretAfter("第二段", in: tv)

        for (index, character) in "继续打字看看".enumerated() {
            tv.insertText(String(character))
            XCTAssertTrue(tv.lastSyncedStringMatchesModel,
                          "敲完第 \(index + 1) 个字，增量维护的同步串就和模型对不上了")
        }
    }

    /// 删掉一批字符之后也要对得上（替换范围比插入更难算对）
    func testSyncedStringMatchesModelAfterDeletes() {
        let tv = makeEditor("# 标题\n第一段\n\n第二段\n")
        putCaretAfter("第二段", in: tv)

        for _ in 0..<3 {
            tv.deleteBackward()
            XCTAssertTrue(tv.lastSyncedStringMatchesModel, "退格之后同步串就和模型对不上了")
        }
        XCTAssertTrue(tv.markdownSource.contains("第一段"), "删第二段的字不该动到第一段")
    }

    // MARK: 落点不错块

    /// 在**中间**某一块的末尾打字：字符要落进那一块，不能跑到别的块去
    func testTypingInTheMiddleBlockStaysInThatBlock() {
        let tv = makeEditor("第一段\n\n第二段\n\n第三段\n")
        putCaretAfter("第二段", in: tv)

        tv.insertText("插")

        XCTAssertTrue(tv.markdownSource.contains("第二段插"), "字符要落在光标所在的那一块里")
        XCTAssertTrue(tv.markdownSource.contains("第一段"), "前面的块不该被改到")
        XCTAssertTrue(tv.markdownSource.contains("第三段"), "后面的块不该被改到")
    }

    /// 折叠一节之后，在折叠区**后面**打字：定位要跳过那些被隐藏的块
    ///
    /// 隐藏块的源码照旧占着长度（只是屏幕上不显示），二分定位命中它们之后必须往后跳，否则光标会落进折叠起来的那一节里 —— 表现为「在文末打字，字却跑到收起来的章节中」。
    func testTypingAfterACollapsedSectionLandsAfterIt() {
        let tv = makeEditor("## 甲\n甲的内容\n\n## 乙\n乙的内容\n\n## 丙\n丙的内容\n")

        guard let target = tv.documentStore.blocks.first(where: { $0.headingTitle?.contains("乙") == true }) else {
            XCTFail("没找到「## 乙」这个标题块")
            return
        }
        tv.toggleCollapse(blockID: target.id)

        putCaretAfter("丙的内容", in: tv)
        tv.insertText("尾")

        XCTAssertTrue(tv.markdownSource.contains("丙的内容尾"), "字要落在折叠区之后那个可见块里")
        XCTAssertTrue(tv.markdownSource.contains("乙的内容"), "折叠只是不显示，源码一个字都不能少")
        XCTAssertTrue(tv.lastSyncedStringMatchesModel, "折叠状态下编辑，同步串也要和模型对得上")
    }

    // MARK: 源码不乱

    /// 连续输入 + 删除混着来一轮，源码要回到「原来那些段落 + 改动」的样子
    func testSourceStaysIntactThroughTypingAndDeleting() {
        let tv = makeEditor("甲\n\n乙\n\n丙\n")
        putCaretAfter("乙", in: tv)

        tv.insertText("12")
        tv.deleteBackward()
        tv.insertText("3")

        XCTAssertEqual(tv.markdownSource, "甲\n\n乙13\n\n丙\n", "改中间那段，前后两段必须原样留着")
    }
}
