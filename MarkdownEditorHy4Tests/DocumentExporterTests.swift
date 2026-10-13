//
//  DocumentExporterTests.swift
//  MarkdownEditorHy4Tests
//
//  导出成图片那条路的验收测试 —— 重点是「没在编辑器里开着的那份文档」：
//  左栏右键导出的文档根本没被打开过，图片是靠临时造一台编辑器画出来的，这条如果画不出来，用户拿到的就是一张空白图或者一句「导出失败」。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class DocumentExporterTests: XCTestCase {

    /// 临时造的编辑器不进视图树，也得能把内容画出来
    func testRenderImageOffScreen() throws {
        let image = try XCTUnwrap(DocumentExporter.renderImage(markdown: "# 标题\n\n正文一段。\n",
                                                              theme: .default,
                                                              baseDirectory: nil,
                                                              width: 600),
                                  "没画出图来 —— 左栏右键导出图片这条路会直接报「导出失败」")

        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    /// 图有多宽，取决于传进去的排版宽度（导出时给的是窗口宽度）
    func testRenderImageUsesGivenWidth() throws {
        let image = try XCTUnwrap(DocumentExporter.renderImage(markdown: "# 标题\n",
                                                               theme: .default,
                                                               baseDirectory: nil,
                                                               width: 512))
        XCTAssertEqual(image.size.width, 512, accuracy: 1, "图宽该跟着排版宽度走")
    }

    /// 内容越多图越高 —— 顺带证明**排版真的发生了**，而不是随便返回一张空图
    func testImageHeightGrowsWithContent() throws {
        let short = try XCTUnwrap(DocumentExporter.renderImage(markdown: "# 标题\n",
                                                               theme: .default,
                                                               baseDirectory: nil,
                                                               width: 600))
        let long = try XCTUnwrap(DocumentExporter.renderImage(markdown: String(repeating: "这是一段正文。\n\n", count: 20),
                                                              theme: .default,
                                                              baseDirectory: nil,
                                                              width: 600))
        XCTAssertGreaterThan(long.size.height, short.size.height * 2,
                             "长文档的图和短文档一样高 —— 说明内容根本没排进去")
    }
}
