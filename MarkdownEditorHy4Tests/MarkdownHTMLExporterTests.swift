import XCTest
import UIKit
@testable import MarkdownEditorHy4

/// 「导出成 HTML」的测试。
///
/// ### 为什么大部分断言是「有没有这一串」而不是比对整份文档
/// 完整的 HTML 还裹着 `<!DOCTYPE html>`、几十行 CSS，整份比对的话以后调一个字号就要改十条用例。
/// 这里只断言**用户看得到的行为**：该转义的有没有转义、任务列表的勾在不在、脚注有没有落到文末 —— 这些变了才是真的坏了。
final class MarkdownHTMLExporterTests: XCTestCase {

    // MARK: 小工具

    private func render(_ markdown: String,
                        options: MarkdownHTMLExporter.Options = MarkdownHTMLExporter.Options(style: .builtIn)) -> String {
        MarkdownHTMLExporter.export(markdown: markdown, title: "标题", options: options)
    }

    /// 剥掉 `<head>` 里的 CSS，只留 `<main>` 里的正文。
    ///
    /// ### 为什么断言大多要看这一段而不是整份文档
    /// CSS 里写着 `sup.footnote-ref`、`section.footnotes` 这些选择器，直接对整份 HTML 判「含不含 footnote-ref」的话，就算一个脚注都没导出也是 true。
    private func mainContent(_ html: String) -> String {
        guard let start = html.range(of: "<main class=\"markdown-body\">"),
              let end = html.range(of: "</main>", range: start.upperBound..<html.endIndex) else { return html }
        return String(html[start.upperBound..<end.lowerBound])
    }

    /// 临时目录，用来放测试用的图片；跑完不用管（系统在临时目录里清理）
    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("html-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 写一张真的小 PNG 到指定目录，返回文件名
    private func writePNG(name: String, into directory: URL) throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { rendererContext in
            UIColor.systemPink.setFill()
            rendererContext.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name))
    }

    // MARK: 外壳

    func testPageIsAStandaloneDocument() {
        let html = render("# hi")
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"), "产物要能直接双击打开，缺 <!DOCTYPE> 浏览器会进怪异模式")
        XCTAssertTrue(html.contains("<meta charset=\"utf-8\">"), "不带 charset 中文就是乱码")
        XCTAssertTrue(html.contains("<title>标题</title>"))
        XCTAssertTrue(html.contains("</html>"))
    }

    func testTitleIsEscaped() {
        let html = MarkdownHTMLExporter.export(markdown: "x",
                                               title: "a<b>\"c\"",
                                               options: .init(style: .builtIn))
        XCTAssertTrue(html.contains("<title>a&lt;b&gt;&quot;c&quot;</title>"),
                      "标题是被转义过的：`<title>a<b>` 会让浏览器以为下面全是标签")
    }

    // MARK: 转义与安全

    func testInlineHTMLLosesItsPower() {
        let html = render("这一段里有 <b>加粗</b> 的原生标签。")
        XCTAssertFalse(html.contains("<b>加粗</b>"), "源文里手写的 HTML 必须转义，否则文档成了网页（XSS 入口）")
        XCTAssertTrue(html.contains("&lt;b&gt;加粗&lt;/b&gt;"))
    }

    func testCodeContentIsEscaped() {
        let html = render("内联 `a & b < c` 结束")
        XCTAssertTrue(html.contains("<code>a &amp; b &lt; c</code>"))
    }

    func testJavaScriptLinkKeepsOnlyItsText() {
        let html = render("[点我](javascript:alert(1))")
        XCTAssertFalse(html.contains("javascript:"), "带 javascript: 的链接不能出现在 href 里")
        XCTAssertTrue(html.contains("点我"), "链接降级成纯文本后，读者至少还能看到原本的字")
    }

    func testLinkProtocolSmuggledAsEntityIsStripped() {
        // `&#106;` 是 `j` 的实体写法：不转义 `&` 的话浏览器会还原成 javascript: 并执行
        let html = render("[点我](&#106;avascript:alert(1))")
        XCTAssertFalse(html.contains("href=\"&#106;"), "转出来的 href 里 `&` 已经被转义，实体还原不了")
        XCTAssertFalse(html.contains("href=\"javascript"))
    }

    func testRelativeLinkIsKept() {
        let html = render("[笔记](notes/other.md)")
        XCTAssertTrue(html.contains("href=\"notes/other.md\""), "相对路径没有协议，属于放行的那一类")
    }

    // MARK: 常规语法

    func testHeadingGetsAnAnchor() {
        let html = render("## 二级标题")
        XCTAssertTrue(html.contains("<h2 id=\"二级标题\">二级标题</h2>"))
    }

    func testDuplicateHeadingsGetDistinctAnchors() {
        let html = render("## 同名\n\n## 同名")
        XCTAssertTrue(html.contains("id=\"同名\""))
        XCTAssertTrue(html.contains("id=\"同名-2\""), "两个同名标题共用一个 id 的话，`#同名` 只会跳到第一个")
    }

    func testSingleLineListItemHasNoNestedParagraph() {
        let html = render("- 内容")
        XCTAssertTrue(html.contains("<li>内容</li>"), "单项列表就该是一行")
        XCTAssertFalse(html.contains("<li><p>"), "套了 `<p>` 会让每行之间多出一段空白")
    }

    /// `- 一级` 下面挂着 `- 二级` 时，第一段不能被 `<p>` 裹起来，否则每行之间会多一段空白。
    func testNestedListItemKeepsItsFirstParagraphFlat() {
        let content = mainContent(render("- 一级\n  - 二级"))
        XCTAssertTrue(content.contains("<li>一级<ul>"), "嵌套项的正文和子列表之间不该隔着 `<p>`")
        XCTAssertFalse(content.contains("<li><p>"))
    }

    func testTaskListCheckboxes() {
        let html = render("- [x] 已完成\n- [ ] 未完成")
        XCTAssertTrue(html.contains("<li class=\"task\"><input type=\"checkbox\" disabled checked> 已完成</li>"))
        XCTAssertTrue(html.contains("<li class=\"task\"><input type=\"checkbox\" disabled> 未完成</li>"))
    }

    func testOrderedListKeepsStartIndex() {
        let html = render("5. 第五\n6. 第六")
        XCTAssertTrue(html.contains("<ol start=\"5\">"))
    }

    func testCodeBlockKeepsLanguage() {
        let html = render("```swift\nlet x = 1\n```")
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">"),
                      "代码块的语言要带出去，页面才好做语法高亮")
        XCTAssertTrue(html.contains("let x = 1"))
    }

    func testInlineCSSForWideTables() {
        let html = render("| a | b |\n| --- | --- |\n| 1 | 2 |")
        XCTAssertTrue(html.contains("<thead>") && html.contains("<th>"))
        XCTAssertTrue(html.contains("<tbody>") && html.contains("<td>"))
        XCTAssertTrue(html.contains("overflow-x: auto"), "表格再宽也要能在自己的盒子里横滑，而不是撑破页面")
    }

    func testColumnAlignmentBecomesInlineStyle() {
        let html = render("| 左 | 中 | 右 |\n| :--- | :---: | ---: |\n| a | b | c |")
        XCTAssertTrue(html.contains("<th style=\"text-align:center\">"))
        XCTAssertTrue(html.contains("<td style=\"text-align:right\">"))
    }

    func testHardLineBreak() {
        let html = render("第一行  \n第二行")
        XCTAssertTrue(html.contains("<br>"), "两个空格结尾的软换行要保住")
    }

    func testBlockquoteAndRule() {
        let html = render("> 引用内容\n\n---\n\n之后")
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("<hr>"))
    }

    // MARK: 脚注

    func testFootnoteDefinitionMovesToTheEnd() throws {
        let content = mainContent(render("这里有一个引用[^note]。\n\n[^note]: 脚注内容。"))
        let bodyPart = try XCTUnwrap(content.components(separatedBy: "<section class=\"footnotes\">").first)

        XCTAssertTrue(bodyPart.contains("这里有一个引用"), "正文该还在")
        XCTAssertFalse(bodyPart.contains("这里有一个引用[^note]"), "引用已经被换成锚点了")
        XCTAssertFalse(bodyPart.contains("脚注内容"), "定义被扣到文末了，正文里再来一遍就是重复")
        XCTAssertTrue(content.contains("<li id=\"fn-note\">"))
        XCTAssertTrue(content.contains("<p>脚注内容。</p>"), "定义正文按普通段落渲染")
    }

    func testFootnoteReferenceLinksToDefinitionAndBack() {
        let html = render("这里有一个引用[^note]。\n\n[^note]: 脚注内容。")
        XCTAssertTrue(html.contains("href=\"#fn-note\" id=\"fnref-note-1\""), "正文往下跳到定义")
        XCTAssertTrue(html.contains("<li id=\"fn-note\">"), "定义要有落脚的锚点")
        XCTAssertTrue(html.contains("href=\"#fnref-note-1\" class=\"footnote-backref\">↩</a>"), "↩ 回跳得上 + 要有 CSS 钩子")
    }

    func testDanglingFootnoteStaysVisibleAsText() {
        let content = mainContent(render("忘了写定义[^nope]。"))
        XCTAssertTrue(content.contains("[^nope]"), "悬空的引用原样留着，才好排查到底是忘了哪一条")
        XCTAssertFalse(content.contains("footnote-ref"))
        XCTAssertFalse(content.contains("<section class=\"footnotes\">"), "没有定义就不该空出一节脚注")
    }

    /// GFM 里一条脚注可以写多行，后面的段要缩进 —— 不先去缩进的话，cmark 会把它当成**代码块**。
    func testIndentedFootnoteContinuationStaysText() {
        let content = mainContent(render("引用[^1]。\n\n[^1]: 第一段。\n    第二段。"))
        XCTAssertTrue(content.contains("<p>第一段。"), "续行要么并进上一段、要么自成一页，反正得是正文")
        XCTAssertFalse(content.contains("<pre><code>"), "变成代码块就说明 dedent 那一步没生效")
    }

    func testNumbersOfFootnotesFollowDefinitionOrder() {
        let html = render("A[^b] 和 C[^a]。\n\n[^b]: 乙。\n[^a]: 甲。")
        XCTAssertTrue(html.contains("<li id=\"fn-b\">"), "先出现的定义在前面")
        // 正文里第一处引用要跳到正确的那一个
        XCTAssertTrue(html.contains("id=\"fnref-b-1\""), "锚点序号按**定义顺序**排")
    }

    // MARK: 图片

    func testLocalImageCanBeInlinedAsDataURI() throws {
        let directory = try makeScratchDirectory()
        try writePNG(name: "pic.png", into: directory)

        let options = MarkdownHTMLExporter.Options(style: .builtIn,
                                                   inlinesLocalImages: true,
                                                   baseDirectory: directory)
        let html = render("![](pic.png)", options: options)
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,"), "本地图片内联之后这份 HTML 拷到哪儿都能显示")
    }

    func testImageKeepsPathWhenInliningIsOff() throws {
        let directory = try makeScratchDirectory()
        try writePNG(name: "pic.png", into: directory)

        let html = render("![](pic.png)", options: .init(style: .builtIn, baseDirectory: directory))
        XCTAssertTrue(html.contains("src=\"pic.png\""))
        XCTAssertFalse(html.contains("data:image/png;base64,"))
    }

    func testMissingImageFallsBackToOriginalPath() {
        let options = MarkdownHTMLExporter.Options(style: .builtIn,
                                                   inlinesLocalImages: true,
                                                   baseDirectory: FileManager.default.temporaryDirectory)
        let html = render("![](不存在的图.png)", options: options)
        XCTAssertTrue(html.contains("src=\"不存在的图.png\""), "读不到就保留原路径，别编出一个空的 data: URL")
    }

    func testNetworkImageKeepsItsURL() {
        let options = MarkdownHTMLExporter.Options(style: .builtIn, inlinesLocalImages: true)
        let html = render("![](https://example.com/a.png)", options: options)
        XCTAssertTrue(html.contains("src=\"https://example.com/a.png\""), "网络图不该被内联")
    }

    /// ⚠️ 别用双引号当例子：cmark 默认开了「聪明引号」，成对的 `"` 会被换成印刷引号，测不到转义。
    func testImageAltTextIsEscaped() {
        let content = mainContent(render("![价格 < 100](a.png)"))
        XCTAssertTrue(content.contains("alt=\"价格 &lt; 100\""), "alt 里的内容也要转义，不然会截断那个属性")
    }

    // MARK: 配色

    func testThemeStyleSheetUsesThemeLinkColor() {
        var theme = MarkdownTheme.default
        theme.linkColor = UIColor(red: 0.5, green: 0.25, blue: 0.75, alpha: 1)
        let html = render("[x](https://a.b)", options: .init(style: .currentTheme(theme)))
        XCTAssertTrue(html.contains("a { color: #8040bf"), "跟主题导出时，链接色要真是主题里那一个")
    }

    func testBuiltInStyleSheetIsStableAcrossThemes() {
        var theme = MarkdownTheme.default
        theme.linkColor = UIColor(red: 0.5, green: 0.25, blue: 0.75, alpha: 1)
        let html = render("[x](https://a.b)", options: .init(style: .builtIn))
        XCTAssertFalse(html.contains("#8040bf"), "选了内置样式就不该再受主题影响")
    }

    /// 主题里那几个半透明的颜色（行内代码底色）不能直接把 `rgba(...)` 写进 CSS —— 白底黑底上都发灰。
    func testTranslucentTokenIsFlattenedToSolidHex() {
        var tokens = MarkdownHTMLTokens.builtIn
        tokens.codeBackground = UIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.12)
        let css = tokens.css()
        XCTAssertFalse(css.contains("rgba"), "CSS 里不该出现 rgba：网页上没有主题那套「不能盖住系统选中高亮」的顾虑")
        XCTAssertTrue(css.contains("background: #f0f0f0"), "0.12 的中灰铺在白底上 ≈ #f0f0f0（0.94 的浅灰）")
    }

    // MARK: 选项面板

    func testExportChoiceRoundTripsThroughUserDefaults() {
        let original = HTMLExportChoice.stored
        defer { original.save() }     // 别把一个测试写的值留给下一个测试

        HTMLExportChoice(usesThemeColors: false, inlinesLocalImages: true).save()
        let readBack = HTMLExportChoice.stored
        XCTAssertFalse(readBack.usesThemeColors)
        XCTAssertTrue(readBack.inlinesLocalImages, "默认 false 的那一项，得能分清是「从没存过」还是「用户选了关」")
    }
}
