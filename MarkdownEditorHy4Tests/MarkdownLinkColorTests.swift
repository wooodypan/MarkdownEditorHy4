//
//  MarkdownLinkColorTests.swift
//  MarkdownEditorHy4Tests
//
//  链接颜色测试：验证 `MarkdownTheme.linkColor` 真的能改到链接文字的颜色。
//
//  背景（2026-09-16）：用户在 `MarkdownTheme` 里改了 `linkColor`，界面上链接颜色完全没变。
//  根因是 `visitLink` 用 `addAttributesIfAbsent` 上色，而这个函数是「已有属性优先」的 ——
//  链接文字早在 `visitText` 阶段就被 `bodyAttributes`（含 `.foregroundColor: textColor`）
//  渲染过了，所以 linkColor 永远挤不进去。详见 `RenderedFragment.addAttributesIfAbsent` 的注释。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownLinkColorTests: XCTestCase {

    // MARK: - 小工具

    /// 一个和正文色明显不同的颜色，用来当测试用的链接色
    private let testLinkColor = UIColor(red: 0.10, green: 0.20, blue: 0.90, alpha: 1.00)

    /// 把 UIColor 拆成 RGBA 分量。
    ///
    /// 为什么不直接 `XCTAssertEqual(colorA, colorB)`：同一个颜色可能落在不同的色彩空间里
    /// （比如 sRGB 和 Display P3），直接比对象会误判成不相等。比分量最稳。
    private func rgba(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        // 保留两位小数就够区分了，避免浮点误差导致断言不稳
        return String(format: "%.2f,%.2f,%.2f,%.2f", r, g, b, a)
    }

    /// 渲染一段 markdown，返回渲染结果 + 主题
    private func render(_ source: String,
                        linkColor: UIColor?) -> (text: NSAttributedString, theme: MarkdownTheme) {
        var theme = MarkdownTheme.default
        if let linkColor { theme.linkColor = linkColor }
        let renderer = MarkupToAttributedRenderer(theme: theme, containerWidth: 600)
        let (text, _) = renderer.render(blockSource: source)
        return (text, theme)
    }

    /// 取字符串里某段文字的属性
    private func attribute(_ key: NSAttributedString.Key,
                           of needle: String,
                           in text: NSAttributedString) -> Any? {
        let plain = text.string as NSString
        let range = plain.range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return text.attribute(key, at: range.location, effectiveRange: nil)
    }

    // MARK: - 测试

    /// 核心用例：链接文字必须用 `theme.linkColor`，不能是正文色
    func testLinkTextUsesLinkColor() {
        let (text, theme) = render("点[这里](https://example.com)看看\n", linkColor: testLinkColor)

        guard let color = attribute(.foregroundColor, of: "这里", in: text) as? UIColor else {
            return XCTFail("链接文字上没找到 foregroundColor 属性")
        }

        XCTAssertEqual(rgba(color), rgba(theme.linkColor),
                       "链接文字应该是 linkColor，实际却是别的颜色（很可能是正文色 textColor）")
    }

    /// 顺带确认：改了 linkColor 之后，链接**之外**的正文颜色不受影响
    func testBodyTextKeepsTextColor() {
        let (text, theme) = render("点[这里](https://example.com)看看\n", linkColor: testLinkColor)

        guard let color = attribute(.foregroundColor, of: "看看", in: text) as? UIColor else {
            return XCTFail("正文上没找到 foregroundColor 属性")
        }

        XCTAssertEqual(rgba(color), rgba(theme.textColor),
                       "链接外面的正文仍然应该是 textColor")
    }

    /// 回归保护：链接必须继续带上 `.link` 属性（可点击 / 可长按打开）
    func testLinkKeepsURLAttribute() {
        let (text, _) = render("点[这里](https://example.com)看看\n", linkColor: testLinkColor)

        let url = attribute(.link, of: "这里", in: text) as? URL
        XCTAssertEqual(url?.absoluteString, "https://example.com",
                       "链接文字必须带 .link 属性，否则点不开")
    }

    // MARK: - 第二层坑：UITextView 自己的链接样式

    /// 系统默认的链接色（实测 `UITextView().linkTextAttributes` 就是这个值）。
    ///
    /// 留着当「对照组」：如果哪天有人把 `syncLinkTextAttributes` 删了，
    /// 下面那个用例就会撞上这个颜色，一眼能看出是退回了系统默认。
    private let systemLinkBlue = UIColor(red: 0.00, green: 0.53, blue: 1.00, alpha: 1.00)

    /// 光把颜色写进富文本还不够 —— UITextView 画图时要用自己的 `linkTextAttributes` 盖上去。
    ///
    /// ### 为什么必须有这个用例
    /// 2026-09-16 修完 `visitLink` 之后富文本里的链接色已经对了，屏幕上却还是蓝的：
    /// `UITextView.linkTextAttributes` 默认是系统蓝，它**只影响绘制、不改字符串**，
    /// 所以上三个用例（查富文本）全绿也照样挡不住这个 bug。
    /// 只有对着真正的 UITextView 查 `linkTextAttributes` 才能拦住。
    func testTextViewLinkAttributesFollowTheme() {
        let textView = MarkdownTextView(markdown: "点[这里](https://example.com)看看\n")

        guard let color = textView.linkTextAttributes[.foregroundColor] as? UIColor else {
            return XCTFail("UITextView 的 linkTextAttributes 里没有 foregroundColor")
        }

        XCTAssertEqual(rgba(color), rgba(MarkdownTheme.default.linkColor),
                       "UITextView 画链接用的是自己的 linkTextAttributes，必须跟 theme.linkColor 对齐")
        XCTAssertNotEqual(rgba(color), rgba(systemLinkBlue),
                          "链接色还停在 UIKit 默认蓝 —— 说明 syncLinkTextAttributes 没生效")
    }
}
