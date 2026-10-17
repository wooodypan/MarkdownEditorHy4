//
//  MermaidKitRenderer.swift
//  MarkdownEditorHy4
//
//  用 MermaidKit 把 Mermaid 源码画成一张图（App 层的实现，注入给编辑器组件）
//
//  ### 这个文件为什么要放在 **App 层**
//  `MarkdownEditor` 是要单独开源给别人用的库。MermaidKit 是本项目 App 选的图表引擎，不该变成开源库的强制依赖 —— 所以库里只有 `MarkdownMermaidRenderer` 协议，真正的 MermaidKit 代码放在这里，由 App 注入进去。
//  结果：`MarkdownEditor/` 下一个 `import MermaidRender` 都没有，开源出去是干净的依赖图。
//
//  ### 为什么用 `MermaidRenderer.image` 而不是 SwiftUI 的 `MermaidView`
//  编辑器那边要求图最终是一张 `UIImage`（理由见 `MermaidAttachment` 的注释：
//  TextKit 2 的 view provider 在整篇替换之后会漏掉 `loadView()`）。
//

import UIKit
import MermaidRender

/// MermaidKit 版的图表渲染器。
///
/// 用法：在编辑器建好之后塞给它，一行就装上了：
/// `editor.renderer.mermaidRenderer = MermaidKitRenderer.shared`
final class MermaidKitRenderer: MarkdownMermaidRenderer {

    /// 全局共用一个：渲染结果的缓存是跨文档复用的（换主题、拖字号时源码没变，全靠它命中）
    static let shared = MermaidKitRenderer()

    /// 渲染结果缓存。
    ///
    /// ### 为什么必须缓存
    /// 每画一张图都要跑一遍「解析 + 布局 + 离屏绘制」。单张不慢（上游 README 说大多数图 15 毫秒内、最坏的 sankey 约 25 毫秒），但**整篇重排是高频事件**：一篇十几个图的文档，每次重排都会把同样的十几段源码问一遍，没缓存会明显卡。
    ///
    /// ⚠️ 命中条件要看清：缓存键是 **源码 + 可用宽度 + 整套配色与明暗档**，所以「改宽度」「换主题」「拖字号滑块」这三条路都是**不命中**的（前两个该重画，字号那条见请求里 `fontSize` 的说明 —— 引擎其实用不上它，白换一次）。
    /// 真正靠它兜住的是**源码、宽度、配色都没变、只是重新排了一遍**的那些趟：编辑别处后的重渲染、折叠展开、查找高亮、导出、重新加载同一篇。
    ///
    /// 上限比公式那边（200）小：图比公式大得多，100 张够一篇长文来回切了。
    private let cache = NSCache<NSString, UIImage>()

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释：
    /// 隔离 deinit 一旦嵌套就会踩 Swift 6.2 运行时的野指针 free。
    nonisolated deinit {}

    private init() {
        cache.countLimit = 100
    }

    /// 画一张 Mermaid 图。
    /// - returns: 画好的图；**语法有误 / 引擎不认识这种图时返回 `nil`**（调用方会退化成显示源码原文）
    func image(for request: MarkdownMermaidRequest) -> UIImage? {
        let theme = Self.diagramTheme(for: request)
        let key = cacheKey(source: request.source, maxWidth: request.maxWidth, theme: theme)
        if let cached = cache.object(forKey: key) { return cached }

        // MermaidKit 是同步渲染（和 SwiftMath 一个量级），这个耗时放在渲染紧循环里可以接受。
        // 真遇到一篇塞了十几个大图的文档卡顿时，再考虑改成「先显示源码、图好了再替换」的异步路 —— 但不要一开始就上异步，那会引入闪烁，公式那条同步路稳得多。
        guard let image = MermaidRenderer.image(source: request.source, theme: theme) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }

    /// 画一张 Mermaid 图的 **SVG**（导出 HTML 用）。
    ///
    /// 和位图那条路共用主题换算。**刻意不缓存**：导出是点一次才做一次的操作，而这个返回值是几十 KB 的字符串 —— 塞进给渲染紧循环准备的 `NSCache` 不划算。
    func svg(for request: MarkdownMermaidRequest) -> String? {
        MermaidRenderer.svg(source: request.source, theme: Self.diagramTheme(for: request))
    }

    /// 把库层给的主题颜色翻译成引擎的外观。
    ///
    /// ### 为什么是翻译，而不是一个「是不是深色」的布尔
    /// 引擎的主题是一个**七槽位调色板**（墨色 / 两级弱化文字 / 画布 / 强调 / 细线 / 分类色带），编辑器主题手上的颜色是另一套名字 —— 两边对不上，中间必须有人做这道翻译。
    /// 全交给内置预设 `DiagramTheme(prefersDark:)` 省事得多，但结果很怪：图会固执地用引擎自己的近黑 / 近白墨色和系统蓝，用户把文档配成米色 + 棕色字，图还是白底黑字那一套，像是从别的文档里贴过来的。
    ///
    /// ### 一个槽位刻意不映射：`palette`
    /// 那六个分类色（饼图扇区、甘特条、git 分支用的）是为「同一张图里彼此可区分」调出来的，编辑器主题里压根没有对应概念 —— 硬凑一组只会更难看，所以留引擎默认。
    ///
    /// ### `prefersDark` 为什么还是要给
    /// 它不只用来挑颜色，引擎内部还有一批「深色下换个画法」的取舍（对比度、着色强度）跟着它走。
    /// 判据用**背景色的亮度**，而不是去问系统外观：用户完全可以给浅色机身配一套深色文档配色，该由文档配色说了算。
    private static func diagramTheme(for request: MarkdownMermaidRequest) -> DiagramTheme {
        let traits = appearanceTraits
        let background = request.backgroundColor.resolvedColor(with: traits)
        let text = request.textColor.resolvedColor(with: traits)
        return DiagramTheme(
            ink: text,
            // 两级弱化文字照引擎内置预设的 55% / 38% 档位摊下去，视觉层级才和别的图一致
            secondaryTextColor: text.withAlphaComponent(0.55),
            tertiaryTextColor: text.withAlphaComponent(0.38),
            // 画布给**页面真实背景色**：箭头、边标签那些「挖洞」的地方按它填，米色 / 深色主题上才不会露出一块块白斑
            canvas: background,
            accent: request.accentColor.resolvedColor(with: traits),
            hairline: request.separatorColor.resolvedColor(with: traits),
            prefersDark: background.isDarkForDiagram)
    }

    // MARK: 缓存键

    /// 一张图的唯一标识：源码 + 可用宽度 + **整套配色与明暗档**。
    ///
    /// ⚠️ 配色那一截直接用引擎算好的 `DiagramTheme.fingerprint`，不要自己挑几个颜色拼字符串。
    /// 那是引擎把七个槽位（含分类色带）连同明暗档一起算出来的摘要，动态色还按与绘制同一套外观解析过。
    /// 自己拼最容易漏：回头主题多塞一个颜色进请求，这里忘了加，症状就是「换了主题图还是旧配色」，而且只在某两份主题之间才复现，很难查。
    private func cacheKey(source: String, maxWidth: CGFloat, theme: DiagramTheme) -> NSString {
        "\(source)|\(Int(maxWidth))|\(theme.fingerprint)" as NSString
    }

    // MARK: 外观

    /// 当下该按哪套外观解析动态色。
    ///
    /// ### 为什么不能直接用 `UITraitCollection.current`
    /// 渲染发生在 `setMarkdown` / 整篇重排里，**不是绘制回调** —— 这个时候 `UITraitCollection.current` 是「未指定」，动态色会被按浅色解析。
    /// 于是系统开着深色时，我们会画一张浅色图贴到深色底上。退回前台窗口的 trait 才拿得到真实外观。
    ///
    /// 反过来，如果调用发生在 `draw(_:)` / `layoutSubviews` 里， `UITraitCollection.current` 本来就是对的，那一路直接返回，不会多问窗口。
    private static var appearanceTraits: UITraitCollection {
        let current = UITraitCollection.current
        guard current.userInterfaceStyle == .unspecified else { return current }

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            let window = windowScene.windows.first(where: \.isKeyWindow) ?? windowScene.windows.first
            if let window { return window.traitCollection }
        }
        return current
    }
}

// MARK: - 背景深浅

private extension UIColor {

    /// 这个颜色算不算「深色」：按相对亮度，低于 0.5 就算。
    ///
    /// ### 为什么不用 `getWhite`
    /// `getWhite` 只对灰度色有意义。一条深蓝 / 深绿的背景会被它算成「不深」，于是图还是画成浅色主题，压在深底上看不清。亮度用和 WCAG 同一套系数。
    ///
    /// 放在 App 层而不是库层 —— `MarkdownTheme` 里压根没有「深色」这个概念，库层不该为了接一个引擎而凭空长出一个字段来。
    var isDarkForDiagram: Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return 0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.5
        }
        // 取不到 RGB 分量（灰度空间的颜色）：退回按亮度判
        var white: CGFloat = 0
        if getWhite(&white, alpha: &alpha) { return white < 0.5 }
        // 两种都拿不到（比如图案色）：当浅色处理，退化成引擎自带的浅色主题，也比画不出来强
        return false
    }
}
