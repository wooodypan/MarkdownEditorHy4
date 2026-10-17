//
//  RecentDocumentsViewController.swift
//  MarkdownEditorHy4
//
//  左栏的第二个 Tab：最近打开过的文档。
//

import UIKit
import MultiTabController

/// 「最近打开」那一页。
///
/// ### 它和「文档」那一页的关系
/// 两页长得像、手势也一样（单击预览 / 双击正式打开），但**列的东西不一样**：
/// - 「文档」列的是磁盘目录里现在有什么（扫目录得来的）；
/// - 「最近」列的是**你打开过什么**（一份记在缓存里的流水账，跟目录现在的样子无关）。
///
/// 所以一份文档可以在「最近」里、但已经不在「文档」里 —— 那就是「你打开过、后来被删了」。
/// 启动时会把这类记录清掉（见 `RecentDocumentsStore`），正在用的时候被删掉的话，
/// 这一页刷新一次它就会自己消失。
///
/// ⚠️ **这一页上的「删除」删的是记录，不是文件**：
/// 文件本身安安稳稳地待在文档目录里，要删那份请去「文档」那一页。
/// 界面上每个菜单都写明了这一点，别让人以为点一下文件就没了。
final class RecentDocumentsViewController: UIViewController {

    /// 「打开一份文档」的出口。和「文档」那一页共用同一个路由（由 `WorkspaceCoordinator` 注入）
    var router: PPContentRouting?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()

    /// 当前列出来的文件，按「最近打开」排在最前面
    private var files: [URL] = []

    // MARK: - 选中行高亮（与右侧选中的 Tab 联动）

    /// 当前高亮行的内容 id —— 就是 `PPContentItem.id`，也就是文件路径（见 `DocumentOpening`）
    private(set) var highlightedItemID: String?

    /// 这一页里有没有这条内容。右栏切换 Tab、联动高亮时用它判断该亮哪一页
    func containsItem(withID id: String) -> Bool {
        files.contains { $0.path == id }
    }

    /// 设置 / 清除高亮行（传 `nil` 清除）。
    ///
    /// - Parameter scrollToSelection: 目标行不在屏幕内时要不要滚过去。
    ///   自己点击时传 false（本来就在眼前）；右侧切 Tab 联动时传 true，更接近 VS Code。
    func setHighlightedItemID(_ id: String?, scrollToSelection: Bool = false) {
        guard id != highlightedItemID else { return }
        highlightedItemID = id
        // 视图还没加载时只记状态，首次 `cellForRowAt` 会按它上色
        guard isViewLoaded else { return }
        applyHighlight(scrollToSelection: scrollToSelection)
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
              let row = files.firstIndex(where: { $0.path == id }) else { return nil }
        return IndexPath(row: row, section: 0)
    }

    private func updateHighlightAppearance(of cell: UITableViewCell, at indexPath: IndexPath) {
        (cell as? DocumentListCell)?.setHighlighted(files[indexPath.row].path == highlightedItemID)
    }

    private static let cellIdentifier = "RecentDocumentCell"

    // MARK: - 生命周期

    init() {
        super.init(nibName: nil, bundle: nil)
        // ⚠️ 导航条按钮放在 init 里配，而不是 viewDidLoad：
        // 这一页是挂在 PPTabBarController 里面的，外层导航条要拿它这颗「清空」按钮
        // （理由见 WorkspaceCoordinator.syncNavigationItem），那时候它的 view 还没加载
        setupNavigationBar()
    }

    required init?(coder: NSCoder) {
        fatalError("RecentDocumentsViewController 不支持从 coder 解档")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "最近打开"
        view.backgroundColor = .systemBackground

        setupTableView()
        setupEmptyLabel()
        setupTapGestures()
        observeWorkspaceChanges()

        reloadFiles()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 从别的页切回来时重列一次：期间可能打开过别的文档
        reloadFiles()
    }

    // MARK: - 界面

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        // 和「文档」那一页一样：行高按三行字（标题 / 预览 / 修改日期）自动算，
        // 字号跟着系统的「文字大小」变，写死数字会挤住字
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 76
        tableView.register(DocumentListCell.self, forCellReuseIdentifier: Self.cellIdentifier)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupEmptyLabel() {
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.text = "还没有打开过文档\n\n在「文档」那一页点一份，\n它就会出现在这里。"
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
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "清空",
                                                            style: .plain,
                                                            target: self,
                                                            action: #selector(clearAllTapped))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "清空最近打开"
    }

    /// 单击 / 双击两把手势，和「文档」那一页完全一致。
    ///
    /// ⚠️ `singleTap.require(toFail: doubleTap)` 这一行不能少：
    /// 少了的话，双击的第二下会先被当成一次单击，右侧会平白多出一个 Tab。
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
        files = RecentDocumentsStore.shared.recentURLs()
        // 高亮的那份如果已经不在列表里（记录被移除），别让状态一直挂着一个不存在的路径
        if let id = highlightedItemID, !files.contains(where: { $0.path == id }) {
            highlightedItemID = nil
        }
        tableView.isHidden = files.isEmpty
        emptyLabel.isHidden = !files.isEmpty
        // 一条记录都没有时，「清空」这个按钮按下去也没意义，直接置灰
        navigationItem.rightBarButtonItem?.isEnabled = !files.isEmpty
        tableView.reloadData()
    }

    private func observeWorkspaceChanges() {
        // 目录里的文件增删改了 → 重列一次（被删掉的那份会从这一页消失）
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(workspaceDidChange),
                                               name: DocumentsWorkspace.didChangeNotification,
                                               object: nil)
    }

    @objc private func workspaceDidChange() {
        reloadFiles()
    }

    // MARK: - 打开

    private func open(_ url: URL, mode: PPContentOpenMode) {
        guard DocumentOpening.open(url, mode: mode, using: router) else {
            showAlert(title: "打不开文件",
                      message: "「\(url.lastPathComponent)」读不出来，可能被删掉或者没有访问权限。")
            reloadFiles()
            return
        }
        // 打开成功就点亮这一行；iPad / Mac 上右侧切 Tab 时还会由
        // `onSelectedItemChanged` 再同步一次（幂等）
        setHighlightedItemID(url.path)
        // 打开过之后这份会重新排到最前面，列表顺序得跟着变
        reloadFiles()
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let url = fileURL(at: gesture) else { return }
        // iPhone 上没有「预览槽位」（它是导航栈），开新 Tab 就等于 push 一页
        let mode: PPContentOpenMode = DeviceHelper.currentLayout == .iPadOrMac ? .preview : .newTab
        open(url, mode: mode)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              DeviceHelper.currentLayout == .iPadOrMac,
              let url = fileURL(at: gesture) else { return }
        open(url, mode: .newTab)
    }

    private func fileURL(at gesture: UITapGestureRecognizer) -> URL? {
        guard let indexPath = tableView.indexPathForRow(at: gesture.location(in: tableView)),
              files.indices.contains(indexPath.row) else { return nil }
        return files[indexPath.row]
    }

    // MARK: - 移除 / 清空

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
        guard !files.isEmpty else { return }
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

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - 表格数据源

extension RecentDocumentsViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        files.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellIdentifier, for: indexPath)
        // 和「文档」那一页共用同一个 cell：标题、首行预览、修改日期，样式自然一致
        guard let documentCell = cell as? DocumentListCell else { return cell }
        let url = files[indexPath.row]
        documentCell.configure(name: DocumentsWorkspace.displayName(for: url),
                               preview: DocumentsWorkspace.previewText(of: url),
                               date: DocumentsWorkspace.modificationDate(of: url))
        // cell 会被复用，所以每次都要按当前高亮状态重新上色
        documentCell.setHighlighted(url.path == highlightedItemID)
        return documentCell
    }

    /// ⚠️ 这里**故意不打开文档** —— 打开归上面那两把手势管（要区分单击 / 双击），
    /// 这儿再开一次就会开两遍
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }

    // MARK: 移除

    /// Mac 上**右键**、iPad 上**长按**弹出的菜单走这里
    func tableView(_ tableView: UITableView,
                   contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        guard files.indices.contains(indexPath.row) else { return nil }
        let url = files[indexPath.row]
        return UIContextMenuConfiguration(identifier: url.path as NSString,
                                          previewProvider: nil) { [weak self] _ in
            self?.removeMenu(for: url)
        }
    }

    /// 手指往左滑也能移除 —— iPhone / iPad 上没有右键，这是那边唯一的入口
    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard files.indices.contains(indexPath.row) else { return nil }
        let url = files[indexPath.row]

        let action = UIContextualAction(style: .destructive, title: "移除") { [weak self] _, _, completion in
            self?.remove(url)
            completion(true)
        }
        action.image = UIImage(systemName: "xmark.circle")

        let configuration = UISwipeActionsConfiguration(actions: [action])
        // 一滑到底就直接移除太容易手滑，关掉
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}
