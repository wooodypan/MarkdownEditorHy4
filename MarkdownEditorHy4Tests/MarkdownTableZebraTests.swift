//
//  MarkdownTableZebraTests.swift
//  MarkdownEditorHy4
//
//  表格的斑马纹：数据行隔行铺底色，表头保持自己的底色。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownTableZebraTests: XCTestCase {

    /// 表头 + 四行数据：紧挨表头的第 1 行留白，第 2、4 行铺斑马纹，第 3 行留白
    func testDataRowsAreStripedAlternately() throws {
        var theme = MarkdownTheme.default
        // 用纯红当斑马色，采样时不容易和表头灰、白底混在一起
        theme.table.alternateRowBackground = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        let attachment = try renderAttachment(theme: theme)

        let layout = attachment.presentation.layout
        XCTAssertEqual(layout.rowHeights.count, 5, "表头 + 四个数据行")

        let image = try flattened(attachment)
        // 行内靠左的空白处：避开 1pt 边框，也还没到 12pt 的内边距，不会采到文字
        let x: CGFloat = 4
        let rows = (0..<5).map { row in
            color(in: image,
                  at: CGPoint(x: x,
                              y: layout.y(ofRow: row) + layout.rowHeights[row] / 2))
        }

        XCTAssertGreaterThan(rows[0].green, 0.8, "表头该保持自己的底色，不该铺斑马纹")
        XCTAssertGreaterThan(rows[1].red, 0.9, "第 1 个数据行该留白，不能和表头的灰连成一块")
        XCTAssertGreaterThan(rows[1].green, 0.9, "第 1 个数据行该留白")
        XCTAssertGreaterThan(rows[2].red, 0.8, "第 2 个数据行该铺斑马纹")
        XCTAssertLessThan(rows[2].green, 0.3, "第 2 个数据行的斑马色不对")
        XCTAssertGreaterThan(rows[3].red, 0.9, "第 3 个数据行该留白")
        XCTAssertGreaterThan(rows[3].green, 0.9, "第 3 个数据行该留白")
        XCTAssertGreaterThan(rows[4].red, 0.8, "第 4 个数据行又该铺斑马纹")
        XCTAssertLessThan(rows[4].green, 0.3, "第 4 个数据行的斑马色不对")
    }

    /// 斑马色设成透明就等于关掉斑马纹，所有数据行都留白
    func testClearStripeDisablesZebra() throws {
        var theme = MarkdownTheme.default
        theme.table.alternateRowBackground = .clear
        let attachment = try renderAttachment(theme: theme)

        let layout = attachment.presentation.layout
        let image = try flattened(attachment)
        for row in 1..<layout.rowHeights.count {
            let sample = color(in: image,
                               at: CGPoint(x: 4,
                                           y: layout.y(ofRow: row) + layout.rowHeights[row] / 2))
            XCTAssertGreaterThan(sample.red, 0.9, "第 \(row) 行该留白")
            XCTAssertGreaterThan(sample.green, 0.9, "第 \(row) 行该留白")
        }
    }

    // MARK: 小工具

    private func renderAttachment(theme: MarkdownTheme) throws -> MarkdownTableAttachment {
        let renderer = MarkupToAttributedRenderer(theme: theme, containerWidth: 700)
        let (text, _) = renderer.render(blockSource: """
        | 名称 | 数量 |
        | --- | --- |
        | 苹果 | 1 |
        | 香蕉 | 2 |
        | 橙子 | 3 |
        | 葡萄 | 4 |
        """)

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

    /// 表格图本身是透明底（留白行在图上没有颜色），先铺一层白底再采样
    private func flattened(_ attachment: MarkdownTableAttachment) throws -> UIImage {
        let table = try XCTUnwrap(attachment.image, "普通表格该画成图片")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: table.size, format: format).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: table.size))
            table.draw(at: .zero)
        }
    }

    /// 取某个点（UIKit 坐标，左上角为原点）的颜色，三个分量都是 0...1
    private func color(in image: UIImage, at point: CGPoint) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        guard let cg = image.cgImage else { return (0, 0, 0) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // 只画 1×1：把目标点移到原点，UIKit 的 y 向下坐标在这里是确定的
        let pixel = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            UIImage(cgImage: cg).draw(at: CGPoint(x: -point.x, y: -point.y))
        }

        var bytes = [UInt8](repeating: 0, count: 4)
        guard let pixelCG = pixel.cgImage,
              let context = CGContext(data: &bytes,
                                      width: 1,
                                      height: 1,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return (0, 0, 0) }
        context.draw(pixelCG, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (CGFloat(bytes[0]) / 255, CGFloat(bytes[1]) / 255, CGFloat(bytes[2]) / 255)
    }
}
