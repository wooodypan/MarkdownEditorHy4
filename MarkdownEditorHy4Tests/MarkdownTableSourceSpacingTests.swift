//
//  MarkdownTableSourceSpacingTests.swift
//  MarkdownEditorHy4Tests
//
//  表格源码的**行距**：相邻两行要只剩自然行距，不能再吃一份段距。
//
//  ### 守的是哪个现象
//  表格图下面那几行 `| a | b |` 源码，每一行都以 `\n` 结尾，而 `\n` 在 TextKit 里就是**段落分隔符** —— 每行都是独立段落，段后各吃一份 `paragraphSpacing`（默认 12）。
//  实测相邻两行相距 30pt（12 段距 + 18 自然行高），看着跟「两段正文之间的间距」一样大，源码散成了好几段。
//  修法是把这几行的段距归零，行与行只剩字体自带的自然行距，和「一段长文本折行」一个观感。
//
//  ### 不能顺手把整块的间距也归零
//  源码上面是表格图（附件段落自带段后），下面是下一段正文。只该收**行与行之间**那一份，块与块之间的距离必须留着。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

final class MarkdownTableSourceSpacingTests: XCTestCase {

    private let markdown = """
    正文第一行 AAA
    正文第二行 BBB

    | 列一 | 列二 |
    | --- | --- |
    | 甲 | 乙 |
    | 丙 | 丁 |

    正文第三段 CCC
    """

    /// 表格源码的那几行（按渲染顺序）
    private let sourceLines = ["| 列一 | 列二 |", "| --- | --- |", "| 甲 | 乙 |", "| 丙 | 丁 |"]

    private func render(_ markdown: String,
                        theme: MarkdownTheme = .default) -> (text: NSAttributedString, theme: MarkdownTheme) {
        let renderer = MarkupToAttributedRenderer(theme: theme, containerWidth: 420)
        let store = MarkdownDocumentStore(renderer: renderer)
        store.load(markdown: markdown, containerWidth: 420)
        return (store.attributedDocument, theme)
    }

    /// 某一行源码的段落样式（按渲染串里的位置取，不按 attribute run 取 —— 整段源码常常是同一个 run）
    private func paragraphStyle(of line: String, in text: NSAttributedString) throws -> NSParagraphStyle {
        let string = text.string as NSString
        let range = string.range(of: line)
        XCTAssertNotEqual(range.location, NSNotFound, "渲染结果里找不到「\(line)」")
        return try XCTUnwrap(text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
    }

    // MARK: - 段落样式

    /// 表格源码每一行：段前段后**都必须是 0** —— 行与行之间只剩自然行距
    func testTableSourceLinesHaveNoParagraphSpacing() throws {
        let (text, _) = render(markdown)
        for line in sourceLines {
            let style = try paragraphStyle(of: line, in: text)
            XCTAssertEqual(style.paragraphSpacingBefore, 0, accuracy: 0.001, "「\(line)」不该有段前间距")
            XCTAssertEqual(style.paragraphSpacing, 0, accuracy: 0.001, "「\(line)」不该有段后间距")
        }
    }

    /// 缩进不能跟着一起丢：列表里的表格要靠 `headIndent` 对齐
    func testTableSourceKeepsIndentAndLineHeight() throws {
        let (text, _) = render(markdown)
        let style = try paragraphStyle(of: "| 列一 | 列二 |", in: text)
        XCTAssertEqual(style.headIndent, 0, accuracy: 0.001)
        XCTAssertEqual(style.firstLineHeadIndent, 0, accuracy: 0.001)

        // 行高倍数只在用户调过（> 1）时才写进段落样式，默认这里应当和正文一致
        var custom = MarkdownTheme.default
        custom.lineHeightMultiple = 1.6
        let (scaled, _) = render(markdown, theme: custom)
        let scaledStyle = try paragraphStyle(of: "| 列一 | 列二 |", in: scaled)
        XCTAssertEqual(scaledStyle.lineHeightMultiple, 1.6, accuracy: 0.001, "用户调过行高，表格源码要跟着走")
    }

    /// 正文那套段距没被误伤：两段正文之间仍然是 12
    func testBodyParagraphSpacingIsUntouched() throws {
        let (text, theme) = render(markdown)
        let style = try paragraphStyle(of: "正文第一行 AAA", in: text)
        XCTAssertEqual(style.paragraphSpacing, theme.paragraphSpacing, accuracy: 0.001)
    }

    // MARK: - 真实排版后的距离

    /// 量两条线的实际距离：只验段落样式不够，TextKit 2 会无视一部分属性
    @MainActor
    func testTableSourceLineSpacingDropsToNaturalLineHeight() throws {
        let textView = MarkdownTextView(markdown: markdown)
        textView.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        textView.layoutIfNeeded()
        textView.setNeedsLayout()
        textView.layoutIfNeeded()

        let string = textView.textStorage.string as NSString
        let begin = textView.beginningOfDocument
        func caret(_ needle: String) throws -> CGRect {
            let range = string.range(of: needle)
            XCTAssertNotEqual(range.location, NSNotFound, "渲染结果里找不到「\(needle)」")
            let position = try XCTUnwrap(textView.position(from: begin, offset: range.location))
            return textView.caretRect(for: position)
        }

        let lineHeight = textView.renderer.theme.tableSourceFont.lineHeight
        for (upper, lower) in zip(sourceLines, sourceLines.dropFirst()) {
            let gap = try caret(lower).minY - caret(upper).minY
            XCTAssertLessThan(gap, lineHeight + 3,
                              "「\(upper)」和「\(lower)」之间多空了一截（实测 \(gap)pt，自然行高 \(lineHeight)pt）")
            XCTAssertGreaterThan(gap, lineHeight - 3, "两行贴得太近了（实测 \(gap)pt，自然行高 \(lineHeight)pt）")
        }
    }

    /// 只收行间那一份：表格源码最后一行和下一段之间得留出距离，不能跟着一起归零
    @MainActor
    func testTableSourceKeepsDistanceFromFollowingParagraph() throws {
        let textView = MarkdownTextView(markdown: markdown)
        textView.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        textView.layoutIfNeeded()
        textView.setNeedsLayout()
        textView.layoutIfNeeded()

        let string = textView.textStorage.string as NSString
        let begin = textView.beginningOfDocument
        func caret(at offset: Int) throws -> CGRect {
            let position = try XCTUnwrap(textView.position(from: begin, offset: offset))
            return textView.caretRect(for: position)
        }

        let lastLine = string.range(of: "| 丙")
        let nextBody = string.range(of: "CCC")
        XCTAssertNotEqual(lastLine.location, NSNotFound)
        XCTAssertNotEqual(nextBody.location, NSNotFound)

        let lastBottom = try caret(at: lastLine.location).maxY
        let nextTop = try caret(at: nextBody.location).minY
        XCTAssertGreaterThan(nextTop - lastBottom, 6, "表格源码和下一段几乎贴住了")
    }

    // MARK: - Mermaid 的源码提示（共用同一份样式）

    /// Mermaid 图下面那几行源码同样收紧 —— 它和表格源码共用 `tableSourceParagraphStyle`
    @MainActor
    func testMermaidSourceHintAlsoTightens() throws {
        final class Stub: MarkdownMermaidRenderer {
            func image(for request: MarkdownMermaidRequest) -> UIImage? {
                UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100)).image { context in
                    UIColor.gray.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
                }
            }
        }

        let source = "```mermaid\nflowchart TD\n  A --> B\n```\n"
        let renderer = MarkupToAttributedRenderer(theme: .default, containerWidth: 600)
        renderer.mermaidRenderer = Stub()
        let (text, _) = renderer.render(blockSource: source)

        let string = text.string as NSString
        for line in ["flowchart TD", "A --> B", "```"] {
            let range = string.range(of: line)
            XCTAssertNotEqual(range.location, NSNotFound, "渲染结果里找不到「\(line)」")
            let style = try XCTUnwrap(text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(style.paragraphSpacingBefore, 0, accuracy: 0.001, "「\(line)」不该有段前间距")
            XCTAssertEqual(style.paragraphSpacing, 0, accuracy: 0.001, "「\(line)」不该有段后间距")
        }
    }
}
