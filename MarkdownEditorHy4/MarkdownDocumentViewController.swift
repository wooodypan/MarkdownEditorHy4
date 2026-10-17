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
    /// 悬浮在正文上的编辑按钮（半透明小圆点，点开是标题 / 待办 / 列表 / 加粗 / 斜体 / 更多）
    private let floatingEditButton = FloatingEditButton()
    /// 大纲协调者：把编辑器和目录面板连起来
    private let outlineCoordinator = OutlineCoordinator()
    /// 顶部的查找 / 替换横条（纯 UI 层，不认识编辑器）
    private let findBar = MarkdownFindBarView()
    /// 键盘上方那条工具条（挂在编辑器的 `inputAccessoryView` 上，最右边是「收起键盘」）
    private let keyboardBar = MarkdownKeyboardBarView()
    /// 查找协调者：把编辑器和查找横条连起来
    private let searchCoordinator = SearchCoordinator()
    /// 用户配置（「记住目录大纲滚动位置」等）。改完会发通知，下面挂了监听同步给大纲面板
    private let settings = MarkdownEditorSettings.shared
    /// 每份文档「上次读到哪儿」的记忆
    private let scrollMemory = DocumentScrollMemory.shared
    /// 导出这条链路（图片 / HTML / PDF）。
    ///
    /// 实现整个在 `DocumentExporter` 里 —— 左栏右键导出走的也是它那一份，两处导出来的东西才一样。
    /// 这里只交代三件事：谁弹面板（本页）、popover 从哪儿长出来（右上角那个「⋯」）、进度往哪儿写（底部状态栏）。
    private lazy var exporter = DocumentExporter(
        presenter: self,
        anchorView: menuButton,
        // 主题用闭包取「点导出那一刻」的：用户可能刚换过配色，建菜单时定下来的话导出的是旧配色
        theme: { [weak self] in self?.editor.renderer.theme ?? .default },
        onStatus: { [weak self] in self?.flashStatus($0) }
    )
    private var bottomConstraint: NSLayoutConstraint?
    /// 正文右边那条约束。
    ///
    /// 单独留一根引用，是因为它的 constant 要跟着大纲面板变：面板展开时正文往左让出
    /// 和面板一样宽的一块，字才不会被浮动的大纲卡片压住（见 `outlineTrailingInset`）
    private var editorTrailingConstraint: NSLayoutConstraint?

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
    /// 「这次存完就把这一页弹回去」。
    ///
    /// ### 为什么不能存完当场弹、非得先记一笔
    /// iPhone 上点「返回」选了「保存」之后，存盘**不一定这一下就完** ——新建的文档还顶着占位名，会先弹个框请用户起名字（见 `promptForFileName`），输完名字才算真的存完。所以这里先挂一笔「存完就走」，等 `writeCurrentSource` 真正写成功那一次再执行；中途取消就把它抹掉。
    private var popAfterSaving = false
    /// 「从左边缘滑回去」那个手势原来的代理。
    ///
    /// 装了返回确认之后，这个手势的代理归本页管（见 `takeOverPopGestureIfNeeded`）——离开之前必须原样还回去，否则**下一个页面**要滑的时候没人管，会滑出半截卡在原地的动画（导航条跟着失去响应）。
    private weak var popGesturePreviousDelegate: UIGestureRecognizerDelegate?
    /// 临时提示（比如「已保存」）显示完要恢复成常规状态栏
    private var statusResetWork: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // 顺序有讲究：菜单按钮先建好（正文、大纲、查找条的上边界都拿它当参照，参照物本身见 `contentTopAnchor`）
        setupMenuButton()
        // 左上角那个「返回」也得换成自己一颗：系统那颗按下直接走人，中间没有插话的机会
        setupBackButton()
        setupEditor()
        setupStatusLabel()
        // ⚠️ 顺序有讲究：**先把用户存过的设置写进主题，再装文档**。
        // 反过来（先 `apply(item)` 再 `applyEditorStyle()`）会让同一份内容渲染两次：
        // `setMarkdown` 先用默认主题整篇渲一遍，紧接着 `refreshTheme()` 再用真主题整篇重渲一遍。
        // 用户改过字号 / 行高的话，那就是白花一次整篇渲染的功夫（实测 ~155 ms，占打开文档的两成）。
        // 这里只写主题、不重排 —— 编辑器此刻还没内容，重排等于空跑。
        applyStyleToTheme()
        // 套用宿主送来的内容项。到这一步才做，是因为下面的界面这时才建好 ——
        // 而且大纲的「初次拉取」也依赖文档已经装进去了。
        // 这一次渲染用的就是上面那套最终主题，不用再来第二遍
        if let item = pendingItem {
            apply(item)
        }
        // 放在文档加载**之后**：装配时的「初次拉取」才能真正拉到标题。
        // 放前面也能跑（编辑器那次 push 会被忽略），但会白拉一次空列表
        setupOutline()
        // 查找条放在最后：它是浮层，后加的视图画在上面，这样它才盖得住正文和大纲面板
        setupFindBar()
        // 悬浮编辑按钮再晚一步：它得盖在查找条上面（圆点要能被拖到屏幕最上面那条）
        setupFloatingEditButton()
        observeKeyboard()
        observeEditorChanges()
        observeSettingsChanges()
        observeWorkspaceChanges()
        // 离开前台时把「读到哪儿」记一笔（用户常常是随手切走、再也没回来）
        observeAppLifecycle()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 窗口（windowScene）要等 view 挂上去才有，标题在这里补一次
        updateWindowTitle()
        // 接管「左边缘滑回去」手势的代理 —— 只在 iPhone 上、且真的在导航栈里时才拿得到
        takeOverPopGestureIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 代理要还回导航控制器，理由见 `giveBackPopGesture`。
        // 弹设置 / 主题面板时这个回调也会走一趟，不要紧 ——那些面板关掉、本页重新出现时 `viewDidAppear` 会再接管一次
        giveBackPopGesture()
    }

    /// 窗口尺寸变了（拉窗口、转屏）之后把悬浮圆点拉回可见范围。
    ///
    /// 圆点是**绝对坐标**摆着的（它要能被拖动，用约束反而绕），窗口一变矮原来的 y 就跑到窗口外面去了。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        floatingEditButton.clampCenterIntoSuperview()
        // 窗口尺寸变了 → 大纲面板的宽度也跟着变（它是按父视图宽度算的），
        // 正文要让出的那一块得重新算一次。值没变时这里什么都不做
        updateEditorTrailingInset()
    }

    // MARK: 界面搭建

    private func setupEditor() {
        editor.translatesAutoresizingMaskIntoConstraints = false
        // 粘贴的图片存到 Documents，bundle 里的 sample.png 走兜底逻辑也能找到
        editor.imageBaseURL = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first
        // 装上公式渲染器：有这一行，`$...$` / `$$...$$` 才会被渲染成公式图。
        // 没有也照样能用 —— 编辑器组件本身不认识任何公式引擎，
        // 没注入的时候公式就按源码原文显示（这是给将来开源出去留的默认降级）
        editor.renderer.mathRenderer = SwiftMathRenderer.shared
        // 装上图表渲染器：有这一行，```mermaid 围栏块才会被画成一张图。
        // 没有也照样能用 —— 块会按普通代码块显示（灰底 + 源码原文），和公式那条降级是同一个设计：
        // 编辑器组件只认 `MarkdownMermaidRenderer` 协议，不认识 MermaidKit 是谁
        editor.renderer.mermaidRenderer = MermaidKitRenderer.shared
        // 装上「剪贴板富文本 → markdown」的转换器：有这一行，从网页复制内容再粘贴，粘进来的才是 markdown 源码（标题、列表、表格…），而不是一堆 HTML 标签。
        // 转不转由设置页那个开关说了算 —— 关掉时转换器返回 nil，粘贴就退回原来的纯文本。
        // 组件本身不认识 App 的转换器，只留了 `richTextConverter` 这么一个口子。
        editor.pasteboardController.richTextConverter = { pasteboard in
            ClipboardHTMLMarkdown.markdown(from: pasteboard)
        }
        // 装上「图片存到哪儿、文件叫什么名字」的决定者：粘贴图片时组件会问一句
        // 「这份字节存哪儿、正文里写什么路径」，还会把图片**原来的文件名**一起递过来（没有就是 nil）。
        // 两个答案都按设置页「插入图片」那一组的选择给（见 `ImageAssetStore`）。
        // ⚠️ 这里读 `openedFileURL` 是**每次插入的那一刻**才读的：用户可能中途换了文档，
        // 图片得跟着当前这份笔记走，不能装配时就把路径记死
        editor.pasteboardController.imageFileWriter = { [weak self] data, originalFileName in
            guard let self else { return nil }
            let outcome = ImageAssetStore.write(data, for: self.openedFileURL, originalFileName: originalFileName)
            // 本来是存到指定文件夹、结果没写成（文件夹被挪走之类）时，得让用户知道图去哪儿了 ——
            // 不然他会以为「粘贴没反应」
            if let note = outcome.note { self.flashStatus(note) }
            return outcome.path
        }
        view.addSubview(editor)

        bottomConstraint = editor.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        // 右边这条要先拿到手：它的 constant 会随大纲展开 / 收起改（见 updateEditorTrailingInset）
        let trailing = editor.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        editorTrailingConstraint = trailing
        NSLayoutConstraint.activate([
            // 上边直接钉在菜单栏下面 —— 跟查找条无关，查找条出现 / 消失正文都不会动
            // （iPhone 上按钮在导航栏里，`contentTopAnchor` 给的是安全区上边）
            editor.topAnchor.constraint(equalTo: contentTopAnchor, constant: 2),
            editor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            trailing,
            bottomConstraint!
        ])

        // 点正文里的图片 → 弹 QuickLook 预览。
        // 编辑器只负责认出「点到了哪张图」，弹窗得由能 present 的这一层来做
        editor.onImageTapped = { [weak self] attachment in
            self?.previewImage(attachment)
        }

        // 键盘上方挂一条工具条：左边撤销 / 重做，右边「收起键盘」（手机上键盘挡住半屏，得留个出口）。
        // 工具条本身不认识编辑器，所以三个动作都在这里接上。
        // 只有软键盘弹出来时它才看得见 —— Mac 上接着实体键盘打字的话，这一条不会出现。
        keyboardBar.onDismissKeyboard = { [weak self] in
            self?.editor.resignFirstResponder()
        }
        keyboardBar.onUndo = { [weak self] in
            guard let self else { return }
            // 撤销 / 重做走编辑器自己的门面（它内部用的是系统的 undoManager，键盘输入那套账也在同一个栈上）
            self.editor.undoEdit()
            // 撤完这一格，能不能继续撤 / 能不能重做都变了，立刻把两粒按钮的亮灭刷一次
            self.refreshKeyboardBarButtons()
        }
        keyboardBar.onRedo = { [weak self] in
            guard let self else { return }
            self.editor.redoEdit()
            self.refreshKeyboardBarButtons()
        }
        editor.inputAccessoryView = keyboardBar
        refreshKeyboardBarButtons()
    }

    // MARK: 键盘工具条

    /// 把「撤销 / 重做」两粒按钮的亮灭跟撤销栈对齐：栈是空的就按灰显示，点了也不会有反应。
    ///
    /// 为什么不止在装配时刷一次：撤销栈随时在变，而按钮自己不知道 —— 这几个时机各刷一次就够用了：
    /// ① 正文一变（打字、从悬浮按钮改格式）；② 键盘动了（条马上要出现，状态可能是上一次留下的）；③ 刚按过撤销 / 重做。
    private func refreshKeyboardBarButtons() {
        keyboardBar.setUndoEnabled(editor.canUndoEdit, redoEnabled: editor.canRedoEdit)
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
            findBar.topAnchor.constraint(equalTo: contentTopAnchor, constant: 2),
//            findBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            findBar.widthAnchor.constraint(equalToConstant: 350),
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

    /// 悬浮编辑按钮：一个能被拖着走的半透明小圆点，点开是常用的那几个排版动作。
    ///
    /// ### 为什么接两根线就够了
    /// 按钮本身不认识编辑器内部，也不认识 markdown 语法：
    /// 「哪个按钮对应哪几个字符」写在 `MarkdownQuickAction` 里，这里只告诉它「动作施加到 `editor` 上」。
    private func setupFloatingEditButton() {
        floatingEditButton.textView = editor
        view.addSubview(floatingEditButton)
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
            // （iPhone 上按钮在导航栏里，这条自动变成「贴着安全区上边」）
            outlineView.topAnchor.constraint(equalTo: contentTopAnchor, constant: 6),
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

        // 第四根线：面板收起 / 展开 → 正文右边距重算。
        // 面板自己不认识正文，所以这条只能由这一层接（让多少也是这一层的事，见 `outlineTrailingInset`）
        outlineView.onCollapseStateChanged = { [weak self] _ in
            self?.updateEditorTrailingInset()
        }

        // 默认收起：冷启动时右上角只留一个小方块（展开按钮），点它才展开整份目录。
        // 目录属于「想看的时候看一眼」的东西，默认摊开会一直占着正文右上角
        outlineView.setCollapsed(true, animated: false)
        // 按用户的配置定高度（默认「父视图高度的 70%」当上限）
        applyOutlineAppearance()

        // 主动要一次初次数据。文档这时已经加载完了，编辑器不会再有「标题变了」的通知；
        // 不主动拉的话目录会一直空着（编辑器里那次 push 发生时装配还没完成）
        outlineCoordinator.reloadFromEditor()
    }

    /// 「⋯」按钮是不是挂到导航栏上（iPhone 那套布局）。
    private var usesNavigationBarMenuButton: Bool {
        DeviceHelper.currentLayout == .iPhone
    }

    /// 正文的「上边界」，正文、查找条、悬浮目录都拿它当参照物。
    ///
    /// - **iPhone**：「⋯」按钮搬进了导航栏（见 `setupMenuButton`），页面里没这个按钮了，正文直接顶着安全区上边开始 —— 安全区上边界本来就已经在导航栏下面了；
    /// - **iPad / Mac**：按钮仍然浮在右上角，正文得从它下边开始，免得第一行被盖住。
    ///
    /// ⚠️ 这两条**不能**合成一条：iPhone 上 `menuButton` 挂在导航栏里，和 `view` 不在同一棵视图树上，拿它当参照去激活约束会直接抛异常。
    private var contentTopAnchor: NSLayoutYAxisAnchor {
        usesNavigationBarMenuButton ? view.safeAreaLayoutGuide.topAnchor : menuButton.bottomAnchor
    }

    /// 页面右上角的「⋯」按钮。
    /// ### iPhone 上它进导航栏，iPad / Mac 上它浮在正文右上角
    /// iPhone 屏幕窄，正文本来就紧张，顶部再浮一个按钮更挤 —— 而导航栏右上角正好空着，挂上去既不占正文宽度，也符合 iPhone 上「更多」在右上角的习惯。
    /// iPad / Mac 那一侧，本页是多 Tab 宿主里的子控制器、**不在导航栈里**（`navigationItem` 没地方显示），所以维持原样：按钮浮在正文右上角。
    private func setupMenuButton() {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "ellipsis.circle")
        config.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        // 图标本身不大，靠内边距把可点区域撑到 40x40，手指和鼠标都好点
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)

        menuButton.configuration = config
        // 关键的一行：设为 true 后，单击就弹菜单，不需要长按等右键那一套
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = makeActionMenu()
        menuButton.accessibilityLabel = "更多操作"

        // iPhone：整颗按钮交给导航栏当 rightBarButtonItem
        if usesNavigationBarMenuButton {
            menuButton.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: menuButton)
            return
        }
        // iPad / Mac ...按钮留在 self.view 里，靠约束定位
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(menuButton)

        NSLayoutConstraint.activate([
            menuButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
            menuButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            menuButton.widthAnchor.constraint(equalToConstant: 40),
            menuButton.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    /// 导航栏左上角的「返回」按钮（只在 iPhone 上装）。
    ///
    /// ### 为什么要自己造一颗，不用系统那颗
    /// 系统那颗按下就 pop，中间没有插话的机会 —— 这一页改过的东西会**静默丢掉**。
    /// 换成自己这颗，就能在真正走人之前先问一句「要不要存」（见 `handleBackTapped`）。
    ///
    /// ### iPhone 上这是**唯一的存盘入口**
    /// 「⋯」菜单里没有「保存」这一项，iPhone 上也没有 ⌘S（⌘S 是 Mac 菜单栏的事）——不问一句，用户改了半天一返回就全没了。
    ///
    /// ### 只在 iPhone 上装
    /// iPad / Mac 上这一页是多 Tab 宿主里的子控制器、**不在导航栈里**（理由同 `setupMenuButton`），压根没有「返回」这回事；那边关掉一页由 Tab 自己的关闭按钮管。
    private func setupBackButton() {
        guard usesNavigationBarMenuButton else { return }

        // 用系统那个 chevron 图标，看着和原来的返回按钮一样。
        // 不带文字 —— 上一页（左侧栏）本来也没设标题，系统那颗画出来也就是个箭头
        let item = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"),
                                   style: .plain,
                                   target: self,
                                   action: #selector(handleBackTapped))
        // 只有图标没有文字，读屏软件得靠这一句知道它是什么
        item.accessibilityLabel = "返回"
        // 关键的一行：换上自己这颗之后，系统那颗就不再出现了
        navigationItem.leftBarButtonItem = item
    }

    // MARK: 只读模式

    /// 动作菜单里那个「只读模式」开关（打开了左边带一个勾）。
    ///
    /// ### 为什么必须存成属性，而不是在 `makeActionMenu()` 里现造一个
    /// 勾是记在 **action 对象自己** 身上的（`UIAction.state`）。每次弹菜单都新建一个 action 的话，
    /// 勾会永远停在创建时的初始值 —— 明明已经打开了，菜单里却不显示勾，看着像「点了没反应」。
    /// 所以整个控制器生涯只用这一个实例，每次点击就地改它的 `state`（和下面那几个调试开关同一个坑）。
    private lazy var readOnlyAction = UIAction(
        title: "只读模式",
        image: UIImage(systemName: "lock"),
        // 初始的勾要照着配置里「上次存下来的状态」画：开了只读关掉 App 再进来，菜单里得是勾着的
        state: settings.isReadOnly ? .on : .off
    ) { [weak self] action in
        self?.toggleReadOnly(action)
    }

    /// 拨一下「只读模式」：改配置 → 同步给编辑器 → 改勾 → 状态栏说一句。
    ///
    /// ### 为什么这里手动再赋一次 `editor.isReadOnly`
    /// 配置的通知（`MarkdownEditorSettings.didChangeNotification`）走的是「写主题 + **整篇重渲染**」那条路，
    /// 而这只个**行为**开关，一个字都不用重排 —— 特意绕开那条重活，直接赋值即可。
    /// （打开文档那条恢复状态的路子另有 `applyStyleToTheme`，两边互补。）
    private func toggleReadOnly(_ action: UIAction) {
        let isOn = !settings.isReadOnly
        settings.setIsReadOnly(isOn)
        editor.isReadOnly = isOn
        action.state = isOn ? .on : .off
        flashStatus(isOn ? "只读模式：能选能复制，键盘也不再弹出来" : "已退出只读模式，可以编辑了")
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

    /// 「显示标尺」开关（只在 Debug 版本里存在）。
    ///
    /// 打开之后编辑器上边和左侧会浮出一条半透明标尺，读数是**文档坐标下的 pt** —— 和代码里打印的那些矩形（代码块灰底、引用竖条、折叠锚点）用的是同一套数，想核对「画上去的东西有没有偏」时直接把读数拿去和日志比就行。
    ///
    /// 和前两条一样必须存成属性：勾（`UIAction.state`）是记在 action 对象自己身上的，每次现造一个的话勾会永远停在初始值。
    #if DEBUG
    private lazy var rulerAction = UIAction(
        title: "显示标尺",
        image: UIImage(systemName: "ruler"),
        state: .off
    ) { [weak self] action in
        guard let self else { return }
        // 返回值就是「现在开着吗」：true = 刚挂上，false = 刚摘掉
        let isOn = self.editor.installRuler()
        action.state = isOn ? .on : .off
        self.flashStatus(isOn ? "已显示标尺（读数是文档坐标，单位 pt）" : "已隐藏标尺")
    }
    #endif

    /// 组装弹出菜单里的条目。
    /// 每一项就是一行：标题 + 图标 + 点击后要执行的代码（`UIAction`），或者一个带下级菜单的入口（`UIMenu`，「导出」就是这种）。
    private func makeActionMenu() -> UIMenu {
        let actions: [UIMenuElement] = [
            UIAction(title: "查找", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                // 顶部滑出查找 / 替换横条
                self?.showFindBar()
            },
            // 「只读模式」带勾开关：一开，这份文档就只能看不能改了（见 toggleReadOnly）
            readOnlyAction,
            // 导出（图片 / HTML / PDF）收成**一项子菜单**：展开才选格式。
            // 这一组菜单项由 `DocumentExporter` 生成 —— 左栏右键那个「导出」是同一份，两处永远一致
            exporter.exportMenu { [weak self] in self?.exportSource() },
            UIAction(title: "主题", image: UIImage(systemName: "paintpalette")) { [weak self] _ in
                // 单独一页挑配色（内置几套 + 可选的 JSON 文件）
                self?.showThemePicker()
            },
            UIAction(title: "设置", image: UIImage(systemName: "gearshape")) { [weak self] _ in
                // 弹出设置页（正文排版、大纲、表格列宽都在那儿）
                self?.showSettings()
            },
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
            UIAction(title: "校验", image: UIImage(systemName: "checkmark.seal")) { [weak self] _ in
                // 全选复制，比对复制出来的文本和源码是否逐字符一致
                self?.verifyRoundTrip()
            }
        ]

        #if DEBUG
        // 调试项单独成一组：`.displayInline` 让它就地展开（不变成二级菜单），
        // 菜单里会在它上面画一条分隔线，免得和上面那些正常功能混在一起被误点。
        // 整个 `#if DEBUG` 都删掉，Release 包里就没有这一项了。
        // 以后再加调试开关，只往这个数组里塞一个 action 就行，别的不用动
        let debugSection = UIMenu(
            options: .displayInline,
            children: [textKitDebugAction, viewBordersAction, rulerAction]
        )
        return UIMenu(children: actions + [debugSection])
        #else
        return UIMenu(children: actions)
        #endif
    }

    // MARK: 设置

    /// 打开设置页。「⋯」菜单里的「设置」和 Mac 菜单栏的「设置…」(⌘,) 都走到这里。
    ///
    /// ⚠️ 这里刻意不加 `private`：Mac 菜单栏那条 ⌘, 要引用它的 selector（`AppDelegate.buildMenu`），别处写的 `#selector` 够不到 `private` 的方法，编译直接报「inaccessible due to 'private' protection level」—— 和下面 `saveDocument` 是同一个理由。
    ///
    /// 具体怎么开（Mac 独立窗口 / 其它设备模态，还有「已经开着就不再开一个」）收在 `SettingsOpener.open(from:)` 里，这里只回答「从谁身上开」。
    @objc func showSettings() {
        SettingsOpener.open(from: self)
    }

    /// 弹出主题页。
    ///
    /// 为什么单开一页而不是在设置页里加一个分组：主题往后不止三套，设置页那套「一个分组 + 一个分段控件」的写法选项一多就挤成了「…」。
    /// 包导航栏的理由和设置页那个一样 —— 「完成」要挂在导航栏上。
    ///
    /// ### 这一页改了不用手动刷新编辑器
    /// 它写的是同一个 `settings`，改动会发出 `didChangeNotification`，本页面的 `settingsDidChange` 收到后照旧调用 `applyEditorStyle()`；
    /// 关掉页面的时候编辑区已经换成新配色了。
    @objc private func showThemePicker() {
        let controller = MarkdownThemeViewController(settings: settings)
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

    /// 把「配色」「正文排版」「表格（列宽 + 源码样式）」「图片尺寸」这几组配置写进编辑器主题，再套上主题外壳（编辑区字号、链接样式、底色）。**不重排。**
    ///
    /// 🚨 单拆出来是为了「打开文档」那条路：那边必须在 `setMarkdown` **之前**调它，让文档那一次渲染就用上最终主题。
    /// 顺序反过来（先 `setMarkdown` 再 `refreshTheme()`）会先用默认主题整篇渲一遍、紧接着再用真主题整篇重渲一遍 —— 同一份内容白渲染两次，实测各 ~155 ms（2026-10-11 的 Time Profiler）。
    ///
    /// 「为什么这四组必须一起写」见下面 `applyEditorStyle` 的注释。
    private func applyStyleToTheme() {
        // 配色放最前面：它只改颜色，后面那三组（字号、表格列宽、图片尺寸）
        // 会再按用户拖过的滑块覆盖自己那几个值，两者不冲突
        settings.applyColors(to: &editor.renderer.theme,
                             customPalette: MarkdownCustomThemeStore.shared
            .loadPalette(named: settings.customThemeFileName))
        // 编辑区外面的这一圈（宿主留白、大纲底下的底板）也要跟着底色走 ——
        // 深色主题下编辑区黑了、四周边框还是白的，看着像没换干净。
        // ⚠️ 大纲面板那一块刻意不动：它用的是系统色，自己会跟着系统的浅色 / 深色外观走
        view.backgroundColor = editor.renderer.theme.editorBackground
        settings.applyTypography(to: &editor.renderer.theme)
        settings.applyTableColumnWidths(to: &editor.renderer.theme)
        // 表格源码的字号 / 颜色：必须排在 `applyColors` 之后，
        // 用户单独指定的那一色才不会被配色表盖掉（理由见 `applyTableSourceStyle`）
        settings.applyTableSourceStyle(to: &editor.renderer.theme)
        settings.applyImageSize(to: &editor.renderer.theme)
        // 行宽是**编辑器自己的布局参数**，不走主题 ——
        // 主题管「文字长什么样」，行宽取决于窗口有多宽，是布局的事
        editor.maxContentWidth = settings.bodyContentWidthLimit.map { CGFloat($0) }
        // 行号是编辑器自己的显示开关：改它会让左边的装订线占/让出一条带子，正文宽度跟着变
        editor.showsLineNumbers = settings.showsLineNumbers
        // 只读模式是编辑器的**行为**开关（能不能改），和长什么样无关，单独赋值一次
        editor.isReadOnly = settings.isReadOnly
        // 「引用内容加底色」是**渲染期**读的开关，改完要整篇重渲染才见效 ——
        // 从设置页过来那条路会走到 `applyEditorStyle()`（里面有刷新），不用在这儿再排一遍
        editor.renderer.theme.showsQuoteBackground = settings.showsQuoteBackground
        // 「行内代码反引号加底色」同理：底色是渲染时挂到字符上的，改完必须重渲染
        editor.renderer.theme.inlineCodeBacktickHasBackground =
            settings.showsInlineCodeBacktickBackground
        // 字号 / 链接色 / 底色存在 view 自己身上，不跟着富文本走，得手动搬一次
        editor.applyThemeChrome()
    }

    /// 设置变了（设置页改了排版、主题页换了配色）：写主题 + 整篇重排一遍。
    ///
    /// ### 为什么这四组合成一个方法
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
        applyStyleToTheme()
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
        // 宽度变了 → 正文要让出去的那块也得跟着变。
        // 这一句同时是「设置页里那个留白开关」的落点：`settingsDidChange` 会走到这里
        updateEditorTrailingInset()
    }

    /// 大纲展开时，正文右边要给出去多少（`0` = 一点都不让）。
    ///
    /// ### 算的是什么
    /// 面板本身的宽度 + 它离屏幕右边那点留白（`edgeMargin`）+ 一点呼吸空间，
    /// 这样正文的右边界正好落在卡片左边缘左边一点点，字不会被卡片压住。
    ///
    /// ### 收起时为什么不让
    /// 收起态就是右上角那个 46×36 的小方块，只压住一个角；为它把整列正文挤窄不值当。
    ///
    /// ### 为什么要封顶
    /// 面板宽度可以调到占屏幕的 80%（「按百分比」模式）。真照这个数让，窄屏上正文就只剩一条缝了，
    /// 所以这里保底给正文留一半宽度：宁可让卡片盖住一点，也不能让正文没法读。
    ///
    /// ### 为什么还要再问一句设备
    /// iPhone 竖屏才三百来点宽，上面那个「封顶一半」也救不回来 —— 让完每行只剩两三个字。
    /// 所以这一项在 iPhone 上**固定不生效**（设置里也不显示那个开关，判断同在
    /// `MarkdownEditorSettings.supportsReservingSpaceForOutline`）
    private var outlineTrailingInset: CGFloat {
        guard settings.reservesSpaceForOutline,
              MarkdownEditorSettings.supportsReservingSpaceForOutline else { return 0 }
        // 收起时 occupiedWidth 就是 0，下面那道判断会直接返回
        let occupied = outlineView.occupiedWidth
        guard occupied > 0, view.bounds.width > 0 else { return 0 }
        let wanted = occupied + outlineView.appearance.edgeMargin + Self.outlineEditorGap
        return min(wanted, view.bounds.width * Self.maximumOutlineShare)
    }

    /// 正文和面板之间再空出多少（点）。纯视觉：贴着卡片边缘排字会显得很挤
    private static let outlineEditorGap: CGFloat = 8
    /// 正文最多让出父视图宽度的这个比例（0.5 = 让人一半、自己留一半）
    private static let maximumOutlineShare: CGFloat = 0.5

    /// 把正文右边距改成「该给大纲让出多少」。
    ///
    /// ⚠️ 值没变就直接返回：这个方法会在**每次布局**里被调（`viewDidLayoutSubviews`），
    /// 不判一下的话相当于每次布局都改一次约束，Auto Layout 会被拖着多跑一轮又一轮。
    ///
    /// ### 为什么不做动画（明明大纲卡片自己是动画收放的）
    /// 编辑器一改宽度就会**整篇重排**（见 `MarkdownTextView.layoutSubviews` 里按 `renderedWidth` 重渲那一段）。
    /// 把它塞进 `UIView.animate` 的话，Auto Layout 会在 0.22 秒里逐帧改宽度，等于每帧整篇重渲一遍 ——
    /// 小文档看不出来，长文档直接卡成幻灯片。所以这里让正文「啪」地一下换到新宽度，
    /// 只有大纲卡片自己滑过去；两条动画不同步，换来的是不掉帧。
    private func updateEditorTrailingInset() {
        guard let editorTrailingConstraint else { return }
        let inset = outlineTrailingInset
        // 约束上的值是负的（往左收），所以比较时取反
        guard abs(-editorTrailingConstraint.constant - inset) > 0.5 else { return }
        // 不在这儿催布局：这个方法多数时候是在布局过程中被调的（`viewDidLayoutSubviews`），
        // 当场 `layoutIfNeeded()` 等于就地再跑一轮。设完 constant，系统下一拍自然会重排
        editorTrailingConstraint.constant = -inset
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

    /// 目录里的文件被改名了 → 我要是正开着那一份，得把「我对应哪个文件」换过来
    private func observeWorkspaceChanges() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(documentDidRename(_:)),
                                               name: DocumentsWorkspace.didRenameNotification,
                                               object: nil)
    }

    /// 左栏右键「重命名」改的是**磁盘上的路径**，而我这边把路径记在 `openedFileURL` 里当「⌘S 写回哪儿」用。
    ///
    /// ### 不跟着换会出什么事
    /// 文件已经叫新名字了，我这边还记着旧名字 —— 用户回到正文按一次 ⌘S，内容就被写进**旧路径**：磁盘上凭空多出一份重复文件，而新名字那份反而是旧的。
    /// 所以改完名必须把路径、图片基准目录、阅读位置的钥匙、标题一起换过来。
    @objc private func documentDidRename(_ notification: Notification) {
        guard let from = notification.userInfo?[DocumentsWorkspace.renameFromURLKey] as? URL,
              let to = notification.userInfo?[DocumentsWorkspace.renameToURLKey] as? URL,
              // 改的不是我这份（或者我根本没有文件）→ 跟我没关系
              openedFileURL == from else { return }

        openedFileURL = to
        // 旧路径那条「读到哪儿」没人用了。文件名以后可能被重新用上，那时不该莫名跳到文档中间 —— 所以要主动忘掉（和删除那份文档时做的是同一件事）
        scrollMemory.forget(key: from.path)

        // 界面还没建好（Tab 先建、后显示）时只改路径就够了，剩下的等 viewDidLoad 走正常流程
        guard isViewLoaded else { return }
        // 相对路径的图片基准目录也跟着换（文件挪了名字，同目录一般没变，但别依赖「一般」）
        editor.imageBaseURL = to.deletingLastPathComponent()
        // 位置先在**新钥匙**下记一笔，免得刚改完名就被忘掉
        rememberCurrentScrollPosition()
        updateWindowTitle()
        refreshStatus()
        flashStatus("已改名为 \(DocumentsWorkspace.displayName(for: to))")
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
        // ⚠️ 换文档必须把撤销栈清空：栈里的旧账是按**上一份文档的文本**记的（范围、长度、整篇快照都是），
        // 套到新文档上要么越界崩溃（实测：在空文档里 ⌘Z 弹出上一份文档的旧记录，直接 NSRangeException），
        // 要么把上一份文档的内容整篇灌进当前编辑器 —— 再按一次 ⌘S 就把新文件覆盖掉了。
        // 只在这里清、不放进 setMarkdown：撤销 / 重做自己也靠 setMarkdown 整篇恢复，放进等于每撤销一次就清空一次。
        if !isSameDocument {
            editor.resetUndoHistory()
        }
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

    // MARK: 返回前的确认

    /// 导航栏左上角「返回」被点了一下。
    ///
    /// 没改过就直接回去；改过就先问一句「存 / 不存 / 算了」。
    @objc private func handleBackTapped() {
        guard isDirty else {
            popBack()
            return
        }
        promptSaveBeforeLeaving()
    }

    /// 有改动没存时，走之前问一句要怎么办。
    ///
    /// ### 为什么是三个选项
    /// - **保存**：存完再走（存盘可能要绕一趟「起名字」，见 `saveThenLeave`）；
    /// - **不保存**：按用户说的走、改动丢掉 —— 用 `destructive` 红字，别让手滑的人误点；
    /// - **取消**：留在这一页接着改。多这一个按钮，是因为返回键太好按到了：
    ///   只给「存 / 不存」的话，手滑一下就只能两害相权，白搭一次改动。
    ///
    /// 返回按钮和「从左边缘滑回去」两条路都走这里（见 `gestureRecognizerShouldBegin`），所以「带着改动离开」这个规矩只有一处。
    private func promptSaveBeforeLeaving() {
        // 已经弹着东西了（比如用户连滑两下）就不再叠一个
        guard presentedViewController == nil else { return }

        let name = openedFileURL?.lastPathComponent ?? "这份文档"
        let alert = UIAlertController(title: "要保存改动吗？",
                                      message: "「\(name)」改了还没存，返回就没了。",
                                      preferredStyle: .alert)

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "不保存", style: .destructive) { [weak self] _ in
            self?.popBack()
        })
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
            self?.saveThenLeave()
        })

        present(alert, animated: true)
    }

    /// 返回时选了「保存」：存完就把这一页弹回去。
    ///
    /// ### 为什么这里只是「挂个标记」，不直接存完再弹
    /// 存盘这一下**可能不是终点** —— 新建的文档还顶着占位名，`saveDocument()`
    /// 会先弹框请用户起名字（见 `promptForFileName`），输完名字才算真的存完。
    /// 所以这里先挂一笔「存完就走」，由 `writeCurrentSource` 在真正写成功那一次执行；
    /// 用户中途取消（不起名字了）就把标记抹掉，人留在原地。
    private func saveThenLeave() {
        guard openedFileURL != nil else {
            // 没有对应文件（宿主没送内容项），存不了。
            // 走正常保存那条路把提示弹出来就行，别顺手设标记 —— 没地方可存，也就没有「存完」那一刻
            saveDocument()
            return
        }
        popAfterSaving = true
        saveDocument()
    }

    /// 把这一页从导航栈里弹回去（等于按了返回）。
    private func popBack() {
        navigationController?.popViewController(animated: true)
    }

    /// 把「从左边缘滑回去」那个手势的代理接过来（只在 iPhone 上）。
    ///
    /// ### 为什么要管这个手势
    /// 返回按钮拦住了，可用户还能从左边缘一滑 —— 那条路一样会静默 pop，改动照样丢，等于只堵了一半。接了代理之后就能在 `gestureRecognizerShouldBegin` 里先看一眼「改过没有」，改过就不让滑、改问一句。
    ///
    /// ### 为什么要把原来那个代理存下来
    /// 这个手势的代理本来是**导航控制器自己**，它靠代理做两件事：
    /// 拦下「栈里只有一页时的手势」（不然会滑出半截卡住的动画），以及驱动交互式转场。
    /// 本页离开时必须原样还回去 —— 直接把代理置空，下一个页面就要出怪事。
    private func takeOverPopGestureIfNeeded() {
        guard usesNavigationBarMenuButton,
              let gesture = navigationController?.interactivePopGestureRecognizer,
              gesture.delegate !== self else { return }
        popGesturePreviousDelegate = gesture.delegate
        gesture.delegate = self
    }

    /// 把「左边缘滑回去」手势的代理还回去。
    private func giveBackPopGesture() {
        guard let gesture = navigationController?.interactivePopGestureRecognizer,
              gesture.delegate === self else { return }
        gesture.delegate = popGesturePreviousDelegate
        popGesturePreviousDelegate = nil
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
        // 说一声，让左侧栏重新扫一遍目录。
        // 左栏每一行上显示着**文档首行的预览**和**修改日期**，不通知的话用户按完 ⌘S左边那两行还是旧的 —— Mac 上左栏一直看得见，这个陈旧会更明显。
        // 照旧走通知，别在这儿直接去刷别的视图控制器
        NotificationCenter.default.post(name: DocumentsWorkspace.didChangeNotification, object: nil)
        // 存盘是个天然的「我读到这儿了」的时间点，顺手记一次
        rememberCurrentScrollPosition()
        refreshStatus()
        updateWindowTitle()
        flashStatus("已保存 \(url.lastPathComponent)")

        // 返回时选的「保存」：到这儿才算真的存完了，可以把这一页弹回去。
        // ⚠️ 等一拍再弹 —— 此刻还在保存这条调用链上，链尾（`save(from:as:)` 那边）
        // 接着还要用 self 收尾，当场把页面弹掉会让那些动作落在已经拆掉的界面上
        if popAfterSaving {
            popAfterSaving = false
            DispatchQueue.main.async { [weak self] in
                self?.popBack()
            }
        }
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
            // 若这次保存是「返回」那条路发起的（选了保存、结果被问名字），取消就等于「别走了」—— 把标记抹掉，人留在原地
            self?.popAfterSaving = false
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
        alert.addAction(UIAlertAction(title: "好", style: .cancel) { [weak self] _ in
            // 名字一直定不下来，这一次保存就此作罢。
            // 若它是「返回」那条路发起的，这一下就等于放弃保存 —— 别把页面弹走
            self?.popAfterSaving = false
        })
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
        // 刚敲进去的字也是一笔可以撤销的账，键盘条上那两粒按钮跟着变
        refreshKeyboardBarButtons()
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

    // MARK: 导出

    /// 点「导出」时交给 `DocumentExporter` 的那份内容。
    ///
    /// ### 为什么是「点的时候现取」而不是建菜单时取
    /// 菜单是装配时建好的一个实例，一直用着它。内容若在建菜单那一刻就定下来，用户改了半天的稿再点导出，导出的还是打开菜单之前那一版。
    ///
    /// 空文档在这里就拦下（`DocumentExporter` 那边还会再兜一次底）：一份空白文档导出来没有任何意义。
    private func exportSource() -> DocumentExportSource? {
        let source = editor.markdownSource
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showAlert(title: "导出失败", message: "当前文档是空的，没有可导出的内容。")
            return nil
        }
        return DocumentExportSource(
            markdown: source,
            displayName: documentDisplayName,
            fileURL: openedFileURL,
            // 正开着这份文档，图片就让编辑器自己画 —— 画出来就是屏幕上看到的那个样子
            imageRenderer: { [weak self] in self?.editor.renderFullContentImage() }
        )
    }

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
        // 键盘一动，上面那条工具条马上要出现 / 消失 —— 顺手把撤销 / 重做的亮灭跟当前撤销栈对齐
        refreshKeyboardBarButtons()
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
// 这个代理现在只剩「打开」（⌘O）这一条路：挑一份文件，交给左侧栏在新 Tab 里打开。
// 导出那半边（挑个位置存文件）已经搬进 `DocumentExporter` —— 它自己当那个面板的代理，于是这里不用再靠一个「这次是打开还是导出」的标记去猜（原来的 `isExportingFile` 就是干这个的）。

extension MarkdownDocumentViewController: UIDocumentPickerDelegate {

    /// 用户挑完了要打开哪份文件
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }

        // 走 MarkdownDocumentOpener 而不是自己去读，是为了顺带申请一次安全作用域（文件在工作目录之外时，不申请就写不回去），它会把通知发出去、由左侧栏在**新 Tab** 里打开这份文件 —— 当前这一页不动
        MarkdownDocumentOpener.shared.handle(url: url)
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

extension MarkdownDocumentViewController: UIGestureRecognizerDelegate {

    /// 「从左边缘滑回去」这个手势要不要开始。
    ///
    /// 两条判据，缺一不可：
    /// 1. **栈里得真有两页以上** —— 这是导航控制器自己原来那条判据，接代理时最容易漏。
    ///    漏了的话在根页（左侧栏）上也能滑，滑出来是个卡住的半截动画，导航条从此不吃点击；
    /// 2. **没有未保存的改动** —— 滑完就直接 pop 走了，中间没有插话的机会，
    ///    所以改过就不让它滑：这一下先拒掉（免得留下半截动画），再把返回按钮那个确认框弹出来，两条路的规矩保持一致。
    ///
    /// 代理只装在「左边缘滑回去」这一个手势上（见 `takeOverPopGestureIfNeeded`），别的手势不会走到这儿来。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 根页不许滑：不然后面没有可返回的页面，手势会滑出一个卡死的半截动画
        guard (navigationController?.viewControllers.count ?? 0) > 1 else { return false }
        guard isDirty else { return true }

        // 等这一下手势处理完再弹框：在 `shouldBegin` 里当场 present，会和正在收尾的手势状态撞上
        DispatchQueue.main.async { [weak self] in
            self?.promptSaveBeforeLeaving()
        }
        return false
    }
}
