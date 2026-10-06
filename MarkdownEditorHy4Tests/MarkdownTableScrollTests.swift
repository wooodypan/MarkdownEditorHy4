//
//  MarkdownTableScrollTests.swift
//  MarkdownEditorHy4
//
//  宽表格（列多到装不下）的呈现策略。
//
//  ### 这里守的三条
//  1. **窄表格照旧**：几列的表格还是按内容画、整体压进容器，不该平白多出一层滚动；
//  2. **列太多就横滚**：每列都按最小宽度还塞不下时改成横向滚动，屏幕上只露容器那么宽；
//  3. **横滚时每列仍要看得清**：滚动模式下任何一列都不许窄于 `minColumnWidth` —— 这是这次要解决的那个问题（30 列被压成二十几点宽、一个字都显示不全）。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownTableScrollTests: XCTestCase {

    // MARK: 小工具

    /// 造一张 `columns` 列、若干行的表格源码
    private func tableSource(columns: Int, rows: Int = 2) -> String {
        let header = (0..<columns).map { "列\($0)" }.joined(separator: " | ")
        let divider = Array(repeating: "---", count: columns).joined(separator: " | ")
        let body = (0..<rows).map { row in
            (0..<columns).map { column in "\(column)-\(row)" }.joined(separator: " | ")
        }
        return (["| \(header) |", "| \(divider) |"] + body.map { "| \($0) |" })
            .joined(separator: "\n") + "\n"
    }

    /// 渲染一段表格源码，把里面那个表格 attachment 挖出来
    private func renderAttachment(_ source: String,
                                  containerWidth: CGFloat = 600) throws -> MarkdownTableAttachment {
        let renderer = MarkupToAttributedRenderer(theme: .default, containerWidth: containerWidth)
        let (text, _) = renderer.render(blockSource: source)

        var found: MarkdownTableAttachment?
        text.enumerateAttribute(.attachment,
                                in: NSRange(location: 0, length: (text.string as NSString).length),
                                options: []) { value, _, _ in
            if let attachment = value as? MarkdownTableAttachment { found = attachment }
        }
        return try XCTUnwrap(found, "没有渲染出 MarkdownTableAttachment")
    }

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

    /// 从视图树里捞所有表格滚动容器（屏幕上真实存在的控件）
    private func allTableScrollViews(in view: UIView) -> [MarkdownTableScrollView] {
        var result: [MarkdownTableScrollView] = []
        for subview in view.subviews {
            if let scroller = subview as? MarkdownTableScrollView { result.append(scroller) }
            result.append(contentsOf: allTableScrollViews(in: subview))
        }
        return result
    }

    // MARK: 装得下 → 不滚

    /// 几列的窄表格：按内容画，宽度自己说了算，不需要横向滚动
    func testNarrowTableNeedsNoScrolling() throws {
        let attachment = try renderAttachment(tableSource(columns: 3))

        XCTAssertFalse(attachment.needsHorizontalScroll, "三列的表格画得下，不该平白多出一层滚动")
        XCTAssertEqual(attachment.presentation.contentWidth,
                       attachment.presentation.visibleWidth,
                       accuracy: 0.5,
                       "不滚动时「画多宽」和「露多宽」是同一个数")
        XCTAssertEqual(attachment.bounds.width, attachment.presentation.visibleWidth, accuracy: 0.5,
                       "attachment 的宽度要就是露出来的宽度")
    }

    /// 超宽但「每列保持最小宽度还塞得下」→ 整体等比压缩，仍然不滚
    func testWideButSqueezableTableStillCompresses() throws {
        // 五列、每列内容都很长：自然宽度肯定超过容器，但 5 × 64 = 320 < 584，压缩完还看得清
        let long = (0..<5).map { "一列很长很长很长的内容\($0)" }.joined(separator: " | ")
        let source = "| \(long) |\n| \(Array(repeating: "---", count: 5).joined(separator: " | ")) |\n| \(long) |\n"
        let attachment = try renderAttachment(source)

        XCTAssertFalse(attachment.needsHorizontalScroll, "压缩完还看得清就不该改成滚动")
        XCTAssertLessThanOrEqual(attachment.presentation.visibleWidth, 584 + 0.5,
                                 "压完必须装进容器，不能溢出")
    }

    // MARK: 装不下 → 横向滚动

    /// 30 列：每列都按最小宽度也塞不下 → 改成横向滚动
    func testThirtyColumnsScrollHorizontally() throws {
        let attachment = try renderAttachment(tableSource(columns: 30))

        XCTAssertTrue(attachment.needsHorizontalScroll, "30 列的表格该改成横向滚动")
        XCTAssertGreaterThan(attachment.presentation.contentWidth,
                             attachment.presentation.visibleWidth + 1,
                             "滚动的前提是「画出来的」比「露出来的」宽")
        XCTAssertLessThanOrEqual(attachment.presentation.visibleWidth, 584 + 0.5,
                                 "屏幕上只露容器那么宽，不能把正文撑出去")
    }

    /// 滚动模式下每一列都不得窄于 `minColumnWidth` —— 这正是「30 列被压成二十几点」那个毛病
    func testScrollableTableKeepsEveryColumnAtLeastMinWidth() throws {
        var theme = MarkdownTheme.default
        theme.table.minColumnWidth = 64
        let renderer = MarkupToAttributedRenderer(theme: theme, containerWidth: 600)
        let (text, _) = renderer.render(blockSource: tableSource(columns: 30))

        var found: MarkdownTableAttachment?
        text.enumerateAttribute(.attachment,
                                in: NSRange(location: 0, length: (text.string as NSString).length),
                                options: []) { value, _, _ in
            if let attachment = value as? MarkdownTableAttachment { found = attachment }
        }
        let attachment = try XCTUnwrap(found, "没有渲染出 MarkdownTableAttachment")

        let widths = attachment.presentation.layout.columnWidths
        XCTAssertEqual(widths.count, 30, "30 列一列都不能少")
        XCTAssertTrue(widths.allSatisfy { $0 >= theme.table.minColumnWidth - 0.01 },
                      "滚动模式下每列都该至少有 \(theme.table.minColumnWidth)pt 宽，实测最窄 \(widths.min() ?? 0)")
        XCTAssertGreaterThanOrEqual(attachment.presentation.contentWidth,
                                    30 * theme.table.minColumnWidth - 0.5,
                                    "总宽该是所有列按最小宽度排开的结果")
    }

    /// 滚动模式下文本流里那个位置仍然只占容器那么宽（占位图不能把整行撑开）
    func testScrollablePlaceholderStaysInsideTheContainer() throws {
        let attachment = try renderAttachment(tableSource(columns: 30))

        XCTAssertLessThanOrEqual(attachment.bounds.width, 584 + 0.5,
                                 "占位用的 attachment 必须只有容器宽，否则整篇都被撑宽了")
        XCTAssertGreaterThan(attachment.bounds.height, 0, "高度该照常占住（表格多高就留多高）")
    }

    // MARK: 浮层真的挂上去了

    /// 宽表格上方要浮出一个「内容比框宽」的滚动容器，宽度就是容器宽
    func testWideTableGetsAScrollViewOnScreen() throws {
        let tv = makeEditor(tableSource(columns: 30))

        let scrollers = allTableScrollViews(in: tv)
        let scroller = try XCTUnwrap(scrollers.first, "宽表格上方该浮出一个滚动容器")
        XCTAssertEqual(scrollers.count, 1, "一个表格只该有一层滚动容器")
        XCTAssertGreaterThan(scroller.contentSize.width, scroller.bounds.width,
                             "内容比框宽才滚得动；一样宽就说明又把它压回去了")
        XCTAssertLessThanOrEqual(scroller.bounds.width, tv.bounds.width + 0.5,
                                 "框不能比正文栏还宽（宽度是渲染时按容器算的，这里只守「不撑出去」）")
        XCTAssertGreaterThan(scroller.bounds.height, 0, "框要有高度，否则什么都看不见")
    }

    /// 窄表格不该凭空多出一层滚动容器（那会白吃掉正文的点击）
    func testNarrowTableHasNoScrollView() {
        let tv = makeEditor(tableSource(columns: 3))

        XCTAssertTrue(allTableScrollViews(in: tv).isEmpty, "窄表格画得下，不该挂滚动容器")
        XCTAssertTrue(tv.tableScrollMarks.isEmpty, "窄表格不该被记进「要横滚」的名单")
    }

    /// 滚动容器里那块画布要**真的画出表格来**。
    ///
    /// ### 为什么非得数像素
    /// 滚动模式下文本流里那个位置是一张**全透明**占位图：浮层要是没画上去，屏幕上就是一片空白，而且不报错、不崩溃 —— 只看 `contentSize` / `frame` 是发现不了的。
    /// 所以这里把画布渲染成图片，数一数里面有多少「墨」（比浅色背景深的像素）。
    func testWideTableCanvasActuallyPaintsTheTable() throws {
        let tv = makeEditor(tableSource(columns: 30))
        let scroller = try XCTUnwrap(allTableScrollViews(in: tv).first, "宽表格上方该浮出一个滚动容器")

        let canvas = scroller.canvas
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: canvas.bounds.size, format: format).image { context in
            canvas.layer.render(in: context.cgContext)
        }

        let ink = inkPixelCount(in: image, rect: CGRect(origin: .zero, size: canvas.bounds.size))
        XCTAssertGreaterThan(ink, 500,
                             "画布该画出边框和文字来；只有几十个点就说明它压根没画（浮层底下那张占位图是全透明的）")
    }

    /// 数一数图片里 `rect` 这块区域有多少个「不是浅色背景」的像素
    private func inkPixelCount(in image: UIImage, rect: CGRect) -> Int {
        guard let cg = image.cgImage, rect.width > 0, rect.height > 0 else { return 0 }
        let width = Int(rect.width), height = Int(rect.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        // 目标区域平移到上下文原点：上下文只有 rect 那么大，不平移画出来的是左上角那一块
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.draw(cg, in: CGRect(origin: .zero, size: image.size))

        var ink = 0
        var index = 0
        while index < pixels.count {
            if pixels[index] < 200 || pixels[index + 1] < 200 || pixels[index + 2] < 200 { ink += 1 }
            index += 4
        }
        return ink
    }

    /// 竖着滚一遍之后，滚动容器还在，而且用户横滑出来的位置不该被重置
    func testScrollerSurvivesVerticalScrolling() throws {
        let tv = makeEditor(tableSource(columns: 30))
        let scroller = try XCTUnwrap(allTableScrollViews(in: tv).first, "宽表格上方该浮出一个滚动容器")

        scroller.contentOffset = CGPoint(x: 200, y: 0)
        tv.contentOffset = CGPoint(x: 0, y: 60)
        tv.layoutIfNeeded()

        let after = try XCTUnwrap(allTableScrollViews(in: tv).first, "竖滚之后滚动容器该还在")
        XCTAssertTrue(after === scroller, "滚动容器要复用同一个对象，重建一次横向位置就回最左边了")
        XCTAssertEqual(after.contentOffset.x, 200, accuracy: 0.5,
                       "竖着滚文档不该把表格的横向位置重置掉")
    }
}
