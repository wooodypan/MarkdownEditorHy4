//
//  AppDelegate.swift
//  MarkdownEditorHy4
//
//  Created by pan on 2026/8/31.
//

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {



    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 兜底：个别系统版本冷启动时只把文件 URL 放在 launchOptions 里，不派发给 scene
        if let url = launchOptions?[.url] as? URL {
            MarkdownDocumentOpener.shared.handle(url: url)
        }
        return true
    }

    // MARK: 从 Finder 打开 .md 文件

    /// 兜底路径：SceneDelegate 没实现 openURLContexts 时，系统会走这里。
    /// 两条路不会同时被调用（UIKit 优先派发给 scene），所以不会重复打开。
    func application(_ app: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        MarkdownDocumentOpener.shared.handle(url: url)
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }


}

