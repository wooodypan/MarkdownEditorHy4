空格键预览（Quick Look）到底是怎么实现的 —— 以及怎么让自己 App 也吃上这一口

> 写给不熟悉 macOS 扩展机制的人。全文基于两个东西：**QLMarkdown 的源码**（本仓库 `QLMarkdown/`，作者 sbarex）和**在你这台机器上实测的输出**。
> 结论都标了出处；凡是「第三方资料说的、我没法在本机验证」的地方，我会明确写出来，别当成 Apple 官方文档。

---

## 0. 结论先行（先看这六条）

1. **空格键预览永远不会启动你的 App。** 它是一个独立的「App 扩展」（`.appex`），装在 `你的App.app/Contents/PlugIns/` 里，由系统在**单独的沙箱进程**里拉起来给一个文件 URL，扩展把渲染结果（HTML / PDF / 图片）还回去，Quick Look 自己弹窗显示。
2. QLMarkdown 就是干这件事的：把 Markdown **渲染成一整页 HTML**，用 `QLPreviewReply` 交出去。**它有两个 target：宿主 App（只管设置界面）+ 扩展（管渲染）**，真正的活全在扩展里。
3. 老式的 `.qlgenerator` 插件格式**从 macOS 15 (Sequoia) 起已被苹果移除支持**，第三方只能用 App 扩展。所以 2026 年了，想加预览能力只有一条路：**写 app extension**。
4. **装完不一定会生效**：扩展默认可能是关的，要去「系统设置 → 通用 → 登录项与扩展 → 快速查看」里打开。QLMarkdown 的 README 也专门写了这条（`README.md:457`）。
5. **切换预览器没有「按文件选」这回事**：同一个文件类型只会有一个赢家，系统自己挑，没有公开 API 指定。可控的只有一件事 —— **把不要的关掉**。
6. ⚠️ **建 target 别走错标签页**：同一个 `Quick Look Preview Extension` 模板在 iOS 和 macOS 两个标签页下都有。**Catalyst 工程必须选 iOS 标签页** —— 从 macOS 标签页建出来的是「纯 macOS 扩展」，在「Embed in Application」里根本选不到你的 App（Xcode 只列同平台的宿主）。详见 4.1 节，这是 10-13 实测纠正的一条。

---

## 1. 按下空格键那一瞬间，系统做了哪些事

在 Finder 里选中 `面试速览-大白话版.md`、按空格，顺序大概是：

| 步骤 | 谁在干 | 干了什么 |
| --- | --- | --- |
| ① | Finder | 收到空格键，向 Quick Look 子系统要「这个文件的预览」 |
| ② | LaunchServices | 算出这个文件的内容类型（UTI）。实测：`mdls -name kMDItemContentType` 得到 `net.daringfireball.markdown` |
| ③ | quicklookd | 拿 UTI 去查「谁申请了 `net.daringfireball.markdown`」——候选有两类：Apple 自带的 `/System/Library/QuickLook/*.qlgenerator`，和**已启用**的第三方 App 扩展（扩展点标识 `com.apple.quicklook.preview`） |
| ④ | 系统 | 挑中一个提供者，**在独立进程 + 沙箱里**把它拉起来，把文件 URL 交给它 |
| ⑤ | 扩展 | 读文件、渲染，返回 `QLPreviewReply`（HTML / PDF / 图片 / 纯文本） |
| ⑥ | Quick Look | 把返回的 HTML 塞进自己的窗口（内部是 WebKit）显示给你 |
| ⑦ | 系统 | 窗口关掉后，扩展进程被挂起/回收；按空格再开一次，可能复用也可能重启 |

三个反直觉但很关键的点：

- **不启动 App**。你的 App 只是「扩展的宿主 + 设置界面」。QLMarkdown 的 README 甚至明说：双击 md 文件不会打开它 —— 那是**故意的**（见下面第 3 节的 `LSHandlerRank`）。
- **扩展活在沙箱里**，默认连你选的那个 md 文件都读不到，得靠系统「交给你」的权限；想显示 md 里引用的本地图片，还得额外申请全盘只读例外（QLMarkdown 就这么干的，见第 3 节）。
- **同一类型只能有一个赢家**。这就是为什么「装了好几个能预览 md 的 App，按空格出来的却不是你想要的那个」。

---

## 2. QLMarkdown 的解剖

### 2.1 两个 target，各管一摊

| 目录 | 是什么 | 职责 |
| --- | --- | --- |
| `QLMarkdown/` | 宿主 App（你在 Launchpad 里看到的那个） | 设置界面：主题、字号、是否启用 MathJax/Mermaid 等。**自己不渲染** |
| `QLExtension/` | App 扩展（`Contents/PlugIns/` 里的 `.appex`） | 真正干活：读文件 → 渲染 HTML → 交回系统 |
| `Shortcut Extension/` | 另一个扩展（快捷指令） | 把 md 转 HTML 供「快捷指令」调用，跟空格键无关 |
| `qlmarkdown_cli` | 命令行工具 | 同上，终端里用 |

扩展的代码只有三个文件，别被吓到：

```
QLExtension/
├── Info.plist           ← 最关键的「我管哪些类型」在这里
├── PreviewProvider.swift ← 入口类，一共 88 行
├── Settings+ext.swift    ← 空的，只是给共享的 Settings 补扩展
└── QLExtension.entitlements ← 权限清单
```

### 2.2 入口类：整个扩展就干一件事

`QLExtension/PreviewProvider.swift:29-40` 是核心，翻成大白话：

```swift
/// 系统要预览某个文件时调这个。我们回一段 HTML 数据，剩下的窗口、WebView 都是 Quick Look 自己搭的。
func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
    // ① 读文件 → 渲染成 HTML 字符串（renderMD 里是 cmark-gfm 解析 + 套 CSS 外壳）
    let html = try renderMD(url: request.fileURL)

    // ② 告诉系统「我给你的是一段 HTML」，contentSize 只是建议尺寸，Quick Look 会自己调
    let reply = QLPreviewReply(dataOfContentType: .html, contentSize: Self.previewContentSize) { replyToUpdate in
        replyToUpdate.stringEncoding = .utf8
        return html.data(using: .utf8)!
    }
    return reply
}
```

这就是「**data-based**（数据型）」扩展：我只生产数据，界面交给你。另一种是「**view-based**（视图型）」，得自己写一个 `NSViewController` 来搭界面 —— 需要原生控件、复杂交互时才值得。两者对比：

| 形态 | 入口 | Info.plist 标志 | 适合 |
| --- | --- | --- | --- |
| 数据型（QLMarkdown 用这个） | 继承 `QLPreviewProvider`，实现 `providePreview(for:)` | `QLIsDataBasedPreview = true` | 「我要显示一片内容」，最省事 |
| 视图型 | `NSViewController` 实现 `QLPreviewingController`，在 `preparePreviewOfFile(at:)` 里搭视图 | 不写上面那项 | 要放原生控件、菜单、拖拽等 |

数据型能返回的格式（来自 `QuickLookUI` 的 `QLPreviewReply.h`）：图片、PDF、HTML、XML、纯文本、RTF、RTFD、视频、音频。另外还有两个专用构造器：`initForPDFWithPageSize`（直接给 PDF 文档）和 `initWithContextSize`（自己画位图/矢量）。

### 2.3 `QLExtension/Info.plist`：真正决定「能不能抢到 .md」的五个键

| 键 | QLMarkdown 的值 | 什么意思 |
| --- | --- | --- |
| `NSExtensionPointIdentifier` | `com.apple.quicklook.preview` | 声明「我是快速查看预览扩展」。写错了系统根本不认 |
| `NSExtensionPrincipalClass` | `$(PRODUCT_MODULE_NAME).PreviewProvider` | 入口类。**必须带模块名**（Swift 特有） |
| `QLSupportedContentTypes` | 17 个 UTI（`net.daringfireball.markdown`、`public.markdown`、`io.typora.markdown` …） | **声明我管哪些文件类型**。这是「抢类型」的唯一手段 |
| `QLIsDataBasedPreview` | `true` | 上面说的数据型 |
| `QLSupportsSearchableItems` | `false` | 要不要支持 Spotlight 搜索结果的预览，一般不用 |

⚠️ 两个容易忽略的坑：

- 列表里那 7 个 `dyn.ah62d4rv4ge8...` 是**动态 UTI**。当一台电脑上没装任何 Markdown App 时，`.md` 文件会被系统临时发一个这种动态类型号；QMarkdown 把它们也声明上，才能保证「不管对方机器上装了什么，md 都能预览」。
- 里面还有 `com.nutstore.down`（坚果云）。**实测你这台机器** `~/Library/QuickLook/` 里就躺着一个坚果云的老式插件（`NSQuickLookPlugin.qlgenerator` → 软链到 Nutstore.app）—— 老插件本身在 Sequoia 之后已经失效了，但它声明的类型还在被新扩展接管。

### 2.4 宿主 App 的 `Info.plist`：为什么要声明「我能打开 .md」

`QLMarkdown/Info.plist:7-47` 声明了三组 `CFBundleDocumentTypes`，每组都是：

```xml
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>None</string>   <!-- ← 关键 -->
<key>LSItemContentTypes</key><array><string>net.daringfireball.markdown</string></array>
```

`LSHandlerRank = None` 的意思是「**别把我算进『打开方式』菜单**」。QLMarkdown 的 README 明确说这是有意为之（`README.md:499-503`）：

> QLMarkdown doesn't appear in the list of applications that can open a Markdown file… **This is a desired behaviour.**

另外它还写了 `UTImportedTypeDeclarations`，把 `.md` / `.markdown` / `.rmd` / `.qmd` 这些**扩展名到 UTI 的对应关系**告诉系统 —— 这些类型不是它发明的（所以是「导入 Imported」而不是「导出 Exported」）。

> 对本项目的意义：我们的 App（`MarkdownEditorHy4/Info.plist`）已经声明了 `net.daringfireball.markdown`（`LSHandlerRank = Alternate`，角色 Editor），**这部分不用改**。加扩展时只要让扩展的 `QLSupportedContentTypes` 用同一串 UTI 就行。

### 2.5 权限清单：为什么它要「读整个磁盘」

`QLExtension/QLExtension.entitlements` 里有几条值得单独说：

| 权限 | 为什么需要 |
| --- | --- |
| `com.apple.security.app-sandbox = true` | 扩展**必须**沙箱（Apple 规定） |
| `com.apple.security.files.user-selected.read-only` | 系统交给扩展的那个文件，得能读 |
| `com.apple.security.temporary-exception.files.absolute-path.read-only = ["/"]` | **读全盘**。md 里写 `![](./images/a.png)` 时要能读到那个图片（源码里也有注释：扩展想访问主 App 的 bundle，要么不沙箱、要么申请全盘读取例外） |
| `com.apple.security.application-groups = ["group.org.sbarex.qlmarkdown"]` | 主 App 和扩展**共享设置**：主题、字号存在这个组容器里（`Settings.applicationSupportUrl` 用的就是 `containerURL(forSecurityApplicationGroupIdentifier:)`） |
| `com.apple.security.network.client` | MathJax / Mermaid 默认从 CDN 拉 JS，得联网 |
| `com.apple.security.temporary-exception.mach-lookup.global-name` | 设置改了怎么通知扩展？用 `DistributedNotificationCenter` 广播 `org.sbarex.qlmarkdown-settings-changed`（`Settings.swift:557`）。你在设置界面改字号，已经打开着的预览窗口能立刻跟着变，靠的就是它 |

### 2.6 主 App 和扩展怎么共用代码

看工程文件会发现：`Settings.swift`、`Settings+render.swift` 这两个文件**同时被加进了 4 个 target**（App、预览扩展、快捷指令扩展、CLI）。

```
Settings.swift       → 主 App ✓  预览扩展 ✓  快捷指令扩展 ✓  CLI ✓
Settings+render.swift → 主 App ✓  预览扩展 ✓   …
```

这是 macOS 开发里最常见的共享方式：**同一份源文件勾给多个 target**，而不是抽成一个 framework。
对本项目的启发：我们也可以把「markdown → HTML」那一套直接勾给新扩展 —— **但有个硬前提**，见第 4.4 节。

### 2.7 安全：渲染出来的 HTML 是「不可信内容」

`Settings+render.swift:865` 那段值得抄作业。它给每次渲染生成一个**随机 nonce**，用 Content-Security-Policy 卡住脚本执行：

```
default-src 'none'; script-src 'nonce-<随机值>' https://cdn.jsdelivr.net; object-src 'none'; base-uri 'none'; form-action 'none'
```

原因写在源码注释里：md 里允许裸 HTML，而 `tagfilter` **不会**过滤掉事件属性（`onclick` 之类），所以必须靠 CSP 兜底，只放行带 nonce 的脚本。你自己写扩展的话，**这条别省**。

---

## 3. 两代技术：为什么现在只能用 App 扩展

| | 老：`.qlgenerator` | 新：App 扩展（`.appex`） |
| --- | --- | --- |
| 出现年代 | 很早 | macOS 10.15 (Catalina) 起，WWDC 2019 宣布 |
| 安装位置 | `~/Library/QuickLook`、`/Library/QuickLook`、`App.app/Contents/Library/QuickLook/` | `App.app/Contents/PlugIns/` |
| 第三方向系统发预览 | 生成 `QLPreview` 之类的对象、或者画图后交给 `qlmanage` 渲染 | 直接回 `QLPreviewReply`（HTML/PDF/图片），界面归系统 |
| 现在还能用吗 | ❌ **macOS 15 Sequoia 起苹果移除了第三方 qlgenerator 支持** | ✅ 唯一可用方案 |
| 查看工具 | `qlmanage -m plugins`（只能看到 Apple 自带的） | `pluginkit`（且 macОS 26 上已受限，见 5.3） |

> ⚠️ 顺带一个容易看错的地方：**Apple 自己的插件文件现在仍然叫 `.qlgenerator`**（就在 `/System/Library/QuickLook/`），它们还能用。被干掉的是**第三方**的。所以别看到 `.qlgenerator` 就以为一定过时了，要看它在哪个目录、是谁提供的。

实测你这台机器上还留着两个**已经失效**的第三方老插件（可以删，删了没影响）：

```
~/Library/QuickLook/NSQuickLookPlugin.qlgenerator        → 指向 坚果云 Nutstore.app
/Library/QuickLook/SogouSkinFileQuickLook.qlgenerator     → 搜狗皮肤
```

---

## 4. 想让自己的 App 也支持空格预览：分步做法

以下步骤是「给 MarkdownEditorHy4 加一个 md 预览扩展」的完整路线。**先不动手也看得懂**，改代码之前可以先拿 Xcode 的模板跑一个 hello world 玩。

### 4.1 第一步：新建扩展 target（⚠️ 走 **iOS** 标签页，不是 macOS）

Xcode → `File` → `New` → `Target…` → **iOS** 标签页 → `Application Extension` → **`Quick Look Preview Extension`**。

**为什么不是 macOS 标签页**：那里面确实有同名模板，但建出来是「纯 macOS 扩展」（`SDKROOT = macosx`），而本项目的 App 是 iOS + Catalyst（`SDKROOT = iphoneos`、`SUPPORTS_MACCATALYST = YES`、没有 `MACOSX_DEPLOYMENT_TARGET`）。Xcode 的「Embed in Application」**只列同平台的宿主 App** —— Catalyst 在 Xcode 眼里属于 iOS 平台家族，所以在 macOS 标签页那一步，你翻遍下拉都找不到 `MarkdownEditorHy4`。

⚠️ 这不是「Mac Catalyst 不支持快速查看扩展」，只是**标签页选错了**。同一个扩展点（`com.apple.quicklook.preview`）两个平台都有，iOS 侧的证据见本节末尾。

iOS 标签页下这个模板的真实路径（本机实测）：
> `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/Library/Xcode/Templates/Project Templates/iOS/Application Extension/Quick Look Preview Extension.xctemplate`

（macOS 标签页那份在同级 `MacOSX.platform/…/macOS/Application Extension/` 下，只给「单独做 macOS 壳 App」那条路用，见 4.4 节。）

创建时 Xcode 会问「Embed in Application」，这时才选得到 `MarkdownEditorHy4`。产物路径会是：

```
MarkdownEditorHy4.app/Contents/PlugIns/你的扩展.appex
```

模板会给你两份骨架（选一种用，另一种删掉）：
- `PreviewProvider.swift`（数据型。**只 `import QuickLook`，不碰 UIKit/AppKit，跨平台最干净，推荐**，注释里就写着要改哪几个 Info.plist 键）
- `PreviewViewController.swift`（视图型。iOS 版是 `UIViewController` + storyboard，macOS 版是 `NSViewController` + `.xib`）

**建完别忘最后一步**：给扩展 target 也打开 Mac Catalyst —— Build Settings 里加 `SUPPORTS_MACCATALYST = YES`，或者 General → Supported Destinations 里把 Mac 勾上。漏了的话，构建 Catalyst 版时 Xcode 会直接报：

```text
Building for Mac Catalyst, but the embedded app extension '你的扩展.appex' is building for iOS.
You may need to configure '你的扩展.appex' to build for Mac Catalyst or restrict
the platforms for which this app extension should be embedded in the target editor.
```

**iOS 侧真有这个扩展点的三条证据**（本机实测，2026-10-13）：
- Xcode 里有 iOS 版模板，`Identifier = com.apple.dt.unit.quicklookios`，`Ancestors = iosAppExtensionBase`。
- iOS 26 运行时的 `QuickLook.framework/Info.plist` 里注册着 `com.apple.quicklook.preview`（`NSExtensionContextClass = QLPreviewExtensionServiceContext_iOS`）。
- Apple 文档给 `QLPreviewingController` 标的可用性是 `iOS 4.0+ / iPadOS 4.0+ / **Mac Catalyst 13.0+** / visionOS 1.0+`；iOS SDK 的 `QLPreviewingController.h` 里还有一句专门提醒：「**For Catalyst compatibility**, avoid using gesture recognizers that take interactions over large portions of the view to avoid collisions with standard **macOS preview behaviors**」—— 这句话只有在「这个扩展会跑在 macOS 的快速查看窗口里」时才讲得通。

### 4.2 第二步：改扩展的 Info.plist

```xml
<key>NSExtension</key>
<dict>
  <key>NSExtensionPointIdentifier</key>
  <string>com.apple.quicklook.preview</string>

  <key>NSExtensionPrincipalClass</key>
  <string>$(PRODUCT_MODULE_NAME).PreviewProvider</string>

  <key>NSExtensionAttributes</key>
  <dict>
    <key>QLIsDataBasedPreview</key>
    <true/>
    <key>QLSupportsSearchableItems</key>
    <false/>
    <key>QLSupportedContentTypes</key>
    <array>
      <!-- 只声明我们真正管的类型，别把 public.plain-text 也写进来，那会把所有 txt 都抢走 -->
      <string>net.daringfireball.markdown</string>
      <string>public.markdown</string>
      <string>com.unknown.md</string>
    </array>
  </dict>
</dict>
```

⚠️ `QLSupportedContentTypes` 是**唯一**决定「能不能抢到 .md」的地方，写少一个类型就会出现「有的机器能预览、有的不能」。

### 4.3 第三步：写入口类

```swift
// iOS / Mac Catalyst 版扩展这么写（4.1 节推荐的路线）
import QuickLook
import UniformTypeIdentifiers
// 纯 macOS 扩展才是：import Cocoa + import QuickLookUI

/// 快速查看扩展的入口。
/// 数据型扩展只生产内容，弹窗、WebView、滚动条都由 Quick Look 自己负责，我们不用管。
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    /// 系统每次要预览都会调这个方法。
    /// 注意它是异步的，Quick Look 会一直转圈直到返回，所以别在这里做耗时的事。
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        // request.fileURL 就是被预览的文件。沙箱下不一定读得到，见 4.5 节的权限说明。
        let markdown = try String(contentsOf: request.fileURL, encoding: .utf8)
        let html = renderToHTML(markdown)

        // contentSize 只是「建议尺寸」：先按这个大小把加载中的界面摆出来，真实内容进来后系统会自己调。
        return QLPreviewReply(dataOfContentType: .html,
                              contentSize: CGSize(width: 820, height: 900)) { reply in
            // 告诉系统这段数据的编码，默认就是 utf8，写出来是为了明确。
            reply.stringEncoding = .utf8
            return Data(html.utf8)
        }
    }

    /// 把 markdown 变成一整页能独立显示的 HTML。
    /// Catalyst 版扩展其实可以 `import UIKit`，但渲染这段只依赖 Foundation 更保险 ——
    /// 以后万一要退回纯 macOS 壳 App 那条路，这份代码不用改。三个坑见 4.4 节。
    private func renderToHTML(_ markdown: String) -> String {
        let body = MarkdownHTMLConverter.render(markdown)
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>body{font:15px -apple-system;margin:28px}</style>
        </head><body>\(body)</body></html>
        """
    }
}
```

### 4.4 第四步：共享渲染代码时的三个坑 ⚠️

这一步最容易翻车，先说结论：

| 坑 | 说明 | 对本项目的具体影响 |
| --- | --- | --- |
| **纯 macOS 扩展里不能用 UIKit** | 那种扩展是 macOS (AppKit) 的可执行文件，`import UIKit` 直接编译不过。**Catalyst 版扩展正好相反** —— 它跑的就是 UIKit-for-Mac，`import UIKit` 完全合法 | 本项目 `MarkdownEditorHy4/MarkdownHTMLRenderer.swift`、`MarkdownHTMLStyle.swift`、`MarkdownHTMLExporter.swift` **都 import 了 UIKit**（多用在颜色/字体换算上）。走 **Catalyst 路能编过**，但**不能原样搬去 macOS 壳 App** —— 想两边通吃，就得把颜色/字体换算抽成 Foundation-only |
| **扩展里不能调「App 专用」API** | 扩展 target 要开 `APPLICATION_EXTENSION_API_ONLY = YES`；一旦链接的代码里用了被禁 API（`UIApplication.shared`、`+[UIApplication openURL:]` 这类），直接链接报错 | 得给依赖加编译标志（Swift 用 `-application-extension`，C/ObjC 用 `-fapplication-extension`）。本仓库 `MarkdownEditor/` 那个包声明的是 **iOS 16 / Mac Catalyst**（`Package.swift:18-22`），**走 Catalyst 路平台是匹配的**，可以试着直接依赖它 —— 但要先拿 `APPLICATION_EXTENSION_API_ONLY` 编一遍，看看有没有踩到被禁 API |
| **扩展必须和宿主同平台** | Xcode 的「Embed in Application」只列同平台的宿主 App；想混搭（比如把 macOS appex 塞进 Catalyst App）得手写 Copy Files 阶段，不值当 | 本项目 App 是 iOS + Catalyst，所以扩展也要建成 **iOS target + 打开 Mac Catalyst 支持**（4.1 节），工程里**不会**多出 macOS target。只有走「单独做 macOS 壳 App + 纯 macOS 扩展」那条路时，才会给工程添第一个 macOS target |

> 另一条备用路：仓库里已经有一个 **Foundation-only** 的渲染器 —— `swift-markdown-engine/`（`platforms: [.macOS(.v14)]`，核心 target 零外部依赖，`Sources/MarkdownEngine/Renderer/MarkdownHTMLRenderer.swift` 只 `import Foundation`）。**万一 Catalyst 那条路在 Finder 里不生效**、只能退回纯 macOS 壳 App，就用它，比给 UIKit 那套动手术干净得多。

### 4.5 第五步：配权限（entitlements）

⚠️ **这一步最容易整段漏掉，而漏了的表现就是「按空格什么也不发生」** —— 新建出来的扩展 target **默认没有 entitlements 文件**，`CODE_SIGN_ENTITLEMENTS` 也是空的。

而且**宿主的权限不会自动继承给扩展**：Xcode 会给 Catalyst 宿主自动注入 `app-sandbox`，但**不会**给嵌在它里面的 `.appex` 注入。所以这两件事得亲手做：

1. 生成 entitlements 文件：选中扩展 target → `Signing & Capabilities` 标签 → 点 `+ Capability` → 加 **App Sandbox**，Xcode 会自动建好文件并填上 `CODE_SIGN_ENTITLEMENTS`；
2. 自己去 Build Settings 搜 `entitlements` 确认一下这条设置指向了那个文件（手动建文件的话，就得自己填）。

验一验真的签进去了没有：

```bash
codesign -d --entitlements :- "你的.app/Contents/PlugIns/你的.appex" | plutil -p -
```

输出里**必须**有 `com.apple.security.app-sandbox => true`。只有一条 `get-task-allow` 就是漏了。

权限清单照 QLMarkdown 抄，按需删减：

| 权限 | 要不要 | 说明 |
| --- | --- | --- |
| `com.apple.security.app-sandbox` | **必开** | `true`。Apple 要求 |
| `com.apple.security.files.user-selected.read-only` | 建议开 | 读系统交过来的那个文件 |
| `temporary-exception.files.absolute-path.read-only = ["/"]` | 看需求 | **想显示 md 里引用的本地图片就必须开**（否则图片全是裂图）。这正是 QLMarkdown 申请全盘只读的原因 |
| `com.apple.security.application-groups` | 想共享设置就开 | 主题、字号这类配置放组容器，主 App 改了扩展能读到 |
| `com.apple.security.network.client` | 看需求 | 要加载 CDN 的 MathJax/Mermaid 就开 |
| `mach-lookup.global-name` | 想实时刷新就开 | 配合 `DistributedNotificationCenter` 让「设置一改，已经打开的预览立刻重画」 |

### 4.6 第六步：装 + 开启

1. 编译、把 `.app` 放进 `/Applications`（或 `~/Applications`）。
2. **手动打开一次这个 App**（QLMarkdown 的 README 专门强调这句）：扩展要被系统「发现」，靠的是 App 启动时向 LaunchServices/PlugInKit 注册。装完从来没打开过 = 系统根本不知道有它。
3. 去开启扩展：**系统设置 → 通用 → 登录项与扩展 → 快速查看**（英文：`System Settings ▸ General ▸ Login Items & Extensions ▸ Quick Look`），找到你的扩展、打开开关。
   - macOS 14 及更早，这个面板在 **隐私与安全性 → 扩展 → 快速查看**。
   - 想让 App 里加个按钮直接跳过去，用这个 URL（QLMarkdown 就在用，见 `QLMarkdown/ViewController.swift:1520`）：
     `x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.quicklook.preview`
4. 让它生效：`qlmanage -r`（强制重新扫一遍生成器列表）。改完 Info.plist 反复调试时基本每次都要来一下。

### 4.7 第七步：调试

| 想干什么 | 怎么做 |
| --- | --- |
| 调试扩展（推荐） | 选中扩展 target 的 scheme → `Edit Scheme` → `Run` → **Executable 选 `Finder`**（或 `Ask on Launch`，启动时弹框让你选 Finder），然后在 `providePreview` 里打断点，去 Finder 按空格 |
| 觉得断点没命中 | 扩展跑在系统拉起的独立进程里（名字里有 `QuickLook`，可以在活动监视器里搜 `quicklook` 找）。Xcode 的 `Debug ▸ Attach to Process` 也能挂上去 |
| 看日志 | `log stream --predicate 'subsystem == "你的 subsystem"'`（QLMarkdown 用的是 `OSLog(subsystem:category:"Quick Look Extension")`，见 `Log.swift:14`） |
| 确认文件的类型号 | `mdls -name kMDItemContentType -name kMDItemContentTypeTree 文件.md` |
| 确认扩展注册了没 | 见 5.3 节的命令数组 |
| 预览不刷新 | `qlmanage -r`，还不行 `killall Finder` |

---

## 5. 「怎么让它抢在 QLMarkdown 前面」/「怎么换回去」

先把话说死：**macOS 没有提供「为这个文件类型指定预览 App」的功能**，也没有公开 API 能让你的扩展「优先」。第三方关于这个的文档写得很直白（siriusmarkdown 的 QuickLook 文档）：

> Finder and QLPreviewView choose the provider. QLPreviewView has no public API for forcing a specific extension bundle identifier, and **other installed Markdown providers can affect which preview appears**.

所以能做的只有两件事：**① 把想要的打开、把别的关掉；② 调整面板里的顺序（这条我无法在本机证实，见下）**。

### 5.1 先搞清楚「谁在抢 .md」——你这台机器的实况

实测命令（可以自己再跑一遍）：

```sh
setopt nullglob
for p in /Applications/*/Contents/PlugIns/*.appex; do
  pid=$(/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionPointIdentifier" "$p/Contents/Info.plist" 2>/dev/null)
  [ "$pid" = "com.apple.quicklook.preview" ] || continue
  echo "== $(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$p/Contents/Info.plist" 2>/dev/null)"
  /usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionAttributes:QLSupportedContentTypes" "$p/Contents/Info.plist" 2>/dev/null | sed 's/^ *//'
done
```

结果（**你这台机器上，三个扩展都声明了 `net.daringfireball.markdown`**）：

| App | 扩展 bundle id | 声明了 md 吗 |
| --- | --- | --- |
| **QLMarkdown** | `org.sbarex.QLMarkdown.QLExtension` | ✅（17 个类型里含 `net.daringfireball.markdown`、`public.markdown`） |
| **Markra** | `dev.markra.app.quicklook` | ✅（只有两个：`net.daringfireball.markdown`、`public.markdown`） |
| **WPS Office** | `com.kingsoft.wpsoffice.mac.WPSQuickLook` | ✅（8 个类型，含 `net.daringfireball.markdown`） |

也就是说：**「按空格出来的不是 QLMarkdown」这件事完全可能发生，而且原因就在这张表里**。

### 5.2 三种切换办法

**办法 A：系统设置里开关（最稳，推荐）**

1. 打开 `系统设置 → 通用 → 登录项与扩展 → 快速查看`（点左下角那个 `ⓘ` 才展开列表）。
2. 列表里逐条试：**先只留你想要的那一个，其余全关**，去 Finder 按空格验证；然后再一个一个开回来，看是哪个把它抢走了。这套「二分法」是 QLMarkdown 官方 README 推荐的排障步骤（`README.md:463-464`）。

> 关于「顺序」：有第三方资料说这个列表的**排列顺序就是优先级、可以拖动**（把想用的拖到最上面）。
> ⚠️ **我没法在本机验证这一点**（这属于系统设置界面行为，我用不了图形界面）。你自己打开的瞬间就能看出来：如果能拖，就拖；拖不动，就退回用「只留一个」的办法。

**办法 B：命令行（可能被新版 macOS 限制）**

`pluginkit` 的 `election` 就是面板里那些开关的命令行版本，`man pluginkit` 写着三种取值：`use` / `ignore` / `default`。

```sh
# 关掉 QLMarkdown 的预览扩展（想换回别的 App 时用）
pluginkit -e ignore -i org.sbarex.QLMarkdown.QLExtension

# 想恢复
pluginkit -e use -i org.sbarex.QLMarkdown.QLExtension
```

⚠️ **实测提醒（macOS 26 上的坑）**：`pluginkit -m -p com.apple.quicklook.preview` 这条**查询**命令在你这台机器上直接失败，报

```
match: unauthorized discovery flag (PKDiscoverAll)
```

（关掉沙箱、用普通用户跑也一样报；看起来是 macOS 26 把无限制的插件枚举收紧了。）
`-e ignore` 我没敢实测（它会真的改扩展状态，不能拿你的环境做实验），但很可能同样受限。**所以查状态、改状态首选办法 A 的面板**。

**办法 C：直接卸载**

```sh
brew uninstall --cask qlmarkdown      # 或者干脆把 /Applications/QLMarkdown.app 拖进废纸篓
rm -rf ~/Library/Group\ Containers/group.org.sbarex.qlmarkdown   # 顺带清掉共享的配置/样式
```

（删 App 之后，`Contents/PlugIns/` 里的扩展跟着没了，系统就不会再把它当候选。再 `qlmanage -r` 一下更干净。）

### 5.3 `qlmanage` 现在还能干什么、不能干什么

这个老工具**大部分功能已经废了**，实测：

```sh
$ qlmanage -m plugins | wc -l
81                       # 全部都是 /System/Library/QuickLook/*.qlgenerator

$ qlmanage -m plugins | grep -i markdown
（没有任何输出）           # ← 第三方 App 扩展一个都看不到
```

| 命令 | 现在的作用 |
| --- | --- |
| `qlmanage -m plugins` | 只列 **Apple 自带的** qlgenerator。**看不到任何第三方 App 扩展**，所以「按类型查谁在管」这件事它已经做不到了 |
| `qlmanage -r` | 强制重建生成器列表（改完 Info.plist / 装完新扩展后基本必跑） |
| `qlmanage -r cache` | 清缩略图磁盘缓存（缩略图不对时用） |
| `qlmanage -p 文件` | 弹一个预览窗口。⚠️ 在**这台机器**上因为沙箱初始化失败跑不起来（`sandbox initialization failed: Operation not permitted`），要用就在普通终端里跑，别在受限环境里跑 |

> 「`qlmanage -m` 看不到第三方扩展」这事不是本机特例，Apple 到现在也没给替代工具 —— 这点在 Howard Oakley 的 QuickLook 分析文章里也写了。所以**想知道谁在抢某个类型，就用 5.1 那段脚本**。

---

## 6. 常见坑清单

| 症状 | 原因 | 怎么办 |
| --- | --- | --- |
| 装完按空格没反应，还是纯文本 | 扩展默认没启用 | 系统设置 → 通用 → 登录项与扩展 → 快速查看 → 打开 |
| 上面那个列表里压根找不到你的 App | 扩展没被系统发现 | 把 App 拖到废纸篓再拖回来（能强制重新注册），然后**打开一次 App**。QLMarkdown README 原话就是这么教的 |
| 列表里有、也开了，但出来的还是别的 App | 有别的扩展也在抢同一个 UTI | 5.1 的脚本列出所有声明 md 的扩展，关掉其它 |
| 只在某些机器上不生效 | 那台机器上 `.md` 类型号是动态 UTI（`dyn.ah62d4rv4ge8...`） | Info.plist 里把常见的动态 UTI 也声明上（QLMarkdown 声明了 7 个） |
| 预览里的本地图片全是裂图 | 扩展在沙箱里读不到别的目录 | 申请 `temporary-exception.files.absolute-path.read-only` |
| 改了 Info.plist 没反应 | 系统缓存着旧的生成器列表 | `qlmanage -r`（必要时再 `killall Finder`） |
| 双击 md 文件打开了 / 出现在「打开方式」里了 | 宿主 App 的 `LSHandlerRank` 不是 `None` | 想「只做预览、不做打开方式」，就照 QLMarkdown 设成 `None` |
| 扩展里 `import UIKit` 编译不过 | 扩展是 AppKit 平台 | 渲染逻辑抽成 Foundation-only（本项目优先看 `swift-markdown-engine`） |
| 链接依赖时报 `API ... is unavailable in application extensions` | 依赖用了 App 专用 API | 给依赖加 `-application-extension` / `-fapplication-extension` 编译标志 |

---

## 7. 本机实测记录（可复查）

```
① 装了 QLMarkdown 在哪、什么身份
   /Applications/QLMarkdown.app/Contents/PlugIns/Markdown QL Extension.appex
   CFBundleIdentifier        = org.sbarex.QLMarkdown.QLExtension
   NSExtensionPointIdentifier= com.apple.quicklook.preview
   NSExtensionPrincipalClass = Markdown_QL_Extension.PreviewViewController
   LSMinimumSystemVersion    = 11.0

② .md 的类型号
   mdls -name kMDItemContentType testcase/*.md
   → net.daringfireball.markdown
     （树：public.item → public.text → public.data → public.content → public.utf8-plain-text → net.daringfireball.markdown → public.plain-text）

③ 本机所有快速查看扩展：16 个（含 Bear / Markra / Menuist×3 / Parallels / QLMarkdown / QuickLook Video×2 / Safari /
   Suspicious Package / Ulysses / Whisky / Windows App / Xcode / WPS）

④ 其中声明了 markdown 的：3 个（QLMarkdown、Markra、WPS Office）

⑤ qlmanage：只用自带 qlgenerator（81 行），第三方扩展一个都看不见

⑥ 老式第三方 qlgenerator：2 个（坚果云、搜狗皮肤），Sequoia 之后已失效

⑦ 正在跑的相关进程：com.apple.quicklook.ThumbnailsAgent（缩略图代理）
```

---

## 8. 一页速查

```
想「用」空格键预览 md      → 装 QLMarkdown（brew install --cask qlmarkdown）+ 打开一次 App + 面板里开启
想「换」成别的预览器        → 系统设置 → 通用 → 登录项与扩展 → 快速查看 → 只留一个
想「自己写」一个            → Catalyst 工程 → **iOS 标签页**新建 Quick Look Preview Extension target
                              （纯 macOS 壳 App 才用 macOS 标签页；选错了 Embed 里找不到你的 App）
                              + 扩展 target 开 SUPPORTS_MACCATALYST
                              + Info.plist 写 QLSupportedContentTypes
                              + 实现 providePreview(for:) 回 HTML
                              + entitlements 开沙箱
                              + 嵌入 App.app/Contents/PlugIns + 打开 App + 面板开启 + qlmanage -r
想「查谁在抢」              → 5.1 节那段 PlistBuddy 循环（qlmanage 已经查不到了）
```

---

## 9. 参考

- 本仓库源码：`QLMarkdown/QLExtension/Info.plist`、`QLExtension/PreviewProvider.swift`、`QLMarkdown/Info.plist`、`QLExtension/QLExtension.entitlements`、`QLMarkdown/Settings+render.swift:865`（CSP）
- QLMarkdown README：`## Installation`（装完必须打开一次）、`## FAQ`（排障二分法、支持的 UTI 列表、`LSHandlerRank` 的说明）
- Apple 官方：[Quick Look](https://developer.apple.com/documentation/quicklook)（iOS/Catalyst/macOS 通吃的那套 API）、[Quick Look UI](https://developer.apple.com/documentation/quicklookui)（macOS 专属：`QLPreviewPanel`、`QLPreviewView`）、[QLPreviewingController](https://developer.apple.com/documentation/quicklook/qlpreviewingcontroller)（可用性一栏写着 **Mac Catalyst 13.0+**）
- SDK 头文件（本机）：`QuickLookUI.framework/Headers/QLPreviewReply.h`（能返回的格式清单）、`QLPreviewingController.h`（**iOS 版** Headers 里那份带 Catalyst 提示，是 4.1 节结论的直接依据）
- Xcode 模板（本机）：**iOS 版** `…/iPhoneOS.platform/…/iOS/Application Extension/Quick Look Preview Extension.xctemplate`（`Identifier = com.apple.dt.unit.quicklookios`）与 macOS 版 `…/MacOSX.platform/…/macOS/Application Extension/…`
- 系统里的扩展点定义（本机，`plutil -p` 可复查）：`/System/Library/Frameworks/QuickLookUI.framework/Resources/Info.plist`（`com.apple.quicklook.preview`，`RunLoopType = _NSApplicationMain`）、iOS 26 运行时 `QuickLook.framework/Info.plist`（同 ID，`QLPreviewExtensionServiceContext_iOS`，`_UIApplicationMain`）
- 背景阅读：Howard Oakley *How Sequoia has changed QuickLook and its thumbnails*（第三方 qlgenerator 被移除、`qlmanage -m` 已看不到 appex）
