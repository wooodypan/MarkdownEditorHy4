import XCTest
import UIKit
@testable import MarkdownEditorHy4

/// 「导出成 PDF」的测试。
///
/// ### 为什么只断言「是不是一份 PDF」而不比对像素
/// PDF 里的字是 WebKit 排的，字体、换行、分页位置随系统版本变 —— 逐像素比对的话，升级一次系统就得改一遍用例。
/// 这里只守**能坏的那几处**：产物是不是以 `%PDF` 开头（拿到的是不是真 PDF）、长文档有没有真的分成好几页。
/// 版式好不好看是肉眼看的事，交给导出后的目视检查。
final class MarkdownPDFExporterTests: XCTestCase {

    /// 把一份 markdown 排成 PDF。用 `async` 而不是 `wait(for:)`：
    /// 排版完成那个回调走主线程，测试要是把主线程堵在等待里，就永远等不到它。
    @MainActor
    private func makePDF(_ markdown: String) async -> MarkdownPDFExporter.PDF? {
        let html = MarkdownHTMLExporter.export(markdown: markdown,
                                               title: "测试文档",
                                               options: .init(style: .builtIn))
        return await withCheckedContinuation { continuation in
            MarkdownPDFExporter.makePDF(html: html, title: "测试文档") { pdf in
                continuation.resume(returning: pdf)
            }
        }
    }

    /// 产物得是一份真能打开的 PDF
    @MainActor
    func testProducesARealPDF() async {
        let pdf = await makePDF("# 标题\n\n正文一段。\n\n- 一\n- 二")
        guard let pdf else {
            XCTFail("PDF 没排出来（WebKit 没回调 / 排版器算出 0 页）")
            return
        }
        XCTAssertTrue(pdf.data.starts(with: "%PDF".utf8), "PDF 文件开头一定是 `%PDF` 这个标记")
        XCTAssertEqual(pdf.pageCount, 1, "这么短的文档就该是一页")
    }

    /// 长文档要真的分页 —— 只有一页的话，说明内容被压扁了或者排版器没拿到完整高度。
    @MainActor
    func testLongDocumentSpansSeveralPages() async {
        let paragraph = "这是用来撑页数的段落，重复很多次，直到一页 A4 装不下为止。"
        let markdown = (0..<80).map { "## 小节 \($0)\n\n\(paragraph)\n" }.joined(separator: "\n")
        let pdf = await makePDF(markdown)

        guard let pdf else {
            XCTFail("长文档没排出来")
            return
        }
        XCTAssertGreaterThan(pdf.pageCount, 1, "80 个小节不可能挤在一页里，分页没生效")
    }
}
