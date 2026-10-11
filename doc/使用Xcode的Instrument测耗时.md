# 性能剖析：打开 `testcase/面试速览-大白话版.md`

> 2026-10-11 · Xcode 27 / Instruments 27.0（`xctrace` CLI + Time Profiler 模板）· **Release**-maccatalyst 构建
> 被剖析的文档：39,507 字符 / 773 行 / 58 个标题 / 81 个列表项 / 26 行表格 / 2 个代码块 / 0 张图片

## 一句话结论

打开这份文档，**App 一共烧了 3.19 s CPU**（主线程 2.77 s）；其中「打开文档」那一段是 **1.1 s 墙钟 / 727 ms CPU**。
这些 CPU 里 **近 6 成根本没进我们自己的函数**（栈上是 UIKit / CoreText / CoreGraphics 自己在排版和画字）；
我们自己的代码里最贵的是 **`RenderedFragment.reconciled`（142 ms）**，其次是**表格那条路**（`makeLayout` + `image` + `draw` 合计 104 ms）。

## 怎么录的（可复现）

```bash
# 1) 全系统采 25 秒；同一时刻用「打开方式」把文档交给 App —— 这条路径和 Finder 双击 md 完全一样
xcrun xctrace record --template 'Time Profiler' --all-processes --no-prompt --time-limit 25s \
    --output /tmp/hy4_open.trace &
sleep 5
open -n -a ~/Library/Developer/Xcode/DerivedData/MarkdownEditorHy4-*/Build/Products/Release-maccatalyst/MarkdownEditorHy4.app \
     /Users/pan/Project/iOSDemo/MarkdownEditorHy4/testcase/面试速览-大白话版.md
wait

# 2) 找出 App 的 pid
xcrun xctrace export --input /tmp/hy4_open.trace --toc | grep -A1 MarkdownEditorHy4

# 3) 导出采样表 → 交给脚本聚合
xcrun xctrace export --input /tmp/hy4_open.trace \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' --output /tmp/hy4_tp.xml
python3 doc/tools/xctrace_timeprofile_top.py /tmp/hy4_tp.xml <pid> MarkdownEditorHy4
```

三个关键点：

1. **必须用 Release 构建**（Xcode 里 Profile / ⌘I 走的就是 Release）。Debug 的 `-Onone` 会放大运行时开销、比例全歪。
2. **必须走 `open -a` 这条路**，而不是给进程传个参数 —— 只有它才会走 `SceneDelegate.scene(_:openURLContexts:)` → `MarkdownDocumentOpener`，也就是用户真实的「双击打开」路径。
3. 采样是 **1 ms 一次、只采在 CPU 上跑的线程**，所以「墙钟 1.1 s、CPU 727 ms」是正常的 —— 中间在等系统。

## 总账

| 项 | 数值 |
| --- | --- |
| 录制时长 | 22.6 s（全系统） |
| App 被采到的采样数 | 3,192 个 = **3,192 ms CPU**（1 采样 = 1 ms） |
| 其中主线程 | 2,773 ms |
| 反向归因：**栈上没有自家函数**（纯系统） | 1,653 ms = 59.6% |
| 反向归因：自家函数 | 1,120 ms = 40.4% |

## 时间线（每 500 ms 一格，主线程 CPU）

| 时间 | CPU | 在干什么 |
| --- | --- | --- |
| t=2.5 ~ 3.0 s | 283 ms | **启动 App**：dyld 加载、objc 类/分类注册（`map_images_nolock`、`load_categories_nolock`） |
| t=6.5 ~ 9.5 s | **1,540 ms** | **打开文档**（其中「解析 + 渲染管线」在 t≈7.7~8.8 s，727 ms） |
| t=11.0 ~ 18.5 s | ~880 ms | 画字（字形栅格化）+ 折叠三角定位 + 滚动后重排 |

⚠️ **为什么「打开」比「启动」晚 4 秒**：冷启动时 `MarkdownDocumentOpener` 先把 URL 存下，**等左栏文件列表就绪**才去开 Tab（这是刻意设计的，见 `SceneDelegate` 注释）。所以时间轴上它是独立的一段，不是「打开花了 6 秒」。

## 「打开文档」那一段：钱花在谁头上（727 ms）

| 记在谁头上 | 耗时 | 占这段 | 在干嘛（大白话） |
| --- | --- | --- | --- |
| `RenderedFragment.reconciled(withSource:in:orphanAttributes:)` | **142 ms** | 19.5% | 把整篇渲染片段按源码范围重拼一遍；**每个 run 都新建一个 `NSMutableAttributedString`** |
| `MarkdownTableView.image(data:…:layout:)` | 48 ms | 6.6% | 把整张表格用 `UIGraphicsImageRenderer` 画成一张位图 |
| `NSMutableAttributedString.init(string:attributes:)` | 43 ms | 5.9% | 建富文本串 |
| `closure #1 in MarkdownTextView.replaceWholeStorage(with:)` | 42 ms | 5.8% | 整篇替换 storage |
| `MarkdownTableView.makeLayout(…)` | 34 ms | 4.7% | 量表（列宽、行高） |
| `RenderedFragment.addAttributesIfAbsent(_:)` | 23 ms | 3.2% | 补属性 |
| `MarkdownTableLayoutBox.draw(in:dirty:)` | 22 ms | 3.0% | 真画表格的格子 |
| `UIFont.__allocating_init(descriptor:size:)` | 17 ms | 2.3% | 造字体对象 |
| `MarkdownTextView.setMarkdown(_:)` | 17 ms | 2.3% | 入口 |
| `RenderedFragment.append(_:)` | 16 ms | 2.2% | 拼片段 |
| `BulletAttachment.markerImage(diameter:color:gap:shape:)` | 14 ms | 1.9% | **每个列表圆点现画一张位图**（该文件里没有任何缓存） |
| `FootnoteIndex.definitionMarkers(in:)` | 13 ms | 1.8% | 扫脚注定义 |

> **1~8 ms 的条目基本等于「1~8 个采样」，是噪声**，别当结论。只认 >20 ms 的那几项。

## 那 59.6% 的「纯系统」在干嘛

| 耗时 | 调用（父帧 ← 祖父帧） | 自身帧 |
| --- | --- | --- |
| 58 ms | `argb32_mark` ← `RIPLayerBltGlyph` | `CGSColorMaskCopyARGB8888` |
| 42 ms | `-[__NSCFString isEqual:]` ← `-[__NSDictionaryM objectForKey:]` | `__CFStringEqual` |
| 20 ms | `objc_lookUpImpOrForward` ← `_objc_msgSend_uncached` | `getMethodNoSuper_nolock` |
| 15 ms | `CGBlt_fillBytes` ← `CA::Render::ShmemBitmap::fill_pixels` | `__bzero` |
| 14 ms | `argb32_mark_constmask` ← `argb32_mark` | `DplusDM` |

前三行（`RIPLayerBltGlyph` / `CGBlt_fillBytes` / `argb32_mark`）都是 **画字：把字形栅格化、往位图上刷像素**。这是「39.5k 字符被排版并画出来」的固有成本 —— 改代码快不了它，能省的只有**少排版几遍、少重画几遍**。

> **自检过**：这 1653 个「纯系统」采样里，**没有一个**在栈上出现自家函数（脚本里带这个断言）。所以这不是解析失误，是真的没进我们的代码。另外它们里最早期的那几百毫秒是启动时的 `dyld4::Loader::getLoader`（动态库加载），跟文档无关。

## 值得下手的点（按性价比排序）

| # | 位置 | 证据 | 方向 |
| --- | --- | --- | --- |
| 1 | `RenderedFragment.reconciled`（`Rendering/RenderedFragment.swift:200`） | 142 ms（19.5%） | 每块渲染后都跑一遍收口；内部**逐 run 新建 `NSMutableAttributedString`**。方向：相邻同属性 run 合并、少建临时串。⚠️ 动之前先单独量一遍这一处 |
| 2 | 表格三件套（`MarkdownTableView.swift` / `MarkdownTableLayoutBox`） | 104 ms（14.3%） | 文档只有 26 行表格却吃掉 1/7。方向：量好的布局能不能跨次复用；横滚那条路本来就不出图，先确认这份文档走的是哪条路 |
| 3 | `BulletAttachment.markerImage` | 14 ms | 该文件里**一个缓存都没有**，同尺寸同色的圆点反复 `UIGraphicsImageRenderer`。方向：按（直径, 颜色, 形状）缓存一张 |
| 4 | `positionFoldControls` 57 ms + `scheduleScrollLayout` 26 ms | 打开后的第二波 | 折叠三角定位 + 滚动后重排 —— 跟另一份分析里「打字路径装饰刷新」是同一片区域 |
| 5 | 画字那 1653 ms | 59.6% | 不是「改快」，是「少重排 / 少重画」：属于性能专项，先别动 |

## 这次分析的局限（别当绝对真理）

- **单次运行**，机器上还有 Chrome / Xcode 等在跑；结论看量级，别抠小数点。
- Time Profiler 只采在 CPU 上的线程，**不含等待时间**。
- **Release 把很多小函数内联掉了** → 默认的「自身耗时」列几乎全是 `objc_msgSend` / `malloc` / `CFString` 这类运行时符号，看不到自家函数。要看自家代码必须用**反向归因**（= Instruments 的 Invert Call Tree，把采样记到调用栈上最内层的自家函数）。
- 少量符号是采样器 unwind 失败（`[?] ?` 105 ms、`libhvf.dylib HVF::…` 32 ms），忽略即可。
- 11~18.5 s 那波离「打开」稍远，可能混着窗口绘制 / 系统在忙别的，不必全算在打开账上。

## 怎么自己在 Instruments 里复看这份 trace

1. 双击 `/tmp/hy4_open.trace`（或按下面步骤自己录一遍）。
2. 左侧选 **Time Profiler**，顶部确认 target 是 `MarkdownEditorHy4`。
3. 自己在 Xcode 里 **⌘I（Profile，走 Release）**，然后在 App 里打开文档、等画完、点停止。
4. Call Tree 那一栏勾上：**Invert Call Tree** + **Hide System Libraries**（这两个是关键，不勾就等于在看成千上万条 objc_msgSend）。
5. 时间轴上**框选「打开」那一段**（本次对应 t≈7.7~8.8 s），Call Tree 就只统计这一段。
6. 按 **Weight** 排序，前 5 名就是答案。

工具脚本：`doc/tools/xctrace_timeprofile_top.py`（把导出的 XML 聚合成上面那张表）。

---

# 2026-10-11（晚）：打开文档时 `load` 被调了两次 —— 已修

## 现象

同一份文档、同一条「双击打开」路径，Call Tree 里出现**两个平行的 `MarkdownDocumentStore.load`**：

```
363.00 ms 25.7%  13.00 ms   MarkdownTextView.setMarkdown(_:)
157.00 ms 11.1%   0 s       MarkdownDocumentStore.load(markdown:containerWidth:)
177.00 ms 12.5%   7.00 ms   MarkdownTextView.refreshTheme()
155.00 ms 11.0%   0 s       MarkdownDocumentStore.load(markdown:containerWidth:)
```

两次各 ~155 ms，合计 **~312 ms**（这一屏总采样约 1412 ms，占 22%）。

## 根因：`viewDidLoad` 里的顺序反了

`MarkdownDocumentViewController.viewDidLoad` 原来是：

```swift
if let item = pendingItem { apply(item) }   // → setMarkdown(body)     ← 用【默认主题】渲染第 1 遍
applyEditorStyle()                           // → refreshTheme()        ← 用【真主题】整篇重渲第 2 遍
```

`applyEditorStyle()` 把用户存过的字号 / 行高 / 段间距 / 配色写进 `editor.renderer.theme`，然后调 `refreshTheme()`
→ `reRenderPreservingCaret()` → `documentStore.load(markdown: fullSource, containerWidth: renderedWidth)`。

也就是说**同一份源码被完整解析 + 渲染了两遍，唯一区别是主题**；第 1 遍的结果从没被用户看到过，是纯浪费。

## 改法（3 个文件、4 处，都不动渲染逻辑）

| 文件 | 改动 |
| --- | --- |
| `MarkdownTextView.swift` | 从 `refreshTheme()` 里拆出 `applyThemeChrome()`（只搬 font / 链接色 / 底色），`refreshTheme()` = 它 + `reRenderPreservingCaret()` |
| `MarkdownTextView.swift` | `setMarkdown` 开头补 `updateTextContainerInsetIfNeeded()` —— 保证读 `currentContainerWidth` 时内边距已经是当前主题 / 设置算出来的 |
| `MarkdownDocumentViewController.swift` | `applyEditorStyle()` 拆出 `applyStyleToTheme()`（只写主题 + 套外壳，**不重排**）；`viewDidLoad` 改成**先 `applyStyleToTheme()`、再 `apply(item)`** |
| `MarkdownThemeViewController.swift` | 预览页同款 bug（`setMarkdown` 后紧跟 `refreshTheme()`）→ 改成 `applyThemeChrome()` 在前、`setMarkdown` 在后 |

改完那条路上 `load` **有且只有一次**，且渲染用的就是最终主题。

⚠️ 顺带修正的一个旧问题：`refreshTheme()` 也读同一份 `fullSource` 重排，所以「先是默认主题、后是真主题」两次渲染还会让
`restoreScrollPositionIfNeeded()` 拿到按**默认主题行高**算出来的文档高度。现在滚动位置恢复发生在最终渲染之后。

## 怎么复核

再录一遍上面那条命令，Call Tree（**不要**勾 Invert Call Tree，要看调用链）里搜 `MarkdownDocumentStore.load`：
应该只剩 `setMarkdown` 底下那一条。若还多出一条挂在 `reRenderPreservingCaret` 下、父帧是 `layoutSubviews`，
那是「容器宽度变了要按新宽度重排」的正常分支（不是这次的问题）。
