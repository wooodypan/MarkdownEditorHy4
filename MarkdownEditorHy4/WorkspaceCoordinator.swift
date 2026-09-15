//
//  WorkspaceCoordinator.swift
//  MarkdownEditorHy4
//
//  把整个 App 的根界面搭起来：左栏是文档列表，右栏是多 Tab 的 markdown 编辑器。
//

import UIKit
import MultiTabController

/// 「整个工作区」的装配器。
///
/// ### 它只干一件事：按设备决定怎么拼装
/// 交给 `MultiTabController` 的 `RootBuilder` 分发：
///
/// - **iPhone** → 一个导航栈：左栏那份文档列表当根，点文件 push 一页详情
///   （走 `PPPhoneContentRouter`）；
/// - **iPad / Mac** → `SplitContainerViewController`：左栏文档列表 + 右栏多 Tab 详情宿主
///   （走 `PPSplitContentRouter`）。
///
/// 两个分支用的是**同一份** `DocumentListViewController` —— 列表只把「我想打开哪一份」
/// 报给 router，自己不关心到底是 push 还是开 Tab（这就是库那套 `PPContentRouting` 的意思）。
///
/// ### 为什么要有 `nonisolated deinit`
/// 见 `MarkdownBlock` / `OutlineCoordinator` 里那段长注释：本工程全局默认 `@MainActor`，
/// 非 UI 的 class 必须显式写一行 nonisolated 的 deinit，否则 Swift 6 运行时在特定释放时机
/// 会去 free 一个野指针直接崩。
final class WorkspaceCoordinator {

    /// 挂到窗口上的根控制器
    let rootViewController: UIViewController

    /// 左栏那份文档列表。留成属性是为了让测试能直接拿到它
    let documentListViewController: DocumentListViewController

    init() {
        // ⚠️ 这里先建成本地常量再捕获：初始化期间直接读 `self.documentListViewController`
        // 会踩 Swift 的「所有存储属性初始化完之前不能使用 self」规则
        let list = DocumentListViewController()
        documentListViewController = list

        // 内容页工厂：宿主每新开一个 Tab 就调一次，要返回一个**全新**的页面
        // （`PPContentViewControllerProvider` 就是 `() -> PPContentDisplaying`）
        let makeContentViewController: PPContentViewControllerProvider = {
            MarkdownDocumentViewController()
        }

        rootViewController = RootBuilder.makeRoot(
            iPhoneRoot: {
                // iPhone 上没有「预览槽位」这回事（它就是导航栈），
                // 所以路由直接把详情 push 上去
                let router = PPPhoneContentRouter(sourceViewController: list,
                                                  contentViewControllerProvider: makeContentViewController)
                list.router = router
                return UINavigationController(rootViewController: list)
            },
            iPadOrMacRoot: {
                // 分栏路由：列表发出的「打开」意图会被转到右侧详情宿主，
                // 由它按预览 / 正式那套策略决定复用还是新开
                let router = PPSplitContentRouter()
                list.router = router
                // ⚠️ 这里**只传列表本身**，不要自己再包一层 UINavigationController：
                // 库的 `SplitContainerViewController.init` 内部已经替左栏包了一层
                // （见它注释里那句 `self.leftNavigationController = UINavigationController(...)`），
                // 传进去一个导航控制器会变成「往导航栈里 push 导航控制器」，
                // 运行时报 `Pushing a navigation controller is not supported` 直接崩 ——
                // 而且崩在启动那一刻，编译期完全看不出来。
                return SplitContainerViewController(
                    leftViewController: list,
                    router: router,
                    contentViewControllerProvider: makeContentViewController
                )
            }
        )
    }

    nonisolated deinit {}
}
