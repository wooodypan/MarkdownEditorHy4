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
| [1](#1-正文里打字之后点目录跳到错误位置2026-09-13) ★ | 2026-09-13 | 目录握着过期的位置快照，在标题上面打字后点目录就跳偏 | `MarkdownDocumentStore.swift` |
| [2](#2-粘贴后-cmdz残留几个字2026-09-13) | 2026-09-13 | 撤销按「源码长度」记账，实际存的却是「渲染长度」，差几个字 | `MarkdownTextView.swift`、`MarkdownPasteboardController.swift` |
| [3](#3-点目录要连点好几次才跳到位2026-09-13) | 2026-09-13 | 屏幕外的行「还没排版」，量出来的坐标是猜的 | `MarkdownTextView+Outline.swift` |
| [4](#4-斜体和粗斜体对中文不生效2026-09-13) | 2026-09-13 | 中文字体没有斜体字形，光标字体特征「斜体」汉字纹丝不动 | `MarkdownTheme.swift`、`MarkupToAttributedRenderer.swift` |
| [5](#5-长文档里折叠卡手二级标题看着折不动2026-09-14) | 2026-09-14 | 目录每次折叠都重建**全部**标题行；只有带下级的行才给三角，看着像「折不动」 | `MarkdownOutlineView.swift`、`OutlineTree.swift` |
| [6](#6-接多标签库时踩的两个坑2026-09-14) | 2026-09-14 | ①包了两层导航控制器，启动就崩；②漏写一个协议名，报错却指着闭包说「推不出类型」 | `WorkspaceCoordinator.swift`、`MarkdownDocumentViewController.swift`、`project.pbxproj` |
| [7](#7-pbxproj-里工程自己引用自己-11-次2026-09-15) | 2026-09-15 | 源码文件夹里有个残缺的 `.xcodeproj`，Xcode 每次扫到就当子工程记一笔，攒了 11 条自引用 | `project.pbxproj`、删掉 `MarkdownEditorHy4/MarkdownEditorHy4.xcodeproj` |
| [8](#8-app-把新建的文档写进了用户真实的文稿目录2026-09-15) | 2026-09-15 | Target 压根没开 App Sandbox，Mac 上文档目录解析成了用户真实的 `~/Documents` | `MarkdownEditorHy4.entitlements`（新增）、`project.pbxproj`、`Info.plist`、`MarkdownDocumentOpener.swift` |
| [9](#9-mac-右键删除点了没反应2026-09-16) ★ | 2026-09-16 | 带副作用的调用写在 `completion?(...)` 的括号里，completion 为 nil 时被 Swift 整个跳过 —— 右键菜单点了没反应 | `DocumentListViewController.swift`、`DocumentDeleteTests.swift` |
| [10](#10-在样式表里改-linkcolor-链接颜色没变2026-09-16) ★ | 2026-09-16 | 两层根因叠在同一个症状上：① 链接用「只补空缺」上色，文字早被涂成正文色；② `UITextView.linkTextAttributes` 默认系统蓝，画图时盖掉富文本里的颜色 | `MarkupToAttributedRenderer.swift`、`RenderedFragment.swift`、`MarkdownTextView.swift`、`MarkdownLinkColorTests.swift`（新增） |
| [11](#11-设置页新增的滑块能拖但拖了什么都没发生2026-09-16) ★ | 2026-09-16 | `sliderChanged` 结尾那句 `default: return` 把「新增行忘了接上」从编译期错误降级成了静默失效 | `SettingsViewController.swift`、`MarkdownTypographyTests.swift`（新增） |
| [12](#12-任务项正文里带-x复选框却显示成已勾选2026-09-18) ★ | 2026-09-18 | 勾选状态取了解析器给的 `item.checkbox`，而它是用 `strstr(整行, "[x]")` 算的 —— 正文里有个 `[x]` 就把整项报成已勾选 | `MarkupToAttributedRenderer.swift`、`MarkdownEditorHy4Tests.swift` |
| [13](#13-点一下复选框方框就变宽2026-09-18) ★ | 2026-09-18 | 方框宽度写成「按**当前**那个字面量取宽」，而 `[ ]` 和 `[x]` 在图里宽度本来就不同（15.95 / 20.09pt）—— 点一下方框就长 4pt | `MarkdownTextView.swift`、`CheckboxControl.swift`、`MarkdownEditorHy4Tests.swift` |
| [14](#14-任务项里按一次退格-整段被吃掉2026-09-18) ★ | 2026-09-18 | 复选框座位是无条件打了语法标记的装饰附件，把 `- ` 和 `[ ] ` 两段标记**粘成一段** —— 在 `]` 右边按一次退格，`- [ ] ` 整段被吃掉；装饰层又没及时重刷，按钮还残留在屏幕上 | `RenderedFragment.swift`、`MarkupToAttributedRenderer.swift`、`MarkdownDocumentStore.swift`、`MarkdownTextView.swift`、`TaskListBackspaceTests.swift`（新增） |
| [15](#15-点开目录一条标题都不显示2026-09-18) ★ | 2026-09-18 | 面板收着（46 点宽）时按这个宽度量好了「每行 36 点」，展开成 210 点宽之后没人重问 —— 减去缩进和三角，标题的可用宽度成了负数，一个字都画不出来 | `MarkdownOutlineView.swift`、`MarkdownOutlineHeightTests.swift` |
| [17](#17-滚动时代码块灰底停在错地方停下才跳到位2026-09-18) ★ | 2026-09-18 | 屏幕外的代码块只能用 TextKit 的**估算坐标**算矩形，缓存下来后滚动一直沿用；重算又放在滚动回调里，那时 viewport 还没更新，算出来还是错值 —— 表现为灰底压在 ` ```swift ` 那行上，停下手才「啪」地归位 | `MarkdownTextView.swift`、`MarkdownEditorHy4Tests.swift` |
| [18](#18-行内代码的灰底盖住了鼠标选中高亮2026-09-19) ★ | 2026-09-19 | 行内代码的灰底是**不透明**的 `.backgroundColor`，而它是跟着文字一起画的 —— 把画在文字**下面**的系统选中高亮整块盖住，框选行内代码看着像没选中；顺带把两侧反引号弱化成浅灰 | `MarkdownTheme.swift`、`MarkupToAttributedRenderer.swift`、`InlineCodeStyleTests.swift`（新增） |
| [19](#19-语言名-swift-的底部被代码块灰底压住2026-09-19) ★ | 2026-09-19 | 灰底的上沿是拿「正文首行 fragment 顶 − padding」定的，而 fragment 里含着**段后间距**。段距被调小（用户可调 0~40），灰底上沿就往上抬进上一行 ```swift 的字里 | `MarkdownTextView.swift`、`CodeBlockBackgroundClearanceTests.swift`（新增） |
| [20](#20-最后一个--戳出代码块灰底2026-09-19) ★ | 2026-09-19 | 修第 19 条时加的两道「夹子」**夹过头了**：围栏行和正文之间的空隙全靠段间距撑着，段距调到 0 时空隙归零，夹子只能往里挤 —— 把灰底底边挤进了正文最后一行，`}` 戳出去 6pt = 灰底高度的 10%。修法换成「给首尾围栏行的段间距兜下限」，夹子整段删掉 | `MarkdownTheme.swift`、`MarkupToAttributedRenderer.swift`、`MarkdownTextView.swift`、`CodeBlockBackgroundClearanceTests.swift`、`MarkdownTypographyTests.swift` |
| [22](#22-分隔线末尾按回车不换行2026-09-20) ★ | 2026-09-20 | 分隔线在渲染串里只占 1 个字符位（一条横线附件），却按 cmark 给的 range 把**后面的空行一起认领**了 —— 那些空行既没有渲染字符、也轮不到补漏步骤补上，等于在屏幕上凭空消失。用户在 `---` 末尾按回车，源码多了一个换行、画面一动不动 | `MarkupToAttributedRenderer.swift`、`SeparatorEnterTests.swift`（新增） |

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

## 1. 正文里打字之后，点目录跳到错误位置（2026-09-13）★

> 本条目就是本文档最初要写的那一条。

### 1.1 现象

用 `testcase/cmark-gfm 常见语法精简测试文件.md` 这个文件：

1. 在文档**最开头**的正文段落里，随便打上十几个字
2. 点右侧目录里**靠后**的任意一个标题（比如 `9. Unordered List`）
3. 光标**没有**落在标题上 —— 它落在标题**前面**，偏的距离正好约等于「刚才打进去的字数」
4. 在标题**下面**的正文里打字，就没这个毛病

打得越多，偏得越远。而且不光跳转错，目录里那行的高亮也会跟着错位（偏移小一些，差几个字）。

### 1.2 先用生活里的例子理解

想象一本书。目录页上写着：

```
第二章 .......... 第 20 页
```

现在你在**第一章**里加了两页纸。第二章实际上变成第 22 页开始 ——
可目录页还是写着「第 20 页」。你按目录翻到第 20 页，看到的是第一章的尾巴，不是第二章。

这个编辑器的「目录」就是那页目录页，「第 20 页」就是代码里那个
`OutlineItem.sourceOffset`（标题在源码里排第几个字符）。

**书变厚了，目录页没跟着改。** 就是这么回事。

### 1.3 为什么会这样（根因）

两个事实叠在了一起：

**事实一：目录每一行都存着一个「位置数字」，而且这是个快照。**

```swift
struct OutlineItem {
    let level: Int
    let title: String
    let sourceOffset: Int   // ← 这个标题在整篇源码里排第几个字符（UTF-16）
}
```

点击目录时，编辑器就是拿这个数字去算「该滚到哪、光标放哪」的：

```
点目录某一行 → 拿到那一行的 sourceOffset → 换算成渲染坐标 → 光标落位 + 滚动
```

**事实二：这个数字会过期。** 文档是活的。你在某个标题**上面**打一个字，
源码就长了一个字符，**它后面所有标题**的位置数字都得往后加一。
（它前面的标题不受影响 —— 这就是为什么只在「标题上面」打字才会触发。）

**真正的错在哪：那句判断「要不要刷新目录」的代码，把两件事当成了一件事。**

旧代码（`MarkdownDocumentStore.applyEdit` 第 9 步）：

```swift
// 旧代码（有 bug）
let headingsChanged = oldBlocks.contains { $0.headingLevel != nil }
    || newBlocks.contains { $0.headingLevel != nil }
```

翻译成大白话：

> 「这次编辑**碰到的那几个块**里，有没有标题？」

在正文段落里打字时，被碰到的块**全是段落**，一个标题都没有 → 判断为「没变」→
不刷新目录 → 目录里继续留着旧数字 → 点下去就偏了。

被搞混的两件事是：

| | 什么时候发生 |
|---|---|
| **标题自己的内容变了**（增删改、升降级） | 只有真的动到标题时才会 |
| **标题的位置变了**（往后挪了几个字符） | 在它**上面**动任何东西都会，哪怕只是打一个正文字 |

旧代码只认第一种。第二种它完全看不见。

### 1.4 一句话概括根因

> **目录手里握着的是一份会过期的快照，而当时的代码只在「标题本身被改了」时才想起来去更新它。**

### 1.5 怎么修的

**把判断条件放宽成「整篇的标题清单，跟编辑前比，有没有不一样」。**

具体做法：编辑**前后**各给整篇的标题拍一张「指纹」快照，两张比一比。
每个标题在指纹里记三项：

| 记什么 | 漏掉它会怎样 |
|---|---|
| **位置**（排第几个字符） | 漏掉就正好是本条 bug：位置被顶移了却判成「没变」 |
| **层级**（几级标题） | 漏掉 `## 甲` 改成 `### 甲`：位置和文字都没变，但目录那行该改缩进 |
| **文字** | 漏掉原地改名 `## 甲` → `## 乙`：位置没变，但目录显示的字旧了 |

三项合起来，正好等价于「目录里那一行**长什么样、指向哪里**」。

```swift
// 新代码
let headingsChanged = oldBlocks.contains { $0.headingLevel != nil }
    || newBlocks.contains { $0.headingLevel != nil }
    || headingsBefore != headingFingerprint()   // ← 新增，兜住「位置被顶移」
```

代码位置：`MarkdownEditor/Model/MarkdownDocumentStore.swift`
- 拍照的地方：`headingFingerprint()`
- 比对的地方：`applyEdit` 第 9 步
- 指纹的类型：`HeadingFingerprint`（私有）

### 1.6 为什么不选另外两种做法

| 做法 | 为什么不用 |
|---|---|
| **① 点击时不信快照，拿 id 去现查** | 不行。块每次编辑都会被**重新创建**，`id`（一个 UUID）也跟着换新。目录里那一行的 id 在 store 里已经找不到了，查出来是 nil。要它成立，得先引入一套稳定的 id —— 那是另一摊改造 |
| **② 干脆把 `sourceOffset` 从 `OutlineItem` 里删掉，改成「用的时候现查」** | 概念上最干净（这一类 bug 直接消失），但要同时改协议、协调者、目录 UI、高亮查询四处，爆炸半径太大。**留给以后重构**，不是现在该做的事 |
| **③ 把判断条件放宽（本次采用）** | ✅ 改动只落在一个函数里；判断的语义天然等价于「重新读一遍会不会读到不一样的东西」 |

顺带说明为什么没写成「把新老所有标题块的偏移都遍历比一遍」：
那样要自己推理块下标、累计长度，容易写错。**拍两张快照直接比**更不容易出 bug。

### 1.7 性能有没有变差

没有。新加的判断是：

- **`O(块数)` 的纯字段读取**（只有前面字段都相同时才比字符串），不做任何解析
- 而且它在「所有标题**之后**」的正文里打字时**不成立** → 长文档在最后一段连续打字，
  一次多余的目录刷新都不会有
- 块数扫描在这条路径上本来就有一次（`affectedBlockIndices`），所以不改变复杂度量级

### 1.8 怎么验证的

**重点不在「测试变绿」，而在「先看到它变红」。**

1. 先写两条会失败的测试
2. 把修复那一支**临时**改成 `|| false`（假装没修）→ **两条都红了**，报错正是用户描述的现象：

   ```
   目录握着 [0, 14, 29]，真值是 [0, 16, 31]      ← 差 2 = 刚打进去的 2 个字
   光标落在源码第 29 位（「三级」在第 31 位）
   ```

3. 恢复修复 → 全绿
4. **用用户的真实文件跑端到端**（带一张很高的图片，最容易暴露坐标问题）：
   - 在最开头打 **13** 个字 → 下游 **35 个**标题的偏移**各差 13**（编辑点上面的那个差 0）
   - 点 `9. Unordered List` → 光标源码偏移 **797**，等于该标题的真实偏移；落点那一行确实是 `## 9. Unordered List`，高亮也跟上了

结论：

> **测试变绿不能证明修复有效，得先看到它变红。**

新增的 3 条回归测试（都在 `MarkdownEditorHy4Tests/MarkdownOutlineTests.swift`）：
`testTypingInBodyAboveHeadingsShiftsOffsetsAndFlagsRepublish`、
`testTappingOutlineAfterTypingInBodyLandsOnHeading`、
`testTypingAfterLastHeadingDoesNotFlagRepublish`（最后这条锁的是**性能边界**，必须仍为 false）。

### 1.9 以后改这里要注意

- `OutlineItem.sourceOffset` 是**快照**，会过期。**不要**把它缓存起来当长期有效的值用。
- 任何新增的「这次编辑要不要刷新目录」的判断，都**必须覆盖「位置被顶移」这一种**，
  不能只看「碰到的块里有没有标题」。
- 相关注释里已经把这件事标成 ⚠️：`OutlineItem.swift`、`MarkdownEditOutcome.headingsChanged`、
  `publishOutlineItems()`。

---

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

## 5. 长文档里折叠卡手；二级标题看着「折不动」（2026-09-14）

> 这条一半是性能问题，一半是**看着像 bug、其实是有意为之**，两半都值得记。

### 现象

两件事一起报上来的：

1. **「二级标题、三级标题点不动、折不了。」**
   在示例文档里，`# Markdown 编辑器 Demo` 右边有三角、点得动；
   底下那七个 `## xxx` 右边**什么都没有**，怎么点都不折。
2. 标题一多（几百个），**点三角会明显卡一下**，手感像掉帧。

第 1 条先说结论：**这不是 bug，是当前的设计**。目录里只有「**自己底下还有下级标题**」
的行才画三角 —— 示例文档里那七个 `##` 底下没有 `###`，折起来不会有任何东西消失，
画个三角反而会让人以为「点了没反应、坏了」。所以那一行干脆不给三角、右边留空白，
保证所有标题左边缘整齐对齐。这个行为是产品上确认过要保留的。

第 2 条是真问题。

### 为什么会这样

**原来目录的行区域是一个竖排的 `UIStackView`**，数据一变就把**所有**标题行
整批重建一遍 —— 哪怕屏幕上只看得到十几行，屏幕外那几百行也一样建。

实测（宿主视图 800 高、行高 30）：

| 标题行数 | 一次折叠 + 布局 |
|---|---|
| 30 | 27 ms |
| 80 | 78 ms |
| 200 | 192 ms |
| 400 | **414 ms** |

大约**每行 1 毫秒**，完全是线性涨的。也就是说大部分功夫花在了**看不见的行**上。

### 怎么修的

按 `doc/标题大纲展开折叠方案.md` 的路子，把行区域换成
`UICollectionView` + `UICollectionViewDiffableDataSource` + `NSDiffableDataSourceSectionSnapshot`
（系统给「树状可展开列表」准备的那套），**只为屏幕上那十几行创建 cell**。

顺手加了标题栏的「**全部折叠 / 全部展开**」按钮：一刀切地把所有能折的章节收起来 / 放回来，
按钮图标和含义跟着当前状态换（同一个位置一按到底）；全文没有能折的章节时按钮置灰。

> 「全部折叠」只收**目录列表**，正文一个字都不动 —— 和第四节装订线那个折正文的小三角是两码事。

### ⚠️ 这次踩的坑（比结论更值钱）

**坑 1：`NSDiffableDataSourceSectionSnapshot` 默认把「有子项的节点」当成收起。**

按直觉写完是这样的：

```swift
snapshot.append(tree.roots.map { items[$0].id }, to: nil)          // 先放根
for index in parentIndices {
    snapshot.append(tree.children[index].map { items[$0].id },      // 再把子项挂上去
                    to: items[index].id)
}
dataSource.apply(snapshot, to: 0, animatingDifferences: animated)
```

跑起来界面上**只剩最顶上那两三个根标题**，底下的全都不见。
排查了半天数据源和树结构，最后才确认是快照的默认状态：
光把层级 `append` 出来不够，**必须在 `apply` 之前显式 `expand` 一遍**。

修法（注意两步的顺序）：

```swift
snapshot.expand(parentIndices.map { items[$0].id })          // 先全部展开
snapshot.collapse(collapsedIDs.filter { collapsibleIDs.contains($0) })  // 再按用户折的收起来
```

⛔ **顺序不能反**：先折后展的话，用户自己折好的那些会被 `expand` 又给放出来。

**坑 2：屏幕外的行没有 cell，「数行数」的测试写法要改。**

以前用 stack view 时，所有行的视图对象**一直都在**（只是藏起来），
所以测试里可以直接数视图个数。换成 cell 复用之后，**屏幕外的行根本没有视图对象**。

现在断言「显示了几行」要读面板自己算出来的可见行标题（`visibleTitles`，读的是快照里的
可见项），不要去数 cell —— 数出来的永远只有屏幕上那十几个。

**坑 3：改面板的宽高之后，光让外层视图跑布局不够。**

面板的行列表挂在面板自己身上，它的尺寸是在**面板自己的** `layoutSubviews` 里摆的。
所以测试里 `setCollapsed(false)` 之后如果只调外层视图的 `layoutIfNeeded()`，
行列表的高度还停在 0、一行都建不出来（表现为「展开之后还是 0 行」）。
要调面板自己的：`outline.setNeedsLayout()` + `outline.layoutIfNeeded()`。

### 为什么不选别的做法

- **继续用 stack view，只把「建行」做成懒加载**：也能省下那 400ms，但行高固定、
  不需要按内容自适应，collection view 现成就是「只建可见行」，比自己搭一套懒加载更直白；
- **把折叠状态交给系统（存进快照里）**：不行。系统的 diff 靠「稳定标识」认人，
  而本项目的标题 `id` 复用块 `id`，**每次编辑都会换新**，折叠状态一编辑就全丢。
  所以折叠状态的唯一出处仍旧是自己那份 `collapsedIDs`，快照只是它的一个「投影」。

### 以后注意

- **折叠状态的唯一出处是 `collapsedIDs`**，不要改成从快照里读；
- **面板高度还是自己算**（可见行数 × 行高），别去读 `collectionView.contentSize` ——
  那是布局跑完才准的值，而面板高度反过来决定行列表高度，用它俩就会绕成圈；
- **叶子行不给三角是有意的**，别「顺手修一下」；
- 「全部折叠」不碰正文，测试里有一条专门盯着这个（只断言目录行数，不断言正文）。

### 改动文件

| 文件 | 改了什么 |
|---|---|
| `MarkdownEditor/Outline/MarkdownOutlineView.swift` | 行区域 `UIStackView` → `UICollectionView`；新增「全部折叠 / 全部展开」按钮；`OutlineRowView` → `OutlineRowCell`（cell 复用） |
| `MarkdownEditor/Outline/OutlineTree.swift` | 新增 `canCollapse(at:)`（「有下级 + 层级在 H1–H5」）和 `collapsibleIndices`，作为「能不能折」的唯一判据 |
| `MarkdownEditorHy4Tests/MarkdownOutlineFoldTests.swift` | 新增 7 条折叠测试（默认全展开、全部折叠 / 展开、叶子行不参与、按钮置灰……） |
| `MarkdownEditorHy4Tests/MarkdownOutlineTests.swift` | 行视图改从 `createdRowCells` 取；点行改走 `simulateRowTap` |

---

## 6. 接多标签库时踩的两个坑（2026-09-14）

这一条不是「用着用着坏了」，而是**把 App 从「单页编辑器」改成「左栏文件列表 + 右栏多标签」
（接了第三方库 `MultiTabController`）时踩的两个坑**。两个都很有代表性：
**报出来的错跟真正的原因完全不像**，不知道套路的话能查半天。

### 6.1 坑一：启动就崩 —— `Pushing a navigation controller is not supported`

#### 现象

代码全写完、编译一路通过。一运行，App 在**启动那一刻**就崩：

```
NSInvalidArgumentException: Pushing a navigation controller is not supported
```

（跑单测时也一样：单测的宿主就是 App 本身，所以「测试崩溃」的表现其实是 App 启动崩了。）

#### 为什么会这样

用生活里的例子说：左栏那份「文档列表」要在导航条下面显示，所以得包一层导航控制器。
我想着「这事儿我来办」，就在交给分栏容器的时候顺手包了一层：

```swift
SplitContainerViewController(leftViewController: UINavigationController(rootViewController: list), ...)
```

问题是 —— **那个分栏容器内部已经替左栏包了一层导航控制器**（它自己也要用这个导航条：
标题、右侧的「＋」按钮都挂在上面）。于是它拿到一个导航控制器之后，又往外层那个导航栈里塞了一个：

> 相当于你把一个已经装好箱子的货，又整个装进另一个箱子，再让人把这个箱子塞进只能放单件货的货架。

UIKit 明确不允许「往导航栈里 push 一个导航控制器」，直接抛异常。

#### 怎么修的

`leftViewController:` **只传列表本身**，导航条由分栏容器自己准备：

```swift
SplitContainerViewController(leftViewController: list, ...)
```

#### 以后注意

- 接任何「容器类」第三方组件（分栏、标签栏、抽屉…）之前，**先读它的 `init` 注释**，
  看它替你包了什么。这个库的注释里就写着 `self.leftNavigationController = UINavigationController(...)`。
- **这类错误只在运行期出现，编译期一点征兆都没有** —— 所以本项目坚持「编译过了也要真启动一次」。
  这次就是靠启动冒烟逮到的（顺带一提：跑单测也等于启动一次，因为单测的宿主就是 App）。

### 6.2 坑二：一句完全不着边际的编译错误

#### 现象

分栏搭好之后编译，`WorkspaceCoordinator.swift` 里报一个错：

```
error: unable to infer closure type without a type annotation
        let makeContentViewController: PPContentViewControllerProvider = {
                                                                         ^
```

箭头指着**一整个闭包**，意思是「这个闭包推不出类型」。可按理说左边已经写了完整的类型
（`PPContentViewControllerProvider`，就是 `() -> PPContentDisplaying`），闭包里也就一句
`MarkdownDocumentViewController()` —— 怎么看都不像类型不明。

按提示「把类型写全一点」折腾了三轮（补参数列表、补返回值、干脆不写 typealias 直接写函数类型），
**错误一字不变**，只是列号跟着变。

#### 为什么会这样

真正的原因在另一个文件里：内容页那个类的声明**漏了一个协议名**。

```swift
// 错的（原来是这样）
final class MarkdownDocumentViewController: UIViewController {

// 对的
final class MarkdownDocumentViewController: UIViewController, PPContentDisplaying {
```

内容页是「右边一个标签里显示什么」的通用约定：宿主不关心具体是谁，只要求它能被一份内容
配置、能上报状态（就是 `PPContentDisplaying`）。这层关系**必须写在类型声明上**。

一旦这个一致性没写，闭包体里那句 `MarkdownDocumentViewController()` 就**没法当成** `PPContentDisplaying` 用 ——
Swift 的类型推导在这一步失败，但它没把「XX 没有遵守 YY」这个真话说出来，
而是回头去怪「这个闭包推不出类型」。

> 就像你寄快递，单子上少填一个必填项。你希望对方说「这里没填」，结果对方说
> 「你这单子我看不懂」—— 你还是不知道该补哪一项。

#### 怎么修的

在类声明上补上协议名（`final class ...: UIViewController, PPContentDisplaying`）。

#### 以后注意

- **Swift 报「推不出闭包类型」时，先把闭包体里那个表达式的类型对一遍** ——
  真凶经常是「里面那个东西不满足外部要求的类型」，而不是闭包本身写法有问题。
- 这类错误之所以难查，是因为**报错位置在调用方、根因在被调用方的类型声明上**。
  所以本项目在那行声明上留了注释，写清「漏了会报什么错」。
- 顺带一条：内容页工厂这种「返回某个协议」的闭包，`X()` 能不能直接当协议用，
  完全取决于 `X` 声明上的协议列表 —— 别在闭包里加类型标注去「修」，修不好。

### 6.3 顺手记一个还留着的控制台告警（**没改**）

跑起来控制台会有一条：

```
Unbalanced calls to begin/end appearance transitions for <MarkdownDocumentViewController>
```

原因查清了：`MultiTabController` 在把内容页的视图挂到右侧容器上时，
**自己主动调了一对 `beginAppearanceTransition / endAppearanceTransition`**（它注释里写了意图：
「view 是手动拆装，UIKit 不会自动重发，所以这里补上」）。但在「父视图已经在屏幕上」的情况下，
UIKit 其实**也会自动发一遍**外观回调 —— 两边都发，就成了「多出来一次」。

对功能**没有可见影响**（内容页的 `viewDidAppear` 里只做了一次窗口标题更新，重复执行无害）。
之所以没动它：这是**上游库自己的实现选择**（`MultiTabController` 的源码），
本项目只是它的使用者。而这个告警只是控制台噪音。**真要清掉，两条路**：
① 在那对手动调用处改一次（那条路径下 UIKit 会自动发，删了也还有回调）——
   库现在是远端依赖，改它等于**给上游提一个改动**，而不是在本地打补丁；
② 让宿主在**自己还没出现在屏幕上**的时候就把第一个标签开好。

### 6.4 附：这个库最后是怎么接进来的（远端 SPM 依赖）

这段不是 bug，是**「上游仓库长什么样」决定接法**的三条实测经验，省得下一个人再试一遍。

**过程**：一开始它只有子目录里的 `MultiTabController/Package.swift`（仓库根目录既没有清单、
也没有 tag），README 里写的「用仓库地址加 SPM」**根本走不通** —— Xcode 只认**仓库根目录**的
`Package.swift`。当时只能把源码 vendor 到 `Vendor/MultiTabController`、用**本地包引用**接。
后来上游在根目录补了 `Package.swift`，这才换成正常的远端依赖，`Vendor/` 也删掉了。

**三条经验**：

1. **没 tag 就用「分支」当要求。** `project.pbxproj` 里写的是 `XCRemoteSwiftPackageReference`
   ＋ `requirement = { branch = master }`。它表达的不是「版本号」，而是「盯住 master 分支上的
   **某一个具体提交**」—— 那个提交会记进 `Package.resolved`（当前锁的是 `bbd7ebe`），
   别人 clone 下来装的是同一份。代价是**升级要手动**（Xcode：File → Packages →
   Update to Latest Package Versions）。
   ⚠️ 想变成普通依赖：在 GitHub 上给仓库打个 tag（比如 `1.0.0`），再把这段换成
   `kind = upToNextMajorVersion; minimumVersion = 1.0.0;`。
2. **库清单里的 `platforms:` 决定「编译时按哪套 API 可用性检查」，不是 App 的部署目标。**
   上游写 iOS 12，而源码里用了 iOS 13 才有的 `UIBarButtonItem.SystemItem.close` ——
   早先按 iOS 12 编真机直接报 `'close' is only available in iOS 13.0`（Catalyst 反而不报）。
   上游后来在源码里补了 `if #available(iOS 13.0, *)` 兜底，这才两平台都能编。
3. **换依赖来源时，`project.pbxproj` 里有三处要一起改**，漏一处就解析不到：
   ① 工程级 `packageReferences` 列表里的那一条；
   ② `XCRemoteSwiftPackageReference` 段里的定义（`repositoryURL` ＋ `requirement`）；
   ③ **每个用到该产品的 target** 里，`XCSwiftPackageProductDependency` 上的 `package = ...` 指回 ①②。
   —— App 和测试 target 各有一份产品依赖，两份都要指对。

### 6.5 改动文件

| 文件 | 改了什么 |
|---|---|
| `MarkdownEditorHy4/WorkspaceCoordinator.swift` | 新增：按设备搭根（iPhone 导航栈 / iPad·Mac 分栏）；左栏**不再**自己包导航控制器 |
| `MarkdownEditorHy4/DocumentListViewController.swift` | 新增：左栏文件列表（单击预览 / 双击正式打开） |
| `MarkdownEditorHy4/DocumentsWorkspace.swift` | 新增：Documents 目录的唯一数据源 + 首启复制示例 |
| `MarkdownEditorHy4/MarkdownDocumentViewController.swift` | 由 `ViewController` 改名并改造成内容页；补上 `PPContentDisplaying` |
| `MarkdownEditorHy4/AppDelegate.swift` | 首启准备目录；`newDocument` 兜底（没有标签时菜单项不至于变灰） |
| `MarkdownEditorHy4.xcodeproj/project.pbxproj` | 接第三方库：远端 SPM 依赖指向 `wooodypan/iOSDemoHub`（怎么接的见 6.4）；测试 target 也挂上该产品 |

---

## 7. pbxproj 里工程自己引用自己 11 次（2026-09-15）

### 现象

`project.pbxproj` 的 `projectReferences`（「本工程引用了哪些**子工程**」那张表）里，
躺着 11 条一模一样的记录，全都指向 `MarkdownEditorHy4.xcodeproj` —— **工程自己**：

```
projectReferences = (
    {
        ProductGroup = 3BF4ACB73057D39E00FE03AD /* Products */;
        ProjectRef = 3BF4ACB23057D39E00FE03AD /* MarkdownEditorHy4.xcodeproj */;
    },
    ... 后面还有 10 条长得一模一样的 ...
);
```

除了这 11 条记录，还配套多出来：11 个**空的** `PBXGroup`（名字全叫 `Products`，
一个 children 都没有）+ 11 条 `PBXFileReference`。

**每次提交就多一条**，翻 git 历史看得清清楚楚：

| 提交 | 自引用条数 |
|---|---|
| `537f9e0` Initial Commit | 0 |
| `118c2f9` | 1 |
| `e5fc955` | 2 |
| `7e8c739` | 3 |
| `d86d5c9` | 4 |
| `0e45f32` | 5 |
| `dca0a56` | 5 |
| 工作区（清理前） | **11** |

### 为什么会这样

**真凶是源码文件夹里躺着一个坏掉的工程包。**

`MarkdownEditorHy4/MarkdownEditorHy4.xcodeproj/` 是 2026-08-31 00:55 冒出来的，
里面**只有一个 `project.xcworkspace/xcuserdata/pan.xcuserdatad/UserInterfaceState.xcuserstate`**，
**没有 `project.pbxproj`** —— 它根本不是一个能打开的工程。

而本工程用的是 `PBXFileSystemSynchronizedRootGroup`（「文件系统同步文件夹」，
就是「往 `MarkdownEditorHy4/` 里丢 `.swift` 不用改 pbxproj」那个机制）。
这个机制的代价是：**Xcode 会把那个文件夹里的一切都扫一遍**。
扫到 `.xcodeproj` 就当成「子工程」去加载 → 没有 pbxproj → 加载失败。

失败归失败，**Xcode 还是往 `projectReferences` 里记一笔，而且从不清理旧的**。
于是每开一次工程就攒一条，攒到 11 条。

佐证：跑 `xcodebuild -list` 每次都会打印

```
IDEFileReferenceDebug: [Load] ... Failed to load container at path:
  .../MarkdownEditorHy4/MarkdownEditorHy4/MarkdownEditorHy4.xcodeproj
  "cannot be opened because it is missing its project.pbxproj file"
```

注意路径里**多了一层 `MarkdownEditorHy4/`** —— 正好是同步文件夹的位置。
这解释了「这些引用不在任何 group 的 children 里，Xcode 却能算出路径」。

> **侦探小技巧**：Xcode 生成的对象 ID 是 24 位十六进制，**中间 8 位就是生成时刻的时间戳**
> （自 2001-01-01 起的秒数）。抠出来一算，就知道每个对象是什么时候蹦出来的：
> ```
> 3BF4ACB2 3057D39E 00FE03AD
>          └─ 0x3057D39E → 2026-09-14
> ```
> 靠它一眼看出「这 11 条是分 11 次长出来的」，而不是一次性写错 ——
> 这个区别决定了「改一次就好」还是「必须先掐掉源头」。

### 怎么修的

1. 把坏包**移走**（没直接删，先挪到 `/tmp/mdeditor-removed/` 放着，确认没问题再清理）：
   `MarkdownEditorHy4/MarkdownEditorHy4.xcodeproj` → `/tmp/mdeditor-removed/nested-broken-MarkdownEditorHy4.xcodeproj`
2. 清掉 11 条自引用，连带它们专用的 11 个空 `Products` 组 + 11 条 `PBXFileReference`，
   以及整个 `projectReferences = (...)` 段和配套的 `minimizedProjectReferenceProxies`。

**只删「在 projectReferences 里出现过」的那些 ID** —— 真正的 `Products` 组
（被 `productRefGroup` 引用的那个）一根汗毛没动。

`project.pbxproj` 从 764 行降到 651 行，**删掉 113 行**。

### 怎么验证的

| 检查 | 结果 |
|---|---|
| 每个待删 ID 在文件里出现次数 | 都是 2 次（定义 1 次 + 引用 1 次）→ 没有别处依赖 |
| 删后有没有「被引用但没定义」的 ID | 0 个 |
| 大括号 / 圆括号配平 | 63:63、54:54，都配平 |
| 三个 target 还在不在 | `MarkdownEditorHy4`、`…Tests`、`…UITests` 都在 |
| `xcodebuild -list` 那条加载告警 | **归零**（连跑两次都是 0 条） |
| 单元测试 | 156 全绿 |
| Catalyst / iOS 编译 | BUILD SUCCEEDED ×2 |

### 以后注意什么

1. **源码文件夹里绝对不能放 `.xcodeproj`。** 提交前手跑一句就能查出来：
   `find . -name "*.xcodeproj" -not -path "./.git/*"` —— 正常只该输出根目录那一个。
2. **`.xcodeproj` 是「包」，不是普通文件夹。** 在 Finder 里拷文件时如果只拷了其中一部分
   （比如只带上了 `project.xcworkspace`），就会留下这种「坏包」。删的时候要**整包**删。
3. **看到 pbxproj 里的重复条目，先翻 git 历史判断它是「一次性写错」还是「每次 +1」。**
   前者修一次就好；后者说明有个源头在持续制造，不掐掉源头，清完还会长回来。
4. 清理 pbxproj 别用跨行正则 —— 一个对象自己就占好几行，`.*?` 不跨行会直接匹配失败
   （这次第一次就是这么翻车的）。用「定位起止下标 + 字符串切片」最稳。

---

## 8. App 把新建的文档写进了用户真实的「文稿」目录（2026-09-15）

### 现象

在 Mac 上跑这个 App（Catalyst 版），**⌘N 新建的 `未命名.md` 跑到了 `/Users/pan/Documents/` 里** ——
那是用户自己的「文稿」目录，不是 App 该待的地方。更吓人的是左栏列表列的也是
`~/Documents` 底下的东西，右键「删除」真能把用户自己的文稿删掉。

iOS 模拟器上怎么试都是好的，只有 Mac 出问题。

### 先用生活里的例子理解

把 App 想成一个租客。

- **iOS 上**：房东（系统）硬性给每个租客一间上锁的房间，钥匙只给这一间 —— 你想乱跑也没门路。
- **macOS 上**：房东不管。租客得**自己主动在合同上签字**，声明「我只要我自己那一间」。
  没签，就等于默认可以在整栋楼里随便走 —— 于是它把东西顺手放进了你的书房。

那个「签字」就是 **entitlement**（`com.apple.security.app-sandbox`）。

### 为什么会这样（根因）

**这个 target 根本没开 App Sandbox，不是代码写错了。**

| 查的东西 | 结果 |
|---|---|
| 工程里有没有 `.entitlements` 文件 | 没有 |
| `project.pbxproj` 里有没有 `CODE_SIGN_ENTITLEMENTS` / `ENABLE_APP_SANDBOX` | 都没有 |
| 实际签名里带了什么 | 只有一个 `com.apple.security.get-task-allow` |
| `~/Library/Containers/com.yijian.mirror` 存不存在 | 不存在 |

于是 `FileManager.urls(for: .documentDirectory, in: .userDomainMask)` 老老实实解析成了
`NSHomeDirectory()/Documents` —— 也就是 `/Users/pan/Documents`。

**为什么只有 Catalyst 现形**：macOS 的沙盒是**选入式**的（靠 entitlement 声明），
而 iOS 的沙盒是**系统强制**的 —— 同一个写法在 iOS 上永远落在容器里。
所以「模拟器上验证过是好的」完全不能说明 Mac 上也是好的。

### 怎么修的（方案 A：开 App Sandbox）

1. **新增 `MarkdownEditorHy4/MarkdownEditorHy4.entitlements`**，声明两件事：
   - `com.apple.security.app-sandbox` = 开沙盒；
   - `com.apple.security.files.user-selected.read-write` = 允许读写**用户亲手挑的**文件
     （⌘O 的打开面板、导出面板、Finder 双击进来的 .md）。只读不够 —— ⌘S 要写回原文件。
2. **`project.pbxproj` 两个配置（Debug / Release）各加三条**：
   ```
   "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]"   = MarkdownEditorHy4/MarkdownEditorHy4.entitlements;
   "ENABLE_APP_SANDBOX[sdk=macosx*]"       = YES;
   "ENABLE_USER_SELECTED_FILES[sdk=macosx*]" = readwrite;
   ```
   后两条是 Xcode 的「能力」开关（同一件事用两种写法表达，Xcode 自己加能力时也是这么写的）。
3. **`Info.plist` 加 `UIFileSharingEnabled`**：把容器里的 Documents 目录露到 iPhone / iPad 的
   「文件」App 里 —— 开了沙盒之后，往容器里放文件 / 取文件得有这么一个正经入口。
4. **`MarkdownDocumentOpener`：安全作用域从「只记最后一个」改成一批。**
   以前不开沙盒，全盘都能读写，记不记无所谓；开了沙盒就不同了 —— 右侧可以同时开着好几份
   容器外的文档，**只留最后一个的授权，会让较早那份按 ⌘S 写不进去**。
5. **左栏空态文案分平台**：Mac 上教用户走「文件 > 打开…」，别再让他去「文件」App 里拖
   （Mac 上没有那个 App 的这一套）。

### 为什么给设置加 `[sdk=macosx*]` 这个条件

因为 **iOS 压根不需要这份文件**：iOS 的沙盒是系统强制的，多写一份跟 iOS 无关的权限声明，
只会让「这个 App 到底要什么权限」变得难讲清。加上条件之后，iOS 构建连
`CODE_SIGN_ENTITLEMENTS` 都是空的（实测 `ENABLE_APP_SANDBOX = NO`、上下文里没有 `.xcent`），
两个平台各管各的。

### 怎么验证的

| 检查 | 结果 |
|---|---|
| 签名里真的带上沙盒了吗 | `codesign -d --entitlements -` 打出 `com.apple.security.app-sandbox = true` ✅ |
| 容器建出来了吗 | `~/Library/Containers/com.yijian.mirror/Data` 首次启动后出现 ✅ |
| 容器里能读写、能删吗 | 新增的 `SandboxWorkspaceTests` 在容器里走了一遍「建 → 写 → 读 → 删」 ✅ |
| **用户真实的 `~/Documents` 有没有被动过** | 跑测试 + 真启动前后各 `ls` 一次，`diff` 退出码 0（一个字节都没变）✅ |
| 回归：有没有把老功能弄坏 | 单元测试 **158 全绿** |
| 两个平台还编得过吗 | Catalyst / iOS(generic) 均 BUILD SUCCEEDED ✅ |
| 还有没有**新增** CodeSign / entitlement 的告警 | 无 |

### 顺带发现的两件事

1. **从「本身已被沙盒包住」的终端里直接跑这个 App，会 SIGTRAP 崩掉**（`EXC_BREAKPOINT`）。
   沙箱不允许套娃 —— 跟 xcodebuild 在沙箱里跑不起来是同一个道理
   （`sandbox_apply: Operation not permitted`）。
   换成 `open -n <App.app>` 让 launchd 去启动就一切正常。
   → 以后**冒烟测试别再用「直接跑二进制」那条路**，用 `open`。
2. **沙盒里 `FileManager.trashItem`（丢系统废纸篓）依然可用**：拿一个临时文件实测过，
   文件确实进了 `/Users/pan/.Trash/`。
   所以「Mac 上删除先试着丢废纸篓」这个设计**不用改**，确认框里那句
   「还能从废纸篓捞回来」也还是实话。

### 以后注意什么

1. **别把 `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]` 那条删了，新建 target 时也记得抄。**
   删掉之后 App 表面上一切正常，只是又悄悄开始往用户的文稿目录里写东西 ——
   编译期看不出来。`MarkdownEditorHy4Tests/SandboxWorkspaceTests.swift` 就是拦这个的：
   Catalyst 上断言文档目录必须落在 `/Library/Containers/` 里。
2. **老文件不会自己搬进容器。** 之前 App 写进真实 `~/Documents` 的那几份，还留在原地，
   要用户自己挪。开关一改，左栏就只看得到容器里的东西了（看不到 ≠ 删掉了）。
3. **写测试仍然不许碰 `DocumentsWorkspace.folderURL` / `documentURLs()`** ——
   那是用户真正的文稿目录，只能读路径、不能拿它当草稿纸。
   `SandboxWorkspaceTests` 里那个「建 → 写 → 读 → 删」的用例是**先确认自己在容器里**才动手的。

### 补记：Xcode 26 里「开沙盒」有两套写法（2026-09-15 晚，用户问手动怎么做）

Xcode 26 的 Signing & Capabilities 编辑器改成了**用构建设置来表达能力**：勾一下 App Sandbox，
写进 pbxproj 的是一串 `ENABLE_*`，**不再强制生成 `.entitlements` 文件**。用户手动点出来的就是这一串：

```
ENABLE_APP_SANDBOX = YES;
ENABLE_USER_SELECTED_FILES = readwrite;
ENABLE_INCOMING_NETWORK_CONNECTIONS = NO;
ENABLE_OUTGOING_NETWORK_CONNECTIONS = NO;
ENABLE_RESOURCE_ACCESS_AUDIO_INPUT / BLUETOOTH / CALENDARS / CAMERA / CONTACTS / LOCATION /
PRINTING / USB = NO;
```

**手动步骤**：选 project → TARGETS 里选 target → `Signing & Capabilities` 页 →
左上角 `+ Capability` → 搜 `App Sandbox` → 添加 → 面板里 `User Selected File` 下拉选 `Read/Write`。
（Xcode 26 加能力时会顺带把不用的一堆开关显式写成 `NO`，那是**防止继承到别的配置的值**，不是多余行。）

**两套写法都会真的生效，而且会合并。** 用空 entitlements 文件 + 只开 ENABLE_* 实测过，
`.xcent` 里照样出 `app-sandbox`；反过来把 `ENABLE_APP_SANDBOX` 覆盖成 `NO`，
文件里那一对键也照样进包。这是用 `xcodebuild build CODE_SIGN_ENTITLEMENTS=/tmp/空文件.entitlements`
逐个验证的（命令行覆盖不改 pbxproj，是安全的试探手法）。

**实测出来的对照表**（把 12 个开关全开 YES，看生成的 `.xcent` 里冒出哪些键）：

| 构建设置 | 生成的 entitlement 键 |
|---|---|
| `ENABLE_APP_SANDBOX` | `com.apple.security.app-sandbox` |
| `ENABLE_USER_SELECTED_FILES` = readwrite / readonly | `…files.user-selected.read-write` / `.read-only` |
| `ENABLE_OUTGOING_NETWORK_CONNECTIONS` | `com.apple.security.network.client` |
| `ENABLE_INCOMING_NETWORK_CONNECTIONS` | `com.apple.security.network.server` |
| `ENABLE_RESOURCE_ACCESS_CAMERA` | `com.apple.security.device.camera` |
| `ENABLE_RESOURCE_ACCESS_AUDIO_INPUT` | `com.apple.security.device.audio-input` |
| `ENABLE_RESOURCE_ACCESS_BLUETOOTH` | `com.apple.security.device.bluetooth` |
| `ENABLE_RESOURCE_ACCESS_USB` | `com.apple.security.device.usb` |
| `ENABLE_RESOURCE_ACCESS_PRINTING` | `com.apple.security.print` |
| `ENABLE_RESOURCE_ACCESS_LOCATION` | `com.apple.security.personal-information.location` |
| `ENABLE_RESOURCE_ACCESS_CALENDARS` | `com.apple.security.personal-information.calendars` |
| `ENABLE_RESOURCE_ACCESS_CONTACTS` | `com.apple.security.personal-information.addressbook` ⚠️ 名字不一样 |

**iOS 不用担心被牵连**（实测）：带着无条件的 `ENABLE_APP_SANDBOX=YES` 构建 iOS 模拟器版，
产物里只有 `application-identifier`，**没有** `app-sandbox`。原因是苹果自己的模板就把这套设置
声明为只属于 macOS 平台：
`Xcode.app/…/Templates/Project Templates/MultiPlatform/Application/macOS App Entitlements.xctemplate`
里写着 `Platforms = [com.apple.platform.macosx]` + `ENABLE_APP_SANDBOX = YES`
+ `ENABLE_USER_SELECTED_FILES = readonly`（新建 macOS App 默认不开沙盒的只给 readonly，
要写回得自己改成 readwrite）。

> 所以本项目给设置加 `[sdk=macosx*]` 属于**表述更清楚**，不是**功能上必需** ——
> 留着挺好：pbxproj 里一眼能看出「这是 Mac 侧的事」，也不会在 Xcode 的 iOS 视图里
> 显示一堆用不上的能力开关。

---

## 9. Mac 右键「删除」点了没反应（2026-09-16）

### 现象

在左栏对着某份文档点**右键**（iPad 上是长按）→ 菜单里选「删除」→ 确认框正常弹出来 →
点确认框里的「删除」→ **什么都没发生，文件还好好地在原地。**

但 iPhone 上**往左滑**删除是好的 —— 同一个确认框、同一段删除代码，两条路一个好一个坏。

### 为什么会这样：`completion?(...)` 会把括号里的东西一起跳过

确认框里原来是这么写的：

```swift
alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
    completion?(self?.performDelete(url) ?? false)   // ← 问题在这
})
```

`completion` 是个**可选**闭包（`((Bool) -> Void)?`）。它为 nil 时，Swift 的 `?()`
**不只是「不调用这个闭包」，连括号里那些参数都不会去算** —— 于是
`performDelete(url)`（真正删文件的那一步）压根没执行过。

拿一个独立脚本就能验证（存成 `.swift` 直接 `swift 文件名.swift` 跑，不用建工程）：

```swift
var sideEffectRan = false
func performDelete() -> Bool { sideEffectRan = true; return true }

var completion: ((Bool) -> Void)? = nil   // 右键菜单那条路：不传 completion
completion?(performDelete())
print(sideEffectRan)                      // 实测打出 false —— 函数根本没被调用
```

**为什么偏偏只有右键这条路坏**：右键菜单（`deleteMenu`）只想「把它删掉」，不需要知道结果，
所以调 `confirmDelete(url)` 时没传 completion → 它是 nil → 被短路。
而左下角往左滑那条路要拿结果去决定「这一行收不收回原位」，传了 completion → 参数照常求值 → 看着一切正常。

一句话总结：**坏不坏，取决于一个「反正也用不上」的参数传没传。** 这就是它难被发现的原因。

### 怎么修的

把「删除」从参数位置**拿出来**，先执行完再回调：

```swift
func handleDeleteConfirmation(_ url: URL, completion: ((Bool) -> Void)? = nil) {
    // 先删，再回调 —— 顺序反了就又回到原来那个坑里
    let didDelete = performDelete(url)
    completion?(didDelete)
}
```

`confirmDelete` 里改成 `self?.handleDeleteConfirmation(url, completion: completion)`。

单独抽成一个方法有两个好处：**能单测**，以及能把「这一步必须无条件执行」的理由写成注释，
免得以后有人又把它塞回参数里。

顺带加了一个给测试用的替换口 `var deleteFile: (URL) throws -> Void`：
测试里换成「直接删临时文件」，免得每跑一次测试就往用户的废纸篓里丢一个文件。

### 怎么验证的

1. **新增两条测试**（`DocumentDeleteTests.swift`）：
   - `testDeleteWorksWhenCompletionIsNil` —— 专门用 `completion: nil` 复现右键那条路；
   - `testDeleteReportsResultToCompletion` —— 左滑那条路要能收到 `true`。
2. **反向验证（这一步才是关键）**：把代码**故意改回**有 bug 的写法再跑一遍 ——
   `testDeleteWorksWhenCompletionIsNil` 立刻变红，其余 5 条照过；然后才改回正确写法。
   **一条从没红过的测试，没法证明它守得住任何东西。**
3. 编译：Catalyst + iOS 两个平台都 BUILD SUCCEEDED。

### 以后注意什么

1. **带副作用的调用，别放进 `?` 调用的括号里。** 判断方法：问一句
   「这一步要是没执行，会有人发现吗？」—— 如果是「文件没删掉」「东西没存进去」这种，
   就先单独一行执行完，再回调。`对象?.方法(有副作用的东西())` 全都有这个毛病。
2. **一个功能有两条入口时，两条都得点一遍。** 这次两条路共用同一个确认框，
   差别只在「传不传 completion」，光读代码很难看出来。
3. 排查测试失败**先确认是不是自己碰坏的**：`git diff --stat` 看工作区还有哪些改动，
   再拿 `stat -f "%Sm %N"` 看文件修改时间对不对得上。这次就是靠时间戳发现
   `testCodeBlockBackgroundFollowsScroll` 的失败来自另一处未提交的段落间距改动，与本次修复无关。
4. **顺带记一笔**：`testCodeBlockBackgroundFollowsScroll` 对**段落间距**很敏感 ——
   它断言「滚到 1500 之后代码块背景该落在哪」，间距一调大，整篇文档高度就变了，断言跟着失败。
   实测把 `MarkdownTheme.swift` 的 `paragraphSpacing` 和列表样式的 `paragraphSpacing`
   改回原值就能恢复通过。以后调排版参数时，记得这条测试会跟着动。

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

## 11. 设置页新增的滑块，能拖但拖了什么都没发生（2026-09-16）★

### 11.1 现象

给设置页加了「正文排版」那一组（字号 / 行高 / 段落间距 / 段落首行缩进 / 行宽上限）。
界面一切正常：五行都画出来了、滑块能拖、右边的数字也跟着变。
**但正文一点反应都没有**，拖完关掉设置页再打开，滑块又回到原来的位置 ——
说明值压根没写进配置。

有意思的是「**看起来完全正常**」这件事本身就是最坑的地方：
滑块能拖、数字在动，用户（和读代码的人）根本不会往「这个回调没接上」上想。

### 11.2 为什么会这样

`sliderChanged(_:)` 里是这么写的：

```swift
switch row {
case .outlineHeightRatio:     settings.setOutlineHeightRatio(stepped)
case .outlineMaximumHeight:   settings.setOutlineMaximumHeight(stepped)
case .tableMinColumnWidth:    settings.setTableMinColumnWidth(stepped)
case .tableMaxColumnWidth:    settings.setTableMaxColumnWidth(stepped)
default:
    return          // ← 祸根
}
```

新增的五行走进了 `default: return` —— 直接返回，连 setter 都没调到。

**关键在于「界面那一半是好的」**：画控件是另一个 switch
（`tableView(_:cellForRowAt:)`），那处加对了。于是「能显示、能拖」和
「拖了不生效」各自成立，拼在一起就是一个静默失效的功能：
不崩、不报错、不打日志，只是没用。

`default: return` 的真正害处是**它把编译期错误降级成了运行期错误**。
`Row` 是个 `CaseIterable` 枚举，本来「有行没处理」是编译器一眼能看出来的事；
加了 `default` 之后，编译器认为「反正有兜底」，就不再管了。

### 11.3 怎么修的

把 `default` 去掉，让 switch **穷举**所有 `Row`；两个挂别种控件的行显式写出来：

```swift
case .remembersScrollPosition, .outlineHeightMode:
    // 这两行挂的是开关 / 分段控件，不是滑块，回调不会从这儿进来。
    // ⚠️ 这里**故意不写 `default:`**：穷举之后，以后往 `Row` 里加一行滑块，
    // 编译器会直接报「switch must be exhaustive」逼你回来接上 ——
    // 少了这层保护就会出现「滑块能拖、但拖了什么都没发生」这种静默失效。
    return
```

去掉 `default` 之后编译器立刻就报了 `error: switch must be exhaustive`，
说明这个护栏是实打实生效的。

### 11.4 怎么验证的

1. 补了 21 条测试（`MarkdownTypographyTests.swift`）。其中设置页那两条
   （`testSettingsPageHasTypographySlidersAndWritesBack`、
   `testDraggingContentWidthToTheEndMeansUnlimited`）**在修之前就是红的**，
   断言正是「拖完 `settings.bodyFontSize` 应该变成 21，实际还是 17」。
   先红后绿，说明这个测试真的守得住这条链路。
2. 顺手做了突变验证，确认另外三条守卫不是空跑：
   把 `applyLineHeight` 改成永不生效、把列表项的段间距改回写死的 `12`，
   对应三条测试**立刻变红**（其中 `testLineHeightActuallyPushesFollowingContentDown`
   是拿「第二个代码块被推下去多少点」量的，属于**排版层**的证据，不是属性层）。

### 11.5 以后注意什么

1. **「能拖但没反应」优先怀疑回调没接上**，而不是「设置没生效」。
   排查顺序：`sliderChanged` 的 switch → setter → 配置对象是不是同一个实例 →
   内容页有没有监听通知。这个 bug 卡在第一层。
2. **分发用的 switch 不要写 `default`。** 枚举穷举时，编译器就是最好的测试 ——
   白拿一条「新增成员必须处理」的编译期断言，没有理由不要。
3. **给设置页加一行，要同时改四处，少一处就静默失效**：
   | 位置 | 改什么 |
   |---|---|
   | `Section.rows` | 把新行放进哪个分组、排第几 |
   | `Row` 的各个计算属性 | `title` / `detail` / `sliderRange` / `sliderStep` / `currentValue` / `formatted` |
   | `tableView(_:cellForRowAt:)` | 挂哪种控件（开关 / 分段 / 滑块） |
   | `sliderChanged(_:)` | 写回哪个 setter（**穷举，别加 `default`**） |
   另外 `MarkdownEditorSettings` 那边还要补：`Default` / `Limits` / `Payload` /
   属性 / setter / `init` / `load` / `save`（全可选字段，老配置缺字段要能退默认）。
4. **设置页的单元测试，帧高一定要给够。** `UITableView` 只创建**可见范围内**的
   cell：帧太矮时靠下的行根本不存在，`XCTUnwrap` 会以「找不到控件」失败 ——
   那是测试自己没把页面铺开，不是功能坏了。现在统一用 `420 × 2600`，
   踩之前那几条用的 640 / 900 就不够了。
5. **打开视图树里找控件的辅助函数，用「量程上界」当身份证最稳**，
   别用顺序（挪一行就挂）或 tag（往枚举里插一个 case 就全错位）：
   ```swift
   private func slider(in view: UIView, maximumValue: Float) -> UISlider?
   ```
   代价是**每行的量程必须唯一**。这次的量程是 28 / 2 / 40 / 4 / 1200，
   和原有的 1 / 900 / 200 / 600 互不冲突。

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

## 15. 点开目录，一条标题都不显示（2026-09-18）★

### 15.1 现象

冷启动时右上角只有一个展开小方块（`MarkdownDocumentViewController.setupOutline` 里
`outlineView.setCollapsed(true, animated: false)`）。点它展开目录：

- 面板**确实变高变宽了**（46×36 → 210×224），
- 可里面**一个字都没有** —— 六条标题像是凭空消失了。

### 15.2 类比

面板是块能伸缩的画板。收起来时只有 46 点宽，画板照着这个宽度量好了「每一行该多宽（36 点）」，
把结果写在便签上。展开成 210 点宽之后，**便签没人重写** —— 画板继续按 36 点排行。

一行只有 36 点宽，左边缩进 15 点、右边要给折叠三角留 26 点，留给标题文字的宽度是
**负数**。字自然一个都画不出来。

### 15.3 为什么会这样（根因）

`MarkdownOutlineView.layoutSubviews` 里那段「宽度变了就重新问一遍行宽」的判据，
量错了对象：

```swift
let width = effectiveWidth          // ← 问题就在这一行
if abs(width - lastLaidOutWidth) > 0.5 {
    lastLaidOutWidth = width
    collectionView.collectionViewLayout.invalidateLayout()
}
```

`effectiveWidth` 是「**展开时该有多宽**」，它压根不认识收起态 —— 面板收着（真身只有 46 点宽）的
时候，它返回的照样是 210。于是：

| 时刻 | `effectiveWidth` | `lastLaidOutWidth` | 差值 | 结果 |
|---|---|---|---|---|
| 首次布局（收起态） | 210 | 0 → 210 | 210 | 作废一次布局，行按 46 点宽算 → **36** |
| 后续布局（仍是收起） | 210 | 210 | 0 | 什么都不做 |
| **展开（真身 46 → 210）** | **210** | **210** | **0** | **什么都不做 —— flow layout 继续用 36 点那个缓存** |

Probe 打出来的行 frame 一眼能看出问题（面板已经是 210 宽了，行却只有 36 宽，
六个被横着挤到一行里）：

```
PROBE 展开后: panelH=224.0 bounds=(0.0, 0.0, 210.0, 224.0)
  row frame=(5.0,   4.0, 36.0, 30.0)   一级标题
  row frame=(46.0,  4.0, 36.0, 30.0)   二级标题
  row frame=(87.0,  4.0, 36.0, 30.0)   三级标题
  …
  row frame=(5.0,  34.0, 36.0, 30.0)   六级标题   ← 挤到第二行了
```

修好之后是正常的竖排：

```
  row frame=(5.0, 4.0,   200.0, 30.0)  一级标题
  row frame=(5.0, 34.0,  200.0, 30.0)  二级标题
  …
```

### 15.4 怎么修的（两处）

| 文件 | 改动 |
|---|---|
| `MarkdownOutlineView.layoutSubviews` | 改成量 `panelWidthConstraint.constant`（收起 46 / 展开 210，**任何状态下都是真值**），不再量 `effectiveWidth` |
| `MarkdownOutlineView.setCollapsed` | 收起 / 展开时**主动**作废一次行宽布局。⚠️ 必须排在 `refreshPanelSize` **之前** —— 后者会触发布局，顺序反了这次布局还是照旧尺寸摆行 |

### 15.5 怎么验证

两条回归测试放在 `MarkdownEditorHy4Tests/MarkdownOutlineHeightTests.swift`：

| 测试 | 盯的是什么 |
|---|---|
| `testRowsReflowToFullWidthWhenExpandedFromCollapsed` | 收起 → 灌标题 → 展开，每一行必须占满面板宽度，且行与行正好差一个行高 |
| `testRowsKeepFullWidthAfterCollapseAndExpandAgain` | 来回收起展开一次，行宽不许跑掉 |

**反向验证**（把两处修复都撤掉重跑）：两条都红，报的正是
`36.0 is not equal to 200.0` 和「第 2 行没排在下一行」。

#### ⚠️ 这个 bug 极难写出「能复现的测试」，下面两个坑都真踩过

1. **展开那一步必须走 `animated: true`**（真实点按钮走的就是它 —— 只靠 `refreshPanelSize`
   里那个动画块触发布局）。换成 `animated: false` 再手工 `layoutIfNeeded()`，
   那次全量布局会顺带把行宽重算一遍 → 测试变绿，而 bug 照样在用户手里。
2. **面板必须「从出生就是收起态」**。拿现成的 `makeOutlineView()` 建出来的面板默认是展开的，
   会先以 210 点宽布局一次 —— 那一次就把「展开后每行该多宽（200）」缓存进 flow layout 了，
   之后再展开正好命中缓存 → 又是绿的。为此专门加了 `makeCollapsedOutlineView()`，
   在**第一次布局之前**就 `setCollapsed(true)`，和 App 里 `setupOutline` 的顺序一致。

第一版测试就是这么写的，撤掉修复仍然全绿，等于什么都没测到。

### 15.6 以后注意什么

1. **「该有多宽」和「现在是多宽」是两回事。** 拿 `effectiveWidth` / `effectiveMaximumHeight`
   这类「算值」当「变了没有」的判据，只要一出现「某个状态下的算值恰好等于另一个状态的真值」
   就会静默漏判（本例正是如此）。要检测变化，就老老实实量真值 —— 这里量的是约束上的 constant。
2. **`UICollectionViewFlowLayout` 会缓存 `sizeForItemAt` 的结果**，容器尺寸变了它不会自动重问。
   凡是「容器的宽高是自己算出来、会突然变化」的地方（本例的收起 / 展开，还有设置页改高度），
   都得**显式** `invalidateLayout()`，而且顺序要排在「触发布局的那次调用」之前。

### 15.7 改动文件

- `MarkdownEditor/Outline/MarkdownOutlineView.swift`（两处 + 一处注释订正）
- `MarkdownEditorHy4Tests/MarkdownOutlineHeightTests.swift`（新增 2 条测试 + 1 个 helper）

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

