//
//  MarkdownMermaidRenderer.swift
//  MarkdownEditorHy4
//
//  Mermaid 图的渲染接口（```mermaid 围栏代码块）
//
//  ### 为什么这里只有协议、没有实现
//  和 `MarkdownMathRenderer` 是同一个理由：`MarkdownEditor` 是要单独开源给别人用的库，而「把 Mermaid 源码画成一张图」这件事只能靠第三方库（本项目用的是 MermaidKit）。
//  库里直接 `import MermaidKit` 的话，**所有**用这个库的人都被迫拖上这个依赖 ——哪怕他一张图都不画。
//
//  所以沿用代码高亮和公式那两套已经被验证过的做法：**库只定义接口，实现由宿主 App 注入**。
//
//  ### 和数学公式那条路的差别
//  公式是「夹在文字里的 `$...$` 换成一个字符位」，Mermaid 是「整段围栏代码块换成一块图」。
//  差别只在**源码长度映射**上：`RenderedFragment.attachment` 本来就支持「占 1 个字符位、吃掉源码里 N 个字符」，所以库层不需要为它新增任何能力，直接调用即可。
//

import UIKit

/// 一次 Mermaid 渲染请求：画一张图需要的所有信息。
///
/// ### 为什么给的是几个真实颜色，而不是「是不是深色」这个布尔
/// `MarkdownTheme` 里**根本没有「深色」这个概念** —— 配色表是一张覆盖表，用户可以给一份浅色机身配一套深色文档配色，机身外观和文档配色是两回事。
/// 凭空造一个布尔出来只会造错：图明明该用文档那套色，却跟着系统外观走了。
/// 把主题里那几个真实颜色给全，让实现自己去挑谁对应谁 ——「引擎要的外观槽位」和「编辑器主题的字段」本来就不是一一对应的。
struct MarkdownMermaidRequest {
    /// 围栏代码块里头的正文（**不含** ``` 那两行），比如 "flowchart TD\n  A --> B"
    var source: String
    /// 图的最大宽度（点）。和表格同一条算法：容器宽度减去缩进和内边距
    var maxWidth: CGFloat
    /// 正文颜色 —— 图里的文字跟着它走
    var textColor: UIColor
    /// 页面背景色。MermaidKit 画出来的是**透明底**位图，所以这个颜色有两个用处：
    /// 一是让引擎给箭头、边标签这些「挖洞」的地方填对底色（填白的话，米色 / 深色主题上会露出一块块白斑），二是宿主拿它判断该用浅色图还是深色图
    var backgroundColor: UIColor
    /// 强调色（编辑器里就是链接色）—— 图里的节点填充、标记点这些「起强调作用」的地方用它，图才和文档整体配色是一家人
    var accentColor: UIColor
    /// 分隔线色（编辑器里就是列表分隔线那个灰）—— 图里的细线：网格、生命线、区域框的分隔
    var separatorColor: UIColor
    /// 正文字号 —— **意图**是让图里的文字量级跟着正文走，和周围内容视觉一致。
    ///
    /// ⚠️ **实现方可以不理会它**：MermaidKit 就只有 `image(source:theme:spacing:)` 这么一个入口，**没有字号参数**，
    /// 所以本项目这条路目前画出来的图，字有多大完全由引擎自己定，跟正文字号无关（图在屏幕上的实际大小另由 `MermaidAttachment` 缩放决定）。
    /// 留着这个字段是为了两件事：协议不用等引擎补齐再改一次；以及**它仍然要进缓存键** —— 万一将来某个实现真的用了它，
    /// 少算它就会「改了字号还拿到旧图」。代价是引擎用不上时白换一次缓存（每张几毫秒），可以接受，别为了省这点把协议改歪。
    var fontSize: CGFloat
}

/// 把 Mermaid 源码画成一张图的渲染器。
///
/// 由宿主 App 实现后注入给 `MarkupToAttributedRenderer.mermaidRenderer`。
/// 不注入的话，```mermaid 围栏块就按普通代码块显示（灰底 + 源码原文），功能降级但**不会坏**。
///
/// ### 实现者要注意两件事
/// 1. **这个方法会在渲染的紧循环里被调用**（滚动、换主题、拖字号滑块都会整篇重排），
///    一定要缓存结果 —— 同一段源码在来回切主题、重排时会被反复问到。
///    缓存键至少要把 `source` / `maxWidth` / 那几个颜色 / `fontSize` 都算进去 —— 少算一个，换个主题就会拿到上一套配色画出来的旧图。
/// 2. **返回 `nil` 表示「这段 Mermaid 画不出来」**（语法错、引擎不认识这种图…）。
///    调用方会退化成显示源码原文，所以**不要**为了兜底返回一张「错误提示图」——用户正在敲半截 `flowchart T`，满屏红框才是最差的体验。
///    这条规矩和 `MarkdownMathRenderer` 一字不差。
protocol MarkdownMermaidRenderer: AnyObject {

    /// 把一段 Mermaid 源码画成图。
    /// - returns: 画好的图（尺寸就是它在屏幕上的实际大小）；画不出来返回 `nil`
    func image(for request: MarkdownMermaidRequest) -> UIImage?

    /// 把一段 Mermaid 源码画成 **SVG**（导出 HTML 用）。
    ///
    /// 矢量图放到多大都不糊，而且比内联一张 PNG（base64）小十倍以上 ——导出给别人看的网页用这条更划算。所以导出 HTML 时优先走它。
    ///
    /// - returns: 一段能直接内联进 HTML 的 `<svg>…</svg>`（**不带** `<?xml?>` 声明）；
    ///   画不出来返回 `nil`，调用方会退回 `<pre><code>` 显示源码原文
    func svg(for request: MarkdownMermaidRequest) -> String?
}

extension MarkdownMermaidRenderer {

    /// 默认不给 SVG：这样只做位图的实现（或者测试里的假引擎）不用被逼着写一个空方法。
    /// 代价是导出 HTML 时那个 `mermaid` 块会退回显示源码 —— 功能降级，但不会坏。
    func svg(for request: MarkdownMermaidRequest) -> String? { nil }
}

/// 哪些围栏语言会被画成图。
///
/// 抽出来是因为有**两个**消费方要认同一套语言：编辑器那条路（`MarkupToAttributedRenderer`）
/// 和导出 HTML 那条路（`MarkdownHTMLRenderer`）。两边各抄一份的话，将来加一门语言（DOT、SQL DDL…）必然漏掉一处。
enum MarkdownMermaidLanguages {

    /// 只收 Mermaid 自己。MermaidKit 的 `format` 参数另外还认 DOT / SQL DDL / git log，真要做的时候在这里加一项、并在 `MarkdownMermaidRequest` 上带上格式即可。
    static let all: Set<String> = ["mermaid", "mmd"]

    /// 这个围栏语言算不算 Mermaid。
    ///
    /// 语言标记不区分大小写（```Mermaid 也认）；顺手把两头空白去掉，免得 ``` mermaid 这种写法（语言前面多一个空格）漏掉。
    static func matches(_ language: String?) -> Bool {
        guard let language else { return false }
        return all.contains(language.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
