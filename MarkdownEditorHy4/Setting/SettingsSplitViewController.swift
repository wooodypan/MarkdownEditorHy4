//
//  SettingsSplitViewController.swift
//  MarkdownEditorHy4
//
//  设置页的 Mac 版：左边一列侧边栏列分组，右边是选中那一组的面板 —— 照系统偏好设置的样子。
//
//  ⚠️ 整个文件包在 `#if targetEnvironment(macCatalyst)` 里，两个原因：
//  ① `primaryBackgroundStyle` 这些接口只有 Catalyst 才有，iPhone / iPad 编不过；
//  ② 那一边压根用不上这个类（走的是 `SettingsListViewController` 那条「列表 + push」的路）。
//  包起来之后，iOS 那份二进制里不会有这两个类。
//

#if targetEnvironment(macCatalyst)

import UIKit

/// Mac 设置窗口的根控制器：分栏（侧边栏 + 面板）。
///
/// ### 为什么不是「导航栈 + 列表」
/// 那套在手机上合适（一屏只放得下一件事，推下一页很自然），在窗口够宽的 Mac 上就亏了：
/// 看一行说明、回去、再看一行说明 —— 每次都要点一次返回。分栏把「有哪些分组」一直摆在左边，换分组只点一下，右边当场就换，跟系统偏好设置一个手感。
final class SettingsSplitViewController: UISplitViewController {

    /// 读 / 写这份配置，转交给面板
    private let settings: MarkdownEditorSettings

    /// 侧边栏里的分组，顺序就是 `SettingsSection` 里声明的顺序
    private let sections = SettingsSection.allCases

    init(settings: MarkdownEditorSettings = .shared) {
        self.settings = settings
        super.init(style: .doubleColumn)
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsSplitViewController 不支持从 coder 解档")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // 侧边栏常驻显示：系统偏好设置里左边那列永远在，不会因为选了某一项就缩起来
        preferredDisplayMode = .oneBesideSecondary
        // 两栏并排铺开，而不是「侧边栏浮在内容上面」那种覆盖式
        preferredSplitBehavior = .tile
        // 侧边栏用系统材质，和大窗口里别处的侧边栏一个观感
        primaryBackgroundStyle = .sidebar
        // 侧边栏宽度：我们的分组名都是四个字，180 就够；上限 260 是因为再宽就白白吃掉面板里滑块的宽度。
        // 给区间而不是死宽度，用户想拉宽一点看长名字也不该被拦住
        preferredPrimaryColumnWidth = 200
        minimumPrimaryColumnWidth = 180
        maximumPrimaryColumnWidth = 260

        let sidebar = SettingsSidebarViewController(sections: sections) { [weak self] section in
            self?.showPane(for: section)
        }
        // ⚠️ 这里刻意不套 `UINavigationController`：
        // 设置窗口自己已经有一根标题栏（`SceneDelegate.setUpSettingsWindow` 里配的），再套一层导航栏就是「标题栏 + 导航栏」两个头，白白占掉一条。
        // 侧边栏这半边的标题本来就是窗口标题「设置」，不需要导航栏再写一遍
        setViewController(sidebar, for: .primary)

        // 一进来就选中第一条、右边显示它的面板 —— 空着一块白板，用户会以为没加载出来
        if let first = sections.first {
            showPane(for: first)
            sidebar.select(first)
        }
    }

    /// 换右边那块面板。
    ///
    /// 每次重新造一块（而不是缓存起来复用）：造一块很便宜（一张表、几行控件），而且顺带保证「切回来的时候显示的一定是当前配置」—— 不用去操心缓存的那些面板有没有过期。
    private func showPane(for section: SettingsSection) {
        let pane = SettingsPaneViewController(section: section, settings: settings)
        setViewController(pane, for: .secondary)
    }
}

/// 侧边栏：七个分组一行一个，选中的那一行高亮。
///
/// ### 为什么用 `UICollectionView` 的 sidebar 样式，而不是 `UITableView`
/// `.sidebar` 是系统专门为侧边栏准备的外观：行的圆角、选中的填充色、图标和文字的对齐、左右留白……
/// 全是现成的，画出来就是系统偏好设置那个样子。用 `UITableView` 得自己一项项凑，还凑不像。
///
/// ### 为什么不叫 `MacSettingsSidebarViewController`
/// 它整个文件都在 `#if targetEnvironment(macCatalyst)` 里，只有 Mac 会编到它，名字里再带平台就是废话。
/// 访问级别也是 `private`：外面只经 `SettingsSplitViewController` 用，不给别人乱碰。
private final class SettingsSidebarViewController: UIViewController {

    private let sections: [SettingsSection]

    /// 用户点了某一行：把选中的分组交出去，由分栏控制器换右边的面板
    private let onSelect: (SettingsSection) -> Void

    private var collectionView: UICollectionView!

    /// 列表的数据源：不用数组 + 下标，走 diffable，选中项和内容的对应关系交给系统管
    private var dataSource: UICollectionViewDiffableDataSource<Int, Int>!

    /// 整份列表就一组，行数固定
    private static let singleSection = 0

    init(sections: [SettingsSection], onSelect: @escaping (SettingsSection) -> Void) {
        self.sections = sections
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
        title = "设置"
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsSidebarViewController 不支持从 coder 解档")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // ### 布局：系统给的「列表型」布局 + 侧边栏外观
        // 自己摆一套 flow layout 也能画，但行高、缩进、选中样式全得自己算；这里一行就够
        let layout = UICollectionViewCompositionalLayout.list(
            using: UICollectionLayoutListConfiguration(appearance: .sidebar))
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        // 侧边栏这七行一屏就装下了，滚动条只会碍眼（真装不下时还是能滚）
        collectionView.showsVerticalScrollIndicator = false
        view.addSubview(collectionView)

        // 每一行长什么样：左边图标 + 分组名
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { [weak self] cell, _, index in
            guard let self, let section = self.section(at: index) else { return }
            var content = cell.defaultContentConfiguration()
            content.text = section.title
            // 图标画不出来时 `image` 为 nil，系统自己会把左边空出来
            content.image = UIImage(systemName: section.iconName)
            cell.contentConfiguration = content
            cell.accessibilityLabel = section.title
        }

        dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: collectionView) { view, indexPath, index in
            view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: index)
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([Self.singleSection])
        // 用 `rawValue` 当身份：加分组只要往枚举里补一个 case，`allCases` 自然会带上来
        snapshot.appendItems(sections.map(\.rawValue), toSection: Self.singleSection)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// 把某一行标成选中。
    ///
    /// ⚠️ 调用方（`SettingsSplitViewController`）是在自己的 `viewDidLoad` 里调的，那时这一页的界面还没建 —— `collectionView` 还是 nil，直接往上写会崩。所以先 `loadViewIfNeeded()` 把界面逼出来
    func select(_ section: SettingsSection) {
        loadViewIfNeeded()
        guard let index = sections.firstIndex(of: section) else { return }
        collectionView.selectItem(at: IndexPath(item: index, section: Self.singleSection),
                                  animated: false,
                                  scrollPosition: .top)
    }

    /// 按下标取出分组（下标是从 diffable 数据源那套里来的，兜一下底）
    private func section(at index: Int) -> SettingsSection? {
        sections.indices.contains(index) ? sections[index] : nil
    }
}

extension SettingsSidebarViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let section = section(at: indexPath.item) else { return }
        onSelect(section)
    }
}

#endif
