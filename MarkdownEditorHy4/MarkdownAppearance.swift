//
//  MarkdownAppearance.swift
//  MarkdownEditorHy4
//
//  App 的「外观模式」：跟随系统 / 浅色 / 深色。
//
//  ### 为什么改窗口，而不是逐个页面改
//  窗口是系统外观的源头：在窗口上设一次 `overrideUserInterfaceStyle`，它下面整棵视图树（包括之后 push / present 出来的页面）都会按新的明暗重新解析颜色。逐个页面改得遍历视图树、还要管新出现的页面，漏一个地方就是「这一页变黑、上一页还是白的」。
//
//  ### 和「配色主题」是什么关系
//  这里是系统外观，管的是导航栏、列表、设置页这些系统控件用浅色还是深色；「配色主题」（默认 / Vue / Vue Dark / 自定义）管的是正文那一套颜色。
//  两者默认联动：外观是深色、配色又是「默认」时，正文自动换成内置的深色默认配色（见 `MarkdownEditorSettings.palette(base:merging:)`）—— 不然深灰字铺在黑底上根本看不清。
//  用户自己选过 Vue / Vue Dark / 自定义配色时，以他的选择为准：那是显式指定的，不该被外观扭掉。
//

import UIKit

/// 外观模式。三个选项，和设置页里那一行一一对应。
enum MarkdownAppearanceMode: String, Codable, CaseIterable {

    /// 跟着系统的「外观」设置走（默认）
    case system

    /// 强制浅色，不管系统开的是什么
    case light

    /// 强制深色
    case dark

    /// 设置页菜单上显示的名字
    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色模式"
        case .dark: return "深色模式"
        }
    }

    /// 翻译成 UIKit 用的样式。`.unspecified` 就是「不覆盖，跟着系统」
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 把外观模式套到所有窗口上。
///
/// ### 为什么做成一组静态方法，而不是一个单例对象
/// 它没有任何状态要维护 —— 真正的状态（用户选了哪一档）存在 `MarkdownEditorSettings` 里，这里只记一份「当前生效的是哪档」。
/// 用法只有三处：启动时 `install()`、切换时 `setMode(_:)`、新窗口出现时 `apply(to:)`。
enum MarkdownAppearance {

    /// 当前生效的模式。
    ///
    /// 只由 `install()` 和 `setMode(_:)` 改；别处一律读它。
    /// 它和 `MarkdownEditorSettings.appearanceMode` 是同一个值，分开存是为了「启动时读配置」这一步只做一次。
    private(set) static var mode: MarkdownAppearanceMode = .system

    /// 现在是不是深色。
    ///
    /// 渲染层要用它决定「默认配色该用浅色版还是深色版」。
    ///
    /// ### 为什么不直接读 `UITraitCollection.current`
    /// 渲染发生在 `setMarkdown` / 整篇重排里，不是绘制回调，这时候 `UITraitCollection.current` 往往是「未指定」，会被当成浅色。
    /// 退回前台窗口的 trait 才拿得到真实外观（`MermaidKitRenderer.appearanceTraits` 那处也是这么处理的）。
    static var isDark: Bool {
        switch mode {
        case .dark: return true
        case .light: return false
        case .system: return windowIsDark
        }
    }

    /// 启动时调一次：读回上次的选择，套到已经存在的窗口上，再挂上「配置变了自动套」的监听。
    ///
    /// ⚠️ 调用点要在建窗口之前（`AppDelegate.didFinishLaunching`）：那时还没有窗口，`applyToAllWindows()` 什么都不会做，但模式已经记下来了，`SceneDelegate` 建好窗口后会补一次 `apply(to:)`。
    static func install(settings: MarkdownEditorSettings = .shared) {
        mode = settings.appearanceMode
        applyToAllWindows()

        // 配置一变就把窗口重套一遍。切换外观那条主路（`setMode`）自己会套，这里是兜底：
        // 以后要是加了「恢复默认设置」这类一次改多项的入口，窗口也能跟上，不用记得回来补一行
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: MarkdownEditorSettings.didChangeNotification,
            object: settings,
            queue: .main
        ) { _ in
            applyToAllWindows()
        }
    }

    /// 切换外观：先套窗口，再把选择存进配置。
    ///
    /// ### 顺序为什么不能反
    /// 写配置会同步广播，打开的文档收到通知立刻整篇重渲染。重渲染时要读 `isDark` 决定用浅色还是深色配色 ——
    /// 如果窗口还没套上，它读到的还是旧外观，出来的就是一屏浅色字贴在深色底上。所以窗口必须先改。
    static func setMode(_ newMode: MarkdownAppearanceMode, settings: MarkdownEditorSettings = .shared) {
        mode = newMode
        applyToAllWindows()
        settings.setAppearanceMode(newMode)
    }

    /// 套到某一个窗口上。自己新建窗口（比如 Mac 的设置窗口）时补这一次。
    static func apply(to window: UIWindow) {
        window.overrideUserInterfaceStyle = mode.interfaceStyle
    }

    /// 套到所有窗口上。
    ///
    /// 遍历的是「所有场景的所有窗口」：Mac 上工作区和设置窗口是两个场景，只改 key window 的话另一扇会留在旧外观里。
    static func applyToAllWindows() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                apply(to: window)
            }
        }
    }

    // MARK: 内部

    /// 配置通知的观察者。App 活多久它就在多久，不用移除
    private static var observer: NSObjectProtocol?

    /// 系统当前是不是深色：读前台窗口的 trait（那里才带着 override 之后的结果）
    private static var windowIsDark: Bool {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            let window = windowScene.windows.first(where: \.isKeyWindow) ?? windowScene.windows.first
            if let window {
                return window.traitCollection.userInterfaceStyle == .dark
            }
        }
        // 一个窗口都没有（启动极早期、单测环境）：按浅色算，和系统默认一致
        return false
    }
}
