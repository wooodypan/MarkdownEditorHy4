//
//  CodeHighlightingTests.swift
//  MarkdownEditorHy4Tests
//
//  代码块语法高亮测试（第一批：JavaScript / Python / Swift）
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class CodeHighlightingTests: XCTestCase {

    // MARK: - 小工具

    /// 渲染一个代码块，返回渲染后的富文本和当时的主题
    private func render(_ code: String,
                        language: String,
                        configure: ((inout MarkdownTheme) -> Void)? = nil) -> (text: NSAttributedString, theme: MarkdownTheme) {
        var theme = MarkdownTheme.default
        configure?(&theme)
        let renderer = MarkupToAttributedRenderer(theme: theme, containerWidth: 600)
        let source = "```\(language)\n\(code)\n```\n"
        let (text, _) = renderer.render(blockSource: source)
        return (text, theme)
    }

    /// 把 UIColor 拆成 RGBA 分量。
    ///
    /// 为什么不直接比 UIColor 对象：同一个颜色可能落在不同色彩空间里（sRGB / Display P3），
    /// 直接 `XCTAssertEqual` 会误判。比字符串分量最稳。
    private func rgba(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%.2f,%.2f,%.2f,%.2f", r, g, b, a)
    }

    /// 取渲染结果里某个片段的前景色的 RGBA 字符串。
    /// 找不到那段文字（或被拆成好几段）返回 nil —— 断言时会给出明确失败信息
    private func colorString(of needle: String, in text: NSAttributedString) -> String? {
        let plain = text.string as NSString
        let range = plain.range(of: needle)
        guard range.location != NSNotFound,
              let color = text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor else {
            return nil
        }
        return rgba(color)
    }

    // MARK: - 三种语言各自生效

    func testSwiftKeywordsAndStringsAreColored() {
        let code = """
        let document = Document(parsing: markdown)
        // 这是一行注释
        print("hello")
        """
        let (text, theme) = render(code, language: "swift")

        XCTAssertEqual(colorString(of: "let", in: text), rgba(theme.syntaxColors.keyword),
                       "`let` 是 Swift 关键字，应该用关键字色")
        XCTAssertEqual(colorString(of: "// 这是一行注释", in: text), rgba(theme.syntaxColors.comment),
                       "`//` 开头的整行都应该是注释色")
        XCTAssertEqual(colorString(of: "\"hello\"", in: text), rgba(theme.syntaxColors.string),
                       "双引号字符串应该是字符串色")
        XCTAssertEqual(colorString(of: "Document", in: text), rgba(theme.syntaxColors.type),
                       "大写开头的标识符按类型名上色（启发式）")
    }

    func testJavaScriptTemplatesAndCommentsAreColored() {
        let code = """
        const name = `hello ${user}`;
        /* 块注释 */
        if (count > 0) { return 42 }
        """
        let (text, theme) = render(code, language: "javascript")

        XCTAssertEqual(colorString(of: "const", in: text), rgba(theme.syntaxColors.keyword),
                       "`const` 是 JS 关键字")
        // 模板字符串按整段算：`${user}` 里的插值不单独着色（详见 SimpleCodeHighlighter 的注释）
        XCTAssertEqual(colorString(of: "`hello ${user}`", in: text), rgba(theme.syntaxColors.string),
                       "反引号模板字符串整段应该是字符串色")
        XCTAssertEqual(colorString(of: "/* 块注释 */", in: text), rgba(theme.syntaxColors.comment),
                       "`/* … */` 应该是注释色")
        XCTAssertEqual(colorString(of: "42", in: text), rgba(theme.syntaxColors.number),
                       "数字字面量应该是数字色")
        // 用小写的 js 也得生效（用户写的围栏语言名是 ```js）
        let lower = render(code, language: "js").text
        XCTAssertEqual(colorString(of: "const", in: lower), rgba(theme.syntaxColors.keyword),
                       "```js 也要能命中 JavaScript 规则表")
    }

    func testPythonHashCommentsAndPrefixedStringsAreColored() {
        let code = """
        def greet(name):
            # 打招呼
            return f"hi {name}"
        """
        let (text, theme) = render(code, language: "python")

        XCTAssertEqual(colorString(of: "def", in: text), rgba(theme.syntaxColors.keyword),
                       "`def` 是 Python 关键字")
        XCTAssertEqual(colorString(of: "# 打招呼", in: text), rgba(theme.syntaxColors.comment),
                       "Python 的 `#` 是行注释")
        // `f"..."` 的前缀要连着字符串一起上色，不能只把引号部分染红
        XCTAssertEqual(colorString(of: "f\"hi {name}\"", in: text), rgba(theme.syntaxColors.string),
                       "`f\"…\"` 这种带前缀的字符串，前缀也应该算在字符串里")
        XCTAssertEqual(colorString(of: "return", in: text), rgba(theme.syntaxColors.keyword),
                       "`return` 是 Python 关键字")
        XCTAssertEqual(colorString(of: "None", in: text), nil,
                       "这段代码里没有 None —— 顺带确认取不到片段时返回 nil，不会把测试带偏")
    }

    func testPythonTripleQuotedStringSpansMultipleLines() {
        let code = """
        doc = \"\"\"
        第一行 if x
        第二行
        \"\"\"
        n = 1
        """
        let (text, theme) = render(code, language: "python")

        // 三引号内部的 `if` 不能被引擎当成关键字（整段都是字符串）
        let plain = text.string as NSString
        let ifRange = plain.range(of: "if")
        XCTAssertNotEqual(ifRange.location, NSNotFound)
        XCTAssertEqual(rgba(text.attribute(.foregroundColor, at: ifRange.location,
                                           effectiveRange: nil) as? UIColor ?? .clear),
                       rgba(theme.syntaxColors.string),
                       "三引号里的 `if` 属于字符串内容，不该被当前缀关键字")
        // 三引号外面那行还是正常高亮
        XCTAssertEqual(colorString(of: "1", in: text), rgba(theme.syntaxColors.number),
                       "字符串结束之后的数字要恢复数字色")
    }

    // MARK: - 不支持的语言 / 开关

    func testUnsupportedLanguageStaysPlain() {
        // ⚠️ 别拿 sql / cpp 这些来举例「不支持的语言」—— 它们现在都支持了。
        // html 是**刻意**不支持的：它的语法结构（标签、属性）跟这里「按字符一趟扫过去」
        // 的做法不搭，硬套只会得到满屏乱色（详见 CodeLanguageProfile.profile 的注释）
        let theme0 = MarkdownTheme.default
        let (text, _) = render("<div class=\"a\"><span>hi</span></div>", language: "html")

        for needle in ["div", "span"] {
            XCTAssertEqual(colorString(of: needle, in: text), rgba(theme0.textColor),
                           "不支持的语言（html）不做高亮，应该保持代码块正文色")
        }
    }

    /// `enablesCodeHighlighting = false` 时必须和以前一模一样（老样子的原样保留）
    func testToggleOffKeepsPlainCode() {
        let (text, theme) = render("let x = \"abc\"", language: "swift") { theme in
            theme.enablesCodeHighlighting = false
        }

        for needle in ["let", "\"abc\""] {
            XCTAssertEqual(colorString(of: needle, in: text), rgba(theme.textColor),
                           "关掉开关之后所有代码字符都应该用代码块正文色")
        }
    }

    /// 换配色要能立刻反映到渲染结果里（验证「颜色由主题统一管」这条设计）
    func testCustomSyntaxColorIsApplied() {
        let custom = UIColor(red: 0.01, green: 0.02, blue: 0.03, alpha: 1.00)
        let (text, _) = render("const a = 1", language: "js") { theme in
            theme.syntaxColors.keyword = custom
        }
        XCTAssertEqual(colorString(of: "const", in: text), rgba(custom),
                       "改了主题的 keyword 色，渲染出来的关键字要跟着变 —— 颜色不能写死在高亮器里")
    }

    // MARK: - 不变式：高亮不能动源码

    /// 最重要的不变式：**显示的每一个字都是源码本身**（全选复制 === 源文件）
    func testHighlightingDoesNotChangeTextOrMapping() {
        let code = """
        func render(_ text: String) -> NSAttributedString {
            // 中文注释 👍
            let count = 42
        }
        """
        let source = "```swift\n\(code)\n```\n"

        var theme = MarkdownTheme.default
        let renderer = MarkupToAttributedRenderer(theme: theme, containerWidth: 600)
        let (highlighted, mappings) = renderer.render(blockSource: source)

        // 1) 显示的文本和源码一致
        XCTAssertTrue(highlighted.string.contains(code), "代码正文必须原样显示")
        // 2) 每个渲染字符位都有映射（`text.length == mappings.count` 是由 RenderedFragment 保证的）
        XCTAssertEqual(highlighted.length, mappings.count, "映射表长度必须和渲染长度一致")

        // 3) 关掉高亮之后，渲染出来的文本应该一模一样（只有颜色不同）
        theme.enablesCodeHighlighting = false
        let plainRenderer = MarkupToAttributedRenderer(theme: theme, containerWidth: 600)
        let (plain, _) = plainRenderer.render(blockSource: source)
        XCTAssertEqual(plain.string, highlighted.string, "开关只影响颜色，不该影响文本内容")

        // 4) 走一遍文档模型，确认「全选复制 === 源文件」依然成立
        let store = MarkdownDocumentStore()
        store.load(markdown: source, containerWidth: 600)
        let restored = store.sourceText(forRenderedRange: NSRange(location: 0, length: store.renderedLength))
        XCTAssertEqual(restored, source, "高亮之后全选复制出来的文本必须还是源文件本身")
    }

    /// 高亮之后代码块**背景**照常工作（多个属性 run 不能把 `.markdownCodeBlock` 那段区间切碎）
    func testCodeBlockBackgroundStillCoversWholeBlock() {
        let source = "```swift\nlet a = 1\nlet b = \"x\"\n```\n"
        let textView = MarkdownTextView(markdown: source)
        textView.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        textView.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        // 扫描 textStorage：代码块标记必须是**一整段**（ownership 没被打散）
        var markedRanges: [NSRange] = []
        textView.textStorage.enumerateAttribute(.markdownCodeBlock,
                                                in: NSRange(location: 0, length: textView.textStorage.length),
                                                options: []) { value, range, _ in
            if value is CodeBlockInfo { markedRanges.append(range) }
        }
        XCTAssertEqual(markedRanges.count, 1,
                       "整篇只有一个代码块，`.markdownCodeBlock` 必须是一段连续区间（被拆碎说明背景会画错）")

        let (frames, _) = textView.computeCodeBlockFrames()
        XCTAssertEqual(frames.count, 1, "应该算出一个代码块矩形")
    }

    // MARK: - 性能护栏

    /// 超长代码块直接放弃高亮 —— 防止贴一大段日志进来把输入卡住
    func testVeryLongCodeBlockIsNotHighlighted() {
        let line = "let value = 12345 // padding padding padding padding\n"
        let long = String(repeating: line, count: 600)   // 约 3 万个字符
        XCTAssertGreaterThan(long.count, 20_000)

        let highlighter = SimpleCodeHighlighter()
        XCTAssertTrue(highlighter.highlight("let a = 1", language: "swift").isEmpty == false,
                      "短代码块应该产出 token")
        XCTAssertTrue(highlighter.highlight(long, language: "swift").isEmpty,
                      "超过上限的代码块应该整块放弃高亮（返回空数组）")
    }

    /// 顺便量化一下：一万行的常规代码应该能在几十毫秒内扫完。
    /// 这条断言卡得很松（1 秒），主要是防止将来有人把扫描器改成多遍正则、偷偷慢几十倍。
    func testHighlightingSpeed() {
        let line = "let total = count + 1 // step \(Int.random(in: 0...9))\n"
        let code = String(repeating: line, count: 5_000)

        // 显式把上限抬上去，测的是**扫描器本身的吞吐**，不是自我保护那条分支
        let started = Date()
        let tokens = SimpleCodeHighlighter(maximumLength: 1_000_000).highlight(code, language: "swift")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(tokens.isEmpty, "这么大的代码块应该正常产出 token")
        XCTAssertLessThan(elapsed, 1.0, "扫 5000 行代码花了 \(elapsed)s，太慢了")
    }
}
