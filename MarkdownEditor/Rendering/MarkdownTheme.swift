//
//  MarkdownTheme.swift
//  MarkdownEditorHy4
//
//  样式表：所有渲染样式的唯一出处
//

import UIKit

/// 编辑器的样式表。
///
/// 改外观只需要动这里，渲染层不写死任何颜色 / 字号。
struct MarkdownTheme {
    // MARK: 字体

    /// 正文字体
    var bodyFont: UIFont
    /// 等宽字体（行内代码、代码块）
    var codeFont: UIFont
    /// 各级标题字体，key 是标题级别（1~6）
    var headingFonts: [Int: UIFont]

    // MARK: 颜色

    var textColor: UIColor
    /// 语法标记（`#`、`**`、`-`、`>` 这些）的弱化色
    var markerColor: UIColor
    /// **有序列表**的「数字 + 点」（`1.` / `10.`）专用颜色。
    ///
    /// 单独拎出来是因为它和 `#`、`- ` 这类标记虽然都是弱化色，但语义不一样：
    /// 有序列表的序号是正文要读的内容，经常想单独调（比如调成主色、或者跟正文同色），
    /// 不该跟着 `markerColor` 一起变。默认沿用和 `markerColor` 一样的浅灰。
    var orderedListMarkerColor: UIColor
    var linkColor: UIColor
    /// 行内代码**正文**（两个反引号中间那部分）的颜色
    var inlineCodeColor: UIColor
    /// 行内代码**两侧反引号**的颜色。
    ///
    /// 反引号属于「语法标记」，和 `#`、`- ` 一样只是提示「这里有个语法」，不该抢读者的注意力，所以单独给一个更淡的颜色。
    ///
    /// ⚠️ 不能图省事直接用 `markerColor`（0.9 的浅灰）：那个灰是给**白底**设计的，铺在行内代码那块灰底（≈0.94）上只差 5%，反引号会像凭空消失。这里用一个稍深一点的浅灰，压得住灰底、又明显比代码正文（0.28~0.51 的蓝灰）淡。
    var inlineCodeBacktickColor: UIColor
    /// 行内代码的底色。
    ///
    /// ⚠️ **必须半透明，不能填不透明的实色**（踩过坑，别改回 `alpha: 1.0`）：这个颜色是挂在 `NSAttributedString` 上的 `.backgroundColor`，**跟着文字一起画**，而系统的「选中高亮」（鼠标框选出来那块蓝底）画在它**下面**。底色一旦不透明，选中行内代码时蓝底就被灰块整块盖住 —— 看着像压根没选中。
    ///
    /// 半透明之后蓝底能透上来，而且这种做法**不挑分层顺序**：将来系统就算把高亮挪到上层也照样正常。当前这个值铺在白底上大约是 0.94 的浅灰，和不透明的 0.95 肉眼分不出差别，外观没变。
    var inlineCodeBackground: UIColor
    var codeBlockBackground: UIColor
    /// 引用块里**正文文字**的颜色（`>` 符号本身仍然是 `markerColor` 的灰色）。
    ///
    /// 默认和正文同色（下面的 `default` 里直接取 `textColor`），
    /// 想让引用内容看起来淡一点就把这里改成 `.secondaryLabel` 之类。
    var quoteTextColor: UIColor
    var bulletColor: UIColor
    var separatorColor: UIColor
    /// 查找命中的底色（「当前命中」之外的那些）
    ///
    /// 和项目里其它颜色一样，这里是唯一一处决定「命中给什么颜色」的地方，改这儿就够了。
    /// 和行内代码那个底色不同，这里**可以**用不透明实色：它是 `SearchHighlightLayer`
    /// 画在文字**下面**的一层，不像挂在文字上的 `.backgroundColor` 那样会盖住系统选中高亮。
    var searchMatchBackground: UIColor = UIColor.systemYellow.withAlphaComponent(0.55)
    /// 当前那一个命中的底色（比其它命中更重，好让用户看清「现在在第几个」）
    var searchCurrentMatchBackground: UIColor = UIColor.systemOrange.withAlphaComponent(0.85)

    // MARK: 尺寸

    /// 无序列表左侧圆点直径
    var bulletDiameter: CGFloat
    /// 每一级列表的缩进
    var listIndent: CGFloat
    /// 引用块的缩进
    var quoteIndent: CGFloat
    /// 段落之间的间距
    var paragraphSpacing: CGFloat
    /// 标题上方的额外间距
    var headingSpacing: CGFloat

    /// 行高倍数。
    ///
    /// ### 怎么理解这个数
    /// 字体自己带一个「自然行高」（body 字体大约 1.2 倍字号），这里给的是**再乘几倍**：
    /// - `1.0`（默认）：一行都不多，完全用字体自带的自然行高 —— 也就是和没有这一项时一模一样；
    /// - `1.5`：行与行之间比自然值再多出 50%，读起来更松。
    ///
    /// 小于等于 1 的时候**不往段落样式里写**（`NSParagraphStyle.lineHeightMultiple`
    /// 默认是 0，0 和 1 都是「照自然行高来」）。不写的好处是默认状态下排版结果
    /// 和以前逐点一致，不会因为多挂一个属性而出现亚像素级的行高变化。
    var lineHeightMultiple: CGFloat = 1.0

    /// 正文段落**首行**额外缩进多少点（换行后的第二行不缩）。
    ///
    /// ### 为什么只给正文段落用
    /// 标题、列表项、代码块、图片/表格这些整块内容的首行本来就有标记、序号或者
    /// 就是一整张图，再往里缩会歪掉。所以这个值只在渲染普通段落时才用得上，
    /// 具体在 `MarkupToAttributedRenderer.visitParagraph` 里决定给不给。
    ///
    /// 中文排版的习惯是首行缩进两个汉字宽 —— 那是 `bodyFont.pointSize × 2`，
    /// App 层的设置页就是按「几个字」让用户选的（见 `MarkdownEditorSettings.applyTypography`）。
    var paragraphIndent: CGFloat = 0
    /// 代码块矩形背景的圆角
    var codeBlockCornerRadius: CGFloat
    /// 代码块矩形比文字上下各多出来的留白
    var codeBlockVerticalPadding: CGFloat
    /// 代码文字相对矩形左边的缩进
    var codeBlockTextInset: CGFloat
    /// 引用块左侧绿条的颜色
    var quoteBarColor: UIColor
    /// 引用块左侧绿条的宽度（相当于 CSS 里的 border-left-width）
    var quoteBarWidth: CGFloat
    /// 折叠按钮（小三角）的边长，同时也是点击热区大小
    var foldButtonSide: CGFloat
    /// 折叠按钮和正文之间的间距
    var foldButtonGap: CGFloat
    /// 正文左边专门留给折叠三角的「装订线」宽度。
    ///
    /// 三角浮在这条带子里，不占正文的字符位，多行文字的左边缘才对得齐。
    /// 这个值会额外加到 `UITextView.textContainerInset.left` 上。
    var foldGutterWidth: CGFloat
    /// 折叠后那个「⋯」占位的宽度。
    ///
    /// ⚠️ **一个数管两处**：文本流按这条宽度留空档，浮层上那个圆角按钮也按这条宽度画 —— 两边同一个数，按钮才正好盖在空档上，既不会压住标题文字、右边也不会多一块空白。
    var collapsedPlaceholderWidth: CGFloat
    /// 折叠后那个「⋯」的颜色（同时当按钮的描边色和文字色用）
    var collapsedPlaceholderColor: UIColor
    /// 折叠后那个「⋯」按钮的**高度**，固定值、不跟字号走。
    ///
    /// ⚠️ 为什么不跟字号：行高是随字号变的，按钮要是跟着变，用户在设置页拖字号时 这个「控件」会忽大忽小，看着就不像个按钮了。宽度不用另给一个数 —— 就是 `collapsedPlaceholderWidth`。
    var collapsedButtonHeight: CGFloat = 20

    // MARK: 行号（开关在 App 层的设置里，这里只管「画出来长什么样」）

    /// 左边行号装订线的宽度（只有「显示行号」打开时才占这块地方）。
    ///
    /// 和折叠三角那条装订线（`foldGutterWidth`）是同一个套路：这个宽度会被加进
    /// `textContainerInset.left`，所以行号**不占正文的字符位** —— 正文左边缘仍然是
    /// 整齐的一条线，行号画在它左边的带子里。
    var lineNumberGutterWidth: CGFloat = 46
    /// 行号的颜色。默认用系统的三级标签色（浅灰），浅色/深色模式下都看得清又不抢眼
    var lineNumberColor: UIColor = .tertiaryLabel
    /// 行号右边缘和正文（严格说是和折叠三角那条带子）之间留的空
    var lineNumberTrailingGap: CGFloat = 10
    /// 行号的字体：比正文小 2 号的**等宽数字**。
    ///
    /// ### 为什么必须是等宽数字
    /// 行号是竖着排成一列的，数字不等宽的话「1」和「8」的宽度不一样，
    /// 一列号码会左右参差。等宽数字让每个字符占一样的宽，右对齐时才是一条直线。
    ///
    /// ### 为什么是计算属性而不是存一个 `UIFont`
    /// 字号是从 `bodyFont` **派生**出来的，用户在设置页拖正文字号时要跟着变。
    /// 存一份就得在 `applyBodyFontSize` 里同步一份，漏一处就会「字号变了行号没变」。
    var lineNumberFont: UIFont {
        UIFont.monospacedDigitSystemFont(ofSize: max(9, bodyFont.pointSize - 2), weight: .regular)
    }

    /// 是否显示「源码提示」：图片下面那行 `![alt](url)`、圆点后面的 `- `
    var showsSourceHints: Bool = true
    /// 代码块的 **``` 围栏行**（第一行 ```lang 和最后一行 ```）要不要跟着正文一起铺淡灰背景。
    ///
    /// - `false`（默认）：只有代码正文有背景，围栏行留白，看起来是「一段被高亮的代码」；
    /// - `true`：首尾围栏也罩进背景，整块糊成一个灰方块。
    ///
    /// 想切换效果只改这一个值即可，详见 `MarkdownTextView.computeCodeBlockFrames`。
    var showsCodeBlockFenceBackground: Bool = false

    /// 代码块要不要做**语法高亮**。
    ///
    /// - `true`（默认）：受支持的语言（C / C++ / Objective-C / Java / C# / Kotlin / Go / Rust / Swift / JavaScript / TypeScript / Python / Ruby / PHP / Shell / SQL / JSON）按 `syntaxColors` 上色；
    /// - `false`：整块用代码块默认色，和没做高亮时一模一样。
    ///
    /// ⚠️ 这是渲染期读的开关，改完要**重新渲染**（`setMarkdown`）才生效
    /// —— 颜色是烙进 `NSAttributedString` 里的，不像背景矩形那样每帧读主题。
    var enablesCodeHighlighting: Bool = true

    /// 代码高亮里各个语法角色的颜色，见 `CodeSyntaxColors`
    var syntaxColors = CodeSyntaxColors()

    /// 表格的样式（表头底色、边框、单元格内边距…）
    ///
    /// ### 为什么叫 `TableStyle` 而不是 `Table`
    /// `Markdown` 模块里已经有一个 `Table`（swift-markdown 的表格 AST 节点），
    /// 同名会让代码里到处要写 `Markdown.Table`，容易看错。
    var table = TableStyle()

    /// 图片的显示尺寸（最大宽、最大高），见 `ImageStyle`
    var image = ImageStyle()

    /// **中文的仿斜体倾斜量**（字体的仿斜矩阵系数，0.2 ≈ 11°，0 = 关闭）。
    ///
    /// ### 为什么需要这一项
    /// 系统给中文回退的字体（苹方 PingFang）**没有斜体字形** —— `*斜体*` 的
    /// 字体特征（italic trait）对汉字完全不生效，用户看起来就是「斜体没支持」。
    /// 所以对中文要用「把字形手动掰歪」的仿斜矩阵补出来（实现见
    /// `MarkupToAttributedRenderer.applySyntheticItalicToCJK`）。
    ///
    /// ### 为什么不能用 `.obliqueness` 属性
    /// 那是 TextKit 1 的属性，TextKit 2 排版时直接忽略（实测属性挂上了、画面不动）。
    ///
    /// 英文不在这里处理：英文字体有真斜体，走 `visitEmphasis` 的字体特征就够了，
    /// 再叠仿斜矩阵会歪过头。
    var cjkItalicSlant: CGFloat = 0.2

    /// 任务列表（`- [x] xxx`）的样式
    var taskList = TaskListStyle()

    /// 数学公式（`$...$` / `$$...$$`）的样式，见 `MathStyle`
    var math = MathStyle()

    // MARK: 默认样式

    static var `default`: MarkdownTheme {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let code = UIFont.monospacedSystemFont(ofSize: body.pointSize - 1, weight: .regular)

        // 正文色先算出来，下面引用正文色要直接复用它（默认「引用文字和正文一样黑」）
        let text = UIColor(red: 0.27, green: 0.27, blue: 0.28, alpha: 1.00)
        // 语法标记的弱化灰，有序列表序号默认也用它（想单独调改 `orderedListMarkerColor`）
        let marker = UIColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.00)

        return MarkdownTheme(
            bodyFont: body,
            codeFont: code,
            headingFonts: Self.makeHeadingFonts(baseSize: body.pointSize),
            textColor: text,
            markerColor: marker,
            orderedListMarkerColor: UIColor(red: 0.26, green: 0.72, blue: 0.51, alpha: 1.00),
            linkColor: UIColor(red: 0.16, green: 0.59, blue: 0.39, alpha: 1.00), //#42b883
            inlineCodeColor: UIColor(red: 0.28, green: 0.40, blue: 0.51, alpha: 1.00),
            inlineCodeBacktickColor: UIColor(white: 0.68, alpha: 1.00),
            // 12% 的中灰：铺在白底上 ≈ 0.94 的浅灰（和以前的不透明 0.95 看不出差别），
            // 铺在深色底上则是一点淡淡的提亮，两头都能用
            inlineCodeBackground: UIColor(white: 0.5, alpha: 0.12),
            codeBlockBackground: UIColor(red: 0.95, green: 0.96, blue: 0.96, alpha: 1.00),
            quoteTextColor: text,
            bulletColor: UIColor(red: 0.26, green: 0.72, blue: 0.51, alpha: 1.00),
            separatorColor: .separator,
            bulletDiameter: 12,
            listIndent: 22,
            quoteIndent: 16,
            paragraphSpacing: 12,
            headingSpacing: 14,
            codeBlockCornerRadius: 8,
            codeBlockVerticalPadding: 6,
            codeBlockTextInset: 10,
            quoteBarColor: UIColor(red: 0.20, green: 0.63, blue: 0.44, alpha: 1.00),
            quoteBarWidth: 5,
            foldButtonSide: 20,
            foldButtonGap: 2,
            foldGutterWidth: 22,
            // 32 × 20：宽比高大约 3:2，'⋯' 摆在正中间才像个按钮（宽高一样就成了圆形）
            collapsedPlaceholderWidth: 32,
            collapsedPlaceholderColor: .tertiaryLabel
        )
    }

    /// 生成 1~6 级标题字体：级别越高字越大，统一加粗
    static func makeHeadingFonts(baseSize: CGFloat) -> [Int: UIFont] {
        // 依次是 H1 ~ H6 的字号增量（15/8/5/2/0/-1）：H1 比正文大 15 点最显眼，往后逐级收敛，到 H6 已经比正文小 1 点
        let deltas: [CGFloat] = [15, 8, 5, 2, 0, -1]
        var result: [Int: UIFont] = [:]
        for (index, delta) in deltas.enumerated() {
            let level = index + 1
            result[level] = UIFont.boldSystemFont(ofSize: baseSize + delta)
        }
        return result
    }

    /// 换一个正文字号，并把跟着它派生出来的字体一起换掉。
    ///
    /// ### 为什么必须整组换
    /// 主题里只有「正文字号」这一个源头：等宽字体取 `正文 - 1`，各级标题取 `正文 + 15/8/5/2/0/-1`。
    /// 设置页上用户拖的是正文字号，要是这里只改 `bodyFont`，标题就会留在原来的大小上 —— 字号调大以后正文比 H2 还大。
    ///
    /// ### 说明一下和「动态字体」的关系
    /// 这是**用户手动指定**的字号，用的是 `systemFont(ofSize:)` 而不是
    /// `preferredFont(forTextStyle:)`，所以系统的「文字大小」设置不再作用于正文
    /// （用户既然自己拖了滑块，就该听滑块的）。默认值是从主题原来的字号取的，
    /// 所以没动过设置的人看到的大小和以前完全一样。
    mutating func applyBodyFontSize(_ size: CGFloat) {
        bodyFont = UIFont.systemFont(ofSize: size)
        codeFont = UIFont.monospacedSystemFont(ofSize: max(9, size - 1), weight: .regular)
        headingFonts = Self.makeHeadingFonts(baseSize: size)
    }

    // MARK: 派生的属性字典

    /// 正文属性（不含段落样式，段落样式由块级节点统一设置）
    func bodyAttributes(font: UIFont? = nil, color: UIColor? = nil) -> [NSAttributedString.Key: Any] {
        [.font: font ?? bodyFont, .foregroundColor: color ?? textColor]
    }

    /// 语法标记的弱化属性
    var markerAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: markerColor]
    }

    /// 行内代码**正文**（反引号中间那部分）
    var inlineCodeAttributes: [NSAttributedString.Key: Any] {
        [.font: codeFont,
         .foregroundColor: inlineCodeColor,
         .backgroundColor: inlineCodeBackground]
    }

    /// 行内代码两侧的**反引号**。
    ///
    /// 和正文只差一个前景色：字体仍是等宽体（换成正文字体会让反引号宽度跳一下、灰底一头宽一头窄），底色也照旧留着（这样整段行内代码还是一块完整的灰底，而不是中间断成三截）。
    var inlineCodeBacktickAttributes: [NSAttributedString.Key: Any] {
        [.font: codeFont,
         .foregroundColor: inlineCodeBacktickColor,
         .backgroundColor: inlineCodeBackground]
    }

    /// 代码块正文。
    ///
    /// 注意这里**没有** backgroundColor —— 整块的背景是由 `MarkdownTextView` 画的一个
    /// 圆角矩形（`codeBlockBackground`），逐字符加背景会变成一条条的色带，块与块之间还断开。
    var codeBlockAttributes: [NSAttributedString.Key: Any] {
        [.font: codeFont,
         .foregroundColor: textColor]
    }

    /// 链接正文
    var linkAttributes: [NSAttributedString.Key: Any] {
        [.foregroundColor: linkColor]
    }

    /// 有序列表的序号（`1.` / `10.`）属性。
    ///
    /// 颜色走单独的 `orderedListMarkerColor`，不受 `markerColor` 影响。
    var listMarkerAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: orderedListMarkerColor]
    }

    /// 表格下方那几行**表格源码**的样式：等宽字体 + 浅灰。
    ///
    /// 表格本体已经画成一张图了，源码留在这里只是为了「所见即所编辑」
    /// （光标能停进去改），所以颜色压到很淡，不抢视觉焦点。
    var tableSourceAttributes: [NSAttributedString.Key: Any] {
        [.font: codeFont, .foregroundColor: table.sourceTextColor]
    }

    // MARK: 段落样式

    /// 把「行高倍数」写进段落样式。
    ///
    /// ⚠️ 只有大于 1 才写：`NSParagraphStyle.lineHeightMultiple` 默认是 0，
    /// 而 0 和 1 是同一个意思（照字体的自然行高来）。默认状态下干脆不碰这个属性，
    /// 免得「什么都没调」的时候行高却和以前差一丝。
    ///
    /// 不是 private：列表项的段落样式在 `MarkupToAttributedRenderer` 那个文件里，
    /// 跨文件拿不到 private 成员。
    func applyLineHeight(to style: NSMutableParagraphStyle) {
        guard lineHeightMultiple > 1 else { return }
        style.lineHeightMultiple = lineHeightMultiple
    }

    /// 普通段落。
    /// - parameter firstLineIndentExtra: 首行比其余行多缩进多少点（段落首行缩进）。
    ///   只有正文段落才传非 0 —— 见 `paragraphIndent` 的说明
    func paragraphStyle(indent: CGFloat,
                        extraSpacingBefore: CGFloat = 0,
                        firstLineIndentExtra: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = indent
        style.firstLineHeadIndent = indent + firstLineIndentExtra
        style.paragraphSpacingBefore = extraSpacingBefore
        style.paragraphSpacing = paragraphSpacing
        applyLineHeight(to: style)
        return style
    }

    /// 标题段落
    func headingParagraphStyle(indent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        style.paragraphSpacingBefore = headingSpacing
        style.paragraphSpacing = paragraphSpacing
        applyLineHeight(to: style)
        return style
    }

    /// 代码块**正文**段落：文字相对背景矩形往里缩一点，右边也留出对称的间距
    func codeParagraphStyle(indent: CGFloat) -> NSParagraphStyle {
        codeStyle(indent: indent, minimumSpacing: 0)
    }

    /// 代码块**首尾围栏行**（` ```swift ` 和 ` ``` `）段落：和正文那套只差一点 —— 段前/段后间距有个下限，至少留出 `codeBlockVerticalPadding`。
    ///
    /// ### 为什么围栏行要单独一套
    /// 灰底矩形是按「代码正文的排版盒 ± padding」算的，而那个 padding 其实**借**了围栏行自己的段间距：段距默认 12 正好是 padding × 2（纯属巧合），灰底上下各空 18pt，看着很正常；用户一旦把段距调小，这点空隙跟着缩水，灰底就会**切进正文**—— 段距调到 0 时最后一个 `}` 的底部戳出灰底 6pt，正好是灰底高度的 10%。
    /// 给围栏行兜一个下限之后，这段空隙从「用户调多少就是多少」变成「结构上必然够」，灰底也就**不需要再算**「要不要躲开围栏行」了。
    func codeFenceParagraphStyle(indent: CGFloat) -> NSParagraphStyle {
        codeStyle(indent: indent, minimumSpacing: codeBlockVerticalPadding)
    }

    /// 代码块段落样式的公共部分。
    /// - parameter minimumSpacing: 段前/段后间距的**下限**，用户调的段距比它大就听用户的
    private func codeStyle(indent: CGFloat, minimumSpacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = indent + codeBlockTextInset
        style.firstLineHeadIndent = indent + codeBlockTextInset
        style.tailIndent = -codeBlockTextInset
        style.paragraphSpacingBefore = max(paragraphSpacing, minimumSpacing)
        style.paragraphSpacing = max(paragraphSpacing, minimumSpacing)
        applyLineHeight(to: style)
        return style
    }

    /// 图片 / 分隔线独占一行的段落样式。
    ///
    /// 这里**故意不套行高倍数**：这一段的「内容」是一张图或一条线，
    /// 把字号那套行高乘上去只会给图片上下平白多垫空白，跟用户调「行高」的本意对不上。
    func blockAttachmentParagraphStyle(indent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        style.paragraphSpacingBefore = paragraphSpacing
        style.paragraphSpacing = paragraphSpacing + 4
        return style
    }

    /// 块级公式（`$$...$$`）的段落样式：**居中**，上下各留一点呼吸。
    ///
    /// ### 为什么不能直接用上面那个 `blockAttachmentParagraphStyle`
    /// 图片是「铺在正文里的一块」，跟着缩进左对齐；公式块是「单独列出的一个式子」，
    /// 课本里那套排版惯例是居中。另外它的高度可能比一行正文高不少，
    /// 段前段后各留一点才不会顶着上下的段落。
    func mathBlockParagraphStyle(indent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        style.paragraphSpacingBefore = math.blockSpacingBefore
        style.paragraphSpacing = math.blockSpacingAfter
        return style
    }
}

// MARK: - 图片样式

extension MarkdownTheme {
    /// 图片的显示尺寸。
    ///
    /// ### 三个值各自管什么
    /// - `maxWidthRatio` / `maxWidthPoints`：最大宽度**二选一**（前者非 nil 就用前者）；
    /// - `maxHeight`：最大高度（点），一张图再高也不超过它。
    ///
    /// ### 为什么「宽度」做成两种模式而「高度」只有一个点数
    /// 宽度是用户最想自己定的（「图别超过半屏」/「就 200px」两种诉求都很常见），
    /// 所以给百分比和固定点数两个选择；高度只是防「一张长图撑爆屏幕」的兜底，
    /// 一个固定点数就够了。
    ///
    /// ⚠️ 高度**别再改成「窗口高度的百分之几」** —— 试过一版，代价是渲染层要多收一个
    /// `containerHeight`、编辑器要多记一个 `renderedHeight`，窗口一拉高拉矮整篇文档
    /// 就重排一次；而换来的收益（窗口特别高时图能大一点点）几乎没人会注意到。
    ///
    /// ### 这三个都是「上限」，不拉大小图
    /// 小图（比如 10×10）永远按原尺寸显示，不会被撑大。
    /// 放大只会让小图变糊，用户粘贴一个图标却看到马赛克是最糟的体验。
    struct ImageStyle {
        /// 最大宽度 = 容器可用宽度 × 这个比例。`nil` 表示改用下面的固定点数。
        ///
        /// 默认 `0.5`：图片最多占编辑器宽度的一半，正文不会被一张图打断节奏。
        var maxWidthRatio: CGFloat? = 0.5

        /// 最大宽度（点）。只在 `maxWidthRatio == nil` 时生效。默认 `200`。
        var maxWidthPoints: CGFloat = 200

        /// 最大高度（点），默认 `420`。只防「一张长图撑爆屏幕」，正常大小的图碰不到它。
        var maxHeight: CGFloat = 420
    }
}

// MARK: - 公式样式

extension MarkdownTheme {
    /// 数学公式的样式。
    ///
    /// 这里只管「公式本身的排版参数」（多大、多宽、留多少空），**不管公式长什么样** ——
    /// 那件事由注入进来的 `MarkdownMathRenderer` 决定。
    struct MathStyle {
        /// 行内公式的字号 = 正文字号 × 这个倍率。
        ///
        /// 默认 `1.0`：行内公式应该和周围文字一般大，大了会把行高撑开、
        /// 小了看着像下标。
        var inlineFontScale: CGFloat = 1.0

        /// 块级公式的字号 = 正文字号 × 这个倍率。
        ///
        /// 默认 `1.15`：单独列出的式子比正文略大一号，才像「被列出来重点强调的东西」，
        /// 这也是 LaTeX 里 display style 的默认观感。
        var blockFontScale: CGFloat = 1.15

        /// 块级公式最多占容器宽度的比例，默认 `0.9`。
        ///
        /// 留一点边距：一条刚好撑满宽度的式子看着像要溢出屏幕，
        /// 两边各让出 5% 会明显舒服些。超宽的式子会**等比缩小**（不会换行、也不会拉糊）。
        var maxWidthRatio: CGFloat = 0.9

        /// 块级公式上方的留白（点），默认 `12`（和正文的段落间距一致）
        var blockSpacingBefore: CGFloat = 12

        /// 块级公式下方的留白（点），默认 `12`
        var blockSpacingAfter: CGFloat = 12
    }
}

// MARK: - 代码高亮配色

extension MarkdownTheme {
    /// 代码高亮里各个「语法角色」对应的颜色。
    ///
    /// ### 这张表是整个高亮功能里唯一决定颜色的地方
    /// 高亮器（`SimpleCodeHighlighter`）只回答「这段字符是关键字 / 字符串 / 注释…」，
    /// 上色在渲染器里查这张表完成。所以以后换成 tree-sitter 那种精确解析器也好、
    /// 换成别的第三方库也好，**配色风格不会跟着变**，变的只是判定准确度。
    struct CodeSyntaxColors {
        /// 关键字（`func` / `def` / `const` …）—— 紫
        var keyword: UIColor = UIColor(red: 0.63, green: 0.13, blue: 0.60, alpha: 1.00)
        /// 字符串字面量 —— 红
        var string: UIColor = UIColor(red: 0.76, green: 0.13, blue: 0.24, alpha: 1.00)
        /// 注释 —— 灰绿
        var comment: UIColor = UIColor(red: 0.42, green: 0.45, blue: 0.50, alpha: 1.00)
        /// 数字、以及 `true` / `false` / `nil` / `None` 这类字面量常量 —— 蓝
        var number: UIColor = UIColor(red: 0.14, green: 0.36, blue: 0.72, alpha: 1.00)
        /// 类型名（大写开头的标识符，启发式判定）—— 青
        var type: UIColor = UIColor(red: 0.08, green: 0.47, blue: 0.47, alpha: 1.00)
    }

    /// 某个语法角色用什么颜色。
    ///
    /// 标识符和没归类的字符不给专门的色 —— 直接用代码块正文色（`textColor`），
    /// 这样换主题时它们会自动跟着正文走，不用再配一份「高亮黑色」。
    func color(for role: SyntaxRole) -> UIColor {
        switch role {
        case .keyword: return syntaxColors.keyword
        case .string: return syntaxColors.string
        case .comment: return syntaxColors.comment
        case .number: return syntaxColors.number
        case .type: return syntaxColors.type
        case .identifier, .plain: return textColor
        }
    }
}

// MARK: - 表格样式

extension MarkdownTheme {
    /// 表格的绘制参数。
    ///
    /// 表格是**自绘成一张图片**再当 attachment 塞进文本流的（原因见 `MarkdownTableView`），
    /// 所以颜色、边距这些只能在绘制时读，套不到 UIKit 的 view 层级上去。
    struct TableStyle {
        /// 表头行的底色
        var headerBackground: UIColor = UIColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1.00)
        /// 表格线和外框的颜色
        var borderColor: UIColor = .separator
        /// 表格线宽度（1 就是一条细线）
        var borderWidth: CGFloat = 1
        /// 单元格文字到左右边框的距离
        var cellPaddingHorizontal: CGFloat = 12
        /// 单元格文字到上下边框的距离
        var cellPaddingVertical: CGFloat = 8
        /// 一列最窄多少（内容再短也不再压缩）
        var minColumnWidth: CGFloat = 64
        /// 一列最宽多少（防止某一列内容特别长，把别的列挤没了）
        var maxColumnWidth: CGFloat = 280
        /// 表格外框圆角
        var cornerRadius: CGFloat = 8
        /// 表格源码文字的颜色（浅灰）
        var sourceTextColor: UIColor = .tertiaryLabel
    }

    /// 任务列表复选框的样式。
    ///
    /// 复选框是**真正的 UIButton**（叠在文本上的原生控件），不是画进文本流的图片，
    /// 所以尺寸、颜色这些是 UIKit 原生的属性，不是绘制参数。
    struct TaskListStyle {
        /// 复选框边长（同时也是点击热区大小）
        var checkboxSide: CGFloat = 16
        /// 复选框左右两侧的间距（只在「不遮盖」模式下生效）。
        ///
        /// 渲染层按 `checkboxSide + checkboxGap × 2` 留出座位，按钮居中摆在座位里，所以这个值决定的是「按钮离左边的 `-` 和右边的 `[x]` 各有多远」。
        var checkboxGap: CGFloat = 3
        /// 勾选后的填充色
        var checkedColor: UIColor = .systemGreen
        /// 未勾选时的边框色
        var uncheckedBorderColor: UIColor = .separator
        /// 未勾选时的底色。
        ///
        /// 「不遮盖」模式下用透明（复选框就浮在源码旁边，不该挖个洞）；
        /// 「遮盖」模式下必须是**不透明**的，否则底下的 `[x]` 会透出来。
        var uncheckedFillColor: UIColor = .clear
        /// 勾选后那个对勾的颜色
        var checkmarkColor: UIColor = .white
        /// 边框粗细
        var borderWidth: CGFloat = 1.5
        /// 圆角
        var cornerRadius: CGFloat = 4

        /// **复选框要不要盖住 `[x]` / `[ ]` 这三个字符**。
        ///
        /// - `false`（默认）：**不盖**。渲染层会在 `- ` 和 `[x]` 中间留出一块「座位」（透明占位 attachment），复选框就摆在座位正中 —— 看到的顺序是 `-`（浅灰）→ 复选框 → `[ ]`/`[x]`（浅灰）→ 正文，两边的源码都看得见；任务项也因此不再画圆点（标记换成了浅灰的 `-`）。
        /// - `true`：复选框正好盖在 `[x]` 上，源码字符仍然在文本里（复制、编辑都不受影响），只是视觉上被挡住 —— Bear / Obsidian 的常见样子。
        ///
        /// ⚠️ 这个开关会**改变渲染出来的文本流**（要不要插座位），所以它是渲染期读的，切换后要整篇重渲染才生效。详见 `MarkupToAttributedRenderer.appendTaskListMarker` 与 `MarkdownTextView.positionCheckboxes()`。
        var coversCheckboxLiteral: Bool = false
    }
}

// MARK: - UIFont 的字形变体（粗体 / 斜体）

extension UIFont {
    /// 在现有字体基础上叠加一个字形特征（粗体、斜体…），并保留原有特征。
    /// - parameter trait: 要叠加的特征，比如 `.traitBold`、`.traitItalic`
    func adding(_ trait: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let merged = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(trait))
        return UIFont(descriptor: merged ?? fontDescriptor, size: pointSize)
    }

    /// 在现有字体基础上加一个「手动掰歪」的仿斜矩阵，做出假斜体效果。
    ///
    /// 矩阵里的 `c` 就是倾斜系数：x' = x + c·y，y 越大（字形越靠上的部分）往右挪得越多，
    /// 看起来就是往右倒 —— 和斜体的样子一致。
    /// 给中文用的（中文回退字体没有真斜体），见 `MarkdownTheme.cjkItalicSlant`。
    ///
    /// ### 两个坑（都实测踩过，别改回去）
    /// 1. `UIFontDescriptor.withMatrix(_:)` 在 Mac Catalyst 上不可用（编译期报错）；
    /// 2. 不能只用 `.name: fontName` 重建描述符 —— 系统字体叫 `.SFNS-…` 这种点开头
    ///    的内部名，按名字重建会**找不到字体**，悄悄回退成 Times。
    ///    正确做法：把原描述符的**全部属性**抄下来、只追加矩阵，再重建。
    func withSlant(_ slant: CGFloat) -> UIFont {
        var attributes = fontDescriptor.fontAttributes
        attributes[.matrix] = NSValue(cgAffineTransform:
            CGAffineTransform(a: 1, b: 0, c: slant, d: 1, tx: 0, ty: 0))
        return UIFont(descriptor: UIFontDescriptor(fontAttributes: attributes), size: pointSize)
    }
}
