作者：claude

**优先用 HTML 路径：读取剪贴板里的 `public.html`，用 SwiftSoup 解析成 DOM，再遍历节点生成 Markdown。RTF 只作为没有 HTML 时的兜底。**

不建议走 `NSAttributedString` 中转，原因见下文。

## 1. 为什么 HTML 优先

浏览器（Safari、Chrome）和 Word 复制时，剪贴板通常同时带有多种格式：`public.html`、`public.rtf`/`com.apple.flat-rtfd`、纯文本。

- **HTML 保留语义**：`<h1>`、`<ul>`、`<table>`、`<pre><code>`、`<a>` 都是结构化的，可以直接映射到 Markdown。
- **RTF 只有样式**：标题只是"字号大、加粗"，列表只是带制表符的文本，要靠启发式规则还原，很容易错。

```swift
let pb = UIPasteboard.general
if let data = pb.data(forPasteboardType: "public.html", inItemSet: nil)?.first,
   let html = String(data: data, encoding: .utf8) {
    // HTML 路径
} else if let rtf = pb.data(forPasteboardType: "public.rtf", inItemSet: nil)?.first {
    // 兜底路径
}
```

## 2. 不推荐 `NSAttributedString(html:)` 再转 Markdown

- HTML 导入底层走 WebKit，必须在主线程执行，内容大时会卡顿。
- 转换后语义丢失：标题变成字号，列表变成 `•\t` 文本，代码块变成等宽字体的 run。
- 表格、嵌套列表、任务列表基本无法可靠还原。

## 3. HTML → Markdown 的具体方案

**方案 A（推荐）：SwiftSoup + 自写转换器**
- 纯 Swift，可在后台线程运行，无 WebView 依赖。
- 规则完全可控，便于处理 Word、Google Docs 等来源的脏 HTML。
- 递归遍历节点，按标签输出对应的 Markdown 语法。

**方案 B：Turndown（JS）+ turndown-plugin-gfm**
- 规则成熟，开箱支持 GFM 表格、删除线、任务列表。
- 注意：Turndown 需要 DOM。纯 `JavaScriptCore` 没有 `DOMParser`，要么打包 domino 之类的 DOM 实现，要么放进隐藏的 `WKWebView`（异步，较重）。
- 适合想快速上线、能接受 JS 依赖的场景。

**方案 C：现成的 Swift HTML→Markdown 库**
- 可以评估，但动手前先确认维护状态和对表格、嵌套列表的支持，很多库覆盖不全。

## 4. 来源相关的坑（预处理 HTML）

| 来源 | 问题 | 处理 |
|---|---|---|
| 通用 | 剪贴板 HTML 带 `<html><body>` 外壳 | 只取 `<!--StartFragment-->` 到 `<!--EndFragment-->` 之间的内容 |
| Word | `<o:p>`、`mso-*` 样式、条件注释、`MsoNormal` 类 | 解析前清理 |
| Word | 列表是 `<p class="MsoListParagraph">` 加 `mso-list:l0 level1 lfo1` 样式，不是 `<ul>` | 按 `mso-list` 的 level 重建嵌套列表 |
| Word、Google Docs | 粗体、斜体写在 `span style="font-weight:700"`，而不是 `<b>`、`<i>` | 解析 style 属性映射成 `**`、`*` |
| Google Docs | 整个内容包在 `<b style="font-weight:normal">` 里 | 判断 `font-weight` 后再决定是否加粗 |
| 通用 | `&nbsp;`、连续空白、`<br>` | 先规范化空白，再处理换行 |

## 5. 转换细节清单

- **转义**：正文里的 `* _ # [ ] > |` 等字符要转义，代码块内不转义。
- **代码块**：`<pre><code class="language-xxx">` 转成带语言标识的围栏代码块。
- **表格**：转成 GFM 表格；含合并单元格或块级内容时，建议保留原始 HTML。
- **图片**：
  - `data:` URI 或本地资源要决定是落盘还是丢弃。
  - 不要把 base64 直接塞进 Markdown，体积会很大。
- **链接**：相对路径需要结合 `<base>` 或来源 URL 补全。
- **嵌套列表**：统一缩进规则（2 或 4 空格），有序列表序号要重新计数。

## 6. RTF 兜底方案

没有 HTML 时，才走：

```
RTF → NSAttributedString(data:, documentType: .rtf) → 遍历 attributes
```

- 字号显著大于正文 → 标题（需要自定义阈值）
- `.link` → 链接
- 字体 traits 的 bold/italic → `**`、`*`
- `NSTextList` → 列表
- `NSTextAttachment` → 图片

这条路径只能做到"尽力而为"，要接受结果不如 HTML 路径准确。

## 建议的整体流程

```
UIPasteboard → 取 public.html → 提取 Fragment → 预处理(Word/GDocs 清理)
→ SwiftSoup 解析 → 自定义 Markdown 渲染器 → 后处理(空行、转义、图片)
                    ↘ 无 HTML 时：RTF → NSAttributedString → 启发式转换
```

如果你告诉我主要的来源（只是 Safari 网页，还是 Word、Pages、Google Docs 都要支持），我可以帮你细化转换器的规则，或者给出 SwiftSoup 递归渲染器的核心代码骨架。