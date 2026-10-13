import Foundation
import Markdown
import UIKit

/// 把 swift-markdown 解析出来的语法树渲染成 HTML **片段**（不含 `<!DOCTYPE html>` 那些外壳）。
///
/// ### 为什么自己写而不用 `HTMLFormatter`
/// `HTMLFormatter` 是零成本的现成方案，但有三处不合要求：不认识脚注（`[^1]` 只是普通文本）、不管链接协议（`javascript:` 原样输出）、也不会加这套排版要用的 class（任务列表那个 `<input>` 得配 CSS 才排得好）。
/// 导出是一次性操作、产物给别人看，这三点比省几百行代码重要。
///
/// ### 安全底线
/// 所有来自用户文本的内容都过 `escape(_:)`：文本、代码、URL、`alt`。
/// 源码里手写的 HTML（`HTMLBlock` / `InlineHTML`）**转义成纯文本**显示 —— 这是 XSS 唯一的入口，放行它等于把文档变成网页。
struct MarkdownHTMLRenderer: MarkupVisitor {

    typealias Result = String

    // MARK: 调用方能配的东西

    /// 这篇文档里**真正有定义**的脚注 ID。
    ///
    /// 正文遇到 `[^id]` 时：ID 在集合里才渲染成锚点，否则原样输出成普通文本（悬空引用，和 GitHub 的处理一致）。
    var footnoteIDs: Set<String> = []

    /// 每个脚注 ID 在文末列表里的序号（按定义出现的先后排），用在 `↩` 回跳上。
    var footnoteNumbers: [String: Int] = [:]

    /// 图片地址怎么输出。给 `nil` 就照写；给了就用返回值当最终的 `src`（App 层用它把本地图编成 base64）。
    var imageSourceResolver: ((String) -> String)?

    /// 脚注 ID → `#fn-xxx` 锚点后缀的换算（同一个 ID 必须算出同一个值，不然引用和定义对不上）
    static func fragment(forFootnote id: String) -> String {
        let allowed = id.map { character -> Character in
            (character.isLetter || character.isNumber) ? character : "-"
        }
        return String(allowed)
    }

    // MARK: 内部状态

    /// 已经发出去的标题锚点，用来避免两个同名标题共用同一个 `id`
    private var usedHeadingIDs: Set<String> = []
    /// 给「标题没有可用字符」（比如标题全是汉字）时兜底的流水号
    private var headingFallbackCount = 0

    // MARK: 块级

    mutating func defaultVisit(_ markup: any Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    mutating func visitDocument(_ document: Document) -> String {
        defaultVisit(document)
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let body = defaultVisit(heading)
        let level = min(max(heading.level, 1), 6)
        return "<h\(level) id=\"\(makeHeadingID(heading))\">\(body)</h\(level)>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        "<p>\(defaultVisit(paragraph))</p>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        "<blockquote>\n\(defaultVisit(blockQuote))</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let language = codeBlock.language.map { " class=\"language-\(Self.escape($0))\"" } ?? ""
        return "<pre><code\(language)>\(Self.escape(codeBlock.code))</code></pre>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        "<ul>\n\(defaultVisit(unorderedList))</ul>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        // `start` 只在不是从 1 开始时才写：`<ol start="1">` 只是凭空多几个字节
        let start = orderedList.startIndex > 1 ? " start=\"\(orderedList.startIndex)\"" : ""
        return "<ol\(start)>\n\(defaultVisit(orderedList))</ol>\n"
    }

    mutating func visitListItem(_ item: ListItem) -> String {
        // 任务列表：`<input disabled>` 让它看起来是个勾却点不了，再靠 CSS 把原生那个圆点摘掉（见 `list-style:none`）
        let checkboxHTML: String
        let extraClass: String
        if let checkbox = item.checkbox {
            checkboxHTML = "<input type=\"checkbox\" disabled\(checkbox == .checked ? " checked" : "")> "
            extraClass = " class=\"task\""
        } else {
            checkboxHTML = ""
            extraClass = ""
        }

        // 列表项的**第一段**摊平成一行：不管是 `- 内容` 还是 `- 一级\n  - 二级`，写成 `<li><p>内容</p></li>` 都会让浏览器给那段 `<p>` 上下各留一段外边距 —— 每行之间空得像点了两次回车。
        // ⚠️ swift-markdown 不给「这个是松散列表还是紧凑列表」，所以统一按紧凑处理：
        // 绝大多数列表都是紧凑的，真遇上松散的那几条牺牲一点点间距，比每行都多一段空白划算。
        let children = Array(item.children)
        var body = ""
        if let first = children.first as? Paragraph {
            body += defaultVisit(first)
            body += children.dropFirst().map { visit($0) }.joined()
        } else {
            body += "\n" + children.map { visit($0) }.joined()
        }
        return "<li\(extraClass)>\(checkboxHTML)\(body)</li>\n"
    }

    /// 表格：整张一次画完（`MarkupFormatter` 里也警告 Head / Body / Row / Cell 不能单独救）。
    mutating func visitTable(_ table: Table) -> String {
        // 列对齐来自 `| :---: |` 那行，写成每个单元格的 `style` 而不是 `<colgroup>` ——后者在 WKWebView 和不少 Markdown 阅读器里会被忽略
        let alignments = Array(table.columnAlignments)
        let headerCells = Array(table.head.cells)
        let bodyRows = Array(table.body.rows)

        guard !headerCells.isEmpty || !bodyRows.isEmpty else { return "" }

        var output = "<table>\n"
        if !headerCells.isEmpty {
            output += "<thead>\n<tr>"
            for (index, cell) in headerCells.enumerated() {
                output += "<th\(Self.alignmentStyle(alignments, index))>\(visit(cell))</th>"
            }
            output += "</tr>\n</thead>\n"
        }
        if !bodyRows.isEmpty {
            output += "<tbody>\n"
            for row in bodyRows {
                output += "<tr>"
                for (index, cell) in Array(row.cells).enumerated() {
                    output += "<td\(Self.alignmentStyle(alignments, index))>\(visit(cell))</td>"
                }
                output += "</tr>\n"
            }
            output += "</tbody>\n"
        }
        return output + "</table>\n"
    }

    /// 正常路径是 `visitTable` 一次画完；真有人单独走到这里就顺着子树往下渲染，别越权去拼 `<tr>`
    mutating func visitTableHead(_ tableHead: Table.Head) -> String {
        defaultVisit(tableHead)
    }

    mutating func visitTableBody(_ tableBody: Table.Body) -> String {
        defaultVisit(tableBody)
    }

    mutating func visitTableRow(_ tableRow: Table.Row) -> String {
        defaultVisit(tableRow)
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) -> String {
        defaultVisit(tableCell)
    }

    // MARK: 行内

    mutating func visitText(_ text: Text) -> String {
        renderInlineString(text.string)
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(defaultVisit(strong))</strong>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(defaultVisit(emphasis))</em>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        "<del>\(defaultVisit(strikethrough))</del>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(Self.escape(inlineCode.code))</code>"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br>\n"
    }

    mutating func visitLink(_ link: Link) -> String {
        let destination = link.destination ?? ""
        let body = defaultVisit(link)
        let title = link.title.map { " title=\"\(Self.escape($0))\"" } ?? ""

        // 🚨 协议白名单之外的（`javascript:`、`data:text/html` 这些）一律不给 `href` ——只留文字。这一步加上 `escape` 里先转义 `&`，`&#106;avascript:` 这种绕过写法才会失效
        guard Self.isSafeURL(destination) else {
            return body.isEmpty ? Self.escape(destination) : body
        }
        let shown = body.isEmpty ? Self.escape(destination) : body
        return "<a href=\"\(Self.escape(destination))\"\(title)>\(shown)</a>"
    }

    mutating func visitImage(_ image: Image) -> String {
        let rawSource = image.source ?? ""
        let source = imageSourceResolver?(rawSource) ?? rawSource
        let alt = Self.escape(image.plainText)
        let title = image.title.map { " title=\"\(Self.escape($0))\"" } ?? ""

        // base64 内联出来的那个 `data:` 要放行，其它协议照上面的白名单来
        guard Self.isSafeURL(source) || source.hasPrefix("data:") else {
            return alt
        }
        return "<img src=\"\(Self.escape(source))\" alt=\"\(alt)\"\(title)>"
    }

    /// 源码里手写的行内 HTML（`<span style="...">` 之类）→ **转义成纯文本**。
    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        Self.escape(inlineHTML.rawHTML)
    }

    /// 源码里手写的整块 HTML（`<div>`、`<table>` 这类）→ 转义后放进一个保留换行的盒子。
    ///
    /// 为什么要那个盒子：裸文本会被浏览器把换行当空格吞掉，`<div>a</div>\n<div>b</div>` 就糊成一行。
    /// CSS 里给 `.raw-html` 加了 `white-space: pre-wrap`，换行就回来了。
    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        "<div class=\"raw-html\">\(Self.escape(html.rawHTML))</div>\n"
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) -> String {
        "<code>\(Self.escape(symbolLink.destination ?? ""))</code>"
    }

    // MARK: 文本与脚注

    /// 一段纯文本里的 `[^id]` 换成脚注锚点，其余部分照常转义。
    private mutating func renderInlineString(_ raw: String) -> String {
        let matches = FootnoteIndex.references(in: raw)
        guard !matches.isEmpty else { return Self.escape(raw) }

        var output = ""
        var cursor = raw.startIndex
        for match in matches {
            guard let range = Range(match.range, in: raw) else { continue }
            output += Self.escape(String(raw[cursor..<range.lowerBound]))
            output += footnoteReference(id: match.id)
            cursor = range.upperBound
        }
        output += Self.escape(String(raw[cursor...]))
        return output
    }

    /// 正文里一处 `[^id]` 渲染出来的样子。
    ///
    /// 悬空引用（没写定义的）保持原样输出 `[^id]` —— 写源码的人多半是忘了补定义，原样留着比悄悄变成一个点不响的链接好排查。
    private func footnoteReference(id: String) -> String {
        guard footnoteIDs.contains(id) else { return Self.escape("[^" + id + "]") }
        let fragment = Self.fragment(forFootnote: id)
        let number = footnoteNumbers[id] ?? 0
        return "<sup class=\"footnote-ref\">"
            + "<a href=\"#fn-\(fragment)\" id=\"fnref-\(fragment)-\(number)\">\(Self.escape(id))</a>"
            + "</sup>"
    }

    // MARK: 标题锚点

    /// 给标题算一个 `id`，让 `#xxx` 能跳进来（也方便以后凑目录）。
    private mutating func makeHeadingID(_ heading: Heading) -> String {
        let slug = Self.slugify(heading.plainText)
        var candidate = slug.isEmpty ? "" : slug
        if candidate.isEmpty {
            headingFallbackCount += 1
            candidate = "section-\(headingFallbackCount)"
        }
        // 两个标题同名时给后者加后缀，不然浏览器只会跳到第一个
        var unique = candidate
        var suffix = 2
        while usedHeadingIDs.contains(unique) {
            unique = "\(candidate)-\(suffix)"
            suffix += 1
        }
        usedHeadingIDs.insert(unique)
        return unique
    }

    /// GitHub 风格的锚点：小写、非字母数字换成 `-`、连续 `-` 合并。
    ///
    /// ⚠️ 汉字也算 `isLetter`，所以纯中文标题会整段留下当锚点（`id="中文标题"` 是合法的 HTML id，浏览器照跳）。
    /// 真正会清空的是全标点标题（`## ???` 这种），那时由调用方兜底成流水号。
    private static func slugify(_ text: String) -> String {
        var output = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                output.append(character)
            } else if output.last != "-" {
                output.append("-")
            }
        }
        // 收尾那个 `-` 不要
        while output.last == "-" { output.removeLast() }
        return output
    }

    // MARK: 小工具

    /// 第 `index` 列的对齐属性（写了 `| :---: |` 才有内容）
    private static func alignmentStyle(_ alignments: [Table.ColumnAlignment?], _ index: Int) -> String {
        guard index < alignments.count, let alignment = alignments[index] else { return "" }
        switch alignment {
        case .left: return " style=\"text-align:left\""
        case .center: return " style=\"text-align:center\""
        case .right: return " style=\"text-align:right\""
        }
    }

    /// HTML 转义。所有来自文档的文本都得过这一道。
    ///
    /// `&` 必须排第一：先转义它，`&#106;avascript:` 这类「用实体藏协议」的写法才会连带失效 ——浏览器看到的是 `&amp;#106;`，只是一串字，不会还原成 `j`。
    static func escape(_ text: String) -> String {
        var output = text.replacingOccurrences(of: "&", with: "&amp;")
        output = output.replacingOccurrences(of: "<", with: "&lt;")
        output = output.replacingOccurrences(of: ">", with: "&gt;")
        output = output.replacingOccurrences(of: "\"", with: "&quot;")
        output = output.replacingOccurrences(of: "'", with: "&#39;")
        return output
    }

    /// 链接 / 图片地址能不能放行。
    ///
    /// 放行三类：不带协议的相对路径（`sample.png`、`#锚点`）、 Protocols 白名单里的标识符、以及 `//host/path` 这种跟随协议的地址。
    /// 其它（`javascript:`、`file:`、`data:`）一律不行。
    static func isSafeURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // 相对路径 / 页内锚点：第一个字符不是字母就不是协议
        guard let colon = trimmed.firstIndex(of: ":") else { return true }
        let scheme = String(trimmed[trimmed.startIndex..<colon]).lowercased()
        // 协议只能由字母、数字、`+`、`-`、`.` 组成（RFC 3986），混进别的字符说明鬼祟
        guard scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }),
              !scheme.isEmpty else { return false }
        return Self.allowedSchemes.contains(scheme)
    }

    /// 放行的链接协议（只包含「跳出去 / 发封信 / 打电话」这几种不会执行脚本的）
    private static let allowedSchemes: Set<String> = ["http", "https", "mailto", "tel"]
}
