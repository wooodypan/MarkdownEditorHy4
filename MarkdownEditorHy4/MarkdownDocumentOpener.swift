//
//  MarkdownDocumentOpener.swift
//  MarkdownEditorHy4
//
//  Finder「打开方式」/ 双击 / 拖到 Dock 图标 进来的 .md 文件，都先落到这里，
//  再由 ViewController 取走显示。
//
//  ### 为什么要单独存一份 pendingURL
//  冷启动时（App 没在跑，用户双击 md）系统先回调 SceneDelegate，此时界面还没建好、
//  通知也没人监听。所以先把 URL 存起来，等 ViewController 的 viewDidLoad 主动来取；
//  热启动时（App 已经在跑）界面早就有了，直接发通知即可。
//

import UIKit

extension Notification.Name {
    /// 有新的 .md 文件要打开（object 是文件 URL）
    static let markdownDocumentOpenRequested = Notification.Name("MarkdownDocumentOpenRequested")
}

final class MarkdownDocumentOpener {

    static let shared = MarkdownDocumentOpener()

    /// 界面还没起来时先攒着的 URL，被取走后清空
    private(set) var pendingURL: URL?

    private init() {}

    // MARK: - 入口

    /// 收到一个文件 URL。scene 和 AppDelegate 两条路径都会走到这里。
    func handle(url: URL) {
        guard url.isFileURL else { return }

        // ⚠️ `.json` 不是文档，是主题文件：交给主题那边收走，别再往下当 .md 打开。
        // 不拦的话双击一份主题 JSON 会在编辑器里开出一页「#ff0000」这种鬼东西，而且一按 ⌘S 就会把那份主题文件覆盖成它的源码。
        if MarkdownThemeFileImport.isThemeFile(url) {
            MarkdownThemeOpener.shared.handle(url: url)
            return
        }

        // 打开面板 / Finder 递过来的是「安全作用域」URL。先把访问权拿到手，
        // Mac 上还会顺手存一份书签，下次从「最近」打开就不用再问用户了。
        // ⚠️ 申请权限要在**原始 URL**上做（通行证附在它身上），存路径时才换成规范化路径。
        _ = ExternalDocumentAccess.shared.readableURL(for: url)
        let canonical = ExternalDocumentAccess.shared.canonicalURL(for: url)

        pendingURL = canonical
        NotificationCenter.default.post(name: .markdownDocumentOpenRequested, object: canonical)
    }

    /// ViewController 就绪后调用：取走冷启动时攒下的 URL
    func takePendingURL() -> URL? {
        defer { pendingURL = nil }
        return pendingURL
    }

    /// 退出时释放这一轮申请到的所有安全作用域。
    ///
    /// 具体申请 / 释放都归 `ExternalDocumentAccess` 管 —— 编辑页保存时也要靠它
    /// 重新拿到书签里的权限，放在一处才不会两边各记一套。
    func stopAccessing() {
        ExternalDocumentAccess.shared.stopAccessingAll()
    }
}
