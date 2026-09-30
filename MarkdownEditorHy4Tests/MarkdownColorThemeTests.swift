//
//  MarkdownColorThemeTests.swift
//  MarkdownEditorHy4Tests
//
//  配色（主题）测试。
//
//  这里守的是三件「错了用户一眼就能看出来」的事：
//  1. 十六进制颜色字符串要能被解析（写错不能崩、也不能把界面涂黑）；
//  2. 套上 vue / vue-dark 之后，颜色确实是那两份 CSS 里的值；
//  3. **从 vue-dark 切回「默认」，颜色必须退回 `MarkdownTheme` 自带的那一套** ——
//     这条最容易坏：配色表是「覆盖表」，空表一项都不覆盖，
//     不做「先退回默认再覆盖」的话，切回默认会原封不动留着深色。
//  另外顺带钉住「换配色不动排版参数」，以及「用户的 JSON 只盖自己写了的那些色」。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownColorThemeTests: XCTestCase {

    // MARK: - 小工具

    /// 把 UIColor 拆成 RGBA 字符串来比。
    ///
    /// 为什么不直接 `XCTAssertEqual` 两个 UIColor：同一个颜色可能落在不同的色彩空间
    /// （sRGB / Display P3），比对象会误判成不相等。比分量最稳。
    private func rgba(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%.2f,%.2f,%.2f,%.2f", r, g, b, a)
    }

    private func rgba(_ hex: String) -> String {
        rgba(MarkdownHexColor.parse(hex) ?? .clear)
    }

    // MARK: - 十六进制颜色

    /// 三种写法都要认：6 位、8 位（带透明度）、3 位简写
    func testHexColorParsing() {
        XCTAssertEqual(rgba("#42b983"), "0.26,0.73,0.51,1.00", "6 位写法要能解析")
        XCTAssertEqual(rgba("42B983"), "0.26,0.73,0.51,1.00", "没有 # 前缀、大写也要认")
        XCTAssertEqual(MarkdownHexColor.parse("#42b983D9")?.cgColor.alpha ?? 0, 0.85, accuracy: 0.01,
                       "8 位写法的后两位是透明度")
        XCTAssertEqual(rgba("#f0a"), "1.00,0.00,0.67,1.00", "3 位简写要展开成 6 位再解析")
    }

    /// 写坏了不能崩，也不能返回一个「黑块」把界面搞乱 —— 返回 nil，那一色就跳过
    func testInvalidHexColorIsIgnored() {
        XCTAssertNil(MarkdownHexColor.parse("#12345"), "位数不对")
        XCTAssertNil(MarkdownHexColor.parse("不是颜色"), "根本不是十六进制")
        XCTAssertNil(MarkdownHexColor.parse(""), "空串")
    }

    // MARK: - 内置预设

    /// vue-dark 的颜色必须和仓库根目录 `vue-dark.css` 里的一致
    func testVueDarkPaletteMatchesCSS() {
        var theme = MarkdownTheme.default
        theme.applyColorPalette(.vueDark)

        XCTAssertEqual(rgba(theme.editorBackground), rgba("#1f1f1f"), "body 的 background-color")
        XCTAssertEqual(rgba(theme.textColor), rgba("#eeeeee"), "body 的 color")
        XCTAssertEqual(rgba(theme.linkColor), rgba("#42b983"), "a 的 color（Vue 绿）")
        XCTAssertEqual(rgba(theme.inlineCodeColor), rgba("#f3b37f"), "`#write code, tt` 的 color")
        XCTAssertEqual(rgba(theme.codeBlockBackground), rgba("#1a1a1a"), "`.md-fences` 的背景")
        XCTAssertEqual(rgba(theme.separatorColor), rgba("#2e2e2e"), "hr 的 background-color")
        XCTAssertEqual(rgba(theme.syntaxColors.keyword), rgba("#bb7fc3"), "`.cm-keyword`")
        XCTAssertEqual(rgba(theme.syntaxColors.string), rgba("#d48888"), "`.cm-string`")
    }

    /// vue（浅色）的颜色必须和 `vue.css` 里的一致
    func testVuePaletteMatchesCSS() {
        var theme = MarkdownTheme.default
        theme.applyColorPalette(.vue)

        XCTAssertEqual(rgba(theme.editorBackground), rgba("#ffffff"), "浅色主题是白底")
        XCTAssertEqual(rgba(theme.textColor), rgba("#34495e"), "body 的 color")
        XCTAssertEqual(rgba(theme.linkColor), rgba("#42b983"), "a 的 color（Vue 绿）")
        XCTAssertEqual(rgba(theme.inlineCodeColor), rgba("#e96900"), "`#write code, tt` 的 color")
        XCTAssertEqual(rgba(theme.codeBlockBackground), rgba("#f8f8f8"), "`.md-fences` 的背景")
        XCTAssertEqual(rgba(theme.quoteTextColor), rgba("#777777"), "blockquote 的 color")
    }

    /// 行内代码底色**必须半透明**：不透明会盖住系统画在文字下面的选中高亮
    func testInlineCodeBackgroundStaysTranslucent() {
        var theme = MarkdownTheme.default

        theme.applyColorPalette(.vue)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        theme.inlineCodeBackground.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertLessThan(alpha, 1, "行内代码底色一旦不透明，框选它时会像没选中")

        theme.applyColorPalette(.vueDark)
        theme.inlineCodeBackground.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertLessThan(alpha, 1, "深色主题同理")
    }

    /// 最要紧的一条：从深色切回「默认」，必须退回 `MarkdownTheme` 自带的颜色
    func testSwitchingBackToDefaultRestoresBuiltInColors() {
        var theme = MarkdownTheme.default
        theme.applyColorPalette(.vueDark)
        // 先确认深色确实套上了，否则这个测试「什么都没验到」就通过了
        XCTAssertNotEqual(rgba(theme.textColor), rgba(MarkdownTheme.default.textColor))

        theme.applyColorPalette(.default)

        XCTAssertEqual(rgba(theme.textColor), rgba(MarkdownTheme.default.textColor),
                       "切回「默认」却还留着深色 —— 配色表是覆盖表，空表一项都不覆盖，必须先退回内建默认")
        XCTAssertEqual(rgba(theme.editorBackground), rgba(MarkdownTheme.default.editorBackground))
        XCTAssertEqual(rgba(theme.codeBlockBackground), rgba(MarkdownTheme.default.codeBlockBackground))
        XCTAssertEqual(rgba(theme.syntaxColors.keyword), rgba(MarkdownTheme.default.syntaxColors.keyword))
    }

    /// 换配色**只**换颜色：用户在设置页调过的字号、行高、段间距不能被冲掉
    func testColorThemeKeepsTypographyAndSizes() {
        var theme = MarkdownTheme.default
        theme.applyBodyFontSize(22)
        theme.lineHeightMultiple = 1.6
        theme.paragraphSpacing = 30
        theme.image.maxHeight = 500

        theme.applyColorPalette(.vueDark)

        XCTAssertEqual(theme.bodyFont.pointSize, 22, accuracy: 0.01, "换配色不该动字号")
        XCTAssertEqual(theme.lineHeightMultiple, 1.6, accuracy: 0.01, "换配色不该动行高")
        XCTAssertEqual(theme.paragraphSpacing, 30, accuracy: 0.01, "换配色不该动段间距")
        XCTAssertEqual(theme.image.maxHeight, 500, accuracy: 0.01, "换配色不该动图片尺寸")
    }

    // MARK: - JSON 覆盖

    /// 用户的 JSON 只盖自己写了的色，没写的继续用内置主题的
    func testJSONPaletteOverridesOnlyWhatItSays() throws {
        // 只写一条：把链接改成红色
        let json = Data("{\"link\": \"#ff0000\"}".utf8)
        let custom = try XCTUnwrap(try? JSONDecoder().decode(MarkdownColorPalette.self, from: json))

        var theme = MarkdownTheme.default
        theme.applyColorPalette(.vue.merging(custom))

        XCTAssertEqual(rgba(theme.linkColor), rgba("#ff0000"), "JSON 里写了的色要盖住预设")
        XCTAssertEqual(rgba(theme.textColor), rgba("#34495e"), "JSON 没写的色继续用 vue 的")
    }

    /// JSON 里颜色写成普通字符串就行（手写起来省一层括号）；`{"hex": ...}` 那种老写法也认
    func testColorInJSONAcceptsBothForms() throws {
        let flat = try JSONDecoder().decode(MarkdownColorPalette.self,
                                            from: Data("{\"link\": \"#ff0000\"}".utf8))
        XCTAssertEqual(flat.link?.hex, "#ff0000", "首选写法：直接一个字符串")

        let nested = try JSONDecoder().decode(MarkdownColorPalette.self,
                                              from: Data("{\"link\": {\"hex\": \"#00ff00\"}}".utf8))
        XCTAssertEqual(nested.link?.hex, "#00ff00", "兼容写法：键里套一个对象")
    }

    /// 「一个色都没给」的 JSON 不该被当成「用户指定了主题」
    func testEmptyJSONPaletteIsNotATheme() throws {
        let json = Data("{\"unrelatedKey\": 42}".utf8)
        let custom = try XCTUnwrap(try? JSONDecoder().decode(MarkdownColorPalette.self, from: json))
        XCTAssertTrue(custom.isEmpty, "一个颜色字段都没匹配上，就该当成空的")
        XCTAssertTrue(MarkdownColorPalette.default.isEmpty, "「默认」本来就是一张空表")
    }

    /// 配置层：没指定 JSON 时就用所选主题自带的颜色；指定了才叠加
    func testSettingsResolveIgnoresCustomPaletteWhenNotSpecified() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setColorTheme(.vueDark)

        let withoutFile = settings.resolvedColorPalette(customPalette: nil)
        XCTAssertEqual(withoutFile, MarkdownColorPalette.vueDark, "没指定文件 → 用内置主题的色")

        // 只记了名字、文件却读不出来（比如被删了）时，同样退化成内置主题，
        // 绝不能因为一份读不到的文件让界面变成一片黑
        settings.setCustomThemeFileName("gone.json")
        XCTAssertEqual(settings.resolvedColorPalette(customPalette: nil),
                       MarkdownColorPalette.vueDark, "指定了文件但读不出来 → 还是用内置主题的色")

        let withFile = settings.resolvedColorPalette(customPalette: MarkdownColorPalette(text: "#123456"))
        XCTAssertEqual(withFile.text?.hex, "#123456", "读到了文件 → 文件里的色盖在上面")
        XCTAssertEqual(withFile.link?.hex, MarkdownColorPalette.vueDark.link?.hex,
                       "文件没写的色继续用主题的")
    }

    // MARK: - 渲染出来的颜色

    /// 端到端钉一下：套了配色之后，渲染出来的链接文字真是那个颜色
    func testRenderedLinkUsesPaletteColor() {
        var theme = MarkdownTheme.default
        theme.applyColorPalette(.vueDark)
        let renderer = MarkupToAttributedRenderer(theme: theme, containerWidth: 600)
        let (text, _) = renderer.render(blockSource: "点[这里](https://example.com)看看\n")

        let plain = text.string as NSString
        let range = plain.range(of: "这里")
        XCTAssertNotEqual(range.location, NSNotFound, "测试用的链接文字没渲染出来")

        guard let color = text.attribute(.foregroundColor, at: range.location,
                                        effectiveRange: nil) as? UIColor else {
            return XCTFail("链接文字上没有 foregroundColor 属性")
        }
        XCTAssertEqual(rgba(color), rgba("#42b983"), "渲染出来的链接应该是 vue-dark 的主色")
    }

    // MARK: - 小工具

    private func makeTempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-settings-\(UUID().uuidString).json")
    }
}
