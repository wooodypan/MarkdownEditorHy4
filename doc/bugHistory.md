# 缺陷修复记录（bugHistory）

这个文件专门记录本项目修过的、**比较值得留一手**的 bug。

每条都写清五件事：

1. **现象** —— 用户看到的是什么（怎么复现）
2. **为什么会这样** —— 根因，用大白话说
3. **怎么修的** —— 改了什么
4. **怎么验证的** —— 凭什么说修好了
5. **以后注意什么** —— 免得下次又踩

写给谁看：**刚接手这个项目的人**（也包括三个月后的自己）。所以尽量不用行话，
真绕不开的术语在文末有一份[小词典](#附-1名词小词典)。

---

## 索引

| # | 日期 | 一句话 | 主要改动文件 |
|---|---|---|---|
| [2](#2-粘贴后-cmdz残留几个字2026-09-13) | 2026-09-13 | 撤销按「源码长度」记账，实际存的却是「渲染长度」，差几个字 | `MarkdownTextView.swift`、`MarkdownPasteboardController.swift` |
| [3](#3-点目录要连点好几次才跳到位2026-09-13) | 2026-09-13 | 屏幕外的行「还没排版」，量出来的坐标是猜的 | `MarkdownTextView+Outline.swift` |
| [4](#4-斜体和粗斜体对中文不生效2026-09-13) | 2026-09-13 | 中文字体没有斜体字形，光标字体特征「斜体」汉字纹丝不动 | `MarkdownTheme.swift`、`MarkupToAttributedRenderer.swift` |
| [10](#10-在样式表里改-linkcolor-链接颜色没变2026-09-16) ★ | 2026-09-16 | 两层根因叠在同一个症状上：① 链接用「只补空缺」上色，文字早被涂成正文色；② `UITextView.linkTextAttributes` 默认系统蓝，画图时盖掉富文本里的颜色 | `MarkupToAttributedRenderer.swift`、`RenderedFragment.swift`、`MarkdownTextView.swift`、`MarkdownLinkColorTests.swift`（新增） |
| [12](#12-任务项正文里带-x复选框却显示成已勾选2026-09-18) ★ | 2026-09-18 | 勾选状态取了解析器给的 `item.checkbox`，而它是用 `strstr(整行, "[x]")` 算的 —— 正文里有个 `[x]` 就把整项报成已勾选 | `MarkupToAttributedRenderer.swift`、`MarkdownEditorHy4Tests.swift` |
| [13](#13-点一下复选框方框就变宽2026-09-18) ★ | 2026-09-18 | 方框宽度写成「按**当前**那个字面量取宽」，而 `[ ]` 和 `[x]` 在图里宽度本来就不同（15.95 / 20.09pt）—— 点一下方框就长 4pt | `MarkdownTextView.swift`、`CheckboxControl.swift`、`MarkdownEditorHy4Tests.swift` |
| [14](#14-任务项里按一次退格-整段被吃掉2026-09-18) ★ | 2026-09-18 | 复选框座位是无条件打了语法标记的装饰附件，把 `- ` 和 `[ ] ` 两段标记**粘成一段** —— 在 `]` 右边按一次退格，`- [ ] ` 整段被吃掉；装饰层又没及时重刷，按钮还残留在屏幕上 | `RenderedFragment.swift`、`MarkupToAttributedRenderer.swift`、`MarkdownDocumentStore.swift`、`MarkdownTextView.swift`、`TaskListBackspaceTests.swift`（新增） |
| [17](#17-滚动时代码块灰底停在错地方停下才跳到位2026-09-18) ★ | 2026-09-18 | 屏幕外的代码块只能用 TextKit 的**估算坐标**算矩形，缓存下来后滚动一直沿用；重算又放在滚动回调里，那时 viewport 还没更新，算出来还是错值 —— 表现为灰底压在 ` ```swift ` 那行上，停下手才「啪」地归位 | `MarkdownTextView.swift`、`MarkdownEditorHy4Tests.swift` |
| [18](#18-行内代码的灰底盖住了鼠标选中高亮2026-09-19) ★ | 2026-09-19 | 行内代码的灰底是**不透明**的 `.backgroundColor`，而它是跟着文字一起画的 —— 把画在文字**下面**的系统选中高亮整块盖住，框选行内代码看着像没选中；顺带把两侧反引号弱化成浅灰 | `MarkdownTheme.swift`、`MarkupToAttributedRenderer.swift`、`InlineCodeStyleTests.swift`（新增） |
| [19](#19-语言名-swift-的底部被代码块灰底压住2026-09-19) ★ | 2026-09-19 | 灰底的上沿是拿「正文首行 fragment 顶 − padding」定的，而 fragment 里含着**段后间距**。段距被调小（用户可调 0~40），灰底上沿就往上抬进上一行 ```swift 的字里 | `MarkdownTextView.swift`、`CodeBlockBackgroundClearanceTests.swift`（新增） |
| [20](#20-最后一个--戳出代码块灰底2026-09-19) ★ | 2026-09-19 | 修第 19 条时加的两道「夹子」**夹过头了**：围栏行和正文之间的空隙全靠段间距撑着，段距调到 0 时空隙归零，夹子只能往里挤 —— 把灰底底边挤进了正文最后一行，`}` 戳出去 6pt = 灰底高度的 10%。修法换成「给首尾围栏行的段间距兜下限」，夹子整段删掉 | `MarkdownTheme.swift`、`MarkupToAttributedRenderer.swift`、`MarkdownTextView.swift`、`CodeBlockBackgroundClearanceTests.swift`、`MarkdownTypographyTests.swift` |
| [22](#22-分隔线末尾按回车不换行2026-09-20) ★ | 2026-09-20 | 分隔线在渲染串里只占 1 个字符位（一条横线附件），却按 cmark 给的 range 把**后面的空行一起认领**了 —— 那些空行既没有渲染字符、也轮不到补漏步骤补上，等于在屏幕上凭空消失。用户在 `---` 末尾按回车，源码多了一个换行、画面一动不动 | `MarkupToAttributedRenderer.swift`、`SeparatorEnterTests.swift`（新增） |
| [23](#23-文档滚动之后点图片没反应2026-10-12) ★ | 2026-10-12 | 手势给的坐标**已经含了滚动偏移**（滚动视图的坐标原点就是 `contentOffset`），命中测试又减了一次 —— 手指点在图片上，问出去的却是「下方一屏处」的位置。症状是「滚过一段之后点图片全没反应，点图片上方一屏处的文字反倒弹出图片预览」 | `MarkdownTextView.swift`、`MarkdownTextView+Footnote.swift`、`MarkdownImageSizeTests.swift` |

---

## 名词小词典

| 词                                  | 大白话                                                       |
| ----------------------------------- | ------------------------------------------------------------ |
| **源码（source）**                  | 用户实际存进文件的那段 markdown 文本                         |
| **渲染文本（rendered）**            | 编辑器**显示**出来的样子。和源码不一定等长，因为行首会多插圆点、图片会占位等 |
| **源码偏移 / `sourceOffset`**       | 某个字符在**源码**里排第几个（UTF-16 单位）。相当于「书里的第几页」 |
| **渲染偏移**                        | 某个字符在**渲染文本**里排第几个。相当于「屏幕上第几行第几个字」 |
| **快照**                            | 某个时间点拍下来的一份数据副本。文档一改，它就可能过期       |
| **标题指纹 / `headingFingerprint`** | 给整篇标题拍的一张「位置 + 层级 + 文字」的清单。两张比一比就知道目录要不要刷新 |
| **目录 / 大纲（outline）**          | 右侧那个列出所有标题、点了能跳过去的悬浮组件                 |
| **cell / cell 复用**                | 列表里「一行」的视图对象。系统只会为**屏幕上看得见**的行创建几个，滚出屏幕的会被回收、拿去显示新滚进来的行 —— 所以一个 cell 对象会「先后代表好几行」，每次复用都必须把上一行的状态清干净 |
| **快照（两种含义）**                | ①（第 1 条）某个时间点拍下来的数据副本，文档一改就可能过期；②（第 5 条）`NSDiffableDataSourceSectionSnapshot`，交给列表控件的「这次该显示哪些行、谁折着」的一份交代 |
| **全部折叠 / 全部展开**             | 目录标题栏上的按钮，一刀切地收起 / 放出所有带下级的章节。只动目录列表，不动正文 |
| **块（block）**                     | 编辑器把整篇 markdown 切成的一段一段，比如一个标题、一个段落、一个代码块。**每个块在编辑后都会被重新创建**，它的 `id`（UUID）也跟着换新 |

## 2. 粘贴后 Cmd+Z，残留几个字（2026-09-13）

### 现象

粘贴这段文本：

```markdown
- [x] 已完成
- [ ] 未完成
```

光标落在「未完成」后面，按 Cmd+Z 撤销 → 末尾**残留「完成」两个字**，而且源码也被污染了。

### 为什么会这样

编辑器存进 `textStorage` 的是**渲染后的文本**，它的长度和**源码**长度不一定相等。

无序列表项渲染时，行首会多插一个圆点占位符（`U+FFFC`，占 1 个字符位）：

| | 长度 | 内容 |
|---|---|---|
| 源码 | **19** | `- [x] 已完成\n- [ ] 未完成` |
| 渲染 | **21** | 每行行首多一个 `￼` |

流程是：粘贴 → 系统按**源码的 19 个字符**记了一笔「撤销 = 删掉 19 个字符」→
我们的渲染管线把这 19 个字符重渲染成 **21** 个字符（且那次替换故意不登记撤销）→
账对不上了。Cmd+Z 从 21 个字符里删掉 19 个，**末尾正好剩下差的那 2 个字**。

### 怎么修的

**键盘输入继续交给系统撤销；「命令类编辑」（粘贴 / 剪切 / 插图片）由编辑器自己接管**，
按**整篇源码快照**登记撤销。撤销时用 `setMarkdown` 把整篇源码换回去 ——
渲染是确定性的，换回去逐字符一致，所以撤销栈里更早的记录也不会被带歪。

### 为什么不能交给系统

系统按「插入时的长度」记账。只要编辑器在插入之后又改变了长度，这笔账就作废。
命令类编辑必然要重渲染，所以必然作废 —— 只能自己管。

### 已知边界（没修的部分）

**输入本身就会改变渲染长度的场景**，比如在行首敲 `- ` 把段落变成列表项，
仍然走系统撤销，那条记录同样会失效。但它在系统内部，拿不到也删不掉。
要彻底干净得自管整条撤销栈，是另一个量级的改造。

**详细排查过程见技能**：`~/.workbuddy/skills/ios-wysiwyg-editor-undo-desync`

---

## 3. 点目录要连点好几次才跳到位（2026-09-13）

### 现象

点一次目录，光标**不一定到位**：点 `9. Unordered List` 要点 5 次才跳对，
点 8 次会直接滚到最后一行。

### 为什么会这样

iOS 的文本系统（TextKit 2）是**按需排版**的 —— 只排当前这一屏能看到的内容。
屏幕外还没排过的区域，你问它「这段文字在哪个坐标」，它给的是**估算值**，不是真值。

实测过一个真实位置在 `2783` 的标题，它一直报 `1817`。
更坑的是 `contentSize.height` 也是估算的（报 8134，真实内容到 9700 以上）。

所以在「算一次坐标、滚一次」的老写法下，一次点击根本不可能到位 ——
用户只能自己多点几次，靠每次滚动把目标「喂」进已排版区域，才慢慢逼近。

### 怎么修的

改成**迭代逼近**：反复执行「量一下视口现在渲染到哪段文字 → 按当前字符密度换算还差多远 → 滚过去」，
2~4 轮就收敛。收敛后做**像素级精细对齐**（把光标放到离屏幕上沿 16pt 的位置）。

同时用**跳转序号**（`outlineJumpToken`）把上一轮的残余步骤作废 ——
免得用户连点两个不同标题时，两个目标互相拉扯。

**详细排查过程见技能**：`~/.workbuddy/skills/ios-wysiwyg-editor-stale-offsets`

---

## 4. 斜体和粗斜体对中文不生效（2026-09-13）

### 现象

写 `*斜体*`、`***粗斜体***`，英文能看出来是斜的，**汉字完全不动** ——
用户看起来就是「这编辑器不支持斜体」。属性层面其实全对（字体特征里确实有斜体标记），
就是画出来的汉字是正的。

### 为什么会这样

系统的中文字体（苹方 PingFang）**根本没有斜体字形**。
我们给斜体文字换的「斜体字体特征」，英文 SF 字体认（有 `*-Italic` 这套字形），
轮到汉字时系统按字符回退到苹方 —— 苹方没有斜的，就照正的画。

类比：你让印刷厂「用斜体印这一段」，印刷厂的英文字库有斜体模板，照办；
中文字库里压根没刻斜体模板，它就自作主张用正体印了 —— 而且不报错。

### 怎么修的（以及两条死路）

给斜体范围内的**汉字**换一个带「仿斜矩阵」的字体：把字形的上半部分往右掰一点，
硬掰出斜体的样子（`UIFont` 扩展 `withSlant(_:)`）。英文不动 —— 它有真斜体，再掰就歪过头。

试过两条路都走不通，别再试：

1. **`.obliqueness` 属性**：TextKit 1 的老属性，**TextKit 2 排版时直接忽略**。
   实测：属性清清楚楚挂在 textStorage 上（测试能读到 0.2），画出来纹丝不动。
2. **`UIFontDescriptor.withMatrix(_:)`**：在 Mac Catalyst 上**不可用**，编译期直接报错。

最终能用的写法：把现有字体描述符的**全部属性抄下来**（`fontDescriptor.fontAttributes`），
追加一个 `.matrix` 属性，再重建描述符。
⚠️ 千万不能偷懒只传 `.name: fontName` —— 系统字体叫 `.SFNS-…` 这种点开头的内部名，
按名字重建会**找不到字体**，悄悄回退成 Times New Roman（不报错，字全变了才发现）。

### 怎么验证的

- 单元测试：`testItalicSlantsCJKAndKeepsLatinUntouched`（中文换了字体、英文保持真斜体）、
  `testBoldItalicCJKKeepsBoldAndSlant`（粗斜体既要保留粗、也要带矩阵）；
- 渲染成 PNG 肉眼比对（汉字真的往右倒了）；
- 真实 App 打开 `testcase/斜体粗斜体测试用例.md` 冒烟。

### 以后注意

- 「属性挂上了但画面没变」先怀疑 **TextKit 2 不认这个属性**，换 TextKit 1 时代的属性前先画出来看看；
- 重建字体描述符**永远抄全量属性**，不要按名字拼 —— 点开头的系统字体名按名字找不到；
- 中文仿斜的实现和开关（`MarkdownTheme.cjkItalicSlant`，0 = 关闭）都在
  `MarkupToAttributedRenderer.applySyntheticItalicToCJK`，想调倾斜度改主题那一处就行。

---

## 10. 在样式表里改 linkColor，链接颜色没变（2026-09-16）

### 现象

在 `MarkdownTheme` 里把 `linkColor` 改成任何颜色，界面上的链接**一点变化都没有** ——
始终是正文那个颜色。但链接本身是好的：能点、能长按打开（说明 `.link` 属性其实挂上了）。

### 为什么会这样：链接用「只补空缺」的方式上色，可文字早就有颜色了

渲染是「先里后外」的：最里面的文字节点先被 `visitText` 渲染出来，那时候就套上了
`bodyAttributes`，里面已经含 `.foregroundColor: textColor`。

然后才轮到外层的 `visitLink` 给整段上链接色。可它用的是 `addAttributesIfAbsent`，
这个函数的语义是「**已有属性优先，我只填空缺**」：

```swift
// RenderedFragment.swift —— addAttributesIfAbsent 里那几行
var merged = attributes           // 想加的新属性（这里是 linkColor）
for (key, value) in existing {    // 已有的属性（这里是 textColor）
    merged[key] = value           // 已有的盖掉新的
}
```

`foregroundColor` 这个 key 早就存在了（是正文色），于是 `linkColor` 被直接挤掉。

而 `.link`（URL）倒是加上了 —— 它是个**全新**的 key，不属于「已经有」的东西，
所以链接依然能点开。这就解释了「为什么链接能用，偏偏颜色不对」。

**生活化类比**：给一张已经涂满颜色的纸再上色，规则是「只涂还没涂到的地方」——
整张纸都涂过了，新颜色自然一点都上不去。

### 怎么修的

`visitLink` 换成 `setAttributes`（强制覆盖）。它只覆盖传进去的那几个 key，
字体、段落样式这些别的属性都保留：

```swift
// MarkupToAttributedRenderer.swift —— visitLink
out.setAttributes(theme.linkAttributes)     // 原来是 addAttributesIfAbsent
if let destination = link.destination, let url = URL(string: destination) {
    out.setAttributes([.link: url])
}
```

顺手在 `addAttributesIfAbsent` 的注释里加了一句提醒：它本来是给 Emphasis / Strong 这类
嵌套语法准备的（外层不该把内层行内代码的等宽字体盖掉），凡是「必须盖掉正文色」的样式
都不能用它。

### 怎么验证的

1. **先证明它真的坏了**（反向验证）：新写了 `MarkdownLinkColorTests`，跑出来
   `("0.13,0.21,0.28,1.00") is not equal to ("0.10,0.20,0.90,1.00")` ——
   链接文字拿到的确实是**正文色**，不是设进去的蓝色。
2. 修完三条全过：链接文字是 linkColor、链接**外面**的正文仍是 textColor、`.link` 属性还在。
3. 全量 178 条测试，只有 `testCodeBlockBackgroundFollowsScroll` 一条失败 ——
   它对段落间距敏感，来自另一处未提交的改动（`paragraphSpacing` 6→12），与本次无关
   （见第 9 条「以后注意什么」的第 3、4 点）。
4. 编译：Catalyst + iOS 两个平台都 BUILD SUCCEEDED。

### 以后注意什么

1. **`addAttributesIfAbsent` 不是「加属性」，是「补空缺」。** 判断办法：问一句
   「这个 key 在更内层是不是已经被设过了？」—— 只要是（尤其是 `foregroundColor`，
   叶子文字节点一定设过），用它就等于没写。这种情况要用 `setAttributes`。
2. **改了样式没反应时，别急着怀疑「主题是不是没传进来」。** 这次先确认了
   `MarkdownTextView` 用的就是 `MarkdownTheme.default`（第 135 行），链路没问题，
   才往下查到是上色方式的问题。排查顺序：样式表 → renderer → attributed string → 屏幕。
3. **断言颜色要比 RGBA 分量，别直接比 `UIColor` 对象。** 同一个颜色可能落在不同的
   色彩空间里（sRGB / Display P3），直接 `XCTAssertEqual` 会误判成不相等。
4. 顺带说一句：`linkAttributes` 仍然保持「样式表是唯一样式出处」，
   `visitLink` 里没有写死任何颜色。

### 补记：富文本改对了，屏幕上还是蓝的（同一症状的第二层根因）

上面修完之后富文本里的链接色确实是红的，可界面上**照样是蓝的**。同一个症状底下压着
两个独立的根因，第二个在 UIKit 那一层：

**`UITextView` 画 `.link` 范围时，会拿自己的 `linkTextAttributes` 盖上去，默认值是系统蓝
`0.00,0.53,1.00`。** 实测（把一段「红色文字 + `.link`」赋给一个全新的 `UITextView`）：

```text
赋值后从 textView.attributedText 读回来 = 1.00,0.00,0.00,1.00   ← 富文本没被改，还是红
textView.linkTextAttributes             = [NSColor = 0.00,0.53,1.00,1.00]   ← 系统蓝
```

最阴的地方在于：**它只影响绘制，不改字符串。** 从 `attributedText` 里查颜色永远是对的，
所以上一轮那三个查富文本的用例全绿，也照样挡不住这个 bug。只有对着真正的
`UITextView` 查 `linkTextAttributes` 才能拦住。

修法：`MarkdownTextView` 新增 `syncLinkTextAttributes()`，把 `theme.linkAttributes`
交给 `linkTextAttributes`（出处仍然只有样式表一份），在 `configureTextView()` 和
`refreshTheme()` 两处调用。

```swift
private func syncLinkTextAttributes() {
    linkTextAttributes = renderer.theme.linkAttributes
}
```

**以后注意什么**

1. **凡是「富文本里挂了 `.link`」的样式，都要同时在 `UITextView` 上设一遍**
   （`linkTextAttributes`）。光写进 `NSAttributedString` 只对 `UILabel` / 自己画的情况有效。
2. **排查「改了样式没反应」要一路查到屏幕**：样式表 → renderer → attributed string →
   **UITextView 自身的样式属性**。这一轮就是卡在最后一环 —— 前三环全对。
3. 反向验证是真的：把 `syncLinkTextAttributes()` 注掉之后，新用例立刻报
   `("0.00,0.53,1.00,1.00") is not equal to ("1.00,0.00,0.00,1.00")`。

---

## 12. 任务项正文里带 [x]，复选框却显示成「已勾选」（2026-09-18）★

### 12.1 现象

文档里这么写：

```markdown
- [ ] 未完成的项，点一下变 [x]
```

这一行的标记明明是 `[ ]`（没勾），可它那个复选框**画成了勾上的绿框**。
去点它，**点了没反应** —— 源码还是 `[ ]`，框也还是勾着的。

触发条件是这一行的**正文里也有一个 `[x]`**。把正文里那个 `[x]` 删掉，一切正常。

### 12.2 为什么会这样

两件事凑在一起。

**第一件：判定勾没勾的，是「整行文字里有没有 `[x]`」。**

本项目解析 markdown 走的是 `swift-markdown` → 底层 `cmark-gfm`。
它任务列表扩展里判定状态就一句（`extensions/tasklist.c`）：

```c
parent_container->as.list.checked =
    (strstr((char *)input, "[x]") || strstr((char *)input, "[X]"));
```

`input` 是**整行**，而 `strstr` 是「在这个字符串里找子串」——
所以只要这一行**别处**还出现一个 `[x]` / `[X]`，整项就被报成「已勾选」，
哪怕真正的标记是 `[ ]`。实测：

| 源码 | 语法树给的 `item.checkbox` | 真相 |
|---|---|---|
| `- [ ] 未完成的项` | unchecked | `[ ]` |
| `- [ ] 未完成的项，点一下变 [x]` | **checked** | `[ ]` |
| `- [ ] 第一行`⏎`  续行有 [x]` | unchecked | 只看第一行，续行不算 |
| `- 正文里有 [x]`（行首没有标记） | `nil`（不是任务项） | 行首这个判定是准的 |

**第二件：我们把这个字段直接拿来画按钮了。**

渲染器 `markCheckboxLiteral` 里原本是：

```swift
isChecked: checkbox == .checked    // checkbox 就是 item.checkbox
```

于是「语法树说勾了」= 「按钮画成勾上」。
**文本框里那三个字符到底是什么，从头到尾没人看过一眼。**

**为什么点不动**：点一下会走 `toggleCheckbox`，它按 `info.isChecked` 决定往源码里写什么 ——
既然 `isChecked` 是（错的）`true`，它就写 `[ ]`；而源码本来就是 `[ ]`，等于什么都没干。
所以症状是「**点了没反应**」，而不是「切反了」。

### 12.3 怎么修的

只改一处：**勾选状态从源码里那三个字符本身读**；语法树只保留「这一行是不是任务项」这一个用途。

`MarkupToAttributedRenderer.swift`：

```swift
guard item.checkbox != nil,                                  // 只用来判定「是不是任务项」
      let literal = checkboxLiteral(in: markerText, markerRange: markerRange) else { return }
let info = CheckboxInfo(sourceStart: blockOrigin + literal.range.location,
                        isChecked: literal.isChecked)         // ← 状态读字面量本身
```

原来的 `checkboxLiteralRange` 顺手升级成 `checkboxLiteral`：找 `[` 的同时，
把中间那个字符一起读出来（`x` / `X` 算勾上，其余算没勾）。

为什么不干脆绕开 cmark 自己判断「是不是任务项」：那一半语法树**是准的**
（`- 正文里有 [x]` 不会被误判成任务项），没必要自己再造一套。
**错的只有「状态」这一个字段。**

### 12.4 怎么验证的

先写了个**探针单测**（用完就删），把三层并排打出来：

1. 语法树给的 `item.checkbox`
2. 渲染后 `.markdownCheckbox` 标记落在哪三个字符上
3. 真实视图里那个按钮到底画没画对勾

三层一比，问题立刻现形（对照表见 12.2）。**别只盯其中一层猜。**

然后补了 3 条正式回归测试（在 `MarkdownEditorHy4Tests.swift` 的复选框那一节）：

| 测试 | 盯的是什么 |
|---|---|
| `testCheckboxStateComesFromLiteralNotWholeLine` | 数据层：标记是 `[ ]` 就不许报成已勾选；正文含 `[ ]` 的 `[x]` 项仍要算勾上 |
| `testCheckboxButtonLooksUncheckedWhenLiteralIsUnchecked` | **视图层**：从视图树里捞出那个真按钮，问它有没有画对勾 |
| `testClickingCheckboxWithDecoyXStillWritesX` | 点击真能改到源码，且正文里那个 `[x]` 一个字不动 |

**反向验证**：把 `isChecked:` 临时改回 `item.checkbox == .checked` 再跑 ——
3 条新测试**全部变红**，2 条老测试照过（这正是它能溜过测试的原因）。
这一步很关键：**一条从没红过的测试，证明不了它守得住什么。**

回归：全量 228 条只有 1 条红（`testCodeBlockBackgroundFollowsScroll`，
成因是 11.5 末尾说的那个段落间距改动，与本次无关 —— 那个测试文档里一个任务列表都没有）；
Catalyst / iOS 双平台编译通过；Catalyst 冒烟存活、用户真实文稿目录未被写。

### 12.5 以后注意什么

1. **上游解析器给的「语义字段」不等于真相。** 本项目的铁律是「源码才是唯一真相」，
   落到代码上就是：**能读字面量就别读解析结果**。这次栽的就是信了 `item.checkbox`。
2. 但也别一杆子打翻：`item.checkbox != nil`（是不是任务项）**是准的**，该用还用。
   分清「一个字段的哪一部分可信」比「整个字段信不信」更重要。
3. **症状是「点了没反应」时，先怀疑「它算出来的当前状态本身就是错的」。**
   状态算错 → 写回的就是原值 → 表现成空操作，不报错、不崩。
4. 「UI 显示 vs 数据对不上」这类问题，最省事的排查手段就是**探针单测三层并排打印**
   （解析器字段 / 渲染标记 / 真实视图控件）。

---

## 13. 点一下复选框，方框就变宽（2026-09-18）★

### 13.1 现象

任务项的复选框，**点一下（从 `[ ]` 变成 `[x]`）方框就变宽**，再点回去又缩回来。
宽度差得不小，一眼能看出来在「跳」。

> 提出这个问题的原话是：「`UIImage(systemName: "checkmark", withConfiguration:)` 点击后变宽」。
> 顺着这句话去查符号本身，会一无所获 —— 真正变的是**方框**，不是对勾。见下。

### 13.2 为什么会这样

复选框是**叠在源码 `[ ]` / `[x]` 上面**的一个原生按钮（不是插进文本流的附件）。
为了让方框把那三个字符整个盖住，宽度当初是这么算的：

```swift
// 旧写法：按**当前这一项**的字面量取宽
let width = max(checkboxSide, literal.width)
```

问题出在 `literal.width` —— 它是**当前那三个字符在图里的实际宽度**，
而这三个字面量在图里**宽度本来就不一样**（正文 17pt 系统字体实测）：

| 字面量 | 图里宽度 | 旧写法算出的方框宽 |
|---|---|---|
| `[ ]` | 15.95pt | **16.00pt**（`max(16, 15.95)`） |
| `[x]` | 20.09pt | **20.09pt** |
| `[X]` | 22.71pt | **22.71pt** |

于是**点一下 `[ ]` → `[x]`，方框就从 16pt 长到 20.09pt**，多出来 4.1pt。
`[X]`（大写）更夸张，长 6.7pt。

**宽度本来就不该跟「当前状态」走** —— 同一份文档里、勾上没勾上的复选框，
在用户眼里就是同一种控件，尺寸必须一样。

顺带一提：同一份文档里同时有勾上和没勾的项时，**不用点就已经一宽一窄**了，
这也是同一个根因。

### 13.3 怎么修的

分两件事，第一件是根因，第二件是顺手把对勾也变成可控的。

**① 宽度只跟字体有关，跟状态无关**（`MarkdownTextView.swift`）。

把三种字面量都量一遍、取最宽的那个，全场共用这一个定值：

```swift
// positionCheckboxes() 里，循环之前算一次
let coverWidth = checkboxCoverWidth(side: side)

private func checkboxCoverWidth(side: CGFloat) -> CGFloat {
    guard let font = checkboxLiteralFont() else { return side }
    let widest = ["[ ]", "[x]", "[X]"]
        .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        .max() ?? 0
    return max(side, widest)      // 仍要 ≥ 方框边长
}
```

字体从 `textStorage` 里那三个字符的实际 `.font` 属性读（整篇正文同一套字体，量第一个就够），
所以主题改字号、改字体，这里自动跟着变，不用写死数字。

> **2026-09-18 补充**：同一天晚些时候默认改成了「**不遮盖**」——复选框不再压住 `[x]`，
> 而是坐在 `- ` 和 `[x]` 之间留出来的一块「座位」上（用户要的排布）。
> 于是 `checkboxCoverWidth` 这套宽度只对 `coversCheckboxLiteral = true` 的老模式还有意义；
> 新默认路径下方框宽度恒等于 `checkboxSide`，压根没有「变宽」的余地。
> 详见 `doc/任务列表渲染方案.md` 末尾的「实际实现」一节。

**② 对勾改成自己画**（`CheckboxControl.swift`）。

原来用 `UIImage(systemName: "checkmark", withConfiguration:)`，
大小由 `configuration.pointSize` 定死，**和方框边长没有任何关系** ——
而方框边长是主题里可配的（`taskList.checkboxSide`）。符号不会跟着方框变，
只能写一个「凑出来正好」的 pointSize 去碰运气；系统换一套符号度量就偏了。

改成按方框边长算笔画粗细和留白、用 `UIGraphicsImageRenderer` 画一张 `side × side` 的图：

```swift
let lineWidth = max(1, side * 0.14)     // 笔画粗细
let inset = side * 0.26                 // 四周留白
// 一个普通的对勾：左边起笔偏下 → 下方折点 → 右边收笔偏上
path.move(to: CGPoint(x: inset, y: side * 0.53))
path.addLine(to: CGPoint(x: side * 0.42, y: side - inset))
path.addLine(to: CGPoint(x: side - inset, y: inset))
```

画成黑色 + `.alwaysTemplate` —— 颜色照旧由 `tintColor`（主题的 `checkmarkColor`）决定，
所以换主题、切深浅色都不用动这里。

### 13.4 怎么验证的

先写了个**探针单测**（用完就删），把四样东西并排打出来：

```
[PROBE] before #0 literal=[ ] checked=false literalW=15.953663476293599 buttonW=16.0
[PROBE] before #1 literal=[x] checked=true  literalW=20.0874525387936 buttonW=20.0874525387936
[PROBE] before #2 literal=[X] checked=true  literalW=22.7104994137936 buttonW=22.7104994137936
[PROBE] before symbolImageSize=(13.0, 12.0)      ← 对勾图片本身恒定，压根没变
```

一句 `print` 就把「不是符号的锅、是方框的锅」钉死了 —— **别照着用户的猜测去查**，
先把事实打出来。

然后补了 3 条正式回归测试：

| 测试 | 盯的是什么 |
|---|---|
| `testCheckboxWidthDoesNotDependOnCheckedState` | 同一份文档里 `[ ]` / `[x]` / `[X]` 三项的方框**必须一样宽**，且不窄于要盖住的字面量 |
| `testCheckboxWidthStaysAfterToggling` | **用户看到变化的正是点击那一刻**：点一下 `[ ]` 变 `[x]`，宽度不许变 |
| `testCheckmarkIsSelfDrawnSquareWithinBox` | 对勾是自绘的：正方形、不比如框高、走模板模式（颜色交给 tintColor） |

**反向验证**：把宽度改回 `max(side, literal.width)` 再跑 ——
2 条宽度测试变红，报的就是用户看到的那组数：

```
实际宽度：[16.0, 20.0874525387936, 22.7104994137936]
点一下 `[ ]` 变 `[x]`，方框宽度不该跟着变：("Optional(20.087...)") is not equal to ("Optional(16.0)")
```

还原后全绿。回归：全量 **235 条 0 失败**；Catalyst / iOS 双平台编译通过；用户真实文稿目录未被写。

### 13.5 以后注意什么

1. **浮在文本上的控件，尺寸别从「当前状态对应的文本度量」里算。**
   这里的 `literal.width` 就是「当前状态对应的度量」—— 状态一变它就变，
   控件跟着跳。这类量应该是**常量**（只跟字体 / 主题有关），循环外算一次、全场共用。
2. **用户报的根因未必是根因。** 这次原话指着 SF Symbol 说「点击后变宽」，
   但探针打出来符号尺寸 `(13, 12)` 从头到尾没动过。**先把事实打出来，再动手。**
3. **别让控件的尺寸依赖某个「凑出来的数字」。** 旧的 `pointSize: 11` 就是凑的：
   它和方框边长（主题可配）之间没有任何关系，改主题就会对不上。
   能按比例算就别写死。
4. 自绘图 + `.alwaysTemplate` 是个好组合：**形状自己定，颜色还给 `tintColor`**，
   浅色深色、换主题都不用另写一遍。

---

## 14. 任务项里按一次退格，`- [ ] ` 整段被吃掉（2026-09-18）★

### 14.1 现象

源码只有一行 `- [ ] 未完成的项`，光标停在 `]` 的右边，按一次删除键：

- **源码**：`- [ ] 未完成的项` → `未完成的项`（列表标记 `- ` **也被吃了**）
- **屏幕**：只剩一个没勾选的空复选框 + 「未完成的项」，要等下次滚动才干净

（这是两个 bug 叠出来的同一个现场：删除范围算大了 + 装饰层没及时重刷。）

### 14.2 类比

`- ` 和 `[ ] ` 是两根挨着的短木条，中间垫着一块**透明塑料块**（复选框座位）。
退格的规则是「碰到木条，就把它那一根整根抽走」。塑料块一旦也被当成木条，
三样就粘成了一根长木条 —— 一抽，整根全出来。

### 14.3 根因（两层）

1. `RenderedFragment.decorationAttachment(...)` 给**每一个**装饰附件都无条件打了
   `.markdownSyntaxMarker`。这个属性本来是给引用竖条、代码块背景这类**真·结构装饰**
   准备的（删它们就该整段删），但复选框座位只是个**占位**，于是它把左边 `- `
   和右边 `[ ] ` 两段**本来独立**的标记粘成了一段连续标记。
2. `MarkdownDocumentStore.expandedSyntaxMarkerRange` 扩展删除范围时只看「有没有标记」，
   不认座位，于是一路从 `]` 扩到 `- ` 前面。
3. 附带一层：装饰层（复选框按钮、代码块背景、引用竖条）只在 `layoutSubviews` 里刷新，
   而 TextKit 2 的 `performEditingTransaction` 改文本**不保证**让 textView 重新布局 ——
   渲染文本里座位已经没了，屏幕上那个按钮却一直留着。

探针把渲染文本按「属性 run」打出来，一眼就看见座位被标了：

```
i=0 len=2 marker=true  ch="- "
i=2 len=1 marker=true  seat=true  att=CheckboxSeatAttachment   ← 座位也带语法标记
i=3 len=3 marker=true  box=true   ch="[ ]"
i=6 len=1 marker=true  ch=" "
```

### 14.4 修法（四处，都很小）

| 文件 | 改动 |
|---|---|
| `Rendering/RenderedFragment.swift` | `decorationAttachment` 多一个 `isSyntaxMarker: Bool = true` 参数；座位这类占位传 `false` |
| `Rendering/MarkupToAttributedRenderer.swift` | 座位调用点传 `isSyntaxMarker: false` |
| `Model/MarkdownDocumentStore.swift` | 扩展时**碰到座位就停**；起点落在座位上时先往后挪一格（座位不占源码，直接删它算出的范围是空的，表现为「按了没反应」） |
| `Editing/MarkdownTextView.swift` | `applyEdit` 末尾补 `setNeedsLayout()` + `updateCodeBlockDecorationsIfNeeded()` |

修完的行为：

| 光标位置 | 源码变化 | 说明 |
|---|---|---|
| `]` 右边 | `- [ ] 未完成的项` → `- 未完成的项` | 只走复选框那几个字符，列表标记留着 |
| 座位上 | 同上 | 座位属于它右边那一段 |
| `- ` 里 | `- [ ] 未完成的项` → `[ ] 未完成的项` | 整段 `- ` 走掉，这一行降级成普通段落（和普通列表项圆点一致） |

### 14.5 为什么不这样做

- **没照搬 TextKit 1 参考项目**（`markdown_textkit1_qwen3.8max`）的「删一个字符就删一个字符」：
  那个版本没有 `.markdownSyntaxMarker` 这套机制，删一下会留下 `- [ 未完成的项` 这种半截标记，
  既不是任务项也不是普通句子。本项目「碰到结构标记就整段删」的设计更合理，保留。
- **没只改扩展逻辑、让座位继续带标记**：那样删除行为也能对，但「座位是语法标记」这个说法本身是错的 ——
  下次再往标记中间夹一个新装饰，同样的坑会再来一次。属性层改对 + 扩展层兜底，两道都留着。

### 14.6 性能

`applyEdit` 多调了一次装饰层重算。但 `needsCodeBlockRefresh = true` 本来就会在**下一次**
layout 里触发同一件事，这次只是把「下一次」提前到「这一次」，没有新增量级。

### 14.7 怎么验证

新增 5 条回归测试放在**新文件** `MarkdownEditorHy4Tests/TaskListBackspaceTests.swift`
（新加测试文件不用改 pbxproj）：

| 测试 | 盯的是什么 |
|---|---|
| `testBackspaceAfterBracketKeepsListMarker` | `]` 右边退格 → 源码必须正好是 `- 未完成的项\n` |
| `testBackspaceOnSeatDeletesCheckboxLiteral` | 座位上的退格 → 同样删掉 `[ ] `，不许变成空操作 |
| `testBackspaceOnListMarkerDegradesToParagraph` | `- ` 里退格 → 整段走掉，降级成段落 |
| `testCheckboxButtonDisappearsImmediatelyAfterDelete` | 删掉最后一个任务项后，按钮必须**立刻**从屏幕上消失 |
| `testCheckboxSeatIsNotSyntaxMarker` | 机制层护栏：座位不许带 `.markdownSyntaxMarker` |

**反向验证**跑了两轮，确认每条修复都有测试钉着：

- 座位改回 `isSyntaxMarker: true` → `testCheckboxSeatIsNotSyntaxMarker` 变红
- 注掉 `setNeedsLayout()` + `updateCodeBlockDecorationsIfNeeded()` →
  `testCheckboxButtonDisappearsImmediatelyAfterDelete` 变红

### 14.8 以后注意什么

1. **装饰附件要分两类**：真·结构装饰（删它就该整段删）vs 纯占位（绝不能算标记）。
   `decorationAttachment` 的默认值是给前者用的，后者必须**显式**关掉，
   并且在代码里写清楚为什么 —— 不然下次有人「统一一下」就把它改回去了。
2. **「向两侧扩展直到属性断掉」这类逻辑，一定要问一句：中间会不会夹着别的东西。**
   本次是座位，下次可能是图片占位、折叠三角 ⋯ 任何一个装饰。
3. **改了文本就主动刷一次装饰层。** TextKit 改文本 ≠ view 会重新布局 ——
   「数据对了，屏幕没跟上」这种 bug 全靠这一条防。

---

## 17. 滚动时代码块灰底停在错地方，停下才跳到位（2026-09-18）★

### 17.1 现象

打开一份**长文档**（代码块在首屏之外）往下滚：

- 灰底先停在一个**偏上**的位置（实测偏 84pt，越往下越离谱），
  正好压在开围栏那一行上 —— ` ```swift ` 这几个字看着像是写在灰底里的
  （用户原话：「swift 跟背景重合了」）；
- 手一停，灰底「啪」地挪到代码背后。

也就是说：**滚动过程中一直是错的，只有停下来才对。**

### 17.2 为什么会这样（两层原因叠在一起）

**第一层：屏幕外的坐标是估算值。**
TextKit 2 只给 viewport 附近排实；`enumerateTextLayoutFragments` 走到屏幕外的区域时，
拿到的 frame 是**估算**的（和第 3 条「点目录要连点好几次」是同一个根因）。
打开长文档那一刻，代码块还在屏幕外，算出来的矩形就是错的（实测差 84pt），
这个值被存进了 `codeBlockFrames` 缓存。

**第二层：滚动时只平移、不重算，而「补算」的时机也不对。**
滚动回调里当时只做「文档坐标减滚动偏移」的平移 —— 用的是第一层那个错的缓存值。
唯一的纠正机会是滚动停下 0.15s 后的 `scheduleFoldRedraw`（整篇重算），
所以用户看到的「跳」就是这一次纠正。

那为什么不在滚动回调里直接重算？试过了，**没用**：
TextKit 的 viewport 是在 `layoutSubviews`（`super.layoutSubviews()` 那一轮）里更新的，
滚动回调发生在布局**之前**，这时候问 TextKit，它还在用上一次的 viewport 回答你 ——
算出来的还是同一个错值（实测 451.67 vs 正确值 559.67，一模一样的偏差）。

### 17.3 怎么修的

核心思路：**滚动时只重算「视野附近」的那几个块**，视野外的继续用缓存。

- `computeCodeBlockFrames(reusingOutside:)` / `computeQuoteBarFrames(reusingOutside:)` /
  `computeCheckboxFrames(reusingOutside:)` 多了一个「只算这一带」的参数：
  落在带子外面的沿用上一轮结果，一次 TextKit 都不问。
  带子取「viewport 上下各扩一屏」—— 估算误差最大也就几百 pt，扩一屏足够兜住
  「缓存里看着还在外面、其实已经露出来了」的块。
- 重算放在 `layoutSubviews` 里（`updateCodeBlockDecorationsIfNeeded` 的纯滚动分支），
  也就是 `super.layoutSubviews()` **之后** —— 这时 viewport 才是新的。
- 滚动回调里改成三步：先按缓存平移（便宜，每帧）、再 `setNeedsLayout()`、
  再 `scheduleScrollLayout()`（排一个 async 的 `layoutIfNeeded`，一帧最多一次）。
  最后这一步是保险：系统滚动只改 bounds 原点，**不一定**会自己调 `layoutSubviews`。
- 节流按**滚动距离**（每滚 40pt 才重算一次）而不是按时间：
  块在进视野前一屏就已经进带子被算过了，40pt 的粒度足够早，用户看不到中间状态；
  慢速滚动几乎不触发，不会掉帧。整篇重算仍然只在内容/宽度变化时做。

### 17.4 怎么验证的

- 新增两条测试（都用内联的长文档，不依赖磁盘文件）：
  - `testCodeBlockBackgroundIsCorrectRightAfterScrolling`：滚完后只跑 0.1 秒
    （远小于 0.15s 的兜底），背景位置就要等于「文档坐标减滚动量」，容差 2pt；
  - `testCodeBlockBackgroundDoesNotCoverFenceLineAfterScrolling`：滚动到位后，
    背景顶必须低于开围栏行的文字底部、背景底必须高于闭围栏行的文字顶部
    （这就是「swift 跟背景重合」那条的直接回归）。
- 修之前的实测数字：滚动当帧 227.29、停下后 311.29（差 84pt）；修完两者都是 311.29。
- 272 条单元测试全绿；Catalyst + iOS 真机目标均 `BUILD SUCCEEDED`。

### 17.5 以后注意什么

- **凡是靠 fragment 矩形画的东西（代码块背景、引用竖条、复选框、折叠三角），
  缓存的坐标只在「它当时在视野附近」时才可信。** 屏幕外算出来的值要当成草稿，
  滚近了必须重算 —— 不能指望「算一次管到底」。
- **想拿真坐标，就必须站在 `layoutSubviews` 里（`super` 之后）问 TextKit。**
  在滚动回调、KVO、或者任何「布局还没发生」的时机问，拿到的都是旧 viewport 的答案。
- 别为了「省一次计算」把重算挪出布局流程；也不要在滚动回调里直接同步 `layoutIfNeeded()`
  （可能和布局过程互相递归），用 async 排到下一帧。
- 关于围栏行要不要进背景：开关早就有了，`MarkdownTheme.showsCodeBlockFenceBackground`
  （默认 `false` = 围栏行不带背景）。这次的「swift 跟背景重合」**不是**开关失灵，
  是坐标错 —— 排查时先分清「效果没实现」和「位置画错了」。

### 17.6 改动文件

- `MarkdownEditor/Editing/MarkdownTextView.swift`（三个 compute 加 `reusingOutside` 参数、
  新增 `nearViewportBand` / `refreshDecorationsNearViewport` / `scheduleScrollLayout`、
  滚动回调改三步走）
- `MarkdownEditorHy4Tests/MarkdownEditorHy4Tests.swift`（新增 2 条测试 + `makeLongDocumentWithCodeBlock`）

---

## 18. 行内代码的灰底盖住了鼠标选中高亮（2026-09-19）★

### 18.1 现象

两个都是行内代码的观感问题：

1. 用鼠标框选一段含着 `` `行内代码` `` 的文字，**别的地方都变蓝了，就代码那一小块还是灰的** —— 看着像没选中（用户原话：「选中文字的背景被行内代码文字的浅灰色遮住了」）。
2. 两侧的反引号 `` ` `` 和代码正文是同一个深色，看着像代码的一部分，不如别的语法标记那么「退到后面去」。

### 18.2 类比

富文本里的颜色分两拨人画：**文字和它的底色是一拨**（`NSAttributedString` 的 `.font` / `.foregroundColor` / `.backgroundColor`，跟着字一起画），**选中高亮是另一拨**（系统自己画的一块半透明蓝底）。

系统把蓝底画在**文字那一拨的下面**。所以只要代码的底色是**不透明的实色**，就等于给代码盖了块不透明的灰板 —— 蓝底被完整盖住，你看到的就是一块灰。

### 18.3 怎么会这样（根因）

`MarkdownTheme.inlineCodeAttributes` 里的底色原本是：

```swift
inlineCodeBackground: UIColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.00)
//                                                        ↑ 问题就在这个 1.00
```

`alpha: 1.00` = 完全不透明。CoreGraphics 画它的时候，下面那层蓝底就彻底看不见了。
注意这**不是** UTI 版本问题、也不是层级写错了 —— 装饰层（代码块灰底那些）压根没参与，它们画的矩形在文字下面、选中高亮下面，反而是对的；坏事的只有「挂在文字上的底色」这一种写法。

### 18.4 怎么修

| 想解决什么 | 改法 |
|---|---|
| 选中时看得见蓝底 | 把底色改成**半透明**：`UIColor(white: 0.5, alpha: 0.12)`。铺在白底上混出来 ≈ 0.94 的浅灰（和原来的 0.95 肉眼看不出差别），而蓝底能透上来 |
| 反引号弱化 | 反引号单独走 `inlineCodeBacktickColor`（默认 0.68 的浅灰）；渲染时把行内代码**拆成三段**上色：左反引号 → 代码正文 → 右反引号 |

为什么用「半透明」而不是「把灰底挪到更下面一层」：

- **不挑分层顺序。** 半透明是「让下面的颜色透上来」，无论系统把选中高亮画在哪一层都正常；挪层则是**押注**在高亮一定在文字下面 —— 系统哪天真改了，选中又看不见了。
- **不用新增一个装饰层。** 项目里代码块灰底 / 引用竖条 / 复选框那些装饰层，代价是「滚动时要跟着重算坐标」（见第 17 条）。行内代码数量多、又贴着文字流，再养一层不值得。

⚠️ 拆三段时，**反引号的个数不能写死成 1**：cmark 允许 `` ``a`b`` `` 这种用多个反引号包住含反引号的内容。写死 1 的话第二个反引号会被当成代码正文，三段全错位。所以按「开头连续几个反引号」现数（`inlineCodeFenceLength`）。

### 18.5 怎么验证的

`MarkdownEditorHy4Tests/InlineCodeStyleTests.swift` 新增 6 条：

| 测试 | 盯的是什么 |
|---|---|
| `testBackticksAreDimmedAndBodyStaysDark` | 左/右反引号是弱化色、中间是代码色；且两个颜色确实不一样 |
| `testBackticksKeepMonospacedFontAndBackground` | 反引号仍然等宽、仍然带底色（否则灰底断成三截） |
| `testInlineCodeBackgroundIsTranslucent` | **底色必须半透明** —— 这条就是选中那个 bug 的护栏 |
| `testTranslucentBackgroundStillReadsAsLightGrayOnWhite` | 半透明底铺在白底上混出来还得是「浅灰」（0.88~1.0 之间），别淡到看不见 |
| `testMultiBacktickInlineCodeSplitsAtTheRightPlaces` | `` ``a`b`` `` 的第 2 个反引号也算围栏、正文里那个反引号不许被弱化 |
| `testSplittingIntoThreePiecesKeepsSourceIntact` | 拆三段上色之后，「展示的就是源码本身」不能破 |

**反向验证**：把反引号个数改回写死 `1`，`testMultiBacktickInlineCodeSplitsAtTheRightPlaces` 立刻报
「第二个反引号也是「围栏」，不能当成代码正文」—— 证明这条测试真的抓得住。

#### ⚠️ 选中效果本身没法写进单测（别在这上面浪费时间）

单测环境里 **UIKit 根本不画系统选中高亮**（实测：`window.makeKeyAndVisible()` + `becomeFirstResponder()` +
`selectedRange` 都设好了，视图树里连一个选中高亮 view 都没有，`layer.render(in:)` 出来的像素也和未选中时一模一样；
连光标 `UIStandardTextCursorView` 都是空的）。所以「选中能不能看见」只能靠**方案本身的正确性**（半透明 ⇒ 顺序无关）
加**肉眼看一眼**，写不出像素级断言。这条测试守的是「半透明」这个前提，不是结果。

### 18.6 以后注意什么

1. **`.backgroundColor` 这种「跟着文字一起画」的属性，永远别用不透明的实色。** 它会盖住画在文字下面的所有东西
   （系统选中高亮、拼写检查波浪线、查找高亮……）。要一段「实色垫底」的效果，就得像代码块那样另开一层画矩形。
2. **改样式之前先分清「谁画的」**：装饰层画的矩形（代码块灰底、引用竖条）和挂在文字上的属性，分层完全不同 ——
   同样是「一块灰底」，一个在选中高亮下面、一个在上面，表现正好相反。
3. **数符号个数别写死。** markdown 里凡是「成对出现的符号」，都允许出现好几个（`` `` ``、`***`、`>>>`），
   写死一个在正常文档里测不出来，遇到特殊写法就错位。

---

## 19. 语言名 `swift` 的底部被代码块灰底压住（2026-09-19）★

### 19.1 现象

代码块第一行是 ` ```swift `，用户报：「swift 这个单词的底部大概有 10% 跟代码块背景顶部重合」。

**默认设置下看不出来**，把「段落间距」调小（或者字号调大、行高调大）之后就很明显 ——
灰底的上沿切进 `swift` 这几个字的下缘，像压住了半截。

### 19.2 类比

灰底那块矩形的位置，是**照着「文字排版后留下的那个框」**定的。

问题在于：那个框（`layoutFragmentFrame`）里装的**不只是字** —— 它还含行距和**段间距**。
段间距被用户调小，框就变矮，于是「框顶往上一个 padding」算出来的灰底上沿跟着往上抬，
抬进了上面那一行（` ```swift `）的字里。

### 19.3 怎么会这样（根因）

`MarkdownTextView.computeCodeBlockFrames` 里算灰底上沿的公式是：

```
灰底顶 = 正文首行 fragment 顶 − padding
```

而 `正文首行 fragment 顶` 正好等于 `围栏行 fragment 底`，围栏行 fragment 的高 = **排版盒高 + 段后间距**。

拿字号 17（`codeBlockVerticalPadding` = 6）算一遍：

| 段落间距 | 围栏行 fragment 底 | 灰底顶 | `swift` 文字底 | 结果 |
|---|---|---|---|---|
| 12（默认） | 22 + 12 = 34 | 28 | 25.5 | 间隙 12.5pt，看着正常 |
| 8 | 22 + 8 = 30 | 24 | 25.5 | 压住 1.5pt |
| 4 | 22 + 4 = 26 | 20 | 25.5 | 压住 5.5pt |
| 0 | 22 | 16 | 25.5 | **压住 9.5pt** |

⚠️ **默认设置之所以看着没问题，纯属巧合**：默认段距 12 恰好等于 `padding × 2`。
换句话说，这个 bug 一直躺在代码里，只是要用户把段落间距从 12 调小才会露头
（设置里 `paragraphSpacing` 的范围是 0...40）。

### 19.4 怎么修

枚举 fragment 的时候**顺手把两条围栏行的「文字排版盒」记下来**，再把灰底的上下沿夹进安全范围：

| 边 | 算法 |
|---|---|
| 上沿 | `max(正文首行 fragment 顶 − padding, 开围栏行文字底 + padding)` |
| 下沿 | `min(正文末行 fragment 底 + padding, 闭围栏行文字顶 − padding)` |

两个概念的区别（这次的关键）：

- **`layoutFragmentFrame`** = 这一段在版面里占的整块地方，**含行距、段前后间距**；
- **`NSTextLineFragment.typographicBounds`** = **只包住字**的那个盒子（上到字顶、下到字底）。

要「躲开某行字」，就必须用后者。默认段距下两个公式算出来的值几乎相等（44.008 与 44.0），
所以默认观感**一点没变**；段距调小或行高调大时，由新增的那一项兜底，间隙恒定等于 `padding`。

另外还有两条小护栏：

- 夹取之后如果上下沿翻了过来（挤到没有高度），**宁可不画这块背景**，也不画一个翻过来的框；
- `showsCodeBlockFenceBackground == true`（整块一个灰方块）时围栏行本来就在背景里，这套夹取自动不参与。

### 19.5 怎么验证的

新增 `MarkdownEditorHy4Tests/CodeBlockBackgroundClearanceTests.swift`，4 条：

| 测试 | 盯的是什么 |
|---|---|
| `testFenceTextClearanceAcrossTypographySettings` | **字号 × 行高 × 段落间距** 15 组组合，灰底上沿必须 ≥ 围栏行文字底 + padding，下沿必须 ≤ 收尾行文字顶 − padding |
| `testDefaultSettingsClearanceEqualsPadding` | 默认设置下间隙**正好**等于 padding（守住默认观感没被改动） |
| `testClearanceStaysTightAtDefaultSpacing` | 默认段距下灰底不能无端被推远/缩短 |
| `testEmptyCodeBlockStillHasNoBackground` | 空代码块（` ``` ` 紧接 ` ``` `）依旧不铺背景，新夹取逻辑没在这儿画出怪框 |

**反向验证**：把两处夹取注释掉，15 组里凡段距 ≤ 4 的 12 组立刻变红，报的正是
「背景顶(30.0) 压到了 swift 这行文字的底部(36.0)」和「背景底(114.0) 压到了收尾 ``` 那行文字(108.0)」
—— 把用户报的重叠原样复现了出来，说明这两条测试真的抓得住。

### 19.6 以后注意什么

1. **别拿 `fragment.frame` 当「文字在哪儿」用。** 它含行距和段间距；要「字的位置」就用
   `NSTextLineFragment.typographicBounds`（代码块背景、装饰层定位都会遇到这个岔路）。
2. **凡是「默认设置下正好对」的算法，先做一遍参数扫描。** 这条 bug 能活下来就是因为默认段距
   恰好 = `padding × 2` —— 单看默认设置永远发现不了。项目里此类"用户可调、又会改变排版几何"的
   参数有：字号（12~28）、行高倍数（1.0~2.0）、段落间距（0~40）、段落首行缩进（0~4 字符）。
3. **像素级的探针要小心「灰底 vs 浅灰文字」互相误判。** 围栏行文字是 0.9 的浅灰（亮度 ≈ 230），
   灰底是 0.95（≈ 245），用「亮度 < 252 就算灰底」去扫会把文字的抗锯齿一起算进去。
   这次量准位置靠的是**几何量**（fragment / 排版盒）对照，像素只用来确认最终观感。


## 20. 最后一个 `}` 戳出代码块灰底（2026-09-19）★

### 20.1 现象

第 19 条修完当天，用户报：「你刚才修改后，最后一个大括号 `}` 的底部超出了背景大概 10% 的高度」
—— 灰底的**底边**反过来切进了正文最后一行，把 `}` 的下半截挤到灰底外面。

实测（字号 17 / padding 6 / 段距 0，正文 60pt 高）：`}` 底部正好戳出去 **6pt = 灰底高度的 10.0%**
—— 用户嘴里那个「10%」就是这么来的。

**默认段距 12 下完全没有这个问题**（灰底上下各空 18pt），所以它是「调小段距才出现」的同一族 bug。

### 20.2 类比

第 19 条给灰底加了两道**夹子**：上沿不许越过上一行字的底、下沿不许越过下一行字的顶。

夹子本身没错，错在**夹过头了** —— 上下两条围栏行和正文之间的空隙，**完全由段落间距撑着**：
段间距是「用户调的」（0~40），一调到 0，空隙就归零。夹子这时候只能往里挤，
挤到把自己该罩的**正文**切掉。相当于为了不碰到隔壁的门，把自己家的桌子锯了一角。

### 20.3 怎么会这样（根因）

先看清两条围栏行和正文之间到底隔着多少空白。实测一个 fragment 的结构是：

```
[这一段的「段前间距」][这一行的行盒][这一段的「段后间距」]
        = 段距              = 字体行高         = 段距
```

注意**段前后各有一份**，不会合并 —— 于是「```swift 的行盒底」到「正文首行行盒顶」的距离 = `段距 × 2`。
灰底的上沿是 `正文首行 fragment 顶 − padding`，而 fragment 顶比行盒顶还高一个段距，两条一串：

| 段距 | ```swift 字底 → 正文首行字顶 | 灰底顶 − 正文首行字顶 | 结果 |
|---|---|---|---|
| 12（默认） | 24 | 18 | 正常 |
| 8 | 16 | 14 | 正常 |
| 4 | 8 | 10 | 正常 |
| 0 | **0** | **−6** | 灰底切进正文 6pt |

段距一旦小于 `padding`，灰底就没地方可躲了：躲开围栏行 = 压住正文，压住正文 = 碰到围栏行，
**两者不可能同时满足**。第 19 条那版代码选择了「碰围栏行」，代价是把正文切掉。

### 20.4 怎么修

用户给的路子是对的：**别算了，给那两条围栏行单独留出空档**。

1. **`MarkdownTheme.codeFenceParagraphStyle(indent:)`（新增）** —— 和代码正文那套段落样式只差一点：
   段前/段后间距取 `max(paragraphSpacing, codeBlockVerticalPadding)`，也就是**至少留一个 padding**。
   这样「围栏行和正文之间的空隙 ≥ padding」就从「用户调多少就是多少」变成**结构上必然成立**。
   默认段距 12 > padding 6，取 max 之后还是 12 —— **默认观感一格没动**，只有段距 < 6 的人会看到变化。
2. **`MarkupToAttributedRenderer.visitCodeBlock`** —— 把 `orphanAttributes[.paragraphStyle]` 从
   `codeStyle` 换成上面那套。**这里一行就够了**：补漏步骤在代码块范围内补的「孤儿字符」
   **正好只有首尾这两条围栏行**（正文是 `sourceSliced` 来的，不在补漏范围内），
   所以传给补漏的段落样式天然就是「围栏行专用」的。
3. **`MarkdownTextView.computeCodeBlockFrames`** —— 把夹子（`openFenceTextBottom` /
   `closeFenceTextTop` 那两个变量、枚举里的排版盒分支、取大小值的四行）**整段删掉**，
   退回最朴素的两行：`灰底顶 = 正文首行 fragment 顶 − padding`、`灰底底 = 末行 fragment 底 + padding`。

修完（段距 0）：灰底从 `42..102`（切掉正文 6pt）变成 `36..120`，上下各稳留 6pt = padding；
正文自己的段距越大，灰底的留白跟着越大（原有行为，没改）。

### 20.5 怎么验证的

`MarkdownEditorHy4Tests/CodeBlockBackgroundClearanceTests.swift` 重写成**守两条不变式**（不再是守某一次夹取的结果）：

| 不变式 | 为什么 |
|---|---|
| 灰底 ≥ 正文首行字顶 − padding，且 ≤ 末行字底 + padding | 灰底必须盖住正文并留够 padding，一丁点都不许切进字里（这条就是用户报的 bug） |
| 灰底 ≥ 开围栏行文字盒底，且 ≤ 闭围栏行文字盒顶 | 灰底不许碰围栏行（撑住它的是围栏行那套段间距的下限） |

参数扫描 **17 组**（字号 14/17/22/28 × 行高 1.0/1.4/1.6/2.0 × 段距 0/4/8/12/40），全绿。

**反向验证**：把围栏行那套段落样式换回 `codeStyle`（等于撤掉修复），凡段距 < 6 的 12 组**全部变红**，
报的正是「灰底顶(30.0) 压到了 ```swift 这行文字(36.0)」「灰底底(114.0) 压到了收尾 ``` 那行文字(108.0)」。

另外用像素扫描核过一遍：`computeCodeBlockFrames` 报的矩形和**实际画出来**的灰底差在 1.5pt 以内
（抗锯齿边缘），不存在「算得对但画得不对」。

### 20.6 以后注意什么

1. **⚠️ 给「算出来的几何」加夹子之前，先问「夹到极限会怎样」。** 夹子的边界如果是**用户可调参数**
   撑出来的（这里是段距），就一定会有人把它调到 0，夹子就会咬到不该咬的地方。
   更稳的做法是**把差额做进结构里**（这里：给围栏行的段间距兜下限），而不是在计算时补救。
2. **这一族的 bug 有个共同特征：默认设置下正好对，靠的是「默认值恰好等于某个内部常数的两倍」**
   （段距 12 = padding 6 × 2）。只看默认设置永远测不出来 —— 见第 19 条注意事项 2 的参数清单。
3. **改测试时要分清「守结果」和「守不变式」。** 第 19 条那版测试守的是「灰底 = 围栏行文字盒 ± padding」，
   它把「夹取」这个实现细节钉死了，于是修法一换测试就得重写。改成守「盖住正文 / 不碰围栏行」之后，
   两条都是**用户能看见的性质**，换实现不用动测试。
4. **改渲染层的属性分配时，先确认「补漏步骤实际会补到哪些字符」**：代码块里补的只有首尾围栏行，
   所以 `orphanAttributes` 就等于「围栏行专用属性」—— 不用再写一套「按行范围改属性」的映射代码。

## 22. 分隔线末尾按回车不换行（2026-09-20）

<!--我是新手，请给我打比方或者举例子的方式说明为什么之前我按10次enter，界面上都不换行，但是我复制全文粘贴到其他地方发现有10此换行-->

**一句话：屏幕上的画面不是你文件里的「原文」，而是原文经过「重新排版」之后的样子；有些字符会被合成一个图形，就看不见了。但你复制的时候走的是原文那条道，一个字符都不会少。**

打个比方：编辑器里有个**排版工人**。他在处理 `---` 这一行时，拿到的规矩是「从 `---` 开始，**下面的空行也都归这条横线管**，整段只印成一条横线」。你按回车插进去的换行，正好落在他的「管辖范围」里 —— 他一看，还是那一条横线，画面上什么都没多。你按 10 次，他就吞 10 次。就像快递站把一摞箱子打包成一个托盘，你往里再塞一个箱子，托盘还是那一个托盘。

**1. 为什么偏偏是这一行出问题？**
`---` 不是普通文字，它在 Markdown 里是「分隔线」，排版工人要把它画成一条横线。而普通文字（比如「你好」）是一对一翻译的，两个字就是两个字，不会丢。分隔线这种「要变成图形」的东西，才有「多个字符合成一个图形」的机会 —— 空行就是在这个合成过程里被吞掉的。

**2. 为什么连光标都不动？**
光标的位置也是照着「屏幕上的画面」算的，不是照着源码算的。你按下的那个位置已经被归给横线图形了，画面上那里没有能放光标的地方，所以光标也不往前挪 —— 看起来就是「我这下按的键像是没生效」。

**3. 那 10 个换行到底在不在？**
**在。**​ 你复制全文粘到别的地方，粘的就是那份源码（上图右边虚线那张卡），10 个换行一个不少。所以这不是「你的操作丢了」，是**丢在显示器上**，不是丢在文件里。

**修复做的事**（大白话版）：把那条规矩改成「横线只负责它自己那一行的换行，后面的空行不再归它管」。那些空行从此各自单独排队、单独占一行 —— 你按一次 Enter，屏幕上就真的多出一行；按 10 次就是 10 行。现在打开 sample.md，光标停在第 49 行 `---` 末尾敲回车，能直接看到效果。


---

## 23. 文档滚动之后点图片没反应（2026-10-12）★

**一句话：手指点下去的位置「本来就带着滚动量」，代码又给减了一次滚动量 —— 于是问的是「图片下方一屏处」是哪儿。**

打个比方：你站在一列火车上，告诉调度员「我脚下这里是 3 号车厢」。可调度员拿到的坐标是「从车头数第几节」—— 他以为你说的 3 是「离车头 3 节」，再按你站的位置往前滑了一整个车队的长度，最后去问的是「离这儿还很远的那一节」。你明明踩着 8 号车厢，他去问 11 号，当然说「这儿没有你要找的东西」。

### 现象

打开 `cmark-gfm 常见语法精简测试文件.md`（沙盒 Documents 里那份），

- 滚到第 8 节，**点那两张图片一点反应都没有**（本该弹出 `QLPreviewController` 预览）；
- 但把手往上移一屏，点那儿的**普通文字**（比如 `## 5. Inline Code`、`## 6. Link` 这两行），反而弹出了图片预览 —— 点的位置和弹出来的东西完全对不上。

停在文档最顶上（没滚过）时，点图片是正常的。

### 为什么会这样

1. 点图片的手势里，`point = gesture.location(in: self)` 拿到的是「在 `textView` 自己的坐标系里的位置」。
2. **`textView` 是滚动视图，它自己的坐标原点就是 `bounds.origin`，而 `bounds.origin` 恒等于 `contentOffset`。** 也就是说：滚到 1863 点处时，屏幕左上角那个点在 `textView` 坐标里就是 `(0, 1863)`，**滚动量已经算进去了**。
3. 可命中测试里写的是「先按**屏幕坐标**算，再加回 `contentOffset`」：

   ```swift
   let target = CGPoint(x: point.x + contentOffset.x - textContainerInset.left,
                        y: point.y + contentOffset.y - textContainerInset.top)
   ```

   `point` 既然已经含了滚动量，这里再加一次，就等于**把滚动量算了两遍**。
4. 结果：手指点在图片上（内容坐标 y=2564），问出去的是 y=2564+1863=4427 那个位置 —— 早跑到文档下面别处去了，那里没有图片，于是「没反应」。

   反过来也成立：手指点在图片**上方 1863 点**的普通文字处，问出去的正好是 y=700+1863=2563，**落在图片上** —— 这就是「点上面的文字反倒弹出图片预览」。

   （`contentOffset` 为 0 时两种算法结果一样，所以在文档顶部点图片一直是好的，`MarkdownImageSizeTests` 里那条老用例也一直是绿的 —— 它只在 `contentOffset = 0` 的情况下量。）

### 怎么修的

`point` 本来就跟 `layoutFragmentFrame` 只差一个 `textContainerInset`，所以换算只剩一步：**减掉 inset，不要再动 `contentOffset`**。

- `MarkdownTextView.swift` 的 `imageAttachment(at:)`
- `MarkdownTextView+Footnote.swift` 的 `footnoteHit(_:at:)` —— 同一个毛病，症状是「滚过之后 ⌘+点在脚注引用上没反应」

```swift
let target = CGPoint(x: point.x - textContainerInset.left,
                     y: point.y - textContainerInset.top)
```

两处的文档注释也改了：明确写上「`point` 用手势给的那套坐标，**别再加 `contentOffset`**」。

### 怎么验证的

1. 一次性探针（已删）先钉死坐标约定：把 `contentOffset` 设成 500，再把「可见区左上角」按 UIKit 的换算公式换到 `textView` 坐标系 —— 得到 `(0, 500)`，说明手势给的就是**内容坐标**。
2. 拿用户那份真文件复现（容器 700×800，`contentOffset.y = 1863.7`）：

   | 手指落在 | 修复前 | 修复后 |
   | --- | --- | --- |
   | 第 1 张图上（内容 y=2564） | nil（认不出来） | 认出来了 |
   | 第 2 张图上（内容 y=3009） | nil（认不出来） | 认出来了 |
   | 图片上方 1863 点处（内容 y=700） | 认出来了（就是用户看到的怪现象） | nil |

3. 新增回归用例 `MarkdownImageSizeTests.testTappingImageStillWorksAfterScrolling`：前面垫 40 段正文把图片顶下去，真滚 600 点之后再断言「点在图片上认得出」「往上挪一屏不认」。**做了一次反向验证**：把生产代码临时改回旧公式，这条用例变红；换回来立刻绿。

### 以后注意什么

- **`gesture.location(in: 滚动视图)` 给的是内容坐标，已经含滚动偏移。** 凡是拿它去和 `layoutFragmentFrame`（容器坐标，不含 inset）比，只减 `inset` 就够了。
- 这个坑的伪装是「在文档顶部测永远是对的」：**任何跟滚动位置有关的行为，测试必须先把 `contentOffset` 真的推成非 0**，否则测的等于没测。
- 同一个文件里还有一处**故意**加 `contentOffset` 的地方：装饰层（代码块灰底、折叠三角、行号…）。那些视图挂在**钉在视口上的父层**里，父层自己的 `frame.origin.y` 就等于 `contentOffset`，所以它们算的确实是「视口坐标」。两套约定并存，别互相抄。
