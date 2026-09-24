//
//  MarkdownDocumentViewController.swift
//  MarkdownEditorHy4
//
//  「一份文档」这一页：markdown 编辑器 + 悬浮目录 + 右上角「⋯」菜单
//  （重载 / 分块 / 源码 / 校验 / 导出成图片 / 设置）。
//  Mac 上另有菜单栏：文件 > 新建 / 打开 / 存储。
//
//  ### 它是右侧多 Tab 里的**内容页**
//  自己不决定「我是第几个 Tab、什么时候被关掉」——那些由 `MultiTabController` 的
//  详情宿主（`DetailHostViewController`）管。它只需要满足库要求的 `PPContentDisplaying`：
//  能被一份内容项配置（`configure(with:)`）、能拿到一个上报通道（`contentHost`）。
//
//  ### 它同时是「Command 键命令」的落点
//  ⌘N / ⌘O / ⌘S 都是靠响应链找到当前这一页的：**哪个 Tab 在前台，命令就作用在它身上** ——
//  这正是多 Tab 编辑该有的行为，不需要额外写「当前 Tab 是哪个」的分发逻辑。
//

import UIKit
// 菜单里的「打开」要判断哪些文件可选，用到 UTType.markdown
import UniformTypeIdentifiers
// 点图片弹系统预览（QLPreviewController）
import QuickLook
import MultiTabController

/// ⚠️ `PPContentDisplaying` 必须写在类型声明上，不能只写个 extension：内容页工厂的闭包
/// 声明成「返回 `PPContentDisplaying`」，少了这一致性，闭包体里那个 `MarkdownDocumentViewController()`
/// 就转换不过去 —— 编译器报的却是一句很难懂的
/// `unable to infer closure type without a type annotation`（指着一整个闭包，看不出真正的问题）。
final class MarkdownDocumentViewController: UIViewController, PPContentDisplaying {

    // MARK: 与多 Tab 宿主的连接

    /// 宿主注入的上报通道。
    ///
    /// ⚠️ 必须 `weak`：宿主强引用着每一个 Tab 的内容页（这是「保活」的实现方式），
    /// 这里再强引用回去就成了循环引用，Tab 关掉也放不掉。
    weak var contentHost: PPContentHosting?

    /// 有人在我还是「预览 Tab」的时候改了我 → 告诉宿主把我固定成正式 Tab。
    ///
    /// 只报一次，也**只报 true**：宿主那边的约定是「收到 true 就把这一页固定下来，
    /// 收到 false 就把预览标记还回去」。如果保存之后顺手报一个 false，
    /// 用户双击开出来的那个正式 Tab 会被降级回预览，被下一次单击顶掉 —— 那就反了。
    private var didReportEdited = false

    /// 内容项可能在 `viewDidLoad` **之前**就送到了（宿主要先建好 Tab 才会显示它）。
    /// 先存下来，等界面搭好再套用 —— 这也是库在 `PPContentDisplaying` 里写明的约定
    private var pendingItem: PPContentItem?

    // MARK: 子视图

    private let editor = MarkdownTextView()
    private let statusLabel = UILabel()
    /// 右上角的「⋯」按钮。点一下弹出菜单，里面装着重载 / 分块 / 源码 / 校验
    private let menuButton = UIButton(type: .system)
    /// 悬浮目录面板（纯 UI 层，不认识编辑器）
    private let outlineView = MarkdownOutlineView()
    /// 大纲协调者：把编辑器和目录面板连起来
    private let outlineCoordinator = OutlineCoordinator()
    /// 顶部的查找 / 替换横条（纯 UI 层，不认识编辑器）
    private let findBar = MarkdownFindBarView()
    /// 查找协调者：把编辑器和查找横条连起来
    private let searchCoordinator = SearchCoordinator()
    /// 用户配置（「记住目录大纲滚动位置」等）。改完会发通知，下面挂了监听同步给大纲面板
    private let settings = MarkdownEditorSettings.shared
    /// 每份文档「上次读到哪儿」的记忆
    private let scrollMemory = DocumentScrollMemory.shared
    private var bottomConstraint: NSLayoutConstraint?

    /// 当前这一页对应磁盘上的哪个文件 —— 也就是 ⌘S 要写回哪里。
    ///
    /// 正常情况下一定有值（每个 Tab 都是被某一份文件开出来的）。为 nil 只有一种情形：
    /// 宿主没送内容项就直接把我显示出来了（不该发生），这时按「未命名」对待、
    /// ⌘S 会提示没有可保存的文件。
    private var openedFileURL: URL?
    /// 上次打开/保存时的源码快照，和它比对就知道有没有改动
    private var savedSource = ""
    /// 有没有未保存的改动
    private var isDirty: Bool { editor.markdownSource != savedSource }
    /// 临时提示（比如「已保存」）显示完要恢复成常规状态栏
    private var statusResetWork: DispatchWorkItem?
    /// 当前弹出的文件选择器是不是「导出成图片」用途（Mac）
    private var isExportingImage = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // 顺序有讲究：菜单按钮先建好（正文、大纲、查找条都挂在它下面）
        setupMenuButton()
        setupEditor()
        setupStatusLabel()
        // 套用宿主送来的内容项。到这一步才做，是因为下面的界面这时才建好 ——
        // 而且大纲的「初次拉取」也依赖文档已经装进去了
        if let item = pendingItem {
            apply(item)
        }
        // 放在文档加载**之后**：装配时的「初次拉取」才能真正拉到标题。
        // 放前面也能跑（编辑器那次 push 会被忽略），但会白拉一次空列表。
        // 这里也顺带把用户存过的字号 / 行高 / 段间距套上去 —— 文档刚才是用默认主题
        // 渲进去的，不补这一下，改过设置的人下次启动会看到「开头那几秒是默认字号」
        applyEditorStyle()
        setupOutline()
        // 查找条放在最后：它是浮层，后加的视图画在上面，这样它才盖得住正文和大纲面板
        setupFindBar()
        observeKeyboard()
        observeEditorChanges()
        observeSettingsChanges()
        // 离开前台时把「读到哪儿」记一笔（用户常常是随手切走、再也没回来）
        observeAppLifecycle()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 窗口（windowScene）要等 view 挂上去才有，标题在这里补一次
        updateWindowTitle()
    }

    // MARK: 界面搭建

    private func setupEditor() {
        editor.translatesAutoresizingMaskIntoConstraints = false
        // 粘贴的图片存到 Documents，bundle 里的 sample.png 走兜底逻辑也能找到
        editor.imageBaseURL = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first
        view.addSubview(editor)

        bottomConstraint = editor.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            // 上边直接钉在菜单栏下面 —— 跟查找条无关，查找条出现 / 消失正文都不会动
            editor.topAnchor.constraint(equalTo: menuButton.bottomAnchor, constant: 2),
            editor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint!
        ])

        // 点正文里的图片 → 弹 QuickLook 预览。
        // 编辑器只负责认出「点到了哪张图」，弹窗得由能 present 的这一层来做
        editor.onImageTapped = { [weak self] attachment in
            self?.previewImage(attachment)
        }
    }

    // MARK: 查找 / 替换

    /// 铺查找条，并把 **编辑器 — 协调者 — 查找条** 三者接起来。
    ///
    /// 装配代码放在这里的原因和 `setupOutline` 完全一样：协调者刻意不在编辑器或者查找条内部创建，那样组件之间就互相认识了。把这层连接集中在这一处，两个组件各自的初始化都不需要对方的实例。
    ///
    /// ### 它是怎么做到「出现 / 消失都不挪动正文」的
    /// 横条**浮**在正文上面：位置固定在菜单栏下面，显示与否只切 `isHidden`，高度完全不参与排版。
    /// 正文的上边直接钉在菜单栏下面（不挂在查找条下边），所以横条出现时正文纹丝不动 ——代价是它会盖住正文最上面一小条，点查找时眼睛在查找框上，不影响使用。
    /// 两个前提别弄反：① 它必须在正文**之后**加进视图（后加的画在上面）；② 别再给它钉任何高度约束，高度由它自己里面的内容撑。
    private func setupFindBar() {
        findBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(findBar)

        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: menuButton.bottomAnchor, constant: 2),
            findBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -60)
        ])

        // 三根线：数据源、展示方、以及编辑器往外报「内容变了」的出口
        searchCoordinator.searchDataSource = editor
        searchCoordinator.findBar = findBar
        findBar.delegate = searchCoordinator
        editor.searchEventSink = searchCoordinator

        // 「把自己藏起来」是容器的事（查找条自己不认识容器），所以出口交回这里
        findBar.onDismiss = { [weak self] in self?.hideFindBar() }
    }

    /// 显示查找条（⌘F / 菜单里的「查找」都走到这里）
    @objc private func showFindBar() {
        guard findBar.isCollapsed else {
            // 已经开着：再按一次 ⌘F 就只是把焦点交还给查找框（常见的查找框行为）。
            // 但选中文字照样要填进去 —— 选了新词再按一次 ⌘F，多半就是想换个词找
            fillQueryFromSelection()
            findBar.beginSearch()
            return
        }
        // 先取消隐藏、再淡入。它的位置是固定的，动的只有透明度，所以正文一点都不会被挤
        findBar.setCollapsed(false)
        findBar.alpha = 0
        UIView.animate(withDuration: 0.15) { self.findBar.alpha = 1 }
        fillQueryFromSelection()
        findBar.beginSearch()
    }

    /// 把正文里选中的文字预填进查找框（没选中就什么都不做，保留上一次的查找词）
    private func fillQueryFromSelection() {
        guard let selected = editor.selectedSourceText else { return }
        findBar.fillQuery(selected)
    }

    /// 收起查找条：先撤焦点（免得键盘一直挂在它上面），再直接藏起来。
    ///
    /// 标 `@objc` 是为了让测试能直接驱动它（查找框那条关闭链路是异步的，测起来不方便）
    @objc private func hideFindBar() {
        guard !findBar.isCollapsed else { return }
        findBar.endSearch()
        findBar.setCollapsed(true)
        // 透明度还原成不透明，下次显示时才能从透明淡入
        findBar.alpha = 1
    }

    // MARK: 图片预览（QuickLook）

    /// 当前正在预览的那一项。
    ///
    /// ⚠️ 必须用属性**持有**着：QuickLook 是异步去取数据的，
    /// 预览窗还开着的时候这个对象不能已经释放了。
    private var previewItem: ImagePreviewItem?

    /// 弹出 QuickLook 预览。
    ///
    /// ### 为什么要先落到文件
    /// `QLPreviewController` 只认**文件 URL**，不认内存里的 `UIImage`。
    /// 本地图片本来就有文件，直接把地址给它；网络图片则先把已经下载好的图
    /// 写成一份临时 png 再给地址。
    private func previewImage(_ attachment: ImageAttachment) {
        guard let url = previewFileURL(for: attachment) else { return }
        previewItem = ImagePreviewItem(url: url, title: attachment.previewTitle)

        let controller = QLPreviewController()
        controller.dataSource = self
        present(controller, animated: true)
    }

    /// 给预览准备一个文件地址。
    private func previewFileURL(for attachment: ImageAttachment) -> URL? {
        // 本地图片直接用原文件，不动它
        if attachment.imageURL.isFileURL,
           FileManager.default.fileExists(atPath: attachment.imageURL.path) {
            return attachment.imageURL
        }
        // 网络图片（或者原文件已经不在了）：用已经加载好的那张图写一份临时文件
        guard let data = attachment.loadedImage?.pngData() else { return nil }
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("preview-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func setupStatusLabel() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 1
        statusLabel.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.9)
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            statusLabel.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    /// 悬浮目录：建视图 + **把编辑器、协调者、目录面板三者接起来**。
    ///
    /// ### 为什么装配代码必须在这里
    /// `OutlineCoordinator` 刻意不在编辑器或目录面板内部创建：
    /// - 编辑器内部创建 → 编辑器就认识了协调者，将来换协调者策略得改编辑器；
    /// - 目录面板内部创建 → 面板就得知道「去哪找编辑器」。
    ///
    /// 放在上层容器里，三者的生命周期和连接关系集中在这一处，
    /// 两个组件各自的初始化都不需要对方的实例。
    private func setupOutline() {
        outlineView.translatesAutoresizingMaskIntoConstraints = false
        // 浮在编辑器之上：加在 editor 后面，z 序自然在上层。
        // 它的点击只落在自己那块卡片上，卡片以外的手势照常透给编辑器
        view.addSubview(outlineView)

        NSLayoutConstraint.activate([
            // 贴在右上角「⋯」按钮下面，右边距和按钮对齐
            outlineView.topAnchor.constraint(equalTo: menuButton.bottomAnchor, constant: 6),
            outlineView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            // 兜底：窄屏上也要给左边留出位置。
            // 面板自己的宽度算法（effectiveWidth）保证这条永远不会被顶爆
            outlineView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12)
        ])

        // 三根线：数据源、展示方、事件出口
        outlineCoordinator.editorDataSource = editor
        outlineCoordinator.outlineView = outlineView
        outlineView.delegate = outlineCoordinator
        // 编辑器只拿到一个「事件出口」，它并不知道出口后面是协调者还是别的什么
        editor.outlineEventSink = outlineCoordinator

        // 默认收起：冷启动时右上角只留一个小方块（展开按钮），点它才展开整份目录。
        // 目录属于「想看的时候看一眼」的东西，默认摊开会一直占着正文右上角
        outlineView.setCollapsed(true, animated: false)
        // 按用户的配置定高度（默认「父视图高度的 70%」当上限）
        applyOutlineAppearance()

        // 主动要一次初次数据。文档这时已经加载完了，编辑器不会再有「标题变了」的通知；
        // 不主动拉的话目录会一直空着（编辑器里那次 push 发生时装配还没完成）
        outlineCoordinator.reloadFromEditor()
    }

    /// 页面右上角的「⋯」按钮。
    /// 原来这里是贴着状态栏的一排四个按钮（校验 / 源码 / 分块 / 重载），
    /// 现在全部收进弹出菜单，只留一个按钮，编辑区域更清爽
    private func setupMenuButton() {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "ellipsis.circle")
        config.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        // 图标本身不大，靠内边距把可点区域撑到 40x40，手指和鼠标都好点
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)

        menuButton.configuration = config
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        // 关键的一行：设为 true 后，单击就弹菜单，不需要长按等右键那一套
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = makeActionMenu()
        menuButton.accessibilityLabel = "更多操作"
        view.addSubview(menuButton)

        NSLayoutConstraint.activate([
            menuButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
            menuButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            menuButton.widthAnchor.constraint(equalToConstant: 40),
            menuButton.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    // MARK: 调试菜单项

    /// 「TextKit 调试层」开关（只在 Debug 版本里存在）。
    ///
    /// ### 为什么必须存成一个属性，而不是在 `makeActionMenu()` 里现造一个
    /// 菜单项左边的那个勾，是记在 **action 对象自己** 身上的（`UIAction.state`）。
    /// 每次弹菜单都新建一个 action 的话，勾会永远停在创建时的初始值 ——
    /// 明明已经打开了，菜单里却不显示勾，看着像「点了没反应」。
    /// 所以整个控制器生涯只用这一个实例，每次点击就地改它的 `state`。
    #if DEBUG
    private lazy var textKitDebugAction = UIAction(
        title: "TextKit 调试层",
        image: UIImage(systemName: "rectangle.dashed"),
        state: .off
    ) { [weak self] action in
        // 先把 self 解开：下面既要调编辑器，又要更新状态栏
        guard let self else { return }
        // 返回值就是「现在开着吗」：true = 刚装上，false = 刚摘掉
        let isOn = self.editor.installLineFragmentDebugOverlay()
        action.state = isOn ? .on : .off
        self.flashStatus(isOn ? "已显示：红=行框 蓝=usedRect 绿=附件 橙=容器" : "已隐藏 TextKit 调试层")
    }
    #endif

    /// 「视图描边」开关（只在 Debug 版本里存在）。
    ///
    /// 这就是网页里那句 `*{outline:1px dashed red}` 书签的等价物：递归走一遍窗口里的视图树，给每个 layer 描一圈极细的边，用来查「这个控件到底占了多大、有没有伸出父视图、谁盖住了谁」。
    ///
    /// 和上面那条一样，必须存成属性而不是每次现造一个 —— 勾（`UIAction.state`）是记在 action 对象自己身上的，新建一个就永远停在初始值。
    #if DEBUG
    private lazy var viewBordersAction = UIAction(
        title: "视图描边",
        image: UIImage(systemName: "square.dashed"),
        // 初始的勾按「现在是不是真描着边」来：`ViewBorders.installIfRequested` 那条环境变量 (`VIEW_BORDERS=1`) 的路子可能已经在启动时描上了，菜单里的勾得和实际状态一致，否则第一次点下去看着像「点了没反应」
        state: ViewBorders.isVisible ? .on : .off
    ) { [weak self] action in
        guard let self else { return }
        // 传 window 而不是 self.view：从窗口根开始描，才能把状态栏、弹出菜单这些不在本控制器视图树里的东西一起描上。
        // ⚠️ 窗口还没挂上时这里是 nil —— 此时 ViewBorders 会退化成「所有活跃窗口」，正好也是我们要的效果，不用额外兜底
        let isOn = ViewBorders.toggle(in: self.view.window)
        action.state = isOn ? .on : .off
        self.flashStatus(isOn ? "已显示视图描边（颜色按层级轮换）" : "已隐藏视图描边")
    }
    #endif

    /// 组装弹出菜单里的条目。
    /// 每个 UIAction 就是一行：标题 + 图标 + 点击后要执行的代码
    private func makeActionMenu() -> UIMenu {
        let actions: [UIAction] = [
            UIAction(title: "重载", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                // 丢掉未保存的改动，从磁盘把这份文件重新读一遍
                self?.reloadFromDisk()
            },
            UIAction(title: "分块", image: UIImage(systemName: "square.grid.2x2")) { [weak self] _ in
                // 弹窗列出当前所有块的源码 / 渲染区间
                self?.showBlocks()
            },
            UIAction(title: "源码", image: UIImage(systemName: "doc.plaintext")) { [weak self] _ in
                // 新开一页展示当前 markdown 源码
                self?.showSource()
            },
            UIAction(title: "查找", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                // 顶部滑出查找 / 替换横条
                self?.showFindBar()
            },
            UIAction(title: "校验", image: UIImage(systemName: "checkmark.seal")) { [weak self] _ in
                // 全选复制，比对复制出来的文本和源码是否逐字符一致
                self?.verifyRoundTrip()
            },
            UIAction(title: "导出成图片", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
                // 把编辑器整篇内容渲染成一张长图，弹系统分享面板
                self?.exportEditorAsImage()
            },
            UIAction(title: "设置", image: UIImage(systemName: "gearshape")) { [weak self] _ in
                // 弹出设置页（正文排版、大纲、表格列宽都在那儿）
                self?.showSettings()
            }
        ]

        #if DEBUG
        // 调试项单独成一组：`.displayInline` 让它就地展开（不变成二级菜单），
        // 菜单里会在它上面画一条分隔线，免得和上面那些正常功能混在一起被误点。
        // 整个 `#if DEBUG` 都删掉，Release 包里就没有这一项了。
        // 以后再加调试开关，只往这个数组里塞一个 action 就行，别的不用动
        let debugSection = UIMenu(
            options: .displayInline,
            children: [textKitDebugAction, viewBordersAction]
        )
        return UIMenu(children: actions + [debugSection])
        #else
        return UIMenu(children: actions)
        #endif
    }

    // MARK: 设置

    /// 弹出设置页。
    ///
    /// 包一层 `UINavigationController`：设置页右上角那个「完成」要挂在导航栏上才正常，
    /// 而且以后设置项多了、需要点进二级页面时，导航栏是现成的。
    /// 用弹窗（present）而不是 push 到主界面：设置和文档是两码事，看完就关，
    /// 不该占着主界面的导航栈
    @objc private func showSettings() {
        let controller = SettingsViewController(settings: settings)
        present(UINavigationController(rootViewController: controller), animated: true)
    }

    /// 设置变了 → 立刻生效，不用重启
    private func observeSettingsChanges() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(settingsDidChange),
                                               name: MarkdownEditorSettings.didChangeNotification,
                                               object: settings)
    }

    @objc private func settingsDidChange() {
        applyOutlineAppearance()
        applyEditorStyle()
    }

    /// 把「正文排版」「表格列宽」「图片尺寸」三组配置一起写进编辑器主题，再整篇重排一遍。
    ///
    /// ### 为什么这三组合成一个方法
    /// 它们走的是同一条路：改主题里的数值 → **必须重渲染才生效**
    /// （字号、行高、段间距、首行缩进是渲染时烙进段落样式的；表格是渲染时画成图的；
    /// 图片尺寸是渲染时就写进 attachment 的 `bounds` 的，事后改主题也改不动已经排好的图）。
    /// 各写一个方法、各排一遍的话，用户在设置页拖一下滑块会白排两遍。
    ///
    /// ### 为什么非得重排
    /// 只改主题里的数值、不重新渲染，屏幕上那篇文字纹丝不动。好在这套渲染是幂等的：
    /// 同一份源码 + 同一套主题永远得到同一个结果，所以拖滑块时每动一下就重排一遍
    /// 也扛得住 —— 而且它保着光标位置（见 `MarkdownTextView.refreshTheme`），
    /// 不会拖两下就跳回文首。
    private func applyEditorStyle() {
        settings.applyTypography(to: &editor.renderer.theme)
        settings.applyTableColumnWidths(to: &editor.renderer.theme)
        settings.applyImageSize(to: &editor.renderer.theme)
        // 行宽是**编辑器自己的布局参数**，不走主题 ——
        // 主题管「文字长什么样」，行宽取决于窗口有多宽，是布局的事
        editor.maxContentWidth = settings.bodyContentWidthLimit.map { CGFloat($0) }
        // 行号是编辑器自己的显示开关：改它会让左边的装订线占/让出一条带子，
        // 正文宽度跟着变，所以放在 `refreshTheme()`（整篇重排）之前一起生效
        editor.showsLineNumbers = settings.showsLineNumbers
        editor.refreshTheme()
    }

    /// 把「大纲面板」这一组的配置（宽高 + 背景不透明度）同步给面板本体。
    ///
    /// 「配置 → 面板参数」的换算本身放在配置那边
    /// （`MarkdownEditorSettings.applyOutlineWidth` / `applyOutlineHeight` / `applyOutlineBackground`），这样它们能各自被单独测；
    /// 这里只负责把结果送过去、再让面板重算一次宽高
    private func applyOutlineAppearance() {
        settings.applyOutlineWidth(to: &outlineView.appearance)
        settings.applyOutlineHeight(to: &outlineView.appearance)
        settings.applyOutlineBackground(to: &outlineView.appearance)
        // 宽高是算出来的（不算动画：拖滑块时不该一直有动画）
        outlineView.refreshAppearance()
    }

    // MARK: 记住「这份文档读到哪儿了」

    /// 这份文档在「阅读位置」里的钥匙 —— 就是文件路径。
    ///
    /// 现在每一页都对应磁盘上一份文件，所以不再有「内置示例 / 空白草稿」那两种
    /// 没有文件可记的情形。真没有文件就返回 nil，等于不记。
    private var documentScrollKey: String? {
        openedFileURL?.path
    }

    /// 离开当前文档之前，把它读到哪儿记下来。
    /// 三个时机调用：换文档之前、按⌘S保存之后、App 失去焦点 / 进后台时
    private func rememberCurrentScrollPosition() {
        guard settings.remembersScrollPosition, let key = documentScrollKey else { return }
        scrollMemory.remember(sourceOffset: editor.topVisibleSourceOffset, for: key)
    }

    /// 换完文档之后，回到上次读到的位置。
    ///
    /// 关掉「记住滚动位置」时什么都不做 —— 打开就是文档开头。
    /// 滚动本身在编辑器内部是异步收敛的（TextKit 2 一次滚不到位），这里只管发出指令
    private func restoreScrollPositionIfNeeded() {
        guard settings.remembersScrollPosition, let key = documentScrollKey else { return }
        guard let offset = scrollMemory.sourceOffset(for: key) else { return }
        editor.restoreScrollPosition(sourceOffset: offset)
    }

    /// App 被切走 / 进后台时也该记一次 —— 用户很可能就是随手切出去、再也没回来
    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        center.addObserver(self,
                           selector: #selector(appWillLeaveForeground),
                           name: UIApplication.willResignActiveNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(appWillLeaveForeground),
                           name: UIApplication.didEnterBackgroundNotification,
                           object: nil)
    }

    @objc private func appWillLeaveForeground() {
        rememberCurrentScrollPosition()
    }

    // MARK: - PPContentDisplaying（宿主 → 内容页）

    /// 宿主送来一份内容项：把这一页换成那份文档。
    ///
    /// ⚠️ 宿主**可能在我的界面还没建好时就调用**（Tab 是先创建、后显示）。
    /// 所以这里只把内容存下来，真正的加载留给 `viewDidLoad`
    func configure(with item: PPContentItem) {
        pendingItem = item
        guard isViewLoaded else { return }
        // 界面已经在了（比如同一个预览 Tab 被复用成另一份文档）→ 当场换
        apply(item)
    }

    /// 把一份内容项装进编辑器。
    ///
    /// 文本是从内容项里取的（`item.body`），不再自己去读盘：
    /// 「读文件」那一步在左侧栏做完，读失败在那里就被拦住了 ——
    /// 不然这里拿到空内容、用户一按 ⌘S 就把原文件清空了。
    private func apply(_ item: PPContentItem) {
        let url = URL(fileURLWithPath: item.id)
        let isSameDocument = openedFileURL == url

        // 换文档 = 换一把「阅读位置」的钥匙。必须在改 openedFileURL 之前记，
        // 那之后 documentScrollKey 就已经指向新文档了
        if !isSameDocument { rememberCurrentScrollPosition() }

        openedFileURL = url
        savedSource = item.body
        // 换了一份文档 → 「我改过了」这件事重新从零算（新 Tab 该有新的机会被固定）
        didReportEdited = false
        // md 里的图片多是相对路径，基准目录要指向文件所在目录，否则图片全裂
        editor.imageBaseURL = url.deletingLastPathComponent()
        editor.setMarkdown(item.body)

        refreshStatus()
        updateWindowTitle()
        // 换文档 → 大纲从「全部展开」开始（上一份文档折过什么，跟这一份没关系）
        outlineView.resetFolding()
        // 查找还开着的话，按原来那个词在新文档里重查一遍 —— 换文档时编辑器已经把自己的命中清掉了，不补这一下，计数会停在上一份文档的旧数字上
        searchCoordinator.rerunIfNeeded()
        // 同一份文档被重新配置（预览 Tab 复用回它自己）就别乱滚，免得跳走
        if !isSameDocument { restoreScrollPositionIfNeeded() }
    }

    // MARK: 新建 / 打开（Mac 菜单入口）

    /// ⌘N：新建一份空白文档。
    ///
    /// 这个动作**不在这一页里完成** —— 它只是把「想新建」这件事报出去，
    /// 由左侧栏（它管着文档目录和路由）去磁盘上建文件、并在右侧开一个新 Tab。
    ///
    /// ### 为什么绕这一圈
    /// 新架构下每一份文档都是目录里的一个真文件。如果在这里就地清空当前 Tab，
    /// 会先把用户正在看的那份文件从界面上顶掉、而新文档又没有落盘，
    /// 左侧栏和右侧就对不上了。
    @objc func newDocument() {
        NotificationCenter.default.post(name: DocumentsWorkspace.newDocumentRequestedNotification,
                                        object: nil)
    }
    /// ⌘O：弹系统文件选择器，挑一个 .md / .txt 打开 —— **在新 Tab 里开**，
    /// 不会把当前这一页顶掉。
    ///
    /// 这里不像以前那样先问「当前这份改了还没存要不要放弃」：打开新 Tab 根本
    /// 不动当前这一份，没什么可放弃的。
    @objc func openDocumentFromPanel() {
        // UTType 里没有预置的 markdown 常量，只能按扩展名推一个；
        // 推不出来就退回纯文本 —— md 本来就是纯文本，还能正常选到
        let markdownType = UTType(filenameExtension: "md") ?? .plainText
        // asCopy: false = 原地打开、不复制副本，这样 ⌘S 才能写回原文件
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [markdownType, .plainText],
                                                    asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    /// 接管系统菜单自带的「文件 > 打开…」(⌘O)。
    ///
    /// Catalyst 的「文件」菜单里本来就有一条 Open…，它的 action 是 `open:`。
    /// 我们不去新增一条同快捷键的菜单项（UIKit 遇到重复快捷键会抛异常崩溃），
    /// 而是实现这个方法 —— 系统那条菜单项会顺着响应链找到这里。
    /// 方法名必须叫 `open`（selector 就是 `open:`），所以加了反引号
    @objc func `open`(_ sender: Any?) {
        openDocumentFromPanel()
    }

    /// 有未保存改动时先问一句。回调传 true 表示可以继续，false 表示用户选了取消
    private func confirmDiscardIfNeeded(_ completion: @escaping (Bool) -> Void) {
        guard isDirty else {
            completion(true)
            return
        }
        let name = openedFileURL?.lastPathComponent ?? "未命名文档"
        let alert = UIAlertController(title: "还有改动没保存",
                                      message: "「\(name)」改了还没存，继续的话这部分改动就丢了。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "放弃改动", style: .destructive) { _ in completion(true) })
        present(alert, animated: true)
    }

    // MARK: 保存

    /// ⌘S：写回这个 Tab 对应的文件。
    ///
    /// 正常一定有文件可写（每个 Tab 都是被一份文件开出来的）。真没有的话
    /// 只弹个提示 —— 新建的文档是左侧栏先在磁盘上建好的，
    /// 也就不存在「草稿没有文件」这种中间态。
    ///
    /// ### 新建的文档会先问一句名字
    /// 从「＋」/ ⌘N 建出来的文档，磁盘上先是 `未命名.md` 之类的**占位名**。
    /// 在它上面第一次按 ⌘S，会弹个输入框请用户起名字 —— 这是 Mac 上
    /// 「新文档第一次保存要问文件名」的老规矩，也是别让用户的文稿堆里
    /// 攒下一串「未命名 7.md」的唯一时机。起过名字之后 ⌘S 就直接写回，不再打扰。
    ///
    /// 这里刻意不加 private —— 菜单栏的「存储」项要引用它的 selector，
    /// 修饰符是 private 的话，AppDelegate 里 `#selector(...)` 取不到
    @objc func saveDocument() {
        guard let url = openedFileURL else {
            showAlert(title: "没有可保存的文件",
                      message: "这一页没有对应到磁盘上的文件，没法保存。在左侧栏点一份文档，或者在「文件」App 里把 .md 放进来。")
            return
        }

        // 还顶着占位名 → 先请用户起名字，别把一堆「未命名 5.md」留给用户
        guard !needsFileNameBeforeSaving else {
            promptForFileName(startingFrom: url)
            return
        }

        writeCurrentSource(to: url)
    }

    /// 「这一页是不是还没起过名字、保存前得先问一句」。
    ///
    /// 判断本身在 `DocumentsWorkspace.isUntitled` 里（纯文件名判断），
    /// 这里多包一层是为了**能单测** —— 弹框那一步在单测里走不起来，
    /// 但「该不该弹」这条逻辑值得单独钉住。
    var needsFileNameBeforeSaving: Bool {
        guard let url = openedFileURL else { return false }
        return DocumentsWorkspace.isUntitled(url)
    }

    /// 把编辑器里的内容写进指定文件。
    ///
    /// - Returns: 写成功了回 true。失败会弹提示，让用户知道「没存上」
    @discardableResult
    private func writeCurrentSource(to url: URL) -> Bool {
        let source = editor.markdownSource
        do {
            try DocumentsWorkspace.write(source, to: url)
        } catch {
            showAlert(title: "保存失败",
                      message: "\(url.lastPathComponent)\n\n\(error.localizedDescription)")
            return false
        }

        savedSource = source
        // 存盘是个天然的「我读到这儿了」的时间点，顺手记一次
        rememberCurrentScrollPosition()
        refreshStatus()
        updateWindowTitle()
        flashStatus("已保存 \(url.lastPathComponent)")
        return true
    }

    /// 弹「给文档起个名字」的输入框。
    ///
    /// ### 为什么是 UIAlertController + 输入框，而不是系统存储面板
    /// Mac 上做这件事的正经办法是 `NSSavePanel`，但 Catalyst 把它标成了 unavailable
    /// （编译器直接拦）。退而求其次就是这个「一个输入框 + 保存 / 取消」的对话框 ——
    /// 该有的都有了：预填名字、能改、能取消。
    ///
    /// - Parameter suggested: 预填进输入框的名字。第一次弹时是占位名（「未命名」），
    ///   用户因为重名被打回来重弹时，就填他上一次输的名字，好改一个字接着来
    private func promptForFileName(startingFrom url: URL, suggested: String? = nil) {
        let defaultName = suggested ?? DocumentsWorkspace.displayName(for: url)

        let alert = UIAlertController(
            title: "保存文档",
            message: "给这份文档起个名字，它会存在 App 的文档目录里。\n"
                   + "直接点「保存」也行，那就还叫「\(defaultName)」。",
            preferredStyle: .alert)

        alert.addTextField { field in
            field.text = defaultName
            field.placeholder = "文件名"
            field.clearButtonMode = .whileEditing
            field.returnKeyType = .done
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            // 取消 = 这一下不存。正文还在编辑器里、标题上的「已修改」也还在，
            // 但得说一声，免得用户以为刚才那一下存过了
            self?.flashStatus("已取消保存")
        })
        // `weak alert`：UIAlertController 持有 action、action 持有这个闭包，
        // 闭包里再强引用 alert 就绕成一个圈，弹框关了也放不掉
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            self.save(from: url, as: alert?.textFields?.first?.text ?? "")
        })

        // 顺带把预填的名字整条选中：用户直接打字就等于「改掉它」，
        // 不用先自己全选删一遍。
        // 放在 present 的 completion 里做：弹框还没上屏时输入框不是第一响应者，
        // 那会儿设选中会被系统清掉
        present(alert, animated: true) {
            alert.textFields?.first?.selectAll(nil)
        }
    }

    /// 用户在命名框里点了「保存」之后真正要做的事：**改名 + 把内容写进去**。
    ///
    /// 抽成独立方法（而不是直接写在弹框的闭包体里）有两个原因：
    /// 1. **能单测** —— `UIAlertController` 那一步在单测里走不起来，
    ///    而「改名 + 写盘 + 更新本页状态」才是真会出错的地方；
    /// 2. 失败提示要分得清是「名字不行」还是「写不进去」，两者的下一步动作不一样。
    ///
    /// - Returns: 存成功了回新的文件地址；名字是空的 / 被占用了则回 nil
    @discardableResult
    func save(from url: URL, as rawName: String) -> URL? {
        let newURL: URL
        do {
            newURL = try DocumentsWorkspace.rename(url, toBaseName: rawName)
        } catch {
            showNameRejectedAlert(error, from: url, triedName: rawName)
            return nil
        }

        // 改完名，这一页从此就认新路径了 —— 之后的 ⌘S、窗口标题、
        // 「读到哪儿」的记录全都跟着走
        openedFileURL = newURL
        // 旧路径那条阅读位置的记录留着没用了（而且文件名以后可能被重新用上，
        // 那时候不该莫名跳到文档中间）
        DocumentScrollMemory.shared.forget(key: url.path)
        // 说一声，让左侧栏重新扫一遍目录 —— 照旧走通知，别在这儿直接刷
        NotificationCenter.default.post(name: DocumentsWorkspace.didChangeNotification, object: nil)

        // 顺序是**先改名、后写内容**：改名最可能因为重名失败，那时宁可什么都还没动
        // （文件还在原来的占位名下，用户换个名字接着存）
        writeCurrentSource(to: newURL)
        return newURL
    }

    /// 名字用不了（空的 / 重名）时的提示，带一个「重新起名」的入口。
    ///
    /// 单独写一个而不是复用 `showAlert`：只丢一句「保存失败」的话，
    /// 用户得自己再按一次 ⌘S 才能重新输名字，白多两步。
    private func showNameRejectedAlert(_ error: Error, from url: URL, triedName: String) {
        let alert = UIAlertController(title: "这个名字用不了",
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        // 预填的是用户上一次输入的那个名字，改一个字就能接着来
        alert.addAction(UIAlertAction(title: "重新起名", style: .default) { [weak self] _ in
            self?.promptForFileName(startingFrom: url, suggested: triedName)
        })
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        present(alert, animated: true)
    }

    #if targetEnvironment(macCatalyst)
    /// Mac 专属：把 ⌘N / ⌘O / ⌘S 注册成键盘快捷键。
    ///
    /// 整段用 `#if targetEnvironment(macCatalyst)` 包住，iOS 上这段代码
    /// 根本不参与编译，所以 iOS 构建完全不受影响。
    ///
    /// 说明：AppDelegate 里往菜单栏加了同样三个条目。
    /// 两者不会打架 —— macOS 先走菜单的快捷键匹配，菜单命中后就不再往下传，
    /// 这里只是菜单那条路走不通时的兜底。
    override var keyCommands: [UIKeyCommand]? {
        let new = UIKeyCommand(title: "新建",
                               action: #selector(newDocument),
                               input: "n",
                               modifierFlags: .command)
        let open = UIKeyCommand(title: "打开",
                                action: #selector(openDocumentFromPanel),
                                input: "o",
                                modifierFlags: .command)
        let save = UIKeyCommand(title: "存储",
                                action: #selector(saveDocument),
                                input: "s",
                                modifierFlags: .command)
        let find = UIKeyCommand(title: "查找",
                                action: #selector(showFindBar),
                                input: "f",
                                modifierFlags: .command)
        return [new, open, save, find]
    }
    #endif

    /// 界面上要显示的名字：文件名**去掉扩展名**（满屏 `.md` 后缀看着很吵）。
    /// 没有对应文件时（不该发生）叫「未命名」
    private var documentDisplayName: String {
        guard let url = openedFileURL else { return "未命名" }
        return DocumentsWorkspace.displayName(for: url)
    }

    private func updateWindowTitle() {
        let name = documentDisplayName
        let suffix = isDirty ? " — 已修改" : ""
        title = name
        // Mac Catalyst：windowScene.title 就是窗口标题栏上显示的文字。
        // 多个 Tab 时只有**当前**那一页会写它（藏着的那几页不会触发这里），
        // 所以窗口标题永远跟着前台 Tab 走
        view.window?.windowScene?.title = name + suffix
    }

    private func observeEditorChanges() {
        // 内容一变就刷新窗口标题上的「已修改」标记
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(editorContentChanged),
            name: UITextView.textDidChangeNotification,
            object: editor
        )
    }

    @objc private func editorContentChanged() {
        updateWindowTitle()
        reportEditedStateIfNeeded()
    }

    /// 「我改过了」这件事只上报一次，让宿主把这一页从「预览 Tab」固定成正式 Tab。
    ///
    /// 只报一次、也只报 true，原因见 `didReportEdited` 的注释。
    private func reportEditedStateIfNeeded() {
        guard isDirty, !didReportEdited else { return }
        didReportEdited = true
        contentHost?.contentViewController(self, didChangeEditedState: true)
    }

    private func refreshStatus() {
        let name = documentDisplayName
        let dirty = isDirty ? " · 已修改（⌘S 保存）" : ""
        statusLabel.text = "\(name)\(dirty) · 块数 \(editor.documentStore.blocks.count) · 源码 \(editor.markdownSource.utf16.count) 字符 · 渲染 \(editor.documentStore.renderedLength) 字符"
    }

    /// 状态栏上闪一句提示，1.5 秒后自动恢复成常规信息
    private func flashStatus(_ message: String) {
        statusResetWork?.cancel()
        statusLabel.text = message
        let work = DispatchWorkItem { [weak self] in self?.refreshStatus() }
        statusResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: 按钮动作

    /// 核心验收：全选复制出来的文本，必须和源码逐字符一致
    @objc private func verifyRoundTrip() {
        editor.becomeFirstResponder()
        editor.selectAll(nil)
        editor.copy(nil)               // 走我们接管的 copy → 查映射表还原源码
        editor.selectedRange = NSRange(location: editor.selectedRange.location, length: 0)

        let copied = UIPasteboard.general.string ?? ""
        let source = editor.markdownSource
        let passed = copied == source

        let alert = UIAlertController(
            title: passed ? "✅ 复制结果和源码完全一致" : "❌ 复制结果和源码不一致",
            message: passed
                ? "共 \(source.utf16.count) 个字符，逐字符比对通过。\n粘到任何编辑器里都是 markdown 源码。"
                : firstDifferenceDescription(source, copied),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
        refreshStatus()
    }

    /// 显示当前源码
    @objc private func showSource() {
        let textViewController = UIViewController()
        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.text = editor.markdownSource
        textView.isEditable = false
        textViewController.view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: textViewController.view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: textViewController.view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: textViewController.view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: textViewController.view.bottomAnchor)
        ])

        textViewController.title = "源码"
        textViewController.navigationItem.rightBarButtonItem =
            UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissPresented))
        let navigation = UINavigationController(rootViewController: textViewController)
        present(navigation, animated: true)
    }

    /// 显示当前分块情况（调试增量解析用）
    @objc private func showBlocks() {
        let lines = editor.documentStore.blocks.enumerated().map { index, block in
            "[\(index)] \(block.kindDescription.padding(toLength: 22, withPad: " ", startingAt: 0)) src=\(block.sourceRange.location)+\(block.sourceRange.length) render=\(block.renderedRange.location)+\(block.renderedRange.length)"
        }
        let alert = UIAlertController(title: "共 \(editor.documentStore.blocks.count) 个块",
                                      message: lines.joined(separator: "\n"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    /// 「重载」：丢掉未保存的改动，从磁盘把这份文件重新读一遍。
    ///
    /// ### 为什么这个动作要有
    /// 这份文件可能被别的程序改过（用户自己用别的编辑器存过、iCloud 同步下来新版本），
    /// 而编辑器手里还是打开那一刻的内容。重载就是「以磁盘上的为准，重新读一遍」。
    ///
    /// ### 为什么要先确认
    /// 它会盖掉当前未保存的改动 —— 不是「刷新」，是「丢弃并重读」，所以必须先问一句。
    @objc private func reloadFromDisk() {
        guard let url = openedFileURL else {
            showAlert(title: "没有可重载的文件", message: "这一页没有对应到磁盘上的文件。")
            return
        }
        confirmDiscardIfNeeded { [weak self] canContinue in
            guard let self, canContinue else { return }
            guard let text = DocumentsWorkspace.read(url) else {
                self.showAlert(title: "重载失败",
                               message: "「\(url.lastPathComponent)」读不出来，可能被移走或者没有访问权限。")
                return
            }
            // 走和「换文档」同一条路：图片基准目录、大纲重置、滚动位置都一并处理
            self.apply(PPContentItem(id: url.path,
                                     title: DocumentsWorkspace.displayName(for: url),
                                     body: text,
                                     category: "Documents"))
            self.flashStatus("已重载 \(url.lastPathComponent)")
        }
    }

    @objc private func dismissPresented() {
        dismiss(animated: true)
    }

    /// 「导出成图片」：编辑器整篇内容 → 一张长图。
    /// 渲染细节（撑大视口、逐段画文字那些）都封装在 MarkdownTextView 里，这里只管「导出到哪」：
    ///   - Mac Catalyst：弹系统「存储」面板，直接落到用户选的本地文件夹
    ///   - iOS：弹系统分享面板（存相册 / AirDrop / 存到「文件」都行）
    private func exportEditorAsImage() {
        guard let image = editor.renderFullContentImage() else {
            showAlert(title: "导出失败", message: "没有可导出的内容。")
            return
        }
        #if targetEnvironment(macCatalyst)
        saveImageToFolder(image)
        #else
        presentShareSheet(for: image)
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// Mac 专属：把长图存成 PNG，落到用户选的本地文件夹。
    ///
    /// ### 为什么不用 NSSavePanel
    /// Catalyst 把它标记成 unavailable（Swift 编译器直接拦）。等效替代是
    /// `UIDocumentPickerViewController(forExporting:asCopy:)` —— 项目里「另存为」
    /// 用的同一块面板，在 Mac 上呈现的就是原生风格的存储对话框（选文件夹 + 改文件名）。
    private func saveImageToFolder(_ image: UIImage) {
        guard let pngData = image.pngData() else {
            showAlert(title: "导出失败", message: "图片编码成 PNG 失败。")
            return
        }
        flashStatus("已生成图片 \(Int(image.size.width))×\(Int(image.size.height))，请选择存储位置")

        // 导出面板要求给一个真实文件：先写进临时目录，面板再把副本复制到用户选的位置。
        // 默认文件名跟文档同名：notes.md → notes.png
        let suggestedName = (documentDisplayName as NSString).deletingPathExtension + ".png"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName)
        do {
            try pngData.write(to: tempURL)
        } catch {
            showAlert(title: "导出失败", message: error.localizedDescription)
            return
        }

        // 面板回调里要靠这个标记区分「图片导出」和「另存为 markdown」（见 delegate）
        isExportingImage = true
        let picker = UIDocumentPickerViewController(forExporting: [tempURL], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }
    #else
    /// iOS：系统分享面板，存相册 / AirDrop / 存到「文件」都走这里
    private func presentShareSheet(for image: UIImage) {
        flashStatus("已生成图片 \(Int(image.size.width))×\(Int(image.size.height))，正在打开分享面板")
        let activity = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        // iPad 上分享面板必须以 popover 形式出现，得给个锚点；iPhone 用不上这条，留着不碍事
        if let popover = activity.popoverPresentationController {
            popover.sourceView = menuButton
            popover.sourceRect = menuButton.bounds
        }
        present(activity, animated: true)
    }
    #endif

    // MARK: 键盘避让

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    @objc private func keyboardFrameChanged(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        // 键盘收起时 frame.origin.y 会等于屏幕高度，此时不需要避让
        let overlap = max(0, view.bounds.height - frame.origin.y)
        bottomConstraint?.constant = -overlap
        view.layoutIfNeeded()
    }

    // MARK: 小工具

    /// 弹提示。冷启动时 view 还没挂到窗口上，present 会无效，所以延后一帧再弹
    private func showAlert(title: String, message: String) {
        let presentBlock = { [weak self] in
            guard let self else { return }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            self.present(alert, animated: true)
        }
        if view.window == nil {
            DispatchQueue.main.async(execute: presentBlock)
        } else {
            presentBlock()
        }
    }

    /// 找出两段文本第一处不同的位置，方便定位问题
    private func firstDifferenceDescription(_ source: String, _ copied: String) -> String {
        let sourceChars = Array(source)
        let copiedChars = Array(copied)
        for index in 0..<min(sourceChars.count, copiedChars.count) where sourceChars[index] != copiedChars[index] {
            let start = max(0, index - 15)
            let sourceSnippet = String(sourceChars[start..<min(sourceChars.count, index + 15)])
            let copiedSnippet = String(copiedChars[start..<min(copiedChars.count, index + 15)])
            return "第 \(index) 个字符不同\n\n源码: …\(sourceSnippet)…\n复制: …\(copiedSnippet)…"
        }
        return "长度不同：源码 \(sourceChars.count) 字符，复制出来 \(copiedChars.count) 字符"
    }
}

// MARK: 文件选择器回调
//
// 这个代理现在只服务两种面板：
//   - 「打开」（⌘O）→ 挑一份文件，交给左侧栏在新 Tab 里打开；
//   - 「导出成图片」→ 挑个位置存 PNG。
// 以前还有「另存为」，现在没了 —— 新文档是左侧栏先在磁盘上建好的，不需要它。

extension MarkdownDocumentViewController: UIDocumentPickerDelegate {

    /// 用户挑完了（挑中的是文件，还是图片的保存位置，靠 isExportingImage 区分）
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }

        if isExportingImage {
            // 「导出成图片」：系统已经把 PNG 副本复制到这个位置了，提示一下就完事
            isExportingImage = false
            flashStatus("图片已存储到 \(url.deletingLastPathComponent().path)")
        } else {
            // 「打开」：把 URL 交给统一的入口。
            // 走 MarkdownDocumentOpener 而不是自己去读，是为了顺带申请一次安全作用域
            // （文件在工作目录之外时，不申请就写不回去），
            // 它会把通知发出去、由左侧栏在**新 Tab** 里打开这份文件 ——
            // 当前这一页不动
            MarkdownDocumentOpener.shared.handle(url: url)
        }
    }

    /// 用户点了取消：什么都不改，保持原样，顺手把导出标记清掉
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        isExportingImage = false
    }
}

// MARK: - QuickLook 数据源

/// QuickLook 预览窗里的「一项」：一个文件地址 + 标题栏上显示的名字。
///
/// 为什么单独建这个类而不复用 `ImageAttachment`：attachment 是渲染层的东西
/// （还带着源码映射那些职责），而 QuickLook 只想要一个 URL。让两者互相认识没必要。
private final class ImagePreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        self.previewItemURL = url
        self.previewItemTitle = title
        super.init()
    }

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释：
    /// 隔离 deinit 会踩 Swift 6.2 运行时的野指针 free
    nonisolated deinit {}
}

extension MarkdownDocumentViewController: QLPreviewControllerDataSource {

    /// 一次只预览一张图 —— 就是用户点的那张
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        previewItem == nil ? 0 : 1
    }

    func previewController(_ controller: QLPreviewController,
                           previewItemAt index: Int) -> QLPreviewItem {
        // 上面报了 1，走到这儿 `previewItem` 必然有值。
        // 万一真的没有（时序异常），给个空壳也比强解包崩掉好
        previewItem ?? ImagePreviewItem(url: URL(fileURLWithPath: NSTemporaryDirectory()),
                                        title: "图片")
    }
}
