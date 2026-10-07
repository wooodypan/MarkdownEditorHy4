//
//  HTMLToMarkdownConverter.swift
//  MarkdownEditorHy4
//
//  把从网页 / Word / 备忘录里复制来的富文本（HTML）转成 markdown 源码。
//
//  ### 为什么放在 App 这一层
//  这是「App 想怎么处理剪贴板」的事，不是编辑器组件的能力 ——编辑器只认 markdown 源码，从来没见过 HTML。放在这里，`MarkdownEditor/`
//  那一层（将来要单独开源）就不用依赖 SwiftSoup，也不用认识设置页。
//
//  ### 为什么用 SwiftSoup 自己遍历，而不是 `NSAttributedString(html:)`
//  - `NSAttributedString` 的 HTML 导入底层走 WebKit，**只能在主线程跑**，内容一大就卡；
//  - 它拿到的是「样式」不是「语义」：标题变成字号、列表变成 `•\t` 文本，
//    表格和嵌套列表基本还原不出来。而 HTML 里 `<h1>` / `<ul>` / `<table>` 是明摆着的结构。
//
//  ### 目标不是一比一还原
//  复制来的东西本来就是「够用就行」：只要标题是标题、列表是列表、链接和图片还在，剩下的细节（缩进几个空格、用 `*` 还是 `-`）不影响阅读。
//  所以下面的规则一律是「尽量转，转不了就退回纯文本」，不追求和原页面一模一样。
//

import Foundation
import SwiftSoup

/// HTML → Markdown。
///
/// 用法就一个入口：`markdown(fromHTML:)`。解析失败、或者整段 HTML 里没有任何能转的内容时返回 `nil`，调用方据此退回「按纯文本粘贴」。
enum HTMLToMarkdownConverter {

    /// 把一段 HTML 转成 markdown 源码。
    ///
    /// - parameter html: 剪贴板里的 `public.html`（可以是完整页面，也可以只是一个片段）
    /// - returns: 转出来的源码；一个字都没转出来时 `nil`
    static func markdown(fromHTML html: String) -> String? {
        let prepared = prepare(html)
        guard !prepared.isEmpty else { return nil }

        do {
            let document = try SwiftSoup.parse(prepared)
            // 这些标签里装的不是正文（脚本、样式、内嵌页面…），整块扔掉。
            // ⚠️ 必须在遍历**之前**删：留着的话脚本里的 `<` `>` 会被当成正文输出
            try document.select(Self.droppedSelector).remove()
            // 有 `<body>` 就从 body 开始：`<head>` 里的 title / meta 不是正文
            let root: Element = document.body() ?? document
            return Renderer(root: root).run()
        } catch {
            return nil
        }
    }

    // MARK: - 解析前的预处理

    /// 整块删掉的选择器（解析完立刻 `remove()`）
    private static let droppedSelector = "script, style, noscript, template, svg, math, iframe, "
        + "object, embed, canvas, audio, video, source, track, link, meta, base, head, title, colgroup"

    /// 剥掉剪贴板带来的外壳，只留真正被选中的那一段
    private static func prepare(_ html: String) -> String {
        var text = fragment(in: html)
        // Word / 老版浏览器塞进来的条件注释（`<!--[if gte mso 9]>…<![endif]-->`），里面是一整套 mso 样式表，留着会被当成正文输出
        text = text.replacingOccurrences(of: "(?is)<!--\\[if\\b.*?<!\\[endif\\]\\s*-->",
                                         with: " ", options: .regularExpression)
        return text
    }

    /// 取 `<!--StartFragment-->` 到 `<!--EndFragment-->` 之间的内容。
    ///
    /// Windows 上的剪贴板 HTML 是一整个外壳：`<html><body><!--StartFragment-->…`，前后还挂着 `<meta>`、`<style>` 和一堆 mso 样式。没有这两个标记就原样返回（Safari / Chrome 复制出来的往往就是一个干净的片段，本身没有这些标记）。
    private static func fragment(in html: String) -> String {
        guard let start = html.range(of: "<!--StartFragment-->", options: .caseInsensitive) else {
            return html
        }
        let afterStart = html[start.upperBound...]
        guard let end = afterStart.range(of: "<!--EndFragment-->", options: .caseInsensitive) else {
            return String(afterStart)
        }
        return String(afterStart[..<end.lowerBound])
    }
}

// MARK: - 遍历

/// 一次转换的全部状态都在这里。
///
/// ### 为什么是一个类而不是一堆静态函数
/// 遍历过程要带着「当前缩进 / 引用前缀」往下走，写成静态函数就得把这些参数一路传下去，每个方法都得多两个参数。
private final class Renderer {

    private let root: Element

    init(root: Element) {
        self.root = root
    }

    /// 原因同 `MarkdownPasteboardController`：app target 开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，非 UI 的类不写这一行，释放时可能踩 Swift 6.2 运行时的野指针 free。本类只持有节点引用，安全。
    nonisolated deinit {}

    /// 转出来的 markdown；一个字都没有就返回 `nil`
    func run() -> String? {
        let text = Self.assemble(renderChildren(root, prefix: ""))
        return text.isEmpty ? nil : text
    }

    // MARK: 标签分类

    /// 会被当成块级处理的标签。
    ///
    /// ⚠️ 只列「要单独占一段」的。没在名单里的标签（`<article>`、`<main>`、`<span>`…）
    /// 走兜底分支：当一层透明的壳，直接往下遍历子节点。
    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "caption", "center", "dd", "details",
        "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form",
        "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "menu", "nav",
        "ol", "p", "pre", "section", "summary", "table", "tbody", "td", "tfoot", "th",
        "thead", "tr", "ul"
    ]

    private static let headingLevels: [String: Int] = [
        "h1": 1, "h2": 2, "h3": 3, "h4": 4, "h5": 5, "h6": 6
    ]

    /// 表头 / 单元格的对齐方式 → GFM 分隔行里那一串
    private static let alignmentMarks: [String: String] = [
        "left": ":---", "center": ":---:", "right": "---:", "start": ":---", "end": "---:"
    ]

    // MARK: 块级

    /// 遍历一个容器的**直接**子节点，返回若干个块（块之间会用一个空行隔开）。
    ///
    /// ### 为什么要一边攒行内、一边收块
    /// HTML 里 `<p>文本<a>链接</a>文本</p>` 这种结构，文本节点和行内元素是混着来的 ——只有碰到一个块级元素才说明「上一段结束了」。所以用一个 `inline` 缓冲攒着，碰到块就先把它吐出去。
    private func renderChildren(_ node: Node, prefix: String) -> [String] {
        var blocks: [String] = []
        var inline = ""

        func flush() {
            guard !inline.isEmpty else { return }
            // ⚠️ 这里必须**合成一个块**：`<p>第一行<br>第二行</p>` 里的硬换行会在 inline 里留一个换行，切成两块的话中间就多出一个空行 ——那两段看起来就不再是同一个段落了
            let lines = Self.paragraph(inline, prefix: prefix)
            if !lines.isEmpty {
                blocks.append(lines.joined(separator: "\n"))
            }
            inline = ""
        }

        for child in node.getChildNodes() {
            if let produced = renderBlock(child, prefix: prefix) {
                flush()
                blocks.append(contentsOf: produced)
            } else if let text = renderInline(child) {
                inline += text
            }
        }
        flush()
        return blocks
    }

    /// 把 `node` 当块级元素渲染。它不是块级（行内 / 文本 / 注释）就返回 `nil`
    private func renderBlock(_ node: Node, prefix: String) -> [String]? {
        guard let element = node as? Element else { return nil }
        let tag = element.nodeName().lowercased()

        // 行内标签却装着块级内容（Google Docs 那层 `<b style="font-weight:normal">`）
        // → 它不是「一段加粗的文字」，只是一层透明的壳，按容器往下走
        if !Self.blockTags.contains(tag) {
            return Self.containsBlockChild(element) ? renderChildren(element, prefix: prefix) : nil
        }

        if let level = Self.headingLevels[tag] {
            let body = Self.escapeLineStarts(in: trimmedInline(of: element))
            guard !body.isEmpty else { return [] }
            return [prefix + String(repeating: "#", count: level) + " " + body]
        }

        switch tag {
        case "hr":
            return [prefix + "---"]
        case "pre":
            return fencedCode(element, prefix: prefix)
        case "blockquote":
            return blockquote(element, prefix: prefix)
        case "ul", "ol":
            return list(element, prefix: prefix)
        case "table":
            return table(element, prefix: prefix)
        case "dl":
            return definitionList(element, prefix: prefix)
        default:
            // `<div>` / `<section>` / `<figure>` 这些壳，以及孤零零出现的 `<li>` / `<td>`：
            // 都当成容器往下走
            return renderChildren(element, prefix: prefix)
        }
    }

    /// 这个元素**直接**装着块级元素吗
    ///
    /// ### 为什么需要问这一句
    /// Google Docs 复制出来的东西整篇包在 `<b style="font-weight:normal">` 里 —— `<b>` 是行内元素，但里面装的是 `<p>`、`<ul>`。按行内处理的话，行内渲染遇到块级子节点会直接跳过，整篇内容就凭空消失了。
    /// 这种场合它只是一层**透明的壳**，该按容器往下走。
    private static func containsBlockChild(_ element: Element) -> Bool {
        for child in element.getChildNodes() {
            guard let childElement = child as? Element else { continue }
            if blockTags.contains(childElement.nodeName().lowercased()) { return true }
        }
        return false
    }

    /// 引用块：每一行前面补 `> `。
    ///
    /// ### 为什么块之间用一个 `>` 空行连起来，而不是空行
    /// 引用里有多段、或者套着一层引用时，中间空一行就**跳出引用**了：
    /// ```
    /// > 外层引用← 空行，后面的内容已经不属于这个引用 > > 内层引用
    /// ```
    /// 中间补一行只有一个 `>` 的空引用行，整块才一直待在引用里。
    private func blockquote(_ element: Element, prefix: String) -> [String] {
        let blocks = renderChildren(element, prefix: prefix + "> ")
        guard !blocks.isEmpty else { return [] }
        return [blocks.joined(separator: "\n" + prefix + ">" + "\n")]
    }

    /// 定义列表：`<dt>` 当小标题加粗，`<dd>` 用 Pandoc 那套 `: ` 缩进
    private func definitionList(_ element: Element, prefix: String) -> [String] {
        var blocks: [String] = []
        for child in Array(element.children()) {
            let tag = child.nodeName().lowercased()
            let text = Self.escapeLineStarts(in: trimmedInline(of: child))
            guard !text.isEmpty else { continue }
            switch tag {
            case "dt": blocks.append(prefix + "**" + text + "**")
            case "dd": blocks.append(prefix + ": " + text)
            default: blocks.append(contentsOf: renderChildren(child, prefix: prefix))
            }
        }
        return blocks
    }

    // MARK: 列表

    /// 一个列表整体算一个块：行与行之间**不**插空行（插了就变成「松散列表」，段间距会变大）
    private func list(_ element: Element, prefix: String) -> [String] {
        let ordered = element.nodeName().lowercased() == "ol"
        var number = Self.startNumber(of: element)

        var lines: [String] = []
        for child in Array(element.children()) where child.nodeName().lowercased() == "li" {
            let marker = ordered ? "\(number). " : "- "
            number += 1
            lines.append(contentsOf: listItem(child, marker: marker, prefix: prefix))
        }
        return lines.isEmpty ? [] : [lines.joined(separator: "\n")]
    }

    /// `<ol start="3">` 从几开始数。属性是空的（浏览器常写成 `<ol start='' >`）就当 1
    private static func startNumber(of element: Element) -> Int {
        guard let raw = try? element.attr("start"),
              let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 1
        }
        return value
    }

    /// 一个列表项。
    ///
    /// ### 缩进为什么按「标记的宽度」
    /// ```
    /// - 一级
    ///   接着写            ← 2 个空格，和 "- " 对齐，才不会跳出列表
    /// - 一级
    ///   - 二级            ← 子列表再退 2 格
    /// ```
    private func listItem(_ element: Element, marker: String, prefix: String) -> [String] {
        let indent = String(repeating: " ", count: marker.count)
        let fullMarker = prefix + marker + taskMarker(for: element)

        var lines: [String] = []
        var inline = ""

        func flush() {
            guard !inline.isEmpty else { return }
            let pieces = Self.paragraphLines(inline)
            guard let first = pieces.first else { return }
            lines.append(fullMarker + Self.escapeLineStarts(in: first))
            for rest in pieces.dropFirst() {
                lines.append(prefix + indent + Self.escapeLineStarts(in: rest))
            }
            inline = ""
        }

        for child in element.getChildNodes() {
            // ⚠️ 浏览器复制列表时几乎总是 `<li><p>内容</p></li>`：`<p>` 是块级元素，按块处理会把内容甩到下一行，变成 "- \n    内容" —— 很难看。
            // 所以「还没攒下任何内容」时，第一个 `<p>` 直接当行内接在标记后面
            if inline.isEmpty, lines.isEmpty,
               let childElement = child as? Element,
               childElement.nodeName().lowercased() == "p" {
                inline += inlineText(of: childElement)
                continue
            }
            if let produced = renderBlock(child, prefix: prefix + indent) {
                flush()
                lines.append(contentsOf: produced)
            } else if let text = renderInline(child) {
                inline += text
            }
        }
        flush()

        // 空列表项也留一个标记，不然整项就凭空消失了
        return lines.isEmpty ? [fullMarker] : lines
    }

    /// 任务列表：`<li><input type="checkbox" checked>已完成</li>` → `- [x] `
    private func taskMarker(for element: Element) -> String {
        guard let inputs = try? element.select("input") else { return "" }
        for input in inputs {
            guard let type = try? input.attr("type"), type.lowercased() == "checkbox" else { continue }
            return input.hasAttr("checked") ? "[x] " : "[ ] "
        }
        return ""
    }

    // MARK: 表格

    /// GFM 表格。一个 `<th>` 都没有时补一行空表头 —— CommonMark 的表格**必须**有表头行
    private func table(_ element: Element, prefix: String) -> [String] {
        guard let rows = try? element.select("tr"), !Array(rows).isEmpty else { return [] }

        var headerCells: [String] = []
        var bodyRows: [[String]] = []

        for row in rows {
            guard let cells = try? row.select("th, td"), !Array(cells).isEmpty else { continue }
            let texts = Array(cells).map { Self.tableCell(inlineText(of: $0)) }
            let firstIsHeader = Array(cells).first?.nodeName().lowercased() == "th"
            if headerCells.isEmpty && firstIsHeader {
                headerCells = texts
            } else {
                bodyRows.append(texts)
            }
        }

        let columnCount = max(headerCells.count, bodyRows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return [] }
        if headerCells.isEmpty {
            headerCells = Array(repeating: "", count: columnCount)
        }

        var lines: [String] = []
        lines.append(prefix + Self.rowLine(headerCells.padded(to: columnCount)))
        lines.append(prefix + Self.rowLine(Self.delimiterCells(for: element, columnCount: columnCount)))
        for row in bodyRows {
            lines.append(prefix + Self.rowLine(row.padded(to: columnCount)))
        }
        return [lines.joined(separator: "\n")]
    }

    /// `| a | b |`
    private static func rowLine(_ cells: [String]) -> String {
        "| " + cells.joined(separator: " | ") + " |"
    }

    /// 单元格里的 `|` 必须转义，不然一列会裂成两列
    private static func tableCell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }

    /// 分隔行：按表头单元格的对齐方式给 `:---` / `:---:` / `---:`
    private static func delimiterCells(for table: Element, columnCount: Int) -> [String] {
        guard let headerRow = Array((try? table.select("tr")) ?? Elements()).first,
              let cells = try? headerRow.select("th, td") else {
            return Array(repeating: "---", count: columnCount)
        }
        var marks: [String] = []
        for cell in cells {
            marks.append(alignmentMarks[alignment(of: cell)] ?? "---")
        }
        return marks.padded(to: columnCount, filler: "---")
    }

    /// 对齐方式：优先看 `align` 属性，再看 `style="text-align:..."`
    private static func alignment(of cell: Element) -> String {
        if let value = try? cell.attr("align"), !value.isEmpty { return value.lowercased() }
        let style = ((try? cell.attr("style")) ?? "").lowercased()
        if let range = style.range(of: "text-align:\\s*([a-z]+)", options: .regularExpression),
           let name = style[range].split(separator: ":").last {
            return String(name)
        }
        return ""
    }

    // MARK: 代码块

    /// `<pre><code class="language-swift">…</code></pre>` → 带语言标识的围栏代码块
    private func fencedCode(_ element: Element, prefix: String) -> [String] {
        // 代码里的空白是有意义的，所以取**原始文本**，不做任何规范化
        let code = rawText(of: element).trimmingCharacters(in: .newlines)
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let fence = Self.fence(for: code)
        var lines: [String] = [prefix + fence + Self.language(of: element)]
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(prefix + String(line))
        }
        lines.append(prefix + fence)
        return [lines.joined(separator: "\n")]
    }

    /// 围栏要多长：比内容里最长的一串反引号再多一个，不然代码里的 ``` 会提前把块关掉
    private static func fence(for code: String) -> String {
        var longest = 0
        var current = 0
        for character in code {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return String(repeating: "`", count: max(longest + 1, 3))
    }

    /// 语言标识：`language-xxx` / `lang-xxx` / `highlight-source-xxx` / `lang="xxx"`
    private static func language(of pre: Element) -> String {
        let code = try? pre.select("code").first()
        let candidates = [(try? code?.attr("class")), (try? code?.attr("lang")),
                          (try? pre.attr("class")), (try? pre.attr("lang"))]
        let markers = ["language-", "lang-", "highlight-source-", "highlight-"]
        for candidate in candidates.compactMap({ $0 }) where !candidate.isEmpty {
            for part in candidate.split(separator: " ") {
                for marker in markers where part.hasPrefix(marker) {
                    let value = String(part.dropFirst(marker.count))
                    // 空的（比如 `class="language-"`）就别输出了，纯围栏代码块更干净
                    return value.isEmpty ? "" : value
                }
            }
        }
        return ""
    }

    /// 把节点下面所有文本**原样**拼起来（不规范化空白）—— 代码块专用。
    ///
    /// ### ⚠️ 为什么用 `getWholeText()` 而不是 `text()`
    /// SwiftSoup 的 `text()` 会先把空白规范化一遍（`normaliseWhitespace`），换行全变成空格 —— 用它取代码会得到「一整行挤在一起」的结果。
    /// `getWholeText()` 才是原文，换行和缩进都还在。
    private func rawText(of node: Node) -> String {
        if let text = node as? TextNode { return text.getWholeText() }
        var output = ""
        for child in node.getChildNodes() {
            output += rawText(of: child)
        }
        return output
    }

    // MARK: 行内

    /// 把 `node` 当行内元素渲染。它是块级元素就返回 `nil`（交给 `renderBlock`）
    private func renderInline(_ node: Node) -> String? {
        if let text = node as? TextNode {
            return Self.escape(Self.normalize(text.text()))
        }
        // 注释、`<!DOCTYPE>` 之类既不是元素也不是文本 → 直接跳过
        guard let element = node as? Element else { return nil }

        let tag = element.nodeName().lowercased()
        guard !Self.blockTags.contains(tag) else { return nil }
        // 里面装着块级内容 → 交给 `renderBlock` 当透明的壳处理（原因见 `containsBlockChild`）
        guard !Self.containsBlockChild(element) else { return nil }
        let inner = inlineText(of: element)

        switch tag {
        case "br":
            // 硬换行：行尾一个反斜杠 + 换行（markdown 里这就是「这里要断行」）
            return "\\\n"
        case "img":
            return Self.image(element)
        case "a":
            return Self.link(element, inner: inner)
        case "code", "kbd", "samp", "tt":
            // ⚠️ 代码里的内容是**字面量**，不能用上面那套带转义的 `inner`：
            // 反引号会被转成 \`，`` `code` `` 就出不来了
            return Self.inlineCode(Self.plainText(of: element))
        case "sup":
            return Self.superscript(element, inner: inner)
        case "sub":
            // Markdown 没有下标，保留成行内 HTML
            return inner.isEmpty ? "" : "<sub>" + inner + "</sub>"
        case "mark":
            return Self.wrap("==", inner)
        case "strong", "b":
            // Google Docs 会把整篇包在 `<b style="font-weight:normal">` 里 ——光看标签会全篇加粗，所以得看一眼 style
            return Self.isBold(element) ? Self.wrap("**", inner) : inner
        case "em", "i", "cite", "dfn", "var":
            return Self.wrap("*", inner)
        case "del", "s", "strike":
            return Self.wrap("~~", inner)
        case "input", "button", "select", "textarea", "option", "label", "wbr":
            // 复选框已经在 `taskMarker` 里用掉了；别的控件在 markdown 里没有对应物
            return ""
        default:
            // `<span style="font-weight:700">` 这种把样式写在属性里的（Word 最爱这么干）
            return Self.styled(element, inner: inner)
        }
    }

    /// 一个元素下面所有行内内容拼起来
    private func inlineText(of element: Element) -> String {
        var output = ""
        for child in element.getChildNodes() {
            output += renderInline(child) ?? ""
        }
        return output
    }

    /// 一个元素下面所有**文本**拼起来，不做 markdown 转义 —— 行内代码 / 图片 alt 专用
    private static func plainText(of node: Node) -> String {
        if let text = node as? TextNode { return normalize(text.text()) }
        var output = ""
        for child in node.getChildNodes() {
            output += plainText(of: child)
        }
        return output
    }

    /// 行内代码：内容里有反引号就加长围栏（`` `a` ``）
    private static func inlineCode(_ content: String) -> String {
        guard !content.isEmpty else { return "" }
        guard content.contains("`") else { return "`" + content + "`" }
        var longest = 0
        var current = 0
        for character in content {
            if character == "`" { current += 1; longest = max(longest, current) } else { current = 0 }
        }
        let fence = String(repeating: "`", count: longest + 1)
        let padding = content.hasPrefix("`") || content.hasSuffix("`") ? " " : ""
        return fence + padding + content + padding + fence
    }

    /// 链接。文字和地址一模一样时输出 `<地址>`（自动链接，更短也更好读）
    private static func link(_ element: Element, inner: String) -> String {
        let href = ((try? element.attr("href")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = inner.trimmingCharacters(in: .whitespaces).isEmpty
            ? escape(href)
            : inner.trimmingCharacters(in: .whitespaces)
        // 空地址 / 页内锚点：地址没有意义，只留文字
        guard !href.isEmpty, !href.hasPrefix("#") else { return text }
        if text == href { return "<" + href + ">" }

        // 带空格或括号的地址要用尖括号包起来，否则解析会在空格 / 右括号处断掉
        let needsBrackets = href.contains(" ") || href.contains("(") || href.contains(")")
        let destination = needsBrackets ? "<" + href + ">" : href
        let title = ((try? element.attr("title")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty
            ? "[" + text + "](" + destination + ")"
            : "[" + text + "](" + destination + " \"" + title.replacingOccurrences(of: "\"", with: "'") + "\")"
    }

    /// 图片。`data:` 开头的（网页内嵌图）照样输出 —— 悄悄丢掉内容的代价更大
    private static func image(_ element: Element) -> String {
        let source = ((try? element.attr("src")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return "" }
        let alt = ((try? element.attr("alt")) ?? "").replacingOccurrences(of: "\n", with: " ")
        let needsBrackets = source.contains(" ") || source.contains("(") || source.contains(")")
        let destination = needsBrackets ? "<" + source + ">" : source
        let title = ((try? element.attr("title")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty
            ? "![" + alt + "](" + destination + ")"
            : "![" + alt + "](" + destination + " \"" + title.replacingOccurrences(of: "\"", with: "'") + "\")"
    }

    /// 上标：网页里的脚注通常长这样 `<sup class="md-footnote"><a href="#fn-1">1</a></sup>`
    private static func superscript(_ element: Element, inner: String) -> String {
        guard !inner.isEmpty else { return "" }
        let className = ((try? element.attr("class")) ?? "").lowercased()
        if className.contains("footnote") || className.contains("fn") {
            return "[^" + inner + "]"
        }
        return "<sup>" + inner + "</sup>"
    }

    /// `<span style="font-weight:700">` 这类把样式写在属性里的，按样式补 `**` / `*` / `~~`
    private static func styled(_ element: Element, inner: String) -> String {
        let style = ((try? element.attr("style")) ?? "").lowercased()
        guard !style.isEmpty else { return inner }
        var output = inner
        if style.contains("line-through") { output = wrap("~~", output) }
        if style.contains("italic") { output = wrap("*", output) }
        if isBold(element) { output = wrap("**", output) }
        return output
    }

    /// 加不加粗：看 style 里的 `font-weight`。
    ///
    /// ⚠️ 遇到 `font-weight:normal`（Google Docs 那层 `<b>`）要**否掉**标签自带的粗体，不然整篇都会变成 `**`。没写 style 就按标签本身算（`<strong>` 默认加粗）。
    private static func isBold(_ element: Element) -> Bool {
        let style = ((try? element.attr("style")) ?? "").lowercased()
        guard !style.isEmpty else { return true }
        if style.contains("font-weight:normal") { return false }
        if let range = style.range(of: "font-weight:\\s*(\\d+)", options: .regularExpression),
           let digits = style[range].split(separator: ":").last,
           let weight = Int(digits) {
            return weight >= 600
        }
        return style.contains("font-weight:bold")
    }

    /// 给一段文字套上标记。内容是空的就别套（`****` 这种空标记很难看）
    private static func wrap(_ mark: String, _ content: String) -> String {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return mark + content + mark
    }

    // MARK: 文本处理

    /// 空白规范化：换行、制表符、不换行空格一律压成一个普通空格。
    ///
    /// 浏览器为了排版会在 HTML 里插满换行和缩进；markdown 里一个换行就可能是一段的结束，不压掉的话一句好端端的话会被切成好几段（软换行本来就该是空格）。
    /// ⚠️ 两端的空格都要留着
    /// - `<p>这是一个 <span>inline</span> 元素</p>`：空格分别在上一个文本节点的**末尾**
    ///   和下一个文本节点的**开头**，两头任何一个丢掉都会变成「这是一个inline元素」。
    /// - 多出来的空格在每行收尾时会被 `paragraphLines` 裁掉，不会留在结果里。
    private static func normalize(_ text: String) -> String {
        var output = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace || character == "\u{00A0}" {
                pendingSpace = true
                continue
            }
            if pendingSpace { output.append(" ") }
            pendingSpace = false
            output.append(character)
        }
        if pendingSpace { output.append(" ") }
        return output
    }

    /// 一段行内内容，两端不留白（标题文字、链接文字这类「整段就是一个词」的场合用）
    private func trimmedInline(of element: Element) -> String {
        inlineText(of: element).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 转义 markdown 的记号字符。
    ///
    /// ⚠️ 只对**文本节点**做：代码块里的反引号、链接地址里的字符都是字面量，转义了反而错。
    private static func escape(_ text: String) -> String {
        var output = ""
        for character in text {
            switch character {
            case "\\", "`", "*", "_", "[", "]":
                output.append("\\")
                output.append(character)
            default:
                output.append(character)
            }
        }
        return output
    }

    /// 一行开头是 `#` `-` `+` `>` `=` `|` 会被 markdown 当成标题 / 列表 / 引用 / 表格，正文里真有这种开头就转义掉
    private static func escapeLineStarts(in text: String) -> String {
        let triggers: Set<Character> = ["#", "-", "+", ">", "=", "|"]
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                guard let first = line.first, triggers.contains(first) else { return String(line) }
                return "\\" + String(line)
            }
            .joined(separator: "\n")
    }

    /// 把攒下来的一段行内文本切成若干行（`<br>` 已经变成「行尾反斜杠 + 换行」了）
    private static func paragraphLines(_ inline: String) -> [String] {
        inline.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 一段行内文本 → 若干带前缀的行（空行丢掉，所以「什么都没有」时返回空数组）
    private static func paragraph(_ inline: String, prefix: String) -> [String] {
        paragraphLines(inline).map { prefix + escapeLineStarts(in: $0) }
    }

    /// 块之间用一个空行隔开；连续三个以上换行压回两个；首尾不留白
    private static func assemble(_ blocks: [String]) -> String {
        var text = blocks.joined(separator: "\n\n")
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 数组补位

private extension Array where Element == String {

    /// 把一行补到 `count` 列（HTML 里一行的 `<td>` 个数常常参差不齐）
    func padded(to count: Int, filler: String = "") -> [String] {
        guard self.count < count else { return self }
        return self + Array(repeating: filler, count: count - self.count)
    }
}
