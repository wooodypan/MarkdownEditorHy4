import Foundation
import UIKit

/// 导出 HTML 这一版式用到的全部颜色和字体，字段跟 `MarkdownTheme` 一一对应。
///
/// ### 为什么把颜色和主题拆成两层
/// 「从 `MarkdownTheme` 取哪些色」这件事只在这里写一遍，`css()` 只认本结构体里的字段 ——以后主题加字段、改语义都碰不到 CSS 那段字符串拼接。反过来也一样：调排版只改 `css()` 一处。
///
/// ### 为什么不直接把动态色打印出来
/// 主题里的 `UIColor.label` 这类「动态色」在浅色 / 深色下是两个不同的值，必须先 `resolvedColor(with:)` 拿到当下这一份；
/// 而且行内代码底色是**半透明**的（这是主题里刻意留的，否则会盖住系统的选中高亮），铺到网页上要先和页面底色叠成实色 ——不然导出来是 `rgba(0.5,0.5,0.5,0.12)`，白底黑底上看着都脏。
/// ### 内置那套写在哪儿
/// 就写在下面这些**属性的默认值**里：`MarkdownHTMLTokens()` 出来就是内置的那版 GitHub 风格， `init(theme:)` 再把它们按当前主题逐个覆盖掉。
/// （Swift 里自定义了 init 就不再给逐成员的初始化器，少写一个 16 个参数的构造函数是这么来的。）
struct MarkdownHTMLTokens {

    var pageBackground: UIColor = UIColor(white: 1, alpha: 1)
    var text: UIColor = UIColor(red: 0.15, green: 0.16, blue: 0.18, alpha: 1)
    var headingText: UIColor = UIColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1)
    var link: UIColor = UIColor(red: 0.04, green: 0.38, blue: 0.79, alpha: 1)
    /// 行内代码、代码块里的文字色
    var codeText: UIColor = UIColor(red: 0.20, green: 0.23, blue: 0.27, alpha: 1)
    var codeBackground: UIColor = UIColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1)
    var quoteText: UIColor = UIColor(red: 0.38, green: 0.42, blue: 0.48, alpha: 1)
    var quoteBar: UIColor = UIColor(red: 0.82, green: 0.85, blue: 0.88, alpha: 1)
    var tableHeaderBackground: UIColor = UIColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1)
    var tableBorder: UIColor = UIColor(red: 0.87, green: 0.89, blue: 0.91, alpha: 1)
    /// 分隔线（`<hr>`）、脚注区上边线的颜色
    var rule: UIColor = UIColor(red: 0.89, green: 0.91, blue: 0.93, alpha: 1)
    /// 次要文字：源文里手写 HTML 被转义后那一块
    var mutedText: UIColor = UIColor(red: 0.44, green: 0.48, blue: 0.53, alpha: 1)
    /// 点击脚注跳过去时那一行的高亮底（`:target`）
    var footnoteFlash: UIColor = UIColor(red: 1.00, green: 0.96, blue: 0.76, alpha: 1)

    var bodyFontFamily: String = Self.systemBodyStack
    var bodyFontSize: CGFloat = 17
    var codeFontFamily: String = Self.systemCodeStack

    // MARK: 内置这套（GitHub 风格，浅色）

    /// 内置的 GitHub 风格配色。**跟编辑器当前用的主题无关**，任何时候导出都长一个样。
    static var builtIn: MarkdownHTMLTokens { MarkdownHTMLTokens() }

    /// 按编辑器当前这套主题配色导出。
    ///
    /// ⚠️ 主题里的那些颜色可能是动态色（`UIColor.label`），也可能是半透明的（行内代码底色为了不盖住选中高亮刻意留了 alpha）——这两件事都由 `css()` 里那个 `flat(_:)` 兜着：先按当前外观解析，再叠到页面底色上摊成实色。
    ///
    /// ### 为什么写成工厂方法而不是 `init(theme:)`
    /// Swift 里一旦自己写了 init，就不给那个「逐成员」的初始化器了 ——内置的 `MarkdownHTMLTokens()` 就没了。改走静态工厂，两边都不用手写 16 个参数。
    static func from(theme: MarkdownTheme) -> MarkdownHTMLTokens {
        MarkdownHTMLTokens(
            pageBackground: theme.editorBackground,
            text: theme.textColor,
            headingText: theme.textColor,
            link: theme.linkColor,
            codeText: theme.inlineCodeColor,
            codeBackground: theme.inlineCodeBackground,
            quoteText: theme.quoteTextColor,
            quoteBar: theme.quoteBarColor,
            tableHeaderBackground: theme.table.headerBackground,
            tableBorder: theme.table.borderColor,
            rule: theme.separatorColor,
            mutedText: theme.markerColor,
            footnoteFlash: theme.searchMatchBackground,
            bodyFontFamily: cssFont(from: theme.bodyFont.familyName, fallback: systemBodyStack),
            bodyFontSize: theme.bodyFont.pointSize,
            codeFontFamily: cssFont(from: theme.codeFont.familyName, fallback: systemCodeStack)
        )
    }

    // MARK: 生成 CSS

    /// 把这套 token 拼成一份完整的样式表。
    ///
    /// 几个刻意的选择：
    /// - 表格用 `display:block; width:max-content; overflow-x:auto`：太宽的表能在自己的盒子里横滑，而不是把整个页面撑出横向滚动条；
    /// - `img { max-width:100% }`：图再大也不会把正文顶出屏幕；
    /// - 任务列表那一项去掉 `list-style`，换掉原生圆点，否则它和那个 `<input>` 会并排出现两个符号。
    func css() -> String {
        let paper = flat(pageBackground)
        return """
        :root { color-scheme: \(Self.isDarkSplashkit(paper) ? "dark" : "light"); }
        html { -webkit-text-size-adjust: 100%; }
        body {
          margin: 0 auto;
          max-width: 820px;
          padding: 32px 24px 96px;
          background: \(paper);
          color: \(flat(text));
          font-family: \(bodyFontFamily);
          font-size: \(Int(bodyFontSize.rounded()))px;
          line-height: 1.72;
          word-wrap: break-word;
        }
        h1, h2, h3, h4, h5, h6 {
          margin: 1.7em 0 0.7em;
          line-height: 1.35;
          font-weight: 600;
          color: \(flat(headingText));
        }
        h1 { font-size: 1.9em; border-bottom: 1px solid \(flat(rule)); padding-bottom: 0.3em; }
        h2 { font-size: 1.5em; border-bottom: 1px solid \(flat(rule)); padding-bottom: 0.3em; }
        h3 { font-size: 1.25em; }
        h4 { font-size: 1.08em; }
        h5 { font-size: 1em; }
        h6 { font-size: 0.94em; color: \(flat(mutedText)); }
        p, ul, ol, dl, blockquote, pre, table { margin: 0 0 1em; }
        a { color: \(flat(link)); text-decoration: none; }
        a:hover { text-decoration: underline; }
        strong { font-weight: 600; }
        code {
          font-family: \(codeFontFamily);
          font-size: 0.9em;
          padding: 0.15em 0.36em;
          border-radius: 4px;
          background: \(flat(codeBackground));
          color: \(flat(codeText));
        }
        pre {
          padding: 14px 16px;
          border-radius: 8px;
          overflow-x: auto;
          background: \(flat(codeBackground));
        }
        pre code {
          padding: 0;
          border-radius: 0;
          background: none;
          font-size: 0.88em;
          line-height: 1.6;
        }
        blockquote {
          margin-left: 0;
          padding: 0 0 0 1em;
          border-left: 4px solid \(flat(quoteBar));
          color: \(flat(quoteText));
        }
        blockquote > :last-child { margin-bottom: 0; }
        ul, ol { padding-left: 1.7em; }
        li > ul, li > ol { margin-top: 0.4em; }
        li.task { list-style: none; margin-left: -1.5em; }
        li.task input { margin-right: 0.45em; vertical-align: -0.1em; }
        hr {
          border: 0;
          border-top: 1px solid \(flat(rule));
          margin: 2.2em 0;
        }
        table {
          border-collapse: collapse;
          border-spacing: 0;
          display: block;
          width: max-content;
          max-width: 100%;
          overflow-x: auto;
        }
        th, td {
          border: 1px solid \(flat(tableBorder));
          padding: 7px 13px;
        }
        th { background: \(flat(tableHeaderBackground)); font-weight: 600; }
        img { max-width: 100%; height: auto; vertical-align: middle; }
        .raw-html {
          white-space: pre-wrap;
          font-family: \(codeFontFamily);
          font-size: 0.86em;
          padding: 10px 12px;
          border-radius: 6px;
          background: \(flat(codeBackground));
          color: \(flat(mutedText));
        }
        sup.footnote-ref { line-height: 0; }
        sup.footnote-ref a { text-decoration: none; }
        section.footnotes {
          margin-top: 3em;
          padding-top: 0.4em;
          border-top: 1px solid \(flat(rule));
          font-size: 0.92em;
        }
        section.footnotes ol { padding-left: 1.5em; }
        section.footnotes li { margin-bottom: 0.55em; }
        section.footnotes li:target {
          background: \(flat(footnoteFlash));
          border-radius: 4px;
        }
        a.footnote-backref { text-decoration: none; margin-left: 0.15em; }
        """
    }

    // MARK: 颜色换算

    /// 把颜色摊成一个 `#rrggbb`。
    ///
    /// 两步：① 动态色（`UIColor.label` 这类）先按当前外观解析成具体值；
    /// ② 带透明度的颜色（`inlineCodeBackground` 那种半透明的）按 alpha 叠到 `pageBackground` 上，得到网页用的实色。
    private func flat(_ color: UIColor) -> String {
        let resolved = color.resolvedColor(with: UITraitCollection.current)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1

        guard let deviceRGB = resolved.cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
              let components = deviceRGB.components,
              components.count >= 3 else { return "#000000" }

        red = components[0]
        green = components[1]
        blue = components[2]
        alpha = components.count > 3 ? components[3] : 1

        guard alpha < 1 else { return Self.hex(red: red, green: green, blue: blue) }

        let backdrop = pageBackground.resolvedColor(with: UITraitCollection.current)
        guard let paperRGB = backdrop.cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
              let paperComponents = paperRGB.components, paperComponents.count >= 3 else {
            return Self.hex(red: red, green: green, blue: blue)
        }
        // `结果 = 前景 × alpha + 背景 × (1 - alpha)` —— 半透明前景压到背景上的标准算法
        let mixed = (
            red: paperComponents[0] + (red - paperComponents[0]) * alpha,
            green: paperComponents[1] + (green - paperComponents[1]) * alpha,
            blue: paperComponents[2] + (blue - paperComponents[2]) * alpha
        )
        return Self.hex(red: mixed.red, green: mixed.green, blue: mixed.blue)
    }

    private static func hex(red: CGFloat, green: CGFloat, blue: CGFloat) -> String {
        let clamp = { (value: CGFloat) -> Int in
            Int(max(0, min(1, value) * 255).rounded())
        }
        return String(format: "#%02x%02x%02x", clamp(red), clamp(green), clamp(blue))
    }

    /// 用相对亮度粗略判断这套底色是深还是浅，只用来给 `:root { color-scheme }` 选一个值（告诉浏览器滚动条、表单控件该用深色还是浅色那一套）。
    private static func isDarkSplashkit(_ css: String) -> Bool {
        guard css.count == 7 else { return false }
        let red = Int(String(css.dropFirst().prefix(2)), radix: 16) ?? 255
        let green = Int(String(css.dropFirst(3).prefix(2)), radix: 16) ?? 255
        let blue = Int(String(css.dropFirst(5).prefix(2)), radix: 16) ?? 255
        let luma = 0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)
        return luma < 128
    }

    // MARK: 字体

    /// 系统的字体族名（`.AppleSystemUIFont` 这种塞进 CSS 只会得到宋体，得换成标准的字体栈）
    private static var systemBodyStack: String {
        "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", \"PingFang SC\", \"Microsoft YaHei\", sans-serif"
    }

    private static var systemCodeStack: String {
        "ui-monospace, SFMono-Regular, Menlo, Consolas, \"Liberation Mono\", monospace"
    }

    /// `UIFont.familyName` → CSS 字体栈。
    ///
    /// 系统给的 familyName 在 WebKit 里是废的（`.AppleSystemUIFont` 根本不是一个公开字体名），所以凡是系统自带的（名字以 `.` 开头，或者带 System / Helvetica Neue 这些）都换回字体栈，用户自己装的第三方字体（比如把正文字体设成了霞鹜文楷）才原样带过去。
    private static func cssFont(from familyName: String, fallback: String) -> String {
        let lower = familyName.lowercased()
        let isSystem = familyName.hasPrefix(".") || lower.contains("system") || lower.contains("helvetica") || lower.contains(".sfui")
        return isSystem ? fallback : "\"\(familyName)\", \(fallback)"
    }
}
