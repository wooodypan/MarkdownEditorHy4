//
//  DocumentListViewController.swift
//  MarkdownEditorHy4
//
//  左栏：Documents 目录里的文件列表。点一份文件 → 右侧开一个 Tab 编辑它。
//

import UIKit
import MultiTabController

/// 左侧栏 —— 列 Documents 目录里的文档。
///
/// ### 它只负责「报告用户想打开哪一份」
/// 点一份文件之后到底发生什么（iPhone 上 push 一页、iPad / Mac 上在右侧开 Tab），
/// 由注入的 `router` 决定（`PPContentRouting`）。列表自己不关心设备环境，
/// 这样同一份列表在三种形态下是同一份代码。
///
/// ### 单击 / 双击的两种「打开」
/// 跟 `MultiTabController` 的示例一致，对应它那套类 VS Code 的 Tab 策略：
/// - **单击** → 预览（`preview`）：右侧复用那个「预览槽位」，不会开一堆 Tab；
/// - **双击** → 正式打开（`newTab`）：永远新开一个，不被后面的预览顶掉。
///
/// 所以「随手看看」用单击，「这份我要一直开着」用双击。
///
/// ### 删除
/// **Mac 上对着某一行点右键**（iPad 上是长按）→ 菜单里选「删除」；
/// iPhone 上没有右键，改成**往左滑**那一行。两条路都会先弹一次确认框，
/// 删掉的文件在 Mac 上会进系统废纸篓（还能捞回来），手机上就是真删了。
final class DocumentListViewController: UIViewController {

    /// 「打开一份文档」的出口。iPhone / iPad / Mac 三种环境注入不同实现
    var router: PPContentRouting?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()

    /// 当前列出来的文件，按显示顺序
    private var files: [URL] = []

    /// 冷启动时那个「该不该自动打开第一份文档」只做一次
    private var didOpenInitialDocument = false

    /// 真正动手「把一个文件删掉」的那一下。默认走 `DocumentsWorkspace.delete`
    /// （Mac 上先进系统废纸篓，手机上直接删）。
    ///
    /// **这是给测试留的替换口**：测试里会换成「直接删临时目录里的文件」，
    /// 免得跑一次测试就往用户的废纸篓里丢一个文件（`DocumentsWorkspace.delete`
    /// 的注释里有同样的警告）。
    var deleteFile: (URL) throws -> Void = { try DocumentsWorkspace.delete($0) }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "文档"
        view.backgroundColor = .systemBackground

        setupTableView()
        setupEmptyLabel()
        setupNavigationBar()
        setupTapGestures()
        observeWorkspaceChanges()

        reloadFiles()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 用户在「文件」App / Finder 里往这个目录丢了东西，切回来就能看到
        reloadFiles()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 放在 viewDidAppear 而不是 viewDidLoad：这时候外层分栏容器的视图已经装好了，
        // 右侧的 Tab 宿主也已经就位，开 Tab 才是安全的（早于此时机开 Tab 会让
        // 宿主在「视图还没加载」的状态下插入条目）
        openInitialDocumentIfNeeded()
    }

    // MARK: - 界面

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 46
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellIdentifier)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    /// 一份文件都没有时的说明文字 —— 空白列表很容易被当成「卡住了」
    ///
    /// ### 为什么两个平台要分开写
    /// 开了 App 沙盒之后，这个文档目录藏在 App 自己的容器里，两个平台「把文件弄进来」
    /// 的办法也就不一样了：
    /// - Mac 上 Finder 里不方便直接拖到容器里，教用户走「文件 > 打开…」（⌘O）；
    /// - iPhone / iPad 上靠 Info.plist 的 `UIFileSharingEnabled` 把这个目录露在
    ///   「文件」App 里，直接往里丢就行。
    private func setupEmptyLabel() {
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        #if targetEnvironment(macCatalyst)
        emptyLabel.text = "这个目录里还没有文档\n\n用「文件 > 打开…」把硬盘上的 .md 打开，\n或者点右上角的「+」新建一份。"
        #else
        emptyLabel.text = "这个目录里还没有文档\n\n把 .md 文件放进「文件」App\n的 MarkdownEditorHy4 文件夹，\n或者点右上角的「+」新建一份。"
        #endif
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
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(createNewDocument)
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = "新建文档"
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
        files = DocumentsWorkspace.documentURLs()
        tableView.isHidden = files.isEmpty
        emptyLabel.isHidden = !files.isEmpty
        tableView.reloadData()
    }

    /// 通知：目录变了 / 有人要新建 / 有外部文件要打开
    private func observeWorkspaceChanges() {
        let center = NotificationCenter.default
        center.addObserver(self,
                           selector: #selector(workspaceDidChange),
                           name: DocumentsWorkspace.didChangeNotification,
                           object: nil)
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
        guard let url = notification.object as? URL else { return }
        open(url, mode: .newTab)
    }

    // MARK: - 打开 / 新建

    /// 冷启动时该不该自己开一份。
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
        guard DeviceHelper.currentLayout == .iPadOrMac, let first = files.first else { return }
        open(first, mode: .preview)
    }

    /// 把一份磁盘文件交给右侧编辑
    private func open(_ url: URL, mode: PPContentOpenMode) {
        guard let item = contentItem(for: url) else {
            showAlert(title: "打不开文件",
                      message: "「\(url.lastPathComponent)」读不出来，可能被删掉或者没有访问权限。")
            reloadFiles()
            return
        }
        router?.open(item, mode: mode)
    }

    /// 把磁盘文件变成库认识的内容项。
    ///
    /// 内容**当场就读出来塞进 `body`**，不让编辑页自己去读：这样「读失败」在这里就能拦住，
    /// 不会出现「编辑页拿到空内容 → 一保存就把用户的原文件清空」这种事故。
    private func contentItem(for url: URL) -> PPContentItem? {
        guard let text = DocumentsWorkspace.read(url) else { return nil }
        return PPContentItem(id: url.path,
                             title: DocumentsWorkspace.displayName(for: url),
                             body: text,
                             // 左侧栏只有一个平铺列表，用不上分组。留着这个字段是为了
                             // 以后要按子目录 / 标签分组时不用改协议
                             category: "Documents")
    }

    /// 新建一份空白文档，并立刻在右侧开个新 Tab 编辑它。
    ///
    /// 文件是**先落到磁盘**的，所以左侧栏立刻就能看到 ——
    /// 不搞「内存里的草稿」那种中间态，⌘S 也就永远有地方写。
    ///
    /// 这会儿它还顶着「未命名」这个占位名；等用户在右栏第一次按 ⌘S，
    /// 编辑页会弹框请他起个正式名字（见 `MarkdownDocumentViewController.saveDocument`）。
    @objc private func createNewDocument() {
        do {
            let url = try DocumentsWorkspace.createEmptyDocument()
            NotificationCenter.default.post(name: DocumentsWorkspace.didChangeNotification, object: nil)
            open(url, mode: .newTab)
        } catch {
            showAlert(title: "新建失败", message: error.localizedDescription)
        }
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              let url = fileURL(at: gesture) else { return }
        // iPhone 上没有「预览槽位」这个概念（它是导航栈），开新 Tab 就等于 push 一页。
        // 这个判断跟库里示例的写法一致
        let mode: PPContentOpenMode = DeviceHelper.currentLayout == .iPadOrMac ? .preview : .newTab
        open(url, mode: mode)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              // 双击「正式打开」只在有 Tab 的环境里有意义；iPhone 上忽略
              DeviceHelper.currentLayout == .iPadOrMac,
              let url = fileURL(at: gesture) else { return }
        open(url, mode: .newTab)
    }

    private func fileURL(at gesture: UITapGestureRecognizer) -> URL? {
        guard let indexPath = tableView.indexPathForRow(at: gesture.location(in: tableView)),
              files.indices.contains(indexPath.row) else { return nil }
        return files[indexPath.row]
    }

    // MARK: - 删除

    /// 「删除」那一项菜单。抽成单独的方法是为了能单测 ——
    /// 不然测试得先伪造一次右键事件才能看到菜单长什么样。
    func deleteMenu(for url: URL) -> UIMenu {
        let delete = UIAction(title: "删除",
                              image: UIImage(systemName: "trash"),
                              // destructive：菜单里显示成红色，先给用户一个「这一步不可逆」的暗示
                              attributes: .destructive) { [weak self] _ in
            self?.confirmDelete(url)
        }
        // 菜单顶上的小标题用文件名：右键的时候正好再确认一眼点的是哪一份
        return UIMenu(title: DocumentsWorkspace.displayName(for: url), children: [delete])
    }

    /// 删之前先问一句。这是**不可逆**的操作（Mac 上还能从废纸篓捞，手机上就是没了）。
    ///
    /// - Parameter completion: 真删掉了回 true。滑动手势要靠它决定「这一行收不收回原位」。
    private func confirmDelete(_ url: URL, completion: ((Bool) -> Void)? = nil) {
        let alert = UIAlertController(title: "删除「\(DocumentsWorkspace.displayName(for: url))」？",
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

    /// 确认框里那两句话：一句说「文件去哪儿了」，一句说「删完右侧那个标签页怎么办」
    private func deletionWarning(for url: URL) -> String {
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
        do {
            // 走 deleteFile 而不是直接调 DocumentsWorkspace：测试要能换成「直接删」
            try deleteFile(url)
        } catch {
            showAlert(title: "删不掉",
                      message: "「\(url.lastPathComponent)」没能删掉：\(error.localizedDescription)")
            return false
        }

        // 顺手忘掉「这份文档上次读到哪儿」：文件名以后可能被重新用上，
        // 那时不该莫名其妙跳到文档中间
        DocumentScrollMemory.shared.forget(key: url.path)

        // 说一声，列表自己会重新扫一遍目录（照旧走通知这一条路，别在这儿直接刷）
        NotificationCenter.default.post(name: DocumentsWorkspace.didChangeNotification, object: nil)
        return true
    }

    // MARK: - 小工具

    private static let cellIdentifier = "DocumentListCell"

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - 表格数据源

extension DocumentListViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        files.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellIdentifier, for: indexPath)
        let url = files[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = DocumentsWorkspace.displayName(for: url)
        content.image = UIImage(systemName: "doc.text")
        // 只有一行字：文件名**去掉扩展名**（这里所有文件都是 md，后缀只是噪音）。
        // 不再加一行「secondary text」写完整文件名 —— 那跟上面那行几乎一模一样，看着是重复的
        cell.contentConfiguration = content
        return cell
    }

    /// ⚠️ 这里**故意不打开文档**。
    ///
    /// 「打开」是上面那两把手势负责的（要区分单击 / 双击）。如果这里也开一次，
    /// 一次点击就会开两遍。所以这里只把选中态收掉 —— 顺手也给了「按下」的视觉反馈。
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }

    // MARK: - 删除

    /// Mac 上**右键**、iPad 上**长按**弹出的菜单，就是走这里。
    ///
    /// （Catalyst 把「次要点击」翻译成 UIKit 的上下文菜单，所以同一个方法在两处都生效。）
    func tableView(_ tableView: UITableView,
                   contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        guard files.indices.contains(indexPath.row) else { return nil }
        let url = files[indexPath.row]
        // previewProvider 传 nil：不要那个「按下去浮起一张预览图」的效果，
        // 右键列表就想要一个干脆的菜单
        return UIContextMenuConfiguration(identifier: url.path as NSString,
                                          previewProvider: nil) { [weak self] _ in
            self?.deleteMenu(for: url)
        }
    }

    /// 手指往左滑也能删 —— iPhone / iPad 上没有右键，这是那边唯一的入口
    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard files.indices.contains(indexPath.row) else { return nil }
        let url = files[indexPath.row]

        let action = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            guard let self else {
                completion(false)
                return
            }
            // 要等用户点完确认框才知道到底删没删，所以 completion 得挂在确认结果上
            self.confirmDelete(url) { didDelete in completion(didDelete) }
        }
        action.image = UIImage(systemName: "trash")

        let configuration = UISwipeActionsConfiguration(actions: [action])
        // 一滑到底就直接删太容易手滑（何况还要弹确认框），关掉
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}
