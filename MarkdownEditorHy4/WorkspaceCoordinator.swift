//
//  WorkspaceCoordinator.swift
//  MarkdownEditorHy4
//
//  把整个 App 的根界面搭起来：左栏是「文档 / 最近打开」两个 Tab，右栏是多 Tab 的 markdown 编辑器。
//

import UIKit
import MultiTabController

/// 「整个工作区」的装配器。
///
/// ### 它只干一件事：按设备决定怎么拼装
/// 交给 `MultiTabController` 的 `RootBuilder` 分发：
///
/// - **iPhone** → 一个导航栈：左栏那个标签页容器当根，点文件 push 一页详情
///   （走 `PPPhoneContentRouter`）；
/// - **iPad / Mac** → `SplitContainerViewController`：左栏标签页容器 + 右栏多 Tab 详情宿主
///   （走 `PPSplitContentRouter`）。
///
/// ### 左栏为什么是「标签页容器」
/// 左栏现在装着两份列表：**文档**（磁盘目录里有什么）和**最近打开**（你打开过什么）。
/// 用 `PPTabBarController` 把它们并排放，切一下就能换 —— 两份列表各有各的用处，
/// 而且「最近」里那份可能早就不在目录里了，正该分开列。
///
/// ⚠️ **两个 Tab 里的列表都不要再各自包一层 `UINavigationController`**：
/// 外层本来就有导航控制器（iPhone 上是这里建的，iPad / Mac 上是 `SplitContainerViewController`
/// 内部替左栏建的 —— 见它注释里那句 `UINavigationController(rootViewController:)`）。
/// 再包一层就是「导航控制器里套导航控制器」，屏幕上会叠出**两条导航条**。
///
/// ### 为什么要有 `nonisolated deinit`
/// 见 `MarkdownBlock` / `OutlineCoordinator` 里那段长注释：本工程全局默认 `@MainActor`，
/// 非 UI 的 class 必须显式写一行 nonisolated 的 deinit，否则 Swift 6 运行时在特定释放时机
/// 会去 free 一个野指针直接崩。
final class WorkspaceCoordinator {

    /// 挂到窗口上的根控制器
    let rootViewController: UIViewController

    /// 左栏「文档」那一页。留成属性是为了让测试能直接拿到它
    let documentListViewController: DocumentListViewController

    /// 左栏「最近打开」那一页
    let recentDocumentsViewController: RecentDocumentsViewController

    /// 左栏那个标签页容器（装着上面两页）
    private let leftTabBar: PPTabBarController

    /// 左栏两页，下标和标签页的按钮一一对应
    private let leftTabs: [UIViewController]

    init() {
        // ⚠️ 这里先建成本地常量再捕获：初始化期间直接读 `self.documentListViewController`
        // 会踩 Swift 的「所有存储属性初始化完之前不能使用 self」规则
        let list = DocumentListViewController()
        documentListViewController = list

        let recent = RecentDocumentsViewController()
        recentDocumentsViewController = recent

        let tabs: [UIViewController] = [list, recent]
        leftTabs = tabs

        let tabBar = TabBarBuilder.build(
            viewControllers: tabs,
            items: [
                PPTabItem(title: "文档", image: UIImage(systemName: "doc.text")),
                PPTabItem(title: "最近", image: UIImage(systemName: "clock"))
            ]
        )
        // 库默认是白底 + 固定灰色，深色模式下会很扎眼，换成跟着系统走的那两套颜色
        tabBar.tabBarBackgroundColor = .systemBackground
        tabBar.unselectedTintColor = .secondaryLabel
        leftTabBar = tabBar

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
                recent.router = router
                return UINavigationController(rootViewController: tabBar)
            },
            iPadOrMacRoot: {
                // 分栏路由：列表发出的「打开」意图会被转到右侧详情宿主，
                // 由它按预览 / 正式那套策略决定复用还是新开
                let router = PPSplitContentRouter()
                list.router = router
                recent.router = router
                // ⚠️ 这里**只传标签页容器本身**，不要自己再包一层 UINavigationController：
                // 库的 `SplitContainerViewController.init` 内部已经替左栏包了一层，
                // 传进去一个导航控制器会变成「往导航栈里 push 导航控制器」，
                // 运行时报 `Pushing a navigation controller is not supported` 直接崩 ——
                // 而且崩在启动那一刻，编译期完全看不出来。
                return SplitContainerViewController(
                    leftViewController: tabBar,
                    router: router,
                    contentViewControllerProvider: makeContentViewController
                )
            }
        )

        // 到这一步所有属性才初始化完，这时候才能写捕获 self 的闭包
        tabBar.onSelectedIndexChanged = { [weak self] index in
            self?.syncNavigationItem(for: index)
        }
        // 初始那一页也要搬一次（切 Tab 的回调不会为「第一次」触发）
        syncNavigationItem(for: tabBar.selectedIndex)
    }

    nonisolated deinit {}

    // MARK: - 导航条

    /// 把当前那一页导航条上的按钮，搬到外层导航条上。
    ///
    /// ### 为什么要手动搬一次
    /// 外层那个导航控制器（iPhone 上这里建的、iPad / Mac 上库里建的）只认
    /// **它直接那个子控制器**的 `navigationItem` —— 也就是 `PPTabBarController` 自己的。
    /// 两个列表挂在标签页**里面**，它们各自的「+」「清空」按钮不会自己冒到导航条上。
    /// 所以切 Tab 的时候得把当前这一页的按钮搬上去。
    ///
    /// 这也是两个列表页把按钮配在 `init` 里、而不是 `viewDidLoad` 里的原因：
    /// 搬的时候它们的 view 可能还没加载。
    private func syncNavigationItem(for index: Int) {
        guard leftTabs.indices.contains(index) else { return }
        // 直接共用同一个按钮对象：它的可用状态（比如「清空」在没有记录时置灰）
        // 由列表页自己维护，两边看到的自然是同一个
        leftTabBar.navigationItem.rightBarButtonItem = leftTabs[index].navigationItem.rightBarButtonItem
    }
}
