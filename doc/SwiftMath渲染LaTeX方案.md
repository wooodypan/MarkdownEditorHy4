SwiftMath渲染LaTeX方案

## 结论先行

**用 `SwiftMath`（`iosMath` 的 Swift 移植版）——纯 Core Graphics/Core Text 原生排版，不经过 WebView，不经过 JavaScriptCore，把公式渲染结果封装进你已有的 `NSTextAttachmentViewProvider` 附件体系（复用你架构文档第 8 节图片/表格那一套机制），不要用 MathJax/KaTeX 这类需要跑在 WebView 里的方案。** 这个选型和你的代码高亮选型（Tree-sitter 而非 Highlightr）是完全对称的判断——两次的性能瓶颈都是"要不要经过一层跨运行时桥接"，答案也应该一致。

## 为什么排除 MathJax / KaTeX（WebView 路线）

- 这两个都是 JS 库，要在 iOS 里用，只能塞进 `WKWebView` 渲染，或者像 Highlightr 那样通过 `JavaScriptCore` 跑一遍拿到结果再转换。前者每个公式一个 WebView 实例的开销极高（WebView 初始化本身就有几十毫秒级的固定成本，一篇文档里有十几个公式就是十几个 WebView，内存和渲染都会成为明显瓶颈）；后者虽然比 WebView 省一些，但还是有跨运行时调用的固定开销（这正是 Highlightr 那次"50ms/500行"数字的来源）。
- 更本质的问题：WebView/JS 产出的是**图片或 HTML 渲染结果**，塞进你的 TextKit 2 附件体系时要额外转成 `UIImage` 或者自己再走一遍 HTML 解析，这条链路比"直接拿到一个原生 `UIView`"要绕得多。

## 为什么是 SwiftMath 而不是 iosMath 本身

两者是同一套代码（`SwiftMath` 是 `iosMath` 的纯 Swift 移植，排版算法一致），选 `SwiftMath` 主要是工程上的考虑：`iosMath` 是 Objective-C 实现，`SwiftMath` 省掉桥接 Objective-C 的模块边界配置；且 `SwiftMath` 在原版基础上做了一些字符集补充和 bug 修复。两者性能特征相同——都是**纯 CoreText 字形排版**，没有 WebView、没有 JS，是当前 iOS 生态里渲染 LaTeX 最快的开源方案。

## 具体架构：复用图片附件的模式，不要另起一套

这一步是关键——LaTeX 公式和你已经做过的"图片""表格"是**同一类问题**（需要真正的 View 渲染、不是靠字符属性能表达的内容），所以不需要发明新机制，直接照搬第 8 节的附件模式：

### 1. 渲染阶段：识别 LaTeX 语法，生成附件

swift-markdown 本身不认识 LaTeX 语法（`$...$`/`$$...$$` 不是 CommonMark/GFM 标准语法），这部分需要你自己在 inline 解析结果上做一层轻量的二次扫描：

```swift
mutating func visitText(_ text: Text) -> NSAttributedString {
    let raw = text.string
    // 用一个简单的正则/手写扫描器识别 $...$（行内）和 $$...$$（块级）,
    // 未匹配到的部分走原有的纯文本渲染逻辑——不影响其他 inline 处理
    guard raw.contains("$") else {
        return NSAttributedString(string: raw, attributes: [
            .font: theme.typography.bodyFont, .foregroundColor: theme.colors.text,
        ])
    }
    return renderTextWithLatexSegments(raw)
}

private func renderTextWithLatexSegments(_ raw: String) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for segment in LatexSegmentScanner.scan(raw) {
        switch segment {
        case .plain(let s):
            result.append(NSAttributedString(string: s, attributes: [
                .font: theme.typography.bodyFont, .foregroundColor: theme.colors.text,
            ]))
        case .inlineMath(let latex, let literalText):
            result.append(renderMathAttachment(latex: latex, literalText: literalText, isBlock: false))
        case .blockMath(let latex, let literalText):
            result.append(renderMathAttachment(latex: latex, literalText: literalText, isBlock: true))
        }
    }
    return result
}
```

### 2. 附件本身：`SwiftMath` 的 `MTMathUILabel` 直接就是一个 `UIView`

这一点是这个方案性能好、实现也简单的核心原因——`MTMathUILabel` 本身就是 `UIView` 子类，不需要你自己写排版逻辑，直接塞进 `NSTextAttachmentViewProvider`：

```swift
final class MarkdownLatexAttachment: NSTextAttachment {
    let latex: String
    let isBlock: Bool
    let theme: MarkdownTheme

    override func viewProvider(for parentView: UIView?, location: NSTextLocation,
                                 textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        MarkdownLatexAttachmentViewProvider(textAttachment: self, parentView: parentView,
                                              textLayoutManager: textContainer?.textLayoutManager, location: location)
    }
}

final class MarkdownLatexAttachmentViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        let attachment = textAttachment as! MarkdownLatexAttachment
        let label = MTMathUILabel()
        label.latex = attachment.latex
        label.textColor = attachment.theme.colors.text
        label.fontSize = attachment.isBlock ? attachment.theme.typography.bodyFont.pointSize * 1.1
                                             : attachment.theme.typography.bodyFont.pointSize
        label.labelMode = attachment.isBlock ? .display : .text   // display 模式用于块级公式(居中、更大间距)
        view = label
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any],
                                     location: NSTextLocation, textContainer: NSTextContainer?,
                                     proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        let label = view as! MTMathUILabel
        let intrinsicSize = label.intrinsicContentSize   // SwiftMath 内部已经算好了排版尺寸,直接拿来用
        return CGRect(origin: .zero, size: intrinsicSize)
    }
}
```

**这里几乎不需要额外的性能优化代码**——因为公式排版计算本身就发生在 `MTMathUILabel` 内部（用的是 CoreText 字形排版，本身就很快），你不需要像图片那样处理"异步加载"（没有网络请求这一环），也不需要像代码高亮那样处理"超长内容分帧渲染"（公式通常很短，一次性排版的开销可以忽略）。

### 3. 语法弱化 + 全字符保留：延续你已经确立的统一模式

```swift
private func renderMathAttachment(latex: String, literalText: String, isBlock: Bool) -> NSAttributedString {
    let attachment = MarkdownLatexAttachment(latex: latex, isBlock: isBlock, theme: theme)
    let attachmentString = NSMutableAttributedString(attachment: attachment)

    if isBlock {
        // 块级公式:附件独占一行,原始 $$...$$ 源码弱化显示在下方——与图片/表格是同一个模式
        attachmentString.addAttribute(.paragraphStyle, value: theme.paragraphStyle(for: .mathBlock),
                                        range: NSRange(location: 0, length: attachmentString.length))
        let result = NSMutableAttributedString()
        result.append(attachmentString)
        result.append(NSAttributedString(string: "\n", attributes: [.markdownSynthetic: true]))
        result.append(NSAttributedString(string: literalText, attributes: [
            .font: theme.typography.codeFont, .foregroundColor: theme.colors.syntaxMarkerDimmed,
        ]))
        return result
    } else {
        // 行内公式:附件直接嵌在文字中间,原始 $...$ 字符透明遮盖(与任务列表复选框是同一个模式)
        let literalRun = NSMutableAttributedString(string: literalText, attributes: [
            .foregroundColor: UIColor.clear, .font: theme.typography.bodyFont,
        ])
        literalRun.insert(attachmentString, at: 0)  // 附件盖在文字前面,精确宽度对齐见下方说明
        return literalRun
    }
}
```

**行内公式**（`$x^2$`）复用你在任务列表复选框那一轮定下的"做法 A"（透明文字 + 附件覆盖，字符序列长度不变），**块级公式**（`$$...$$`）复用图片的"附件在上、弱化源码在下"模式——**这两种模式你已经在架构里各自验证过一次了，LaTeX 不需要发明第三种，只是分别套用到行内/块级两种场景**。

## 要不要做成协议（复用你上一轮学到的判断标准）

用你自己总结的检验表过一遍：

| 检验项 | LaTeX 渲染 |
|---|---|
| 存在多种互斥的合理实现,且真的可能换? | 弱存在——理论上 `SwiftMath`/`MathJax-WebView`/未来苹果可能出的原生公式 API 都是候选,但目前 `SwiftMath` 是压倒性最优选择(唯一的纯原生方案),换的可能性远低于代码高亮(代码高亮天然有"要不要支持正则/模糊搜索"这类确定会发生的演进) |
| 抽象出来的协议参数会不会泄露实现细节? | 如果做协议,返回类型该是什么？公式排版结果本质就是"一个 View"(CoreText 排版出的字形位置),不像代码高亮能提炼出"SyntaxRole"这种中性词汇表,很难在不泄露 UIKit/CoreText 细节的前提下做出有意义的中性接口 |
| 只有你自己一个实现,且预期长期如此? | 是——数学公式排版是一个高度专业化的领域,不像"查找算法"那样新手也能写一个可用的默认实现兜底,做协议本身不会带来"新手也能实现一个"的收益 |

**结论：不建议做协议，直接依赖 `SwiftMath`。** 和代码高亮那次的关键区别在于——代码高亮天然有"简单实现 vs 精确实现"的光谱（哪怕自己写个正则都能凑合用），LaTeX 排版没有这个光谱，`SwiftMath` 已经是"唯一靠谱的原生选项"，协议在这里只会增加一层没有实际替换收益的抽象，属于你自己总结的"值不值得解耦"判断标准里明确落在"不值得"一侧的情况。

## 和现有架构的复用关系一览

| 需要的能力 | 复用哪部分已有设计 |
|---|---|
| 附件承载真正的排版 View | 与图片、表格、代码复制按钮同一套 `NSTextAttachmentViewProvider` 机制 |
| 块级公式:源码保留+弱化+附件在上方 | 与 `visitImage`/`visitTable` 完全一致的模式 |
| 行内公式:字符透明+附件覆盖 | 与任务列表复选框完全一致的模式(做法 A) |
| 复制时不带公式渲染结果 | 块级走 `markdownSynthetic` 换行标记(与图片一致);行内因字符本身未被删除(与复选框一致),两者都不需要给 `DisplaySourceMap` 新增规则 |
| 增量渲染 | 含 LaTeX 的段落依然是一个 `MarkdownBlock`,编辑公式内容按现有的"编辑发生在段落内部→重渲染该段落"规则处理,无需新增 11.2 节的边界规则(LaTeX 语法不改变 CommonMark 的块边界判定) |
| Theme 统一管理样式 | 在 `MarkdownTheme` 里新增一个 `Math` 子结构体(字号倍率、颜色、块级上下间距) |

需要在 `MarkdownTheme` 里补的配置：

```swift
struct Math: Equatable {
    var inlineFontScale: CGFloat = 1.0
    var blockFontScale: CGFloat = 1.15
    var blockSpacingBefore: CGFloat = 12
    var blockSpacingAfter: CGFloat = 12
    var errorColor: UIColor = .systemRed   // SwiftMath 解析失败时(比如用户输错 LaTeX 语法)的兜底显示色
}
```

## 一个容易被忽略但影响体验的细节：解析失败的兜底

`SwiftMath` 对非法 LaTeX 语法会抛出解析错误（`MTMathUILabel` 有 `parseError` 结果），因为你的编辑场景里用户会**实时输入不完整的公式**（比如正在打 `\frac{` 还没打完），必须处理"当前是无效 LaTeX"这个高频状态：

```swift
extension MarkdownLatexAttachmentViewProvider {
    override func loadView() {
        let label = MTMathUILabel()
        label.latex = attachment.latex
        if let error = label.error {
            // 不要让附件消失或崩溃——保留原始源码文字的可见性,
            // 用一个轻量提示(比如公式位置显示错误色的占位符)而不是完全渲染失败
            view = fallbackErrorView(latex: attachment.latex, theme: attachment.theme)
        } else {
            view = label
        }
    }
}
```

结合你增量渲染的机制（第 11 节），**公式输入过程中的中间态**（语法不完整）会频繁触发重渲染，建议给公式渲染单独加一个轻量的防抖（用户停止在公式区域输入 200-300ms 后才触发排版），避免每敲一个字符就重新跑一次 CoreText 排版——这个思路和你在目录组件、查找框那几轮已经用过的"高频事件防抖"是同一个模式，不需要发明新机制。