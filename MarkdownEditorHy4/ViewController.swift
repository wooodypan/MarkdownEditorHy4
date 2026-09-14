//
//  ViewController.swift
//  MarkdownEditorHy4
//
//  Demo 界面：一个 markdown 编辑器 + 右上角「⋯」弹出菜单（重载 / 分块 / 源码 / 校验）
//  Mac 上另有菜单栏：文件 > 新建 / 打开 / 存储
//

import UIKit
// 菜单里的「打开」要判断哪些文件可选，用到 UTType.markdown
import UniformTypeIdentifiers

final class ViewController: UIViewController {

    // MARK: 子视图

    private let editor = MarkdownTextView()
    private let statusLabel = UILabel()
    /// 右上角的「⋯」按钮。点一下弹出菜单，里面装着重载 / 分块 / 源码 / 校验
    private let menuButton = UIButton(type: .system)
    /// 悬浮目录面板（纯 UI 层，不认识编辑器）
    private let outlineView = MarkdownOutlineView()
    /// 大纲协调者：把编辑器和目录面板连起来
    private let outlineCoordinator = OutlineCoordinator()
    /// 用户配置（「记住目录大纲滚动位置」等）。改完会发通知，下面挂了监听同步给大纲面板
    private let settings = MarkdownEditorSettings.shared
    /// 每份文档「上次读到哪儿」的记忆
    private let scrollMemory = DocumentScrollMemory.shared
    private var bottomConstraint: NSLayoutConstraint?

    /// 当前打开的文件。nil 表示在看内置示例文档，这类内容不能保存回磁盘
    private var openedFileURL: URL?
    /// 上次打开/保存时的源码快照，和它比对就知道有没有改动
    private var savedSource = ""
    /// 有没有未保存的改动
    private var isDirty: Bool { editor.markdownSource != savedSource }
    /// 临时提示（比如「已保存」）显示完要恢复成常规状态栏
    private var statusResetWork: DispatchWorkItem?
    /// 是不是「新建」出来的空白草稿。用来区分它和内置示例文档 —— 两者都没有关联文件，
    /// 但标题该显示「未命名」还是「示例文档」不一样
    private var isNewDraft = false
    /// 当前弹出的文件选择器是不是「另存为」（导出）用途，回调里要靠它区分两种面板
    private var isExportingDocument = false
    /// 当前弹出的文件选择器是不是「导出成图片」用途（Mac），和上面那个互斥
    private var isExportingImage = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // 顺序有讲究：菜单按钮要先建好，编辑器的顶部约束要挂在它下面
        setupMenuButton()
        setupEditor()
        setupStatusLabel()
        // 冷启动时文件 URL 已经在 MarkdownDocumentOpener 里等着了，先取出来用；
        // 没有外部文件才退回到内置示例文档
        if let url = MarkdownDocumentOpener.shared.takePendingURL() {
            openDocument(at: url)
        } else {
            loadSampleDocument()
        }
        // 放在文档加载**之后**：装配时的「初次拉取」才能真正拉到标题。
        // 放前面也能跑（编辑器那次 push 会被忽略），但会白拉一次空列表
        applyTableStyle()
        setupOutline()
        observeKeyboard()
        observeDocumentOpenRequests()
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
            // 顶部对齐菜单按钮的下边，这样按钮不会盖住正文第一行
            editor.topAnchor.constraint(equalTo: menuButton.bottomAnchor, constant: 2),
            editor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint!
        ])
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

    /// 组装弹出菜单里的条目。
    /// 每个 UIAction 就是一行：标题 + 图标 + 点击后要执行的代码
    private func makeActionMenu() -> UIMenu {
        let actions: [UIAction] = [
            UIAction(title: "重载", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                // 回到内置示例文档，重新渲染一遍
                self?.reloadSample()
            },
            UIAction(title: "分块", image: UIImage(systemName: "square.grid.2x2")) { [weak self] _ in
                // 弹窗列出当前所有块的源码 / 渲染区间
                self?.showBlocks()
            },
            UIAction(title: "源码", image: UIImage(systemName: "doc.plaintext")) { [weak self] _ in
                // 新开一页展示当前 markdown 源码
                self?.showSource()
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
                // 弹出设置页（目前就一行：是否记住目录大纲滚动位置）
                self?.showSettings()
            }
        ]
        return UIMenu(children: actions)
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

    /// 设置变了（用户在设置页拨了开关）→ 立刻作用到大纲面板上，不用重启
    private func observeSettingsChanges() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(settingsDidChange),
                                               name: MarkdownEditorSettings.didChangeNotification,
                                               object: settings)
    }

    @objc private func settingsDidChange() {
        applyScrollSetting()
        applyOutlineAppearance()
        applyTableStyle()
    }

    /// 把「表格列宽」的配置同步给编辑器主题。
    ///
    /// ### 为什么要整篇重渲染
    /// 表格是**渲染时画成的一张图**，列宽在画的那一刻就定死了；
    /// 只改主题里的数值、不重新渲染的话，画面上的表格纹丝不动。
    /// 拖滑块是低频操作，整篇重渲染一遍完全没问题。
    private func applyTableStyle() {
        settings.applyTableColumnWidths(to: &editor.renderer.theme)
        editor.setMarkdown(editor.markdownSource)
    }

    /// 把「是否记住滚动位置」同步给大纲面板
    private func applyScrollSetting() {
        outlineView.remembersScrollPosition = settings.remembersScrollPosition
    }

    /// 把「大纲面板高度」的配置同步给大纲面板。
    ///
    /// 「配置 → 面板参数」的换算本身放在配置那边
    /// （`MarkdownEditorSettings.applyOutlineHeight`），这样它能被单独测；
    /// 这里只负责把结果送过去、再让面板重算一次宽高
    private func applyOutlineAppearance() {
        settings.applyOutlineHeight(to: &outlineView.appearance)
        // 宽高是算出来的（不算动画：拖滑块时不该一直有动画）
        outlineView.refreshAppearance()
    }

    // MARK: 记住「这份文档读到哪儿了」

    /// 这份文档在「阅读位置」里的钥匙。
    ///
    /// - 打开的磁盘文件 → 用文件路径（同一个文件重开回到原处）；
    /// - 内置示例文档 → 一个固定字符串（内容每次都一样，记得住就有意义）；
    /// - 新建的空白草稿 → `nil`，不记。它每次都是新的，记了也没下一次。
    private var documentScrollKey: String? {
        if let url = openedFileURL { return url.path }
        return isNewDraft ? nil : "<sample>"
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

    // MARK: 载入示例文档

    private func loadSampleDocument() {
        let text = loadSampleMarkdown() ?? """
        # 找不到示例文档

        `Resources/sample.md` 没被打包进 App，先看这段兜底内容。

        - 列表项一
        - 列表项二

        ![示例图片](sample.png)
        """
        isNewDraft = false
        openedFileURL = nil
        savedSource = text
        editor.imageBaseURL = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first
        editor.setMarkdown(text)
        refreshStatus()
        updateWindowTitle()
        // 换文档 → 大纲从「全部展开」开始（上一份文档折过什么，跟这一份没关系）
        outlineView.resetFolding()
        restoreScrollPositionIfNeeded()
    }

    // MARK: 新建 / 打开（Mac 菜单入口）

    /// ⌘N：新建一份空白文档。
    /// 这时还没有对应的磁盘文件，第一次按 ⌘S 会弹「另存为」让你挑保存位置
    @objc func newDocument() {
        confirmDiscardIfNeeded { [weak self] canContinue in
            guard let self, canContinue else { return }
            // 换文档 = 换一把「阅读位置」的钥匙。必须在改 openedFileURL / isNewDraft 之前记，
            // 那之后 documentScrollKey 就已经指向新文档了
            self.rememberCurrentScrollPosition()
            self.isNewDraft = true
            self.openedFileURL = nil
            self.savedSource = ""
            // 新文档还没存到磁盘，粘贴的图片先放 Documents，等另存为之后不影响
            self.editor.imageBaseURL = FileManager.default.urls(for: .documentDirectory,
                                                               in: .userDomainMask).first
            self.editor.setMarkdown("")
            self.refreshStatus()
            self.updateWindowTitle()
            self.outlineView.resetFolding()
            self.flashStatus("已新建空白文档")
        }
    }

    /// ⌘O：弹系统文件选择器，挑一个 .md / .txt 打开
    @objc func openDocumentFromPanel() {
        confirmDiscardIfNeeded { [weak self] canContinue in
            guard let self, canContinue else { return }
            self.isExportingDocument = false
            // UTType 里没有预置的 markdown 常量，只能按扩展名推一个；
            // 推不出来就退回纯文本 —— md 本来就是纯文本，还能正常选到
            let markdownType = UTType(filenameExtension: "md") ?? .plainText
            // asCopy: false = 原地打开、不复制副本，这样 ⌘S 才能写回原文件
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [markdownType, .plainText],
                                                        asCopy: false)
            picker.delegate = self
            picker.allowsMultipleSelection = false
            self.present(picker, animated: true)
        }
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

    /// 新建 / 打开都会顶掉当前内容，有未保存改动就先问一句。
    /// 回调传 true 表示可以继续，false 表示用户选了取消
    private func confirmDiscardIfNeeded(_ completion: @escaping (Bool) -> Void) {
        guard isDirty else {
            completion(true)
            return
        }
        let name = openedFileURL?.lastPathComponent ?? (isNewDraft ? "未命名文档" : "示例文档")
        let alert = UIAlertController(title: "还有改动没保存",
                                      message: "「\(name)」改了还没存，继续的话这部分改动就丢了。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "放弃改动", style: .destructive) { _ in completion(true) })
        present(alert, animated: true)
    }

    /// 没有关联文件时（刚「新建」的草稿）走「另存为」：把内容导出到用户挑的位置。
    /// 导出面板必须给一个真实文件，所以先把内容写到临时目录再交给系统复制过去
    private func presentSaveAsPanel() {
        let name = openedFileURL?.lastPathComponent ?? "未命名.md"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try editor.markdownSource.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            showAlert(title: "保存失败", message: error.localizedDescription)
            return
        }
        isExportingDocument = true
        // asCopy: true = 复制过去，临时文件留着也无所谓
        let picker = UIDocumentPickerViewController(forExporting: [tempURL], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    // MARK: 打开 / 保存外部 .md 文件

    /// 打开 Finder 传进来的文件（右键「打开方式」、双击、拖到 Dock 图标都走这里）
    private func openDocument(at url: URL) {
        do {
            let text = try loadText(from: url)
            // 读出来了才记「上一份文档读到哪儿」；读失败就当作没换过文档，别把记录搅乱。
            // 同样要在改 openedFileURL 之前调用（那之后 documentScrollKey 就指向新文档了）
            rememberCurrentScrollPosition()
            isNewDraft = false
            openedFileURL = url
            savedSource = text
            // 关键：md 里的图片多是相对路径，基准目录要指向文件所在目录，否则图片全裂
            editor.imageBaseURL = url.deletingLastPathComponent()
            editor.setMarkdown(text)
            refreshStatus()
            updateWindowTitle()
            // 换文档 → 大纲从「全部展开」开始，别继承上一份文档的折叠
            outlineView.resetFolding()
            // 换完内容再滚回这个文件上次读到的位置
            restoreScrollPositionIfNeeded()
        } catch {
            showAlert(title: "打不开文件",
                      message: "\(url.lastPathComponent)\n\n\(error.localizedDescription)")
        }
    }

    private func loadText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        // 按 UTF-8 解码。遇到不合法的字节会换成替换字符，总比整篇打不开强
        return String(decoding: data, as: UTF8.self)
    }

    /// ⌘S：写回原文件。
    /// 没有关联文件时（内置示例文档 / 刚「新建」的草稿）分两条路走：
    ///   - Mac：弹「另存为」面板，让新建的草稿能落地成文件
    ///   - iOS：弹个提示，说明得先从外部打开一个文件
    /// 这里刻意不加 private —— 菜单栏的「存储」项要引用它的 selector，
    /// 修饰符是 private 的话，AppDelegate 里 `#selector(...)` 取不到
    @objc func saveDocument() {
        guard let url = openedFileURL else {
            #if targetEnvironment(macCatalyst)
            presentSaveAsPanel()
            #else
            showAlert(title: "没有可保存的文件",
                      message: "现在看的是内置示例文档。在 Finder 里右键 .md 文件 →「打开方式」→ 选本 App，打开后就能用 ⌘S 存回原文件。")
            #endif
            return
        }

        let source = editor.markdownSource
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
            savedSource = source
            // 存盘是个天然的「我读到这儿了」的时间点，顺手记一次
            rememberCurrentScrollPosition()
            refreshStatus()
            updateWindowTitle()
            flashStatus("已保存 \(url.lastPathComponent)")
        } catch {
            showAlert(title: "保存失败", message: "\(url.lastPathComponent)\n\n\(error.localizedDescription)")
        }
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
        return [new, open, save]
    }
    #endif

    /// 界面上要显示的名字：有文件就用文件名；没有文件则区分「新建的草稿」和「内置示例」
    private var documentDisplayName: String {
        if let url = openedFileURL { return url.lastPathComponent }
        return isNewDraft ? "未命名" : "示例文档"
    }

    private func updateWindowTitle() {
        let name = documentDisplayName
        let suffix = isDirty ? " — 已修改" : ""
        title = name
        // Mac Catalyst：windowScene.title 就是窗口标题栏上显示的文字
        view.window?.windowScene?.title = name + suffix
    }

    private func observeDocumentOpenRequests() {
        // 热启动：App 已经在跑，用户又双击了一个 md 文件
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(documentOpenRequested(_:)),
            name: .markdownDocumentOpenRequested,
            object: nil
        )
    }

    @objc private func documentOpenRequested(_ notification: Notification) {
        guard let url = notification.object as? URL else { return }
        openDocument(at: url)
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
    }

    private func loadSampleMarkdown() -> String? {
        guard let url = Bundle.main.url(forResource: "sample", withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
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

    @objc private func reloadSample() {
        loadSampleDocument()
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
// 「打开」和「另存为」用的是同一个 UIDocumentPickerViewController，
// 靠 isExportingDocument 区分这次弹的是哪一种，回调里分开处理。

extension ViewController: UIDocumentPickerDelegate {

    /// 用户挑完了（打开：挑中的文件；另存为/导出图片：挑中的保存位置）
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }

        if isExportingImage {
            // 「导出成图片」：系统已经把 PNG 副本复制到这个位置了，提示一下就完事
            isExportingImage = false
            flashStatus("图片已存储到 \(url.deletingLastPathComponent().path)")
        } else if isExportingDocument {
            // 「另存为」：系统已经把临时文件复制到这个位置了，把它记成当前文件
            isExportingDocument = false
            isNewDraft = false
            openedFileURL = url
            savedSource = editor.markdownSource
            refreshStatus()
            updateWindowTitle()
            flashStatus("已保存 \(url.lastPathComponent)")
        } else {
            // 「打开」：走正常的读文件流程（换基准目录、重建分块那些都在里面）
            openDocument(at: url)
        }
    }

    /// 用户点了取消：什么都不改，保持原样，顺手把导出标记清掉
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        isExportingDocument = false
        isExportingImage = false
    }
}
