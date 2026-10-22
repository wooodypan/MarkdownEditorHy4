//
//  DocumentListViewController.swift
//  MarkdownEditorHy4
//
//  左栏：文件列表。「文档」和「最近打开」两页由同一个类、不同的 `Source` 决定列什么。
//

import UIKit
import MultiTabController

/// 左侧栏的文件列表。
///
/// ### 一个类，两页
/// 「文档」和「最近打开」的差别只有**列的是哪一批文件**和**右键里能做什么**；
/// 列表长什么样（标题 / 首行预览 / 修改日期）、单击双击怎么打开、搜索、排序、
/// 右侧切换 Tab 时怎么跟着高亮，全都一样。写两份迟早会改漏一边，所以收成一个类：
///
/// - `.documents`：扫当前目录（`DocumentsWorkspace.entries(in:)`），右键里是重命名 / 导出 / 删除；
/// - `.recent`：列「打开过什么」（`RecentDocumentsStore`），右键里只有「从最近打开中移除」。
///
/// ### 子文件夹怎么走
/// 「文档」页可以往下走：文件夹也作为一行列出来，点一下把 `currentDirectory` 换成它再重扫一层，不做 push（理由见 `currentDirectory`）。顶上那条返回带负责回上一级；文件夹永远排在文件前面，和 Finder / VS Code 一致。
///
/// 搜索是**递归**的：关键词非空时扫当前目录以下整棵树，命中行的标题显示相对路径，否则子文件夹里的同名文件根本分不清是哪一个。
///
/// ### 单击 / 双击的两种「打开」
/// 跟 `MultiTabController` 的示例一致，对应它那套类 VS Code 的 Tab 策略：
/// - **单击** → 预览（`preview`）：右侧复用那个「预览槽位」，不会开一堆 Tab；
/// - **双击** → 正式打开（`newTab`）：永远新开一个，不被后面的预览顶掉。
///
/// 所以「随手看看」用单击，「这份我要一直开着」用双击。
///
/// ### 一行里显示什么
/// 文件名 + 浅灰的**预览**（文档首行文字，一行放不下从尾巴省略）+ 文件的**修改日期**。
/// 后两样都得读盘，所以**不在 `cellForRowAt` 里同步取**：主线程只查 `DocumentListRowCache` 里现成的值，没命中就先空着，后台读完再回填。
/// 存盘 / 增删文件时目录会重扫一遍，缓存按「修改时间有没有变」自己失效，所以 Mac 上「在右栏改完按 ⌘S」，左栏那两行照样跟着变。
///
/// ### 搜索与排序
/// 两页都有：顶上搜索框按文件名过滤（忽略大小写），导航条「⋯」里按修改时间 /
/// 创建时间 / 标题排序（各有正反两种）。「最近」另外保留「按最近打开」这一种默认顺序。
final class DocumentListViewController: UIViewController {

    /// 这一页列什么
    enum Source {
        /// 文档目录里现在有什么
        case documents
        /// 打开过什么（记在缓存里的流水账，跟目录现在的样子无关）
        case recent
    }

    private let source: Source

    /// 「打开一份文档」的出口。iPhone / iPad / Mac 三种环境注入不同实现
    var router: PPContentRouting?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private let searchBar = UISearchBar()

    // MARK: - 返回上级

    /// 子文件夹里顶上那条导航带：左边「返回上级」，右边当前路径
    private let breadcrumbBar = UIView()
    private let backButton = UIButton(type: .system)
    private let pathLabel = UILabel()
    /// 返回条高度。0 = 收起来（停在根目录），34 = 正常显示
    private var breadcrumbHeightConstraint: NSLayoutConstraint?

    // MARK: - 自己画的滚动条

    /// 列表右边那根细长的圆角条（系统的滚动条已经关掉了，见 `setupTableView`）
    private let scrollIndicator = UIView()
    /// 滚动条上边那条约束 —— 滚动时改它的 constant 让它跟着内容滑
    private var scrollIndicatorTopConstraint: NSLayoutConstraint?
    /// 滚动条高度那条约束 —— 内容越长它越短，按「看得见的占整篇多少」算
    private var scrollIndicatorHeightConstraint: NSLayoutConstraint?
    /// 「停手之后淡出」这件事的待办。每次滚动都取消重排，所以只有真停下来才轮得到它执行
    private var scrollIndicatorFadeOutWorkItem: DispatchWorkItem?

    /// 滚动条多宽（点）。3 点差不多是系统那根的视觉宽度，再粗就抢眼了
    private static let scrollIndicatorWidth: CGFloat = 3
    /// 离右边缘多少点。贴死边缘在 Catalyst 上会被窗口圆角切掉一点
    private static let scrollIndicatorSideInset: CGFloat = 2
    /// 滚动条最短多长（点）。长列表按比例算会缩成一根线头，给个下限才看得见
    private static let scrollIndicatorMinLength: CGFloat = 36
    /// 停手之后先等这么久再淡出：手指松开、惯性还在滚的时候不该马上消失
    private static let scrollIndicatorFadeOutDelay: TimeInterval = 0.6

    /// 「文档」页当前停在哪个目录。默认就是 App 文档根目录。
    ///
    /// ### 为什么是「就地换目录」而不是 push 一页新的
    /// 左栏本身是 `PPTabBarController` 里的一页，push 等于把标签页容器压进导航栈；而且外层导航条只同步了右键（`WorkspaceCoordinator.syncNavigationItem`），push 之后标题和返回键都得另做一套。就地换一份数据，三个平台行为完全一致。
    ///
    /// 「最近」页不用它 —— 那一页列的是跨目录的记录，没有「当前目录」这回事。
    private(set) var currentDirectory: URL = DocumentsWorkspace.folderURL

    /// 这一页的完整数据（排序 / 过滤之前）。
    /// 对「最近」来说它已经按打开时间倒序排好了（`RecentDocumentsStore.recentURLs`）
    private var allFiles: [DocumentsWorkspace.Entry] = []

    /// 当前**展示**的行（已经过排序和搜索过滤）
    private var files: [DocumentsWorkspace.Entry] = []

    /// 每行的副标题和日期。首行预览要读盘、文件夹要列子目录，这些都不能在 `cellForRowAt` 里同步做
    private let rowCache = DocumentListRowCache()

    // MARK: - 选中行高亮（与右侧选中的 Tab 联动）

    /// 当前高亮行的内容 id —— 就是 `PPContentItem.id`，也就是文件路径（见 `DocumentOpening`）
    private(set) var highlightedItemID: String?

    /// 这一页里有没有这条内容。右栏切换 Tab、联动高亮时用它判断该亮哪一页
    func containsItem(withID id: String) -> Bool {
        allFiles.contains { !$0.isDirectory && $0.url.path == id }
    }

    /// 设置 / 清除高亮行（传 `nil` 清除）。
    ///
    /// - Parameter scrollToSelection: 目标行不在屏幕内时要不要滚过去。
    ///   自己点击时传 false（本来就在眼前）；右侧切 Tab 联动时传 true，更接近 VS Code。
    func setHighlightedItemID(_ id: String?, scrollToSelection: Bool = false) {
        // 右侧切到一份「不在当前目录里」的文档时，先把左栏带到它所在的文件夹。
        // 少了这一步，「右边切哪个、左边亮哪个」进了子文件夹就失效了
        if let id, revealDirectoryIfNeeded(for: id) {
            reloadFiles()
        }
        guard id != highlightedItemID else { return }
        highlightedItemID = id
        // 视图还没加载时只记状态，首次 `cellForRowAt` 会按它上色
        guard isViewLoaded else { return }
        applyHighlight(scrollToSelection: scrollToSelection)
    }

    /// 高亮的那份不在当前目录里时，把列表切到它所在的文件夹。
    ///
    /// - Returns: 真的换了目录才回 true（调用方据此重扫一遍）
    private func revealDirectoryIfNeeded(for id: String) -> Bool {
        guard source == .documents else { return false }
        // 只认文档根目录底下的路径：从 Finder 打开的外部文件跟这一页没有关系
        let root = ExternalDocumentAccess.shared.canonicalPath(for: DocumentsWorkspace.folderURL)
        let path = ExternalDocumentAccess.shared.canonicalPath(for: URL(fileURLWithPath: id))
        guard path.hasPrefix(root + "/"),
              // 路径已经不存在（Tab 刚关掉、文件被删）就别拿它当理由跳目录
              FileManager.default.fileExists(atPath: path) else { return false }

        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard directory.path != currentDirectory.path else { return false }
        currentDirectory = directory
        updateBreadcrumb()
        return true
    }

    /// 把高亮状态套到当前可见的 cell 上；看不见的行等滚动出现时由 `cellForRowAt` 上色
    private func applyHighlight(scrollToSelection: Bool) {
        for cell in tableView.visibleCells {
            guard let indexPath = tableView.indexPath(for: cell) else { continue }
            updateHighlightAppearance(of: cell, at: indexPath)
        }

        guard scrollToSelection,
              let indexPath = highlightedIndexPath(),
              tableView.window != nil,
              !(tableView.indexPathsForVisibleRows ?? []).contains(indexPath) else { return }
        tableView.scrollToRow(at: indexPath, at: .middle, animated: true)
    }

    private func highlightedIndexPath() -> IndexPath? {
        guard let id = highlightedItemID,
              let row = files.firstIndex(where: { $0.url.path == id }) else { return nil }
        return IndexPath(row: row, section: 0)
    }

    private func updateHighlightAppearance(of cell: UITableViewCell, at indexPath: IndexPath) {
        (cell as? DocumentListCell)?.setHighlighted(files[indexPath.row].url.path == highlightedItemID)
    }

    // MARK: - 排序

    /// 列表的排序方式
    private enum SortOrder: Equatable {
        /// 「最近」页默认：按打开时间倒序（`allFiles` 本来的顺序）
        case recentlyOpened
        case titleAscending
        case titleDescending
        case modifiedNewestFirst
        case modifiedOldestFirst
        case createdNewestFirst
        case createdOldestFirst
    }

    private var sortOrder: SortOrder

    /// 导航条右侧的「更多」按钮（排序菜单），两页都有
    private lazy var moreBarButtonItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"),
                                   menu: makeSortMenu())
        item.accessibilityLabel = "更多"
        return item
    }()

    /// 「最近」页导航条上的「清空」按钮
    private lazy var clearBarButtonItem: UIBarButtonItem = {
        let item = UIBarButtonItem(title: "清空",
                                   style: .plain,
                                   target: self,
                                   action: #selector(clearAllTapped))
        item.accessibilityLabel = "清空最近打开"
        return item
    }()

    /// 冷启动时那个「该不该自动打开第一份文档」只做一次（只有「文档」页用）
    private var didOpenInitialDocument = false

    /// 真正动手「把一个文件删掉」的那一下。默认走 `DocumentsWorkspace.delete`
    /// （Mac 上先进系统废纸篓，手机上直接删）。
    ///
    /// **这是给测试留的替换口**：测试里会换成「直接删临时目录里的文件」，
    /// 免得跑一次测试就往用户的废纸篓里丢一个文件（`DocumentsWorkspace.delete`
    /// 的注释里有同样的警告）。
    var deleteFile: (URL) throws -> Void = { try DocumentsWorkspace.delete($0) }

    /// 导出这条链路（图片 / HTML / PDF）。
    ///
    /// 和编辑页用的是**同一个** `DocumentExporter` —— 同一个子菜单、同一套选项面板、同一条落盘 / 分享流程，所以「右键导出」和「编辑页导出」出来的东西长得一样。
    ///
    /// 主题给的是「按当前设置现拼的一套」：这份文档没在编辑器里开着，没有编辑器的主题可借。
    /// 进度提示（`onStatus`）不传 —— 左栏没有状态栏可写，系统的存储 / 分享面板本身就是反馈。
    private lazy var exporter = DocumentExporter(
        presenter: self,
        anchorView: tableView,
        theme: { MarkdownEditorSettings.shared.currentTheme }
    )

    // MARK: - 生命周期

    /// - Parameter source: 列文档目录（默认）还是列「最近打开」
    init(source: Source = .documents) {
        self.source = source
        // 「最近」默认保持「最近打开的排在前」这个本来的顺序
        self.sortOrder = source == .recent ? .recentlyOpened : .titleAscending
        super.init(nibName: nil, bundle: nil)
        // ⚠️ 导航条按钮放在 init 里配，而不是 viewDidLoad：
        // 这一页是挂在 PPTabBarController 里面的，外层导航条要拿它的按钮
        // （理由见 WorkspaceCoordinator.syncNavigationItem），那时候它的 view 还没加载
        setupNavigationBar()
    }

    required init?(coder: NSCoder) {
        fatalError("DocumentListViewController 不支持从 coder 解档")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = source == .recent ? "最近打开" : "文档"
        view.backgroundColor = .systemBackground

        setupSearchBar()
        setupBreadcrumbBar()
        setupTableView()
        setupEmptyLabel()
        setupTapGestures()
        observeWorkspaceChanges()

        updateBreadcrumb()
        reloadFiles()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 切回来时重列一次：目录里 / 「最近」记录都可能已经变了
        reloadFiles()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 窗口缩放 / 分栏拖动会改变可视高度和表格的上边，滚动条的位置和长度都得跟着重算。
        // 值没变时 `updateScrollIndicator()` 自己会跳过，不会每次都改约束
        updateScrollIndicator()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 只有「文档」页会在 iPad / Mac 上自动打开第一份。
        // 放在 viewDidAppear 而不是 viewDidLoad：这时候外层分栏容器的视图已经装好了，
        // 右侧的 Tab 宿主也已经就位，开 Tab 才是安全的（早于此时机开 Tab 会让
        // 宿主在「视图还没加载」的状态下插入条目）
        guard source == .documents else { return }
        openInitialDocumentIfNeeded()
    }

    // MARK: - 界面

    /// 列表顶上的搜索框：按文件名过滤，忽略大小写
    private func setupSearchBar() {
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.delegate = self
        searchBar.placeholder = "搜索文件名"
        searchBar.searchBarStyle = .minimal
        // 文件名不需要自动大写 / 纠错，别让系统把用户输入改掉
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.spellCheckingType = .no
        view.addSubview(searchBar)

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    /// 子文件夹里顶上那条：左边「上级」，右边当前路径。
    ///
    /// ### 为什么不挂在导航条上
    /// 这一页挂在 `PPTabBarController` 里面，外层导航条只搬了右键（见 `WorkspaceCoordinator.syncNavigationItem`）；而 iPhone 上 push 了编辑页之后，左键是系统的返回键，再塞一颗「上级」会跟它打架。
    ///
    /// ### 为什么不用 `tableHeaderView`
    /// 那个会跟着列表一起滚走 —— 越往下翻越找不到返回入口。这里是一条固定的条，高度约束在 0 和 34 之间切，根目录时等于不存在。
    private func setupBreadcrumbBar() {
        breadcrumbBar.translatesAutoresizingMaskIntoConstraints = false
        // 高度收成 0 时把内容裁掉，免得那两颗控件从 0 高度里露出来
        breadcrumbBar.clipsToBounds = true
        view.addSubview(breadcrumbBar)

        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.setTitle("上级", for: .normal)
        backButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        backButton.tintColor = .secondaryLabel
        backButton.accessibilityLabel = "返回上级文件夹"
        backButton.addTarget(self, action: #selector(goToParentDirectory), for: .touchUpInside)
        breadcrumbBar.addSubview(backButton)

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .preferredFont(forTextStyle: .caption1)
        pathLabel.adjustsFontForContentSizeCategory = true
        pathLabel.textColor = .tertiaryLabel
        pathLabel.textAlignment = .right
        // 路径长的时候从**开头**省略：结尾那段（当前文件夹名）才是最有用的
        pathLabel.lineBreakMode = .byTruncatingHead
        breadcrumbBar.addSubview(pathLabel)

        let height = breadcrumbBar.heightAnchor.constraint(equalToConstant: 0)
        breadcrumbHeightConstraint = height

        NSLayoutConstraint.activate([
            breadcrumbBar.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            breadcrumbBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            breadcrumbBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            height,

            backButton.leadingAnchor.constraint(equalTo: breadcrumbBar.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: breadcrumbBar.centerYAnchor),
            backButton.heightAnchor.constraint(equalToConstant: 28),

            pathLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
            pathLabel.trailingAnchor.constraint(equalTo: breadcrumbBar.trailingAnchor, constant: -16),
            pathLabel.centerYAnchor.constraint(equalTo: breadcrumbBar.centerYAnchor)
        ])
    }

    /// 按当前目录决定返回条显不显示、路径写什么。
    private func updateBreadcrumb() {
        let root = DocumentsWorkspace.folderURL.standardizedFileURL.path
        let path = currentDirectory.standardizedFileURL.path
        let isRoot = path == root
        let shouldShow = source == .documents && !isRoot

        breadcrumbHeightConstraint?.constant = shouldShow ? 34 : 0
        breadcrumbBar.isHidden = !shouldShow
        guard shouldShow else { return }

        // 这里**不能**用 `relativeDisplayName`：它会去掉最后一段的扩展名，而文件夹名里的点只是名字的一部分（`v1.0` 砍成 `v1` 就认不出来了）
        pathLabel.text = path.hasPrefix(root + "/")
            ? String(path.dropFirst(root.count + 1))
            : currentDirectory.lastPathComponent
    }

    /// 进入一个文件夹（退回上级也走它）。
    private func enterDirectory(_ directory: URL) {
        guard source == .documents else { return }

        // ⚠️ 符号链接可以指向文档目录外面，进去之后列的就是 App 别处的文件了
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        let root = DocumentsWorkspace.folderURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else { return }

        currentDirectory = directory
        // 搜索词必须清掉：上一个目录里搜的词带到新目录，十有八九一条都不命中，用户看到的就是「这个文件夹是空的」——很像坏了
        searchBar.text = ""
        searchBar.resignFirstResponder()

        updateBreadcrumb()
        reloadFiles()

        // 换了目录就从头看起，停在上一层的滚动位置没有意义
        if !files.isEmpty {
            tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
        }
    }

    /// 返回条上那颗「上级」。
    @objc private func goToParentDirectory() {
        let root = DocumentsWorkspace.folderURL.standardizedFileURL.path
        let current = currentDirectory.standardizedFileURL.path
        guard current != root else { return }

        let parent = currentDirectory.deletingLastPathComponent().standardizedFileURL.path
        // 正常点不到这一层，防御一下：别退到文档根目录外面去
        guard parent == root || parent.hasPrefix(root + "/") else { return }
        enterDirectory(currentDirectory.deletingLastPathComponent())
    }

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        // 滚动列表时顺手把搜索键盘收起来
        tableView.keyboardDismissMode = .onDrag
        // 系统那根滚动条关掉，换成下面 `setupScrollIndicator()` 画的那根：
        // 系统的在 Catalyst 上是浮层、样式由平台定，和自己画的那根对不上，还会在滑动时一闪一闪
        tableView.showsVerticalScrollIndicator = false
        tableView.separatorStyle = .none
//        tableView.separatorInset = UIEdgeInsets(top: 0, left: 48, bottom: 0, right: 44)
        // 行高交给系统按内容算：这一行有三行字（文件名 / 预览 / 日期），字号还会跟着系统的
        // 「文字大小」设置变，写死一个数字迟早会在某种字号下把字挤住
        tableView.rowHeight = UITableView.automaticDimension
        // 估个大概值只为滚动条长度好看，真实高度还是系统算的
        tableView.estimatedRowHeight = 76
        tableView.register(DocumentListCell.self, forCellReuseIdentifier: Self.cellIdentifier)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: breadcrumbBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // 一定要在表格之后加：后加的在上面，才不会被列表盖住
        setupScrollIndicator()
    }

    /// 造那根细长的圆角滚动条（位置 / 长度每次滚动由 `updateScrollIndicator()` 算）。
    ///
    /// ### 为什么要自己画一根
    /// 系统那根只给「开 / 关」两个选项，样式归平台管：Catalyst 上它是浮层、iPhone 上粗细也不一样，
    /// 想让两端看着一致就得自己来。自己画的另一头好处是淡入淡出节奏也能自己定。
    private func setupScrollIndicator() {
        scrollIndicator.translatesAutoresizingMaskIntoConstraints = false
        // 细长 + 两头半圆：圆角取宽度的一半，圆角条的两端才是完整的半圆而不是被削平
        scrollIndicator.layer.cornerRadius = Self.scrollIndicatorWidth / 2
        scrollIndicator.backgroundColor = UIColor.label.withAlphaComponent(0.3)
        // 它只是指示器：盖在列表右边，但不能抢走滑动 / 点击（左滑删除那条手势要靠列表收事件）
        scrollIndicator.isUserInteractionEnabled = false
        scrollIndicator.isAccessibilityElement = false
        // 一开始透明：列表还没动过，不该凭空出现一根条
        scrollIndicator.alpha = 0
        view.addSubview(scrollIndicator)

        // 上边和高度都是「变量」：滚动时改 constant 让它滑、让它伸缩，比直接改 frame 更省事
        let top = scrollIndicator.topAnchor.constraint(equalTo: view.topAnchor)
        let height = scrollIndicator.heightAnchor.constraint(equalToConstant: 0)
        scrollIndicatorTopConstraint = top
        scrollIndicatorHeightConstraint = height

        NSLayoutConstraint.activate([
            top,
            height,
            scrollIndicator.trailingAnchor.constraint(equalTo: view.trailingAnchor,
                                                      constant: -Self.scrollIndicatorSideInset),
            scrollIndicator.widthAnchor.constraint(equalToConstant: Self.scrollIndicatorWidth)
        ])
    }

    /// 按列表当前的滚动位置，重算滚动条的头在哪、有多长。
    ///
    /// - 没得滚（内容比一屏还短、或者列表被藏起来了）→ 高度给 0，等于看不见；
    /// - 有得滚 → 高度按「看得见的占整篇多少」算，位置按「滚了几成」算。
    ///
    /// 值没变就不动：这个方法在每次滚动、每次布局里都会被调，白改一次约束就多跑一轮 Auto Layout。
    private func updateScrollIndicator() {
        guard let topConstraint = scrollIndicatorTopConstraint,
              let heightConstraint = scrollIndicatorHeightConstraint else { return }

        let insets = tableView.adjustedContentInset
        let visibleHeight = tableView.bounds.height
        // 内容总高要连内边距一起算，否则带内边距的列表滚动条会偏短
        let contentHeight = tableView.contentSize.height + insets.top + insets.bottom
        // 能滚多远：内容比屏幕高出来的那一截。减去可视高度，滚到底时进度才是 1
        let scrollableDistance = contentHeight - visibleHeight

        guard !tableView.isHidden, visibleHeight > 0, scrollableDistance > 1 else {
            heightConstraint.constant = 0
            return
        }

        // 长度按面积比算（可视高 / 内容高），再夹一个下限，免得长列表里缩成一条线头
        let length = min(max(Self.scrollIndicatorMinLength,
                             visibleHeight * visibleHeight / contentHeight),
                         visibleHeight)
        // 滚到哪儿了：0 = 最上面，1 = 最下面。滚到顶时 contentOffset.y 是 -insets.top，所以先补回来
        let progress = min(max((tableView.contentOffset.y + insets.top) / scrollableDistance, 0), 1)
        // 表格在父视图里的上边就是滚动条的轨道起点，剩下那截（可视高 - 条长）才是它滑的范围
        let newTop = tableView.frame.minY + progress * (visibleHeight - length)

        if abs(heightConstraint.constant - length) > 0.5 {
            heightConstraint.constant = length
        }
        if abs(topConstraint.constant - newTop) > 0.5 {
            topConstraint.constant = newTop
        }
    }

    /// 滚动条亮起来（已经在亮就不重复动画，免得每帧都开一个动画）
    private func showScrollIndicator() {
        guard scrollIndicator.alpha < 1 else { return }
        // 短一点：手指一动就该看见，拖泥带水反而像卡了
        UIView.animate(withDuration: 0.15) { self.scrollIndicator.alpha = 1 }
    }

    /// 排一次「停手后淡出」。每次滚动都取消旧的再排新的，于是只有真停下来那一拍才轮到执行
    private func scheduleScrollIndicatorFadeOut() {
        scrollIndicatorFadeOutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.35) { self?.scrollIndicator.alpha = 0 }
        }
        scrollIndicatorFadeOutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollIndicatorFadeOutDelay,
                                     execute: workItem)
    }

    /// 本来就是空的时候的说明文字（搜索没命中是另一段，见 `updateEmptyState`）
    private var emptyDirectoryMessage: String {
        switch source {
        case .documents:
            // 子文件夹里的空和根目录的空不是一回事：根目录还能教用户怎么把文件弄进来，子文件夹里只该说「在这儿新建一份」
            let root = DocumentsWorkspace.folderURL.standardizedFileURL.path
            if currentDirectory.standardizedFileURL.path != root {
                return "这个文件夹里还没有文档\n\n点右上角的「+」就在这里新建一份。"
            }
            // 开了 App 沙盒之后，这个文档目录藏在 App 自己的容器里，两个平台「把文件弄进来」
            // 的办法也就不一样了：
            // - Mac 上 Finder 里不方便直接拖到容器里，教用户走「文件 > 打开…」（⌘O）；
            // - iPhone / iPad 上靠 Info.plist 的 `UIFileSharingEnabled` 把这个目录露在
            //   「文件」App 里，直接往里丢就行。
            #if targetEnvironment(macCatalyst)
            return "这个目录里还没有文档\n\n用「文件 > 打开…」把硬盘上的 .md 打开，\n或者点右上角的「+」新建一份。"
            #else
            return "这个目录里还没有文档\n\n把 .md 文件放进「文件」App\n的 MarkdownEditorHy4 文件夹，\n或者点右上角的「+」新建一份。"
            #endif
        case .recent:
            return "还没有打开过文档\n\n在「文档」那一页点一份，\n它就会出现在这里。"
        }
    }

    /// 一份文件都没有时的说明文字 —— 空白列表很容易被当成「卡住了」
    private func setupEmptyLabel() {
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.text = emptyDirectoryMessage
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.font = .preferredFont(forTextStyle: .footnote)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = .secondaryLabel
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func setupNavigationBar() {
        switch source {
        case .documents:
            let addItem = UIBarButtonItem(barButtonSystemItem: .add,
                                          target: self,
                                          action: #selector(createNewDocument))
            addItem.accessibilityLabel = "新建文档"
            // rightBarButtonItems 里**第一个是最右边那颗**：这样「+」在左、「⋯」在右
            navigationItem.rightBarButtonItems = [moreBarButtonItem, addItem]
        case .recent:
            // 同样让「⋯」在右、「清空」在左
            navigationItem.rightBarButtonItems = [moreBarButtonItem, clearBarButtonItem]
        }
    }

    /// 单击 / 双击两把手势。
    ///
    /// ⚠️ 关键在 `singleTap.require(toFail: doubleTap)`：
    /// 「单击」要等系统确认「这不是双击」之后才触发。少了这一行，
    /// 双击的第二下会先被当成一次单击 —— 于是「双击正式打开」会变成
    /// 「先预览一次、再正式打开一次」，右侧平白多出一个 Tab。
    private func setupTapGestures() {
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)

        tableView.addGestureRecognizer(singleTap)
        tableView.addGestureRecognizer(doubleTap)
    }

    // MARK: - 数据

    private func reloadFiles() {
        switch source {
        case .documents:
            // 只列当前目录这一层：子文件夹作为「能进去的一行」一起出来
            allFiles = DocumentsWorkspace.entries(in: currentDirectory)
        case .recent:
            // 「最近」列的是跨目录的记录，永远只有文件。
            // 走 `entry(for:)` 是为了把修改时间一起读出来（按时间排序要用），那是每条一次 stat —— 记录条数很少，比逐行填 cell 时再 stat 划算得多
            allFiles = RecentDocumentsStore.shared.recentURLs().map { DocumentsWorkspace.entry(for: $0) }
        }

        // 重扫完了：缓存里那些「修改时间对不上」或「已经不在这一层」的行作废。
        // 没变的行继续用，切回左栏时不会整片重新闪一遍
        rowCache.invalidate(against: allFiles)

        // 高亮的那份如果已经不在了（被删 / 改名 / 从记录里移除），别让状态一直挂着
        // 一个不存在的路径。注意看的是 `allFiles` 而不是过滤后的 `files`：
        // 只是被搜索藏起来的行，清空搜索后还该亮着
        if let id = highlightedItemID, !allFiles.contains(where: { $0.url.path == id }) {
            highlightedItemID = nil
        }

        // 「清空」只在有记录时可点（找不找得到搜索结果跟这个无关）
        if source == .recent {
            clearBarButtonItem.isEnabled = !allFiles.isEmpty
        }

        applySortAndFilter()
    }

    /// 按当前排序方式 + 搜索框里的关键词，重算 `files` 并刷新列表。
    ///
    /// ### 「文档」页的搜索是递归的
    /// 进了子文件夹之后只搜这一层，用户得一层层点进去才找得到东西，搜索框基本就废了。
    /// 所以关键词非空时会把当前目录以下整棵树扫一遍，命中行的标题显示相对路径（`日记/2026-10`），这样同名文件也能分清是哪一个。
    ///
    /// 「最近」页还是只过滤它自己那份记录 —— 那些记录本来就是跨目录的，没有「当前目录」可言。
    private func applySortAndFilter() {
        let query = (searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let matched: [DocumentsWorkspace.Entry]
        if query.isEmpty {
            matched = allFiles
        } else if source == .documents {
            matched = DocumentsWorkspace.searchDocuments(in: currentDirectory, matching: query)
        } else {
            matched = allFiles.filter { entry in
                // 匹配的是界面上显示的标题（去掉扩展名），忽略大小写；
                // 带上 diacriticInsensitive，英文名带重音也能搜到
                entry.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }

        files = sorted(matched)
        updateEmptyState(query: query)
        tableView.reloadData()
    }

    /// 按 `sortOrder` 排一份拷贝。
    ///
    /// ### 文件夹永远排在最前面
    /// 和 Finder / VS Code 一样：进目录是「往下走」，混在文件中间会让人每次都要在两种东西里挑。
    /// 分组之后两组各自按当前排序方式排，组内规则仍然听用户的。
    private func sorted(_ entries: [DocumentsWorkspace.Entry]) -> [DocumentsWorkspace.Entry] {
        let folders = entries.filter { $0.isDirectory }
        let documents = entries.filter { !$0.isDirectory }
        return sortedWithinGroup(folders) + sortedWithinGroup(documents)
    }

    private func sortedWithinGroup(_ entries: [DocumentsWorkspace.Entry]) -> [DocumentsWorkspace.Entry] {
        // 空组（「最近」页的文件夹组永远是空的）直接返回，省掉后面那几趟遍历
        guard entries.count > 1 else { return entries }

        switch sortOrder {
        case .recentlyOpened:
            // `allFiles` 本来就是按「最近打开」倒序的，过滤只保持原顺序，不用再排
            return entries
        case .titleAscending:
            return entries.sorted { compareNames($0, $1) == .orderedAscending }
        case .titleDescending:
            return entries.sorted { compareNames($0, $1) == .orderedDescending }
        case .modifiedNewestFirst:
            return sortedByDate(entries, newestFirst: true, kind: .modified)
        case .modifiedOldestFirst:
            return sortedByDate(entries, newestFirst: false, kind: .modified)
        case .createdNewestFirst:
            return sortedByDate(entries, newestFirst: true, kind: .created)
        case .createdOldestFirst:
            return sortedByDate(entries, newestFirst: false, kind: .created)
        }
    }

    private enum DateKind {
        case modified
        case created
    }

    /// 按时间排；时间一样时退回按标题升序，保证顺序稳定、可预期
    private func sortedByDate(_ entries: [DocumentsWorkspace.Entry],
                              newestFirst: Bool,
                              kind: DateKind) -> [DocumentsWorkspace.Entry] {
        // 时间直接用扫描目录时顺手读到的那份（`Entry.modifiedDate` / `createdDate`），不再每条都去 stat、更不用为每条申请一次外部文件访问权 —— 那两项在长目录上很贵
        let dates = Dictionary(uniqueKeysWithValues: entries.map { entry -> (String, Date) in
            let date: Date?
            switch kind {
            case .modified:
                date = entry.modifiedDate
            case .created:
                date = entry.createdDate
            }
            return (entry.url.path, date ?? .distantPast)
        })
        return entries.sorted { lhs, rhs in
            let lhsDate = dates[lhs.url.path] ?? .distantPast
            let rhsDate = dates[rhs.url.path] ?? .distantPast
            if lhsDate != rhsDate {
                return newestFirst ? lhsDate > rhsDate : lhsDate < rhsDate
            }
            return compareNames(lhs, rhs) == .orderedAscending
        }
    }

    /// 标题比较用 `localizedStandardCompare`：中文 / 数字排法才符合直觉
    private func compareNames(_ lhs: DocumentsWorkspace.Entry,
                              _ rhs: DocumentsWorkspace.Entry) -> ComparisonResult {
        lhs.name.localizedStandardCompare(rhs.name)
    }

    /// 列表空了时该显示哪段说明：本来就没有文件，还是搜索没命中
    private func updateEmptyState(query: String) {
        let isEmpty = files.isEmpty
        tableView.isHidden = isEmpty
        emptyLabel.isHidden = !isEmpty
        guard isEmpty else { return }
        // 有关键词就是「没搜到」，没有关键词才是「这一层本来就是空的」。
        // 不能拿 `allFiles.isEmpty` 判：搜索是递归的，当前层空、子目录里有东西时它会答错
        emptyLabel.text = query.isEmpty
            ? emptyDirectoryMessage
            : "没有找到「\(query)」\n\n换个关键词试试。"
    }

    // MARK: - 排序菜单

    /// 「⋯」点开的排序菜单：修改时间 / 创建时间 / 标题，各自升序和降序。
    /// 「最近」页多一项「按最近打开」，用来回到它本来的默认顺序。
    private func makeSortMenu() -> UIMenu {
        func action(_ title: String, _ order: SortOrder) -> UIAction {
            UIAction(title: title, state: sortOrder == order ? .on : .off) { [weak self] _ in
                self?.applySortOrder(order)
            }
        }

        // 时间类按用户的说法写「最新的排在前 / 最旧的排在前」，比「降序 / 升序」直观
        let modified = UIMenu(title: "按修改时间",
                              image: UIImage(systemName: "clock"),
                              children: [
                                  action("最新的排在前", .modifiedNewestFirst),
                                  action("最旧的排在前", .modifiedOldestFirst)
                              ])
        let created = UIMenu(title: "按创建时间",
                             image: UIImage(systemName: "calendar"),
                             children: [
                                 action("最新的排在前", .createdNewestFirst),
                                 action("最旧的排在前", .createdOldestFirst)
                             ])
        let title = UIMenu(title: "按标题",
                           image: UIImage(systemName: "textformat"),
                           children: [
                               action("升序", .titleAscending),
                               action("降序", .titleDescending)
                           ])

        let sections: [UIMenu]
        switch source {
        case .documents:
            sections = [modified, created, title]
        case .recent:
            // 「最近」本来的顺序就是按打开时间倒序，换回来时用这一项
            let recentlyOpened = UIMenu(title: "按最近打开",
                                        image: UIImage(systemName: "clock.arrow.circlepath"),
                                        children: [action("最近打开的排在前", .recentlyOpened)])
            sections = [recentlyOpened, modified, created, title]
        }
        return UIMenu(children: sections)
    }

    private func applySortOrder(_ order: SortOrder) {
        guard order != sortOrder else { return }
        sortOrder = order
        // 对勾要跟着换：重建菜单挂回按钮上
        moreBarButtonItem.menu = makeSortMenu()
        applySortAndFilter()
    }

    // MARK: - 通知

    /// 通知：目录变了 / 有人要新建 / 有外部文件要打开
    private func observeWorkspaceChanges() {
        let center = NotificationCenter.default
        center.addObserver(self,
                           selector: #selector(workspaceDidChange),
                           name: DocumentsWorkspace.didChangeNotification,
                           object: nil)

        // 下面两条只管「文档」页：「最近」不负责新建，也不接外部打开的文件
        guard source == .documents else { return }
        center.addObserver(self,
                           selector: #selector(createNewDocument),
                           name: DocumentsWorkspace.newDocumentRequestedNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(documentOpenRequested(_:)),
                           name: .markdownDocumentOpenRequested,
                           object: nil)
    }

    @objc private func workspaceDidChange() {
        reloadFiles()
    }

    /// 有人（⌘O 打开面板、Finder 双击、后台传文件进来）送了一个文件路径 → 新开一个 Tab
    @objc private func documentOpenRequested(_ notification: Notification) {
        guard source == .documents, let url = notification.object as? URL else { return }
        open(url, mode: .newTab)
    }

    // MARK: - 打开 / 新建

    /// 冷启动时该不该自己开一份（只跟「文档」页有关）。
    ///
    /// - 用户是从 Finder 双击某个 .md 进来的 → 当然开那一份（走外部文件那条通知）；
    /// - iPad / Mac 上右侧本来就是空的，顺手把第一份打开，别让人对着空面板发呆；
    /// - iPhone 上不开：那边是导航栈，一进来就 push 一页会让人莫名其妙。
    private func openInitialDocumentIfNeeded() {
        guard !didOpenInitialDocument else { return }
        didOpenInitialDocument = true

        if let pending = MarkdownDocumentOpener.shared.takePendingURL() {
            open(pending, mode: .newTab)
            return
        }
        // 有存档时不再自动打开第一份文档。恢复发生在详情宿主的 viewDidLoad，比这里的 viewDidAppear 早，所以此刻存档还没被改写。
        guard !MarkdownTabRestoration.willRestoreTabsOnLaunch else { return }
        // ⚠️ 第一行可能是文件夹（目录永远排前面），那不是能打开的东西 —— 不筛掉的话，冷启动第一件事就是对着文件夹弹一个「打不开文件」
        guard DeviceHelper.currentLayout == .iPadOrMac,
              let first = files.first(where: { !$0.isDirectory }) else { return }
        open(first.url, mode: .preview)
    }

    /// 把一份磁盘文件交给右侧编辑。
    ///
    /// ### iOS 上先问一句要不要复制
    /// 容器外的文件在 iOS 上没有跨启动的访问权，直接编辑原文件容易「这次能开、
    /// 下次从最近点开就报错」。所以先问用户：复制一份到 App 里（推荐），
    /// 还是只这次直接打开。Mac Catalyst 有 security-scoped bookmark，不用问。
    ///
    /// 打开这件事（读内容、记一笔「最近打开」、送给路由）统一在 `DocumentOpening` 里做 ——
    /// 「文档」和「最近」走的是同一条路，两边的行为必须对得上。
    private func open(_ url: URL, mode: PPContentOpenMode) {
        #if !targetEnvironment(macCatalyst)
        // 判断「在不在容器里」用规范化路径；真去申请权限、复制文件时还得用原始 URL ——
        // 临时通行证是附在原始地址上的，先解析一遍可能就失效了
        if !ExternalDocumentAccess.shared.isInsideContainer(url) {
            promptToCopyExternalDocument(url, mode: mode)
            return
        }
        #endif

        performOpen(url, mode: mode)
    }

    /// 真正的打开动作：拿内容、开 Tab、联动高亮。
    private func performOpen(_ url: URL, mode: PPContentOpenMode) {
        guard let openedURL = DocumentOpening.open(url, mode: mode, using: router) else {
            showOpenFailureAlert(for: url)
            reloadFiles()
            return
        }
        // 打开成功就把这一行点亮（VS Code 式）；iPad / Mac 上右侧切 Tab 时
        // 还会由 `onSelectedItemChanged` 再同步一次（幂等）。
        // 高亮按规范化路径比对 —— 列表里的行存的就是这个，原始访问 URL 可能带着不一样的前缀
        setHighlightedItemID(ExternalDocumentAccess.shared.canonicalPath(for: openedURL))

        switch source {
        case .documents:
            break
        case .recent:
            // 打开过之后这份会重新排到最前面，列表顺序得跟着变
            reloadFiles()
        }
    }

    #if !targetEnvironment(macCatalyst)
    /// iOS 上打开容器外文件时的选择框。
    ///
    /// 「复制并打开」是推荐项，复制出来的副本会落进 Documents，之后就是一个普通的
    /// 容器内文档；「直接打开」只借用这次运行期间的临时授权，App 重启后
    /// 「最近」里的这条记录就不一定还能打开了。
    private func promptToCopyExternalDocument(_ url: URL, mode: PPContentOpenMode) {
        // 先确认这次确实拿得到访问权，拿不到就别给用户一个按了会失败的按钮
        guard ExternalDocumentAccess.shared.readableURL(for: url) != nil else {
            showOpenFailureAlert(for: url)
            return
        }

        let name = DocumentsWorkspace.displayName(for: url)
        let alert = UIAlertController(
            title: "这份文件在 App 外面",
            message: "「\(name)」不在 App 的文档目录里。\n\n"
                   + "复制一份到 App 里（推荐）：之后改名、删除、重启后从「最近」打开都正常，"
                   + "但改的是副本，不会写回原文件。\n\n"
                   + "直接打开：只借用这次运行期间的临时权限，重启后可能就打不开了。",
            preferredStyle: .alert)

        let copyAction = UIAlertAction(title: "复制并打开", style: .default) { [weak self] _ in
            // 等选择框退场再干活，失败提示才有地方弹
            DispatchQueue.main.async { self?.copyExternalDocumentAndOpen(url, mode: mode) }
        }
        alert.addAction(copyAction)
        alert.addAction(UIAlertAction(title: "直接打开", style: .default) { [weak self] _ in
            DispatchQueue.main.async { self?.performOpen(url, mode: mode) }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.preferredAction = copyAction
        // 文件选择器刚选完时，它可能还占着最上层。等一拍再弹，
        // 免得「present 在一个正在消失的控制器上」
        DispatchQueue.main.async { [weak self] in
            self?.presentAlert(alert)
        }
    }

    /// 把容器外文件复制进 Documents，再打开副本。
    private func copyExternalDocumentAndOpen(_ url: URL, mode: PPContentOpenMode) {
        guard let readableURL = ExternalDocumentAccess.shared.readableURL(for: url) else {
            showOpenFailureAlert(for: url)
            return
        }

        do {
            let copyURL = try DocumentsWorkspace.importDocument(from: readableURL)
            // 用户接下来编辑的是副本，原路径的「最近」记录和书签都没用了
            RecentDocumentsStore.shared.remove(url)
            NotificationCenter.default.post(name: DocumentsWorkspace.didChangeNotification, object: nil)
            performOpen(copyURL, mode: mode)
        } catch {
            showAlert(title: "复制失败",
                      message: "「\(url.lastPathComponent)」没能复制进 App：\(error.localizedDescription)")
        }
    }
    #endif

    /// 打不开时给一句能照着做的提示。
    ///
    /// 容器外文件最常见的原因是没拿到访问权，光说「读不出来」用户不知道下一步该干嘛。
    private func showOpenFailureAlert(for url: URL) {
        let name = url.lastPathComponent
        let message: String
        if ExternalDocumentAccess.shared.isInsideContainer(url) {
            message = "「\(name)」读不出来，可能已经被删掉了。"
        } else {
            #if targetEnvironment(macCatalyst)
            message = "「\(name)」在 App 的文档目录之外，当前没有它的访问权限。\n\n"
                    + "请用「文件 > 打开…」(⌘O) 重新选一次这份文件，系统会重新授权；"
                    + "这次打开后会把书签记下来，下次就能直接从「最近」打开。"
            #else
            message = "「\(name)」在 App 的文档目录之外，这次没有拿到访问权限。\n\n"
                    + "请从「文件」App 重新用本 App 打开它，并在提示里选择「复制并打开」。"
            #endif
        }
        showAlert(title: "打不开文件", message: message)
    }

    /// 新建一份空白文档，并立刻在右侧开个新 Tab 编辑它（只有「文档」页有这颗按钮）。
    ///
    /// 文件是**先落到磁盘**的，所以左侧栏立刻就能看到 ——
    /// 不搞「内存里的草稿」那种中间态，⌘S 也就永远有地方写。
    ///
    /// 这会儿它还顶着「未命名」这个占位名；等用户在右栏第一次按 ⌘S，
    /// 编辑页会弹框请他起个正式名字（见 `MarkdownDocumentViewController.saveDocument`）。
    @objc private func createNewDocument() {
        createDocument(in: currentDirectory)
    }

    /// 在指定文件夹里新建一份并立刻打开（右上角的「+」和文件夹右键菜单都走它）。
    ///
    /// - Parameter directory: 建到哪个文件夹。用户在子文件夹里按「+」时就该建在眼前这一层，
    ///   而不是又跑回根目录去 —— 那会让人以为「新建没成功」
    private func createDocument(in directory: URL) {
        guard source == .documents else { return }
        do {
            let url = try DocumentsWorkspace.createEmptyDocument(in: directory)
            // 在别的文件夹里建的，先切过去，否则用户看不到刚建好的那一份
            if directory.standardizedFileURL.path != currentDirectory.standardizedFileURL.path {
                enterDirectory(directory)
            }
            NotificationCenter.default.post(name: DocumentsWorkspace.didChangeNotification, object: nil)
            open(url, mode: .newTab)
        } catch {
            showAlert(title: "新建失败", message: error.localizedDescription)
        }
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              let item = entry(at: gesture) else { return }
        // 文件夹没有「预览 / 正式」之分，点一下就是进去
        if item.isDirectory {
            enterDirectory(item.url)
            return
        }
        // iPhone 上没有「预览槽位」这个概念（它是导航栈），开新 Tab 就等于 push 一页。
        // 这个判断跟库里示例的写法一致
        let mode: PPContentOpenMode = DeviceHelper.currentLayout == .iPadOrMac ? .preview : .newTab
        open(item.url, mode: mode)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              let item = entry(at: gesture) else { return }
        // ⚠️ 文件夹在这一下里也必须「进入」而不是「打开」：
        // 往下走 `DocumentOpening.open` 会去读一个目录、读失败，然后弹一句「打不开文件」，很吓人
        if item.isDirectory {
            enterDirectory(item.url)
            return
        }
        // 双击「正式打开」只在有 Tab 的环境里有意义；iPhone 上忽略
        guard DeviceHelper.currentLayout == .iPadOrMac else { return }
        open(item.url, mode: .newTab)
    }

    private func entry(at gesture: UITapGestureRecognizer) -> DocumentsWorkspace.Entry? {
        guard let indexPath = tableView.indexPathForRow(at: gesture.location(in: tableView)),
              files.indices.contains(indexPath.row) else { return nil }
        return files[indexPath.row]
    }

    // MARK: - 右键菜单

    /// 右键（iPad 上是长按）弹出的那一组菜单项。
    ///
    /// 抽成单独的方法是为了能单测 —— 不然测试得先伪造一次右键事件才能看到菜单长什么样。
    func contextMenu(for url: URL) -> UIMenu {
        switch source {
        case .documents:
            let entry = DocumentsWorkspace.entry(for: url)
            // 文件夹没有「导出」可言，能做的只有新建 / 改名 / 删除
            if entry.isDirectory {
                return folderMenu(for: entry)
            }
            // 菜单顶上的小标题用文件名：右键的时候正好再确认一眼点的是哪一份
            return UIMenu(title: entry.name,
                          children: [
                              renameAction(for: url),
                              // 「导出」是个子菜单（图片 / HTML / PDF），整块由 `DocumentExporter` 生成 ——编辑页那个菜单用的是同一个方法，所以两处的选项永远一致
                              exporter.exportMenu { [weak self] in self?.exportSource(for: url) },
                              deleteAction(for: url)
                          ])
        case .recent:
            // 「最近」里只动记录，不动文件
            return removeMenu(for: url)
        }
    }

    /// 文件夹的右键菜单。
    private func folderMenu(for entry: DocumentsWorkspace.Entry) -> UIMenu {
        let newDocument = UIAction(title: "在此新建文档",
                                   image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
            self?.createDocument(in: entry.url)
        }
        return UIMenu(title: entry.name,
                      children: [
                          newDocument,
                          renameAction(for: entry.url),
                          deleteAction(for: entry.url)
                      ])
    }

    // MARK: - 文档页：重命名 / 导出 / 删除

    /// 「重命名」那一项
    private func renameAction(for url: URL) -> UIAction {
        UIAction(title: "重命名", image: UIImage(systemName: "pencil")) { [weak self] _ in
            self?.promptForRename(url)
        }
    }

    /// 「删除」那一项
    private func deleteAction(for url: URL) -> UIAction {
        UIAction(title: "删除",
                 image: UIImage(systemName: "trash"),
                 // destructive：菜单里显示成红色，先给用户一个「这一步不可逆」的暗示
                 attributes: .destructive) { [weak self] _ in
            self?.confirmDelete(url)
        }
    }

    /// 弹「改个名字」的输入框。文件和文件夹共用这一个。
    ///
    /// ### 为什么在 App 里改，而不是让用户去 Finder / 「文件」里改
    /// 在 App 里改完名，那些按路径存的记录能顺手一起收拾（「上次读到哪儿」「最近打开」，还有正开着这份文档的编辑页 —— 见 `performRename`）。在 App 外面改，App 这边只会看到「那份文件不见了、又多出一份新的」，两边的账就对不上了。
    ///
    /// - Parameter suggested: 预填进输入框的名字。用户因为重名被打回来重弹时填他上一次输的，改一个字就能接着来
    private func promptForRename(_ url: URL, suggested: String? = nil) {
        let isDirectory = DocumentsWorkspace.isDirectory(url)
        // ⚠️ 文件夹名不能去掉「扩展名」：`v2.0` 是名字，不是后缀。按文件那套处理会把预填值改成 `v2`
        let currentName = isDirectory ? url.lastPathComponent : DocumentsWorkspace.displayName(for: url)
        let defaultName = suggested ?? currentName

        let alert = UIAlertController(title: "重命名",
                                      message: "给「\(currentName)」换个名字，内容不会动。",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.text = defaultName
            field.placeholder = isDirectory ? "文件夹名" : "文件名"
            field.clearButtonMode = .whileEditing
            field.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        // `weak alert`：UIAlertController 持有 action、action 持有这个闭包，闭包里再强引用 alert 就绕成一个圈，弹框关了也放不掉
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            self.commitRename(url, toBaseName: alert?.textFields?.first?.text ?? "")
        })

        // 预填的名字整条选中：用户直接打字就等于「改掉它」，不用先自己全选删一遍。
        // 放在 present 的 completion 里做：弹框还没上屏时输入框不是第一响应者，那会儿设选中会被系统清掉
        present(alert, animated: true) {
            alert.textFields?.first?.selectAll(nil)
        }
    }

    /// 用户在命名框里点了「好」之后真正要做的事：改名；不成就提示 + 给一条重新起名的路。
    ///
    /// 弹框 / 提示这一半单独留着，改名那一半见下面 `rename(_:toBaseName:)` —— 那边不弹框，好单测。
    private func commitRename(_ url: URL, toBaseName rawName: String) {
        do {
            try rename(url, toBaseName: rawName)
        } catch {
            showRenameFailureAlert(error, for: url, triedName: rawName)
        }
    }

    /// 真正动手改名：把文件挪到新名字下，再把跟着路径走的那些记录一起收拾干净。
    ///
    /// ### 为什么单独一个方法、而且**不弹框**
    /// 弹框那一步在单测里走不起来，而「改名 + 清记录 + 通知界面」才是真会出错的地方，所以把它拆出来，失败时直接抛出去，由界面决定怎么跟用户说。
    ///
    /// - Returns: 改名后的新地址
    /// - Throws: 名字是空的（`WorkspaceError.emptyName`）、撞上重名（`WorkspaceError.nameTaken`）、或者文件系统本身报错
    @discardableResult
    func rename(_ url: URL, toBaseName rawName: String) throws -> URL {
        // 文件夹和文档走两条路：文件夹不改扩展名，而且一改就是整棵子树换前缀
        if DocumentsWorkspace.isDirectory(url) {
            let newURL = try DocumentsWorkspace.renameDirectory(url, toBaseName: rawName)
            // 两个按路径记账的地方都要整片搬走。不搬的话，「最近」里这些记录下次刷新会被当成「文件已经不存在」清掉，「读到哪儿」也全部作废
            DocumentScrollMemory.shared.migrate(fromPrefix: url.path, toPrefix: newURL.path)
            RecentDocumentsStore.shared.migrate(fromPrefix: url.path, toPrefix: newURL.path)
            // 用户正停在被改名的文件夹里（或它下面）时，当前目录跟着换 —— 否则列表会去扫一个已经不存在的路径，看起来就像「里面的东西全没了」
            relocateCurrentDirectory(from: url, to: newURL)
            NotificationCenter.default.post(name: DocumentsWorkspace.didChangeNotification, object: nil)
            return newURL
        }

        let newURL = try DocumentsWorkspace.rename(url, toBaseName: rawName)

        // 「这份文档上次读到哪儿」是按路径存的，旧路径那条没人用了。
        // 文件名以后可能被重新用上，那时不该莫名跳到文档中间 —— 主动忘掉（和删除时做的是同一件事）
        DocumentScrollMemory.shared.forget(key: url.path)
        // 「最近打开」里那一行也别再指着旧路径：那份记录会被判成「文件已经不在」，白占一行
        RecentDocumentsStore.shared.remove(url)
        // 说一声，列表自己会重新扫一遍目录（照旧走通知这条路，别在这儿直接刷）。
        // ⚠️ 正开着这份文档的编辑页**不用**在这儿通知：`DocumentsWorkspace.rename` 自己会发 `didRenameNotification`（带上新旧路径），它靠那条把路径换过去
        NotificationCenter.default.post(name: DocumentsWorkspace.didChangeNotification, object: nil)
        return newURL
    }

    /// 当前目录正好在被改名的文件夹里（或就是它本人）时，把 `currentDirectory` 换到新位置。
    private func relocateCurrentDirectory(from oldURL: URL, to newURL: URL) {
        guard source == .documents else { return }
        let oldPrefix = oldURL.standardizedFileURL.path
        let current = currentDirectory.standardizedFileURL.path
        guard current == oldPrefix || current.hasPrefix(oldPrefix + "/") else { return }

        // 只替换前缀，剩下那截（可能还有好几层）原样接上
        let suffix = String(current.dropFirst(oldPrefix.count))
        currentDirectory = URL(fileURLWithPath: newURL.standardizedFileURL.path + suffix,
                               isDirectory: true)
        updateBreadcrumb()
        reloadFiles()
    }

    /// 名字用不了（空的 / 重名）时的提示，带一个「重新起名」的入口。
    ///
    /// 单独写一个而不是复用 `showAlert`：只丢一句「改不了名」的话，用户得自己再右键一次才能重新输名字，白多两步。
    private func showRenameFailureAlert(_ error: Error, for url: URL, triedName: String) {
        let alert = UIAlertController(title: "这个名字用不了",
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        // 预填的是用户上一次输入的那个名字，改一个字就能接着来
        alert.addAction(UIAlertAction(title: "重新起名", style: .default) { [weak self] _ in
            self?.promptForRename(url, suggested: triedName)
        })
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        present(alert, animated: true)
    }

    /// 点「导出」时交给 `DocumentExporter` 的那份内容 —— 从磁盘上读。
    ///
    /// ### 和编辑页那条路的差别
    /// 只有「内容从哪儿来」不一样：编辑页给的是编辑器内存里的当前内容（可能还没存盘），这里给的是文件里躺着的那一份（一份没打开的文档，也就只有这一份可用）。
    private func exportSource(for url: URL) -> DocumentExportSource? {
        guard let text = DocumentsWorkspace.read(url) else {
            showAlert(title: "导出失败",
                      message: "「\(url.lastPathComponent)」读不出来，可能被删掉或者没有访问权限。")
            return nil
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showAlert(title: "导出失败",
                      message: "「\(DocumentsWorkspace.displayName(for: url))」是空的，没有可导出的内容。")
            return nil
        }
        // 不传 imageRenderer：这份文档没在编辑器里开着，交给导出器临时造一台编辑器去画（见 DocumentExporter.renderImage）
        return DocumentExportSource(markdown: text,
                                    displayName: DocumentsWorkspace.displayName(for: url),
                                    fileURL: url)
    }

    /// 删之前先问一句。这是**不可逆**的操作（Mac 上还能从废纸篓捞，手机上就是没了）。
    ///
    /// - Parameter completion: 真删掉了回 true。滑动手势要靠它决定「这一行收不收回原位」。
    private func confirmDelete(_ url: URL, completion: ((Bool) -> Void)? = nil) {
        // 文件夹要显示全名（`v2.0` 去掉尾巴就成了另一个名字）
        let name = DocumentsWorkspace.isDirectory(url)
            ? url.lastPathComponent
            : DocumentsWorkspace.displayName(for: url)
        let alert = UIAlertController(title: "删除「\(name)」？",
                                      message: deletionWarning(for: url),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion?(false) })
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            // ⚠️ 删除这一步必须**先单独执行完**，再回头调 completion。
            //
            // 千万别图省事写成 `completion?(self?.performDelete(url) ?? false)` ——
            // `completion` 是 nil 时，Swift 的 `?()` 会把**括号里的参数一起跳过不求值**，
            // 于是 `performDelete` 根本不会跑。右键菜单那条路恰恰就是不传 completion 的
            // （只有左滑需要知道结果），所以点完「删除」文件会原地不动。
            self?.handleDeleteConfirmation(url, completion: completion)
        })
        present(alert, animated: true)
    }

    /// 用户在确认框里点了「删除」之后真正要做的事。
    ///
    /// 单独抽出来有三个原因：
    /// 1. **它必须无条件执行** —— 理由见上面那段警告，一旦写进 `completion?(...)`
    ///    的参数位置，就会被 optional chaining 短路掉；
    /// 2. 能单测：`completion` 传 nil（也就是右键菜单那条路的样子）时，
    ///    文件也必须真的被删掉；
    /// 3. 提醒后来的人别把它挪回闭包的参数里。
    ///
    /// - Parameter completion: 真删掉了回 true；滑动手势靠它决定「这一行收不收回原位」。
    func handleDeleteConfirmation(_ url: URL, completion: ((Bool) -> Void)? = nil) {
        // 先删，再回调 —— 顺序反了就又回到原来那个坑里
        let didDelete = performDelete(url)
        completion?(didDelete)
    }

    /// 确认框里那两句 / 三句话：一句说「东西去哪儿了」，一句说「删完右侧那个标签页怎么办」
    private func deletionWarning(for url: URL) -> String {
        // 删文件夹必须把「里面的文档也会一起没」说在最前面，这是最容易后悔的一种删除
        if DocumentsWorkspace.isDirectory(url) {
            let summary = DocumentsWorkspace.summary(ofDirectory: url)
            var inside = "\(summary.documents) 份文档"
            if summary.folders > 0 { inside += "和 \(summary.folders) 个子文件夹" }
            var folderLines = ["整个文件夹「\(url.lastPathComponent)」都会删掉，里面的 \(inside) 一起没。"
                               + (DocumentsWorkspace.deletionGoesToTrash
                                  ? "它先进系统废纸篓，反悔了可以去那儿「放回原处」。"
                                  : "删掉就找不回来了。")]
            if DeviceHelper.currentLayout == .iPadOrMac {
                folderLines.append("右侧标签页如果正开着里面的文档，删完请点标签上的 × 关掉。")
            }
            return folderLines.joined(separator: "\n\n")
        }

        var lines = ["\(url.lastPathComponent) 会从文档目录里移走。"
                     + (DocumentsWorkspace.deletionGoesToTrash
                        ? "它先进系统废纸篓，反悔了可以去那儿「放回原处」。"
                        : "删掉就找不回来了。")]

        // 右侧正开着这份文档时，删完那个标签页还在编辑一份已经不存在的文件。
        // 库目前没有「按内容关掉某个 Tab」的公开接口（只有标签上那个 × 能关），
        // 所以这里只能提醒一句。iPhone 上是导航栈、没有标签页，就不用说这句了。
        if DeviceHelper.currentLayout == .iPadOrMac {
            lines.append("右侧标签页如果正开着它，删完请点标签上的 × 关掉。")
        }
        return lines.joined(separator: "\n\n")
    }

    /// 真正动手删。
    ///
    /// - Returns: 删成功回 true；失败会弹一句提示，让用户知道「没删掉」而不是以为删了
    @discardableResult
    private func performDelete(_ url: URL) -> Bool {
        let isDirectory = DocumentsWorkspace.isDirectory(url)

        do {
            // 走 deleteFile 而不是直接调 DocumentsWorkspace：测试要能换成「直接删」
            try deleteFile(url)
        } catch {
            showAlert(title: "删不掉",
                      message: "「\(url.lastPathComponent)」没能删掉：\(error.localizedDescription)")
            return false
        }

        if isDirectory {
            // 文件夹里所有文档一起没了：两本按路径记的账都要整片清掉
            DocumentScrollMemory.shared.forgetAll(underPrefix: url.path)
            RecentDocumentsStore.shared.removeAll(underPrefix: url.path)
            // 用户正停在这个文件夹里（或它下面）时，退回文档根目录
            resetCurrentDirectoryIfDeleted(url)
        } else {
            // 顺手忘掉「这份文档上次读到哪儿」：文件名以后可能被重新用上，那时不该莫名其妙跳到文档中间
            DocumentScrollMemory.shared.forget(key: url.path)
        }

        // 说一声，列表自己会重新扫一遍目录（照旧走通知这一条路，别在这儿直接刷）
        NotificationCenter.default.post(name: DocumentsWorkspace.didChangeNotification, object: nil)
        return true
    }

    /// 当前目录正好在被删掉的文件夹里（或就是它本人）时，退回文档根目录。
    private func resetCurrentDirectoryIfDeleted(_ url: URL) {
        guard source == .documents else { return }
        let prefix = url.standardizedFileURL.path
        let current = currentDirectory.standardizedFileURL.path
        guard current == prefix || current.hasPrefix(prefix + "/") else { return }

        currentDirectory = DocumentsWorkspace.folderURL
        updateBreadcrumb()
        reloadFiles()
    }

    // MARK: - 最近页：移除 / 清空

    /// 右键（iPad 上长按）弹出的菜单。
    ///
    /// 抽成单独的方法是为了能单测 —— 不然测试得先伪造一次右键事件才能看到菜单长什么样。
    func removeMenu(for url: URL) -> UIMenu {
        let remove = UIAction(title: "从最近打开中移除",
                              image: UIImage(systemName: "xmark.circle"),
                              attributes: .destructive) { [weak self] _ in
            self?.remove(url)
        }
        // 标题里就把「文件不会没」说清楚：这一页的删除只动记录，
        // 用户最担心的恰恰是「我是不是把文件删了」
        return UIMenu(title: "\(DocumentsWorkspace.displayName(for: url))\n（只从列表里去掉，文件还在）",
                      children: [remove])
    }

    /// 从记录里去掉一份（**不动磁盘上的文件**，所以不用弹确认框——移错了再打开一次就回来了）
    func remove(_ url: URL) {
        RecentDocumentsStore.shared.remove(url)
        reloadFiles()
    }

    /// 「清空」按钮：一次把全部记录抹掉，所以先问一句。
    ///
    /// 这里同样**不动任何文件**，确认框里得说明白，别把人吓着。
    @objc private func clearAllTapped() {
        guard source == .recent, !allFiles.isEmpty else { return }
        let alert = UIAlertController(
            title: "清空最近打开？",
            message: "「最近打开」这一页会变成空的。\n\n这只是把记录清掉，文档目录里的文件一份都不会动。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
            self?.performClearAll()
        })
        present(alert, animated: true)
    }

    /// 确认框里点了「清空」之后真正要做的事（单独抽出来是为了能单测）
    func performClearAll() {
        RecentDocumentsStore.shared.removeAll()
        reloadFiles()
    }

    // MARK: - 小工具

    private static let cellIdentifier = "DocumentListCell"

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        presentAlert(alert)
    }

    /// 弹框要落在用户正看着的那一页上。
    ///
    /// iPhone 上编辑页 push 上来之后，左栏列表还在导航栈底下；直接拿列表去
    /// `present` 会报「不在窗口层级里」。这时改由导航栈当前可见的页面来弹。
    /// 已经 present 了别的页面（设置、选择器）就继续往上找最顶上的那个。
    private var alertPresenter: UIViewController {
        var top: UIViewController = self
        if let navigationController,
           let visible = navigationController.visibleViewController,
           visible !== self {
            top = visible
        }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    private func presentAlert(_ alert: UIAlertController) {
        alertPresenter.present(alert, animated: true)
    }
}

// MARK: - 搜索

extension DocumentListViewController: UISearchBarDelegate {

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        // 每敲一个字就过滤一次：文件列表通常不大，不用加防抖
        applySortAndFilter()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}

// MARK: - 表格数据源

extension DocumentListViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        files.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellIdentifier, for: indexPath)
        // 上面注册的就是 DocumentListCell，这里一定转得成；真转不成说明那行注册被改坏了
        guard let documentCell = cell as? DocumentListCell else { return cell }

        let entry = files[indexPath.row]
        if let info = rowCache.cached(for: entry.url) {
            // 已经读好的：纯内存操作，这一格不再碰盘
            documentCell.configure(name: info.name,
                                   preview: info.preview,
                                   date: info.date,
                                   isDirectory: entry.isDirectory)
        } else {
            // 还没读过：先把能立刻给出去的填上（名字 + 扫描时顺手读到的日期），副标题留空，交给后台读完再回填。⚠️ 这里千万别同步读盘 —— 一滚列表就会卡
            documentCell.configure(name: entry.name,
                                   preview: nil,
                                   date: entry.modifiedDate,
                                   isDirectory: entry.isDirectory)
            requestRowInfo(for: entry)
        }
        // cell 会被复用，所以每次都要按当前高亮状态重新上色。文件夹不是「当前编辑的那一份」，永远不点亮
        documentCell.setHighlighted(!entry.isDirectory && entry.url.path == highlightedItemID)
        return documentCell
    }

    /// 让后台把这一行的副标题读出来，读完回填到对应单元格上。
    ///
    /// 读完时列表可能已经换了内容（重扫、搜索、切目录、排序），所以**按路径重新找行**，而不是拿老的下标去填 —— 下标早就指向别人了。找不到（被过滤掉、行不在屏幕上）就什么都不做，值已经进了缓存，下次滚回来直接用。
    private func requestRowInfo(for entry: DocumentsWorkspace.Entry) {
        rowCache.request(for: entry) { [weak self] info in
            guard let self,
                  let row = self.files.firstIndex(where: { $0.url.path == entry.url.path }),
                  let cell = self.tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? DocumentListCell
            else { return }
            cell.configure(name: info.name,
                           preview: info.preview,
                           date: info.date,
                           isDirectory: entry.isDirectory)
            cell.setHighlighted(!entry.isDirectory && entry.url.path == self.highlightedItemID)
        }
    }

    /// ⚠️ 这里**故意不打开文档**。
    ///
    /// 「打开」是上面那两把手势负责的（要区分单击 / 双击）。如果这里也开一次，
    /// 一次点击就会开两遍。所以这里只把选中态收掉 —— 顺手也给了「按下」的视觉反馈。
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }

    // MARK: - 滚动条

    /// 滚动中：先把那根条摆到新位置，再让它亮着。
    ///
    /// 惯性滑行阶段这个方法也在被调用，所以「停手之后」不用另外监听减速结束 ——
    /// 真停下来时不会再调这里，`scrollIndicatorFadeOutWorkItem` 那份待办才轮得到执行
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateScrollIndicator()
        showScrollIndicator()
        scheduleScrollIndicatorFadeOut()
    }

    // MARK: - 右键菜单

    /// Mac 上**右键**、iPad / iPhone 上**长按**弹出的菜单，就是走这里。
    ///
    /// （Catalyst 把「次要点击」翻译成 UIKit 的上下文菜单，所以同一个方法在两处都生效。）
    func tableView(_ tableView: UITableView,
                   contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        guard files.indices.contains(indexPath.row) else { return nil }
        let url = files[indexPath.row].url
        // previewProvider 传 nil：不要那个「按下去浮起一张预览图」的效果，
        // 右键列表就想要一个干脆的菜单
        return UIContextMenuConfiguration(identifier: url.path as NSString,
                                          previewProvider: nil) { [weak self] _ in
            self?.contextMenu(for: url)
        }
    }

    /// 手指往左滑：文档页是删除，最近页是移除记录 —— iPhone / iPad 上没有右键，这是那边的入口
    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard files.indices.contains(indexPath.row) else { return nil }
        let url = files[indexPath.row].url

        let action: UIContextualAction
        switch source {
        case .documents:
            action = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
                guard let self else {
                    completion(false)
                    return
                }
                // 要等用户点完确认框才知道到底删没删，所以 completion 得挂在确认结果上
                self.confirmDelete(url) { didDelete in completion(didDelete) }
            }
            action.image = UIImage(systemName: "trash")
        case .recent:
            action = UIContextualAction(style: .destructive, title: "移除") { [weak self] _, _, completion in
                self?.remove(url)
                completion(true)
            }
            action.image = UIImage(systemName: "xmark.circle")
        }

        let configuration = UISwipeActionsConfiguration(actions: [action])
        // 一滑到底就直接执行太容易手滑（文档页还要弹确认框），关掉
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}
