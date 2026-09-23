MarkdownEditorHy4 —— 渲染架构与功能现状（交接文档）

> 这份文档是**给新会话看的**：读完它，加上 `doc/架构与界面约定.md`（markdown 渲染的判据与踩坑），就能直接接着做功能，不用回翻历史对话。
> 记录的是**最终版实现**（同一功能改过多轮的，只写最后一版怎么做的，旧做法只在「为什么」里提一句）。
> 代码路径基于 2026-09-23 的工作区状态。

---

## 0. 三十秒速览

这是一个 **WYSIWYG 显示 markdown、但复制出来还是源码** 的编辑器。

- 底层：`UITextView` + **TextKit 2**（`NSTextLayoutManager` / `NSTextContentStorage`）。
- 解析：`swift-markdown`（Apple 的 `Markdown` 模块，**只用 `Document(parsing:)`，不碰 cmark C API**）。
- 平台：Mac Catalyst 为主（iOS 也能编，但当前只验 Catalyst），Swift 6.2 + `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`。
- 门面：`MarkdownTextView`（`MarkdownEditor/Editing/MarkdownTextView.swift`，1775 行）—— 对外只有它一个。

三条不可动摇的不变式（改任何东西都要守）：

1. **展示的一定是源码本身**。所有块的源码首尾相接 === 整篇源码；「全选复制出来的文本 === 源文件」是结构性成立的，靠 `RenderedFragment.reconciled` 补漏保证，不靠逐语法维护映射。
2. **渲染串每个字符位都有一条源码映射**（`CharMapping`），`text.length == mappings.count` 恒成立。
3. **装饰（灰底 / 竖条 / 三角 / 复选框 / 查找高亮）一律走 overlay + fragment 矩形，不往文本流里塞 attachment**。

---

## 1. 分层与目录

```
MarkdownEditor/                 ← 编辑器组件（可被单独复用）
  Model/          MarkdownDocumentStore（分块 / 增量 parse / 映射 / 折叠）
                  MarkdownBlock、CharMapping、SourceLocationTable
  Rendering/      MarkupToAttributedRenderer（AST → NSAttributedString）
                  RenderedFragment（渲染中间产物）
                  MarkdownTheme（样式唯一出处）
                  Attachments/  ImageAttachment / MarkdownTableAttachment /
                                BulletAttachment（含复选框座位、分隔线）/ CollapsedBlockAttachment
                  Highlighting/ SyntaxRole、CodeHighlighting、CodeLanguageProfile(+3 个扩展)、
                                SimpleCodeHighlighter
                  ImageLoader、VectorIcon、CheckboxInfo、CodeBlockInfo、QuoteChain、
                  FoldAnchorInfo、CollapsedSectionInfo
  Editing/        MarkdownTextView（门面）、MarkdownEditController、
                  MarkdownPasteboardController、CodeBlockDecoration、
                  FoldDisclosureControl、CheckboxControl
  Outline/        MarkdownOutlineView、OutlineTree、OutlineCoordinator、MarkdownTextView+Outline
  Search/         MarkdownFindBarView、MarkdownTextView+Search、SearchCoordinator
  Debugging/      TextKitDebugOverlay、ViewBorders

MarkdownEditorHy4/              ← App 层（demo 外壳）
  MarkdownDocumentViewController（内容页，1157 行）
  MarkdownEditorSettings（配置持久化，802 行）
  SettingsViewController（设置页，726 行）
  DocumentsWorkspace / DocumentListViewController / WorkspaceCoordinator …
```

依赖方向是**单向的**：`MarkdownEditor` 不认识 App 层的任何类型；主题不认识「用户存了什么」（换算放在配置侧方法里）。

---

## 2. 一次渲染的完整数据流

````
源码 String
  ↓ MarkdownDocumentStore.buildBlocks(region:of:)      只对受影响的那一小段重新 parse
块 [MarkdownBlock]（源码首尾相接）
  ↓ 每块：MarkupToAttributedRenderer.render(blockSource:blockOrigin:)
      swift-markdown AST → MarkupVisitor 逐个 visit
      → RenderedFragment（NSMutableAttributedString + [CharMapping]）
      → reconciled(补漏：AST 没覆盖到的 `>`、```、`|` 等字符)
      → 打自定义属性（.markdownCodeBlock / .markdownQuoteChain / .markdownFoldAnchor …）
  ↓ 拼成 attributedDocument
NSTextStorage（backingStorage.replaceCharacters，包在 performEditingTransaction 里）
  ↓ TextKit 2 排版
屏幕
  ↓ layoutSubviews / 滚动回调
装饰层（代码块灰底、引用竖条、折叠三角、复选框、查找命中）
````

**编辑闭环**（`MarkdownTextView.swift` 头部注释）：

```
用户敲键盘 → 系统把字符插进 NSTextStorage → textViewDidChange
  → reconcileFromTextChange：和上一版渲染文本做 diff
  → MarkdownDocumentStore.applyEdit（渲染范围 → 源码范围，局部 parse，局部渲染）
  → EditOutcome：局部替换 NSTextStorage 的那一段 → 刷新光标
```

⚠️ **为什么不在 `shouldChangeTextIn` 里拦截**：那样会绕过系统的输入法 marked text 机制，中文拼音输入直接坏掉。所以是「先让系统改，改完 diff 回写」。

---

## 3. 模型层：MarkdownDocumentStore

### 3.1 分块（buildBlocks）

`MarkdownDocumentStore.swift:412`

- 判据只有一条：**是不是 `Document` 的顶层 `BlockMarkup` 子节点**。所以标题、段落、代码块、表格、引用块、列表、分隔线各自是独立块；引用内部的段落不算块。
- 切分约定：每块源码 = `[本块起点, 下一个块起点)`，**中间的空行、换行全被吃掉** → 所有块 `sourceText` 首尾相接正好等于整篇源码，不需要分隔符。
- 第一个块吃掉 region 开头的空白；最后一个块的 end = region 末尾。整段空白 → 退化成一个 `makeTextBlock`（`kindDescription = "RawText"`）。

### 3.2 MarkdownBlock 的字段

| 字段                                                         | 说明                                                                                      |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------------------- |
| `id`                                                         | UUID。**编辑重建块时会换新 UUID**，所以 UI 层不能长期缓存 id 状态（大纲有自己的对账逻辑） |
| `sourceText` / `sourceRange`                                 | 源码文本 & 在整篇里的 NSRange（UTF-16）                                                   |
| `renderedContent` / `renderedRange`                          | 渲染结果 & 在整篇 attributed string 里的范围                                              |
| `charMappings`                                               | 每个字符位的源码映射，长度恒 = `renderedContent.length`                                   |
| `headingLevel` / `headingTitle`                              | 非标题块为 nil                                                                            |
| `isCollapsed`                                                | **用户意图**：这个标题下面那节是否折叠                                                    |
| `isHidden`                                                   | 是否落在某个已折叠标题底下（不参与渲染），由 `updateHiddenStates()` 统一算                |
| `renderedAsHidden` / `renderedIsCollapsed` / `hasFoldAnchor` | 当前渲染出来的实际状态，用于幂等判断                                                      |

⚠️ 块上没有 `level` 字段，只有 `headingLevel`。
⚠️ **所有遍历块的地方都要 `where !block.isHidden`**：隐藏块在屏幕上一个字符都没有，算进 diff / 坐标换算会把源码改坏。

### 3.3 增量编辑（applyEdit，9 步）

`applyEdit(inRenderedRange:replacementText:containerWidth:) -> MarkdownEditOutcome`（`:121`）

1. 编辑**前**先给整篇标题拍指纹 `headingFingerprint()`（必须早于第 6 步换块）；
2. 渲染范围 → 源码范围（删除时先做语法标记扩展 `expandedSyntaxMarkerRange`）；
3. 拼 `newSource`；
4. `affectedBlockIndices` 算出受影响的块；
5. 重 parse 区域 = 受影响块源码的并集，按增删量伸缩后 clamp；
6. 记下**旧坐标系**的 `oldRenderedRange` → 换块 → `fullSource = newSource` → `inheritCollapseStates` → `refreshCollapseState()`；
7. 拼 `newContent`；
8. 算新光标（源码偏移 → 渲染偏移）；
9. 判定 `headingsChanged`。

**「受影响的块」怎么算**（`affectedBlockIndices`，`:767`）：

- 跳过 `isHidden`（它们的 `renderedRange` 长度是 0，光标停在「⋯」后会被误判命中 → 每敲一个字重解析整节）；
- 光标是一个点时用闭区间判定，否则用 `intersects`；
- **尾部换行被改动时把下一块也拉进来**（删空行会导致两块合并）；`end = min(upper + 1, blocks.count)` —— 这个 `min` 不能省，否则命中最后一块时 `removeSubrange` 越界崩溃（实测踩过）。

**`headingsChanged` 的两条判据**：受影响块里有标题，或 `headingFingerprint()` 前后不一致。第二条是补「在正文里打字把下游标题顶移」这个漏判（早期 bug：目录拿过期偏移跳，跳到标题前面刚打进去那几个字的位置）。

### 3.4 坐标换算与复制还原

| 方法                                | 方向            | 要点                                                                                                                    |
| ----------------------------------- | --------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `sourceCaret(forRenderedOffset:)`   | 渲染 → 源码     | 落在装饰字符 / 块末尾时**往前**找最近有映射的字符取它的结束位置                                                         |
| `renderedCaret(forSourceOffset:)`   | 源码 → 渲染     | 边界判定用 `<` 不是 `<=`（边界偏移同时属于前一块末尾和后一块开头）；两遍搜索，第一遍跳过 attachment                     |
| `renderedRange(s)(forSourceRange:)` | 源码 → 渲染区间 | 复选框、查找用它                                                                                                        |
| `sourceText(forRenderedRange:)`     | 复制还原        | **`lastSourceEnd` 去重**（每个块重置）；源码一律从 `fullSource` 切，不从 `block.sourceText` 切（折叠的「⋯」映射会越块） |

### 3.5 折叠系统（最终版：按标题层级）

| 方法                               | 作用                                                                                                                                            |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `sectionBlockRange(forHeadingAt:)` | 从标题往后吃，直到遇到「层级 ≤ 自己」的标题。返回**后续块**的下标范围（不含标题自己）                                                           |
| `updateHiddenStates()`             | 栈算法：`collapsedLevels` 存「当前生效的折叠层级」。非标题块 `isHidden = !栈空`；标题块**先判自己的可见性再压栈**（顺序反了会把标题自己也藏掉） |
| `hasSectionContent(_:)`            | 这一节有没有非空白内容。只有空行的节**不给三角**                                                                                                |
| `refreshCollapseState()`           | 总入口。隐藏/显示 + 标题折叠态 + 打三角锚点，三段各自幂等（状态没变就不重渲染）                                                                 |
| `rerenderCollapsed(_:at:)`         | 生成「标题文字 + ⋯ 占位符」                                                                                                                     |
| `inheritCollapseStates(from:to:)`  | 编辑后块被重建，`isCollapsed` 会丢 —— 按「源码起点相同」或「源码文本相同且 ≥4 字符」把状态继承过来                                              |
| `toggleCollapse(blockAt:)`         | 折叠 / 展开都用「同一范围换一段新内容」表达，调用方不用区分方向                                                                                 |

**最终版的关键性质**：折叠只收起标题**下面那一节**，标题自己照常显示（能点进去改）；被收起的内容变成一个「⋯」占位符，**映射那一整节的源码** → 折叠状态下「全选复制 === 源文件」照样成立。

---

## 4. 渲染层：MarkupToAttributedRenderer + RenderedFragment

### 4.1 RenderedFragment（渲染中间产物）

`RenderedFragment { text: NSMutableAttributedString, mappings: [CharMapping] }`，不变式 `text.length == mappings.count`。

构造方式（决定了这个字符位「复制时吐什么」）：

| 工厂方法                                     | 语义                                              | 用在哪                                  |
| -------------------------------------------- | ------------------------------------------------- | --------------------------------------- |
| `.sourceSliced(_:sourceStart:)`              | **真实源码字符**，逐字符有映射                    | 正文、标题、代码正文、`1. ` 序号        |
| `.sourceHint(_:sourceStart:isSyntaxMarker:)` | 弱化显示的**源码本身**（灰只是样式）              | 图片下方的 `![alt](url)`、圆点后的 `- ` |
| `.decoration(_:)`                            | 纯装饰，`sourceStart = -1`，复制跳过              | 补的换行、占位符后面的空档              |
| `.attachment(_:sourceStart:sourceLength:)`   | 占 **1 个字符位**但吃掉 `sourceLength` 个源码字符 | 图片、表格、圆点、分隔线、折叠「⋯」     |
| `.decorationAttachment(_:isSyntaxMarker:)`   | 占 1 位、**不消耗**源码                           | 复选框座位                              |

⚠️ `sourceHint` 必须走真实映射（早期标成 decoration 的后果：光标落在 `![alt](url)` 中间时找不到源码位置，输入被插到右括号后面）。

**补漏 `reconciled(withSource:in:orphanAttributes:)`**：把 AST 没覆盖到的源码字符按原顺序补进渲染结果。`orphanAttributes` 就是这些补进来字符的样式 —— 想给「引用行的 `>`」「代码块的 ``` 围栏行」单独一套样式，换这个字典即可，不用写范围映射。

属性写入两个函数，**语义完全不同**：

- `addAttributesIfAbsent` = **补空缺**（已有属性优先）→ 给嵌套语法（Emphasis / Strong）用，外层不盖内层行内代码的等宽字体；
- `setAttributes` = **强制覆盖** → 凡是「必须盖掉正文色」的都必须用它（链接就是典型：叶子节点早在 `visitText` 就带上 `foregroundColor`，用 add-if-absent 上色等于没上）。

### 4.2 各节点怎么渲染（最终版）

| 语法        | 最终实现                                                                               | 关键点                                                                                                                                                                      |
| ----------- | -------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 标题        | `pushFont(headingFonts[level])` + 段落样式；`#` 靠补漏进来，用 `markerAttributes` 弱化 | 字号 = 正文 +15/8/5/2/0/−1                                                                                                                                                  |
| 段落        | 首行缩进**只给普通正文段落**（列表项内、引用块内不给）                                 | `quoteChain.ids.isEmpty && !wasInsideListItem`                                                                                                                              |
| 粗体 / 斜体 | 字体特征 `.traitBold` / `.traitItalic`；**中文额外做仿斜**                             | 见下                                                                                                                                                                        |
| 删除线      | `.strikethroughStyle`                                                                  |                                                                                                                                                                             |
| 链接        | `setAttributes(theme.linkAttributes)` + 挂 `.link`                                     | ⚠️ 还必须在 `configureTextView` 里 `linkTextAttributes = theme.linkAttributes`（UITextView 画图时会用自己的 linkTextAttributes 盖上去，只查 attributedText 永远看不出问题） |
| 行内代码    | **拆三段**上色：左反引号 → 正文 → 右反引号                                             | 反引号数量不能写死 1（` `a`b` ` 合法）；底色**必须半透明**（不透明会盖住系统选中高亮）                                                                                      |
| 图片        | `ImageAttachment`（自绘成 UIImage）+ 下方弱化显示源码                                  | 见 §6.5                                                                                                                                                                     |
| 代码块      | 正文 `sourceSliced` + 围栏行靠补漏 + 打 `.markdownCodeBlock` 标记 + **最后**上语法色   | 见 §6.3                                                                                                                                                                     |
| 表格        | 自绘成一张图（attachment）+ 下方保留源码                                               | 见 §6.4                                                                                                                                                                     |
| 引用块      | **不在文本流里插竖条**：只打 `.markdownQuoteChain` 标记，UI 层画连续竖条               | 见 §6.2                                                                                                                                                                     |
| 有序列表    | 直接显示源码里的 `1. `（色由 `orderedListMarkerColor` 单独管）                         |                                                                                                                                                                             |
| 无序列表    | 圆点 attachment 占 1 位、映射到 `- ` 两个字符 + 弱化显示 `- `                          | 退格删掉 `- ` 自然降级成段落                                                                                                                                                |
| 任务列表    | `- `（浅灰）+ **座位**（透明占位）+ `[x]`（浅灰）+ 正文，**不画圆点**                  | 见 §6.6                                                                                                                                                                     |
| 分隔线      | 整行换成一个横线 attachment                                                            | 认领长度必须夹到「本行」                                                                                                                                                    |
| HTML 块     | 整块按 `markerAttributes` 原样显示                                                     |                                                                                                                                                                             |

**中文斜体**：

- `.obliqueness` 是 TextKit 1 的属性，**TextKit 2 直接忽略**（实测挂上了画面不动）；
- `UIFontDescriptor.withMatrix(_:)` 在 Catalyst 上编译不过；
- 按 `.name` 重建描述符会回退成 Times（系统字体内部名是 `.SFNS-…`）；
- **最终做法**：`UIFont.withSlant(_:)` —— 抄下原描述符的**全部** `fontAttributes`，只追加 `.matrix`，再重建。并且**只给 CJK 字符换**（英文有真斜体，再叠会歪过头）。`MarkdownTheme.cjkItalicSlant = 0.2`。

### 4.3 自定义属性（渲染层打标 → UI 层消费）

| Key                                           | 值类型                                 | 打标位置                                                   | UI 消费                                     |
| --------------------------------------------- | -------------------------------------- | ---------------------------------------------------------- | ------------------------------------------- |
| `.markdownCodeBlock`                          | `CodeBlockInfo(code, language)`        | `visitCodeBlock`（**含**首尾 ``` 行）                      | 灰底矩形 + 复制按钮                         |
| `.markdownQuoteChain`                         | `QuoteChain(ids: [Int])`（外→内）      | `visitBlockQuote`（add-if-absent，内层长链不被外层覆盖）   | 竖条（每层一条）                            |
| `.markdownFoldAnchor`                         | `FoldAnchorInfo(blockID, isCollapsed)` | `markFoldAnchor`：打在第一个非空白字符，**不插入任何字符** | 折叠三角                                    |
| `.markdownCollapsedPlaceholder`               | `CollapsedSectionInfo(blockID)`        | 打在「⋯」那个字符位                                        | 「⋯」点击热区                               |
| `.markdownCheckbox` / `.markdownCheckboxSeat` | `CheckboxInfo(sourceStart, isChecked)` | 字面量三字符 / 座位                                        | 复选框按钮（**优先认座位**）                |
| `.markdownSyntaxMarker`                       | `Bool`                                 | `sourceHint(isSyntaxMarker:)`                              | 退格时整段删（`expandedSyntaxMarkerRange`） |

`QuoteChain.ids` 用「节点源码起始位置」而不是 UUID，是为了每次重渲染 ID 稳定 —— 否则 UI 层「结果稳定才收手」的收敛循环永远收敛不了。

### 4.4 代码高亮子系统

- 协议 `CodeHighlighting`：`supportsLanguage(_:)` + `highlight(_:language:) -> [HighlightToken]`。渲染器只认协议 → 将来换 tree-sitter 只要实现同一个协议塞进 `renderer.codeHighlighter`，UI 一行不改。
- 中间表示 `SyntaxRole`：`keyword / string / comment / number / type / identifier / plain`。**颜色只在 `MarkdownTheme.syntaxColors` 一处决定**，换高亮器配色不变。
- 实现 `SimpleCodeHighlighter`：手写**单遍扫描**（不用正则，避免每种 token 扫一遍全文），除了查关键字表几乎不分配内存；预建一张「标量下标 → UTF-16 偏移」表，取 NSRange 是 O(1)。超过 `maximumLength`（默认 20000）整段放弃高亮。
- 支持语言（当前）：js/javascript/mjs/cjs/node、ts/typescript、python/py、ruby/rb、php、sh/shell/bash/zsh、c/h、cpp、objc、java、c#/cs、kotlin、go、rust、swift、sql、json、jsonc。规则表在 `CodeLanguageProfile` + 三个扩展（`+CLike` / `+Scripts` / `+Modern`），**加一门语言只加一张表，不动扫描器**。
- 上色**只改 `.foregroundColor`**，不动文字和映射 → 「复制 === 源文件」自动成立。
- ⚠️ **调用顺序是刻意排的**：全量属性操作（补漏、补段落样式）在前，**上色在最后**。因为 `addAttributesIfAbsent` 内部是 `enumerateAttributes` + 逐 run `setAttributes`，耗时跟 run 数强相关（1 个 run 0.005ms / 1140 个 run 6.4ms，约 1280 倍）。先上色等于把后面几步全逼到碎渣上跑。

**实测性能（同机对照，2026-09-23）**：

| 场景              | 手写 lexer               | tree-sitter（swift grammar，Python 绑定） |
| ----------------- | ------------------------ | ----------------------------------------- |
| 512KB 全量        | **29.1 ms**（16.8 MB/s） | 57.9 ms（8.4 MB/s）                       |
| 18KB 代码块全量   | **1.285 ms**             | 1.887 ms（还不含 highlight 查询）         |
| 敲 1 个字符后重算 | 整块重扫 1.285 ms        | 增量 **0.0106 ms**                        |

结论：全量扫描这版快约 2 倍；但编辑场景 tree-sitter 快两个数量级（增量重解析）。**不过这 1.3ms 在真实按键链路里占比很小**（整篇重渲染才是大头）→ 要提速先做增量渲染，换高亮器是伪优化。

---

## 5. UI 层：MarkdownTextView

### 5.1 组成

- `renderer: MarkupToAttributedRenderer`（`let`）、`documentStore: MarkdownDocumentStore`（`let`）
- 两个 controller：`MarkdownEditController`（当 `delegate`）、`MarkdownPasteboardController`
- **五个装饰层**，层序（从下到上）固定，改错就会互相盖：

```
codeBlockBackgroundLayer（灰底，index 0）
  ↑ quoteBarLayer（引用竖条）
  ↑ 文字（系统画的）
  ↑ searchHighlightLayer（查找命中，夹在竖条上面、文字下面）
  ↑ codeBlockControlLayer（复制按钮）
  ↑ checkboxLayer / foldControlLayer（三角、复选框）
```

三个控件层（`CodeBlockControlLayer` / `CheckboxLayer` / `FoldControlLayer`）都用 `hitTest` 只认自己的子按钮、其余穿透。

### 5.2 layoutSubviews 里做的事（顺序有讲究）

```
super.layoutSubviews()
  → updateTextContainerInsetIfNeeded()      ← 必须第一件，下面所有装饰都读它
  → if pendingFullReplace { applyPendingFullReplace() }
  → updateCodeBlockDecorationsIfNeeded()
  → positionFoldControls()
  → updateSearchHighlightsIfNeeded()
  → 宽度变了？ → reRenderPreservingCaret()
```

⚠️ **整篇替换必须放在 `layoutSubviews` 里做**（`applyPendingFullReplace`）：在按钮事件里同步整篇替换，TextKit 2 会把所有 attachment 的 view 摘掉却不为新的建 view →「图片和圆点全部消失，滚一下才回来」。试过但都无效的绕法列了 7 种（`invalidateLayout` / `ensureLayout` / 抖 `textContainer.size` / 清空再赋值 / 复用旧 attachment 实例…），别再试一遍。

### 5.3 行宽上限

`maxContentWidth` 不改 `textContainer` 的宽，而是**对称加宽左右 `textContainerInset`**（超出部分左右平分 → 正文居中）。好处：所有装饰读 inset 定位，改一处整套餐跟着挪。⚠️ 只在结果真变了才赋值，否则 `layoutSubviews` 死循环。

### 5.4 滚动时装饰怎么跟上（这是「停下滑才跳到位」那个 bug 的解法）

滚动 KVO 回调里做三件事：

1. **先按缓存的文档坐标平移一次**（每帧必做，很便宜）—— 不平移背景会掉队一帧都看得出来；
2. `setNeedsLayout()` + `scheduleScrollLayout()`（一帧最多一次 `layoutIfNeeded`）；
3. `scheduleFoldRedraw()`（0.15s 后整篇兜底重算）。

**重算必须站在 `layoutSubviews` 里（`super.layoutSubviews()` 之后）**：TextKit 是在那一轮更新 viewport 的，在滚动回调里直接算拿到的是上一次 viewport 的估算值，等于白算。

**`nearViewportBand`** = 视野上下各扩一屏（高 3×bounds）的文档坐标矩形。`compute*(reusingOutside: band)` 的语义是：**落在这个矩形外面的块直接沿用上一轮缓存，不再问 TextKit**。`enumerateTextLayoutFragments(options: [.ensuresLayout])` 等于强制排版，整篇重算会让长文档掉帧；而视野外的块算出来本来也是估算值，等它滚进 band 再算才准。

**节流按滚动距离（40pt）而不是按时间**：块进视野前 1 屏就已经落在 band 里被算过了，40pt 粒度足够早。

**收敛循环**：`refreshCodeBlockDecorations` 每 60ms 重算一次并和上一轮比对，结果还在变就继续（上限 30 次），连续两轮一致才收手。这套就是「屏幕外估算坐标」的机制层解法。

---

## 6. 各功能最终实现清单

### 6.1 折叠（按标题层级）

- **三角浮在正文左边的装订线里**（`theme.foldGutterWidth` 加进 `textContainerInset.left`），**不占字符位** —— 早期版本把三角当 attachment 插进文本流，会把首行往右推，多行左边缘对不齐。
- 定位 `positionFoldControls`：扫 `.markdownFoldAnchor` → `textLayoutFragment(for:)` → ⚠️ **`guard fragment.state == .layoutAvailable`**（没排到的 fragment 用估算坐标画必然错位，被跳过的都在屏幕外）→ 取 `textLineFragments.first?.typographicBounds`（对齐**首行**，不是整段居中）。
- 图标：折叠 ▶ `chevron.right`、展开 ▼ `chevron.down`。
- 「⋯」占位符（`CollapsedBlockAttachment`）上面盖一个透明按钮当热区，`insetBy(dx: -8, dy: -8)` 撑开。点它展开。
- **折叠后清空撤销栈**（`undoManager?.removeAllActions()`）：栈里更早的记录是针对折叠前的渲染文本的，撤销它们会把文本改到和模型对不上的状态。⚠️ 这里不能用 `disable/enableUndoRegistration` 包住替换（`_UITextUndoManager` 会抛 invalid state，实测崩）。

### 6.2 引用块竖条

- 最终走 **overlay + fragment 矩形合并**（早期版本每行插一个 `QuoteBarAttachment`，段距处断成虚线、嵌套时挤在一起）。
- 渲染层给引用块内字符打 `.markdownQuoteChain`（从外到内的层 ID）。UI 层把每个区间覆盖的 fragment 矩形求出来后，**链上每一层各自累计一份** → 外层竖条贯穿整块（含内层占据的行），内层只覆盖自己的行。
- x = `inset.left + level × quoteIndent`，和第 n 层文字的段落缩进对齐。
- 与代码块背景共用同一套刷新循环。

### 6.3 代码块（灰底 + 围栏开关 + 复制按钮 + 高亮）

- 灰底：`computeCodeBlockFrames` 扫 `.markdownCodeBlock` → 枚举 fragment 取 **`layoutFragmentFrame`**（要的是「整段的纵向并集」，不是 `typographicBounds`）求 min/max → 上下各加 `codeBlockVerticalPadding`。
  - ⚠️ **坐标系**：`layoutFragmentFrame` 原点已扣 `textContainerInset`，画到 textView 坐标系 y 要 **补回** `inset.top`。
- **围栏开关** `theme.showsCodeBlockFenceBackground`（默认 `false`）：`false` 时把首行 `lang 和末行 ` 从矩形里抠掉（背景只罩代码正文），`true` 就整块一个灰方块。只有 `computeCodeBlockFrames` 一处读它。
- **为什么灰底不用「夹取」躲围栏行**（早期做法的坑）：缝隙是**用户可调的段距**撑出来的，段距调到 0 时夹子会咬进正文（实测最后一个 `}` 戳出灰底 6pt）。正解是把差额做进结构里 —— 给围栏行单独一套 `codeFenceParagraphStyle`，段距取 `max(段落间距, codeBlockVerticalPadding)`，通过 `visitCodeBlock` 的 **`orphanAttributes`** 生效（补漏补到的只有那两行）。
- 复制按钮 `CodeBlockCopyButton`（26pt）摆在背景矩形右上角内缩 6pt，点击把 `info.code`（不含围栏）放进剪贴板。
- 每次重建 subviews，不维护复用池（代码块数量很少）。

### 6.4 表格

- **自绘成一张 UIImage** 再当 attachment 塞进文本流（`MarkdownTableAttachment` 的 `bounds` 取 `image.size`）。表格下方保留**弱化显示的源码**（真实映射，光标能停进去改）。
- 附件都画成 UIImage 而不是用 `NSTextAttachmentViewProvider`：**TextKit 2 整篇替换后会摘掉 attachment 的 view 且不再回调 `loadView()`**（整个 App 生命周期只调一次）→ 图片/圆点消失，滚一下才回来。
- **列宽（最终版，只缩不放）**：`MarkdownTableView.makeLayout`
  1. 逐列取「最长内容宽」→ `ideal = ceil(widest) + padding×2` → 夹到 `[minColumnWidth, maxColumnWidth]`（默认 64 / 280）；
  2. **只有 `total > availableWidth` 才等比压缩**，没超就不动；
  3. 保底 `floorWidth = min(minColumnWidth, limit/columnCount)`，压完还超就再缩一次；
  4. 行高按各列实际换行高度取最大。
  - ⚠️ 旧实现是「不管多窄都等比撑满容器」，把第 1 步夹的 min/max 洗掉了 —— 表现就是「列宽限制没生效，表格跟窗口一样宽」。
  - `MarkdownTableLayout.totalWidth = columnWidths.reduce(0,+)`，**常小于** availableWidth（这是「只缩不放」的直接结果）。
- 表格源码用等宽 + 浅灰（`tableSourceAttributes`），段落样式不能省（好几行，没它缩进和行距都不对）。

### 6.5 图片

- `ImageAttachment`：本地/已缓存 → 同步出图；网络图 → 先按 `maxWidth × 16:9` 占位，`ImageLoader` 异步下载（`NSCache` 100 张 + 同 URL 请求合并），回主线程 `apply` 后 `host?.invalidateLayout(for:)`（只在 bounds 真变了才通知）。
- 尺寸：最大宽 = `maxWidthRatio(默认0.5) × 可用宽` **或** `maxWidthPoints(默认200)`（两者互斥，`nil` 切换）；最大高 = 420（只防长图撑爆，跟窗口无关）。**只缩不放**（`scale = min(宽比, 高比, 1.0)`，小图绝不放大）。
- 加载失败 → 虚线框 + 照片图标占位（最多 2 行正文高）。
- 点击图片 → 手势（`cancelsTouchesInView = false` + `shouldRecognizeSimultaneouslyWith` 返回 true，不抢光标）→ `imageAttachment(at:)` → `onImageTapped` → 内容页弹 `QLPreviewController`。

### 6.6 任务列表复选框

- 文本流排布：`- `（浅灰，真实源码）→ **座位**（`CheckboxSeatAttachment`，透明占位，不消耗源码）→ `[x]`（浅灰，真实源码）→ 正文。**不画圆点**。
- ⚠️ 座位必须 `isSyntaxMarker: false`：带上 `.markdownSyntaxMarker` 会把左右两段本来独立的标记**粘成一段**，光标停在 `]` 右边按退格会吃掉整段 `- [ ] `。
- 按钮（`MarkdownCheckboxButton`，真 UIButton）摆在座位正中（`coversCheckboxLiteral == false`，默认）；`true` 时压在 `[x]` 上（底色不透明，宽度用三种字面量里最宽的那个算**定值**，否则点一下就变宽）。
- **勾选状态读源码里那三个字符，绝不能读 `item.checkbox`**：cmark-gfm 用 `strstr(整行, "[x]")` 判定，行里别处出现 `[x]` 就会误报成已勾选 → 点它时按「已勾选」写回 `[ ]`，源码本来就是 `[ ]`，等于什么都没干（用户看到「点了没反应」）。「是不是任务项」那个判定语法树是准的，保留。
- 定位用 `enumerateTextSegments`（字符级矩形，行级 fragment 给不了）。
- 点击 → `toggleCheckbox` 走标准编辑管线（撤销/重做自动生效、只重渲染一块）。

### 6.7 查找 / 大纲（与渲染的关系）

- 查找高亮层夹在**引用竖条之上、文字之下**：插最底层会被代码块不透明灰底盖住，加最上层会压住文字。
- 命中记的是**源码偏移**（`renderedRanges(forSourceRange:)` 跨块查询），内容一改就通知外面重查。
- 大纲：`MarkdownDocumentStore+Outline` 提供 `outlineItems`；编辑器只通过协议 `MarkdownOutlineEventSink` 把标题列表和光标位置喊出去，不认识目录长什么样。光标上报防抖 120ms。

### 6.8 复制 / 粘贴 / 撤销

- `copy` / `cut` 被接管：放进剪贴板的是**源码文本**。
- **键盘输入**：系统已记过撤销，`applyEdit` 里用 `disable/enableUndoRegistration` 包住（不包会记两遍）。
- **命令类编辑**（粘贴 / 剪切 / 插入图片 / 查找替换）：走 `performUndoableModelEdit` + `registerRestore(toSource:)`，按**整篇源码快照**登记撤销。
  - 为什么必须自己接管：系统撤销按「插入时的长度」记账，而源码 19 个 UTF-16 会被渲染成 21 个（每行行首多一个圆点占位符）→ Cmd+Z 从 21 个里删 19 个，末尾剩下「完成」两个字。
- ⚠️ 程序自己发起的编辑（`isProgrammaticEdit`）**连 disable/enable 都不能碰**，否则 `_UITextUndoManager` 抛 invalid state。

### 6.9 导出长图

`renderFullContentImage()`：临时把 bounds 撑到全文高度（循环到 contentSize 不再变）→ 自己枚举 `NSTextLayoutFragment` 逐个 `draw(at:in:)`（`.rendersUnseenText`）→ 装饰层各自 render layer → 恢复现场。
⚠️ 不能指望 `layer.render(in:)`：UITextView 只把「画过的」缓存进 layer，屏幕外是空白。

---

## 7. 设置与主题（改了必须整篇重渲染）

### 7.1 主题是唯一出处

`MarkdownTheme`（553 行）：正文字号派生出等宽字体（`正文-1`）和 H1~H6（`正文 +15/8/5/2/0/−1`），`applyBodyFontSize` 整组一起换。颜色、间距、折叠三角尺寸、表格样式、图片尺寸、高亮配色全在这里。

### 7.2 设置项（App 层持久化）

| 设置         | 默认           | 量程                           | 影响                                  |
| ------------ | -------------- | ------------------------------ | ------------------------------------- |
| 正文字号     | 17             | 12…28                          | 整组字体                              |
| 行高倍数     | 1.0            | 1.0…2.0                        | ≤1 时不写进段落样式                   |
| 段落间距     | 12             | 0…40                           | 正文/标题/列表项共用                  |
| 首行缩进     | 0              | 0…4（**字符数**）              | × 字号换成点                          |
| 行宽上限     | 1200（= 不限） | 320…1200                       | 走 `editor.maxContentWidth`，不走主题 |
| 表格最小列宽 | 64             | 32…200                         |                                       |
| 表格最大列宽 | 280            | 80…600                         |                                       |
| 图片宽度模式 | 百分比         | `.percentage` / `.fixedPoints` | 两者互斥                              |
| 图片宽度比例 | 0.5            | 0.2…0.9                        |                                       |
| 图片固定宽   | 200            | 80…800                         |                                       |
| 图片最大高   | 420            | 120…1600                       |                                       |

设置页 5 组：正文排版 / 阅读位置 / 大纲面板 / 表格列宽 / 图片尺寸。

**渲染期开关（只在 `MarkdownTheme` 里，设置页没有对应行）**：`showsSourceHints`（默认 true）、`showsCodeBlockFenceBackground`（默认 false）、`enablesCodeHighlighting`（默认 true）、`coversCheckboxLiteral`（默认 false）。

### 7.3 为什么改完必须整篇重渲染

字号、行高、段间距、首行缩进、图片尺寸都是**渲染那一刻烙进**字体 / `NSParagraphStyle` / attachment `bounds` 的，只改主题数值屏幕上一动不动。入口 `MarkdownDocumentViewController.applyEditorStyle()`：

```
settings.applyTypography(to: &editor.renderer.theme)
settings.applyTableColumnWidths(to: &editor.renderer.theme)
settings.applyImageSize(to: &editor.renderer.theme)
editor.maxContentWidth = settings.bodyContentWidthLimit.map { CGFloat($0) }
editor.refreshTheme()          // 保光标
```

三个配置侧方法里还有两处兜底：`applyTableColumnWidths` 在「最小 > 最大」时以最大值压回最小值（否则渲染层 `min(max(ideal, min), max)` 会让「最小列宽」悄悄失效）；`applyImageSize` 给 maxHeight 兜 60 的下限。

渲染是**幂等**的（同一份源码 + 同一套主题 → 逐字符一样的结果），所以拖滑块每动一下重排一遍也扛得住。

---

## 8. TextKit 2 坐标坑（改渲染/装饰前必读）

1. **屏幕外的 fragment 给的是估算坐标**（实测差 84pt+）。任何「算一次管到底」的装饰都会错位 → 必须配收敛循环（每 60ms 重算 + 与上一轮比对 + 滚动停下补一轮）。
2. **重算必须站在 `layoutSubviews` 里（`super.layoutSubviews()` 之后）**，滚动回调/KVO 里问拿到的是旧 viewport 的答案。系统滚动未必自己调 `layoutSubviews` → 要 `setNeedsLayout()` + async 的 `layoutIfNeeded()`。
3. **`layoutFragmentFrame` 原点已扣 `textContainerInset`**，画到 textView 坐标系 y 要补回 `.top`；横向按 inset 现算。
4. **要「字顶/字底」用 `NSTextLineFragment.typographicBounds`，要「这段占多高」才用 `layoutFragmentFrame`**。折叠三角对齐首行必须用前者；代码块灰底求并集用后者。
5. **字符级矩形用 `enumerateTextSegments`**（复选框三字符、「⋯」热区），行级 fragment 给不了。
6. **装饰层 `state != .layoutAvailable` 就跳过**（三角定位），别拿估算值画。
7. **挂在文字上的 `.backgroundColor` 必须半透明**（不透明会盖住画在文字下面的系统选中高亮）。装饰层画的矩形没这个问题。
8. **改完文本要主动刷装饰层**：`applyEdit` 末尾 `setNeedsLayout()` + `updateCodeBlockDecorationsIfNeeded()` —— `performEditingTransaction` 会让排版失效但**不保证**系统排一次布局（实测：删掉最后一个任务项后按钮留在原地，要等下一次滚动才消失）。
9. **新增非 UI 的 class 必须写 `nonisolated deinit {}`**（隔离 deinit 会 free 野指针 → `pointer being freed was not allocated`）。
10. **cmark 给的 range 会比肉眼所见大**：整行只渲染成一个字符的块级附件（分隔线），认领长度必须夹到**本行**（`singleLineLength(of:)`），否则那部分源码在屏幕上蒸发（在 `---` 末尾按回车像没反应）。

---

## 9. 性能判据（实测，别凭感觉优化）

- **全量属性遍历的代价跟 attribute run 数强相关**：1 个 run 0.005ms / 1140 个 run 6.4ms（约 1280 倍）→ 先做完所有全量属性操作，最后再上色。
- **编辑粒度 = 只重渲染受影响的块**：2500 字符 14ms / 10000 字符 48ms / 19000 字符 86ms（Catalyst + Debug），**线性增长**（≈4.4ms/千字符）。
- **渲染管线本身才是大头，高亮只占 ~15%**。真要提速，方向是增量渲染，不是换高亮器。
- 想量就量「关掉高亮的 `render(blockSource:)` 耗时」；基准探针在 `MarkdownEditorHy4Tests/pptmp/HighlightPerfProbe.swift`。

---

## 10. 验证方式

- **只验 Catalyst 一个平台**。命令**必须以 `xcodebuild` 开头 + `-project` 绝对路径**，**绝不接 `| head -N`**（SIGPIPE 会报假的 `Failed to write to CAR`）。
- 单测宿主就是 App；新加测试文件**不用改 pbxproj**；`@testable import MarkdownEditorHy4`。当前约 **360+ 条用例**。
- ⚠️ **别依赖用户的真实设置**：`MarkdownEditorSettings.shared` 读的是沙盒容器里的真实配置，用户在 App 里调一下测试就红。断言「显示几行」用数据层 `visibleTitles`，别数 cell。
- ⚠️ **带动画的 UIKit 操作要跑 runloop**（`RunLoop.main.run(until: Date().addingTimeInterval(0.4))`）再断言。
- 冒烟用 `open -n <App.app>`（直跑二进制 = 沙箱套沙箱 → SIGTRAP）。
- 自动化冒烟：`testcase/` 下有 7 个用例 md（斜体粗斜体、表格、标题折叠、代码高亮…）。

---

## 11. 已知遗留 / 下次接手可以先扫一眼

1. `MarkdownTextView.positionFoldControls` 里有一行遗留调试输出 `print("==========", line.midY)`（每次摆三角都打）。
2. `MarkdownTableView`（那个 `UIView` 子类）和 `MarkdownTableView.height(...)` **没有生产调用点** —— 表格实际走静态 `image(...)` 离屏出图。
3. 三角 frame 的 `y = line.midY + side/2 - 5` 里那个 `- 5` 是没命名的魔法数。
4. `theme.showsCodeBlockFenceBackground` 默认 false 且只有一处读取，改成 true 不用动别的地方（但没有设置页入口）。
5. 编辑仍是**整块重渲染**（不是块内增量），长文档大块编辑会有几十 ms 抖动 —— 这是已知的性能上限，不是 bug。
6. 折叠状态在**块重建后靠 `inheritCollapseStates` 继承**（按源码起点/文本匹配），匹配不上的会丢状态。

---

## 12. 文件索引（按「要改什么」查）

| 想改…                  | 看哪个文件                                                                                      |
| ---------------------- | ----------------------------------------------------------------------------------------------- |
| 某个语法长什么样       | `MarkupToAttributedRenderer.swift`（各 `visitXxx`）                                             |
| 颜色 / 字号 / 间距     | `MarkdownTheme.swift`（唯一出处）                                                               |
| 复制出来不对 / 补漏    | `RenderedFragment.swift`（`reconciled`）+ `MarkdownDocumentStore.sourceText(forRenderedRange:)` |
| 分块 / 增量 / 光标换算 | `MarkdownDocumentStore.swift`                                                                   |
| 折叠逻辑               | `MarkdownDocumentStore`（§3.5）+ `FoldDisclosureControl.swift`                                  |
| 装饰画错位置           | `MarkdownTextView.swift`（`compute*` / `position*`）+ §8                                        |
| 表格画法 / 列宽        | `MarkdownTableView.swift`（`makeLayout`）+ `MarkdownTableAttachment.swift`                      |
| 图片加载 / 尺寸        | `ImageAttachment.swift` + `ImageLoader.swift`                                                   |
| 代码高亮               | `Highlighting/`（加语言只改 `CodeLanguageProfile+*.swift`）                                     |
| 复选框                 | `MarkupToAttributedRenderer.appendTaskListMarker` + `CheckboxControl.swift`                     |
| 设置项                 | `MarkdownEditorSettings.swift` + `SettingsViewController.swift`（加一行要改四处）               |
| 层序 / 生命周期        | `MarkdownTextView.swift`（`setup*` / `layoutSubviews`）                                         |

**配套文档**：`doc/架构与界面约定.md`（**只放 markdown 渲染相关**的判据与踩坑，6 节）、`doc/代码高亮方案.md`、`doc/引用渲染方案.md`、`doc/任务列表渲染方案.md`、`doc/标题大纲渲染方案.md`、`doc/表格渲染方案.md`、`doc/查找替换方案.md`、`doc/bugHistory.md`（历史 bug，2026-09-21 起不再新增）。
