作者：claude

swift-markdown 有两条路：直接用自带的 `HTMLFormatter`，或者自己写一个 `MarkupVisitor` 输出 HTML。我建议先用前者跑通，遇到定制需求再换成后者。

## 方案一：用自带的 `HTMLFormatter`

```swift
import Markdown

let document = Document(parsing: source)
let html = HTMLFormatter.format(document)
```

`HTMLFormatter` 本身就是基于 `MarkupWalker` 实现的，所以你也可以用 `HTMLFormatter.format(source)` 直接传字符串。它覆盖标题、段落、列表、引用、代码块、表格、行内样式等常规语法。我没有在当前版本里逐一实测，下面几项请你用 fixture 跑一遍确认：

- 任务列表 `[x]` 是否输出为 `<input type="checkbox">`
- 脚注是否有输出
- 图片、链接的 URL 是否做了转义

LaTeX 的 `$...$` 不是 CommonMark 语法，它不会认识，公式会被当成普通文本输出。

## 方案二：自定义 `MarkupVisitor`

以下情况需要自己写：想控制输出标签和 class，要接入脚注、LaTeX 这类扩展，或者要统一转义策略。

```swift
import Markdown

struct HTMLRenderer: MarkupVisitor {
    typealias Result = String

    mutating func defaultVisit(_ markup: any Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    mutating func visitDocument(_ d: Document) -> String { defaultVisit(d) }

    mutating func visitHeading(_ h: Heading) -> String {
        "<h\(h.level)>\(defaultVisit(h))</h\(h.level)>\n"
    }

    mutating func visitParagraph(_ p: Paragraph) -> String {
        "<p>\(defaultVisit(p))</p>\n"
    }

    mutating func visitText(_ t: Text) -> String { escape(t.string) }
    mutating func visitStrong(_ s: Strong) -> String { "<strong>\(defaultVisit(s))</strong>" }
    mutating func visitEmphasis(_ e: Emphasis) -> String { "<em>\(defaultVisit(e))</em>" }
    mutating func visitStrikethrough(_ s: Strikethrough) -> String { "<del>\(defaultVisit(s))</del>" }
    mutating func visitInlineCode(_ c: InlineCode) -> String { "<code>\(escape(c.code))</code>" }
    mutating func visitSoftBreak(_ b: SoftBreak) -> String { "\n" }
    mutating func visitLineBreak(_ b: LineBreak) -> String { "<br>\n" }
    mutating func visitThematicBreak(_ t: ThematicBreak) -> String { "<hr>\n" }

    mutating func visitLink(_ l: Link) -> String {
        "<a href=\"\(escape(l.destination ?? ""))\">\(defaultVisit(l))</a>"
    }

    mutating func visitImage(_ i: Image) -> String {
        "<img src=\"\(escape(i.source ?? ""))\" alt=\"\(escape(i.plainText))\">"
    }

    mutating func visitBlockQuote(_ q: BlockQuote) -> String {
        "<blockquote>\n\(defaultVisit(q))</blockquote>\n"
    }

    mutating func visitCodeBlock(_ c: CodeBlock) -> String {
        let cls = c.language.map { " class=\"language-\(escape($0))\"" } ?? ""
        return "<pre><code\(cls)>\(escape(c.code))</code></pre>\n"
    }

    mutating func visitUnorderedList(_ l: UnorderedList) -> String {
        "<ul>\n\(defaultVisit(l))</ul>\n"
    }

    mutating func visitOrderedList(_ l: OrderedList) -> String {
        "<ol>\n\(defaultVisit(l))</ol>\n"
    }

    mutating func visitListItem(_ item: ListItem) -> String {
        var prefix = ""
        if let box = item.checkbox {
            prefix = "<input type=\"checkbox\" disabled\(box == .checked ? " checked" : "")> "
        }
        return "<li>\(prefix)\(defaultVisit(item))</li>\n"
    }

    // 原始 HTML 的处理策略见下文"安全"一节
    mutating func visitHTMLBlock(_ h: HTMLBlock) -> String { h.rawHTML }
    mutating func visitInlineHTML(_ h: InlineHTML) -> String { h.rawHTML }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

var renderer = HTMLRenderer()
let html = renderer.visit(Document(parsing: source))
```

这个骨架没有处理的几类节点，要按需补上：

- **表格**：`Table`、`Table.Head`、`Table.Body`、`Table.Row`、`Table.Cell`，列对齐在 `table.columnAlignments` 里。
- **脚注**：需要先收集所有 `FootnoteDefinition`，渲染时再统一输出到文末，并给引用加上 `<sup><a href="#fn-1">` 这类锚点。这一步和编辑器里的 `FootnoteIndex` 是同一个思路。
- **LaTeX**：在 `visitText` 里扫描 `$...$` 和 `$$...$$`，输出 `<span class="math">` 并配合 KaTeX 或 MathJax 在页面里渲染。

## 几个容易踩的点

**1. 导出时全量解析，不要复用编辑器的增量块。** 导出是低频操作，直接对 `source` 做一次 `Document(parsing:)` 最简单也最不容易出错。编辑器里那套顶层块缓存是为编辑性能服务的，拿来拼 HTML 反而可能漏掉跨块的内容（比如脚注）。

**2. 转义是安全底线。** 所有来自用户文本的内容（`Text`、`InlineCode`、`CodeBlock`、URL、alt）都必须转义，否则 `<script>` 之类的内容会原样进入页面。

**3. 原始 HTML 要有明确策略。** `HTMLBlock` 和 `InlineHTML` 默认原样输出，如果最终放进 `WKWebView` 预览或分享给别人，这就是 XSS 入口。三种处理方式：

- 完全信任（只给自己用）：原样输出
- 转义成纯文本显示：最安全
- 白名单过滤（只放行少数标签）：需要引入或自己写 sanitizer

**4. 链接协议要过滤。** `[点我](javascript:alert(1))` 的 `destination` 会原样给到你，建议只放行 `http`、`https`、`mailto` 和相对路径。

**5. 图片路径。** `![](sample.png)` 是相对路径，导出成独立 HTML 文件后图片会找不到。要么把图片转成 base64 内联，要么导出时一起复制资源并改写路径。

**6. 包一层完整页面。** 上面输出的只是 body 片段，实际使用时需要包上 `<!DOCTYPE html>`、`<meta charset="utf-8">` 和一份 CSS。如果想让导出效果和编辑器风格一致，可以由 `MarkdownTheme` 生成 CSS，保持"样式只在 Theme 里管理"的原则。

## 怎么选

| 场景 | 建议 |
|---|---|
| 只需要把常规 Markdown 转成可读的 HTML | `HTMLFormatter`，零代码 |
| 需要脚注、LaTeX、自定义 class、统一转义 | 自定义 `MarkupVisitor` |
| 需要把 HTML 交给不可信环境展示 | 自定义 `MarkupVisitor`，并配上转义和协议白名单 |

如果你想把这个功能放进编辑器，可以把它做成一个独立的导出模块，输入是 `source: String`，输出是 `String`。它不依赖 `MarkdownTextView` 和 `BlockRenderer`，和之前的 diff 页面是同一种设计。