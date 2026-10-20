import XCTest
import UIKit
@testable import MarkdownEditorHy4

/// 换文档时光标必须归零。
///
/// ### 这个 bug 长什么样
/// 打开另一份文档后，光标还停在上一份文档的那个偏移上（`replaceCharacters` 只会把旧位置夹进新文本长度，不会清掉）。
/// 用户滚到文末按回车，换行却插进了文档中间 —— 看起来就像「光标突然跳到第 54 行」。
final class MarkdownCaretAcrossDocumentsTests: XCTestCase {

    func testSwitchingDocumentResetsCaret() {
        let textView = makeEditor(String(repeating: "上一份文档的正文。\n\n", count: 200))
        textView.selectedRange = NSRange(location: 1500, length: 0)
        XCTAssertEqual(textView.selectedRange.location, 1500, "前置条件：光标先停在上一份文档的中间")

        textView.setMarkdown("# 另一份文档\n\n内容。")
        textView.layoutIfNeeded()

        XCTAssertEqual(textView.selectedRange.location, 0, "换文档后光标必须归零，不能把上一份文档的位置带过来")
    }

    func testEnterAfterSwitchingDocumentLandsAtStart() {
        let textView = makeEditor(String(repeating: "上一份文档的正文。\n\n", count: 200))
        textView.selectedRange = NSRange(location: 1500, length: 0)

        textView.setMarkdown("第一段。\n\n第二段。")
        textView.layoutIfNeeded()
        textView.insertText("\n")

        let source = textView.documentStore.sourceDocument as NSString
        XCTAssertTrue(source.hasPrefix("\n"),
                      "换文档后按回车，换行应该插在文档开头，实际开头是「\(source.substring(to: min(20, source.length)))」")
        XCTAssertEqual(textView.documentStore.sourceCaret(forRenderedOffset: textView.selectedRange.location), 1,
                       "光标应该停在新换行后面")
    }

    /// 整篇归零不能顺手把撤销兜底弄坏：`restoreDocument` 需要把光标放回指定位置。
    func testRestoreDocumentStillPlacesCaret() {
        let textView = makeEditor("开始")
        textView.restoreDocument(source: "abc", caret: 2)
        XCTAssertEqual(textView.selectedRange.location, 2, "撤销兜底的整篇恢复要能把光标放回指定位置")
    }

    private func makeEditor(_ markdown: String) -> MarkdownTextView {
        let textView = MarkdownTextView()
        textView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        textView.layoutIfNeeded()
        textView.setMarkdown(markdown)
        textView.layoutIfNeeded()
        return textView
    }
}
