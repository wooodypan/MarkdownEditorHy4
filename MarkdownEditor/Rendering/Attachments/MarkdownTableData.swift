//
//  MarkdownTableData.swift
//  MarkdownEditorHy4
//
//  表格的结构化数据：从 swift-markdown 的 Table 节点抽出来，供表格 view 绘制
//

import UIKit
import Markdown

/// 一个 markdown 表格的内容（表头 + 数据行 + 每列对齐方式）。
///
/// ### 为什么要有这一层
/// `Table` 是 AST 节点，里面套着 `Head` / `Body` / `Row` / `Cell`，还带着源码位置；
/// 画表格只需要「第几行第几列写什么字、这一列靠哪边对齐」。
/// 抽成一张扁平的表，绘制代码就不用碰 AST 了。
///
/// ### 单元格是 `NSAttributedString` 而不是 `String`
/// 表格图是只读预览，单元格里的 `**粗体**`、`*斜体*`、`~~删除~~`、`` `代码` ``、`[链接](url)`
/// 要显示成真正的粗体 / 斜体 / 删除线 / 等宽代码 / 链接色，**语法标记本身不出现**。
/// 这些属性在 init 时按主题烘进富文本（和正文渲染同一套思路），
/// 所以换主题必须整篇重新渲染，不能只改 `MarkdownTableView` 的字体或颜色。
struct MarkdownTableData {
    /// 每一列的对齐方式（对应 GFM 的 `:---` / `:--:` / `---:`）
    var columnAlignments: [NSTextAlignment]
    /// 表头那一行的**纯文本**（语法标记已去掉，供测试、复制等场景使用）
    var header: [String]
    /// 数据行（GFM 允许某一行比表头短，缺的格子按空串处理）
    var rows: [[String]]

    /// 表头单元格的富文本（粗体、颜色、行内样式都已经挂好）
    private let headerAttributed: [NSAttributedString]
    /// 数据行单元格的富文本
    private let rowsAttributed: [[NSAttributedString]]
    /// 缺格时用的空串：字体和颜色仍要跟着本行，量宽度时别退回系统默认字体
    private let emptyHeaderCell: NSAttributedString
    private let emptyBodyCell: NSAttributedString

    /// 从 swift-markdown 的表格节点抽取数据。
    ///
    /// - parameter theme: 单元格的字体、颜色、行内代码和链接样式都从这里取。
    ///   `MarkdownTableData` 建好之后就带着这套样式，换主题要重新建一份。
    init(_ table: Table, theme: MarkdownTheme) {
        // `:---` 左对齐、`:--:` 居中、`---:` 右对齐；没写（nil）按左对齐处理
        // 注意：columnAlignments 的元素是**可选值**（`ColumnAlignment?`），没写对齐就是 nil，
        // 所以 case 要写成 `.some(.center)` 这种形式
        columnAlignments = table.columnAlignments.map { alignment -> NSTextAlignment in
            switch alignment {
            case .some(.center): return .center
            case .some(.right): return .right
            default: return .left
            }
        }

        // 表头默认加粗，行内语法在这个基础上继续叠加：
        // `**粗体**` 不会变细，`*斜体*` 会变成粗斜体
        let headerFont = theme.bodyFont.adding(.traitBold)
        let headerCells = Array(table.head.cells).map {
            Self.attributedCell($0, baseFont: headerFont, theme: theme)
        }
        let bodyRows = Array(table.body.rows).map { row in
            Array(row.cells).map {
                Self.attributedCell($0, baseFont: theme.bodyFont, theme: theme)
            }
        }

        headerAttributed = headerCells
        rowsAttributed = bodyRows
        header = headerCells.map(\.string)
        rows = bodyRows.map { $0.map(\.string) }
        emptyHeaderCell = Self.emptyCell(font: headerFont, theme: theme)
        emptyBodyCell = Self.emptyCell(font: theme.bodyFont, theme: theme)
    }

    /// 总列数（取表头和所有数据行里最宽的那个，防止某行多写了一个格子）
    var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    /// 总行数 = 表头 1 行 + 数据行
    var rowCount: Int { rows.count + 1 }

    /// 第 `row` 行第 `column` 列的**纯文本**（第 0 行是表头）。
    /// 这一行比表头短、或者根本没有这一格时返回空串。
    func text(row: Int, column: Int) -> String {
        let line = row == 0 ? header : rows[row - 1]
        guard column < line.count else { return "" }
        return line[column]
    }

    /// 第 `row` 行第 `column` 列的富文本（第 0 行是表头）。
    ///
    /// 缺格时返回空串，但字体/颜色仍然和这一行一致 —— 量宽度时
    /// 不能因为属性字典里没有字体就退回系统默认值。
    func attributedText(row: Int, column: Int) -> NSAttributedString {
        guard row == 0 || row <= rowsAttributed.count else { return emptyBodyCell }
        let line = row == 0 ? headerAttributed : rowsAttributed[row - 1]
        guard column >= 0, column < line.count else {
            return row == 0 ? emptyHeaderCell : emptyBodyCell
        }
        return line[column]
    }

    /// 第 `column` 列的对齐方式（列数比 alignment 多时按左对齐）
    func alignment(column: Int) -> NSTextAlignment {
        guard column < columnAlignments.count else { return .left }
        return columnAlignments[column]
    }

    // MARK: 行内语法 → 富文本

    /// 一个单元格里当前叠加到哪一层的样式。
    ///
    /// 递归时只改需要改的那一项：粗体加粗、斜体倾斜、删除线加一条线、
    /// 代码换等宽字体和底色、链接换颜色。
    private struct CellStyle {
        var font: UIFont
        var color: UIColor
        var strikethrough: Bool = false
        var backgroundColor: UIColor?
        var isItalic: Bool = false
    }

    /// 把一个单元格的 inline 子树整棵走一遍，拼成富文本。
    ///
    /// 只把**语义文字**写进结果，语法标记（`**`、`~~`、反引号、`[...](...)`）一个都不写；
    /// 这也是表格图和下面那几行源码最大的区别 —— 源码保留原样，图里显示渲染结果。
    private static func attributedCell(_ cell: Markup,
                                       baseFont: UIFont,
                                       theme: MarkdownTheme) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        append(cell,
               to: result,
               style: CellStyle(font: baseFont, color: theme.textColor),
               theme: theme)
        return result
    }

    private static func append(_ markup: Markup,
                               to result: NSMutableAttributedString,
                               style: CellStyle,
                               theme: MarkdownTheme) {
        if let text = markup as? Text {
            appendText(text.string, to: result, style: style, theme: theme)
            return
        }
        if let code = markup as? InlineCode {
            var codeStyle = style
            codeStyle.font = theme.codeFont
            codeStyle.color = theme.inlineCodeColor
            codeStyle.backgroundColor = theme.inlineCodeBackground
            // 代码用独立字体，不再叠粗/斜体；删除线这种语义还要保留
            codeStyle.isItalic = false
            appendText(code.code, to: result, style: codeStyle, theme: theme)
            return
        }
        if markup is SoftBreak || markup is LineBreak {
            // 表格一行里不能放真换行，软/硬换行都按一个空格显示
            appendText(" ", to: result, style: style, theme: theme)
            return
        }
        if markup is InlineHTML {
            // 单元格里的内联 HTML（`<u>` 之类）不属于这次支持的行内语法。
            // 标签本身不能显示，否则 `| <u>x</u> |` 会在格子里露出尖括号
            return
        }
        if markup is Strong {
            var strongStyle = style
            strongStyle.font = style.font.adding(.traitBold)
            appendChildren(of: markup, to: result, style: strongStyle, theme: theme)
            return
        }
        if markup is Emphasis {
            var emphasisStyle = style
            emphasisStyle.font = style.font.adding(.traitItalic)
            emphasisStyle.isItalic = true
            appendChildren(of: markup, to: result, style: emphasisStyle, theme: theme)
            return
        }
        if markup is Strikethrough {
            var strikeStyle = style
            strikeStyle.strikethrough = true
            appendChildren(of: markup, to: result, style: strikeStyle, theme: theme)
            return
        }
        if let link = markup as? Link {
            // 链接只显示链接文字，URL 不显示。表格是图片、点不了，
            // 所以这里只上链接色，不挂 `.link` 属性（挂了也没交互，只会让人误会）
            let start = result.length
            appendChildren(of: link, to: result, style: style, theme: theme)
            let range = NSRange(location: start, length: result.length - start)
            if range.length > 0 {
                result.addAttribute(.foregroundColor, value: theme.linkColor, range: range)
            }
            return
        }
        // 其它行内节点（图片的 alt 文本等）：按子节点递归；
        // 没有子节点就当空串，绝不把源码符号写进图里
        appendChildren(of: markup, to: result, style: style, theme: theme)
    }

    private static func appendChildren(of markup: Markup,
                                       to result: NSMutableAttributedString,
                                       style: CellStyle,
                                       theme: MarkdownTheme) {
        for child in markup.children {
            append(child, to: result, style: style, theme: theme)
        }
    }

    /// 往结果里追加一段普通文字，并按当前样式上属性。
    ///
    /// 斜体要单独处理中文：系统给汉字回退的字体没有斜体字形，只加 `.traitItalic`
    /// 汉字不会歪（和 `MarkupToAttributedRenderer.applySyntheticItalicToCJK` 同一个坑）。
    /// 这里按「连续 CJK / 非 CJK」切段，只给中文换仿斜矩阵，英文仍然用真斜体。
    private static func appendText(_ text: String,
                                   to result: NSMutableAttributedString,
                                   style: CellStyle,
                                   theme: MarkdownTheme) {
        guard !text.isEmpty else { return }
        guard style.isItalic, theme.cjkItalicSlant != 0 else {
            result.append(NSAttributedString(string: text, attributes: attributes(for: style)))
            return
        }

        var run = ""
        var runIsCJK: Bool?
        for character in text {
            let isCJK = character.unicodeScalars.first?.isCJK == true
            if runIsCJK == nil {
                run = String(character)
                runIsCJK = isCJK
            } else if runIsCJK == isCJK {
                run.append(character)
            } else {
                appendRun(run,
                          isCJK: runIsCJK == true,
                          to: result,
                          style: style,
                          theme: theme)
                run = String(character)
                runIsCJK = isCJK
            }
        }
        if !run.isEmpty {
            appendRun(run,
                      isCJK: runIsCJK == true,
                      to: result,
                      style: style,
                      theme: theme)
        }
    }

    private static func appendRun(_ text: String,
                                  isCJK: Bool,
                                  to result: NSMutableAttributedString,
                                  style: CellStyle,
                                  theme: MarkdownTheme) {
        var runStyle = style
        if isCJK, theme.cjkItalicSlant != 0 {
            runStyle.font = style.font.withSlant(theme.cjkItalicSlant)
        }
        result.append(NSAttributedString(string: text, attributes: attributes(for: runStyle)))
    }

    private static func attributes(for style: CellStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: style.font,
            .foregroundColor: style.color
        ]
        if style.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let backgroundColor = style.backgroundColor {
            attributes[.backgroundColor] = backgroundColor
        }
        return attributes
    }

    private static func emptyCell(font: UIFont, theme: MarkdownTheme) -> NSAttributedString {
        NSAttributedString(string: "",
                           attributes: [.font: font, .foregroundColor: theme.textColor])
    }
}
