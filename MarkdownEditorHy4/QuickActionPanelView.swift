//
//  QuickActionPanelView.swift
//  MarkdownEditorHy4
//
//  悬浮编辑按钮弹出来的那块面板：一条毛玻璃底的圆角条，里面横向（或纵向）排几个按钮。
//
//  ### 它认识谁
//  只认识 `MarkdownQuickAction` 和「点了哪个按钮」这两个回调 —— 不认识编辑器，也不认识悬浮圆点。
//  谁把它摆在哪、菜单弹出来往哪儿放，都是 `FloatingEditButton` 的事。
//
//  ### 为什么按钮自己带背景高亮
//  面板底是毛玻璃，按钮要是光秃秃一行字，按下去没有任何反馈，用户会以为没点到。
//  这里用 `configurationUpdateHandler` 在**按下**时给按钮垫一层半透明底色：
//  比给每个按钮常驻一个灰色块干净，也不会把毛玻璃盖成一整条死板的灰。
//

import UIKit

/// 面板上的一项。
///
/// 有两种：一种自己就是个动作（点一下直接改文档），一种只是「更多」这种入口（点一下弹出 `menu` 里那几项）。
struct QuickActionPanelItem {

    /// 这一项代表的动作；nil 表示它只是个菜单入口，本身不改文档
    var action: MarkdownQuickAction?

    /// 按钮上的字
    var title: String

    /// 按钮上的图标（SF Symbol 名）；nil 或者系统里没这个符号时，只显示字
    var symbol: String?

    /// 字的字体（加粗 / 斜体那两个按钮要把字本身做成加粗 / 倾斜的）
    var titleFont: UIFont?

    /// 长按（或 `opensMenuOnTap` 为真时点一下）弹出来的菜单；空数组表示没有菜单
    var menu: [MarkdownQuickAction] = []

    /// 菜单是不是「点一下就弹」。默认 false —— 默认要长按才弹，单击直接执行动作
    var opensMenuOnTap = false

    /// 不走 `MarkdownQuickAction` 的自定义动作（比如「图片」要弹系统选择器）。
    ///
    /// 有它时点一下直接执行，不再看 `action` / `menu`。
    /// 用闭包而不是 case，是因为这类动作需要宿主（文档页）才能完成，
    /// 不该塞进「只改 markdown 字符」的动作枚举里。
    var handler: (() -> Void)?

    /// 按 `MarkdownQuickAction` 造一项（标题、图标、备选菜单都从动作自己身上取）。
    ///
    /// `menu` 传空数组时自动用动作自带的备选（标题那六项就是这样挂上去的）。
    static func action(_ action: MarkdownQuickAction, menu: [MarkdownQuickAction] = []) -> QuickActionPanelItem {
        QuickActionPanelItem(action: action,
                             title: action.title,
                             symbol: action.symbolName,
                             titleFont: action.titleFont,
                             menu: menu.isEmpty ? action.alternatives : menu)
    }

    /// 造一个「自定义入口」：点一下直接执行 `handler`，和 markdown 动作无关。
    ///
    /// 「图片」用的就是它 —— 插入图片要先弹系统选择器，那一步不是改字符，
    /// 没法写成 `MarkdownQuickAction`。
    static func custom(title: String, symbol: String?, handler: @escaping () -> Void) -> QuickActionPanelItem {
        QuickActionPanelItem(action: nil,
                             title: title,
                             symbol: symbol,
                             titleFont: nil,
                             handler: handler)
    }

    /// 造一个纯菜单入口（「更多」）：它自己不改文档，点一下弹出 `menu`
    static func menuEntry(title: String, symbol: String?, _ menu: [MarkdownQuickAction]) -> QuickActionPanelItem {
        QuickActionPanelItem(action: nil,
                             title: title,
                             symbol: symbol,
                             titleFont: nil,
                             menu: menu,
                             opensMenuOnTap: true)
    }
}

/// 一条毛玻璃底的按钮条。
final class QuickActionPanelView: UIView {

    // MARK: 回调

    /// 选中了一个动作（`button` 是用户点的那个按钮，菜单要对着它定位）
    var onSelect: ((_ action: MarkdownQuickAction, _ button: UIButton) -> Void)?

    /// 要弹菜单（`items` 是菜单里那几项，`button` 是对着它定位的那个按钮）
    var onMenu: ((_ items: [MarkdownQuickAction], _ button: UIButton) -> Void)?

    // MARK: 子视图与数据

    private let stack = UIStackView()
    private let items: [QuickActionPanelItem]
    private let axis: NSLayoutConstraint.Axis

    /// 玻璃顶部的一层高光。只有材质没有高光时，面板看起来像一块磨砂塑料
    private let sheen = CAGradientLayer()

    /// 每个按钮连同它对应的那一项、以及「图标到底取到没有」。
    ///
    /// ⚠️ 按**按钮对象本身**配对，不用 tag：tag 得先找一个不会重复的整数，标题重名就配错了。
    private var entries: [(item: QuickActionPanelItem, button: UIButton, hasSymbol: Bool)] = []

    /// 按钮和面板边缘之间留多少。条越厚看起来越「浮」，但别超过 6，否则按钮显得很小
    private static let padding: CGFloat = 5
    private static let spacing: CGFloat = 4
    private static let buttonHeight: CGFloat = 36
    private static let cornerRadius: CGFloat = 12

    // MARK: 生命周期

    init(items: [QuickActionPanelItem], axis: NSLayoutConstraint.Axis) {
        self.items = items
        self.axis = axis
        super.init(frame: .zero)

        // 毛玻璃：透的是**材质**而不是给容器打 alpha —— 给容器打 alpha 会把里面的按钮一起弄成半透明，叠在正文上时底下的字还会透成一片糊（这套浮层的老规矩，见项目记忆）
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        // 从上往下的一道淡高光，给平面材质加一点玻璃的厚度感；压在模糊层上、按钮下面
        sheen.colors = [
            UIColor.white.withAlphaComponent(0.3).cgColor,
            UIColor.white.withAlphaComponent(0.05).cgColor,
            UIColor.clear.cgColor
        ]
        sheen.locations = [0, 0.35, 0.8]
        sheen.startPoint = CGPoint(x: 0.5, y: 0)
        sheen.endPoint = CGPoint(x: 0.5, y: 1)
        sheen.masksToBounds = true
        layer.addSublayer(sheen)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = axis
        stack.spacing = Self.spacing
        stack.alignment = .fill
        stack.distribution = .equalSpacing
        addSubview(stack)

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding)
        ])

        for item in items {
            let (button, hasSymbol) = makeButton(for: item)
            entries.append((item, button, hasSymbol))
            stack.addArrangedSubview(button)
        }

        layer.cornerRadius = Self.cornerRadius
        layer.borderWidth = 0.5
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 6)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 没实现：这个面板只在代码里创建") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 毛玻璃要跟着圆角裁，不然四个角会戳出面板外面
        let radius = min(Self.cornerRadius, bounds.height / 2)
        layer.cornerRadius = radius
        // 描边和高光都跟着圆角走，换外观时描边颜色也要重新取
        layer.borderColor = UIColor.label.withAlphaComponent(0.12).cgColor
        sheen.frame = bounds
        sheen.cornerRadius = radius
        for subview in subviews where subview is UIVisualEffectView {
            subview.layer.cornerRadius = radius
            subview.clipsToBounds = true
        }
    }

    // MARK: 尺寸

    /// 面板按当前内容算出来该多大（外面拿它定 frame）。
    ///
    /// `showsLabels` 为 false 时按钮只留图标 —— 窗口太窄塞不下整条时用得上。
    ///
    /// ### 为什么自己按按钮的 `intrinsicContentSize` 加一遍，而不用 `systemLayoutSizeFitting`
    /// 那套 API 两种用法都会出错：`layoutFittingCompressedSize` 允许系统把按钮**压扁**
    /// （实测「行内代码」被压成 28pt —— 四个字只露出两个），而给它一个大目标尺寸配 `fittingSizeLevel`
    /// 又会把目标尺寸当真，直接返回两千多。按钮该多宽只有按钮自己知道，问它再相加最稳。
    func contentSize(showsLabels: Bool = true) -> CGSize {
        applyShowsLabels(showsLabels)
        // 按钮之间那几道缝：n 个按钮只有 n-1 道
        let gap = entries.count > 1 ? Self.spacing * CGFloat(entries.count - 1) : 0

        var width: CGFloat = 0
        var height: CGFloat = 0
        if axis == .horizontal {
            // 横向：宽是**每个按钮的宽度之和**，高取最高的那个
            width = entries.reduce(0) { $0 + $1.button.intrinsicContentSize.width } + gap
            height = entries.reduce(0) { max($0, $1.button.intrinsicContentSize.height) }
        } else {
            // 纵向：宽取**最宽**的那个（不然每个按钮宽窄不一、右边的边线对不齐），高是高度之和
            width = entries.reduce(0) { max($0, $1.button.intrinsicContentSize.width) }
            height = entries.reduce(0) { $0 + $1.button.intrinsicContentSize.height } + gap
        }
        return CGSize(width: ceil(width) + Self.padding * 2,
                      height: max(Self.buttonHeight, ceil(height)) + Self.padding * 2)
    }

    /// 只留图标、把文字藏起来（窗口窄到整条塞不下时降级用）。
    ///
    /// ⚠️ 只对**真的有图标**的按钮生效：`H1` / `B` / `I` 这几个本来就是纯文字，藏了就什么都不剩了。
    private func applyShowsLabels(_ showsLabels: Bool) {
        for entry in entries {
            var configuration = entry.button.configuration
            configuration?.title = (showsLabels || !entry.hasSymbol) ? entry.item.title : nil
            entry.button.configuration = configuration
        }
    }

    // MARK: 按钮

    private func makeButton(for item: QuickActionPanelItem) -> (button: UIButton, hasSymbol: Bool) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = item.title
        // 纵向的菜单里让字靠左（跟系统菜单一个观感）；横向那条按钮短，居中更好看
        configuration.titleAlignment = axis == .vertical ? .leading : .center
        configuration.titleTextAttributesTransformer =
            UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = item.titleFont ?? .systemFont(ofSize: 14, weight: .regular)
                return outgoing
            }
        // 图标取不到（系统里没这个符号）就只显示字，不留一个空白的坑
        var hasSymbol = false
        if let symbol = item.symbol, let image = UIImage(systemName: symbol) {
            configuration.image = image
            configuration.imagePlacement = .leading
            configuration.imagePadding = 4
            configuration.preferredSymbolConfigurationForImage =
                UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            hasSymbol = true
        }
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        configuration.background.cornerRadius = 8
        configuration.baseForegroundColor = .label

        let button = UIButton(configuration: configuration, primaryAction: nil)
        button.accessibilityLabel = item.title
        button.translatesAutoresizingMaskIntoConstraints = false
        // Mac 上鼠标移上去有个高亮框，不然 Catalyst 里完全看不出这是个按钮
        button.isPointerInteractionEnabled = true
        // 横向：既不许被拉宽，也不许被压窄 —— 压窄了标题会被截掉（「行内代码」变「行内」）
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.buttonHeight - 4).isActive = true

        // 按下时垫一层半透明底色当反馈（松手就撤掉）
        button.configurationUpdateHandler = { button in
            var updated = button.configuration
            updated?.background.backgroundColor =
                button.isHighlighted ? UIColor.label.withAlphaComponent(0.12) : .clear
            button.configuration = updated
        }

        button.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)
        if !item.menu.isEmpty {
            let press = UILongPressGestureRecognizer(target: self, action: #selector(buttonLongPressed(_:)))
            press.minimumPressDuration = 0.35
            button.addGestureRecognizer(press)
        }
        return (button, hasSymbol)
    }

    @objc private func buttonTapped(_ sender: UIButton) {
        guard let item = item(for: sender) else { return }
        // 自定义入口（图片）：交给宿主自己处理，和 markdown 动作 / 菜单两条路都不相干
        if let handler = item.handler {
            handler()
            return
        }
        if let action = item.action, !item.opensMenuOnTap {
            onSelect?(action, sender)
            return
        }
        // 「更多」这类入口（以及没有自己动作的那一项）走弹菜单
        if !item.menu.isEmpty { onMenu?(item.menu, sender) }
    }

    @objc private func buttonLongPressed(_ gesture: UILongPressGestureRecognizer) {
        // 长按只在「刚按住」那一刻弹一次：不判 .began 的话，手指没松开也会一遍遍弹
        guard gesture.state == .began,
              let button = gesture.view as? UIButton,
              let item = item(for: button),
              !item.menu.isEmpty else { return }
        onMenu?(item.menu, button)
    }

    private func item(for button: UIButton) -> QuickActionPanelItem? {
        entries.first { $0.button === button }?.item
    }
}
