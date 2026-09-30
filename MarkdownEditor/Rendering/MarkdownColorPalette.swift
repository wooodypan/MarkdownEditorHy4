//
//  MarkdownColorPalette.swift
//  MarkdownEditorHy4
//
//  配色表：一份「只管颜色、别的都不管」的覆盖表。
//
//  ### 它解决的是什么问题
//  主题（`MarkdownTheme`）里既有颜色，也有字号、间距这些排版参数。
//  换配色的时候只想换颜色 —— 字号、行高、段间距是用户在设置页一格一格调出来的，
//  换主题不该把它们一起冲掉。所以颜色单独抽出一张表：套配色 = 只改颜色那几个字段。
//
//  ### 三个来源，优先级从低到高
//  1. `MarkdownTheme` 自带的默认色（写在 `MarkdownTheme.default` 里）；
//  2. 内置预设（`vue` / `vueDark`）—— 只覆盖自己给了的那些色；
//  3. 用户指定的 JSON 文件 —— 再覆盖一次，同样只覆盖给了的色。
//
//  每一层都是「给了才覆盖」，没给的自动落到下一层，
//  所以「默认」这套预设就是一张**空表**：什么都不覆盖，直接用 `MarkdownTheme` 自带的颜色。
//

import UIKit

/// 一个十六进制颜色，比如 `#42b983`。
///
/// ### 为什么颜色在文件里是字符串
/// 配色要能存进 JSON（用户可以自己写一份、或者从别处拿一份来用），
/// 而 `UIColor` 本身不能直接被 `Codable` 编解码 —— 所以存字符串，用的时候再转成 `UIColor`。
struct MarkdownHexColor: Codable, Equatable {

    /// 形如 `#42b983`（不透明）或 `#42b983cc`（后两位是透明度）的字符串。
    ///
    /// 写错了不会崩，也不会把界面涂成一片黑 —— `color` 会返回 `nil`，
    /// 调用方跳过这一项，那个位置继续用主题自带的颜色。
    var hex: String

    init(_ hex: String) {
        self.hex = hex
    }

    /// 转成 `UIColor`。字符串不合法时返回 `nil`（调用方会跳过这一项）
    var color: UIColor? {
        Self.parse(hex)
    }

    /// 解析十六进制颜色：认 `#f0a` / `#ff00aa` / `#ff00aacc` 三种写法，`#` 前缀和大小写都不挑。
    ///
    /// 8 位写法里最后两位是**透明度**（`cc` ≈ 80%）：底色这类颜色必须能带透明度，
    /// 详见 `MarkdownTheme.inlineCodeBackground` 那条说明（不透明会盖住系统的选中高亮）。
    static func parse(_ text: String) -> UIColor? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("#") { body.removeFirst() }
        // 3 位简写（#f0a）先展开成 6 位（#ff00aa），后面就只需要处理 6 / 8 两种长度
        if body.count == 3 {
            body = body.map { "\($0)\($0)" }.joined()
        }
        guard body.count == 6 || body.count == 8 else { return nil }
        guard let value = UInt64(body, radix: 16) else { return nil }

        let unit: CGFloat = 255
        let shiftForRed = body.count == 8 ? 24 : 16
        let red = CGFloat((value >> shiftForRed) & 0xFF) / unit
        let green = CGFloat((value >> (shiftForRed - 8)) & 0xFF) / unit
        let blue = CGFloat((value >> (shiftForRed - 16)) & 0xFF) / unit
        let alpha = body.count == 8 ? CGFloat(value & 0xFF) / unit : 1
        return UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

// MARK: - 编解码

extension MarkdownHexColor {

    /// JSON 里长什么样：一个普通的字符串，比如 `{"link": "#ff0000"}`。
    ///
    /// ### 为什么不默认用 `{"link": {"hex": "#ff0000"}}` 那种带键名的写法
    /// 手写主题文件的时候，键里套一层对象纯属多余的括号 —— 颜色天生就是一个字符串。
    /// 下面同时认两种写法（先试字符串、再试 `{"hex": ...}`），
    /// 是为了迁就那些按默认的 Codable 结构已经写好的文件。
    private enum CodingKeys: String, CodingKey {
        case hex
    }

    init(from decoder: any Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            hex = text
            return
        }
        hex = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .hex)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// 让颜色可以直接写成 `"#42b983"` 这样的字面量。
///
/// 纯为了写着顺手：`MarkdownColorPalette(text: "#34495e")` 比
/// `MarkdownColorPalette(text: MarkdownHexColor("#34495e"))` 好读太多。
/// 编解码不受影响 —— 存进 JSON 时仍然是 `{"hex": "#34495e"}` 这样带键名的对象。
extension MarkdownHexColor: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self.init(value)
    }
}

/// 一套配色（覆盖表）。
///
/// ### 字段为什么全是可选的
/// 因为它是「覆盖」而不是「完整定义」：`nil` = 这一色不覆盖，继续用下一层的颜色。
/// 这样用户写的 JSON 可以只写「我想把链接换成红色」一条，其余照旧 ——
/// 不用被迫把整套二十多个颜色全抄一遍。
struct MarkdownColorPalette: Codable, Equatable {

    // MARK: 编辑区

    /// 编辑区的底色（文字铺在上面）。深色主题全靠这一项把整片背景压下来
    var editorBackground: MarkdownHexColor? = nil
    /// 正文文字
    var text: MarkdownHexColor? = nil
    /// 语法标记（`#`、`-`、`>` 这些）的弱化色
    var marker: MarkdownHexColor? = nil
    /// 有序列表的序号（`1.` / `10.`）。它是正文要读的内容，刻意和 `marker` 分开
    var orderedListMarker: MarkdownHexColor? = nil
    /// 链接
    var link: MarkdownHexColor? = nil
    /// 行内代码**正文**（两个反引号中间那部分）
    var inlineCode: MarkdownHexColor? = nil
    /// 行内代码两侧的**反引号**
    var inlineCodeBacktick: MarkdownHexColor? = nil
    /// 行内代码的底色。
    ///
    /// ⚠️ 必须半透明（8 位写法，比如 `#00000008`）：它是挂在文字上的 `.backgroundColor`，
    /// 和系统画在文字下面的「选中高亮」打架 —— 不透明的话框选行内代码会像没选中
    var inlineCodeBackground: MarkdownHexColor? = nil
    /// 代码块整块的背景（渲染层画的是一个圆角矩形，用的就是这个色）
    var codeBlockBackground: MarkdownHexColor? = nil
    /// 引用块里的正文文字
    var quoteText: MarkdownHexColor? = nil
    /// 引用块左侧那条竖条
    var quoteBar: MarkdownHexColor? = nil
    /// 无序列表的圆点
    var bullet: MarkdownHexColor? = nil
    /// 分隔线
    var separator: MarkdownHexColor? = nil
    /// 查找命中的底色
    var searchMatchBackground: MarkdownHexColor? = nil
    /// 查找「当前那一个命中」的底色（比其它命中更重）
    var searchCurrentMatchBackground: MarkdownHexColor? = nil
    /// 左边行号的颜色
    var lineNumber: MarkdownHexColor? = nil
    /// 折叠之后那个「⋯」的颜色
    var collapsedPlaceholder: MarkdownHexColor? = nil

    // MARK: 代码高亮（五个语法角色，见 `MarkdownTheme.CodeSyntaxColors`）

    var keyword: MarkdownHexColor? = nil
    var string: MarkdownHexColor? = nil
    var comment: MarkdownHexColor? = nil
    var number: MarkdownHexColor? = nil
    var type: MarkdownHexColor? = nil

    // MARK: 表格 / 任务列表

    /// 表头那一行的底色
    var tableHeaderBackground: MarkdownHexColor? = nil
    /// 表格线和外框
    var tableBorder: MarkdownHexColor? = nil
    /// 表格下方那几行**表格源码**的颜色
    var tableSourceText: MarkdownHexColor? = nil
    /// 复选框勾选后的填充色
    var taskChecked: MarkdownHexColor? = nil
    /// 复选框未勾选时的边框色
    var taskUncheckedBorder: MarkdownHexColor? = nil
    /// 勾选后那个对勾的颜色
    var taskCheckmark: MarkdownHexColor? = nil

    /// 这一套里到底有没有给出**任何一个**颜色。
    ///
    /// 全空 = 等于什么都没指定（「默认」那套预设就是全空的）。
    /// 挑文件时用它挡一道：用户挑了份不相干的 JSON（比如 package.json），
    /// 解析出来一个色都没有，那就不该记成「已指定」，否则界面上会出现「选了文件却没反应」。
    var isEmpty: Bool {
        // 全空的那一份就是 `MarkdownColorPalette()`：字段都是可选，逐项相等即「一个色都没给」
        self == MarkdownColorPalette()
    }

    /// 把另一套配色叠在自己上面（它有值的项覆盖我，没值的项保留我的）。
    ///
    /// 叠加顺序就是「优先级」：内置预设在下、用户的 JSON 在上，
    /// 所以调用时写成 `preset.merging(userPalette)`。
    func merging(_ other: MarkdownColorPalette) -> MarkdownColorPalette {
        var result = self
        result.editorBackground = other.editorBackground ?? editorBackground
        result.text = other.text ?? text
        result.marker = other.marker ?? marker
        result.orderedListMarker = other.orderedListMarker ?? orderedListMarker
        result.link = other.link ?? link
        result.inlineCode = other.inlineCode ?? inlineCode
        result.inlineCodeBacktick = other.inlineCodeBacktick ?? inlineCodeBacktick
        result.inlineCodeBackground = other.inlineCodeBackground ?? inlineCodeBackground
        result.codeBlockBackground = other.codeBlockBackground ?? codeBlockBackground
        result.quoteText = other.quoteText ?? quoteText
        result.quoteBar = other.quoteBar ?? quoteBar
        result.bullet = other.bullet ?? bullet
        result.separator = other.separator ?? separator
        result.searchMatchBackground = other.searchMatchBackground ?? searchMatchBackground
        result.searchCurrentMatchBackground =
            other.searchCurrentMatchBackground ?? searchCurrentMatchBackground
        result.lineNumber = other.lineNumber ?? lineNumber
        result.collapsedPlaceholder = other.collapsedPlaceholder ?? collapsedPlaceholder
        result.keyword = other.keyword ?? keyword
        result.string = other.string ?? string
        result.comment = other.comment ?? comment
        result.number = other.number ?? number
        result.type = other.type ?? type
        result.tableHeaderBackground = other.tableHeaderBackground ?? tableHeaderBackground
        result.tableBorder = other.tableBorder ?? tableBorder
        result.tableSourceText = other.tableSourceText ?? tableSourceText
        result.taskChecked = other.taskChecked ?? taskChecked
        result.taskUncheckedBorder = other.taskUncheckedBorder ?? taskUncheckedBorder
        result.taskCheckmark = other.taskCheckmark ?? taskCheckmark
        return result
    }
}

// MARK: - 内置预设

extension MarkdownColorPalette {

    /// **默认配色** = 一张空表：一个色都不覆盖，全部沿用 `MarkdownTheme` 自带的颜色。
    ///
    /// ### 为什么不把那些颜色抄一份到这里
    /// 抄一份就等于同一个数字在两个地方各写一次，改了一边忘了另一边，
    /// 用户就会遇到「我什么都没动，颜色怎么变了」。空表的语义反而最准确：
    /// 「默认」= 不覆盖。
    static let `default` = MarkdownColorPalette()

    /// **Vue（浅色）**：颜色取自仓库根目录的 `vue.css`。
    ///
    /// 主色是 Vue 绿 `#42b983`，正文是 `#34495e`。下面每一项的来历都写在注释里，
    /// 标「推导」的是 CSS 里没有直接对应的色、按同一套色系取的值。
    static let vue = MarkdownColorPalette(
        // `--side-bar-bg-color: #fff`，body 没设背景 = 白底
        editorBackground: "#ffffff",
        // body 的 color
        text: "#34495e",
        // 推导：CSS 里的弱化色是 #777，语法标记要比它更淡才不抢正文
        marker: "#bdc3c7",
        orderedListMarker: "#42b983",
        // a 的 color（主色）
        link: "#42b983",
        // `#write code, tt` 的 color
        inlineCode: "#e96900",
        // 推导：反引号属于语法标记，用中性灰，压得住 #f8f8f8 的底又不抢正文
        inlineCodeBacktick: "#95a5a6",
        // 推导：CSS 里行内代码底色是 #f8f8f8，这里用「8% 的黑」铺在白底上 ≈ #f5f5f5。
        // ⚠️ 必须带透明度，原因见 `inlineCodeBackground` 那条注释（不透明会盖住系统选中高亮）
        inlineCodeBackground: "#00000008",
        // `.md-fences` 的 background-color
        codeBlockBackground: "#f8f8f8",
        // blockquote 的 color
        quoteText: "#777777",
        // blockquote 的 border-left
        quoteBar: "#42b983",
        bullet: "#42b983",
        // hr 的 background-color
        separator: "#e7e7e7",
        // `#write mark` 的 background-color
        searchMatchBackground: "#EBFFEB",
        // 推导：当前命中用主色的 85%，比普通命中更重，一眼看出现在在第几个
        searchCurrentMatchBackground: "#42b983D9",
        // 推导：行号用和注释同一个灰，看得清又不抢正文
        lineNumber: "#95a5a6",
        collapsedPlaceholder: "#95a5a6",
        // `.md-lang`（``` 后面那个语言名）的色，拿它当关键字色
        keyword: "#b4654d",
        // `.cm-s-inner .cm-string`
        string: "#22a2c9",
        // 推导：CSS 里的弱化灰是 #777，注释取同系稍亮一档
        comment: "#95a5a6",
        // 推导：数字和字符串、关键字都要分得开，用 flat-ui 的蓝（#34495e 也是这个色系的）
        number: "#2980b9",
        // 推导：CSS 里没有类型色，取一个紫，避开赭红的关键字和蓝青的字符串
        type: "#8e44ad",
        // `#write table thead th` 的 background-color
        tableHeaderBackground: "#f2f2f2",
        // `table tr th` 的 border
        tableBorder: "#dfe2e5",
        // 推导：表格源码是「只是为了能改」的附属物，压到很淡
        tableSourceText: "#95a5a6",
        taskChecked: "#42b983",
        taskUncheckedBorder: "#dfe2e5",
        // 主色上用白对勾，对比度最稳
        taskCheckmark: "#ffffff"
    )

    /// **Vue Dark（深色）**：颜色取自仓库根目录的 `vue-dark.css`。
    ///
    /// 底色是 `#1f1f1f`、正文 `#eeeeee`，主色仍然是 Vue 绿 `#42b983`。
    /// CSS 里那些 `hsl(0, 0%, N%)` 已经换算成十六进制写在注释里。
    static let vueDark = MarkdownColorPalette(
        // body 的 background-color
        editorBackground: "#1f1f1f",
        // body 的 color
        text: "#eeeeee",
        // 推导：CSS 里注释是 hsl(0,0%,35%) = #595959，语法标记取同档再提亮一点，深底上才看得见
        marker: "#666666",
        orderedListMarker: "#42b983",
        // a 的 color（主色）
        link: "#42b983",
        // `#write code, tt` 的 color
        inlineCode: "#f3b37f",
        // 推导：把行内代码那个暖橙压暗压灰，反引号是语法标记，不该比代码正文还跳
        inlineCodeBacktick: "#926b4c",
        // `#write code, tt` 的 background-color 是 hsla(0,0%,0%,0.2) = 20% 的黑
        inlineCodeBackground: "#00000033",
        // `.md-fences` 的 background-color，hsl(0,0%,10%) = #1a1a1a
        codeBlockBackground: "#1a1a1a",
        // blockquote 的 color
        quoteText: "#eeeeee",
        // blockquote 的 border-left
        quoteBar: "#42b983",
        bullet: "#42b983",
        // hr 的 background-color，hsl(0,0%,18%) = #2e2e2e
        separator: "#2e2e2e",
        // `#write mark` 的 background-color（深色下也是这个亮绿，是「高亮」该有的样子）
        searchMatchBackground: "#EBFFEB",
        // 推导：当前命中用主色的 85%，比普通命中更重
        searchCurrentMatchBackground: "#42b983D9",
        // 推导：行号在深底上要比正文暗一截，取中性灰
        lineNumber: "#6b6b6b",
        collapsedPlaceholder: "#6b6b6b",
        // `.cm-s-inner .cm-keyword`
        keyword: "#bb7fc3",
        // `.cm-s-inner .cm-string`
        string: "#d48888",
        // `.cm-s-inner .cm-comment`，hsl(0,0%,35%) = #595959
        comment: "#595959",
        // `.cm-s-inner .cm-number`
        number: "#88b2a1",
        // `.cm-s-inner .cm-builtin`（CSS 里没有类型色，builtin 最接近「一批名字」这个语义）
        type: "#997fd4",
        // `#write table thead th` 的 background-color，hsl(0,0%,9%) = #171717
        tableHeaderBackground: "#171717",
        // `table tr td` 的 border
        tableBorder: "#1d1d1d",
        // 推导：表格源码深底上压到暗灰
        tableSourceText: "#757575",
        taskChecked: "#42b983",
        // `.md-rawblock-control` 的 background
        taskUncheckedBorder: "#555555",
        // 主色上用白对勾，对比度最稳
        taskCheckmark: "#ffffff"
    )
}

// MARK: - 内置主题

/// 内置的颜色主题。
///
/// ### 为什么要有一个枚举，而不是让调用方自己挑配色表
/// 界面上（设置页）要列出所有可选项、要显示名字、还要把用户的选择存成字符串。
/// 这三件事跟着枚举走，加一套主题只要在这儿加一个 case，界面和存档自动跟上。
///
/// ### 这个类型放在渲染层，App 层怎么用它才不算「耦合」
/// App 层只**存一个字符串**（`rawValue`）和**读 `palette`**，不认识里面具体的颜色。
/// 将来这个模块单独开源，App 层的代码一个字都不用改。
enum MarkdownColorTheme: String, Codable, CaseIterable {

    /// 用 `MarkdownTheme` 自带的默认色（一张空覆盖表）
    case `default` = "default"
    /// Vue 亮色（取自 vue.css）
    case vue = "vue"
    /// Vue 深色（取自 vue-dark.css）
    case vueDark = "vueDark"

    /// 设置页上显示的名字
    var displayName: String {
        switch self {
        case .default: return "默认"
        case .vue: return "Vue"
        case .vueDark: return "Vue Dark"
        }
    }

    /// 这一套主题对应的配色覆盖表
    var palette: MarkdownColorPalette {
        switch self {
        case .default: return .default
        case .vue: return .vue
        case .vueDark: return .vueDark
        }
    }
}
