//
//  MarkdownQuoteBackgroundTests.swift
//  MarkdownEditorHy4Tests
//
//  「引用内容加底色」这个开关：默认必须干净，打开之后**从竖条那条线一直铺到行尾**。
//
//  ### 为什么专门敲这几条用例
//  这层底色是 UI 层按矩形铺的（和代码块背景同一套机制，见 `positionQuoteDecorations`），不是烙进富文本的 —— 因为富文本的背景色只跟着**文字**走，行尾那段空白铺不到，会断成一块块色斑。
//  这类开关最容易出错的地方是「忘了默认关闭」—— 一发布，所有人的引用都凭空多出一整片底色，所以第一条用例专门钉住「没开开关时必须一块底色都铺不出来」。
//
//  另外钉住两件事：一是横向范围（起于竖条、止于行尾），二是颜色的来路。
//  底色必须是**从竖条颜色派生**的（透明度压到 10%），不能是另外写死的第二个颜色，否则用户在主题页把竖条换成蓝色、底色还是绿的 —— 那就成 bug 了。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownQuoteBackgroundTests: XCTestCase {

    /// 一段两层嵌套的引用 + 引用外面的正文
    private let markdown = """
    > 外层第一行
    >
    > > 内层一行
    >
    > 外层第二行

    正文一行。
    """

    /// 造一个挂到窗口上、已经排好版的编辑器（装饰层要挂在窗口里才会真的摆出来）
    private func makeEditor(showsQuoteBackground: Bool) -> MarkdownTextView {
        let textView = MarkdownTextView(markdown: markdown)
        textView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)
        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        textView.renderer.theme.showsQuoteBackground = showsQuoteBackground
        textView.layoutIfNeeded()
        // 开关改了要再走一轮布局才会重摆（这一轮只是平移，不会重算矩形）
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        return textView
    }

    /// 拆出 RGBA 四个分量，好逐个比对
    private func components(of color: UIColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return (r, g, b, a)
    }

    /// 默认必须干净：没开开关时**一块底色都铺不出来**，但竖条照样在。
    func testNoQuoteBackgroundIsDrawnWhenSwitchIsOff() {
        let tv = makeEditor(showsQuoteBackground: false)

        XCTAssertFalse(tv.quoteBarFrames.isEmpty, "这份文档该算出引用竖条，不然这条用例验不到东西")
        XCTAssertTrue(tv.quoteBackgroundLayer.subviews.isEmpty,
                      "开关默认关闭：引用除了竖条之外不该多出任何底色")
        XCTAssertFalse(tv.quoteBarLayer.subviews.isEmpty, "竖条得照常画出来")
    }

    /// 打开之后：每层引用铺一条底色，**起于竖条、止于行尾**，且纵向范围和竖条严丝合缝。
    func testQuoteBackgroundSpansFromBarToLineEnd() {
        let tv = makeEditor(showsQuoteBackground: true)
        let bars = tv.quoteBarFrames
        let bands = tv.quoteBackgroundLayer.subviews

        XCTAssertFalse(bars.isEmpty, "这份文档该算出引用竖条")
        XCTAssertEqual(bands.count, bars.count, "每层引用都要有自己的一条底色")

        let lineEnd = tv.bounds.width - tv.textContainerInset.right
        for (band, bar) in zip(bands, bars) {
            // 起点：就是竖条那条线（引用里嵌了行内代码时，底色要从竖条开始才对得齐）
            XCTAssertEqual(band.frame.minX, bar.frame.minX, accuracy: 0.5, "底色要从竖条那条线开始")
            // 终点：行尾（正文右边界），不是「文字右边界」—— 铺不满整行就会断成色斑
            XCTAssertEqual(band.frame.maxX, lineEnd, accuracy: 0.5, "底色要一直铺到行尾")
            // 纵向：和竖条同一段（两者吃的是同一批矩形，跑了偏就是漏到引用外面了）
            XCTAssertEqual(band.frame.minY, bar.frame.minY, accuracy: 0.5, "底色的上沿要跟竖条对齐")
            XCTAssertEqual(band.frame.height, bar.frame.height, accuracy: 0.5, "底色的高度要跟竖条一致")
        }
    }

    /// 颜色必须是**从竖条颜色派生**的（RGB 一致、透明度压到 10%），不能是另外写死的第二个颜色。
    func testQuoteBackgroundIsQuoteBarColorAtTenPercent() {
        let tv = makeEditor(showsQuoteBackground: true)
        let bands = tv.quoteBackgroundLayer.subviews
        XCTAssertFalse(bands.isEmpty, "开了开关就该铺出底色")

        let theme = tv.renderer.theme
        guard let want = components(of: theme.quoteBackground),
              let bar = components(of: theme.quoteBarColor) else {
            return XCTFail("默认主题里的竖条色应该能拆出 RGB（可见在弹出的体色）")
        }

        for band in bands {
            guard let color = band.backgroundColor, let got = components(of: color) else {
                return XCTFail("铺出来的底色该有颜色")
            }
            // 三个颜色分量要和竖条色一致 —— 用户在主题页换了竖条颜色，底色必须跟着换
            XCTAssertEqual(got.r, bar.r, accuracy: 0.01, "底色的红分量要跟着竖条色")
            XCTAssertEqual(got.g, bar.g, accuracy: 0.01, "底色的绿分量要跟着竖条色")
            XCTAssertEqual(got.b, bar.b, accuracy: 0.01, "底色的蓝分量要跟着竖条色")
            XCTAssertEqual(got.a, 0.1, accuracy: 0.001, "底色的透明度必须是 10%")
            XCTAssertEqual(got.a, want.a, accuracy: 0.001, "透明度要和 `theme.quoteBackground` 一致")
        }
    }

    /// 嵌套引用：内层那条底色要跟着缩进往右挪（不能和外层同宽同起点，那就叠成一整块了）
    func testNestedQuoteBackgroundIndentsWithItsLevel() {
        let tv = makeEditor(showsQuoteBackground: true)
        let bars = tv.quoteBarFrames
        let bands = tv.quoteBackgroundLayer.subviews

        guard bars.count >= 2, bands.count >= 2 else {
            return XCTFail("这段文档有两层引用，该算出至少两条竖条和两条底色（实到 竖条\(bars.count) / 底色\(bands.count)）")
        }

        // quoteBarFrames 是按 (level, id) 排好序的，底色跟着同一个顺序铺
        XCTAssertLessThan(bars[0].frame.minX, bars[1].frame.minX, "内层竖条该比外层更靠右")
        XCTAssertLessThan(bands[0].frame.minX, bands[1].frame.minX, "内层底色该比外层更靠右（跟着缩进走）")
        XCTAssertEqual(bands[0].frame.maxX, bands[1].frame.maxX, accuracy: 0.5, "不管嵌了几层，都一律铺到行尾")
    }

    /// 开过之后再关掉：底色要当场消失（不然就是「开关拨回去了、屏幕上还挂着一层」）
    func testTurningSwitchOffClearsDrawnBackground() {
        let tv = makeEditor(showsQuoteBackground: true)
        XCTAssertFalse(tv.quoteBackgroundLayer.subviews.isEmpty, "开着的时候该有底色")

        tv.renderer.theme.showsQuoteBackground = false
        tv.setNeedsLayout()
        tv.layoutIfNeeded()

        XCTAssertTrue(tv.quoteBackgroundLayer.subviews.isEmpty, "关掉开关后底色要清干净")
        XCTAssertFalse(tv.quoteBarLayer.subviews.isEmpty, "竖条不受这个开关影响，照样在")
    }
}
