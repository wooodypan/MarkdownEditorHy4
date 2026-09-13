//
//  MarkdownOutlineView.swift
//  MarkdownEditorHy4
//
//  悬浮目录（大纲）面板：Outline 模块里唯一一个懂「长什么样」的类
//

import UIKit

/// 悬浮目录面板的外观参数。
///
/// 集中放一处，改样式不用翻实现代码。
struct MarkdownOutlineAppearance {
    /// 展开时的理想宽度（宽度不够时会自动收窄，见 `MarkdownOutlineView.effectiveWidth`）
    var width: CGFloat = 210
    /// 自动收窄时的下限，再窄标题就没法看了
    var minimumWidth: CGFloat = 148
    /// 收起后那个小方块的宽度
    var collapsedWidth: CGFloat = 46
    /// 「按最大高度」模式下的高度上限（同样会被父视图高度压小）。
    /// ⚠️ `heightRatio` 有值时这一项**完全不参与计算**
    var maximumHeight: CGFloat = 360
    /// 面板高度最多占父视图高度的比例。
    ///
    /// - 有值（默认 `0.7` = 70%）→ 高度上限 = 父视图高度 × 这个比例，
    ///   此时 `maximumHeight` **失效**（用户调它不会有任何变化）；
    /// - `nil` → 高度上限改由 `maximumHeight` 决定。
    ///
    /// 由上层容器按用户在设置页选的模式注入 ——
    /// 这个文件不认识 App 层的配置，只认别人塞给它的值
    var heightRatio: CGFloat? = 0.7
    /// 标题栏高度（也是收起态的高度）
    var headerHeight: CGFloat = 36
    /// 每一行的高度
    var rowHeight: CGFloat = 30
    /// 列表整体上下留白
    var bodyVerticalPadding: CGFloat = 4
    /// 每一级标题相对上一级多缩进多少（H1 不缩进，H2 缩一档……）
    var indentPerLevel: CGFloat = 10
    /// 一行的最大缩进，防止 H6 把标题挤成竖排
    var maximumIndent: CGFloat = 48
    /// 面板距父视图边缘的留白（用来算「宽度够不够」）
    var edgeMargin: CGFloat = 12
    /// 卡片圆角
    var cornerRadius: CGFloat = 12
    /// 空文档时占位文字那块的高度
    var emptyStateHeight: CGFloat = 42
}

/// 悬浮目录面板。
///
/// ### 它只认识 `OutlineItem`
/// 这个文件里**不出现** `Markdown`（swift-markdown）、不出现 `NSTextLayoutManager`、
/// 不出现 `MarkdownTheme`、不出现编辑器任何类型。
///
/// 判断解耦有没有做到位有个很土但很准的办法：**看这个文件的 import 列表**。
/// 如果哪天发现它必须 import 编辑器相关的东西才能编译，就说明耦合已经漏进来了。
///
/// ### 交互
/// - 点某一行 → 通过 `delegate` 把 `OutlineItem` 报出去（谁接、接了干什么，它不知道）；
/// - 点一行右边的三角 → 展开 / 折叠这一节（收起来它下面的所有子标题）；
/// - 右上角箭头 → 收起成一个小方块，再点小方块展开（长文档时把编辑区让出来）。
///
/// ### 布局上的两个「自适应」
/// 面板自己不指定位置（位置由外部容器用约束定），只负责自己的
/// **宽度**和**高度**：宽度按父视图宽度的比例收窄，高度按内容算并压在上限之下。
/// 这样它在 iPhone 竖屏和 Mac Catalyst 大窗口里都能看。
///
/// ### 为什么折叠没有改用 `UICollectionView` + 系统树形数据源
/// 曾经评估过 `UICollectionView` + `NSDiffableDataSourceSectionSnapshot`
/// （系统专为「树状可展开列表」提供的 API，`Files.app` 用的就是它）。
/// 结论是**不适合本项目**，原因有三，都不是「嫌麻烦」：
///
/// 1. **它最诱人的那个好处在本项目不成立**。那套 API 的价值在于「数据更新时用稳定的
///    标识做 diff，折叠状态自然保留」。而本项目的 `OutlineItem.id` 复用
///    `MarkdownBlock.id`，编辑器每次增量编辑都会重建受影响的块、UUID 换新 ——
///    标识**不稳定**。所以不管用哪个 UI 控件，「折叠状态怎么跨重建活下来」这件事
///    都得自己写（`OutlineCollapseState` 就是干这个的）。换控件换不来这个好处。
/// 2. **面板高度是「算」出来的，不是「量」出来的**。这块毛玻璃卡片的高度
///    （`refreshPanelSize`）要跟父视图尺寸、行数一起算，并且和收起 / 展开动画联动。
///    改成 collection view 之后，高度就得反过来问布局系统要
///    （`collectionViewContentSize` 要等一次布局才准），
///    「约束算高度」和「布局算高度」两套机制互相等待，在 Catalyst 拉窗口时很容易抖。
/// 3. **行数根本不是瓶颈**。面板最高 360pt、行高 30pt，一屏最多显示十来行；
///    标题总数通常是几十个。整批重建视图（`rebuildRows`）在这个量级上是毫秒级，
///    换 collection view 的 cell 复用省不下什么。
///
/// 采用的是那套方案里真正解决问题的部分：**树结构**（`OutlineTree`）、
/// **折叠状态独立于数据更新**（`collapsedIDs` 单独存、每次更新对账）、
/// **高亮在折叠场景下往上找可见祖先**。这三条与用什么控件无关。
final class MarkdownOutlineView: UIView, MarkdownOutlineDisplaying {

    // MARK: 对外

    /// 用户点击某一行的出口。实现方是 `OutlineCoordinator`
    weak var delegate: MarkdownOutlineViewDelegate?

    /// 外观参数，建好之后也能改（改完调一次 `refreshAppearance()`）
    var appearance: MarkdownOutlineAppearance

    /// 当前是不是收起状态
    private(set) var isCollapsed = false

    /// 是否「记住滚动位置」（设置项，由上层容器按用户的配置注入；默认打开）。
    ///
    /// 打开时：光标所在章节切换 → 自动把那一行滚进可视区；列表因编辑重建 → 保持原位置。
    /// 关掉时：高亮只换颜色，列表停在你手滚到的位置，重建后回到顶部。
    ///
    /// 刻意做成一个普通属性而不是去读配置单例 —— 这个文件必须保持
    /// 「不认识编辑器、也不认识 App 层任何东西」，只认别人塞给它的值。
    var remembersScrollPosition = true

    // MARK: 数据

    /// 完整的标题列表（包含被折叠藏起来的那些）。
    /// 显示哪些行由 `tree` + `collapsedIDs` 算出来，见 `rebuildRows()`
    private var items: [OutlineItem] = []
    /// 由 `items` 建出来的层级树（谁是谁的子标题）
    private var tree = OutlineTree(items: [])
    /// 当前被折叠起来的标题 id。
    ///
    /// ### 为什么要单独存一份，而不是塞进 `OutlineItem` 里
    /// `OutlineItem` 每次编辑都会被整份换掉（块重建 → 新 id、新实例），
    /// 状态存在里面就等于「一编辑就没」。存在这里、并且每次更新时按
    /// `OutlineCollapseState` 对账到新的 id 上，折叠状态才能跨编辑活下来。
    private var collapsedIDs: Set<UUID> = []

    /// 当前**显示出来的**行，按显示顺序。
    /// 高亮定位、滚动定位都基于它（而不是含隐藏行的 `items`）
    private var visibleItems: [OutlineItem] = []

    /// id → 行视图。用来做高亮定位，不用每次遍历整个栈
    private var rows: [UUID: OutlineRowView] = [:]
    /// 当前高亮的 id。`nil` 表示没有任何一行是高亮的。
    /// ⚠️ 存的是「实际点亮的那一行」的 id —— 目标行被折叠藏起来时，
    /// 这里存的是往上找到的那个可见祖先（见 `highlightOutlineItem`）
    private var highlightedID: UUID?

    /// 最近一次「要求点亮谁」的 id（协调者给的原始 id，没做折叠折算）。
    ///
    /// ### 为什么要跟 `highlightedID` 分开存
    /// 行是整批重建的，重建之后旧的行视图全没了。要是只记「实际点亮的那一行」，
    /// 重建完就不知道该重新点亮谁 —— 表现是「点一下折叠三角，当前章节那行的底色也没了」。
    /// 记着原始目标就能照它重算一遍。数据更新时这个 id 可能已经过期，
    /// 那也没关系：协调者紧接着会用新 id 再发一次，照样覆盖
    private var requestedHighlightID: UUID?

    // MARK: 子视图

    /// 毛玻璃卡片本体。收起 / 展开都是改它的宽高约束，不换视图
    private let panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let headerBar = UIView()
    private let headerIcon = UIImageView()
    private let headerLabel = UILabel()
    private let collapseButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let rowsStack = UIStackView()
    /// 收起态铺满整卡的那个按钮
    private let expandButton = UIButton(type: .system)

    /// 卡片宽高（收起 / 展开都靠改这两个的 constant）
    private var panelWidthConstraint: NSLayoutConstraint!
    private var panelHeightConstraint: NSLayoutConstraint!

    // MARK: 初始化

    init(appearance: MarkdownOutlineAppearance = MarkdownOutlineAppearance()) {
        self.appearance = appearance
        super.init(frame: .zero)
        backgroundColor = .clear
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        // 和编辑器一样，界面全部走代码，不支持 storyboard
        fatalError("MarkdownOutlineView 不支持从 coder 解档")
    }

    // MARK: - MarkdownOutlineDisplaying

    /// 整份标题列表变了，重建所有行
    func updateOutlineItems(_ items: [OutlineItem]) {
        // 第一步先把「用户折叠了哪几个标题」认到新列表的 id 上。
        // 必须在这之前做：下面 `self.items = items` 一执行，旧 id 就再也查不到了
        collapsedIDs = OutlineCollapseState.inherit(from: self.items,
                                                    collapsedIDs: collapsedIDs,
                                                    to: items)
        self.items = items
        tree = OutlineTree(items: items)
        rebuildRows(animated: false, preserveScroll: remembersScrollPosition)
    }

    /// 高亮某一行；传 nil 表示取消所有高亮
    func highlightOutlineItem(_ id: UUID?) {
        // 记下「要求点亮的是谁」—— 行整批重建之后靠它把高亮补回来
        requestedHighlightID = id

        // 目标行可能正被折叠藏起来（光标在某个收起来的章节里打字）——
        // 那种情况下应该点亮「往上找到的那个可见祖先」，而不是一个用户根本看不见的行
        let targetID = visibleRepresentativeID(for: id)

        guard targetID != highlightedID else { return }

        // 先把上一行熄掉。注意 highlightedID 可能是行重建前的旧 id，
        // 那时 rows 里已经查不到了，直接忽略即可
        if let previous = highlightedID { rows[previous]?.apply(highlighted: false) }
        highlightedID = targetID

        guard let targetID, let row = rows[targetID] else { return }
        row.apply(highlighted: true)
        // 「记住滚动位置」关掉时不自动滚 —— 列表停在你手滚到的位置，
        // 不然一边打字一边被列表拖着跑，想把某个章节固定住看都做不到
        if remembersScrollPosition { scrollRowIntoView(for: targetID) }
    }

    // MARK: - 折叠 / 展开某一行

    /// 当前这一行是不是折叠着的（被折叠藏起来的行也返回它自己的真实状态）
    func isCollapsed(id: UUID) -> Bool {
        collapsedIDs.contains(id)
    }

    /// 这一行是不是被折叠藏起来了（自己没被折，但上面某一层被折了）
    func isHidden(id: UUID) -> Bool {
        guard let index = tree.index(of: id) else { return false }
        return tree.isHidden(index, collapsedIDs: collapsedIDs)
    }

    /// 切换某一行的折叠状态。
    ///
    /// 叶子行（没有子标题）不给折 —— 折了之后没有任何东西会消失，看着像坏了
    func toggleCollapse(id: UUID) {
        guard let index = tree.index(of: id), tree.hasChildren(at: index) else { return }
        if collapsedIDs.contains(id) {
            collapsedIDs.remove(id)
        } else {
            collapsedIDs.insert(id)
        }
        // 和「列表变了」走同一条重建路径：行数、面板高度、滚动位置都用同一套逻辑处理，
        // 免得折叠和更新各写一份、修了这个漏了那个。
        // 滚动位置这里**一定**要保住（不受设置影响）：用户手指刚点的就是这一行
        rebuildRows(animated: true, preserveScroll: true)
    }

    /// 把所有行的折叠状态清空（换文档时调，让新文档从「全部展开」开始）。
    ///
    /// ### 为什么换文档必须清一次
    /// 折叠状态靠「源码起点 + 层级」认领到新列表上（见 `OutlineCollapseState`），
    /// 在**同一份文档**里这样认是准的。但换了一份文档之后，新文档的第一个 H1 也大概率
    /// 正好在源码偏移 0 上 —— 按规则就会被上一份文档的折叠状态认走，
    /// 一打开新文件发现第一节是折着的。换文档时清一遍最省事，也不会认错。
    func resetFolding() {
        guard !collapsedIDs.isEmpty else { return }
        collapsedIDs.removeAll()
        rebuildRows(animated: false, preserveScroll: true)
    }

    // MARK: - 收起 / 展开（面板整体收起成小方块，和上面那个「折叠某一行」是两码事）

    /// 收起或展开面板
    func setCollapsed(_ collapsed: Bool, animated: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        applyCollapseState()
        refreshPanelSize(animated: animated)
    }

    /// 外观参数被外部改过之后调一次，重新算宽高
    func refreshAppearance() {
        applyRowAppearance()
        refreshPanelSize(animated: false)
    }

    /// 面板当前的高度。
    ///
    /// 刻意读**约束**的值而不是 `frame`：约束表达的是「该多高」，任何时候都准；
    /// 而 `frame` 要等一次布局真的跑完才会更新，读到的可能还是上一轮的。
    /// 单元测试用它断言「折叠之后卡片有没有变矮」
    var panelHeight: CGFloat { panelHeightConstraint.constant }

    // MARK: - 界面搭建

    private func setupSubviews() {
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.layer.cornerRadius = appearance.cornerRadius
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true
        addSubview(panel)

        panelWidthConstraint = panel.widthAnchor.constraint(equalToConstant: appearance.width)
        panelHeightConstraint = panel.heightAnchor.constraint(equalToConstant: appearance.headerHeight)

        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panelWidthConstraint,
            panelHeightConstraint
        ])

        let content = panel.contentView
        setupHeader(in: content)
        setupScrollArea(in: content)
        setupExpandButton(in: content)

        applyCollapseState()
    }

    /// 标题栏：图标 + 「大纲 · N」+ 收起箭头，底部一条分隔线
    private func setupHeader(in content: UIView) {
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(headerBar)

        headerIcon.image = UIImage(systemName: "list.bullet.indent")
        headerIcon.contentMode = .scaleAspectFit
        headerIcon.tintColor = .secondaryLabel
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        headerIcon.setContentHuggingPriority(.required, for: .horizontal)
        headerBar.addSubview(headerIcon)

        headerLabel.font = .preferredFont(forTextStyle: .caption1)
        headerLabel.adjustsFontForContentSizeCategory = true
        headerLabel.textColor = .secondaryLabel
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(headerLabel)

        collapseButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        collapseButton.addTarget(self, action: #selector(toggleCollapsed), for: .touchUpInside)
        collapseButton.accessibilityLabel = "收起大纲"
        headerBar.addSubview(collapseButton)

        // ### 分隔线为什么用一条 UIView，而不是给卡片设 layer.borderColor
        // `CGColor` 是「拍扁」过的颜色，切到深色模式不会自动变，得手动去刷 trait 变化
        // （而 `traitCollectionDidChange` 在 iOS 17 之后已经弃用了）。
        // 用 `backgroundColor` 配一个动态色（`.separator`）的普通 view，系统自己会跟着换色。
        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(separator)

        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: content.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: appearance.headerHeight),

            headerIcon.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 11),
            headerIcon.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            headerIcon.widthAnchor.constraint(equalToConstant: 15),
            headerIcon.heightAnchor.constraint(equalToConstant: 15),

            headerLabel.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 6),
            headerLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            // 防止长文案顶到箭头下面去
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: collapseButton.leadingAnchor,
                                                  constant: -4),

            collapseButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -7),
            collapseButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            collapseButton.widthAnchor.constraint(equalToConstant: 26),
            collapseButton.heightAnchor.constraint(equalToConstant: 26),

            separator.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5)
        ])
    }

    /// 可滚动的行区域
    private func setupScrollArea(in content: UIView) {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // 行不多时不要出现上下回弹，看着晃
        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = true
        content.addSubview(scrollView)

        rowsStack.axis = .vertical
        rowsStack.alignment = .fill
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(rowsStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            // ### 让 ScrollView 的内容撑得开、又不会横向错位
            // 上下左右钉到 contentLayoutGuide = 内容高度由 stack 决定；
            // stack 宽度等于 frameLayoutGuide 宽度 = 内容不会比可视区域宽（否则能左右拖）
            rowsStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor,
                                           constant: appearance.bodyVerticalPadding),
            rowsStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                                              constant: -appearance.bodyVerticalPadding),
            rowsStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                                               constant: 5),
            rowsStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                                                constant: -5),
            rowsStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor,
                                             constant: -10)
        ])
    }

    /// 收起态那个铺满整卡的按钮
    private func setupExpandButton(in content: UIView) {
        expandButton.setImage(UIImage(systemName: "list.bullet.indent"), for: .normal)
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.addTarget(self, action: #selector(toggleCollapsed), for: .touchUpInside)
        expandButton.accessibilityLabel = "展开大纲"
        content.addSubview(expandButton)

        NSLayoutConstraint.activate([
            expandButton.topAnchor.constraint(equalTo: content.topAnchor),
            expandButton.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            expandButton.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            expandButton.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    // MARK: - 行的构建

    /// 重建所有行。
    ///
    /// ### 为什么整批重建，不做增量
    /// 一次折叠会连带显示 / 隐藏一整段连续的行，增量增删要自己算「哪些行该出现、
    /// 插在第几个」，稍不留神就是错位。行数不多（标题撑死几十个），
    /// 整批重建比维护复用池省心得多，也避免「某几行显示的还是旧标题」这类难查的问题。
    /// 滚动位置在重建前后是被记下来还原的，所以用户看不出这是「全拆了重建」。
    /// - parameter preserveScroll: 重建之后要不要把列表滚回原来的位置。
    ///   列表**被换掉**（编辑改了标题）时，由「记住滚动位置」这个设置说了算；
    ///   用户自己在列表里**折叠**时永远要保住位置 —— 手指刚点的地方不能跑
    private func rebuildRows(animated: Bool, preserveScroll: Bool) {
        // 先偷偷记下现在滚到哪儿 —— 重建会把所有行视图都换掉，
        // 不还原的话列表会「唰」地跳回顶部
        let previousScrollOffset = preserveScroll ? scrollView.contentOffset : .zero

        for subview in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        rows.removeAll()
        // 行都是新的了，之前那个高亮 id 对应的视图已经不存在 —— 清掉。
        // 协调者紧接着会重发一次高亮指令（它会用最新 id 重算），所以这里不会漏高亮
        highlightedID = nil

        // 显示哪些行 = 整棵树里「没被折叠藏起来」的那些，按文档顺序。
        // 这一步同时把被折叠的后代整段跳过，所以行数会随折叠变化
        let visibleIndices = tree.visibleIndices(collapsedIDs: collapsedIDs)
        visibleItems = visibleIndices.map { items[$0] }

        if visibleIndices.isEmpty {
            rowsStack.addArrangedSubview(makeEmptyLabel())
        } else {
            for index in visibleIndices {
                let item = items[index]
                let row = OutlineRowView(item: item, appearance: appearance)
                // 只有「还有子标题的 H1-H5」才画三角。H6 不可能有子标题（没有 H7），
                // 没有子标题的行折起来不会有任何变化，画个三角反而让人以为坏了
                row.setDisclosure(visible: showsDisclosure(at: index),
                                  collapsed: collapsedIDs.contains(item.id))
                row.onDisclosureTapped = { [weak self, id = item.id] in
                    self?.toggleCollapse(id: id)
                }
                row.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
                row.heightAnchor.constraint(equalToConstant: appearance.rowHeight).isActive = true
                rowsStack.addArrangedSubview(row)
                rows[item.id] = row
            }
        }

        updateHeaderText()
        refreshPanelSize(animated: animated)
        applyScrollOffset(previousScrollOffset)
        reapplyHighlight()
    }

    /// 这一行要不要显示展开 / 折叠三角
    private func showsDisclosure(at index: Int) -> Bool {
        items[index].level <= 5 && tree.hasChildren(at: index)
    }

    private func makeEmptyLabel() -> UILabel {
        let label = UILabel()
        label.text = "（本文档没有标题）"
        label.font = .preferredFont(forTextStyle: .caption2)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        label.heightAnchor.constraint(equalToConstant: appearance.emptyStateHeight).isActive = true
        return label
    }

    private func updateHeaderText() {
        // 显示的是**全部**标题数，不是当前可见行数 —— 折叠一下数字就变小的话，
        // 反而看不出这份文档一共有多少内容
        headerLabel.text = items.isEmpty ? "大纲" : "大纲 · \(items.count)"
    }

    /// 外观变了之后把每一行重刷一遍（字体、缩进都跟 appearance 有关）
    private func applyRowAppearance() {
        for row in rows.values {
            row.applyAppearance(appearance)
        }
        panel.layer.cornerRadius = appearance.cornerRadius
    }

    @objc private func rowTapped(_ sender: OutlineRowView) {
        guard let item = sender.item else { return }
        // 自己不知道点了之后要干嘛，交给外面
        delegate?.outlineView(self, didSelect: item)
    }

    @objc private func toggleCollapsed() {
        setCollapsed(!isCollapsed, animated: true)
    }

    /// 收起 / 展开时该显示哪些子视图
    private func applyCollapseState() {
        headerBar.isHidden = isCollapsed
        scrollView.isHidden = isCollapsed
        expandButton.isHidden = !isCollapsed
        // 收起态下面板只有 46x36，展开按钮的可点区域比图标大得多，用圆角示意一下
        expandButton.tintColor = .secondaryLabel
    }

    // MARK: - 尺寸计算

    /// 面板宽度：父视图够宽就用理想宽度，不够就按比例收窄。
    ///
    /// `max(min(minimumWidth, available), ratio)` 这个写法保证两件事：
    /// 1. 优先按 46% 的比例收窄（小屏上不会盖掉大半个编辑区）；
    /// 2. 但窄到连 `minimumWidth` 都放不下时，就老老实实让给可用宽度，
    ///    这样外面那条「左边至少留 12pt」的约束永远不会被顶爆。
    private var effectiveWidth: CGFloat {
        guard let superview, superview.bounds.width > 0 else { return appearance.width }
        let available = max(0, superview.bounds.width - appearance.edgeMargin * 2)
        let ratio = available * 0.46
        return min(appearance.width, max(min(appearance.minimumWidth, available), ratio))
    }

    /// 面板顶部要占掉的那点空间（菜单按钮 + 上下间距）。
    /// 「按百分比」模式取到 100% 时，靠它保证面板不会从父视图底部伸出去
    private static let topSpaceAllowance: CGFloat = 96

    /// 面板高度上限。两种模式二选一，看 `appearance.heightRatio` 有没有值：
    ///
    /// - **按百分比**（有值）：父视图高度 × 比例。这个模式下 `maximumHeight`
    ///   完全不参与计算 —— 这正是设置页里「选百分比时最大高度失效」那条规则；
    /// - **按最大高度**（`nil`）：`maximumHeight` 说了算，但仍旧压一道父视图的
    ///   62%，免得小屏手机上目录一路顶到底。
    ///
    /// 还没挂到父视图上（或父视图还是零尺寸）时先给一个保守值，
    /// 等 `layoutSubviews` 跑起来会按真实尺寸重算。
    ///
    /// ⚠️ 不管哪种模式，算出来的都只是**上限**：标题少的时候面板会贴着内容变矮，
    /// 见 `refreshPanelSize` 里的 `min(bodyContentHeight, cap)`
    private var effectiveMaximumHeight: CGFloat {
        guard let superview, superview.bounds.height > 0 else { return appearance.maximumHeight }
        let parentHeight = superview.bounds.height
                if let ratio = appearance.heightRatio {
                    return min(parentHeight * ratio, parentHeight - Self.topSpaceAllowance)
                }
        return min(appearance.maximumHeight, parentHeight * 0.62)
    }

    /// 行区域的自然高度（有多少行就要多高）。
    ///
    /// ⚠️ 行数取的是**当前可见行**：折叠之后行变少了，卡片就该跟着矮下去
    private var bodyContentHeight: CGFloat {
        guard !visibleItems.isEmpty else { return appearance.emptyStateHeight }
        return CGFloat(visibleItems.count) * appearance.rowHeight + appearance.bodyVerticalPadding * 2
    }

    /// 把宽高约束改到当前该有的值
    private func refreshPanelSize(animated: Bool) {
        let width = isCollapsed ? appearance.collapsedWidth : effectiveWidth
        let height: CGFloat
        if isCollapsed {
            height = appearance.headerHeight
        } else {
            let cap = max(appearance.rowHeight, effectiveMaximumHeight - appearance.headerHeight)
            height = appearance.headerHeight + min(bodyContentHeight, cap)
        }

        var changed = false
        if abs(panelWidthConstraint.constant - width) > 0.5 {
            panelWidthConstraint.constant = width
            changed = true
        }
        if abs(panelHeightConstraint.constant - height) > 0.5 {
            panelHeightConstraint.constant = height
            changed = true
        }
        guard changed else { return }

        if animated {
            // 折叠 / 展开时卡片「长高变矮」的动画由这里出。行本身是整批重建的，
            // 不给每行单独做动画 —— 那要维护两套增删逻辑，收益也不明显
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut]) {
                self.superview?.layoutIfNeeded()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 父视图尺寸变了（转屏、Catalyst 拉窗口）→ 宽高跟着重算。
        // 算出来的值只依赖父视图，所以改一次就收敛，不会来回抖
        refreshPanelSize(animated: false)
    }

    // MARK: - 滚动到指定行

    /// 高亮的那一行如果在可视区域外，把它滚进来。
    ///
    /// 行高是固定的，位置能直接算出来，不用等 Auto Layout 跑完再读 frame
    /// （协调者是「更新列表 → 立刻发高亮」这样连着调的，那一刻布局还没发生）。
    private func scrollRowIntoView(for id: UUID) {
        // 注意是在**可见行**里找下标，不是整份 items —— 折叠之后两者对不上
        guard let index = visibleItems.firstIndex(where: { $0.id == id }) else { return }
        let rowHeight = appearance.rowHeight
        let top = appearance.bodyVerticalPadding + CGFloat(index) * rowHeight
        // 目标矩形给上下各留一行，避免刚好卡在边缘反复滚
        let rect = CGRect(x: 0,
                          y: max(0, top - rowHeight),
                          width: 1,
                          height: rowHeight * 3)
        scrollView.scrollRectToVisible(rect, animated: true)
    }

    /// 重建之后把列表滚到该在的位置。
    ///
    /// 传进来的偏移是 0 有两种情况：本来就停在顶部，或者「记住滚动位置」关着
    /// （`rebuildRows` 在那种情况下记的是 `.zero`）。后者要**真的回到顶部**，
    /// 所以这里不能遇到 0 就直接 return，得主动设一次。
    ///
    /// 先 `layoutIfNeeded()` 让新的行算完高度，`contentSize` 才是准的 ——
    /// 否则拿到的还是上一次的尺寸，夹范围会夹错、滚不到位。
    private func applyScrollOffset(_ offset: CGPoint) {
        scrollView.layoutIfNeeded()
        let maximumY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let y = min(max(0, offset.y), maximumY)
        guard abs(y - scrollView.contentOffset.y) > 0.5 else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: false)
    }

    /// 行整批重建之后，把「当前章节」那一行的高亮补回来。
    ///
    /// 数据更新那一路其实不需要它：协调者拿到新列表后会重发一次高亮（用新 id）。
    /// 它是给**折叠**兜底的 —— 折叠不经过协调者，不补的话点一下三角，
    /// 当前章节的底色会跟着那一行一起消失
    private func reapplyHighlight() {
        let target = visibleRepresentativeID(for: requestedHighlightID)
        highlightedID = nil
        guard let target, let row = rows[target] else { return }
        highlightedID = target
        row.apply(highlighted: true)
    }

    /// 把「要高亮的目标 id」换算成「实际点亮哪一行的 id」。
    ///
    /// 目标被折叠藏起来时，往上取**最外层那个被折叠的祖先**：
    /// 光标在某个收起来的 H2 下的 H3 里打字时，界面上真正显示的是 H2 那一行，
    /// 点亮它才是用户看到的「当前章节」。
    private func visibleRepresentativeID(for id: UUID?) -> UUID? {
        guard let id else { return nil }
        // 列表里找不到这条（比如是重建前的旧 id）→ 原样返回，下面 rows 查不到会自然忽略
        guard let index = tree.index(of: id) else { return id }
        let representative = tree.representativeIndex(of: index, collapsedIDs: collapsedIDs)
        return items[representative].id
    }
}

// MARK: - 一行

/// 目录里的一行。
///
/// 纯 UI 控件，同样不认识 markdown —— 给它一个 `OutlineItem` 它就能显示。
/// 用 `UIControl` 是为了直接吃 `touchUpInside`，不用自己写手势识别。
final class OutlineRowView: UIControl {

    /// 这一行对应的数据（点的时候要原样报出去）
    private(set) var item: OutlineItem?

    /// 用户点了右边的展开 / 折叠三角时回调。
    ///
    /// 谁接、接了干嘛（要折叠哪一节）这行视图不知道，由目录面板填。
    var onDisclosureTapped: (() -> Void)?

    private let accentBar = UIView()
    private let titleLabel = UILabel()
    /// 右边的展开 / 折叠三角
    private let disclosureButton = UIButton(type: .system)
    private var appearance: MarkdownOutlineAppearance
    /// 是不是「当前光标所在章节」那一行（跟手指按下时的高亮是两码事）。
    /// 对外只读 —— 单元测试靠它断言「高亮到底落到哪一行了」
    private(set) var isRowHighlighted = false

    /// 缩进靠改这两条约束的 constant 实现，比每层包一个空白 view 省事
    private var accentBarLeading: NSLayoutConstraint!
    private var titleLabelLeading: NSLayoutConstraint!

    /// 三角的边长。**没有子标题的行也占这么大地方**（按钮只是隐藏，不参与命中），
    /// 这样所有行的标题右边界是对齐的；不然有没有三角的行文字右边界差一截，很难看
    private static let disclosureSide: CGFloat = 24
    /// 三角图标的字号
    private static let disclosureSymbol = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)

    /// 测试用：这一行右边显示着展开 / 折叠三角吗
    var isDisclosureVisible: Bool { !disclosureButton.isHidden }

    init(item: OutlineItem, appearance: MarkdownOutlineAppearance) {
        self.item = item
        self.appearance = appearance
        super.init(frame: .zero)
        setupSubviews()
        applyAppearance(appearance)
    }

    required init?(coder: NSCoder) {
        fatalError("OutlineRowView 不支持从 coder 解档")
    }

    /// 手指按下时稍微变淡一下，给出即时反馈
    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.5 : 1 }
    }

    /// 模拟点一下右边的展开 / 折叠三角（单元测试和 VoiceOver 之外的地方想触发时用）
    func tapDisclosure() {
        disclosureButton.sendActions(for: .touchUpInside)
    }

    /// 设置这一行的展开 / 折叠三角长什么样。
    /// - parameter visible: 有没有子标题 —— 没有就只留空位、不画三角
    /// - parameter collapsed: 当前是折着的（▶）还是开着的（▼）
    func setDisclosure(visible: Bool, collapsed: Bool) {
        disclosureButton.isHidden = !visible
        let name = collapsed ? "chevron.right" : "chevron.down"
        disclosureButton.setImage(UIImage(systemName: name, withConfiguration: Self.disclosureSymbol),
                                  for: .normal)
        disclosureButton.accessibilityLabel = visible ? (collapsed ? "展开" : "折叠") : nil
        disclosureButton.accessibilityValue = collapsed ? "已折叠" : "已展开"
    }

    private func setupSubviews() {
        layer.cornerRadius = 7
        layer.cornerCurve = .continuous

        accentBar.translatesAutoresizingMaskIntoConstraints = false
        accentBar.layer.cornerRadius = 1.25
        accentBar.isUserInteractionEnabled = false
        addSubview(accentBar)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isUserInteractionEnabled = false
        addSubview(titleLabel)

        // 三角为什么也放 `tintColor` 而不是写死颜色：跟着主题走，深色模式不用单独管
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        disclosureButton.tintColor = .tertiaryLabel
        disclosureButton.addTarget(self, action: #selector(disclosureTapped), for: .touchUpInside)
        // 三角在整个一行里是个小目标，给一个足够大的热区（24x24，符合最小可点尺寸）
        addSubview(disclosureButton)

        NSLayoutConstraint.activate([
            accentBar.centerYAnchor.constraint(equalTo: centerYAnchor),
            // 高度取行的 55% 而不是写死数值：改 `rowHeight` 时它自己跟着变
            accentBar.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.55),
            accentBar.widthAnchor.constraint(equalToConstant: 2.5),

            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            // 标题右边给三角让位。⚠️ 三角即使隐藏着也占着这块位置，
            // 所以有子标题和没子标题的行，标题文字右边界是对齐的
            titleLabel.trailingAnchor.constraint(equalTo: disclosureButton.leadingAnchor),

            disclosureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            disclosureButton.widthAnchor.constraint(equalToConstant: Self.disclosureSide),
            disclosureButton.heightAnchor.constraint(equalToConstant: Self.disclosureSide)
        ])

        accentBarLeading = accentBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
        titleLabelLeading = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15)
        accentBarLeading.isActive = true
        titleLabelLeading.isActive = true
    }

    @objc private func disclosureTapped() {
        onDisclosureTapped?()
    }

    /// 把数据填进视图：标题文字、层级缩进、字体粗细、无障碍描述
    private func applyItem() {
        guard let item else { return }
        titleLabel.text = item.title.isEmpty ? "（空标题）" : item.title
        titleLabel.font = Self.font(forLevel: item.level)

        let indent = min(appearance.maximumIndent,
                         CGFloat(max(0, item.level - 1)) * appearance.indentPerLevel)
        accentBarLeading.constant = 6 + indent
        titleLabelLeading.constant = 15 + indent

        accessibilityLabel = "\(item.level) 级标题，\(item.title)"
        accessibilityTraits = .button
    }

    /// 外观参数变了，重刷
    func applyAppearance(_ appearance: MarkdownOutlineAppearance) {
        self.appearance = appearance
        applyItem()
        applyHighlightAppearance()
    }

    /// 设置 / 取消「当前章节」高亮。
    ///
    /// 这里刻意**不发** `UIAccessibility.layoutChanged` 通知 —— 光标一边打字一边移动，
    /// 每动一下就抢一次 VoiceOver 焦点会让读屏用户完全没法用。
    func apply(highlighted: Bool) {
        guard highlighted != isRowHighlighted else { return }
        isRowHighlighted = highlighted
        applyHighlightAppearance()
    }

    private func applyHighlightAppearance() {
        if isRowHighlighted {
            backgroundColor = tintColor.withAlphaComponent(0.13)
            accentBar.backgroundColor = tintColor
            accentBar.isHidden = false
            titleLabel.textColor = .label
            titleLabel.font = Self.font(forLevel: item?.level ?? 1, emphasized: true)
        } else {
            backgroundColor = .clear
            accentBar.backgroundColor = .clear
            accentBar.isHidden = true
            titleLabel.textColor = .secondaryLabel
            titleLabel.font = Self.font(forLevel: item?.level ?? 1)
        }
    }

    /// 层级越高字越粗；H3 以后统一用弱一点的颜色，靠缩进区分层级
    private static func font(forLevel level: Int, emphasized: Bool = false) -> UIFont {
        let textStyle: UIFont.TextStyle
        let weight: UIFont.Weight
        switch level {
        case 1:
            textStyle = .subheadline
            weight = emphasized ? .bold : .semibold
        case 2:
            textStyle = .footnote
            weight = emphasized ? .semibold : .medium
        default:
            textStyle = .footnote
            weight = emphasized ? .medium : .regular
        }
        let base = UIFont.preferredFont(forTextStyle: textStyle)
        return UIFont.systemFont(ofSize: base.pointSize, weight: weight)
    }
}
