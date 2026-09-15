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

