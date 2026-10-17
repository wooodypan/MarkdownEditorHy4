//
//  SettingsOpener.swift
//  MarkdownEditorHy4
//
//  「打开设置页」的唯一入口：Mac 上开独立窗口，iPhone / iPad 上模态弹出。
//

import UIKit

/// 「打开设置页」的唯一入口。
///
/// ### 为什么要有这么一个东西
/// 设置页有三个入口 —— 文档页「⋯」菜单里的「设置」、Mac 菜单栏的「设置…」(⌘,)、App 委托给 ⌘, 留的那份兜底 —— 而**怎么显示还分平台**：Mac 上是独立小窗口，iPhone / iPad 上还是模态弹出。这套分流只写一份，三个入口谁都不用关心自己跑在哪儿。
///
/// ### 平台怎么分
/// - **Mac**：`requestSceneSessionActivation` 拉一个新的 `UIWindowScene`，那个场景的生命周期归 `SceneDelegate` 管（尺寸、标题、根控制器都在那边配），关窗口靠标题栏左上角的红绿灯。
/// - **iPhone / iPad**：`present` 一个 `UINavigationController`，用导航栏上的「完成」关掉。
///
/// ### 设置页本身长什么样
/// 也是分平台的，但收在 `makeRootViewController(settings:)` 那一处：Mac 是左右分栏（侧边栏 + 面板），iPhone / iPad 是「目录列表 → push 面板」。这里只管「怎么看」，那边只管「看什么」，两边不互相打结。
///
/// ⚠️ Mac 那条路要求 Info.plist 里 `UIApplicationSupportsMultipleScenes` 为 `true`（本工程 2026-10-14 之前是 `false`，这次一并改过来了）—— 关着的话系统根本不会给第二个窗口，`requestSceneSessionActivation` 会**静默失败**（表现就是「按了 ⌘, 一点反应都没有」）。
enum SettingsOpener {

    /// 设置窗口的「身份证」：用一个 `NSUserActivity` 的 type 标记「这个场景是设置窗口」。
    ///
    /// 由 bundle id 拼出来而不是写死 —— 将来改 bundle id 不用回来改这里。
    static let activityType = (Bundle.main.bundleIdentifier ?? "MarkdownEditorHy4") + ".settings"

    /// 打开设置页。
    ///
    /// - Parameter host: **模态那条路**要从谁身上弹（Mac 上这个参数用不到）。不传就自己去当前活动窗口的根控制器找 —— App 委托那份兜底就是这么调的。
    static func open(from host: UIViewController? = nil) {
        #if targetEnvironment(macCatalyst)
        openAsWindow()
        #else
        presentAsModal(from: host ?? activeRootViewController)
        #endif
    }

    // MARK: - 搭页面

    /// 搭出「设置页」那棵树。两端长得不一样，这里是唯一的分流点。
    ///
    /// - Mac：`SettingsSplitViewController`（左边侧边栏 + 右边面板），直接当窗口的根控制器用。
    /// - iPhone / iPad：`UINavigationController` 包着 `SettingsListViewController`（目录），点一行 push 进面板。
    ///
    /// 调用方（设置窗口、模态弹出）只管拿一个 `UIViewController` 去用，不用关心自己在哪一端 —— 以后想再加一种呈现方式，也只改这一处。
    static func makeRootViewController(settings: MarkdownEditorSettings = .shared) -> UIViewController {
        #if targetEnvironment(macCatalyst)
        return SettingsSplitViewController(settings: settings)
        #else
        let navigation = UINavigationController(rootViewController: SettingsListViewController(settings: settings))
        // 大标题得挂在导航栏上才生效（页面自己那个 `largeTitleDisplayMode` 只管「这一页要不要用」）：
        // 目录那一屏用大标题，push 进去的面板自己会切成小标题
        navigation.navigationBar.prefersLargeTitles = true
        return navigation
        #endif
    }

    // MARK: - Mac：独立窗口

    #if targetEnvironment(macCatalyst)

    /// 已经开着的那扇设置窗口（弱引用：窗口关掉后系统会释放它，这里自动变 nil）。
    private static weak var settingsWindowScene: UIWindowScene?

    /// 这个新场景是不是「设置窗口」？`SceneDelegate` 靠它分流：是搭设置窗口，不是搭整个工作区。
    ///
    /// ### 两个判据缺一不可
    /// ① 创建场景时带进来的 `NSUserActivity` —— 用户点 ⌘, 新建窗口走这条；
    /// ② 系统恢复出来的场景带的恢复信息 —— App 重启后窗口自己回来走这条。
    static func isSettingsScene(session: UISceneSession, options: UIScene.ConnectionOptions) -> Bool {
        if options.userActivities.contains(where: { $0.activityType == activityType }) { return true }
        return session.stateRestorationActivity?.activityType == activityType
    }

    /// `SceneDelegate` 把设置窗口搭好之后登记一下 —— `openAsWindow()` 靠它判断「是不是已经开着了」。
    ///
    /// 为什么不靠 `session.stateRestorationActivity` 反查：那是「系统存的恢复信息」，不是每个窗口都一定有，判断「现在有没有设置窗口」不够可靠。自己记一份最实在。
    static func registerSettingsWindow(_ scene: UIWindowScene) {
        settingsWindowScene = scene
    }

    /// 设置窗口被关掉时注销（同样由 `SceneDelegate` 调）。
    static func unregisterSettingsWindow(_ scene: UIWindowScene) {
        // 只清自己那一扇 —— 别的场景断开时也会走到这里
        if settingsWindowScene === scene { settingsWindowScene = nil }
    }

    /// 拉一扇独立窗口出来。
    ///
    /// ### 已经开着就先不开了
    /// 用户按一次 ⌘,、去别处逛一圈回来再按一次 —— 这时该把**原来那扇窗口**调到前台。不拦的话按几次就叠出几扇一模一样的设置窗口，而且每扇都占一份内存。
    private static func openAsWindow() {
        if let scene = settingsWindowScene {
            UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil, errorHandler: nil)
            return
        }
        let activity = NSUserActivity(activityType: activityType)
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity, options: nil, errorHandler: nil)
    }

    #endif

    // MARK: - iPhone / iPad：模态弹出

    /// 模态弹出。
    ///
    /// 包一层 `UINavigationController`：目录页右上角那个「完成」要挂在导航栏上才正常，点进去的面板也要靠它做 push。
    ///
    /// 两个小细节：**从最上面那一层弹**（底下那层可能正被别的页面盖着，从被盖住的那层弹会被系统丢掉，表现就是「点了没反应」）；**已经弹着设置页就什么都不做**（不然连点两下会叠出两层，关掉上面那层底下还留一层，看着像「点了没关掉」）。
    private static func presentAsModal(from host: UIViewController?) {
        guard let host else { return }
        var top = host
        while let presented = top.presentedViewController { top = presented }

        // ⚠️ 认的是「栈底是不是目录页」—— 现在可能会停在某个面板上（用户点进了「大纲面板」还没返回），只认栈底那一层，才不会误判成「没弹着」又叠一份出来
        if let navigation = top as? UINavigationController,
           navigation.viewControllers.first is SettingsListViewController { return }

        top.present(makeRootViewController(), animated: true)
    }

    /// 当前活动窗口的根控制器（模态那条路得知道「从谁身上弹」）。
    private static var activeRootViewController: UIViewController? {
        UIApplication.shared.connectedScenes
            .filter { $0.activationState == .foregroundActive }
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController
    }
}
