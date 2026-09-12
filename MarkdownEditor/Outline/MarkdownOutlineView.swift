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
    /// 展开时的最大高度（同样会被父视图高度压小）
    var maximumHeight: CGFloat = 360
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
/// - 右上角箭头 → 收起成一个小方块，再点小方块展开（长文档时把编辑区让出来）。
///
/// ### 布局上的两个「自适应」
/// 面板自己不指定位置（位置由外部容器用约束定），只负责自己的
/// **宽度**和**高度**：宽度按父视图宽度的比例收窄，高度按内容算并压在上限之下。
/// 这样它在 iPhone 竖屏和 Mac Catalyst 大窗口里都能看。
final class MarkdownOutlineView: UIView, MarkdownOutlineDisplaying {

    // MARK: 对外

    /// 用户点击某一行的出口。实现方是 `OutlineCoordinator`
    weak var delegate: MarkdownOutlineViewDelegate?

    /// 外观参数，建好之后也能改（改完调一次 `refreshAppearance()`）
    var appearance: MarkdownOutlineAppearance

    /// 当前是不是收起状态
    private(set) var isCollapsed = false

    // MARK: 数据

    private var items: [OutlineItem] = []
    /// id → 行视图。用来做高亮定位，不用每次遍历整个栈
    private var rows: [UUID: OutlineRowView] = [:]
    /// 当前高亮的 id。`nil` 表示没有任何一行是高亮的
    private var highlightedID: UUID?

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
        self.items = items
        rebuildRows()
    }

    /// 高亮某一行；传 nil 表示取消所有高亮
    func highlightOutlineItem(_ id: UUID?) {
        guard id != highlightedID else { return }

        // 先把上一行熄掉。注意 highlightedID 可能是行重建前的旧 id，
        // 那时 rows 里已经查不到了，直接忽略即可
        if let previous = highlightedID { rows[previous]?.apply(highlighted: false) }
        highlightedID = id

        guard let id, let row = rows[id] else { return }
        row.apply(highlighted: true)
        scrollRowIntoView(for: id)
    }

    // MARK: - 收起 / 展开

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
    /// 行数不多（标题撑死几十个），整批重建比维护复用池省心得多，
    /// 也避免「diff 出错导致某几行显示旧标题」这类难查的问题。
    private func rebuildRows() {
        for subview in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        rows.removeAll()
        // 行都是新的了，之前那个高亮 id 对应的视图已经不存在 —— 清掉。
        // 协调者紧接着会重发一次高亮指令（它会用最新 id 重算），所以这里不会漏高亮
        highlightedID = nil

        if items.isEmpty {
            rowsStack.addArrangedSubview(makeEmptyLabel())
        } else {
            for item in items {
                let row = OutlineRowView(item: item, appearance: appearance)
                row.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
                row.heightAnchor.constraint(equalToConstant: appearance.rowHeight).isActive = true
                rowsStack.addArrangedSubview(row)
                rows[item.id] = row
            }
        }

        updateHeaderText()
        refreshPanelSize(animated: false)
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

    /// 面板高度上限：不超过设定上限，也不超过父视图高度的 62%。
    /// 后者保证小屏手机上目录不会一路顶到底。
    private var effectiveMaximumHeight: CGFloat {
        guard let superview, superview.bounds.height > 0 else { return appearance.maximumHeight }
        return min(appearance.maximumHeight, superview.bounds.height * 0.62)
    }

    /// 行区域的自然高度（有多少内容就要多高）
    private var bodyContentHeight: CGFloat {
        guard !items.isEmpty else { return appearance.emptyStateHeight }
        return CGFloat(items.count) * appearance.rowHeight + appearance.bodyVerticalPadding * 2
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
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let rowHeight = appearance.rowHeight
        let top = appearance.bodyVerticalPadding + CGFloat(index) * rowHeight
        // 目标矩形给上下各留一行，避免刚好卡在边缘反复滚
        let rect = CGRect(x: 0,
                          y: max(0, top - rowHeight),
                          width: 1,
                          height: rowHeight * 3)
        scrollView.scrollRectToVisible(rect, animated: true)
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

    private let accentBar = UIView()
    private let titleLabel = UILabel()
    private var appearance: MarkdownOutlineAppearance
    /// 是不是「当前光标所在章节」那一行（跟手指按下时的高亮是两码事）。
    /// 对外只读 —— 单元测试靠它断言「高亮到底落到哪一行了」
    private(set) var isRowHighlighted = false

    /// 缩进靠改这两条约束的 constant 实现，比每层包一个空白 view 省事
    private var accentBarLeading: NSLayoutConstraint!
    private var titleLabelLeading: NSLayoutConstraint!

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

        NSLayoutConstraint.activate([
            accentBar.centerYAnchor.constraint(equalTo: centerYAnchor),
            // 高度取行的 55% 而不是写死数值：改 `rowHeight` 时它自己跟着变
            accentBar.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.55),
            accentBar.widthAnchor.constraint(equalToConstant: 2.5),

            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])

        accentBarLeading = accentBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
        titleLabelLeading = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15)
        accentBarLeading.isActive = true
        titleLabelLeading.isActive = true
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
