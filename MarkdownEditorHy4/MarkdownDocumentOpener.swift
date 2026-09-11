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

    /// 当前正在访问的安全作用域 URL（用过必须配对释放，否则系统会一直留着授权）
    private var accessedURL: URL?

    private init() {}

    // MARK: - 入口

    /// 收到一个文件 URL。scene 和 AppDelegate 两条路径都会走到这里。
    func handle(url: URL) {
        guard url.isFileURL else { return }

        // Finder 传过来的是「安全作用域」URL：不显式申请访问就读不到内容。
        // 没沙盒时这个调用会返回 false，直接读文件也没问题，不影响。
        beginAccessing(url)

        pendingURL = url
        NotificationCenter.default.post(name: .markdownDocumentOpenRequested, object: url)
    }

    /// ViewController 就绪后调用：取走冷启动时攒下的 URL
    func takePendingURL() -> URL? {
        defer { pendingURL = nil }
        return pendingURL
    }

    /// 退出 / 关窗口时释放授权
    func stopAccessing() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    // MARK: - 安全作用域

    private func beginAccessing(_ url: URL) {
        // 换文件了：先把上一个的授权还回去
        if let previous = accessedURL, previous != url {
            previous.stopAccessingSecurityScopedResource()
            accessedURL = nil
        }
        guard accessedURL == nil else { return }

        if url.startAccessingSecurityScopedResource() {
            accessedURL = url
        }
    }
}
