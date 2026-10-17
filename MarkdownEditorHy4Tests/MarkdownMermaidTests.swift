//
//  MarkdownMermaidTests.swift
//  MarkdownEditorHy4Tests
//
//  Mermaid 围栏块（```mermaid）的渲染测试
//
//  ### 这里为什么用「假渲染器」而不真的调 MermaidKit
//  和 `MarkdownMathTests` 是同一个理由：要测的是**组件层的行为**（哪种围栏被当成图、渲染出来的字符位怎么映射回源码、画不出来时怎么降级），不是 MermaidKit 画得好不好看。
//  用一张固定大小的假图当渲染结果，跑出来的结论跟图表引擎无关 —— 将来换引擎这组测试照样成立。
//  （真正调用 MermaidKit 的那几条集成测试单独放在 `MermaidKitRendererTests.swift` 里。）
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownMermaidTests: XCTestCase {

    // MARK: - 小工具

    /// 一个「假图表引擎」：默认回一张固定大小的图。
    ///
    /// 顺手把每次收到的请求记下来 —— 断言「喂给引擎的是不是围栏里的正文」就靠它。
    private final class StubMermaidRenderer: MarkdownMermaidRenderer {
        /// 收到的每一条请求
        private(set) var requests: [MarkdownMermaidRequest] = []
        /// 置真表示「这段源码画不出来」（模拟非法语法），用来测回退
        var returnsNil = false
        /// 交出去的图有多大
        var imageSize = CGSize(width: 300, height: 180)

        func image(for request: MarkdownMermaidRequest) -> UIImage? {
            requests.append(request)
            guard !returnsNil else { return nil }
            let size = imageSize
            return UIGraphicsImageRenderer(size: size).image { context in
                UIColor.gray.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
        }

        /// 收到的源码（不含围栏那两行）
        var sources: [String] { requests.map(\.source) }
    }

    /// 渲染一段 markdown，返回渲染串、映射表、以及那个假引擎。
    /// - parameter stub: 传 nil 表示「不注入图表引擎」，用来测降级行为
    private func render(_ source: String,
                        containerWidth: CGFloat = 600,
                        stub: StubMermaidRenderer? = StubMermaidRenderer())
        -> (text: NSAttributedString, mappings: [CharMapping], stub: StubMermaidRenderer?) {
        let renderer = MarkupToAttributedRenderer(theme: MarkdownTheme.default, containerWidth: containerWidth)
        renderer.mermaidRenderer = stub
        let (text, mappings) = renderer.render(blockSource: source)
        return (text, mappings, stub)
    }

    /// 文本附件在渲染串里占的那个字符（U+FFFC）
    private let placeholder = "\u{FFFC}"

    /// 一个规规矩矩的 Mermaid 围栏块
    private let fence = "```mermaid\nflowchart TD\n  A --> B\n```\n"

    // MARK: - 围栏块 → 一张图

    func testMermaidFenceBecomesOnePlaceholder() {
        let (text, mappings, stub) = render(fence)

        // 图和公式一样：在渲染串里只占 1 个字符位
        XCTAssertEqual(text.string.filter { $0 == "\u{FFFC}" }.count, 1,
                       "一个 mermaid 围栏块应该只占一个字符位")
        // 喂给引擎的是围栏**里面**的正文，不带 ``` 那两行 —— 引擎不认识它们
        XCTAssertEqual(stub?.sources, ["flowchart TD\n  A --> B\n"],
                       "引擎收到的是围栏里面的正文")
        // 不变式：每个渲染字符位都有一条映射
        XCTAssertEqual(text.length, mappings.count, "映射表长度必须和渲染长度一致")
    }

    func testMermaidFenceIsNotDrawnAsCodeBlock() {
        let (text, _, _) = render(fence)

        // 画成图之后就不该再有「这是一个代码块」的标记了 —— UI 层靠这个标记画灰底、放复制按钮，图上罩一层灰底是错的
        var foundCodeBlockMarker = false
        text.enumerateAttribute(.markdownCodeBlock,
                                in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { foundCodeBlockMarker = true }
        }
        XCTAssertFalse(foundCodeBlockMarker, "渲染成图之后不该再挂代码块的标记")
    }

    func testPlaceholderClaimsTheWholeFenceBlock() {
        let (text, mappings, _) = render(fence)

        let location = (text.string as NSString).range(of: placeholder).location
        XCTAssertNotEqual(location, NSNotFound, "渲染串里应该有图的占位符")

        // 占位符这 1 个字符位要认领源码里从开围栏到闭围栏的**整段** —— 认少了，复制出来的源码就会缺掉整个围栏块。
        // ⚠️ 末尾那个换行**不算**在块里：cmark 给的块源码范围止于闭合围栏，紧跟的那个换行是块与块之间的分隔符，
        // 整篇渲染时由文档模型负责输出，不归这个块。所以这里是 `length - 1`。
        XCTAssertEqual(mappings[location].sourceStart, 0, "占位符要认领整段源码的起点")
        XCTAssertEqual(mappings[location].sourceLength, (fence as NSString).length - 1,
                       "占位符要认领整段源码（含围栏两行，不含块后那个换行）")
    }

    func testImageIsFollowedByFadedSource() {
        let (text, _, _) = render(fence)

        // 图下面是**源码本身**（弱化显示），光标能停进去改内容 —— 和表格一个做法。
        // 没有它的话用户就改不了这块内容了
        let location = (text.string as NSString).range(of: placeholder).location
        let after = (text.string as NSString).substring(from: location + 1)
        XCTAssertTrue(after.contains("```mermaid"), "图下面要连着显示围栏行本身")
        XCTAssertTrue(after.contains("A --> B"), "图下面要连着显示正文源码")
    }

    // MARK: - 「全选复制 === 源文件」

    /// 走文档模型那条路（编辑器复制用的就是它），验证整篇选中的渲染范围能还原出**一字不差**的源码。
    private func assertCopyRoundTrip(_ source: String,
                                    stub: StubMermaidRenderer?,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        let store = MarkdownDocumentStore()
        store.renderer.mermaidRenderer = stub
        store.load(markdown: source, containerWidth: 600)

        let copied = store.sourceText(forRenderedRange: NSRange(location: 0, length: store.renderedLength))
        XCTAssertEqual(copied, source,
                       "渲染串选到头复制出来必须逐字等于源文件",
                       file: file, line: line)
    }

    func testCopyRoundTripWithDiagram() {
        // 图和它下面那段源码映射的是同一段源码，复制时靠映射表去重，整段只输出一次
        assertCopyRoundTrip(fence, stub: StubMermaidRenderer())
    }

    func testCopyRoundTripWithoutRenderer() {
        // 没注入引擎时走的是普通代码块那条路，同样得一字不差
        assertCopyRoundTrip(fence, stub: nil)
    }

    func testCopyRoundTripWhenEngineFails() {
        let stub = StubMermaidRenderer()
        stub.returnsNil = true
        assertCopyRoundTrip(fence, stub: stub)
    }

    // MARK: - 什么时候不画图（回退成普通代码块）

    /// 「回退成普通代码块」的判据：源码原文原样显示 + 挂着代码块标记（UI 层要画灰底和复制按钮）
    ///
    /// - parameter expectedText: 渲染串里应该原样出现的那段源码正文。
    ///   ⚠️ 别在这里写死某个围栏的内容 —— 空围栏、别种语言的围栏都走这条辅助函数，写死了它们必然红。
    ///   确实没有正文可验（空围栏）时传 `nil`，那一条就跳过。
    private func assertFallsBackToCodeBlock(_ source: String,
                                           expectedText: String? = "flowchart TD",
                                           stub: StubMermaidRenderer?,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) {
        let (text, mappings, _) = render(source, stub: stub)

        XCTAssertFalse(text.string.contains(placeholder),
                       "回退路径不该出现图的占位符", file: file, line: line)
        if let expectedText {
            XCTAssertTrue(text.string.contains(expectedText),
                          "回退时源码要原样显示", file: file, line: line)
        }

        var hasCodeBlockMarker = false
        text.enumerateAttribute(.markdownCodeBlock,
                                in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { hasCodeBlockMarker = true }
        }
        XCTAssertTrue(hasCodeBlockMarker,
                      "回退时应该按普通代码块渲染（UI 层靠这个标记画灰底）", file: file, line: line)
        XCTAssertEqual(text.length, mappings.count,
                       "降级路径同样要满足映射不变式", file: file, line: line)
    }

    func testFallsBackToCodeBlockWithoutRenderer() {
        // 没注入引擎（开源库默认的用法）：功能降级但不能坏
        let source = "```mermaid\nflowchart TD\n  A --> B\n```\n"
        assertFallsBackToCodeBlock(source, stub: nil)
    }

    func testFallsBackToCodeBlockWhenEngineReturnsNil() {
        // 用户正敲半截 `flowchart T`：引擎画不出来，显示源码原文，**不弹错误提示**
        let stub = StubMermaidRenderer()
        stub.returnsNil = true
        assertFallsBackToCodeBlock(fence, stub: stub)
        XCTAssertEqual(stub.requests.count, 1, "引擎该被问过一次，只是它答不上来")
    }

    func testEmptyFenceDoesNotReachEngine() {
        // 写了 ```mermaid 就闭合：画出来是一张空图，不如让用户看着自己的源码
        let stub = StubMermaidRenderer()
        assertFallsBackToCodeBlock("```mermaid\n```\n", expectedText: nil, stub: stub)
        XCTAssertEqual(stub.requests.count, 0, "空围栏不该去问引擎")
    }

    func testWhitespaceOnlyFenceDoesNotReachEngine() {
        let stub = StubMermaidRenderer()
        assertFallsBackToCodeBlock("```mermaid\n   \n\n```\n", expectedText: nil, stub: stub)
        XCTAssertEqual(stub.requests.count, 0, "只有空白的围栏不该去问引擎")
    }

    func testOtherLanguagesAreUntouched() {
        // 只认 mermaid，别的围栏语言照旧当代码块（顺带确认没有误伤）
        let stub = StubMermaidRenderer()
        assertFallsBackToCodeBlock("```swift\nlet a = 1\n```\n", expectedText: "let a = 1", stub: stub)
        assertFallsBackToCodeBlock("```\nplain code\n```\n", expectedText: "plain code", stub: stub)
        XCTAssertEqual(stub.requests.count, 0, "别的语言不该去问图表引擎")
    }

    // MARK: - 认围栏语言的松紧

    func testMmdAliasIsAccepted() {
        let (text, _, stub) = render("```mmd\nflowchart TD\n  A --> B\n```\n")

        XCTAssertEqual(text.string.filter { $0 == "\u{FFFC}" }.count, 1, "`mmd` 是 mermaid 的别名")
        XCTAssertEqual(stub?.sources, ["flowchart TD\n  A --> B\n"])
    }

    func testLanguageTagIsCaseInsensitive() {
        let (text, _, stub) = render("```Mermaid\nflowchart TD\n  A --> B\n```\n")

        XCTAssertEqual(text.string.filter { $0 == "\u{FFFC}" }.count, 1, "围栏语言不区分大小写")
        XCTAssertEqual(stub?.sources, ["flowchart TD\n  A --> B\n"])
    }

    func testLanguageWithSurroundingSpacesStillCounts() {
        // ``` mermaid 这种写法（语言前面多一个空格）也是合法的围栏
        let (text, _, stub) = render("``` mermaid\nflowchart TD\n  A --> B\n```\n")

        XCTAssertEqual(text.string.filter { $0 == "\u{FFFC}" }.count, 1, "语言标记前带空格也该认")
        XCTAssertEqual(stub?.sources, ["flowchart TD\n  A --> B\n"])
    }

    // MARK: - 传给引擎的参数

    func testRequestCarriesWidthFontAndThemeColors() {
        let (_, _, stub) = render(fence, containerWidth: 600)
        let request = stub?.requests.first

        // 宽度和表格同一条算法：容器宽度 - 缩进 - 16
        XCTAssertEqual(request?.maxWidth ?? 0, 584, accuracy: 0.01,
                       "可用宽度要按容器宽度算出来")
        XCTAssertEqual(request?.fontSize, MarkdownTheme.default.bodyFont.pointSize,
                       "图里的字按正文字号量，才能和周围正文一个大小")
        XCTAssertEqual(request?.textColor, MarkdownTheme.default.textColor,
                       "文字颜色要跟着主题走")
        XCTAssertEqual(request?.backgroundColor, MarkdownTheme.default.editorBackground,
                       "背景色要跟着主题走（引擎拿它垫箭头、也拿它判断深浅）")
        XCTAssertEqual(request?.accentColor, MarkdownTheme.default.linkColor,
                       "强调色要跟着主题走 —— 图里的节点填充靠它，图才不会和文档配色两家人")
        XCTAssertEqual(request?.separatorColor, MarkdownTheme.default.separatorColor,
                       "细线色要跟着主题走 —— 网格、生命线、区域框用它")
    }

    func testMaxWidthFollowsContainerWidth() {
        let (_, _, narrow) = render(fence, containerWidth: 300)
        XCTAssertEqual(narrow?.requests.first?.maxWidth ?? 0, 284, accuracy: 0.01)
    }

    // MARK: - 尺寸

    /// 取出渲染串里那个图的附件
    private func attachment(in text: NSAttributedString) -> MermaidAttachment? {
        let location = (text.string as NSString).range(of: placeholder).location
        guard location != NSNotFound else { return nil }
        return text.attribute(.attachment, at: location, effectiveRange: nil) as? MermaidAttachment
    }

    func testWideDiagramIsScaledToFit() {
        let stub = StubMermaidRenderer()
        stub.imageSize = CGSize(width: 1200, height: 600)
        let (text, _, _) = render(fence, containerWidth: 600, stub: stub)

        guard let attachment = attachment(in: text) else {
            return XCTFail("渲染串里应该有一个图附件")
        }
        // 图比容器宽 → 等比缩到刚好塞下（可用宽度 584），高度按同一个比例缩
        XCTAssertEqual(attachment.bounds.width, 584, accuracy: 0.5, "宽图要缩到容器装得下")
        XCTAssertEqual(attachment.bounds.height, 292, accuracy: 0.5, "缩放要等比，不能拉伸")
        XCTAssertEqual(attachment.originalSize, CGSize(width: 1200, height: 600),
                       "原始尺寸要留着（将来按原分辨率导出用）")
    }

    func testNarrowDiagramKeepsOriginalSize() {
        let stub = StubMermaidRenderer()
        stub.imageSize = CGSize(width: 120, height: 90)
        let (text, _, _) = render(fence, containerWidth: 600, stub: stub)

        guard let attachment = attachment(in: text) else {
            return XCTFail("渲染串里应该有一个图附件")
        }
        // 只缩不放：本来就比容器窄的图按原尺寸显示，放大只会变糊
        XCTAssertEqual(attachment.bounds.size, CGSize(width: 120, height: 90),
                       "窄图不该被放大")
        XCTAssertEqual(attachment.bounds.origin.y, 0, accuracy: 0.01,
                       "块级图坐在基线上（不跟 capHeight 对齐，那是行内公式的做法）")
    }
}
