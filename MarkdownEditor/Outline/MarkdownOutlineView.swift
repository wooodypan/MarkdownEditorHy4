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
    /// 「固定宽度」模式下展开时的理想宽度（宽度不够时会自动收窄，见 `MarkdownOutlineView.effectiveWidth`）。
    ///
    /// ⚠️ `widthRatio` 有值时这一项**完全不参与计算** —— 宽度模式是互斥的二选一，和下面高度那对 `maximumHeight` / `heightRatio` 是同一个套路
    var width: CGFloat = 300
    /// 面板宽度最多占父视图宽度的比例。
    ///
    /// - 有值（比如 `0.3` = 30%）→ 宽度 = 父视图宽度 × 这个比例，此时 `width` **失效**；
    /// - `nil`（默认）→ 宽度改由 `width` 决定。
    ///
    /// 由上层容器按用户在设置页选的模式注入 —— 这个文件不认识 App 层的配置，只认别人塞给它的值
    var widthRatio: CGFloat?
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
    /// 列表左右各留多少（行本身还会在此基础上再缩进）
    var bodyHorizontalPadding: CGFloat = 5
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
/// - 点标题栏的「全部折叠 / 全部展开」→ 一刀切地折起或放出所有能折的节；
/// - 点标题栏最右边的箭头 → 收起成一个小方块，再点小方块展开（长文档时把编辑区让出来）。
///
/// ### 布局上的两个「自适应」
/// 面板自己不指定位置（位置由外部容器用约束定），只负责自己的
/// **宽度**和**高度**：宽度按父视图宽度的比例收窄，高度按内容算并压在上限之下。
/// 这样它在 iPhone 竖屏和 Mac Catalyst 大窗口里都能看。
///
/// ### 行区域为什么用 `UICollectionView`
/// 早先用的是一个竖排 `UIStackView`，每次数据变化就把**所有**标题行整批重建一遍。
/// 2026-09-14 实测这样做的耗时随标题数**线性增长**（宿主机 800 高、行高 30）：
///
/// | 标题行数 | 一次折叠 + 布局 |
/// |---|---|
/// | 30 | 27 ms |
/// | 80 | 78 ms |
/// | 200 | 192 ms |
/// | 400 | **414 ms** |
///
/// 大约**每行 1 毫秒**，而面板一屏最多只显示十几行 —— 也就是说有一多半的钱
/// 花在了「看不见的行」上。长文档（几百个标题）里折叠一下会明显卡手。
///
/// 于是换成 `UICollectionView` + `UICollectionViewDiffableDataSource` +
/// `NSDiffableDataSourceSectionSnapshot`：**只为屏幕上那十几行创建 cell**，
/// 折叠一次的耗时不再随文档长度涨。
///
/// 换控件之前评估过两个「看着更省事」的想法，都放弃了，原因记在这儿免得再试一遍：
///
/// 1. **不能指望系统帮我们记住折叠状态**。那套 API 的卖点是「用稳定的标识做 diff，
///    折叠状态自然保留」，而本项目的 `OutlineItem.id` 复用 `MarkdownBlock.id`，
///    编辑器每次增量编辑都会重建受影响的块、UUID 换新 —— 标识**不稳定**。
///    所以「折叠状态怎么跨重建活下来」这件事不管用哪个控件都得自己写
///    （`OutlineCollapseState` 就是干这个的）。
/// 2. **面板高度是「算」出来的，不是「量」出来的**。这块毛玻璃卡片的高度
///    （`refreshPanelSize`）要跟父视图尺寸、行数一起算，并且和收起 / 展开动画联动。
///    如果改成反过来问布局系统要高度（`collectionViewContentSize` 得等一次布局才准），
///    「约束算高度」和「布局算高度」两套机制就会互相等待，在 Catalyst 拉窗口时很容易抖。
///
/// 这两个结论决定了现在的两条边界：
/// - **折叠状态的唯一出处还是 `collapsedIDs`**（不把快照当数据源）。每次更新都按
///   `OutlineCollapseState` 把旧 id 认到新 id 上，再照着它重建快照 ——
///   标识不稳定这件事照旧由我们处理，不指望系统 diff 帮忙；
/// - **高度仍旧自己算**（`bodyContentHeight` 用可见行数 × 行高）。
///   快照只负责「显示哪些行」，不参与尺寸计算，也就不会和 Auto Layout 互相等待。
final class MarkdownOutlineView: UIView, MarkdownOutlineDisplaying {

    // MARK: 对外

    /// 用户点击某一行的出口。实现方是 `OutlineCoordinator`
    weak var delegate: MarkdownOutlineViewDelegate?

    /// 外观参数，建好之后也能改（改完调一次 `refreshAppearance()`）
    var appearance: MarkdownOutlineAppearance

    /// 当前是不是收起状态
    private(set) var isCollapsed = false

    // MARK: 数据

    /// 完整的标题列表（包含被折叠藏起来的那些）。
    /// 显示哪些行由 `tree` + `collapsedIDs` 算出来，见 `visualSnapshot()`
    private var items: [OutlineItem] = []
    /// 由 `items` 建出来的层级树（谁是谁的子标题）
    private var tree = OutlineTree(items: [])
    /// 当前被折叠起来的标题 id。
    ///
    /// ### 为什么要单独存一份，而不是塞进 `OutlineItem` 里
    /// `OutlineItem` 每次编辑都会被整份换掉（块重建 → 新 id、新实例），
    /// 状态存在里面就等于「一编辑就没」。存在这里、并且每次更新时按
    /// `OutlineCollapseState` 对账到新的 id 上，折叠状态才能跨编辑活下来。
    ///
    /// ⚠️ 这也是整个折叠功能的**唯一出处**：列表里显示哪些行、高亮该落在谁身上，
    /// 全部从它算出来（`collectionView` 的快照只是它的一个「投影」，不是数据源）
    private var collapsedIDs: Set<UUID> = []
    /// 当前能折的行（有子标题、且层级在 H1-H5）的 id 集合。
    /// 随 `items` 一起重算，供「全部折叠」和标题栏按钮状态使用
    private var collapsibleIDs: Set<UUID> = []

    /// 当前**显示出来的**行，按显示顺序。
    /// 高亮定位、滚动定位、面板高度都基于它（而不是含隐藏行的 `items`）
    private var visibleItems: [OutlineItem] = []

    /// 最近一次「要求点亮谁」的原始 id（协调者给的，没做折叠折算）。
    ///
    /// ### 为什么存「要求」而不是「实际点亮的那一行」
    /// 实际点亮谁要现算 —— 目标行可能正被折叠藏着（光标在收起来的章节里打字），
    /// 这时要点亮的是它往上找到的那个可见祖先。而「要求」是稳定不变的，
    /// 行重建、折叠变化之后都能拿它重算，不会出现「折一下底色就没了」。
    /// 见 `effectiveHighlightID`
    private var requestedHighlightID: UUID?

    // MARK: 子视图

    /// 毛玻璃卡片本体。收起 / 展开都是改它的宽高约束，不换视图
    private let panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let headerBar = UIView()
    private let headerIcon = UIImageView()
    private let headerLabel = UILabel()
    /// 「全部折叠 / 全部展开」——按当前是不是已经全折了切换图标和动作
    private let collapseAllButton = UIButton(type: .system)
    private let collapseButton = UIButton(type: .system)
    /// 行区域。这里是 cell 复用真正生效的地方：只为屏幕上看得见的那十几行创建视图
    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!
    /// 一条标题都没有时的占位文字（不用 collection view 的补充视图，简单些）
    private let emptyLabel = UILabel()
    /// 收起态铺满整卡的那个按钮
    private let expandButton = UIButton(type: .system)

    /// 卡片宽高（收起 / 展开都靠改这两个的 constant）
    private var panelWidthConstraint: NSLayoutConstraint!
    private var panelHeightConstraint: NSLayoutConstraint!
    /// 上一次算行宽时用的面板宽度（读的是 `panelWidthConstraint` 的值）。
    /// 它一变就得让 flow layout 重新问一遍每一行该多宽
    private var lastLaidOutWidth: CGFloat = 0

    /// 标题栏「全部折叠 / 全部展开」按钮的图标尺寸。
    ///
    /// 自绘图标按这个边长等比缩放（按钮本身是 26×26，图标留出呼吸空间）。
    /// ⚠️ 图形在它那张 256×256 的画布上只占中间 224×224，所以**实际看到的大小**是
    /// 这里的 87.5% 左右 —— 觉得图标偏小就调大这个数，别去改绘制代码里的坐标
    private static let collapseAllIconSize = CGSize(width: 18, height: 18)

    // MARK: 初始化

    init(appearance: MarkdownOutlineAppearance = MarkdownOutlineAppearance()) {
        self.appearance = appearance
        self.collectionView = Self.makeCollectionView()
        super.init(frame: .zero)
        backgroundColor = .clear
        setupSubviews()
        setupDataSource()
        // 刚建出来还没接到任何标题列表，先照「空的」把标题栏按钮摆好，
        // 免得出现一个既没图标也能按的按钮
        updateHeaderControls()
    }

    required init?(coder: NSCoder) {
        // 和编辑器一样，界面全部走代码，不支持 storyboard
        fatalError("MarkdownOutlineView 不支持从 coder 解档")
    }

    /// 行区域的滚动视图。
    ///
    /// 用 `UICollectionViewFlowLayout` 而不是方案文档里的 list configuration：
    /// 行高固定、不需要 self-sizing，flow layout 的 inset 和尺寸都由我们自己定，
    /// 少一层「配置对象 → 布局 → 猜尺寸」的来回。宽度在
    /// `sizeForItemAt` 里按当前可视宽度现取
    private static func makeCollectionView() -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.estimatedItemSize = .zero
        layout.itemSize = CGSize(width: 100, height: 30)   // 真实尺寸由 sizeForItemAt 给
        layout.sectionInset = .zero                        // 留白交给 appearance
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        // 行不多时不要出现上下回弹，看着晃
        view.alwaysBounceVertical = false
        view.showsVerticalScrollIndicator = true
        // 面板贴在自己算的尺寸里，不需要系统按安全区再补一层内边距
        view.contentInsetAdjustmentBehavior = .never
        view.register(OutlineRowCell.self,
                      forCellWithReuseIdentifier: OutlineRowCell.reuseIdentifier)
        return view
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
        // 能折的行只在列表变了的时候重算一次（「全部折叠」和标题栏按钮都要用）
        collapsibleIDs = Set(tree.collapsibleIndices.map { items[$0].id })
        // 列表换了，里面可能已经没有原来折着的那些标题了，清一遍残留标记
        collapsedIDs.formIntersection(collapsibleIDs)
        // 编辑会让列表整份重建，位置**必须**保住 —— 否则正文里每敲一个字，右边的目录就「唰」地跳回顶部
        rebuildRows(animated: false, preserveScroll: true)
    }

    /// 高亮某一行；传 nil 表示取消所有高亮
    func highlightOutlineItem(_ id: UUID?) {
        // 只记「要求点亮谁」。真正点亮哪一行要按当前折叠状态现算（见 effectiveHighlightID），
        // 这样行重建、折叠变化之后都不会丢高亮
        requestedHighlightID = id
        refreshHighlightAppearance()

        // 把高亮那一行滚进可视区。这一步**无条件做**：大纲不跟着光标走的话，
        // 光标跑到文档后半段时目录还停在开头，等于没有大纲。
        // 行本来就看得见时 `scrollRowIntoView` 会提前返回，不会来回抖
        guard let target = effectiveHighlightID else { return }
        scrollRowIntoView(for: target)
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
    /// 没有子标题的行不给折 —— 折了之后没有任何东西会消失，看着像坏了
    func toggleCollapse(id: UUID) {
        guard let index = tree.index(of: id), tree.canCollapse(at: index) else { return }
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

    /// 现在是不是「已经全部折叠」了（能折的都折了，而且至少有一个能折的）。
    ///
    /// 标题栏那个按钮靠它决定「下一步是折还是放」以及画哪个图标
    var isAllCollapsed: Bool {
        !collapsibleIDs.isEmpty && collapsibleIDs.isSubset(of: collapsedIDs)
    }

    /// 一刀切：把所有能折的节都折起来。
    ///
    /// 折完的结果就是「只剩最顶层那几行」。做不出可折内容的标题（叶子）不参与 ——
    /// 它们本来就没有三角
    func collapseAll() {
        guard !collapsibleIDs.isEmpty, !isAllCollapsed else { return }
        collapsedIDs = collapsibleIDs
        // 全部折起来之后列表会很短，原来的滚动位置没有意义了，直接回顶部
        rebuildRows(animated: true, preserveScroll: false)
    }

    /// 一刀切：全部放出来（回到「默认全展开」）
    func expandAll() {
        guard !collapsedIDs.isEmpty else { return }
        collapsedIDs.removeAll()
        rebuildRows(animated: true, preserveScroll: true)
    }

    /// 标题栏按钮的动作：现在全折着就放出来，否则全折起来
    @objc private func toggleCollapseAll() {
        isAllCollapsed ? expandAll() : collapseAll()
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
        // 面板宽度会在「小方块」和完整面板之间切换，行宽跟着变 —— flow layout 必须重新问一遍
        // 每一行该多宽。⚠️ 这一步必须在下面触发布局**之前**做：收起时行是按 46 点宽算好的，
        // 不重问的话展开后还是那个尺寸；减去左边缩进和右边给三角留的位之后，
        // 标题的可用宽度成了负数，屏幕上一条标题都看不到（看着像「目录里什么都没有」）
        collectionView.collectionViewLayout.invalidateLayout()
        refreshPanelSize(animated: animated)
    }

    /// 外观参数被外部改过之后调一次，重新算宽高。
    ///
    /// 走一遍完整重建就够了：每个 cell 都是照着 `appearance` 现配的
    /// （复用池里那些旧 cell 会被重新配置，不会留着上一次的行高和缩进）
    func refreshAppearance() {
        collectionView.collectionViewLayout.invalidateLayout()
        panel.layer.cornerRadius = appearance.cornerRadius
        // 同上：宽高变了也把位置保住，别让用户滚到一半被甩回顶部
        rebuildRows(animated: false, preserveScroll: true)
    }

    /// 面板当前的高度。
    ///
    /// 刻意读**约束**的值而不是 `frame`：约束表达的是「该多高」，任何时候都准；
    /// 而 `frame` 要等一次布局真的跑完才会更新，读到的可能还是上一轮的。
    /// 单元测试用它断言「折叠之后卡片有没有变矮」
    var panelHeight: CGFloat { panelHeightConstraint.constant }

    /// 面板当前的宽度。读的同样是**约束**的值，理由见上面 `panelHeight`。
    /// 单元测试用它断言两种宽度模式（固定点数 / 按父视图比例）各算出多宽
    var panelWidth: CGFloat { panelWidthConstraint.constant }

    // MARK: - 测试用的小口子

    /// 当前显示出来的行的标题，按显示顺序。
    /// 测试拿它断言「折了之后还剩哪几行」—— 比去数屏幕上的 cell 稳（屏幕外的行没有 cell）
    var visibleTitles: [String] { visibleItems.map(\.title) }

    /// 第 index 行对应的 cell。屏幕外的行还没创建，返回 nil
    func rowCell(at index: Int) -> OutlineRowCell? {
        collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? OutlineRowCell
    }

    /// 测试用：当前已经创建出来的行，按显示顺序。
    ///
    /// ⚠️ 只有**屏幕上放得下**的那些行才有 cell —— 这正是换 collection view 想要的效果
    /// （不再为看不见的行建视图）。所以拿它断言行数时，用例里的行数得在面板高度之内
    var createdRowCells: [OutlineRowCell] {
        collectionView.layoutIfNeeded()
        return (0..<visibleItems.count).compactMap { rowCell(at: $0) }
    }

    /// 模拟「用手指点了这一行」（走和真实点击同一条路：报给 delegate）
    func simulateRowTap(at index: Int) {
        handleRowTap(at: index)
    }

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

    /// 标题栏：图标 + 「大纲 · N」+ 全部折叠 + 收起箭头，底部一条分隔线
    private func setupHeader(in content: UIView) {
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(headerBar)

//        headerIcon.image = UIImage(systemName: "list.bullet.indent")
//        headerIcon.contentMode = .scaleAspectFit
//        headerIcon.tintColor = .secondaryLabel
//        headerIcon.translatesAutoresizingMaskIntoConstraints = false
//        headerIcon.setContentHuggingPriority(.required, for: .horizontal)
//        headerBar.addSubview(headerIcon)

        headerLabel.font = .preferredFont(forTextStyle: .title3)
        headerLabel.adjustsFontForContentSizeCategory = true
        headerLabel.textColor = .label
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(headerLabel)

        collapseAllButton.translatesAutoresizingMaskIntoConstraints = false
        collapseAllButton.tintColor = .secondaryLabel
        collapseAllButton.addTarget(self, action: #selector(toggleCollapseAll), for: .touchUpInside)
        headerBar.addSubview(collapseAllButton)

//        collapseButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        collapseButton.setTitle("x", for: .normal)
        collapseButton.setTitleColor(.gray, for: .normal)
        collapseButton.titleLabel?.font = UIFont.systemFont(ofSize: 20)
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        collapseButton.addTarget(self, action: #selector(toggleCollapsed), for: .touchUpInside)
        collapseButton.accessibilityLabel = "收起大纲"
        headerBar.addSubview(collapseButton)

        // ### 分隔线为什么用一条 UIView，而不是给卡片设 layer.borderColor
        // `CGColor` 是「拍扁」过的颜色，切到深色模式不会自动变，得手动去刷 trait 变化
        // （而 `traitCollectionDidChange` 在 iOS 17 之后已经弃用了）。
        // 用 `backgroundColor` 配一个动态色（`.separator`）的普通 view，系统自己会跟着换色。
//        let separator = UIView()
//        separator.backgroundColor = .separator
//        separator.translatesAutoresizingMaskIntoConstraints = false
//        headerBar.addSubview(separator)

        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: content.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: appearance.headerHeight),

//            headerIcon.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 11),
//            headerIcon.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
//            headerIcon.widthAnchor.constraint(equalToConstant: 15),
//            headerIcon.heightAnchor.constraint(equalToConstant: 15),

            headerLabel.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor, constant: -16),
            headerLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            // 防止长文案顶到按钮下面去
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: collapseAllButton.leadingAnchor,
                                                  constant: -4),

            collapseAllButton.leadingAnchor.constraint(equalTo: headerLabel.trailingAnchor,
                                                        constant: 10),
            collapseAllButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            collapseAllButton.widthAnchor.constraint(equalToConstant: 26),
            collapseAllButton.heightAnchor.constraint(equalToConstant: 26),

            collapseButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -7),
            collapseButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            collapseButton.widthAnchor.constraint(equalToConstant: 26),
            collapseButton.heightAnchor.constraint(equalToConstant: 26),

//            separator.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
//            separator.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
//            separator.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor),
//            separator.heightAnchor.constraint(equalToConstant: 0.5)
        ])
    }

    /// 可滚动的行区域
    private func setupScrollArea(in content: UIView) {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        // 数据源这里不设：`UICollectionViewDiffableDataSource` 初始化时会把自己
        // 接到 collection view 的 dataSource 上（见 `setupDataSource`）
        content.addSubview(collectionView)

        emptyLabel.text = "（本文档没有标题）"
        emptyLabel.font = .preferredFont(forTextStyle: .caption2)
        emptyLabel.textColor = .tertiaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            emptyLabel.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            emptyLabel.heightAnchor.constraint(equalToConstant: appearance.emptyStateHeight)
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

    /// 配数据源。
    ///
    /// ### 为什么标识符用 `UUID` 而不是 `OutlineItem` 本身
    /// diffable 的数据源要求标识符 `Hashable`，而它一旦在别处被当成「整个条目的相等性」用，
    /// 就会出现「标题文字改了但 id 没变 → 系统以为没变，不刷新那一行」。
    /// 这里只拿 id 当标识，条目的其他字段按 id 现查（`item(for:)`），
    /// 所以文字 / 层级怎么变都不会漏刷新。
    private func setupDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Int, UUID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, id in
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: OutlineRowCell.reuseIdentifier, for: indexPath
            ) as? OutlineRowCell ?? OutlineRowCell()
            guard let self, let index = self.tree.index(of: id) else { return cell }
            cell.configure(item: self.items[index],
                           appearance: self.appearance,
                           collapsed: self.collapsedIDs.contains(id),
                           highlighted: id == self.effectiveHighlightID,
                           // 「这行要不要画三角」是面板算的（它才知道树），cell 自己算不出来
                           showsDisclosure: self.tree.canCollapse(at: index))
            cell.onDisclosureTapped = { [weak self] in self?.toggleCollapse(id: id) }
            return cell
        }

        // 分区本身要先存在，后面才能往 0 号分区里塞快照（永远只用这一个分区）
        var initial = NSDiffableDataSourceSnapshot<Int, UUID>()
        initial.appendSections([0])
        dataSource.apply(initial, animatingDifferences: false)
    }

    private func item(for id: UUID) -> OutlineItem? {
        tree.index(of: id).map { items[$0] }
    }

    // MARK: - 行的构建

    /// 把当前该显示哪些行、谁被折着，一次性算出来并交给 collection view。
    ///
    /// ### 为什么每次都是「整份快照重来」
    /// 数据源那边只认 id，而 id 在每次编辑后都会换新（块重建），
    /// 所以增量 diff 本来也命中不了几行，不如整份重算 —— 反正 collection view
    /// 只为屏幕上那十几行创建 cell，整份快照的开销是数据层的几百次比较，很便宜。
    /// - parameter preserveScroll: 重建之后要不要把列表滚回原来的位置。
    ///   默认都传 `true`：编辑改了标题、用户折叠某一行、面板宽高变了，位置都不该跑；
    ///   唯一的例外是「全部折叠」—— 列表缩到只剩几行，原来的位置没有意义，直接回顶部
    private func rebuildRows(animated: Bool, preserveScroll: Bool) {
        // 先偷偷记下现在滚到哪儿 —— 快照换完内容就全变了，
        // 不还原的话列表会「唰」地跳回顶部
        let previousScrollOffset = preserveScroll ? collectionView.contentOffset : .zero

        // 显示哪些行 = 整棵树里「没被折叠藏起来」的那些，按文档顺序。
        // 这一步同时把被折叠的后代整段跳过，所以行数会随折叠变化
        let visibleIndices = tree.visibleIndices(collapsedIDs: collapsedIDs)
        visibleItems = visibleIndices.map { items[$0] }

        updateHeaderControls()
        collectionView.isHidden = items.isEmpty
        emptyLabel.isHidden = !items.isEmpty

        applySnapshot(animated: animated)
        refreshPanelSize(animated: animated)
        // 尺寸改完让布局跑一次：下面要用 contentSize 夹滚动范围，也得让新的 cell 建出来
        layoutIfNeeded()
        applyScrollOffset(previousScrollOffset)
        refreshHighlightAppearance()
    }

    /// 照当前的树 + 折叠状态，生成分区快照并应用
    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSectionSnapshot<UUID>()
        // 先把「谁挂在谁下面」整棵树铺好，再统一标展开 / 折叠 ——
        // 顺序反过来的话，给一个还没加进快照的父节点标展开是无效的
        snapshot.append(tree.roots.map { items[$0].id }, to: nil)
        let parentIndices = items.indices.filter { !tree.children[$0].isEmpty }
        for index in parentIndices {
            snapshot.append(tree.children[index].map { items[$0].id }, to: items[index].id)
        }

        // ⚠️ 实测（2026-09-14）：系统这个分区快照**默认把有子项的节点当成「收起」**，
        // 光 append 出层级，界面上只会显示最顶层那几个根，下面的全都不见。
        // 必须显式把要展开的父节点 expand 一遍。
        // 所以这里先「全部展开」，再照着 `collapsedIDs` 把用户折好的收起来 ——
        // 这两步的顺序不能反（先折后展的话，用户折好的会又被展开）
        snapshot.expand(parentIndices.map { items[$0].id })
        snapshot.collapse(collapsedIDs.filter { collapsibleIDs.contains($0) })
        dataSource.apply(snapshot, to: 0, animatingDifferences: animated)
    }

    /// 标题栏那两处文案 / 图标。
    ///
    /// 左边显示的是**全部**标题数，不是当前可见行数 —— 折叠一下数字就变小的话，
    /// 反而看不出这份文档一共有多少内容。
    /// 右边那个按钮要跟着「现在是不是已经全折了」换图标和含义（同一个位置一按到底，
    /// 不用记「我上一步做了什么」）
    private func updateHeaderControls() {
        headerLabel.text = items.isEmpty ? "大纲 · \(items.count)" : "大纲"

        let allCollapsed = isAllCollapsed
        // 自绘图标（见 VectorIcon.outlineExpandAll / .outlineCollapseAll）：
        // 系统那个 rectangle.compress.vertical 是「方框 + 居中横条」的通用图形，
        // 和大纲这个面板的气质不太搭，换成设计稿给的两个
        let icon: VectorIcon = allCollapsed ? .outlineExpandAll : .outlineCollapseAll
        collapseAllButton.setVectorIcon(icon, size: Self.collapseAllIconSize)
        collapseAllButton.accessibilityLabel = allCollapsed ? "全部展开" : "全部折叠"
        // 一条能折的都没有（比如全文只有单层标题）→ 按钮置灰，明说这儿没得可折
        collapseAllButton.isEnabled = !collapsibleIDs.isEmpty
        collapseAllButton.tintColor = collapsibleIDs.isEmpty ? .tertiaryLabel : .secondaryLabel
    }

    /// 第 index 行被点了（整行点击 = 跳转）
    private func handleRowTap(at index: Int) {
        guard visibleItems.indices.contains(index) else { return }
        // 自己不知道点了之后要干嘛，交给外面
        delegate?.outlineView(self, didSelect: visibleItems[index])
    }

    @objc private func toggleCollapsed() {
        setCollapsed(!isCollapsed, animated: true)
    }

    /// 收起 / 展开时该显示哪些子视图
    private func applyCollapseState() {
        headerBar.isHidden = isCollapsed
        collectionView.isHidden = isCollapsed || items.isEmpty
        emptyLabel.isHidden = isCollapsed || !items.isEmpty
        expandButton.isHidden = !isCollapsed
        // 收起态下面板只有 46x36，展开按钮的可点区域比图标大得多，用圆角示意一下
        expandButton.tintColor = .secondaryLabel
    }

    // MARK: - 尺寸计算

    /// 面板宽度：两种模式二选一，看 `appearance.widthRatio` 有没有值。
    ///
    /// - **按百分比**（有值）：宽度 = 可用宽度 × 比例。⚠️ 这种情况**不套用下面那道 46% 的自动收窄** ——
    ///   那一档是给「固定宽度在小屏上放不下」兜底的，用户明确要 50% 时不该被它压回 46%；
    /// - **固定宽度**（`nil`）：父视图够宽就用 `appearance.width`，不够就按 46% 收窄。
    ///
    /// 两种模式共用同一道保底 `max(min(minimumWidth, available), …)`，它保证两件事：
    /// 1. 面板至少和「可用空间里放得下的 `minimumWidth`」一样宽（再窄标题就没法看了）；
    /// 2. 窄到连 `minimumWidth` 都放不下时，就老老实实让给可用宽度，
    ///    这样外面那条「左边至少留 12pt」的约束永远不会被顶爆。
    private var effectiveWidth: CGFloat {
        guard let superview, superview.bounds.width > 0 else { return appearance.width }
        let available = max(0, superview.bounds.width - appearance.edgeMargin * 2)
        // 窄到放不下 minimumWidth 时就让给可用宽度，两种模式共用这一道保底
        let floor = min(appearance.minimumWidth, available)
        if let ratio = appearance.widthRatio {
            return max(floor, min(available, available * ratio))
        }
        return min(appearance.width, max(floor, available * 0.46))
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
    /// ⚠️ 行数取的是**当前可见行**：折叠之后行变少了，卡片就该跟着矮下去。
    /// 这里刻意不用 `collectionView.contentSize` —— 那是布局跑完才准的值，
    /// 而面板高度反过来决定 collection view 的高度，用它就会绕成一个圈
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
            // 折叠 / 展开时卡片「长高变矮」的动画由这里出。行本身是交给 collection view
            // 的（cell 复用 + 系统自己的增删动画），不再自己给每行做动画
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

        // 行宽 = 面板宽度 - 左右留白。宽度变了得让 layout 重新问一遍尺寸，
        // 否则会沿用上一次的宽度（Catalyst 拉窗口时行会「短一截」）。
        //
        // ⚠️ 这里量的是**面板宽度约束上的值**，不能用 `effectiveWidth`：
        // 后者在收起态返回的也是展开后的理想宽度（它压根不认识收起态），于是收起时就被记成那个值，展开时差值 0、一次都不作废布局 —— 症状就是「点开目录后一条标题都不显示」
        let width = panelWidthConstraint.constant
        if abs(width - lastLaidOutWidth) > 0.5 {
            lastLaidOutWidth = width
            collectionView.collectionViewLayout.invalidateLayout()
        }
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
        // 已经看得见就别动它，否则光标一动列表就跟着抖
        let visibleTop = collectionView.contentOffset.y
        let visibleBottom = visibleTop + collectionView.bounds.height
        if top >= visibleTop + 0.5, top + rowHeight <= visibleBottom - 0.5 { return }
        // 目标矩形给上面留一行，避免刚好卡在边缘反复滚
        let desired = max(0, top - rowHeight)
        scrollToContentOffsetY(desired, animated: true)
    }

    /// 重建之后把列表滚到该在的位置。
    ///
    /// 传进来的偏移是 0 有两种情况：本来就停在顶部，或者「全部折叠」那条路
    /// （`rebuildRows` 在那种情况下记的是 `.zero`）。后者要**真的回到顶部**，
    /// 所以这里不能遇到 0 就直接 return，得主动设一次。
    private func applyScrollOffset(_ offset: CGPoint) {
        scrollToContentOffsetY(offset.y, animated: false)
    }

    /// 把纵向偏移设到 `y`（自动夹在可滚范围内）。
    ///
    /// 夹范围要用**布局之后**的 `contentSize`，否则拿到的还是上一次的尺寸，
    /// 会夹错、滚不到位
    private func scrollToContentOffsetY(_ y: CGFloat, animated: Bool) {
        collectionView.layoutIfNeeded()
        let maximumY = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        let clamped = min(max(0, y), maximumY)
        guard abs(clamped - collectionView.contentOffset.y) > 0.5 else { return }
        collectionView.setContentOffset(CGPoint(x: 0, y: clamped), animated: animated)
    }

    // MARK: - 高亮

    /// 此刻真正该点亮的那一行。
    ///
    /// 目标被折叠藏起来时，往上取**最外层那个被折叠的祖先**：
    /// 光标在某个收起来的 H2 下的 H3 里打字时，界面上真正显示的是 H2 那一行，
    /// 点亮它才是用户看到的「当前章节」。
    ///
    /// 现算而不是存起来：行重建、折叠状态变化之后拿同一个「要求」重算，
    /// 结果自然是对的，不会出现「折一下底色就没了」
    private var effectiveHighlightID: UUID? {
        guard let requested = requestedHighlightID else { return nil }
        // 列表里找不到这条（比如是重建前的旧 id）→ 原样返回，下面查不到 cell 会自然忽略
        guard let index = tree.index(of: requested) else { return requested }
        let representative = tree.representativeIndex(of: index, collapsedIDs: collapsedIDs)
        return items[representative].id
    }

    /// 把「现在谁该亮」刷到屏幕上的 cell 上。
    ///
    /// 只处理可见的那些（十几行），整屏刷一遍也不贵。
    /// 屏幕外 / 还没创建的 cell 不用管 —— 它们创建时会照 `effectiveHighlightID` 配好
    private func refreshHighlightAppearance() {
        let target = effectiveHighlightID
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let cell = collectionView.cellForItem(at: indexPath) as? OutlineRowCell else { continue }
            cell.apply(highlighted: cell.item?.id == target)
        }
    }
}

// MARK: - 点击 / 尺寸（行区域交给 collection view 管）

extension MarkdownOutlineView: UICollectionViewDelegateFlowLayout {

    /// 点了某一行 → 跳转那一节。
    /// ⚠️ 点右边的折叠三角**不会**走到这里：三角是个 UIButton，
    /// 它自己把触摸吃掉，不会变成「选中 cell」
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        handleRowTap(at: indexPath.item)
    }

    /// 行宽按当前可视宽度现取，行高固定。
    ///
    /// 不给固定宽度是因为面板宽度会随窗口变（`effectiveWidth`），
    /// 写死的话窗口一拉行就短一截
    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: max(0, collectionView.bounds.width - appearance.bodyHorizontalPadding * 2),
               height: appearance.rowHeight)
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        insetForSectionAt section: Int) -> UIEdgeInsets {
        UIEdgeInsets(top: appearance.bodyVerticalPadding,
                     left: appearance.bodyHorizontalPadding,
                     bottom: appearance.bodyVerticalPadding,
                     right: appearance.bodyHorizontalPadding)
    }
}

// MARK: - 一行

/// 目录里的一行（collection view 的 cell）。
///
/// 纯 UI 控件，同样不认识 markdown —— 给它一个 `OutlineItem` 它就能显示。
final class OutlineRowCell: UICollectionViewCell {

    static let reuseIdentifier = "OutlineRowCell"

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
    private var appearance = MarkdownOutlineAppearance()
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("OutlineRowCell 不支持从 coder 解档")
    }

    /// 手指按下时稍微变淡一下，给出即时反馈（cell 自带的 `isHighlighted` 就是干这个的）
    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.5 : 1 }
    }

    /// 重新准备复用：上一轮的状态（回调、缩进）都得清掉，
    /// 不然复用到别的行会带着上一行的东西
    override func prepareForReuse() {
        super.prepareForReuse()
        onDisclosureTapped = nil
        item = nil
        isRowHighlighted = false
        applyHighlightAppearance()
    }

    /// 把数据填进视图：标题文字、层级缩进、折叠三角、高亮。
    ///
    /// ### 为什么是一个方法配齐，而不是几个小方法分开设
    /// cell 会被**复用**：从屏幕上滚走的那一行，视图对象会被拿去显示另一行。
    /// 所以每次复用必须把所有会变的东西都重写一遍。拆成「设标题」「设三角」「设高亮」
    /// 几个方法分别调，早晚会漏掉一个 —— 症状是「这一行显示着上一行的三角状态」，
    /// 而且只在滚动之后才出现，极难查。
    ///
    /// - parameter showsDisclosure: 要不要画右边的展开 / 折叠三角。
    ///   由面板算好传进来 —— 「这一行还有没有子标题」要看整棵树，一行自己不知道
    func configure(item: OutlineItem,
                   appearance: MarkdownOutlineAppearance,
                   collapsed: Bool,
                   highlighted: Bool,
                   showsDisclosure: Bool) {
        self.item = item
        self.appearance = appearance

        titleLabel.text = item.title.isEmpty ? "（空标题）" : item.title

        let indent = min(appearance.maximumIndent,
                         CGFloat(max(0, item.level - 1)) * appearance.indentPerLevel)
        accentBarLeading.constant = 6 + indent
        titleLabelLeading.constant = 15 + indent

        // 三角只在「还有子标题、且层级在 H1-H5」的行上显示（这条规则见
        // `OutlineTree.canCollapse`）。叶子行折起来不会有任何变化，
        // 画个三角反而让人以为坏了
        disclosureButton.isHidden = !showsDisclosure
        let name = collapsed ? "chevron.right" : "chevron.down"
        disclosureButton.setImage(UIImage(systemName: name, withConfiguration: Self.disclosureSymbol),
                                  for: .normal)
        disclosureButton.accessibilityLabel = showsDisclosure ? (collapsed ? "展开" : "折叠") : nil
        disclosureButton.accessibilityValue = collapsed ? "已折叠" : "已展开"

        accessibilityLabel = "\(item.level) 级标题，\(item.title)"
        accessibilityTraits = .button

        isRowHighlighted = highlighted
        applyHighlightAppearance()
    }

    /// 模拟点一下右边的展开 / 折叠三角（单元测试和 VoiceOver 之外的地方想触发时用）
    func tapDisclosure() {
        disclosureButton.sendActions(for: .touchUpInside)
    }

    /// 设置 / 取消「当前章节」高亮。
    func apply(highlighted: Bool) {
        guard highlighted != isRowHighlighted else { return }
        isRowHighlighted = highlighted
        applyHighlightAppearance()
    }

    private func setupSubviews() {
        contentView.layer.cornerRadius = 7
        contentView.layer.cornerCurve = .continuous

        accentBar.translatesAutoresizingMaskIntoConstraints = false
        accentBar.layer.cornerRadius = 1.25
        accentBar.isUserInteractionEnabled = false
        contentView.addSubview(accentBar)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isUserInteractionEnabled = false
        contentView.addSubview(titleLabel)

        // 三角为什么也放 `tintColor` 而不是写死颜色：跟着主题走，深色模式不用单独管
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        disclosureButton.tintColor = .tertiaryLabel
        disclosureButton.addTarget(self, action: #selector(disclosureTapped), for: .touchUpInside)
        // 三角在整个一行里是个小目标，给一个足够大的热区（24x24，符合最小可点尺寸）
        contentView.addSubview(disclosureButton)

        NSLayoutConstraint.activate([
            accentBar.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            // 高度取行的 55% 而不是写死数值：改 `rowHeight` 时它自己跟着变
            accentBar.heightAnchor.constraint(equalTo: contentView.heightAnchor, multiplier: 0.55),
            accentBar.widthAnchor.constraint(equalToConstant: 2.5),

            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            // 标题右边给三角让位。⚠️ 三角即使隐藏着也占着这块位置，
            // 所以有子标题和没子标题的行，标题文字右边界是对齐的
            titleLabel.trailingAnchor.constraint(equalTo: disclosureButton.leadingAnchor),

            disclosureButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            disclosureButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            disclosureButton.widthAnchor.constraint(equalToConstant: Self.disclosureSide),
            disclosureButton.heightAnchor.constraint(equalToConstant: Self.disclosureSide)
        ])

        accentBarLeading = accentBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor,
                                                             constant: 6)
        titleLabelLeading = titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor,
                                                               constant: 15)
        accentBarLeading.isActive = true
        titleLabelLeading.isActive = true
    }

    @objc private func disclosureTapped() {
        onDisclosureTapped?()
    }

    private func applyHighlightAppearance() {
        if isRowHighlighted {
            contentView.backgroundColor = tintColor.withAlphaComponent(0.13)
            accentBar.backgroundColor = tintColor
            accentBar.isHidden = false
            titleLabel.textColor = .label
            titleLabel.font = Self.font(forLevel: item?.level ?? 1, emphasized: true)
        } else {
            contentView.backgroundColor = .clear
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
