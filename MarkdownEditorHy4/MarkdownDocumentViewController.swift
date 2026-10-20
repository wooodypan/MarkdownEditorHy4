//
//  MarkdownDocumentViewController.swift
//  MarkdownEditorHy4
//
//  「一份文档」这一页：markdown 编辑器 + 悬浮目录 + 右上角「⋯」菜单
//  （查找、只读模式、导出、主题、设置、重载、分块、源码、校验）。
//  Mac 上另有菜单栏：文件 > 新建 / 打开 / 存储。
//
//  ### 它是右侧多 Tab 里的内容页
//  它不决定「我是第几个 Tab、什么时候被关掉」，那些由 `MultiTabController` 的详情宿主
//  （`DetailHostViewController`）管。它只需要满足库要求的 `PPContentDisplaying`：
//  能被一份内容项配置（`configure(with:)`），能拿到一个上报通道（`contentHost`）。
//
//  ### 它同时是 Command 键命令的落点
//  ⌘N / ⌘O / ⌘S 都靠响应链找到当前这一页：哪个 Tab 在前台，命令就作用在它身上。
//  多 Tab 编辑本来就该这样，不用另写「当前 Tab 是哪个」的分发逻辑。
//
//  ### 这个类的代码分在好几个文件里
//  这一份只留状态（属性）、生命周期、界面搭建和菜单；其余按主题拆成
//  `MarkdownDocumentViewController+XXX.swift`，里面全是 extension。
//  拆出来时代码原样搬过去，只去掉了 `private`（Swift 的 private 只在本文件可见）。
//
//  - `+FindReplace`：查找 / 替换横条
//  - `+FloatingEditButton`：悬浮圆点 + 插图
//  - `+ImagePreview`：点图片弹 QuickLook
//  - `+Settings`：设置页 / 主题页入口、写主题、大纲让位
//  - `+DocumentContent`：装载内容项、阅读位置、改名
//  - `+Save`：⌘S 那一串
//  - `+Leave`：返回前的确认、手势代理
//  - `+DocumentActions`：菜单背后的动作（新建 / 打开 / 校验 / 源码 / 分块 / 重载 / 导出 / 键盘避让）
//
//  两个小工具在 `DocumentAlert` / `DocumentTextDiff` 里。
//

import UIKit
import MultiTabController

/// ⚠️ `PPContentDisplaying` 必须写在类型声明上，不能只写个 extension：内容页工厂的闭包声明成「返回 `PPContentDisplaying`」，少了这一致性，闭包体里那个 `MarkdownDocumentViewController()` 就转换不过去。
/// 编译器报的却是一句很难懂的 `unable to infer closure type without a type annotation`，指着一整个闭包，看不出真正的问题。
final class MarkdownDocumentViewController: UIViewController, PPContentDisplaying {

    // MARK: 与多 Tab 宿主的连接

    /// 宿主注入的上报通道。
    ///
    /// ⚠️ 必须 `weak`：宿主强引用着每一个 Tab 的内容页（这是「保活」的实现方式），
    /// 这里再强引用回去就成了循环引用，Tab 关掉也放不掉。
    weak var contentHost: PPContentHosting?

    /// 有人在我还是「预览 Tab」的时候改了我，就告诉宿主把我固定成正式 Tab。
    ///
    /// 只报一次，也**只报 true**：宿主那边的约定是「收到 true 就把这一页固定下来，收到 false 就把预览标记还回去」。
    /// 如果保存之后顺手报一个 false，用户双击开出来的正式 Tab 会被降级回预览，被下一次单击顶掉，就反了。
    var didReportEdited = false

    /// 内容项可能在 `viewDidLoad` **之前**就送到了（宿主要先建好 Tab 才会显示它）。
    /// 先存下来，等界面搭好再套用。这也是库在 `PPContentDisplaying` 里写明的约定
    var pendingItem: PPContentItem?

    // MARK: 子视图

    let editor = MarkdownTextView()
    private let statusLabel = UILabel()
    /// 右上角的「⋯」按钮。点一下弹出菜单：查找、只读模式、导出、主题、设置、重载、分块、源码、校验
    private let menuButton = UIButton(type: .system)
    /// 悬浮目录面板（纯 UI 层，不认识编辑器）
    let outlineView = MarkdownOutlineView()
    /// 悬浮在正文上的编辑按钮（半透明小圆点，点开是标题 / 待办 / 列表 / 加粗 / 斜体 / 图片 / 更多）
    let floatingEditButton = FloatingEditButton()
    /// 正在挑图片的选择器。挑完或取消之前必须强引用着它：
    /// `UIDocumentPickerViewController.delegate` 是 weak，不持有的话回调还没来对象就没了
    var imagePicker: MarkdownImagePicker?
    /// 大纲协调者：把编辑器和目录面板连起来
    private let outlineCoordinator = OutlineCoordinator()
    /// 顶部的查找 / 替换横条（纯 UI 层，不认识编辑器）
    let findBar = MarkdownFindBarView()
    /// 键盘上方那条工具条（挂在编辑器的 `inputAccessoryView` 上，最右边是「收起键盘」）
    private let keyboardBar = MarkdownKeyboardBarView()
    /// 查找协调者：把编辑器和查找横条连起来
    let searchCoordinator = SearchCoordinator()
    /// 用户配置（「记住目录大纲滚动位置」等）。改完会发通知，下面挂了监听同步给大纲面板
    let settings = MarkdownEditorSettings.shared
    /// 每份文档「上次读到哪儿」的记忆
    let scrollMemory = DocumentScrollMemory.shared
    /// 导出这条链路（图片 / HTML / PDF）。
    ///
    /// 实现整个在 `DocumentExporter` 里，左栏右键导出走的也是它那一份，两处导出来的东西才一样。
    /// 这里只交代三件事：谁弹面板（本页）、popover 从哪儿长出来（右上角那个「⋯」）、进度往哪儿写（底部状态栏）。
    private lazy var exporter = DocumentExporter(
        presenter: self,
        anchorView: menuButton,
        // 主题用闭包取「点导出那一刻」的：用户可能刚换过配色，建菜单时定下来的话导出的是旧配色
        theme: { [weak self] in self?.editor.renderer.theme ?? .default },
        onStatus: { [weak self] in self?.flashStatus($0) }
    )
    var bottomConstraint: NSLayoutConstraint?
    /// 正文右边那条约束。
    ///
    /// 单独留一根引用，是因为它的 constant 要跟着大纲面板变：面板展开时正文往左让出和面板一样宽的一块，字才不会被浮动的大纲卡片压住（见 `outlineTrailingInset`）
    var editorTrailingConstraint: NSLayoutConstraint?

    /// 当前这一页对应磁盘上的哪个文件，也就是 ⌘S 要写回哪里。
    ///
    /// 正常情况下一定有值（每个 Tab 都是被某一份文件开出来的）。为 nil 只有一种情形：
    /// 宿主没送内容项就直接把我显示出来了（不该发生），这时按「未命名」对待、
    /// ⌘S 会提示没有可保存的文件。
    var openedFileURL: URL?
    /// 上次打开/保存时的源码快照，和它比对就知道有没有改动
    var savedSource = ""
    /// 有没有未保存的改动
    var isDirty: Bool { editor.markdownSource != savedSource }
    /// 「这次存完就把这一页弹回去」。
    ///
    /// ### 为什么不能存完当场弹、非得先记一笔
    /// iPhone 上点「返回」选了「保存」之后，存盘不一定这一下就完：新建的文档还顶着占位名，会先弹个框请用户起名字（见 `promptForFileName`），输完名字才算真的存完。所以这里先挂一笔「存完就走」，等 `writeCurrentSource` 真正写成功那一次再执行，中途取消就把它抹掉。
    var popAfterSaving = false
    /// 「从左边缘滑回去」那个手势原来的代理。
    ///
    /// 装了返回确认之后，这个手势的代理归本页管（见 `takeOverPopGestureIfNeeded`）。离开之前必须原样还回去，否则下一个页面要滑的时候没人管，会滑出半截卡在原地的动画，导航条跟着失去响应。
    weak var popGesturePreviousDelegate: UIGestureRecognizerDelegate?
    /// 临时提示（比如「已保存」）显示完要恢复成常规状态栏
    private var statusResetWork: DispatchWorkItem?
    /// 状态栏重算的防抖任务。
    ///
    /// 打字每敲一个键、拖光标每一帧都会想让状态栏重算一次，而算一次要扫全篇源码（字数）。
    /// 合并成 0.12 秒一次的尾部触发，中间那些全丢掉。
    private var statusRefreshWork: DispatchWorkItem?

    /// 状态栏那条高度。固定的 22 点（字号 11 加一点呼吸），不随设置变
    private static let statusBarHeight: CGFloat = 22

    /// 上一次统计用的源码。字数、行首表都挂在它上面 —— 光标移动时源码一个字都没变，没必要把全篇再扫一遍（`String` 的相等比较是先比长度再走 memcmp，比逐字扫快得多）
    private var statsSource: String?
    /// 上面那份源码的字数（去掉空白后的字符数）
    private var statsCharacterCount = 0
    /// 上面那份源码里每一行的起始偏移（UTF-16）。光标一动只要二分一下就知道在第几行
    private var statsLineStarts: [Int] = [0]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // 顺序有讲究：菜单按钮先建好（正文、大纲、查找条的上边界都拿它当参照，参照物本身见 `contentTopAnchor`）
        setupMenuButton()
        // 左上角那个「返回」也得换成自己一颗：系统那颗按下直接走人，中间没有插话的机会
        setupBackButton()
        setupEditor()
        setupStatusLabel()
        // ⚠️ 顺序有讲究：先把用户存过的设置写进主题，再装文档。
        // 反过来（先 `apply(item)` 再 `applyEditorStyle()`）会让同一份内容渲染两次：
        // `setMarkdown` 先用默认主题整篇渲一遍，紧接着 `refreshTheme()` 再用真主题整篇重渲一遍。
        // 用户改过字号 / 行高的话，就白花一次整篇渲染的功夫（实测约 155 ms，占打开文档的两成）。
        // 这里只写主题、不重排：编辑器此刻还没内容，重排等于空跑。
        applyStyleToTheme()
        // 套用宿主送来的内容项。到这一步才做，是因为界面这时才建好，而且大纲的初次拉取也依赖文档已经装进去。
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
        // 接管「左边缘滑回去」手势的代理，只在 iPhone 上、真的在导航栈里时才拿得到
        takeOverPopGestureIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 代理要还回导航控制器，理由见 `giveBackPopGesture`。
        // 弹设置 / 主题面板时这个回调也会走一趟，不要紧：那些面板关掉、本页重新出现时 `viewDidAppear` 会再接管一次
        giveBackPopGesture()
    }

    /// 窗口尺寸变了（拉窗口、转屏）之后把悬浮圆点贴回边上。
    ///
    /// 圆点是按绝对坐标摆的（它要能被拖动，用约束反而绕），窗口一变原来的位置就可能离边很远，或者跑到窗口外面去。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        floatingEditButton.clampCenterIntoSuperview()
        // 窗口尺寸变了，大纲面板的宽度也跟着变（它按父视图宽度算），
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
        // 没有也照样能用：编辑器组件本身不认识任何公式引擎，没注入时公式按源码原文显示（给将来开源留的默认降级）
        editor.renderer.mathRenderer = SwiftMathRenderer.shared
        // 装上图表渲染器：有这一行，```mermaid 围栏块才会被画成一张图。
        // 没有也照样能用，块会按普通代码块显示（灰底 + 源码原文），和公式那条降级是一个设计：
        // 编辑器组件只认 `MarkdownMermaidRenderer` 协议，不认识 MermaidKit
        editor.renderer.mermaidRenderer = MermaidKitRenderer.shared
        // 装上「剪贴板富文本 → markdown」的转换器：有这一行，从网页复制内容再粘贴，粘进来的才是 markdown 源码（标题、列表、表格…），而不是一堆 HTML 标签。
        // 转不转由设置页那个开关说了算，关掉时转换器返回 nil，粘贴就退回原来的纯文本。
        // 组件本身不认识 App 的转换器，只留了 `richTextConverter` 这么一个口子。
        editor.pasteboardController.richTextConverter = { pasteboard in
            ClipboardHTMLMarkdown.markdown(from: pasteboard)
        }
        // 装上「图片存到哪儿、文件叫什么名字」的决定者：粘贴图片时组件会问一句这份字节存哪儿、正文里写什么路径，还会把图片原来的文件名一起递过来（没有就是 nil）。
        // 两个答案都按设置页「插入图片」那一组的选择给（见 `ImageAssetStore`）。
        // ⚠️ 这里每次插入的那一刻才读 `openedFileURL`：用户可能中途换了文档，图片得跟着当前这份笔记走，不能在装配时把路径记死
        editor.pasteboardController.imageFileWriter = { [weak self] data, originalFileName in
            guard let self else { return nil }
            let outcome = ImageAssetStore.write(data, for: self.openedFileURL, originalFileName: originalFileName)
            // 本来要存到指定文件夹、结果没写成（文件夹被挪走之类）时，得让用户知道图去哪儿了，
            // 不然他会以为粘贴没反应
            if let note = outcome.note { self.flashStatus(note) }
            return outcome.path
        }
        // 装上「网页里的图要不要存到本地」：粘贴网页内容时，正文里还是 `https://…` 的图片会先下载一份，按同一套「插入图片」的设置存进对应目录，再把地址换成本地路径，拔了网线笔记里的图也还在。
        // 返回 false 表示这次没有网络图片要存（或者设置里关了），粘贴照旧当场插入，不用等。
        editor.pasteboardController.webImageLocalizer = { [weak self] markdown, completion in
            guard let self else { return false }
            // ⚠️ 和上面那个回调一样，这里读的是按下粘贴那一刻的文档，不是装配时的那份
            return WebMarkdownImageSaver.localize(markdown,
                                                  documentURL: self.openedFileURL,
                                                  onStatus: { [weak self] message in
                                                      self?.flashStatus(message)
                                                  },
                                                  completion: completion)
        }
        view.addSubview(editor)

        bottomConstraint = editor.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        // 右边这条要先拿到手：它的 constant 会随大纲展开 / 收起改（见 updateEditorTrailingInset）。
        // 常态就是左边距那个数，展开大纲时再往左多让一块
        let trailing = editor.trailingAnchor.constraint(equalTo: view.trailingAnchor,
                                                        constant: -Self.editorHorizontalInset)
        editorTrailingConstraint = trailing
        NSLayoutConstraint.activate([
            // 上边直接钉在菜单栏下面，跟查找条无关：查找条出现或消失，正文都不会动
            //（iPhone 上按钮在导航栏里，`contentTopAnchor` 给的是安全区上边）
            editor.topAnchor.constraint(equalTo: contentTopAnchor, constant: 2),
            // 左右各留 20 点：正文贴着窗口边会显得很挤，也给大纲卡片留点余地
            editor.leadingAnchor.constraint(equalTo: view.leadingAnchor,
                                            constant: Self.editorHorizontalInset),
            trailing,
            bottomConstraint!
        ])

        // 点正文里的图片就弹 QuickLook 预览。
        // 编辑器只负责认出「点到了哪张图」，弹窗得由能 present 的这一层来做
        editor.onImageTapped = { [weak self] attachment in
            self?.previewImage(attachment)
        }

        // 键盘上方挂一条工具条：左边撤销 / 重做，右边「收起键盘」（手机上键盘挡住半屏，得留个出口）。
        // 工具条本身不认识编辑器，所以三个动作都在这里接上。
        // 只有软键盘弹出来时它才看得见，Mac 上接着实体键盘打字的话这一条不会出现。
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

    private func setupStatusLabel() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 1
        statusLabel.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.9)
        // 字数、行列这些数字随时在变，读屏软件念这个标签时得先说清它是干什么的
        statusLabel.accessibilityLabel = "文档状态"
        view.addSubview(statusLabel)

        let height = statusLabel.heightAnchor.constraint(equalToConstant: Self.statusBarHeight)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            height
        ])
        // 用户可能在上一次会话里把状态栏关掉了，建完就地按配置摆好
        applyStatusBarVisibility()
    }

    // MARK: 键盘工具条

    /// 把「撤销 / 重做」两粒按钮的亮灭跟撤销栈对齐：栈是空的就按灰显示，点了也不会有反应。
    ///
    /// 为什么不止在装配时刷一次：撤销栈随时在变，按钮自己不知道。这几个时机各刷一次就够用：
    /// ① 正文一变（打字、从悬浮按钮改格式）；② 键盘动了（条马上要出现，状态可能是上一次留下的）；③ 刚按过撤销或重做。
    func refreshKeyboardBarButtons() {
        keyboardBar.setUndoEnabled(editor.canUndoEdit, redoEnabled: editor.canRedoEdit)
    }

    // MARK: 图片预览

    /// 当前正在预览的那一项。预览逻辑在 `+ImagePreview`，属性留在这里由控制器持有。
    ///
    /// ⚠️ 必须**持有**着：QuickLook 异步去取数据，预览窗还开着的时候这个对象不能已经释放了。
    var previewItem: ImagePreviewItem?

    /// 悬浮目录：建视图，并把编辑器、协调者、目录面板三者接起来。
    ///
    /// ### 为什么装配代码必须在这里
    /// `OutlineCoordinator` 不建在编辑器或目录面板内部：
    /// - 建在编辑器里，编辑器就认识了协调者，将来换协调者策略得改编辑器；
    /// - 建在面板里，面板就得知道去哪找编辑器。
    ///
    /// 放在上层容器里，三者的生命周期和连接关系集中在一处，两个组件初始化都不需要对方的实例。
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

        // 第四根线：面板收起或展开，正文右边距重算。
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
    var usesNavigationBarMenuButton: Bool {
        DeviceHelper.currentLayout == .iPhone
    }

    /// 正文的上边界，正文、查找条、悬浮目录都拿它当参照物。
    ///
    /// - iPhone：「⋯」按钮搬进了导航栏（见 `setupMenuButton`），页面里没这个按钮，正文直接顶着安全区上边开始，而安全区上边界本来就在导航栏下面；
    /// - iPad / Mac：按钮仍然浮在右上角，正文得从它下边开始，免得第一行被盖住。
    ///
    /// ⚠️ 这两条不能合成一条：iPhone 上 `menuButton` 挂在导航栏里，和 `view` 不在同一棵视图树上，拿它当参照去激活约束会直接抛异常。
    var contentTopAnchor: NSLayoutYAxisAnchor {
        usesNavigationBarMenuButton ? view.safeAreaLayoutGuide.topAnchor : menuButton.bottomAnchor
    }

    /// 页面右上角的「⋯」按钮。
    /// ### iPhone 上进导航栏，iPad / Mac 上浮在正文右上角
    /// iPhone 屏幕窄，正文本来就紧张，顶部再浮一个按钮更挤，而导航栏右上角正好空着。挂上去不占正文宽度，也符合 iPhone 上「更多」在右上角的习惯。
    /// iPad / Mac 那边，本页是多 Tab 宿主里的子控制器，不在导航栈里（`navigationItem` 没地方显示），所以维持原样：按钮浮在正文右上角。
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
        // iPad / Mac：「⋯」按钮留在 self.view 里，靠约束定位
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
    /// 系统那颗按下就 pop，中间没有插话的机会，这一页改过的东西会静默丢掉。换成自己这颗，就能在真正走人之前先问一句要不要存（见 `handleBackTapped`）。
    ///
    /// ### iPhone 上这是唯一的存盘入口
    /// 「⋯」菜单里没有「保存」这一项，iPhone 上也没有 ⌘S（那是 Mac 菜单栏的事），不问一句，用户改了半天一返回就全没了。
    ///
    /// ### 只在 iPhone 上装
    /// iPad / Mac 上这一页是多 Tab 宿主里的子控制器，不在导航栈里（理由同 `setupMenuButton`），压根没有「返回」这回事，那边关掉一页由 Tab 自己的关闭按钮管。
    private func setupBackButton() {
        guard usesNavigationBarMenuButton else { return }

        // 用系统那个 chevron 图标，看着和原来的返回按钮一样。
        // 不带文字：上一页（左侧栏）本来也没设标题，系统那颗画出来也只是个箭头
        let item = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"),
                                   style: .plain,
                                   target: self,
                                   action: #selector(handleBackTapped))
        // 只有图标没有文字，读屏软件得靠这一句知道它是什么
        item.accessibilityLabel = "返回"
        // 关键的一行：换上自己这颗之后，系统那颗就不再出现了
        navigationItem.leftBarButtonItem = item
    }

    // MARK: 打字机模式

    /// 菜单里那个「打字机模式」开关（打开时左边带一个勾）。
    ///
    /// 理由同下面 `readOnlyAction`：勾记在 action 对象自己身上，每次现造一个的话会永远停在初始值。
    private lazy var typewriterAction = UIAction(
        title: "打字机模式",
        image: UIImage(systemName: "text.aligncenter"),
        state: settings.isTypewriterMode ? .on : .off
    ) { [weak self] action in
        self?.toggleTypewriter(action)
    }

    /// 拨一下「打字机模式」：写配置、告诉编辑器、改勾。
    ///
    /// ### 为什么也手动再赋一次 `editor.isTypewriterMode`
    /// 和「只读模式」同一个理由：这只是个滚动行为开关，一个字都不用重排，没必要等设置广播那条重活。
    private func toggleTypewriter(_ action: UIAction) {
        let isOn = !settings.isTypewriterMode
        settings.setIsTypewriterMode(isOn)
        editor.isTypewriterMode = isOn
        action.state = isOn ? .on : .off
        flashStatus(isOn ? "打字机模式：光标始终停在屏幕中间" : "已退出打字机模式")
    }

    /// 把菜单里那个勾对齐到当前配置（开关是全局的，别的 Tab 拨过之后这一页要跟上）。
    func syncTypewriterActionState() {
        typewriterAction.state = settings.isTypewriterMode ? .on : .off
        // 勾改了还得重挂一次菜单，否则挂在上面的旧快照还带着上一轮的勾
        refreshActionMenu()
    }

    // MARK: 只读模式

    /// 动作菜单里那个「只读模式」开关（打开了左边带一个勾）。
    ///
    /// ### 为什么必须存成属性，而不是在 `makeActionMenu()` 里现造一个
    /// 勾是记在 action 对象自己身上的（`UIAction.state`）。每次弹菜单都新建一个 action 的话，勾会永远停在创建时的初始值：明明已经打开了，菜单里却不显示勾，看着像点了没反应。
    /// 所以整个控制器生涯只用这一个实例，每次点击就地改它的 `state`。下面那几个调试开关同理。
    private lazy var readOnlyAction = UIAction(
        title: "只读模式",
        image: UIImage(systemName: "lock"),
        // 初始的勾要照着配置里「上次存下来的状态」画：开了只读关掉 App 再进来，菜单里得是勾着的
        state: settings.isReadOnly ? .on : .off
    ) { [weak self] action in
        self?.toggleReadOnly(action)
    }

    /// 拨一下「只读模式」：改配置、同步给编辑器、改勾，再让状态栏说一句。
    ///
    /// ### 为什么这里手动再赋一次 `editor.isReadOnly`
    /// 配置的通知（`MarkdownEditorSettings.didChangeNotification`）走的是「写主题 + 整篇重渲染」那条路，而这只是个行为开关，一个字都不用重排，所以绕开那条重活，直接赋值。
    /// 打开文档那条恢复状态的路子另有 `applyStyleToTheme`，两边互补。
    private func toggleReadOnly(_ action: UIAction) {
        let isOn = !settings.isReadOnly
        settings.setIsReadOnly(isOn)
        editor.isReadOnly = isOn
        action.state = isOn ? .on : .off
        // 只读模式没有自己的 sync 方法，勾在这里改，菜单也在这里重挂
        refreshActionMenu()
        flashStatus(isOn ? "只读模式：能选能复制，键盘也不再弹出来" : "已退出只读模式，可以编辑了")
    }

    // MARK: 状态栏开关

    /// 菜单里那个「显示状态栏」开关（打开时左边带一个勾）。
    ///
    /// 理由同 `readOnlyAction`：勾记在 action 对象自己身上，每次现造一个的话会永远停在初始值。
    private lazy var statusBarAction = UIAction(
        title: "显示状态栏",
        image: UIImage(systemName: "character.cursor.ibeam"),
        state: settings.showsStatusBar ? .on : .off
    ) { [weak self] action in
        self?.toggleStatusBar(action)
    }

    /// 拨一下「显示状态栏」：写配置，当场收起 / 展开底下那条带子。
    ///
    /// 关掉时它要显示的「字数 / 行列」也一并停算（见 `refreshStatus`），省得白扫全篇。
    /// 打开时立刻算一次 —— 不然要等第一次动光标才有数字。
    private func toggleStatusBar(_ action: UIAction) {
        let isOn = !settings.showsStatusBar
        settings.setShowsStatusBar(isOn)
        action.state = isOn ? .on : .off
        applyStatusBarVisibility()
        if isOn { refreshStatus() }
    }

    /// 把菜单里那个勾对齐到当前配置。
    ///
    /// 开关是全局的：别的 Tab 拨过之后，这一页菜单里还挂着旧的勾。
    /// 不同步的话勾停在旧状态，用户点一下想关、实际却是开，看着像「点了没反应」。
    func syncStatusBarActionState() {
        statusBarAction.state = settings.showsStatusBar ? .on : .off
        // 同「打字机模式」：改完勾要重挂菜单
        refreshActionMenu()
    }

    // MARK: 调试菜单项

    /// 「TextKit 调试层」开关（只在 Debug 版本里存在）。
    ///
    /// 理由同 `readOnlyAction`：勾记在 action 对象自己身上，每次现造一个的话会永远停在初始值。
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
        // 和其它带勾的开关一样，改完勾要重挂菜单
        self.refreshActionMenu()
        self.flashStatus(isOn ? "已显示：红=行框 蓝=usedRect 绿=附件 橙=容器" : "已隐藏 TextKit 调试层")
    }
    #endif

    /// 「视图描边」开关（只在 Debug 版本里存在）。
    ///
    /// 相当于网页里那句 `*{outline:1px dashed red}` 书签：递归走一遍窗口里的视图树，给每个 layer 描一圈极细的边，用来查这个控件到底占了多大、有没有伸出父视图、谁盖住了谁。
    ///
    /// 和上面那条一样，必须存成属性而不是每次现造一个（理由见 `readOnlyAction`）。
    #if DEBUG
    private lazy var viewBordersAction = UIAction(
        title: "视图描边",
        image: UIImage(systemName: "square.dashed"),
        // 初始的勾按「现在是不是真描着边」来：`ViewBorders.installIfRequested` 那条环境变量 (`VIEW_BORDERS=1`) 的路子可能已经在启动时描上了，菜单里的勾得和实际状态一致，否则第一次点下去看着像「点了没反应」
        state: ViewBorders.isVisible ? .on : .off
    ) { [weak self] action in
        guard let self else { return }
        // 传 window 而不是 self.view：从窗口根开始描，才能把状态栏、弹出菜单这些不在本控制器视图树里的东西一起描上。
        // ⚠️ 窗口还没挂上时这里是 nil，此时 ViewBorders 会退化成「所有活跃窗口」，正好也是想要的效果，不用额外兜底
        let isOn = ViewBorders.toggle(in: self.view.window)
        action.state = isOn ? .on : .off
        self.flashStatus(isOn ? "已显示视图描边（颜色按层级轮换）" : "已隐藏视图描边")
    }
    #endif

    /// 「显示标尺」开关（只在 Debug 版本里存在）。
    ///
    /// 打开之后编辑器上边和左侧会浮出一条半透明标尺，读数是文档坐标下的 pt，和代码里打印的那些矩形（代码块灰底、引用竖条、折叠锚点）用的是同一套数。想核对画上去的东西有没有偏时，直接把读数拿去和日志比。
    ///
    /// 和前两条一样必须存成属性，理由见 `readOnlyAction`。
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

    /// 重新挂一遍「⋯」菜单，让那几个开关的勾当场刷新。
    ///
    /// ### 为什么改完 `state` 还得重挂
    /// 按钮上挂着的 `UIMenu` 是**照着当时那份 action 状态拍下来的快照**：就地改 `UIAction.state` 不会让已经挂上去的菜单重画。
    /// 只改不重挂的症状就是「开关明明已经关了，菜单里还带着勾」。所以凡是改勾的地方，改完都得走这一趟。
    private func refreshActionMenu() {
        menuButton.menu = makeActionMenu()
    }

    /// 组装弹出菜单里的条目。
    /// 每一项就是一行：标题 + 图标 + 点击后要执行的代码（`UIAction`），或者一个带下级菜单的入口（`UIMenu`，「导出」就是这种）。
    private func makeActionMenu() -> UIMenu {
        let actions: [UIMenuElement] = [
            UIAction(title: "查找", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                // 顶部滑出查找 / 替换横条
                self?.showFindBar()
            },
            // 「打字机模式」带勾开关：光标始终停在屏幕中间，正文跟着光标滚（见 toggleTypewriter）
            typewriterAction,
            // 「只读模式」带勾开关：一开，这份文档就只能看不能改了（见 toggleReadOnly）
            readOnlyAction,
            // 「显示状态栏」带勾开关：底下那条「字数 · 行列」的带子可以整条收掉
            statusBarAction,
            // 导出（图片 / HTML / PDF）收成一项子菜单，展开才选格式。
            // 这一组菜单项由 `DocumentExporter` 生成，左栏右键那个「导出」是同一份，两处永远一致
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

    #if targetEnvironment(macCatalyst)
    /// Mac 专属：把 ⌘N / ⌘O / ⌘S 注册成键盘快捷键。
    ///
    /// 整段用 `#if targetEnvironment(macCatalyst)` 包住，iOS 上根本不参与编译，所以 iOS 构建不受影响。
    ///
    /// AppDelegate 里往菜单栏加了同样三个条目，两边不会打架：macOS 先走菜单的快捷键匹配，菜单命中后就不再往下传，这里只是菜单那条路走不通时的兜底。
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
    var documentDisplayName: String {
        guard let url = openedFileURL else { return "未命名" }
        return DocumentsWorkspace.displayName(for: url)
    }

    func updateWindowTitle() {
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
        // 光标一动就刷状态栏上的「行 / 列」。
        // 编辑器那边已经做过防抖（0.12 秒一次），这里不必再叠一层
        editor.onCaretMoved = { [weak self] _ in
            self?.refreshStatus()
        }
    }

    @objc private func editorContentChanged() {
        updateWindowTitle()
        reportEditedStateIfNeeded()
        // 刚敲进去的字也是一笔可以撤销的账，键盘条上那两粒按钮跟着变
        refreshKeyboardBarButtons()
        // 字数变了。同样拖一下再算：每敲一个键就扫一遍全篇不值当
        scheduleStatusRefresh()
    }

    /// 「我改过了」这件事只上报一次，让宿主把这一页从「预览 Tab」固定成正式 Tab。
    ///
    /// 只报一次、也只报 true，原因见 `didReportEdited` 的注释。
    private func reportEditedStateIfNeeded() {
        guard isDirty, !didReportEdited else { return }
        didReportEdited = true
        contentHost?.contentViewController(self, didChangeEditedState: true)
    }

    /// 重算底部状态栏：字数 + 光标所在的行 / 列（有没保存的改动再标一句）。
    ///
    /// ### 「字数」怎么数
    /// 数的是**源码**里去掉空白（空格、换行、Tab）之后的字符数，标点和 markdown 语法符号都算在内。
    /// 这是中文写作工具里「字数」的常规口径；按渲染串数会漏掉被折叠的章节，按 UTF-16 单元数又会把 emoji 算成两个。
    ///
    /// ### 为什么要缓存
    /// 拖光标 / 打字时这里会被高频调到，而「第几行」得从源码开头数起。
    /// 每行的起始偏移按源码内容缓存一份，光标一动只要二分一次（见 `accumulateStatsIfNeeded`）。
    func refreshStatus() {
        applyStatusBarVisibility()
        // 状态栏关着就什么都不算：字数要扫全篇，光标每动一下就白跑一遍不值当
        guard settings.showsStatusBar else { return }

        let source = editor.markdownSource
        accumulateStatsIfNeeded(for: source)
        let position = lineAndColumn(ofSourceOffset: editor.cursorSourceOffset)

        var parts = ["字数 \(statsCharacterCount.formatted())",
                     "行 \(position.line) 列 \(position.column)"]
        if isDirty { parts.append("已修改") }
        statusLabel.text = parts.joined(separator: " · ")
    }

    /// 把状态栏的重算拖到 0.12 秒之后（连续打字 / 拖光标时只算最后一次）。
    ///
    /// 每敲一个键都当场算的话，长文档上每个键都要扫一遍源码，纯属浪费；
    /// 数字晚 0.12 秒跳一下，没人看得出来。
    func scheduleStatusRefresh() {
        statusRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshStatus() }
        statusRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// 按配置显示 / 收起状态栏。
    ///
    /// 只切 `isHidden`：正文的底边钉在 `view.bottomAnchor`，状态栏只是浮在它上面的一条带子，藏起来之后正文本来就已经铺满，没有哪块高度要还回去。
    func applyStatusBarVisibility() {
        statusLabel.isHidden = !settings.showsStatusBar
    }

    /// 把源码统计一遍（字数 + 每行的起始偏移），源码没变就直接用上一次的结果。
    ///
    /// `String` 的 `==` 先比长度、再比内容（memcmp），比逐字算一遍快得多 —— 打字时源码变了才真的重算，光标移动时几乎零开销。
    private func accumulateStatsIfNeeded(for source: String) {
        guard source != statsSource else { return }

        statsCharacterCount = source.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }

        var starts = [0]
        let text = source as NSString
        var scanned = 0
        while scanned < text.length {
            let found = text.range(of: "\n", options: [],
                                   range: NSRange(location: scanned, length: text.length - scanned))
            if found.location == NSNotFound { break }
            starts.append(found.location + 1)
            scanned = found.location + 1
        }
        statsLineStarts = starts
        statsSource = source
    }

    /// 源码偏移（UTF-16）在第几行第几列，都从 1 开始数。
    ///
    /// ⚠️ 列按 UTF-16 单元数：中文、英文一个字符一个单元，和人眼看到的列数一致；
    /// 只有 emoji 这类「一个字符两个单元」的会多算一列。
    private func lineAndColumn(ofSourceOffset offset: Int) -> (line: Int, column: Int) {
        let starts = statsLineStarts
        // 二分找「起始位置 <= 光标」的最后一行；光标停在文末的空行上也照样落得进去
        var low = 0
        var high = starts.count - 1
        var lineIndex = 0
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= offset {
                lineIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return (lineIndex + 1, offset - starts[lineIndex] + 1)
    }

    /// 状态栏上闪一句提示，1.5 秒后自动恢复成常规信息
    func flashStatus(_ message: String) {
        statusResetWork?.cancel()
        statusLabel.text = message
        let work = DispatchWorkItem { [weak self] in self?.refreshStatus() }
        statusResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: 小工具

    /// 弹提示。做法收在 `DocumentAlert` 里（含「冷启动时 view 还没挂到窗口上，present 会无效，得延后一帧」那条），这里只转一手
    func showAlert(title: String, message: String) {
        DocumentAlert.show(title: title, message: message, from: self)
    }
}

