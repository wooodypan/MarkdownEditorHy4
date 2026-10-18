//
//  MarkdownTableCellPaddingTests.swift
//  MarkdownEditorHy4
//
//  单元格内边距：默认值，以及它怎么改列宽和行高。
//
//  ### 守的三条
//  1. 默认左右 20、上下 15，和设置页里的默认值对得上；
//  2. 内边距一变，列宽和行高跟着变 —— 左右加多少、列就宽多少，上下加多少、行就高多少；
//  3. 内边距再大也不能把文字区挤成负数：列宽下限会跟着内边距抬起来。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownTableCellPaddingTests: XCTestCase {

    /// 两列都写得足够长，列宽由内容说了算，不会被最小 / 最大列宽夹住
    private let source = """
    | 很长的中文表头甲 | 很长的中文表头乙 |
    | --- | --- |
    | 很长很长的一段中文内容甲 | 很长很长的一段中文内容乙 |
    | 短甲 | 短乙 |
    """

    /// 默认值来自渲染层主题：左右 20、上下 15
    func testDefaultCellPadding() {
        let table = MarkdownTheme.default.table
        XCTAssertEqual(table.cellPaddingHorizontal, 20, accuracy: 0.001, "左右默认 20pt")
        XCTAssertEqual(table.cellPaddingVertical, 15, accuracy: 0.001, "上下默认 15pt")
    }

    /// 内边距加多少，列宽 / 行高就加多少
    func testPaddingWidensColumnsAndRows() throws {
        // 上下限放开：这里只量内边距的影响，别让 maxColumnWidth 把列宽截住
        var compact = MarkdownTheme.default
        compact.table.cellPaddingHorizontal = 4
        compact.table.cellPaddingVertical = 4
        compact.table.minColumnWidth = 20
        compact.table.maxColumnWidth = 1000

        var roomy = MarkdownTheme.default
        roomy.table.cellPaddingHorizontal = 20
        roomy.table.cellPaddingVertical = 15
        roomy.table.minColumnWidth = 20
        roomy.table.maxColumnWidth = 1000

        let compactLayout = try layout(theme: compact)
        let roomyLayout = try layout(theme: roomy)

        XCTAssertEqual(compactLayout.columnWidths.count, 2)
        for column in 0..<2 {
            XCTAssertEqual(roomyLayout.columnWidths[column] - compactLayout.columnWidths[column],
                           32, accuracy: 0.01,
                           "左右各多 16pt，第 \(column) 列就该宽 32pt")
        }
        XCTAssertEqual(roomyLayout.totalWidth - compactLayout.totalWidth, 64, accuracy: 0.01,
                       "两列各宽 32pt，总宽该多 64pt")

        XCTAssertEqual(compactLayout.rowHeights.count, roomyLayout.rowHeights.count)
        for row in 0..<compactLayout.rowHeights.count {
            XCTAssertEqual(roomyLayout.rowHeights[row] - compactLayout.rowHeights[row],
                           22, accuracy: 0.01,
                           "上下各多 11pt，第 \(row) 行就该高 22pt")
        }
    }

    /// 左右内边距调到比最小列宽还大时，列宽下限要跟着抬，文字区不能被挤成负数
    func testLargePaddingKeepsRoomForText() throws {
        var theme = MarkdownTheme.default
        theme.table.cellPaddingHorizontal = 40
        theme.table.cellPaddingVertical = 32
        // 故意比左右内边距还小，模拟用户把内边距拖到最大
        theme.table.minColumnWidth = 32

        let layout = try layout(theme: theme, containerWidth: 300)
        let minimum = MarkdownTableView.minimumColumnWidth(for: theme.table)
        XCTAssertEqual(minimum, 92, accuracy: 0.01, "两倍内边距 80pt，再留 12pt 给文字")

        for (column, width) in layout.columnWidths.enumerated() {
            XCTAssertGreaterThanOrEqual(width, minimum - 0.01,
                                        "第 \(column) 列不能窄到放不下内边距")
            XCTAssertGreaterThanOrEqual(width - theme.table.cellPaddingHorizontal * 2,
                                        12 - 0.01,
                                        "第 \(column) 列的文字区不能是负数")
        }
    }

    // MARK: 小工具

    /// 按主题渲染一张表格，取它量好的布局
    private func layout(theme: MarkdownTheme,
                        containerWidth: CGFloat = 1000) throws -> MarkdownTableLayout {
        let renderer = MarkupToAttributedRenderer(theme: theme, containerWidth: containerWidth)
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
        return try XCTUnwrap(found, "没有渲染出 MarkdownTableAttachment").presentation.layout
    }
}
