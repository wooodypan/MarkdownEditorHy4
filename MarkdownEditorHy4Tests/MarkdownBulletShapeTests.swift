//
//  MarkdownBulletShapeTests.swift
//  MarkdownEditorHy4Tests
//
//  无序列表标记的「形状随层数变」：一级实心圆、二级空心圆、三级方块（跟 GitHub 一致）
//
//  ### 这里守的是哪条不变式
//  用户能看见的是「三层列表的标记长得不一样」，所以断言的是**每一层用到哪个形状**，而不是「图上有多少个像素」——后者换个画法就得重写测试。
//  另外守一条：三种形状占的宽度必须一样，否则切换形状时正文会左右抖。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownBulletShapeTests: XCTestCase {

    // MARK: - 小工具

    /// 渲染一段 markdown
    private func render(_ source: String) -> NSAttributedString {
        let renderer = MarkupToAttributedRenderer(theme: MarkdownTheme.default, containerWidth: 600)
        return renderer.render(blockSource: source).text
    }

    /// 把渲染串里所有的列表标记附件按顺序掏出来
    private func bullets(in text: NSAttributedString) -> [BulletAttachment] {
        var result: [BulletAttachment] = []
        text.enumerateAttribute(.attachment,
                                in: NSRange(location: 0, length: text.length),
                                options: []) { value, _, _ in
            if let bullet = value as? BulletAttachment { result.append(bullet) }
        }
        return result
    }

    /// 渲染串里每个列表标记的形状（按出现顺序）
    private func shapes(in source: String) -> [BulletAttachment.Shape] {
        bullets(in: render(source)).map(\.shape)
    }

    // MARK: - 形状随层数变

    func testTopLevelIsFilledDisc() {
        XCTAssertEqual(shapes(in: "- 一级\n"), [.disc], "一级列表应该是实心圆")
    }

    func testSecondLevelIsHollowCircle() {
        XCTAssertEqual(shapes(in: "- 一级\n  - 二级\n"), [.disc, .circle],
                       "二级列表应该是空心圆")
    }

    func testThirdLevelIsSquare() {
        XCTAssertEqual(shapes(in: "- 一级\n  - 二级\n    - 三级\n"), [.disc, .circle, .square],
                       "三级列表应该是方块")
    }

    /// 超过三层就从头循环（GitHub 也是这样）：第四级回到实心圆
    func testFourthLevelCyclesBackToDisc() {
        XCTAssertEqual(shapes(in: "- 一级\n  - 二级\n    - 三级\n      - 四级\n"),
                       [.disc, .circle, .square, .disc],
                       "第四级应该循环回实心圆")
    }

    /// 同级的兄弟项形状必须一样：换的是「层」不是「第几项」
    func testSiblingsShareSameShape() {
        XCTAssertEqual(shapes(in: "- a\n- b\n  - c\n  - d\n"),
                       [.disc, .disc, .circle, .circle],
                       "同一层的多个列表项要用同一种形状")
    }

    // MARK: - 换形状不能让正文左右抖

    /// 三种形状占的宽度必须一致 —— 否则一路往里嵌的时候，正文起点会跟着形状变来变去
    func testAllShapesOccupySameWidth() {
        let source = "- 一级\n  - 二级\n    - 三级\n"
        let widths = bullets(in: render(source)).map { $0.bounds.width }

        XCTAssertEqual(widths.count, 3, "三层列表应该有三个标记")
        XCTAssertEqual(Set(widths).count, 1, "三种形状的占位宽度必须一样，否则正文会左右抖")
    }

    /// 标记仍在源码 `- ` 上：形状换了，「退格把列表项降级成段落」这个行为不能跟着变
    func testBulletStillCoversSourceMarker() {
        let source = "- 一级\n  - 二级\n"
        let text = render(source)

        // 两个标记各占 1 个字符位，且它们的源码映射都落在各自那行的 `- ` 上
        var covered: [Int] = []
        text.enumerateAttribute(.attachment,
                                in: NSRange(location: 0, length: text.length),
                                options: []) { value, range, _ in
            if value is BulletAttachment { covered.append(range.location) }
        }
        XCTAssertEqual(covered.count, 2, "两个列表项各有一个标记")
    }
}
