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

    /// 把一个 `UIColor` 写成十六进制字符串 —— 上面 `hex` 那条路的反方向，取色器挑完色要用它存回文件。
    ///
    /// 不透明就写 6 位（`#42b983`），带透明度就写 8 位（`#42b983d9`）：
    /// 底色那几色必须能把透明度存下来，否则读回来会变成实色、盖住系统的选中高亮。
    init(color: UIColor) {
        self.hex = Self.string(from: color)
    }

    /// 把一个颜色写成十六进制字符串（`init(color:)` 背后干活的那个，方便只想要字符串的地方直接调）
    static func string(from color: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        // 少数颜色不在 RGB 空间里（系统动态色、灰度色这类），取不出分量就退回不透明的黑 —— 调用方看得出「这一色没取到」，界面不会跟着乱
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "#000000" }

        let body = [red, green, blue].map { String(format: "%02x", byte($0)) }.joined()
        // 差一点点到 1 也算「不透明」：浮点误差不该让人拿到 8 位的 #fffffffe
        return alpha >= 0.999 ? "#\(body)" : "#\(body)\(String(format: "%02x", byte(alpha)))"
    }

    /// 把 0~1 的分量量化成 0~255 的一个字节。
    ///
    /// 广色域（Display P3）的颜色分量可能略超出 0~1，先夹回来再取整 —— 不然 1.001 会溢出成 0，整块颜色反过来。
    private static func byte(_ value: CGFloat) -> UInt8 {
        UInt8(Int(max(0, min(255, (value * 255).rounded()))))
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

    /// 按「颜色的名字」读写某一个色（界面上一行一个色，用的就是它）。
    ///
    /// ### 为什么要有这个下标
    /// 「逐个颜色摆一行让人改」这件事需要**遍历**这张表的字段，而 Swift 的 struct 没法直接枚举自己的字段。
    /// 于是把 28 个字段的「门牌号」（key path）集中登记在 `MarkdownPaletteColorKey` 里，这里只是一个转手 —— 好处是加一个新颜色只要加一个字段 + 一个 case，别处一行都不用改。
    subscript(key: MarkdownPaletteColorKey) -> MarkdownHexColor? {
        get { self[keyPath: key.palettePath] }
        set { self[keyPath: key.palettePath] = newValue }
    }

    /// 这一套里实际给了几个色（界面上要写「已改 N 色」）
    var definedColorCount: Int {
        MarkdownPaletteColorKey.allCases.filter { self[$0] != nil }.count
    }

    /// 把另一套配色叠在自己上面（它有值的项覆盖我，没值的项保留我的）。
    ///
    /// 叠加顺序就是「优先级」：内置预设在下、用户的 JSON 在上，
    /// 所以调用时写成 `preset.merging(userPalette)`。
    func merging(_ other: MarkdownColorPalette) -> MarkdownColorPalette {
        var result = self
        // 走 `allCases` 而不是挨个写字段名：以后加一个色，`MarkdownPaletteColorKey` 里多一个 case 就自动跟上
        for key in MarkdownPaletteColorKey.allCases {
            result[key] = other[key] ?? self[key]
        }
        return result
    }

    /// 导出成 JSON（给别人用、或者自己留一份）。
    ///
    /// ### 为什么导出来只有「改过的那几色」
    /// 这张表本身就是覆盖表，没给的项就是 `nil`，而 `Codable` 对可选字段用的是 `encodeIfPresent` —— `nil` 的键**不会写进文件**。所以导出来的正好是「我动了哪些」，别人套在自己主题上不会把整套颜色全冲掉。
    func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        }
        return try encoder.encode(self)
    }
}

// MARK: - 颜色清单（界面上一行一个色）

/// 一个色在界面上属于哪一区（只是分组显示用，不影响颜色本身）
enum MarkdownPaletteColorGroup: String, CaseIterable {
    /// 编辑区里看得见的那些色
    case editor
    /// 代码块里的语法高亮（五个语法角色）
    case syntax
    /// 表格和任务列表
    case table

    var displayName: String {
        switch self {
        case .editor: return "编辑区"
        case .syntax: return "代码高亮"
        case .table: return "表格与任务列表"
        }
    }
}

/// 配色表里**每一个颜色**的名字。
///
/// ### 为什么要有这么一个枚举
/// 「让用户逐个改颜色」需要三件 struct 自己给不了的东西：遍历（一行一个色）、名字（给用户看）、以及它在两张表里的门牌号。
/// 枚举的 `rawValue` 就是 JSON 里的键名，`palettePath` 指回 `MarkdownColorPalette` 的字段、`themeColorPath` 指到 `MarkdownTheme` 上对应的那个 `UIColor`
/// —— 于是 `MarkdownTheme.applyColorPalette` 也能改成遍历它，不再需要把 28 个字段抄两遍（抄两遍的必然结果就是加颜色时漏一处，界面上「改了没生效」）。
///
/// ### 加一个新颜色要做的事
/// 1. `MarkdownColorPalette` 加字段；2. 这里加 case（三个 switch 各写一行）；3. `MarkdownTheme` 加字段。
/// 三处都齐了，`MarkdownColorThemeTests` 里那条「枚举个数 == 字段个数」的断言才不会红。
enum MarkdownPaletteColorKey: String, CaseIterable, Identifiable {

    // 编辑区
    case editorBackground
    case text
    case marker
    case orderedListMarker
    case link
    case inlineCode
    case inlineCodeBacktick
    case inlineCodeBackground
    case codeBlockBackground
    case quoteText
    case quoteBar
    case bullet
    case separator
    case searchMatchBackground
    case searchCurrentMatchBackground
    case lineNumber
    case collapsedPlaceholder

    // 代码高亮
    case keyword
    case string
    case comment
    case number
    case type

    // 表格与任务列表
    case tableHeaderBackground
    case tableBorder
    case tableSourceText
    case taskChecked
    case taskUncheckedBorder
    case taskCheckmark

    /// `Identifiable` 要的身份证：就是 JSON 里的键名（比如 `inlineCodeBackground`）
    var id: String { rawValue }

    /// 界面上显示的名字
    var displayName: String {
        switch self {
        case .editorBackground: return "编辑区底色"
        case .text: return "正文文字"
        case .marker: return "语法标记"
        case .orderedListMarker: return "有序列表序号"
        case .link: return "链接"
        case .inlineCode: return "行内代码文字"
        case .inlineCodeBacktick: return "行内代码反引号"
        case .inlineCodeBackground: return "行内代码底色"
        case .codeBlockBackground: return "代码块底色"
        case .quoteText: return "引用块文字"
        case .quoteBar: return "引用块竖条"
        case .bullet: return "列表圆点"
        case .separator: return "分隔线"
        case .searchMatchBackground: return "查找命中底色"
        case .searchCurrentMatchBackground: return "当前命中底色"
        case .lineNumber: return "行号"
        case .collapsedPlaceholder: return "折叠占位「⋯」"
        case .keyword: return "关键字"
        case .string: return "字符串"
        case .comment: return "注释"
        case .number: return "数字"
        case .type: return "类型名"
        case .tableHeaderBackground: return "表头底色"
        case .tableBorder: return "表格线"
        case .tableSourceText: return "表格源码文字"
        case .taskChecked: return "复选框（已勾选）"
        case .taskUncheckedBorder: return "复选框边框（未勾选）"
        case .taskCheckmark: return "复选框对勾"
        }
    }

    /// 属于哪一区
    var group: MarkdownPaletteColorGroup {
        switch self {
        case .keyword, .string, .comment, .number, .type: return .syntax
        case .tableHeaderBackground, .tableBorder, .tableSourceText,
             .taskChecked, .taskUncheckedBorder, .taskCheckmark: return .table
        default: return .editor
        }
    }

    /// 行下面那一行小字：写这一色的「注意事项」，没有就 `nil`（大多数色没什么好说的）
    var note: String? {
        switch self {
        case .inlineCodeBackground:
            return "必须半透明：它是挂在文字上的底色，不透明会盖住系统画在下面的选中高亮。"
        case .editorBackground:
            return "深色主题主要靠它把整片背景压下来。"
        default:
            return nil
        }
    }

    /// 这一色在**配色表**里的门牌号（读写 JSON 里那个键用的就是它）
    var palettePath: WritableKeyPath<MarkdownColorPalette, MarkdownHexColor?> {
        switch self {
        case .editorBackground: return \.editorBackground
        case .text: return \.text
        case .marker: return \.marker
        case .orderedListMarker: return \.orderedListMarker
        case .link: return \.link
        case .inlineCode: return \.inlineCode
        case .inlineCodeBacktick: return \.inlineCodeBacktick
        case .inlineCodeBackground: return \.inlineCodeBackground
        case .codeBlockBackground: return \.codeBlockBackground
        case .quoteText: return \.quoteText
        case .quoteBar: return \.quoteBar
        case .bullet: return \.bullet
        case .separator: return \.separator
        case .searchMatchBackground: return \.searchMatchBackground
        case .searchCurrentMatchBackground: return \.searchCurrentMatchBackground
        case .lineNumber: return \.lineNumber
        case .collapsedPlaceholder: return \.collapsedPlaceholder
        case .keyword: return \.keyword
        case .string: return \.string
        case .comment: return \.comment
        case .number: return \.number
        case .type: return \.type
        case .tableHeaderBackground: return \.tableHeaderBackground
        case .tableBorder: return \.tableBorder
        case .tableSourceText: return \.tableSourceText
        case .taskChecked: return \.taskChecked
        case .taskUncheckedBorder: return \.taskUncheckedBorder
        case .taskCheckmark: return \.taskCheckmark
        }
    }

    /// 这一色**套进 `MarkdownTheme` 之后**落在哪个字段上（界面上要显示「现在实际是什么色」就得读它）
    var themeColorPath: WritableKeyPath<MarkdownTheme, UIColor> {
        switch self {
        case .editorBackground: return \.editorBackground
        case .text: return \.textColor
        case .marker: return \.markerColor
        case .orderedListMarker: return \.orderedListMarkerColor
        case .link: return \.linkColor
        case .inlineCode: return \.inlineCodeColor
        case .inlineCodeBacktick: return \.inlineCodeBacktickColor
        case .inlineCodeBackground: return \.inlineCodeBackground
        case .codeBlockBackground: return \.codeBlockBackground
        case .quoteText: return \.quoteTextColor
        case .quoteBar: return \.quoteBarColor
        case .bullet: return \.bulletColor
        case .separator: return \.separatorColor
        case .searchMatchBackground: return \.searchMatchBackground
        case .searchCurrentMatchBackground: return \.searchCurrentMatchBackground
        case .lineNumber: return \.lineNumberColor
        case .collapsedPlaceholder: return \.collapsedPlaceholderColor
        // 下面这几个是 `MarkdownTheme` 里嵌套的小结构体，key path 可以一层层穿进去
        case .keyword: return \.syntaxColors.keyword
        case .string: return \.syntaxColors.string
        case .comment: return \.syntaxColors.comment
        case .number: return \.syntaxColors.number
        case .type: return \.syntaxColors.type
        case .tableHeaderBackground: return \.table.headerBackground
        case .tableBorder: return \.table.borderColor
        case .tableSourceText: return \.table.sourceTextColor
        case .taskChecked: return \.taskList.checkedColor
        case .taskUncheckedBorder: return \.taskList.uncheckedBorderColor
        case .taskCheckmark: return \.taskList.checkmarkColor
        }
    }

    /// 某一区里有哪些色（界面按区分段用的就是这个）
    static func keys(in group: MarkdownPaletteColorGroup) -> [MarkdownPaletteColorKey] {
        // 按 case 的声明顺序排 —— 也就是上面写的「底色 → 文字 → 标记 → …」这个顺序，用户找起来顺手
        allCases.filter { $0.group == group }
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
