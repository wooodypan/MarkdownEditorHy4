//
//  MarkdownTableInlineStyleTests.swift
//  MarkdownEditorHy4
//
//  表格单元格里的行内 Markdown：粗体 / 斜体 / 删除线 / 行内代码 / 链接。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownTableInlineStyleTests: XCTestCase {

    private let theme = MarkdownTheme.default

    // MARK: 小工具

    /// 渲染一段表格源码，把表格 attachment 挖出来
    private func attachment(for source: String) throws -> MarkdownTableAttachment {
        let renderer = MarkupToAttributedRenderer(theme: theme, containerWidth: 700)
        let (text, _) = renderer.render(blockSource: source)

        var found: MarkdownTableAttachment?
        text.enumerateAttribute(.attachment,
                                in: NSRange(location: 0, length: text.length),
                                options: []) { value, _, stop in
            if let table = value as? MarkdownTableAttachment {
                found = table
                stop.pointee = true
            }
        }
        return try XCTUnwrap(found, "没有渲染出 MarkdownTableAttachment")
    }

    /// 取单元格里某段文字的属性；找不到返回 nil
    private func attributes(in cell: NSAttributedString,
                            for needle: String) -> [NSAttributedString.Key: Any]? {
        let range = (cell.string as NSString).range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return cell.attributes(at: range.location, effectiveRange: nil)
    }

    // MARK: 测试

    /// 五种行内语法都要显示成对应样式，标记符一个都不能留在格子里
    func testCellRendersInlineStylesAndHidesMarkers() throws {
        let source = "| 样式 |\n| --- |\n| **粗体** *斜体* ~~删除~~ `代码` [链接](https://example.com) |\n"
        let attachment = try attachment(for: source)
        let cell = attachment.data.attributedText(row: 1, column: 0)

        // 源码本来就该保留标记符（下面的源码行要靠它编辑和复制）
        XCTAssertTrue(attachment.markdownSource.contains("**粗体**"))
        XCTAssertTrue(attachment.markdownSource.contains("`代码`"))
        XCTAssertTrue(attachment.markdownSource.contains("[链接](https://example.com)"))

        // 但图片里的文字不能带标记符
        XCTAssertFalse(cell.string.contains("**"), "粗体标记不该出现在单元格里")
        XCTAssertFalse(cell.string.contains("~~"), "删除线标记不该出现在单元格里")
        XCTAssertFalse(cell.string.contains("`"), "行内代码的反引号不该出现在单元格里")
        XCTAssertFalse(cell.string.contains("]("), "链接语法不该出现在单元格里")
        XCTAssertFalse(cell.string.contains("https://"), "链接地址不该出现在单元格里")
        XCTAssertTrue(cell.string.contains("粗体"))
        XCTAssertTrue(cell.string.contains("斜体"))
        XCTAssertTrue(cell.string.contains("删除"))
        XCTAssertTrue(cell.string.contains("代码"))
        XCTAssertTrue(cell.string.contains("链接"))

        // 粗体
        let boldAttributes = try XCTUnwrap(attributes(in: cell, for: "粗体"))
        let boldFont = try XCTUnwrap(boldAttributes[.font] as? UIFont)
        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.traitBold),
                      "「粗体」应该是粗体字")

        // 斜体：中文还要叠仿斜矩阵，否则汉字不会歪。
        // `.matrix` 是请求值，读 `fontDescriptor.fontAttributes` 拿不回来（系统会归一化掉），
        // 所以这里和正文渲染的测试一样，比字体本身：同族但和普通斜体不同 = 矩阵生效了
        let italicAttributes = try XCTUnwrap(attributes(in: cell, for: "斜体"))
        let italicFont = try XCTUnwrap(italicAttributes[.font] as? UIFont)
        XCTAssertTrue(italicFont.fontDescriptor.symbolicTraits.contains(.traitItalic),
                      "「斜体」应该带斜体特征")
        let plainItalic = theme.bodyFont.adding(.traitItalic)
        XCTAssertNotEqual(italicFont, plainItalic,
                          "中文没有真斜体字形，应该叠仿斜矩阵（字体该和普通斜体不同）")
        XCTAssertEqual(italicFont.fontName, plainItalic.fontName,
                       "仿斜只该加矩阵，不该把中文换成别的字体")

        // 删除线
        let strikeAttributes = try XCTUnwrap(attributes(in: cell, for: "删除"))
        let strike = (strikeAttributes[.strikethroughStyle] as? NSNumber)?.intValue
        XCTAssertEqual(strike, NSUnderlineStyle.single.rawValue, "「删除」应该有删除线")

        // 行内代码：等宽字体 + 底色
        let codeAttributes = try XCTUnwrap(attributes(in: cell, for: "代码"))
        let codeFont = try XCTUnwrap(codeAttributes[.font] as? UIFont)
        XCTAssertTrue(codeFont.isEqual(theme.codeFont), "行内代码应该用主题里的等宽字体")
        XCTAssertNotNil(codeAttributes[.backgroundColor], "行内代码应该有底色")

        // 链接：只显示文字，用主题里的链接色
        let linkAttributes = try XCTUnwrap(attributes(in: cell, for: "链接"))
        let linkColor = try XCTUnwrap(linkAttributes[.foregroundColor] as? UIColor)
        XCTAssertTrue(linkColor.isEqual(theme.linkColor), "链接文字应该用主题里的链接色")
    }

    /// 表头默认粗体，不需要用户再写 `**`
    func testHeaderIsBoldByDefault() throws {
        let source = "| 表头 |\n| --- |\n| 值 |\n"
        let attachment = try attachment(for: source)
        let cell = attachment.data.attributedText(row: 0, column: 0)
        let attributes = try XCTUnwrap(attributes(in: cell, for: "表头"))
        let font = try XCTUnwrap(attributes[.font] as? UIFont)

        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold),
                      "表头默认就是粗体")
    }

    /// 粗体套斜体要同时保留两个特征，不能后一个把前一个覆盖掉
    func testNestedStrongAndEmphasisCombine() throws {
        let source = "| 样式 |\n| --- |\n| ***重点*** |\n"
        let attachment = try attachment(for: source)
        let cell = attachment.data.attributedText(row: 1, column: 0)
        let attributes = try XCTUnwrap(attributes(in: cell, for: "重点"))
        let font = try XCTUnwrap(attributes[.font] as? UIFont)

        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertFalse(cell.string.contains("*"), "星号不该出现在单元格里")
    }

    /// 富文本单元格仍然要能正常画成 attachment 图片
    func testStyledCellStillRendersIntoTheAttachmentImage() throws {
        let source = "| 样式 |\n| --- |\n| **粗体** *斜体* ~~删除~~ `代码` [链接](https://example.com) |\n"
        let attachment = try attachment(for: source)

        XCTAssertNotNil(attachment.image, "普通表格仍然要画成图片")
        XCTAssertGreaterThan(attachment.bounds.width, 0)
        XCTAssertGreaterThan(attachment.bounds.height, 0)
    }
}
