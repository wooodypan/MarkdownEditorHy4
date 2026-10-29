//
//  SceneDelegate.swift
//  MarkdownEditorHy4
//
//  Created by pan on 2026/8/31.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    /// 整个工作区（左栏文档列表 + 右栏多 Tab 编辑器）的装配器。
    ///
    /// 由场景持有而不是让某个控制器持有：它搭出来的那棵树（分栏容器 / 导航栈）
    /// 才是窗口的根，让它跟着场景一起活着最自然
    private var workspace: WorkspaceCoordinator?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // ### 先分流：这是「设置窗口」还是主窗口
        // Mac 上点了 ⌘,（或「⋯」菜单里的「设置」）时，`SettingsOpener` 会向系统申请一个新场景 —— 它也是本 App 的一个场景，照样走到这个回调里来。
        // 不先分出去的话，它会照下面的流程搭出一整个工作区（左栏 + 多 Tab 编辑器），那扇窗口就不是设置页了。
        #if targetEnvironment(macCatalyst)
        if SettingsOpener.isSettingsScene(session: session, options: connectionOptions) {
            setUpSettingsWindow(windowScene: windowScene)
            return
        }
        #endif

        // ### 界面全部走代码搭，不再有 Main.storyboard
        // 工程里给 scene 的配置（Info.plist 的 UISceneStoryboardFile）也去掉了，
        // 系统不会再替我们造窗口 —— 所以下面这三行必须自己写。
        //
        // 顺带一提：不做 storyboard 也少一个坑 —— storyboard 里那个自定义类
        // 写的是旧名字 ViewController，改名之后它会变成「不认识的类」，
        // 只在控制台留一句警告、界面却是空的，很难查。
        let workspace = WorkspaceCoordinator()
        self.workspace = workspace

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = workspace.rootViewController
        // 套上用户在设置里选的外观（跟随系统 / 深色 / 浅色）。
        // 必须赶在 `makeKeyAndVisible()` 前面：不然窗口会先按系统外观露一下脸，再被改成用户选的那种，冷启动能看见闪一下
        MarkdownAppearance.apply(to: window)
        self.window = window
        window.makeKeyAndVisible()

        // Tab 条那套颜色是按「正文底色 + 当前是深色还是浅色」算出来的，而深浅要等窗口挂到场景上才定得下来。
        // 装配器在 init 里已经算过一次（那时还没窗口，一律按浅色算），这里补算一次 —— 不然深色模式冷启动时，Tab 条会停在浅色那一套上，跟正文对不上。
        workspace.applyTabBarStyle()

        // 冷启动：App 没在跑时用户双击 md 文件，URL 从这里进来。
        // 它只把 URL 存进 MarkdownDocumentOpener，等左栏那份文件列表出现之后
        // 自己去取、在新 Tab 里打开
        handleURLContexts(connectionOptions.urlContexts)
    }

    // MARK: 设置窗口（Mac 专用）

    #if targetEnvironment(macCatalyst)
    /// 给设置场景搭一扇独立小窗口。
    ///
    /// ### 根控制器是「分栏」，不是导航栈
    /// 走 `SettingsOpener.makeRootViewController()`：Mac 上拿到的是 `SettingsSplitViewController`（左边侧边栏、右边面板），它直接当窗口的根，不套 `UINavigationController` —— 窗口自己已经有标题栏了，再来一根导航栏就是两个头。
    ///
    /// ### 那「完成」按钮呢
    /// 没有了，也不需要：那个按钮是给模态弹窗用的（`dismiss` 只能关掉被 present 出来的页面），在独立窗口里够不着。
    /// 关窗口交给标题栏左上角的红绿灯 —— 系统会顺手销毁这个场景，`sceneDidDisconnect` 里再把登记清掉。
    private func setUpSettingsWindow(windowScene: UIWindowScene) {
        // ### 尺寸
        // 最小 640×520：这一页是**左右分栏**的，侧边栏要 180~260 点宽，再减去面板里的留白，640 是「侧边栏 + 一列带滑块的设置行」都还看得清楚的下限 —— 比这窄就该去用 iPhone 那块列表了。
        // 最大 900×1000：再大就不像系统偏好设置那扇小窗口了。
        // 用区间而不是「最小=最大」的死尺寸：用户想拉大一点看长说明，不该被拦住。
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 640, height: 520)
        windowScene.sizeRestrictions?.maximumSize = CGSize(width: 900, height: 1000)
        windowScene.titlebar?.titleVisibility = .visible
        windowScene.title = "设置"

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = SettingsOpener.makeRootViewController()
        // 设置窗口是第二个场景，外观得单独套一次：`applyToAllWindows` 只在切换那一刻遍历当时的窗口，
        // 这扇是之后才开的，不补这一下就会留在系统外观里（工作区是深色、设置窗口还是白的）
        MarkdownAppearance.apply(to: window)
        self.window = window
        window.makeKeyAndVisible()

        // 登记一下：再按 ⌘, 时该「把这扇窗口调到前台」而不是再开一扇
        SettingsOpener.registerSettingsWindow(windowScene)
    }
    #endif

    // MARK: 从 Finder 打开 .md 文件

    /// 热启动：App 已经在跑，用户再双击 md 文件（或把文件拖到 Dock 图标上）
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        handleURLContexts(URLContexts)
    }

    private func handleURLContexts(_ contexts: Set<UIOpenURLContext>) {
        for context in contexts {
            MarkdownDocumentOpener.shared.handle(url: context.url)
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
        // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).

        // 设置窗口被关掉（标题栏左上的红绿灯）时把登记清掉 —— 不清的话再按 ⌘, 会去激活一个已经没了的场景，等于按了没反应。
        // 传进去的那个场景不一定是设置窗口（别的工作区窗口断开也会走到这儿），所以 `unregisterSettingsWindow` 里只认自己那一扇。
        // ⚠️ 整段要包 `#if`：登记这一套只有 Mac 才有（iPhone / iPad 上设置页是模态弹的，压根没有设置场景），不包的话 iOS 编译直接报「no member 'unregisterSettingsWindow'」。
        #if targetEnvironment(macCatalyst)
        if let windowScene = scene as? UIWindowScene {
            SettingsOpener.unregisterSettingsWindow(windowScene)
        }
        #endif
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Called when the scene has moved from an inactive state to an active state.
        // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
    }


}

