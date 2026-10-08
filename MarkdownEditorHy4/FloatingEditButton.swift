//
//  FloatingEditButton.swift
//  MarkdownEditorHy4
//
//  悬浮在正文上的那个编辑按钮：一个半透明的白色小圆点，点一下旁边展开一条按钮条。
//
//  ### 它认识谁
//  只认识 `MarkdownQuickAction`（动作本身）和 `QuickActionPanelView`（那条按钮条）。
//  它**不认识**编辑器的内部：`MarkdownQuickAction.apply(to:)` 才负责把动作施加到文档上。
//  所以这个文件里没有任何一处拼 markdown 记号 —— 那是动作层的事。
//
//  ### 为什么做成手动 frame 而不是 Auto Layout
//  圆点要能被拖着走、还要吸附到左右边缘，这类「位置随时在变」的东西用约束写反而绕：
//  每次拖动都得改约束的常量、再手动提醒系统重排一次，反而更容易踩「数字改了屏幕上没变」的坑。
//  直接改 `center` 就是一份真相，拖动、吸附、越界夹取都读它写它。
//
//  ### 圆点的半透明是怎么来的
//  给 `backgroundColor` 一个 alpha 不到 1 的白色，**不是**给整个视图打 `alpha`。
//  给视图打 alpha 会把中间那个铅笔图标一起弄成半透明，图标就糊了。
//

import UIKit

/// 悬浮编辑按钮。
///
/// 用法：加到某个容器视图上，把编辑器交给它（`textView`）。剩下的（拖动、展开、菜单、执行动作）它自己管。
final class FloatingEditButton: UIView {

    // MARK: 外部连接

    /// 动作施加到哪个编辑器上
    weak var textView: MarkdownTextView?

    // MARK: 子视图

    /// 圆点中间那个铅笔图标
    private let iconView = UIImageView()

    /// 展开后的横向按钮条（懒加载：弹出来才建）
    private var toolbarView: QuickActionPanelView?

    /// 长按 / 点「更多」弹出来的纵向菜单（用完就扔）
    private var menuView: QuickActionPanelView?

    /// 菜单后面那层透明遮罩：点它（也就是点菜单外面）就把菜单收起来
    private var menuBackdrop: UIControl?

    // MARK: 状态

    /// 按钮条现在是展开的还是收起的
    private(set) var isExpanded = false

    /// 拖动开始时圆点在哪儿（拖动过程中按「起点 + 位移」算新位置，不然会越拖越快）
    private var dragStartCenter: CGPoint = .zero

    /// 上次停的位置还没恢复过。
    ///
    /// ⚠️ 恢复必须等容器真的有了尺寸才能做：`viewDidLoad` 里挂上去时 `bounds` 还是零，那时候按算出来的 center 是 (0, 0)，圆点会缩在左上角。所以这里只打个标记，等第一次布局再恢复。
    /// 位置记的是**比例**不是绝对坐标：窗口宽度每次启动都可能不一样，记绝对坐标会在窄窗口里跑到屏幕外面去。
    private var needsPositionRestore = true

    // MARK: 常量

    private static let dotSize: CGFloat = 50
    private static let edgeMargin: CGFloat = 10
    private static let gap: CGFloat = 8

    /// 圆点默认停在哪儿（相对于容器宽高的比例）：右下角偏上一点，不挡正文第一屏
    private static let defaultRelativeX: CGFloat = 0.93
    private static let defaultRelativeY: CGFloat = 0.62

    private static let positionKeyX = "floatingEditButton.relativeX"
    private static let positionKeyY = "floatingEditButton.relativeY"

    // MARK: 生命周期

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize))
        setupAppearance()
        setupGestures()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 没实现：这个按钮只在代码里创建") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 容器尺寸变了（转屏 / 拉窗口）→ 把圆点拉回可见范围，并重新摆一次按钮条
        clampCenterIntoSuperview()
    }

    /// 容器尺寸变了（转屏、拉窗口）之后把圆点拉回可见范围内；顺便补上「上次停在哪儿」的恢复。
    ///
    /// 位置记的是比例，但圆点是绝对坐标摆着的 —— 窗口一变矮，原来的 y 可能就跑到窗口下面去了。
    /// 这里只做「夹回边界内」，夹完不再重新按比例算，免得用户自己拖好的位置被莫名其妙挪走。
    ///
    /// ⚠️ 恢复放在这里而不是 `didMoveToSuperview`：那一步发生在 `viewDidLoad` 里，那时容器的 `bounds` 还是零，按算出来的位置会是 (0, 0)，圆点缩在左上角。
    func clampCenterIntoSuperview() {
        guard let superview = superview,
              superview.bounds.width > 0, superview.bounds.height > 0 else { return }
        if needsPositionRestore {
            needsPositionRestore = false
            let stored = Self.storedRelativePosition()
            center = CGPoint(x: superview.bounds.width * stored.x,
                             y: superview.bounds.height * stored.y)
        }
        let area = Self.usableArea(of: superview)
        center = CGPoint(x: min(max(center.x, area.minX), area.maxX),
                         y: min(max(center.y, area.minY), area.maxY))
        if isExpanded { layoutToolbar() }
    }

    // MARK: 外观

    private func setupAppearance() {
        backgroundColor = UIColor(white: 1, alpha: 0.5)
        layer.cornerRadius = Self.dotSize / 2
        // ⚠️ 白 50% 压在白色正文上**本来就几乎看不见**，全靠这圈灰描边 + 投影把边界描出来
        //（iOS 辅助触控在白底上也是靠一圈灰环才认得出形状的）。描边再淡一点，圆点就找不到了
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 0.4, alpha: 0.35).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
        accessibilityLabel = "悬浮编辑按钮"
        isAccessibilityElement = true

        iconView.image = UIImage(systemName: "pencil")
        iconView.tintColor = UIColor(white: 0.2, alpha: 0.7)
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    // MARK: 手势

    private func setupGestures() {
        // 点击和拖动两个手势并存：手指（鼠标）一动超过几个点，点击手势自己就会失败、交给下面这个拖动，所以「拖完最后那一下」不会被当成点击又把条弹出来 —— 不需要额外写距离判断
        let tap = UITapGestureRecognizer(target: self, action: #selector(dotTapped))
        addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(dotPanned(_:)))
        addGestureRecognizer(pan)
    }

    @objc private func dotTapped() {
        dismissMenu()
        isExpanded ? collapse() : expand()
    }

    @objc private func dotPanned(_ gesture: UIPanGestureRecognizer) {
        guard let superview = superview else { return }
        switch gesture.state {
        case .began:
            // 拖动时先把按钮条收起来：条跟着圆点一起飞既晃眼又挡正文
            dismissMenu()
            collapse()
            dragStartCenter = center
        case .changed:
            let move = gesture.translation(in: superview)
            center = CGPoint(x: dragStartCenter.x + move.x, y: dragStartCenter.y + move.y)
            clampCenterIntoSuperview()
        case .ended, .cancelled:
            snapToNearestEdge()
        default:
            break
        }
    }

    /// 松手之后吸附到左右两侧离得近的那一边（iOS 辅助触控就是这个行为）。
    ///
    /// 停在屏幕正中间的话，圆点会一直压着一行字；贴着边就只压到边距那一小块。
    private func snapToNearestEdge() {
        guard let superview = superview else { return }
        let area = Self.usableArea(of: superview)
        let targetX = (center.x - area.minX) < (area.maxX - center.x) ? area.minX : area.maxX
        let target = CGPoint(x: targetX, y: min(max(center.y, area.minY), area.maxY))
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.center = target
        }
        Self.storeRelativePosition(x: superview.bounds.width > 0 ? target.x / superview.bounds.width : Self.defaultRelativeX,
                                   y: superview.bounds.height > 0 ? target.y / superview.bounds.height : Self.defaultRelativeY)
    }

    // MARK: 展开 / 收起

    private func expand() {
        guard let superview = superview, !isExpanded else { return }
        isExpanded = true
        iconView.image = UIImage(systemName: "xmark")

        let toolbar = toolbarView ?? makeToolbar()
        toolbarView = toolbar
        if toolbar.superview == nil { superview.addSubview(toolbar) }
        layoutToolbar()
        toolbar.isHidden = false
        // 从小放大一下，提示「条是从圆点这儿长出来的」。
        // ⚠️ 只动 transform 不动 alpha：浮层容器打 < 1 的 alpha 会让里面的按钮一起变虚（项目里的老规矩）
        toolbar.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        toolbar.alpha = 1
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            toolbar.transform = .identity
        }
    }

    private func collapse() {
        guard isExpanded, let toolbar = toolbarView else { return }
        isExpanded = false
        iconView.image = UIImage(systemName: "pencil")
        dismissMenu()
        UIView.animate(withDuration: 0.15, animations: {
            toolbar.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        }, completion: { _ in
            // 收完才藏：动画还没跑完就 `isHidden = true` 的话，动画根本看不见
            toolbar.isHidden = true
            toolbar.transform = .identity
        })
    }

    private func makeToolbar() -> QuickActionPanelView {
        let toolbar = QuickActionPanelView(items: Self.mainRowItems, axis: .horizontal)
        toolbar.onSelect = { [weak self] action, _ in self?.perform(action) }
        toolbar.onMenu = { [weak self] actions, button in self?.showMenu(actions, anchoredTo: button) }
        return toolbar
    }

    /// 主横条上那六项（顺序就是屏幕上从左到右的顺序）。
    ///
    /// H1 只摆一个，长按它才把 H1~H6 全列出来 —— 六级别全摆上去的话，横条在窄窗口里就塞不下了。
    private static let mainRowItems: [QuickActionPanelItem] = [
        .action(.heading(1)),
        .action(.todo),
        .action(.bulletedList),
        .action(.bold),
        .action(.italic),
        .menuEntry(title: "更多", symbol: "ellipsis", MarkdownQuickAction.moreActions)
    ]

    /// 把按钮条摆到圆点旁边：圆点在左半边就往右伸，在右半边就往左伸。
    ///
    /// 这样条永远不会把圆点顶到屏幕外面去 —— 圆点贴着右边时，条是往左长的。
    private func layoutToolbar() {
        guard let superview = superview, let toolbar = toolbarView else { return }
        let area = Self.usableArea(of: superview)

        // 先按「带文字」算一次；塞不下就退化成只留图标，再不行才夹到可用宽度
        var size = toolbar.contentSize(showsLabels: true)
        if size.width > area.width { size = toolbar.contentSize(showsLabels: false) }
        size.width = min(size.width, area.width)

        let expandRight = center.x <= superview.bounds.midX
        let x = expandRight ? frame.maxX + Self.gap : frame.minX - Self.gap - size.width
        let y = center.y - size.height / 2
        toolbar.frame = CGRect(
            x: min(max(x, area.minX), area.maxX - size.width),
            y: min(max(y, area.minY), max(area.minY, area.maxY - size.height)),
            width: size.width,
            height: size.height)
    }

    // MARK: 菜单

    private func showMenu(_ actions: [MarkdownQuickAction], anchoredTo button: UIButton) {
        guard let superview = superview else { return }
        dismissMenu()

        let menu = QuickActionPanelView(items: actions.map { .action($0) }, axis: .vertical)
        menu.onSelect = { [weak self] action, _ in
            self?.perform(action)
            self?.dismissMenu()
        }

        // 默认弹在按钮**上方**（跟系统菜单一个方向）；上方顶到屏幕边了就改弹下方
        let anchor = button.convert(button.bounds, to: superview)
        let area = Self.usableArea(of: superview)
        let size = menu.contentSize()
        var y = anchor.minY - size.height - 6
        if y < area.minY { y = min(anchor.maxY + 6, area.maxY - size.height) }

        menu.frame = CGRect(
            x: min(max(anchor.midX - size.width / 2, area.minX), max(area.minX, area.maxX - size.width)),
            y: min(max(y, area.minY), max(area.minY, area.maxY - size.height)),
            width: size.width,
            height: size.height)

        // 透明遮罩：点菜单外面任何地方都把菜单收起来（不加这层的话，菜单会一直挂在屏幕上）
        let backdrop = UIControl(frame: superview.bounds)
        backdrop.backgroundColor = .clear
        backdrop.addTarget(self, action: #selector(dismissMenu), for: .touchUpInside)

        superview.addSubview(backdrop)
        superview.addSubview(menu)
        menuBackdrop = backdrop
        menuView = menu

        menu.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            menu.transform = .identity
        }
    }

    @objc private func dismissMenu() {
        menuView?.removeFromSuperview()
        menuBackdrop?.removeFromSuperview()
        menuView = nil
        menuBackdrop = nil
    }

    // MARK: 执行动作

    private func perform(_ action: MarkdownQuickAction) {
        guard let textView = textView else { return }
        // 编辑器可能已经不是第一响应者了（刚拖过圆点），但选区还在 —— 动作照样作用在选区上
        action.apply(to: textView)
    }

    // MARK: 位置的小工具

    /// 容器里圆点能待的范围（扣掉安全区，再扣掉边距），用 minX/maxX/minY/maxY 表示。
    private static func usableArea(of view: UIView) -> (minX: CGFloat, maxX: CGFloat,
                                                        minY: CGFloat, maxY: CGFloat,
                                                        width: CGFloat) {
        let insets = view.safeAreaInsets
        let bounds = view.bounds
        let minX = insets.left + Self.edgeMargin
        let maxX = bounds.width - insets.right - Self.edgeMargin
        let minY = insets.top + Self.edgeMargin
        let maxY = bounds.height - insets.bottom - Self.edgeMargin
        return (minX, maxX, minY, maxY, max(0, maxX - minX))
    }

    private static func storedRelativePosition() -> (x: CGFloat, y: CGFloat) {
        let defaults = UserDefaults.standard
        // ⚠️ 不能用 `double(forKey:)`：没存过时它返回 0，而 0 正好是「贴着最左边」这个合法位置 ——于是「从没拖过」会被当成「上次拖到了最左边」，默认值永远用不上
        let x = defaults.object(forKey: positionKeyX) as? NSNumber
        let y = defaults.object(forKey: positionKeyY) as? NSNumber
        return (x.map { CGFloat($0.doubleValue) } ?? defaultRelativeX,
                y.map { CGFloat($0.doubleValue) } ?? defaultRelativeY)
    }

    private static func storeRelativePosition(x: CGFloat, y: CGFloat) {
        UserDefaults.standard.set(Double(x), forKey: positionKeyX)
        UserDefaults.standard.set(Double(y), forKey: positionKeyY)
    }
}
