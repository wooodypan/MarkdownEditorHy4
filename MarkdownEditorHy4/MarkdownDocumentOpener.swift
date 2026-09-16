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

    /// 已经申请到「安全作用域」授权的外部文件。
    ///
    /// ### 为什么是一批，不是「只记最后一个」
    /// 沙盒没开的时候，这个集合写什么都无所谓 —— 反正整个硬盘都能读写。
    /// 开了沙盒就不一样了：右侧可以同时开着好几份**容器外**的文档（⌘O 挑的、
    /// Finder 双击进来的），每一份都得留着它自己那张通行证。
    /// 只记最后一个的话，用户回头在**较早打开**那份上按 ⌘S 就会写不进去。
    ///
    /// 授权用过要配对释放，否则系统会一直替这个文件开着口子。这里统一在
    /// `stopAccessing()` 里还（退出时调用）。
    private var accessedURLs: Set<URL> = []

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
        for url in accessedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        accessedURLs.removeAll()
    }

    // MARK: - 安全作用域

    private func beginAccessing(_ url: URL) {
        // 同一个文件申请过就别再申请一次 —— 申请两次要还两次，很容易记漏一半
        guard !accessedURLs.contains(url) else { return }

        // 返回 false 不代表「没戏」：
        //   - 从 Finder 双击进来的文件，系统在启动时就把权限给足了，这里本来就会返回 false；
        //   - 真拿不到权限的话，后面读文件就会失败，用户会看到「打不开文件」的提示。
        if url.startAccessingSecurityScopedResource() {
            accessedURLs.insert(url)
        }
    }
}
