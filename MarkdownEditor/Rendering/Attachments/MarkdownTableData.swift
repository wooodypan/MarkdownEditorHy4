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
struct MarkdownTableData {
    /// 每一列的对齐方式（对应 GFM 的 `:---` / `:--:` / `---:`）
    var columnAlignments: [NSTextAlignment]
    /// 表头那一行的单元格
    var header: [String]
    /// 数据行（GFM 允许某一行比表头短，缺的格子按空串处理）
    var rows: [[String]]

    /// 从 swift-markdown 的表格节点抽取数据
    init(_ table: Table) {
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
        // cells / rows 是懒序列（LazyMapSequence），转成数组后面才好按下标取
        header = Array(table.head.cells).map { Self.plainText(of: $0) }
        rows = Array(table.body.rows).map { row in Array(row.cells).map { Self.plainText(of: $0) } }
    }

    /// 取一个单元格里的纯文字（去掉 `**`、` 这些语法符号）。
    ///
    /// ### 为什么不能直接用 `cell.plainText`
    /// swift-markdown 的 `plainText` 对**行内代码**会连反引号一起返回
    /// （`` `代码` `` 取出来还是 `` `代码` ``），画到表格里就多两个反引号，看着像 bug。
    /// 所以这里自己递归一层：文字取原文、行内代码只取代码本身、软换行换成空格。
    private static func plainText(of markup: Markup) -> String {
        if let text = markup as? Text { return text.string }
        if let code = markup as? InlineCode { return code.code }
        if markup is SoftBreak || markup is LineBreak { return " " }
        if markup.childCount == 0 {
            // 其它叶子（行内 HTML 之类）：拿不到纯文本就当空串，
            // 绝不能把 `<b>` 这种语法符号画进表格
            return ""
        }
        return markup.children.map { plainText(of: $0) }.joined()
    }

    /// 总列数（取表头和所有数据行里最宽的那个，防止某行多写了一个格子）
    var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    /// 总行数 = 表头 1 行 + 数据行
    var rowCount: Int { rows.count + 1 }

    /// 第 `row` 行第 `column` 列的文字（第 0 行是表头）。
    /// 这一行比表头短、或者根本没有这一格时返回空串。
    func text(row: Int, column: Int) -> String {
        let line = row == 0 ? header : rows[row - 1]
        guard column < line.count else { return "" }
        return line[column]
    }

    /// 第 `column` 列的对齐方式（列数比 alignment 多时按左对齐）
    func alignment(column: Int) -> NSTextAlignment {
        guard column < columnAlignments.count else { return .left }
        return columnAlignments[column]
    }
}
