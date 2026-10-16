//
//  MarkdownUnderlineTests.swift
//  MarkdownEditorHy4Tests
//
//  `<u>重点</u>` 的渲染和导出：标签之间**有**下划线，标签本身**没有**，导出成 HTML 时这两个标签还得原样留着。
//
//  ### 守的是哪个现象
//  markdown 没有下划线语法，⌘U 是往源码里写 `<u>…</u>`（理由见 `toggleUnderlineMarkdown`）。
//  以前这两个标签只是按「语法标记」显示成灰字，中间那段文字一点变化都没有 —— 用户按了 ⌘U，屏幕上毫无反应，看着像快捷键坏了。
//  更糟的是导出 HTML 时它俩被当成「手写的 HTML」转义掉，导出来是 `&lt;u&gt;重点&lt;/u&gt;` 这样一串符号。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

final class MarkdownUnderlineTests: XCTestCase {

    // MARK: - 小工具

    private func render(_ source: String) -> NSAttributedString {
        let renderer = MarkupToAttributedRenderer(theme: MarkdownTheme.default, containerWidth: 600)
        return renderer.render(blockSource: source).text
    }

    /// 渲染串里**带下划线**的那些区间（按出现顺序）。
    ///
    /// `.underlineStyle` 为 0 表示「没有下划线」，系统就是这么表示缺省的，所以这里按 `!= 0` 过滤。
    private func underlinedRanges(in text: NSAttributedString) -> [NSRange] {
        var out: [NSRange] = []
        let full = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.underlineStyle, in: full, options: []) { value, range, _ in
            guard let raw = value as? Int, raw != 0 else { return }
            out.append(range)
        }
        return out
    }

    /// `needle` 在渲染串里的范围（找不到就是 `NSRange(location: NSNotFound, ...)`）
    private func range(of needle: String, in text: NSAttributedString) -> NSRange {
        (text.string as NSString).range(of: needle)
    }

    /// `needle` 这一段是不是**整段**都带下划线
    private func isFullyUnderlined(_ needle: String,
                                   in text: NSAttributedString,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) -> Bool {
        let target = range(of: needle, in: text)
        guard target.location != NSNotFound else {
            XCTFail("渲染串里没有「\(needle)」：\(text.string)", file: file, line: line)
            return false
        }
        return underlinedRanges(in: text).contains { NSIntersectionRange($0, target).length == target.length }
    }

    /// `needle` 这一段是不是**一点**下划线都没有
    private func isNotUnderlined(_ needle: String,
                                 in text: NSAttributedString,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) -> Bool {
        let target = range(of: needle, in: text)
        guard target.location != NSNotFound else {
            XCTFail("渲染串里没有「\(needle)」：\(text.string)", file: file, line: line)
            return false
        }
        return !underlinedRanges(in: text).contains { NSIntersectionRange($0, target).length > 0 }
    }

    /// 导出成 HTML 后 `<main>` 里的正文（CSS 里也有 `u` 这种字母，整份比对会误判）
    private func exportedBody(_ markdown: String) -> String {
        let html = MarkdownHTMLExporter.export(markdown: markdown,
                                               title: "标题",
                                               options: MarkdownHTMLExporter.Options(style: .builtIn))
        guard let start = html.range(of: "<main class=\"markdown-body\">"),
              let end = html.range(of: "</main>", range: start.upperBound..<html.endIndex) else { return html }
        return String(html[start.upperBound..<end.lowerBound])
    }

    // MARK: - 渲染

    /// 标签之间那段文字必须有下划线 —— 这就是用户按 ⌘U 之后唯一看得到的变化
    func testContentBetweenTagsIsUnderlined() {
        let text = render("正文 <u>重点</u> 收尾")
        XCTAssertTrue(isFullyUnderlined("重点", in: text), "`<u>` 和 `</u>` 中间那几个字该有下划线")
    }

    /// `<u>` 和 `</u>` 这两个词本身不该有下划线（它们是语法标记，不是正文）
    func testTagsThemselvesAreNotUnderlined() {
        let text = render("正文 <u>重点</u> 收尾")
        XCTAssertTrue(isNotUnderlined("<u>", in: text), "开标签不该带下划线")
        XCTAssertTrue(isNotUnderlined("</u>", in: text), "闭标签不该带下划线")
        XCTAssertTrue(isNotUnderlined("正文 ", in: text), "标签外面的正文也不该被连累")
    }

    /// 下划线得是「单线」，同时字体和颜色不能被动过（用户配的字号 / 配色照旧生效）
    func testUnderlineUsesThemeStyleWithoutChangingFont() {
        let text = render("正文 <u>重点</u>")
        let target = range(of: "重点", in: text)
        let style = text.attribute(.underlineStyle, at: target.location, effectiveRange: nil) as? Int
        XCTAssertEqual(style, NSUnderlineStyle.single.rawValue, "默认画一条细线")

        let font = text.attribute(.font, at: target.location, effectiveRange: nil) as? UIFont
        XCTAssertEqual(font, MarkdownTheme.default.bodyFont, "加下划线不该顺手把字体换了")
    }

    /// 只写了一个 `<u>`、忘了闭：下划线不能一路淌到下一个块去
    func testUnclosedTagDoesNotLeakIntoNextBlock() {
        let theme = MarkdownTheme.default
        let renderer = MarkupToAttributedRenderer(theme: theme, containerWidth: 420)
        let store = MarkdownDocumentStore(renderer: renderer)
        store.load(markdown: "AAA <u>BBB\n\nCCC DDD", containerWidth: 420)

        let text = store.attributedDocument
        XCTAssertTrue(isFullyUnderlined("BBB", in: text), "同一个块里，`<u>` 之后的文字照旧有下划线")
        XCTAssertTrue(isNotUnderlined("CCC DDD", in: text), "换了一个块就该重新来过，不该接着上一个块没闭的标签")
    }

    /// 带属性的写法（`<u class="x">`）不认 —— 白名单只放行干干净净的那两个标签
    func testTaggedWithAttributesIsNotTreatedAsUnderline() {
        let text = render("正文 <u class=\"x\">重点</u>")
        XCTAssertTrue(isNotUnderlined("重点", in: text), "带属性的 `<u>` 不认，免得把「想表达什么」猜错")
    }

    // MARK: - 导出成 HTML

    /// 导出的 HTML 里 `<u>…</u>` 要原样留着 —— 编辑器里有下划线，导出来却是一串 `&lt;u&gt;` 就说不过去
    func testExportKeepsUnderlineTags() {
        let body = exportedBody("正文 <u>重点</u> 收尾")
        XCTAssertTrue(body.contains("<u>重点</u>"), "下划线标签要原样输出，实际是：\(body)")
    }

    /// 别的行内 HTML 一律照旧转义 —— 放行 `<u>` 不等于给所有标签开门
    func testExportStillEscapesOtherInlineHTML() {
        let body = exportedBody("正文 <b>粗</b> 收尾")
        XCTAssertTrue(body.contains("&lt;b&gt;"), "<b> 该转义，实际是：\(body)")
        XCTAssertFalse(body.contains("<b>"), "转义之后不该再出现真的 <b> 标签")
    }

    /// 带属性的 `<u>` 也要转义：白名单比的是**整串**，多了几个字符就不是白名单里那一个了
    func testExportEscapesUnderlineTagWithAttributes() {
        let body = exportedBody("<u onclick=\"alert(1)\">重点</u>")
        XCTAssertFalse(body.contains("<u onclick"), "带属性的标签不能放行")
        XCTAssertTrue(body.contains("&lt;u"), "该转义，实际是：\(body)")
    }

    /// 整块 HTML（`<div>` 那类）的规矩没变，照样转义
    func testExportStillEscapesHTMLBlock() {
        let body = exportedBody("<div>一块手写 HTML</div>")
        XCTAssertTrue(body.contains("&lt;div&gt;"), "整块 HTML 照旧转义，实际是：\(body)")
    }
}
