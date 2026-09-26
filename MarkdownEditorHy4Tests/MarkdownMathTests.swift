//
//  MarkdownMathTests.swift
//  MarkdownEditorHy4Tests
//
//  公式（`$...$` / `$$...$$`）的渲染测试
//
//  ### 这里为什么用「假渲染器」而不真的调 SwiftMath
//  要测的是**组件层的行为**（哪些 `$` 被当成公式、渲染出来的字符位怎么映射回源码），
//  不是 SwiftMath 能不能排版。用一张固定大小的假图当排版结果：
//  1. 测出来的结论跟排版引擎无关 —— 换引擎这组测试照样成立；
//  2. 测试 target 不必链接 SwiftMath，将来把 `MarkdownEditor` 单独开源出去时这组测试能直接带走。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownMathTests: XCTestCase {

    // MARK: - 小工具

    /// 一个「假排版引擎」：不管收到什么 LaTeX，都回同一张固定大小的图。
    ///
    /// 顺手把每次收到的请求记下来 —— 断言「传给引擎的是不是 `$` 里面的正文」就靠它。
    private final class StubMathRenderer: MarkdownMathRenderer {
        /// 收到的每一条请求
        private(set) var requests: [MarkdownMathRequest] = []

        func image(for request: MarkdownMathRequest) -> UIImage? {
            requests.append(request)
            let size = CGSize(width: 40, height: 20)
            return UIGraphicsImageRenderer(size: size).image { context in
                UIColor.black.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
        }

        /// 收到的 LaTeX 正文（不含两侧 `$`）
        var latexList: [String] { requests.map(\.latex) }
    }

    /// 渲染一段 markdown，返回渲染串、映射表、以及那个假引擎。
    /// - parameter stub: 传 nil 表示「不注入公式引擎」，用来测降级行为
    private func render(_ source: String,
                        stub: StubMathRenderer? = StubMathRenderer())
        -> (text: NSAttributedString, mappings: [CharMapping], stub: StubMathRenderer?) {
        let renderer = MarkupToAttributedRenderer(theme: MarkdownTheme.default, containerWidth: 600)
        renderer.mathRenderer = stub
        let (text, mappings) = renderer.render(blockSource: source)
        return (text, mappings, stub)
    }

    /// 文本附件在渲染串里占的那个字符（U+FFFC）
    private let placeholder = "\u{FFFC}"

    // MARK: - 行内公式

    func testInlineMathBecomesOnePlaceholder() {
        let (text, mappings, stub) = render("由 $a$ 推得\n")

        // 公式在屏幕上是一张图，在渲染串里只占 1 个字符位
        XCTAssertEqual(text.string.filter { $0 == "\u{FFFC}" }.count, 1,
                       "一个行内公式应该只占一个字符位")
        // `$a$` 这三个字符不该再出现在屏幕上
        XCTAssertFalse(text.string.contains("$a$"), "公式源码不该原样显示")
        // 夹在公式前后的普通文字必须还在
        XCTAssertTrue(text.string.contains("由"), "公式前面的正文要保留")
        XCTAssertTrue(text.string.contains("推得"), "公式后面的正文要保留")
        // 传给引擎的是 `$` 里面的正文，不含两侧的 `$`
        XCTAssertEqual(stub?.latexList, ["a"], "引擎收到的应该是 `$` 里面的正文")
        // 不变式：每个渲染字符位都有一条映射
        XCTAssertEqual(text.length, mappings.count, "映射表长度必须和渲染长度一致")
    }

    func testInlineMathPlaceholderMapsBackToSource() {
        let source = "由 $a$ 推得\n"
        let (text, mappings, _) = render(source)

        let plain = text.string as NSString
        let location = plain.range(of: placeholder).location
        XCTAssertNotEqual(location, NSNotFound, "渲染串里应该有公式占位符")

        // 这一条守的是「全选复制出来 === 源文件」：
        // 占位符这一个字符位，必须映射回源码里 `$a$` 整整 3 个字符
        let sourceRange = (source as NSString).range(of: "$a$")
        XCTAssertEqual(mappings[location].sourceStart, sourceRange.location,
                       "占位符要映射回 `$a$` 的起点")
        XCTAssertEqual(mappings[location].sourceLength, sourceRange.length,
                       "占位符要认领 `$a$` 全部 3 个字符，否则复制出来会缺字")
    }

    func testMultipleFormulasInOneLine() {
        let (text, _, stub) = render("由 $a$ 推得 $b$ 成立\n")

        XCTAssertEqual(text.string.filter { $0 == "\u{FFFC}" }.count, 2,
                       "一行里有两个公式就该有两个占位符")
        XCTAssertEqual(stub?.latexList, ["a", "b"], "两个公式要按先后顺序都传给引擎")
        XCTAssertTrue(text.string.contains("由"), "公式之间的正文不能丢")
    }

    // MARK: - 别把正文里的 `$` 当成公式

    func testMoneyAmountsAreNotMath() {
        // `$ 100` / `$200` 这种金额写法在正文里很常见，不能凭空变成公式
        let (text, _, stub) = render("花了 $ 100 和 $200 元\n")

        XCTAssertEqual(stub?.requests.count, 0, "金额里的 `$` 不该被当成公式")
        XCTAssertFalse(text.string.contains(placeholder), "不该凭空出现公式占位符")
        XCTAssertTrue(text.string.contains("$200"), "金额要原样显示")
    }

    func testHalfWrittenFormulaShowsSource() {
        // 用户刚敲出 `$x` 还没收口：这一瞬间它不是合法公式，显示源码即可
        let source = "价格是 $x 元\n"
        let (text, _, stub) = render(source)

        XCTAssertEqual(stub?.requests.count, 0, "没收口的 `$` 不该当公式")
        XCTAssertTrue(text.string.contains("$x"), "半截公式要按源码原样显示")
    }

    func testEscapedDollarIsNotMath() {
        // `\$a\$` 是「普通的美元符号」，不是公式
        let (text, _, stub) = render("价格 \\$a\\$ 元\n")

        XCTAssertEqual(stub?.requests.count, 0, "转义过的 `$` 不当公式边界")
        XCTAssertFalse(text.string.contains(placeholder), "不该出现公式占位符")
    }

    func testInlineMathDoesNotCrossLineBreak() {
        // 行内公式不允许跨行：跨行的 `$` 多半只是正文里随手写的
        let (text, _, stub) = render("$a\n和 b$\n")

        XCTAssertEqual(stub?.requests.count, 0, "跨换行的行内公式不成立")
        XCTAssertFalse(text.string.contains(placeholder), "不该出现公式占位符")
    }

    // MARK: - 块级公式

    func testBlockMathIsRenderedAsBlock() {
        let (text, _, stub) = render("$$\nE=mc^2\n$$\n")

        XCTAssertEqual(text.string.filter { $0 == "\u{FFFC}" }.count, 1,
                       "块级公式也只占一个字符位")
        XCTAssertEqual(stub?.latexList, ["E=mc^2"], "引擎收到的是 `$$` 里面的正文")
        XCTAssertEqual(stub?.requests.first?.mode, .block,
                       "$$…$$ 要按块级模式排版（上下标位置跟行内不一样）")
    }

    func testBlockMathSharesLineWithOtherText() {
        // `$$a$$` 和别的文字挤在一行时不算块级，按普通段落处理（里面的公式仍是行内公式）
        let (text, _, _) = render("$$a$$ 和 $$b$$\n")

        XCTAssertEqual(text.string.filter { $0 == "\u{FFFC}" }.count, 2,
                       "两个 `$$…$$` 各自渲染成一个公式")
    }

    // MARK: - 没注入引擎时的降级

    func testFallsBackToSourceWithoutRenderer() {
        // 没注入公式引擎（开源库默认的用法）：公式按源码原文显示，功能降级但不能坏
        let (text, mappings, _) = render("由 $a$ 推得\n", stub: nil)

        XCTAssertFalse(text.string.contains(placeholder), "没有引擎就不该有公式占位符")
        XCTAssertTrue(text.string.contains("$a$"), "没有引擎时公式要按源码原文显示")
        XCTAssertEqual(text.length, mappings.count, "降级路径同样要满足映射不变式")
    }
}
