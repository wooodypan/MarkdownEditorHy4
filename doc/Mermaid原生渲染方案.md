# Mermaid 原生渲染方案

## 一句话结论

选 **MermaidKit**（https://github.com/2389-research/MermaidKit ，MIT，纯 Swift，30 种图，无 JS/无 WebView/无三方依赖），
按项目里已经跑通的 **LaTeX（SwiftMath）** 那套模式接进来 —— 库层只定义协议，App 层注入 MermaidKit 实现，
识别 ` ```mermaid ` 围栏代码块，用 `NSTextAttachment + UIImage` 把图塞进文本流。
**这个取舍已经拍定**：MermaidKit 的地板是 **iOS 17 / macCatalyst 17 / Xcode 26 / Swift 6.2**，而本项目是 iOS 16.0 —— 所以 **fork 一份降到 iOS 16**（`/Users/pan/Project/iOSDemo/MermaidKit`，改动只有 7 个文件、48 增 21 删，见 §2）。
**方案已实施完毕**，落地情况与实测坑见 §8。

---

## 1. 为什么是 MermaidKit

调研时对比过的三条路：

| 方案 | 类型数 | 依赖 | 渲染方式 | 结论 |
|---|---|---|---|---|
| **MermaidKit** | 30 | 无 | 同步 CoreGraphics，~15ms/图 | **推荐** |
| mermaid.js + WKWebView | 全 | mermaid.js 打包资源 | 异步 JS 桥 | 违反「轻量、原生」目标，每个编辑器多一个 Web 进程 |
| BeautifulMermaid（lukilabs） | 6 | elk-swift | 同步+异步 | 类型少，多一层三方依赖 |

MermaidKit 关键事实（从 README / Package.swift / GitHub API 拿到的一手信息）：

- **License**: MIT
- **仓库活跃度**: 2026-07 建仓，最新 tag `v2.3.0`，最后一次 push 2026-10-14（就这两天）
- **Star 数**: 10（**很小，这是主要风险**，见 §7）
- **平台地板**: `platforms: [.macOS(.v14), .iOS(.v17), .visionOS(.v1)]`
- **工具链地板**: Xcode 26 / Swift 6.2（用了 SwiftPM Traits）
- **两个 target**：
  - `MermaidLayout`：平台无关的解析 + 布局 + 场景 IR
  - `MermaidRender`：CoreGraphics / CoreText 绘制，输出 `UIImage` / `NSImage` / `PDF` / `SVG` / `NSAttributedString`
- **对外主 API**（本项目会用的）：
  - `MermaidRenderer.image(source:theme:)` → `UIImage?`
  - `MermaidRenderer.attachmentString(source:format:theme:)` → 已经带好 `NSTextAttachment` 的富文本
  - `MermaidRenderer.svg(source:theme:)` → SVG 字符串（HTML 导出会用）
  - `MermaidRenderer.pngData(source:format:theme:)` → PNG（复制到剪贴板会用）
  - `MermaidParser.parse(_:)` → 解析失败返回 `nil`（用户半截输入时的降级依据）
  - `MermaidParser.maxTextSize = 50_000`，`maxEdges = 500`（内置输入上限，防止恶意大文件卡死）
- **附带白送**：DOT / Dippin / SQL DDL / git log 前置解析器（同一个 `format` 参数就能切），未来可以顺手支持这些围栏语言

不选 mermaid.js 的核心理由：**你的目标是「高性能、轻量化、原生渲染」**。mermaid.js 每篇文档都要拉一个 Web 进程，内存和启动时间都不划算；而且渲染是异步的，滚动到才画出来，会闪。

---

## 2. iOS 16 / iOS 17 的取舍（**已定：fork 降级**）

`MarkdownEditorHy4.xcodeproj/project.pbxproj` 里 6 处 `IPHONEOS_DEPLOYMENT_TARGET = 16.0`，`Package.swift` 里也是 `.iOS(.v16), .macCatalyst(.v16)`。MermaidKit 上游要求 iOS 17。

**2026-10-17 已定方案：fork + 降级** —— 不动项目地板，也不必把源码 vendored 进工程（仍是 SwiftPM 依赖，只把 URL 换成本人 fork）。

| 项 | 值 |
| --- | --- |
| fork | `Panway/MermaidKit`，分支 `ios16-support` |
| 基点 | 上游 v2.3.0（`918d9e8`） |
| 本地路径 | `/Users/pan/Project/iOSDemo/MermaidKit` |
| 改动 | `platforms` → `.macOS(.v13), .iOS(.v16), .macCatalyst(.v16), .visionOS(.v1)`，外加 33 个文件的平台分支 |

### 实测结论（Xcode 27 / Swift 6.4）

| 验证项 | 结果 |
| --- | --- |
| Catalyst 编译（`arm64-apple-ios16.0-macabi`） | ✅ 通过 |
| iOS 16 编译（`arm64-apple-ios16.0`） | ✅ 通过 |
| macOS 13 编译 | ✅ 通过 |
| Catalyst 下真出图（flowchart / sequence / pie，含中文标签） | ✅ 通过 |
| iOS 模拟器全量测试 | ✅ 367 用例、0 失败 |
| 上游源码直接编 Catalyst | ❌ 约 140 个错误、横跨 26 个文件 |

⚠️ **降级不只是改 `platforms`**。根因是 **Mac Catalyst 下 `canImport(AppKit)` 仍为 `true`**（`canImport(UIKit)` 也为 true），于是全库走进 AppKit 分支，而 `NSColor` / `NSFont` / `NSAppearance` / `NSGraphicsContext` / `NSFont.Weight` 在 Catalyst 下**全部 unavailable**。

判据必须写成 `#if canImport(AppKit) && !canImport(UIKit)`（Catalyst 下为 false → 落回 UIKit 分支）。
macabi 探针实测：Catalyst 下 `canImport(AppKit)=true`、`canImport(UIKit)=true`、`targetEnvironment(macCatalyst)=true`、`os(macOS)=false`、`os(iOS)=true`。

### 2.1 改动构成：**只剩 7 个**（初稿说改 33 个，实测可退回）

**编译必需的最小集 = 7 个文件，且已实测「只留这 7 个」照样编得过**

| 文件 | 改什么 |
| --- | --- |
| `Package.swift` | `platforms` 降级 |
| `Platform.swift` | 三个 typealias（Color / Font / Image）在 Catalyst 下走 UIKit ← **根因**，改这一处消掉其余 25 个文件的全部报错 |
| `DiagramTheme.swift` | `usingColorSpace`、`controlAccentColor`（`UIColor` 没有）、`NSAppearance` |
| `DiagramRenderer.swift` | `NSAppearance` / `NSImage(size:flipped:)` / `NSGraphicsContext` / `accessibilityDescription` / `NSTextAttachment` |
| `DiagramRenderer+PDF.swift` | `NSAppearance` + `performAsCurrentDrawingAppearance` |
| `MermaidRenderer.swift` | `NSTextAttachment` |
| `MermaidView.swift` | `Image(nsImage:)`，**必须与 `Platform.swift` 同步改**，否则拿到 `UIImage` 时类型不匹配 |

**那 26 个（25 个 `DiagramRenderer+*.swift` 的 import 分支 + `MermaidRenderer+SVG.swift`）已全部还原成上游**：它们的报错**全部是经 `PlatformColor` / `PlatformFont` 派生**的（改 `Platform.swift` 一处即全消）。做法是减法实验 —— 先把 7 个之外的都还原，编译只剩 `MermaidView.swift` 一处错误 → 再补上 `MermaidView.swift` 就干净了，反证这 26 处编译上非必需。

**为什么不保留它们**：那会让 fork 的 diff 从 30 行涨到几百行，将来跟上游 rebase 时每一处都可能冲突。而「上游以后在某个 `+*.swift` 里新增直用 `NS*` 的代码」这个担心，实测成本很低 —— 真撞上时编译器会点名那个文件，照 `Platform.swift` 的思路改一处即可，不需要提前 26 个文件都改一遍。

最终 diff 规模：**7 files changed, 30 insertions(+), 21 deletions(-)**。

### 2.2 两个已知坑

1. **`MermaidKit-Package`（Xcode 打开包时的聚合 scheme）在 Catalyst 下编不过**。实测该 scheme 下 `MermaidRender` 被编成 `arm64-apple-ios17.0-macabi` 且 UIKit 模块不可见 → 又落回 AppKit 分支，报错落在 `Platform.swift` 等文件上。
   **不影响宿主集成**：宿主是"作为依赖编单个 target"，等效于 `-scheme MermaidRender`，实测通过。副作用只是没法用这个聚合 scheme 在 Catalyst 下跑包自带测试（iOS 模拟器下正常）。
2. **配色别只交给 `prefersDark`**。`DiagramTheme(prefersDark:)` 是一套内置预设：墨色是**写死的近黑 / 近白**（`rgbStatic`，不是动态色），画布写死 `0xFFFFFF` / `0x1B1B1D`，只有 `accent` 取系统的 `tintColor`（动态色，但 `resolveAll` 会在 init 里按 `prefersDark` 钉住的外观解析掉）。
   问题不在「解析成亮色读不了」，而在**图会和文档配色脱节**：用户把文档配成米色底 + 棕字，图仍然是引擎自己的近黑墨色配白画布，箭头「挖洞」处还露出一块白斑。
   `DiagramTheme` 另有**完整颜色的公开 init**，集成时按下面这张表把 `MarkdownTheme` 的真实颜色映射进去（已实现，见 §5.1）：

   | 引擎槽位 | 取主题的哪个颜色 | 不映射会怎样 |
   | --- | --- | --- |
   | `ink` | `textColor` | 图里的字和正文不是同一种色 |
   | `secondaryTextColor` / `tertiaryTextColor` | `textColor` 摊到 55% / 38% α | 层级感和引擎默认不一致 |
   | `canvas` | `editorBackground` | 箭头、边标签「挖洞」处按引擎写死的画布填 → 米色 / 深色主题上露白斑 |
   | `accent` | `linkColor` | 节点填充用系统蓝，和文档强调色两家人 |
   | `hairline` | `separatorColor` | 网格 / 生命线 / 区域框的细线，和文档里的分隔线不是一个灰 |
   | `palette` | **不映射**（留引擎默认） | 那六个分类色是为「同一张图里彼此可区分」调的，主题里没有对应概念，硬凑更难看 |

   `prefersDark` 仍要传：它不只挑颜色，引擎内部还有一批「深色下换个画法」的取舍跟着它走。判据用**背景色的相对亮度**（WCAG 系数），不是去问系统外观 —— 用户完全可以给浅色机身配一套深色文档配色，该由文档配色说了算。

---

## 3. 接入架构 —— 照抄 LaTeX 那条已经跑通的路

项目里 LaTeX 是这样分层的（这个模式经过验证、写进注释了，直接沿用）：

```
MarkdownEditor/                            ← 开源库，无 SwiftMath 依赖
├── Rendering/
│   ├── MarkdownMathRenderer.swift         ← 只定义协议
│   ├── MarkdownMathScanner.swift          ← 从纯文本里扫 $...$
│   ├── Attachments/MathAttachment.swift   ← NSTextAttachment 子类
│   └── MarkupToAttributedRenderer.swift   ← 持有 `mathRenderer`，AST 走到公式节点时调用
MarkdownEditorHy4/                         ← App 层
└── SwiftMathRenderer.swift                ← 用 SwiftMath 实现协议，注入给库
```

**Mermaid 完全同构**：

```
MarkdownEditor/                            ← 开源库，无 MermaidKit 依赖
├── Rendering/
│   ├── MarkdownMermaidRenderer.swift      ← 新增：只定义协议
│   ├── Attachments/MermaidAttachment.swift← 新增：NSTextAttachment 子类
│   └── MarkupToAttributedRenderer.swift   ← 修改：加 `mermaidRenderer` 属性 +
│                                             在 `visitCodeBlock` 里识别 language == "mermaid"
MarkdownEditorHy4/                         ← App 层
└── MermaidKitRenderer.swift               ← 新增：用 MermaidKit 实现协议，注入给库
```

**为什么不能把 MermaidKit 直接 `import` 到库层**：`MarkdownEditor` 是要单独开源的（Package.swift 里写得很清楚），如果库里直接依赖 MermaidKit，所有下游用户不管写不写 Mermaid 都会被迫拖上这个依赖。SwiftMath 已经踩过这条路，注释里明说了「所以库里只有协议」。

---

## 4. 库层要加的代码

### 4.1 `MarkdownEditor/Rendering/MarkdownMermaidRenderer.swift`（新文件）

```swift
import UIKit

/// 一次 Mermaid 渲染请求
struct MarkdownMermaidRequest {
    /// 围栏代码块里头的正文（不含 ``` 那两行），比如 "flowchart TD\n  A --> B"
    var source: String
    /// 图的最大宽度（点）。和表格同一条算法：容器宽度减去缩进和内边距
    var maxWidth: CGFloat
    /// 正文颜色 / 页面背景色 —— 让图跟着主题走，别在深色文档里画出一张白底的图。
    ///
    /// ⚠️ 刻意**不传**「是不是深色」这种布尔：`MarkdownTheme` 里根本没有这个概念
    /// （配色是一张覆盖表，`nil` 表示用下一层的色，用户可以给浅色文档配一套深色配色），
    /// 硬造一个布尔只会造错。引擎要 `prefersDark: Bool` 的话，由 App 层的适配器
    /// 从这两个颜色自己推 —— 信息给全了，怎么映射是适配器的事。
    var textColor: UIColor
    var backgroundColor: UIColor
    /// 正文字号 —— 图里的文字用这个字号来量，和周围正文视觉一致
    var fontSize: CGFloat
}

/// 把 Mermaid 源码画成一张图的渲染器
///
/// 由宿主 App 实现后注入给 `MarkupToAttributedRenderer.mermaidRenderer`。
/// 不注入的话 ` ```mermaid ` 围栏块就按普通代码块显示（源码原文），功能降级但**不会坏**。
///
/// ### 实现者注意
/// 1. 会在渲染紧循环里被调用（滚动、主题切换、字号变更都会重排），**必须缓存**。
///    缓存键至少包含 source / maxWidth / textColor / backgroundColor / fontSize。
/// 2. **返回 nil 表示「这个 Mermaid 语法画不出来」**。调用方会退化成显示源码原文，
///    **不要**返回一张「错误提示图」—— 用户正在敲半截 `flowchart T`，满屏报错是最差体验。
///    这条规矩和 `MarkdownMathRenderer` 完全一样。
protocol MarkdownMermaidRenderer: AnyObject {
    func image(for request: MarkdownMermaidRequest) -> UIImage?
}
```

### 4.2 `MarkdownEditor/Rendering/Attachments/MermaidAttachment.swift`（新文件）

基本可以照抄 `MathAttachment.swift`（57 行，注释都写好了），只需要：
- 类名改成 `MermaidAttachment`
- 去掉 `mode: MarkdownMathMode` 字段（Mermaid 全是块级）
- **`maxWidth` 的处理策略改一下**：Mermaid 图往往比容器宽，需要「缩到刚好塞得下」而不是「原尺寸显示」。逻辑仍然是 `min(maxWidth / original.width, 1)` —— 只缩不放，跟图片附件同一条规矩。
- 垂直定位：块级图不需要跟 `capHeight` 对齐，直接 `y = 0`（或跟 `font.descender` 对齐让底部留一点空隙）。

### 4.3 `MarkdownEditor/Rendering/MarkupToAttributedRenderer.swift`（修改）

三处小改动：

**改动 1**：在 `mathRenderer` 声明旁边加一行
```swift
/// 详见 `MarkdownMermaidRenderer.swift`。挂在这里的理由同 `mathRenderer`：
/// Mermaid 是在「AST → 富文本」这一步变成图的，而这一步就是这里做的。
var mermaidRenderer: MarkdownMermaidRenderer?
```

**改动 2**：在 `visitCodeBlock(_:)`（当前 line 788）**开头**加一段拦截
```swift
func visitCodeBlock(_ codeBlock: CodeBlock) -> RenderedFragment {
    // 优先判断：mermaid 围栏 + 注入了渲染器，就走画图那条路。
    //
    // ⚠️ 不要写 `codeBlock as? FencedCodeBlock` —— swift-markdown 里**没有这个类型**，
    // 围栏代码块就是 `CodeBlock` 本身，语言标识直接在 `codeBlock.language` 上（`String?`）。
    // 项目里其他地方也是这么用的（见 `CodeBlockInfo(code:language:)` 那行）。
    if let lang = codeBlock.language?.lowercased(),
       lang == "mermaid" || lang == "mmd",
       let mermaidRenderer {
        if let fragment = renderMermaidBlock(codeBlock, renderer: mermaidRenderer) {
            return fragment
        }
        // 解析失败 / 图太大 / 空源码 → 落到下面的默认代码块渲染，显示源码原文
    }
    // ……以下保持原样
}
```

**改动 3**：新增私有方法 `renderMermaidBlock`，逻辑跟现有 `renderMath`（line 266）几乎是复刻关系：
```swift
private func renderMermaidBlock(_ block: CodeBlock,
                                renderer: MarkdownMermaidRenderer) -> RenderedFragment? {
    // 源码范围：拿不到（手工构造的 AST）就放弃，交给调用方走默认代码块渲染。
    // ⚠️ 别写 `block.range` —— 那是 `Range<SourceLocation>?`，类型对不上；
    // 项目里统一走 `localRange(of:)` 这个 helper（visitTable / visitThematicBreak 都是这么取的）。
    guard let range = localRange(of: block) else { return nil }

    // ⚠️ 这里有两个「源码」，不是一回事，别混：
    // - `block.code`      不含围栏行的正文，喂给渲染引擎（引擎不认识 ``` 那两行）
    // - `markdownSource`  含围栏行的整段源码，给下面的弱化源码行用（全选复制必须一字不差）
    let source = block.code
    guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let markdownSource = sourceText(in: range)

    let maxWidth = max(120, containerWidth - indent - 16)   // 和 visitTable 同一条算法
    let request = MarkdownMermaidRequest(
        source: source,
        maxWidth: maxWidth,
        textColor: theme.textColor,
        backgroundColor: theme.editorBackground,
        accentColor: theme.linkColor,
        separatorColor: theme.separatorColor,
        fontSize: theme.bodyFont.pointSize
    )
    guard let image = renderer.image(for: request),
          image.size.width > 0, image.size.height > 0 else {
        return nil   // 语法错 / 引擎不支持这个图类型 → 交给调用方回退成源码
    }

    let attachment = MermaidAttachment(image: image,
                                       font: theme.bodyFont,
                                       maxWidth: maxWidth)
    let style = theme.blockAttachmentParagraphStyle(indent: indent)

    var out = RenderedFragment.empty
    // 「N 个源码字符 → 1 个字符位」这个能力**现成就有，不需要改任何东西**：
    // `RenderedFragment.attachment(_:sourceStart:sourceLength:attributes:)` 的注释原文是
    // 「只占 1 个字符位，但吃掉了源码里 sourceLength 个字符（比如整段 ![alt](url)）」。
    // 块级公式 `$$\n E=mc^2 \n$$` 跨多行映射到 1 个字符位，就是同一个场景 —— 直接照抄它的调用形状。
    out.append(.attachment(attachment,
                           sourceStart: range.location,
                           sourceLength: range.length,
                           attributes: [.font: theme.bodyFont, .paragraphStyle: style]))

    // 图下面弱化显示源码（含围栏两行），和 `visitTable` 一模一样：
    // 光标能停进去改内容，复制时靠 `lastSourceEnd` 去重，整段只输出一次。
    // 段落样式不能省：源码有好几行，没有它的话缩进（列表里的图表）和行距都不对。
    var sourceAttributes = theme.tableSourceAttributes
    sourceAttributes[.paragraphStyle] = theme.paragraphStyle(indent: indent)
    out.append(.decoration("\n", attributes: sourceAttributes))
    out.append(.sourceHint(markdownSource, sourceStart: range.location, attributes: sourceAttributes))
    return out
}
```

> **注（已核对源码）**：不用给 `RenderedFragment` 或 `SourceLocationTable` 加任何新能力，「源码长度 ≠ 富文本长度」本来就是支持的。
>
> 参数名是 `sourceStart:` / `sourceLength:` / `attributes:` 三个（`RenderedFragment.swift` line 69）。
> ⚠️ 别写成 `sourceRange:` / `replacesLength:` —— 那两个名字不存在，照着写编译不过。
>
> `theme.tableSourceAttributes` 是表格那边现成的弱化源码样式，图表可以直接复用（名字带 table，将来要么改名通用化，要么另加一个 `diagramSourceAttributes`，两行的事）。

---

## 5. App 层要加的代码

### 5.1 `MarkdownEditorHy4/MermaidKitRenderer.swift`（新文件）

骨架照抄 `SwiftMathRenderer.swift` —— 全局单例 + `NSCache`。**真正有内容的是配色翻译和缓存键这两处**（完整代码见文件本身，155 行，注释比代码长）：

```swift
import UIKit
import MermaidRender   // MermaidKit 的绘制 target

final class MermaidKitRenderer: MarkdownMermaidRenderer {
    static let shared = MermaidKitRenderer()

    /// 上限比公式那边（200）小：图比公式大得多，100 张够一篇长文来回切了
    private let cache = NSCache<NSString, UIImage>()

    nonisolated deinit {}   // 隔离 deinit 一旦嵌套就会踩 Swift 6.2 的野指针 free

    func image(for request: MarkdownMermaidRequest) -> UIImage? {
        let theme = Self.diagramTheme(for: request)
        let key = cacheKey(source: request.source, maxWidth: request.maxWidth, theme: theme)
        if let cached = cache.object(forKey: key) { return cached }

        // 同步渲染（跟 SwiftMath 一个量级）。真卡了再考虑异步 —— 但不要一开始就上，会引入闪烁。
        guard let image = MermaidRenderer.image(source: request.source, theme: theme) else {
            return nil   // 语法错 / 不支持的图类型 → 让库层退回源码显示
        }
        cache.setObject(image, forKey: key)
        return image
    }

    /// 把库层给的四个真实颜色翻译成引擎的七槽位调色板（映射表见 §2.2）
    private static func diagramTheme(for request: MarkdownMermaidRequest) -> DiagramTheme {
        let traits = appearanceTraits
        let background = request.backgroundColor.resolvedColor(with: traits)
        let text = request.textColor.resolvedColor(with: traits)
        return DiagramTheme(
            ink: text,
            secondaryTextColor: text.withAlphaComponent(0.55),   // 照引擎预设的档位摊
            tertiaryTextColor: text.withAlphaComponent(0.38),
            canvas: background,                                   // 箭头「挖洞」按它填，避免露白斑
            accent: request.accentColor.resolvedColor(with: traits),
            hairline: request.separatorColor.resolvedColor(with: traits),
            prefersDark: background.isDarkForDiagram)
    }

    /// ⚠️ 配色那一截直接用引擎算好的 `fingerprint`，别自己挑几个颜色拼字符串
    private func cacheKey(source: String, maxWidth: CGFloat, theme: DiagramTheme) -> NSString {
        "\(source)|\(Int(maxWidth))|\(theme.fingerprint)" as NSString
    }
}

/// 这个颜色算不算「深色」：按 **WCAG 相对亮度**（0.2126R + 0.7152G + 0.0722B）低于 0.5 就算。
///
/// ⚠️ 不要用 `getWhite`：它只对灰度色有意义，一条深蓝 / 深绿的背景会被算成「不深」，
/// 于是图还是画成浅色主题，压在深底上看不清。也放在 App 层而不是库层 ——
/// `MarkdownTheme` 里压根没有「深色」这个概念，库层不该为了接一个引擎而凭空长出一个字段来。
```

**两个容易写错、已经踩过的地方：**

1. **动态色必须先解析再喂给引擎。** 渲染发生在 `setMarkdown` / 整篇重排里，**不是绘制回调** —— 这个时候 `UITraitCollection.current` 是「未指定」，`editorBackground`（默认主题下就是 `.systemBackground`）会被当成浅色解析。于是系统开着深色，却画出一张浅色图贴到深色底上。做法是退到**前台窗口的 trait collection**（见 `appearanceTraits`）；如果调用本来就发生在 `draw(_:)` / `layoutSubviews` 里，那 `UITraitCollection.current` 是对的，直接返回、不多问窗口。
2. **缓存键别自己拼颜色。** `DiagramTheme.fingerprint` 是引擎把七个槽位（含六个分类色）连同明暗档一起算出来的摘要，动态色还按与绘制同一套外观解析过。自己拼最容易漏：回头主题多塞一个颜色进请求，这里忘了加，症状是「换了主题图还是旧配色」，而且只在某两份主题之间才复现。

### 5.2 `MarkdownEditorHy4/MarkdownDocumentViewController.swift`（修改一行）

在原来注入 `mathRenderer` 的地方旁边加一行：

```swift
editor.renderer.mathRenderer    = SwiftMathRenderer.shared
editor.renderer.mermaidRenderer = MermaidKitRenderer.shared   // 新增
```

### 5.3 `Package.swift`（修改）

在 `dependencies` 里加：
```swift
.package(url: "https://github.com/2389-research/MermaidKit.git", from: "2.3.0"),
```

**同时**：`platforms` 抬到 `.iOS(.v17), .macCatalyst(.v17)`（如果 §2 选 A）。

⚠️ **一个坑**：你的 `Package.swift` 头部注释明说「不要把本包也加进 App 的 Xcode 工程依赖，否则同一批源码会被编两遍」。MermaidKit 是**外部依赖**，正确做法是：
- 只在 **Xcode 工程**（MarkdownEditorHy4.xcodeproj）的 "Package Dependencies" 里添加 MermaidKit
- **不要**在 `Package.swift`（这是给开源库 MarkdownEditor 用的）里加
- 库层只见到 `MarkdownMermaidRenderer` 协议，App 层见到 MermaidKit 实现，跟 SwiftMath 一模一样

---

## 6. 周边能力顺手一起做

### 6.1 深浅色跟随
配色走 §2.2 那张映射表（`DiagramTheme` 的**全色 init**），`prefersDark` 由 `UIColor.isDarkForDiagram` 从背景色的**相对亮度**现算 —— 项目里并没有「深色主题」这个概念，所以不去问系统外观。
换主题时自动重画，靠的是缓存键里那截 `DiagramTheme.fingerprint`（引擎把七个槽位连同明暗档一起算的摘要）。**不用额外做什么**。

### 6.2 HTML 导出（`MarkdownEditor/Export/` 三个文件 + `DocumentExporter.swift`）
⚠️ **不要照初稿那样在库层直接调 `MermaidRenderer.svg`** —— 那等于让开源库 `import MermaidRender`，把「库不依赖图表引擎」这条架构约定（§3）当场废掉。

实际做法是把 §3 那条注入路再走一遍，只是换成了「字符串进、字符串出」的闭包：

```
DocumentExporter.makeHTML                      ← App 层：注入 MermaidKitRenderer.shared.svg
      ↓ MarkdownHTMLExporter.Options.diagramSVG   （签名是 (MarkdownMermaidRequest) -> String?）
MarkdownHTMLExporter.exportDocument            ← 拼出请求（宽度 / 四个颜色 / 字号都从 tokens 取）
      ↓ renderer.diagramSVG = { source in … }
MarkdownHTMLRenderer.visitCodeBlock            ← 库层：只认闭包，不知道引擎是谁
```

好处：SVG 是矢量的，浏览器里缩放不糊；比塞 PNG base64 小 10 倍以上。
⚠️ 颜色取的是**页面**那套配色（`tokens.text` / `pageBackground` / `link` / `rule`），不是编辑器主题 —— 导出 HTML 可以选「内置浅色」，那种情况下页面是白的，图也必须按白底画。
⚠️ 引擎返回 `nil`（语法不合法）时退回 `<pre><code>` 显示源码原文，和编辑器那条路一个规矩。

### 6.3 PDF 导出（`MarkdownEditorHy4/MarkdownPDFExporter.swift`）
直接用现有的 attachment 图片即可（`MermaidRenderer.image` 返回的 `UIImage` 已经在 PDF 上下文里画过一次）。想要矢量 PDF 的话，MermaidKit 也支持 `RenderScene` → PDF 的路径，不过第一版没必要。

### 6.4 复制到剪贴板（`ClipboardHTMLMarkdown.swift`）
选中一个 Mermaid 图 → 复制时，除了源码文本，另外塞一份 `MermaidRenderer.pngData(source:format:theme:)` 到 pasteboard 的 `public.png` 类型。粘到 Keynote / 微信 / 邮件里就是一张图。

### 6.5 白送的其他围栏语言
MermaidKit 的 `format` 参数支持 `.mermaid | .dot | .dippin | .sqlDDL | .gitLog`。
`visitCodeBlock` 里的判断可以直接扩展：
```swift
let formatMap: [String: MermaidFormat] = [
    "mermaid": .mermaid, "mmd": .mermaid,
    "dot": .dot, "graphviz": .dot,
    "sql-ddl": .sqlDDL,
]
```
第一版可以先只做 mermaid，后面几行是白捡的。

---

## 7. 风险和坑（老实说）

1. **MermaidKit 只有 10 stars，仓库 2026-07 才建**。作者 2389-research 是个机构号（不是个人），主页 https://2389.ai/research/products/mermaidkit/ 说是他们的 research 产品。**缓解**：MIT 许可，最坏情况可以 fork 到自己名下继续维护；`Package.resolved` 锁死具体 commit（比如 v2.3.0 的 `918d9e8`），不会突然被上游改坏。

2. **iOS 17 地板**（见 §2）。这是唯一需要用户拍板的点。

3. **Mermaid 语法覆盖不是 100%**。README 里作者自己说得很清楚：
   - `%%{init:}%%` / `classDef` / `style` / `linkStyle` / `click` 这些**样式指令被忽略**（图还是会画出来，只是没样式）
   - HTML 标签只认 `<br/>`，其他标签当纯文本
   - FontAwesome 图标、动画、click 回调**不支持**
   - flowchart 的平行四边形 / 梯形 / 非对称形状会画成矩形（label 保留）

   **缓解**：库层协议规定 `nil` → 显示源码原文，用户至少能看到自己写了啥；同时给这类不支持的语法在项目 `doc/功能说明.md` 里加一段说明。

4. **同步渲染的时间上限是 ~25ms（sankey 最坏）**。放在渲染紧循环里，如果一篇文档塞了 20 个 sankey 图，整篇重排就是 500ms —— 会明显卡一下。**缓解**：
   - `NSCache` 命中率会非常高（改字号 / 换主题时 source 没变）
   - 如果实测还是卡，第二版可以把首次渲染改成 async（先显示源码，图好了再替换）—— 但**不要一开始就上 async**，会引入闪烁问题，参考 SwiftMath 那条同步路的稳定性

5. **附件在文本流里只占 1 个字符，源码里是 N 个字符**。这条**已经核实过，现成就能用，不用改任何东西**：`RenderedFragment.attachment(_:sourceStart:sourceLength:attributes:)` 的注释原文就是「只占 1 个字符位，但吃掉了源码里 `sourceLength` 个字符」；块级公式 `$$…$$` 跨多行映射到 1 个字符位，就是同一个场景。**不要自己另造一套映射**。

6. **TextKit 2 的 `NSTextAttachmentViewProvider` 不能用**。`MathAttachment.swift` 的头部注释写得非常明白：「TextKit 2 只在 App 生命周期里调一次 `loadView()`，整篇替换内容之后新附件的 view 根本不会被加载」。**Mermaid 必须走 `NSTextAttachment.image` 这条位图路，不能塞 UIView**。哪怕 MermaidKit 也提供 SwiftUI 的 `MermaidView`，本项目**不要用它**。

---

## 8. 实施状态（2026-10-16 实施完毕）

**Milestone 1：跑通最小闭环 —— ✅ 已完成**
1. ~~抬宿主工程 iOS 部署目标到 17.0~~ → **改方案**：fork 一份降到 iOS 16（见 §2），宿主部署目标一个字节没动
2. 依赖：**本地 SPM 包**（`XCLocalSwiftPackageReference "MermaidKit"`，`relativePath = ../MermaidKit`），只加到 App target
3. `MarkdownEditor/Rendering/MarkdownMermaidRenderer.swift` —— 协议 + `MarkdownMermaidRequest`（4 色 + 宽度 + 字号）+ `MarkdownMermaidLanguages`（编辑器与导出共用同一份语言判据）
4. `MarkdownEditor/Rendering/Attachments/MermaidAttachment.swift`
5. `MarkdownEditorHy4/MermaidKitRenderer.swift` —— 单例 + `NSCache`，配色走 §2.2 那张映射表
6. `MarkdownEditor/Rendering/MarkupToAttributedRenderer.swift` —— `mermaidRenderer` 属性 + `visitCodeBlock` 开头拦截
7. `MarkdownEditorHy4/MarkdownDocumentViewController.swift` —— 注入 `MermaidKitRenderer.shared`
8. 目视验证：往文档里写 ` ```mermaid\nflowchart TD\n  A --> B\n``` ` 看图出不出来（下面 §8.1）

**Milestone 2：单元测试 —— ✅ 已完成**
- `MarkdownEditorHy4Tests/MarkdownMermaidTests.swift` —— 组件层，用**假引擎**（换引擎这组照样成立）：占位符数量 / 喂给引擎的是围栏正文 / 不再挂代码块标记 / 认领整段源码 / 图后面跟着弱化源码 / 全选复制还原源码（3 条）/ 6 条回退 / `mmd` 别名 / 大小写 / ` ``` mermaid` 前导空格 / 请求参数 / 宽度跟随容器 / 宽图缩放、窄图不放大
- `MarkdownEditorHy4Tests/MermaidKitRendererTests.swift` —— **真的**过一遍 MermaidKit：合法图出得来、半截语法返回 nil、深浅底画出不同的图、重复请求命中缓存、不同宽度不互相顶掉、不同强调色各留一份缓存
- `MarkdownEditorHy4Tests/MarkdownHTMLExporterTests.swift` —— +6 条：围栏 → 内联 SVG、没注入时回退、引擎返回 nil 时回退、只认 mermaid 围栏、页面配色取自 tokens 而不是编辑器主题、CSS 约束 SVG 宽度

**Milestone 3：周边能力 —— 部分完成**
- ✅ HTML 导出走 SVG（§6.2）—— 走 `Options.diagramSVG` 闭包注入，**库层仍然不认识引擎**
- ✅ PDF 导出（§6.3）—— 和 HTML 共用一条管线（`makeHTML` → `MarkdownPDFExporter`），所以自动跟着走 SVG，不用另写
- ⬜ 剪贴板复制加 PNG（§6.4）—— **没做**

**Milestone 4：白送的扩展**（DOT / SQL DDL / git log）—— 没做，`MarkdownMermaidLanguages.all` 里留了口子

### 8.1 跑测试要注意的四件事（这次全踩了一遍，都实测过）

1. ⚠️ **Catalyst 目的地跑不了这一套**：`xcodebuild test` 在 Catalyst 上直接 `The test runner hung before establishing connection.`，6 分 49 秒后整轮失败、**一条用例都跑不到**（退出码 65，清 DerivedData 无效）。**改跑 iOS 模拟器**：

   ```
   xcrun simctl boot <设备 UDID>
   xcodebuild test -scheme MarkdownEditorHy4 \
     -destination 'id=<设备 UDID>' \
     -derivedDataPath /tmp/hy4-dd-ios \
     -parallel-testing-enabled NO \
     -only-testing:MarkdownEditorHy4Tests \
     CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
   ```

2. 🚨 **`MarkdownPDFExporterTests` 在这台模拟器上会永久挂起，拖死整轮**。用例是 `async` 等 `WKWebView` 排版回调，日志里有 `Failed to resolve host network app id`，那个 `withCheckedContinuation` 永不 resume —— 加 `-test-timeouts-enabled YES` 也拦不住。和 Mermaid 无关（那条路一行图表代码都没碰）。临时办法：`-skip-testing:MarkdownEditorHy4Tests/MarkdownPDFExporterTests`（实测跳过它，**652 条 35.6 秒**跑完）；根治办法是给 `makePDF` 那个 `withCheckedContinuation` 加超时兜底。

3. ⚠️ **别把 xcodebuild 的输出直接重定向到文件**。它会派生子进程、各自持有**同一个 fd 的旧写偏移**，日志会被写花：「最后一行」是构建早期的 `Resolve Package Graph`，「最后开始的用例」是早就跑完的那些 —— 我照着错乱日志怀疑了两个无辜的用例。**中间加一根管道**（`xcodebuild … 2>&1 | cat > log`）写入就串行化了，顺序完全可信。（另外 `grep -c` 在这台机器上偶发返回 0，怀疑计数不可信时改用 `ls -l` 看 mtime 有没有在动。）

4. ✅ **固定 7 条「老面孔」红是正常的，不是回归**。全量 652 条里恰好 7 处失败（4 个用例、7 个断言），全是**只在 iOS 模拟器红、Catalyst 绿**的平台亚像素 / 空间差异，项目记忆 `MEMORY-详细判据.md` 里逐条记着，**不许为它们改渲染代码**：

   | 用例 | 断言数 | 实际值 |
   | --- | --- | --- |
   | `MarkdownEditorHy4Tests.testCheckboxFrameSitsLeftOfLiteral` | 2 | `frame.maxX` 76.94 vs 上限 76.5 |
   | `MarkdownEditorHy4Tests.testQuoteChainAttributeMarksNesting` | 1 | 内层引用挂两层链的区间实为 2 个 |
   | `MarkdownTableScrollTests.testNarrowTableHasNoScrollView` | 2 | 3 列窄表格在模拟器上被判成要横滚 |
   | `MarkdownTableScrollTests.testScrollerSurvivesVerticalScrolling` | 2 | 竖滚后容器重建、横滑位置归零 |

   **判据**：失败集合和上表逐条对得上 = 无新增回归。（xcodebuild 报的失败条数是**断言数**，不是用例数。）

---

## 9. 参考资料

- MermaidKit 仓库：https://github.com/2389-research/MermaidKit
- MermaidKit 产品页：https://2389.ai/research/products/mermaidkit/
- 项目内已有的同类模式：
  - [doc/SwiftMath渲染LaTeX方案.md](/Users/pan/Project/iOSDemo/MarkdownEditorHy4/doc/SwiftMath渲染LaTeX方案.md) —— LaTeX 是怎么接进来的
  - [doc/代码高亮方案.md](/Users/pan/Project/iOSDemo/MarkdownEditorHy4/doc/代码高亮方案.md) —— 库/App 分层的另一例
  - [doc/架构与界面约定.md](/Users/pan/Project/iOSDemo/MarkdownEditorHy4/doc/架构与界面约定.md)
- 关键源码：
  - `MarkdownEditor/Rendering/MarkdownMathRenderer.swift`（协议样板）
  - `MarkdownEditor/Rendering/Attachments/MathAttachment.swift`（附件样板，头部注释解释了为什么不能用 ViewProvider）
  - `MarkdownEditorHy4/SwiftMathRenderer.swift`（App 层实现样板，缓存策略照抄）
  - `MarkdownEditor/Rendering/MarkupToAttributedRenderer.swift` line 788（`visitCodeBlock` 拦截点）

---

## 附录：事实核查记录（2026-10-16）

初稿里有一批「凭印象写的」API 和文件名，照着写会对不上。下面逐条核对过项目源码和上游 README。

### 已核实无误

| 项 | 核实来源 | 结论 |
| --- | --- | --- |
| `MermaidRenderer.image(source:theme:)` | 上游 README | ✅ 签名一致 |
| `DiagramTheme(prefersDark:)` | 上游 README | ✅ 签名一致 |
| `format: .mermaid / .dot / .dippin / .sqlDDL / .gitLog` | 上游 README | ✅ 一致，§6.5 可以照做 |
| `MermaidParser.parse(_:)` 失败返回 `nil` | 上游 README | ✅ 一致 |
| `attachmentString(source:format:theme:)` / `pngData(source:format:theme:)` | 上游 README | ✅ 都存在 |
| 注入点 `MarkdownDocumentViewController.swift:178` | 项目源码 | ✅ 就是 `editor.renderer.mathRenderer = SwiftMathRenderer.shared` |
| `SwiftMathRenderer` 的 `NSCache<NSString, UIImage>` | 项目源码 | ✅ 可照抄 |
| `localRange(of:)` / `theme.blockAttachmentParagraphStyle(indent:)` / `theme.tableSourceAttributes` | 项目源码 | ✅ 都存在 |
| 其余被引用的文件（`HTMLExportOptionsController.swift`、`ClipboardHTMLMarkdown.swift`、两个测试文件…） | 项目源码 | ✅ 都存在 |

### 已修正（初稿里会编译不过的）

| # | 初稿写的 | 实际 | 已改成 |
| --- | --- | --- | --- |
| 1 | `codeBlock as? FencedCodeBlock` | swift-markdown **没有**这个类型；围栏块就是 `CodeBlock`，语言在 `codeBlock.language` 上 | 直接判 `codeBlock.language` |
| 2 | `.attachment(_, sourceRange:, replacesLength:)` | 参数实际是 `sourceStart:` / `sourceLength:` / `attributes:` | 真实签名 |
| 3 | `theme.prefersDark` | `MarkdownTheme` 里**没有**这个字段（全项目搜不到 `prefersDark` / `isDark` / `userInterfaceStyle`） | 改为传 `textColor` + `backgroundColor`，由 App 层的 `UIColor.isDarkForDiagram` 现算 |
| 4 | `containerWidthForBlockImages()` | **不存在** | 改为 `max(120, containerWidth - indent - 16)`（`visitTable` 的同款算法） |
| 5 | `block.range` | 是 `Range<SourceLocation>?`，类型对不上 | 改为 `localRange(of: block)` |
| 6 | `renderMathSegment`（line 268） | 函数实际叫 `renderMath`（line 266） | 已更正 |
| 7 | `MarkdownEditor/Export/MarkdownPDFExporter.swift` | 实际在 `MarkdownEditorHy4/MarkdownPDFExporter.swift` | 已更正 |

### 顺带纠正的一个「假工作量」

初稿末尾说「Math 是 1 字符换 1 字符，Mermaid 是 N 换 1，可能要给 `RenderedFragment` 加能力」——**这个担心是多余的**。
`RenderedFragment.attachment(...)` 的注释原文就是「只占 1 个字符位，但吃掉了源码里 `sourceLength` 个字符」，N→1 本来就是它的设计用途。已改成「现成可用」。

另外初稿的 `renderMermaidBlock` **漏了「图下面弱化显示源码」那两行** —— 补上之后才和 `visitTable` 行为一致，否则光标进不去源码、编辑不了，复制也会缺内容。

### 还没核实、必须实测的

| 项 | 为什么必须实测 |
| --- | --- |
| MermaidKit 能不能在 **Mac Catalyst** 下编译 | 它的 `platforms` 只写了 `.macOS / .iOS / .visionOS`，**没有 macCatalyst**。SwiftPM 一般会回退到 iOS 的声明，但得真的编一次才算数 |
| 出图质量 / 中文标签渲染 | 上游 README 的样张替代不了自己的场景 |
| `MermaidRenderer.svg(...)` 的确切签名 | README 只提到「now exports SVG too」，没给签名。做 §6.2 时以 Xcode 补全为准 |
| 同步渲染在一篇多图文档里的实际耗时 | README 的 <15ms/图 是空载测的，要按自己的文档量一遍 |
