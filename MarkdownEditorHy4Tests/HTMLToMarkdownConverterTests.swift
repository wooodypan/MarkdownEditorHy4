//
//  HTMLToMarkdownConverterTests.swift
//  MarkdownEditorHy4Tests
//
//  「网页复制的富文本 → markdown 源码」的验收测试。
//
//  这些用例守的是**转换出来的源码长什么样**：标题是不是 `#`、列表是不是 `- `、表格有没有表头行、代码块的换行有没有被吃掉。
//  它们不关心（也不该关心）渲染器把这段源码画成什么样 —— 那是另一层的事。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class HTMLToMarkdownConverterTests: XCTestCase {

    /// 转一段 HTML；转不出来时返回空串（用例里拿它做断言更直观）
    private func convert(_ html: String) -> String {
        HTMLToMarkdownConverter.markdown(fromHTML: html) ?? ""
    }

    // MARK: - 块级结构

    func testHeadingsBecomeHashes() {
        let markdown = convert("<h1>一级</h1><h2>二级</h2><h6>六级</h6>")
        XCTAssertEqual(markdown, "# 一级\n\n## 二级\n\n###### 六级")
    }

    func testParagraphsAreSeparatedByBlankLines() {
        let markdown = convert("<p>第一段</p><p>第二段</p>")
        XCTAssertEqual(markdown, "第一段\n\n第二段")
    }

    func testHorizontalRuleBecomesDashes() {
        XCTAssertEqual(convert("<p>上</p><hr><p>下</p>"), "上\n\n---\n\n下")
    }

    /// `<div>` 只是个壳：里面的段落该各自成段，不该被塞进一行
    func testDivIsTransparent() {
        XCTAssertEqual(convert("<div><p>一</p><p>二</p></div>"), "一\n\n二")
    }

    // MARK: - 行内

    func testEmphasisAndInlineCode() {
        let markdown = convert("<p><strong>粗</strong> 和 <em>斜</em> 和 <del>删</del> 和 <code>码</code></p>")
        XCTAssertEqual(markdown, "**粗** 和 *斜* 和 ~~删~~ 和 `码`")
    }

    /// 行内代码里的内容是字面量，不能转义 —— 反引号一转义 `` `code` `` 就出不来了
    func testBackticksInsideInlineCodeAreNotEscaped() {
        XCTAssertEqual(convert("<p>用 <code>`code`</code> 表示</p>"), "用 `` `code` `` 表示")
    }

    func testLinks() {
        let markdown = convert(#"<p><a href="https://a.com">文字</a> 和 <a href="https://b.com" title="标题">带标题</a></p>"#)
        XCTAssertEqual(markdown, "[文字](https://a.com) 和 [带标题](https://b.com \"标题\")")
    }

    /// 文字和地址一模一样 → 输出自动链接，更短
    func testLinkWithSameTextAndHrefBecomesAutolink() {
        XCTAssertEqual(convert(#"<p>访问 <a href="https://a.com">https://a.com</a></p>"#),
                       "访问 <https://a.com>")
    }

    /// 页内锚点（`#top`）在 markdown 里没有意义，只留文字
    func testAnchorLinkKeepsTextOnly() {
        XCTAssertEqual(convert(##"<p><a href="#top">回到顶部</a></p>"##), "回到顶部")
    }

    func testImages() {
        let markdown = convert(#"<p><img src="./a.png" alt="图"></p>"#)
        XCTAssertEqual(markdown, "![图](./a.png)")
    }

    // MARK: - 列表

    /// 浏览器复制列表时几乎总是 `<li><p>内容</p></li>` —— 内容必须留在标记那一行，不能因为 `<p>` 是块级元素就被甩到下一行
    func testBrowserStyleListItemsStayOnTheMarkerLine() {
        let markdown = convert("<ul><li><p>苹果</p></li><li><p>香蕉</p></li></ul>")
        XCTAssertEqual(markdown, "- 苹果\n- 香蕉")
    }

    func testNestedListIsIndented() {
        let markdown = convert("<ul><li>一级<ul><li>二级</li></ul></li></ul>")
        XCTAssertEqual(markdown, "- 一级\n  - 二级")
    }

    func testOrderedListIsRenumbered() {
        XCTAssertEqual(convert("<ol><li>一</li><li>二</li></ol>"), "1. 一\n2. 二")
    }

    /// `<ol start="3">`：源码里的序号是页面上的，markdown 里照着它数
    func testOrderedListHonorsStartAttribute() {
        XCTAssertEqual(convert(#"<ol start="3"><li>三</li><li>四</li></ol>"#), "3. 三\n4. 四")
    }

    func testTaskList() {
        let markdown = convert(##"<ul><li><input type="checkbox" checked><p>已完成</p></li>"##
            + ##"<li><input type="checkbox"><p>未完成</p></li></ul>"##)
        XCTAssertEqual(markdown, "- [x] 已完成\n- [ ] 未完成")
    }

    // MARK: - 引用

    /// 引用里有多段时，中间那行必须还是引用（`>`），不然第二段就跳出引用了
    func testBlockquoteKeepsEveryBlockInside() {
        let markdown = convert("<blockquote><p>一</p><p>二</p></blockquote>")
        XCTAssertEqual(markdown, "> 一\n>\n> 二")
    }

    func testNestedBlockquote() {
        XCTAssertEqual(convert("<blockquote><p>外</p><blockquote><p>内</p></blockquote></blockquote>"),
                       "> 外\n>\n> > 内")
    }

    // MARK: - 代码块

    /// 代码里的换行必须原样留着 —— 这是最容易坏的一条（SwiftSoup 的 `text()` 会把换行规范化成空格，只有 `getWholeText()` 才是原文）
    func testCodeBlockKeepsNewlinesAndLanguage() {
        let markdown = convert("<pre><code class=\"language-python\">def f():\n    return 1\n</code></pre>")
        XCTAssertEqual(markdown, "```python\ndef f():\n    return 1\n```")
    }

    /// `<pre>` 里没有语言标识时输出纯围栏，不要写个 `language-` 上去
    func testCodeBlockWithoutLanguage() {
        XCTAssertEqual(convert("<pre><code>hello</code></pre>"), "```\nhello\n```")
    }

    // MARK: - 表格

    func testTableBecomesGFMTable() {
        let markdown = convert("""
            <table><thead><tr><th>Name</th><th style="text-align:right;">Age</th></tr></thead>
            <tbody><tr><td>Alice</td><td>20</td></tr></tbody></table>
            """)
        XCTAssertEqual(markdown, "| Name | Age |\n| --- | ---: |\n| Alice | 20 |")
    }

    /// 单元格里的 `|` 不转义的话，一列会裂成两列
    func testPipeInsideCellIsEscaped() {
        let markdown = convert("<table><tr><th>a|b</th></tr><tr><td>1</td></tr></table>")
        XCTAssertTrue(markdown.contains("a\\|b"), "实际输出：\n\(markdown)")
    }

    // MARK: - 空白与换行

    /// `<br>` 是硬换行：行尾一个反斜杠 + 换行，两段文字不能因为换行就分成两个段落
    func testHardBreakStaysInOneParagraph() {
        XCTAssertEqual(convert("<p>第一行<br>第二行</p>"), "第一行\\\n第二行")
    }

    /// HTML 里的软换行（排版用的换行）在 markdown 里是一个空格，不是分段
    func testSoftBreakBecomesSpace() {
        XCTAssertEqual(convert("<p>第一行\n第二行</p>"), "第一行 第二行")
    }

    /// 行内元素前面那个空格不能丢（`<p>这是一个 <span>span</span></p>`）
    func testSpaceBeforeInlineElementIsKept() {
        XCTAssertEqual(convert("<p>这是一个 <span>inline</span> 元素</p>"), "这是一个 inline 元素")
    }

    // MARK: - 转义

    /// 正文里真有的 `*`、`#` 要转义，不然会被当成 markdown 语法
    func testMarkdownCharactersInTextAreEscaped() {
        XCTAssertEqual(convert("<p>*这不是斜体*</p>"), "\\*这不是斜体\\*")
        XCTAssertEqual(convert("<p># 这不是标题</p>"), "\\# 这不是标题")
    }

    // MARK: - 来源相关的脏 HTML

    /// 脚本和样式不是正文，整块扔掉
    func testScriptAndStyleAreDropped() {
        let markdown = convert("<style>p{color:red}</style><script>alert(1)</script><p>正文</p>")
        XCTAssertEqual(markdown, "正文")
    }

    /// Windows 剪贴板的 `<!--StartFragment-->` 外壳：只取两个标记之间的内容
    func testOnlyFragmentIsConverted() {
        let markdown = convert("<html><body>前面不要<!--StartFragment--><p>只要这段</p>"
                               + "<!--EndFragment-->后面也不要</body></html>")
        XCTAssertEqual(markdown, "只要这段")
    }

    /// Word / Google Docs 把样式写在 `style` 里而不是用 `<b>`
    func testFontWeightInStyleBecomesBold() {
        XCTAssertEqual(convert(#"<p><span style="font-weight:700">粗</span></p>"#), "**粗**")
    }

    /// Google Docs 会把整篇包在 `<b style="font-weight:normal">` 里 —— 不能全篇加粗
    func testNormalFontWeightCancelsBoldTag() {
        XCTAssertEqual(convert(#"<b style="font-weight:normal"><p>正文</p></b>"#), "正文")
    }

    /// 网页里的脚注上标 → `[^1]`
    func testFootnoteSuperscript() {
        let markdown = convert(##"<p>文本<sup class="md-footnote"><a href="#dfref-1">1</a></sup></p>"##)
        XCTAssertEqual(markdown, "文本[^1]")
    }

    /// 网页里的实体（`&amp;`）要解成字符，不能原样留着
    func testEntitiesAreDecoded() {
        XCTAssertEqual(convert("<p>Tom &amp; Jerry</p>"), "Tom & Jerry")
    }

    // MARK: - 转不出来的时候就别硬转

    func testEmptyHTMLReturnsNil() {
        XCTAssertNil(HTMLToMarkdownConverter.markdown(fromHTML: ""))
    }

    /// 整页只有脚本 / 样式表：没有正文可转，返回 nil 让调用方退回纯文本
    func testScriptOnlyHTMLReturnsNil() {
        XCTAssertNil(HTMLToMarkdownConverter.markdown(fromHTML: "<script>var a=1</script>"))
    }

    // MARK: - 真实剪贴板内容

    /// 拿仓库根目录里那份「浏览器打开 raw.html 后 ⌘C」的真实剪贴板内容跑一遍。
    ///
    /// ### 为什么只断言几个关键标记，不做全文比对
    /// 这份文件有 30 多节、六万多字节，全文比对会把测试变成「改一个字就红」的快照；
    /// 这里要守的是「该转的都转出来了」——标题、表格、代码块、任务列表都在就行。
    ///
    /// ⚠️ 文件不在（比如仓库被剪枝过）就跳过，不能让测试因为缺文件变红。
    func testRealClipboardHTMLKeepsAllTheStructures() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()     // MarkdownEditorHy4Tests/
            .deletingLastPathComponent()     // 仓库根目录
            .appendingPathComponent("UIPasteboard.html")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("根目录里没有 UIPasteboard.html，跳过这一条")
        }

        let html = try String(contentsOf: url, encoding: .utf8)
        let markdown = try XCTUnwrap(HTMLToMarkdownConverter.markdown(fromHTML: html),
                                     "真实剪贴板内容一个字都没转出来")

        XCTAssertTrue(markdown.contains("# cmark-gfm 常见语法测试"), "一级标题没转出来")
        XCTAssertTrue(markdown.contains("| Name | Age | City |"), "表格没转出来")
        XCTAssertTrue(markdown.contains("```javascript"), "代码块没带上语言标识")
        XCTAssertTrue(markdown.contains("console.log(message);"), "代码块的换行被吃掉了")
        XCTAssertTrue(markdown.contains("- [x] 已完成"), "任务列表没转出来")
        XCTAssertTrue(markdown.contains("[普通链接](https://example.com)"), "链接没转出来")
        XCTAssertTrue(markdown.contains("![示例图片](./sample.png)"), "图片没转出来")
        XCTAssertTrue(markdown.contains("> 外层引用"), "引用没转出来")
        XCTAssertFalse(markdown.contains("<div"), "不该把 HTML 标签留在结果里")
        XCTAssertFalse(markdown.contains("<style"), "样式表不该出现在正文里")
    }

    /// 原始的那个 `raw.html` 同样要能转（它是带 `<html><head>` 外壳的完整页面）
    func testRawHTMLFileIsConvertedFromBodyOnly() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("raw.html")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("根目录里没有 raw.html，跳过这一条")
        }

        let html = try String(contentsOf: url, encoding: .utf8)
        let markdown = try XCTUnwrap(HTMLToMarkdownConverter.markdown(fromHTML: html))

        XCTAssertTrue(markdown.contains("# cmark-gfm 常见语法测试"), "正文没转出来")
        // `<head>` 里的 title 不是正文，不该出现
        XCTAssertFalse(markdown.contains("<!doctype"), "不该把 doctype 当正文")
        XCTAssertFalse(markdown.contains("meta charset"), "`<head>` 里的内容不该当正文")
    }
}

// MARK: - 设置开关

@MainActor
final class PasteHTMLSettingTests: XCTestCase {

    private func makeTempFileURL(_ name: String = "settings.json") -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasteHTMLSettingTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent(name)
    }

    /// 需求：默认开启
    func testPasteConversionIsOnByDefault() {
        XCTAssertTrue(MarkdownEditorSettings(fileURL: makeTempFileURL()).pastesHTMLAsMarkdown)
    }

    /// 关掉要落盘，下次启动还是关着的
    func testPasteConversionIsPersisted() {
        let url = makeTempFileURL()
        MarkdownEditorSettings(fileURL: url).setPastesHTMLAsMarkdown(false)

        XCTAssertFalse(MarkdownEditorSettings(fileURL: url).pastesHTMLAsMarkdown,
                       "开关没落盘，下次启动就复位了")
    }

    /// 老配置文件里没有这个字段 → 退回默认（开），不能顺手把整份配置作废
    func testMissingFieldFallsBackToDefault() throws {
        let url = makeTempFileURL()
        try Data(#"{"remembersScrollPosition": false}"#.utf8).write(to: url)

        let settings = MarkdownEditorSettings(fileURL: url)
        XCTAssertTrue(settings.pastesHTMLAsMarkdown)
        XCTAssertFalse(settings.remembersScrollPosition, "别的设置不该被带走")
    }

    /// 设置页上要有这一行，而且默认是开的；拨一下要写回配置
    ///
    /// ⚠️ 帧高给到 4200：这一行在最后一个分组，帧不够高时它的 cell 根本不会被建出来（那是测试没把页面铺开，不是功能坏了）。
    func testSettingsPageHasTheToggleAndWritesBack() throws {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        let controller = SettingsViewController(settings: settings)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 4200)
        controller.view.layoutIfNeeded()

        let toggle = try XCTUnwrap(switchLabeled("粘贴网页内容时转成 Markdown", in: controller.view),
                                   "设置页上该有「粘贴网页内容时转成 Markdown」这个开关")
        XCTAssertTrue(toggle.isOn, "默认是开的")

        toggle.isOn = false
        toggle.sendActions(for: .valueChanged)
        XCTAssertFalse(settings.pastesHTMLAsMarkdown, "拨了开关却没写回配置")
    }

    /// 关掉开关后，剪贴板即使有 HTML 也不接管 —— 粘贴退回原来的纯文本
    func testTurningTheSwitchOffStopsConversion() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setPastesHTMLAsMarkdown(false)

        let pasteboard = UIPasteboard.withUniqueName()
        pasteboard.setData("<h1>标题</h1>".data(using: .utf8)!, forPasteboardType: "public.html")

        XCTAssertNil(ClipboardHTMLMarkdown.markdown(from: pasteboard, settings: settings))
    }

    /// 开关开着、剪贴板里有 HTML → 转出源码
    func testTurningTheSwitchOnConvertsHTML() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        let pasteboard = UIPasteboard.withUniqueName()
        pasteboard.setData("<h1>标题</h1><p>正文</p>".data(using: .utf8)!,
                            forPasteboardType: "public.html")

        XCTAssertEqual(ClipboardHTMLMarkdown.markdown(from: pasteboard, settings: settings),
                       "# 标题\n\n正文")
    }

    /// 剪贴板里只有纯文本（没有 HTML）→ 不接管
    func testPlainTextPasteboardIsNotTakenOver() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        let pasteboard = UIPasteboard.withUniqueName()
        pasteboard.string = "只是一段文字"

        XCTAssertNil(ClipboardHTMLMarkdown.markdown(from: pasteboard, settings: settings))
    }

    /// 端到端：在编辑器里按 ⌘V，插进来的得是**转换后的源码**，不是剪贴板里的纯文本
    ///
    /// ### 为什么不去动 `UIPasteboard.general`
    /// 那是用户真实的剪贴板，测试一写就把他复制的东西冲掉了。
    /// 所以这里单独开一个剪贴板，再由注入的转换器去读它 —— `MarkdownTextView.paste` 那条路（图片 → 富文本 → 纯文本）走的还是真代码。
    func testPastingInTheEditorInsertsConvertedSource() {
        let textView = MarkdownTextView(markdown: "")
        textView.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        textView.layoutIfNeeded()

        let pasteboard = UIPasteboard.withUniqueName()
        pasteboard.items = [["public.html": "<h1>标题</h1><p>正文</p>",
                             "public.utf8-plain-text": "纯文本那一版"]]
        // ⚠️ `markdownFromRichText()` 内部读的是 `UIPasteboard.general`，所以这里让转换器固定读上面那个专用剪贴板，别的部分照旧走真实代码
        textView.pasteboardController.richTextConverter = { _ in
            ClipboardHTMLMarkdown.markdown(from: pasteboard)
        }

        textView.paste(nil)

        XCTAssertTrue(textView.documentStore.sourceDocument.contains("# 标题"),
                      "粘进来的该是转换后的 markdown，实际是：\n\(textView.documentStore.sourceDocument)")
        XCTAssertFalse(textView.documentStore.sourceDocument.contains("纯文本那一版"))
    }

    private func switchLabeled(_ label: String, in view: UIView) -> UISwitch? {
        for subview in view.subviews {
            if let toggle = subview as? UISwitch, toggle.accessibilityLabel == label { return toggle }
            if let found = switchLabeled(label, in: subview) { return found }
        }
        return nil
    }
}
