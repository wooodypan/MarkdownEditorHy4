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
        self.window = window
        window.makeKeyAndVisible()

        // 冷启动：App 没在跑时用户双击 md 文件，URL 从这里进来。
        // 它只把 URL 存进 MarkdownDocumentOpener，等左栏那份文件列表出现之后
        // 自己去取、在新 Tab 里打开
        handleURLContexts(connectionOptions.urlContexts)
    }

    // MARK: 设置窗口（Mac 专用）

    #if targetEnvironment(macCatalyst)
    /// 给设置场景搭一扇独立小窗口。
    ///
    /// ### 根控制器为什么不是「导航控制器 + 设置页」
    /// 设置页右上角那个「完成」按钮是给模态弹窗用的（`dismiss` 只能关掉被 present 出来的页面），在独立窗口里它是够不着的。所以这里直接把设置页当根，关窗口交给标题栏左上角的红绿灯 —— 系统会顺手销毁这个场景，`sceneDidDisconnect` 里再把登记清掉。
    private func setUpSettingsWindow(windowScene: UIWindowScene) {
        // ### 尺寸
        // 给一个「小窗口」的合理范围：最小 480×520 —— 设置页里那些说明都是整段中文，再窄就挤成一根长条了；最大 800×1000 —— 再大就不像系统偏好设置那扇小窗口了。
        // 用区间而不是「最小=最大」的死尺寸：用户想拉大一点看长说明，不该被拦住。
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 480, height: 520)
        windowScene.sizeRestrictions?.maximumSize = CGSize(width: 800, height: 1000)
        windowScene.titlebar?.titleVisibility = .visible
        windowScene.title = "设置"

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = SettingsViewController()
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

