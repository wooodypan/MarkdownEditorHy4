//
//  FloatingEditButton.swift
//  MarkdownEditorHy4
//
//  悬浮在正文上的那个编辑按钮：一个毛玻璃小圆点，点一下旁边展开一条按钮条。
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
//  ### 圆点的材质
//  底下垫一层 `UIVisualEffectView`，不靠半透明白色撑场面。
//  闲置几秒后圆点会整体淡下去，免得一直挡着正文。
//

import UIKit

/// 悬浮编辑按钮。
///
/// 用法：加到某个容器视图上，把编辑器交给它（`textView`）。剩下的（拖动、展开、菜单、执行动作）它自己管。
final class FloatingEditButton: UIView {

    // MARK: 外部连接

    /// 动作施加到哪个编辑器上
    weak var textView: MarkdownTextView?

    /// 点「图片」时由宿主弹图片选择器。
    ///
    /// 按钮本身不碰相册 / 文件，也不认识 `PHPickerViewController`：
    /// 「挑一张图、存到哪儿」是文档页的事，按钮只负责把这一下转出去。
    var onRequestInsertImage: (() -> Void)?

    /// 展开后点圆点和按钮条以外的空白，是否自动收起。默认开启。
    var dismissesOnOutsideTap = true {
        didSet { updateToolbarBackdrop() }
    }

    /// 点完一个动作后，是否把按钮条收起来。默认开启。
    ///
    /// 关掉之后条会留在原地，适合「连续给几段文字套格式」的用法。
    var collapsesAfterAction = true

    // MARK: 子视图

    /// 圆点底下的毛玻璃。之前是半透明白色，压在正文上更像一块塑料，也看不出材质
    private let glassView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))

    /// 圆点中间那个铅笔图标
    private let iconView = UIImageView()

    /// 展开后的横向按钮条（懒加载：弹出来才建）
    private var toolbarView: QuickActionPanelView?

    /// 长按 / 点「更多」弹出来的纵向菜单（用完就扔）
    private var menuView: QuickActionPanelView?

    /// 菜单后面那层透明遮罩：点它（也就是点菜单外面）就把菜单收起来
    private var menuBackdrop: UIControl?

    /// 展开时铺在按钮条下面的透明遮罩：点空白处收起（`dismissesOnOutsideTap` 关掉时不建）
    private var toolbarBackdrop: UIControl?

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

    /// 上一次布局时的容器尺寸，用来判断窗口 / 屏幕是不是变过
    private var lastSuperviewSize: CGSize = .zero

    /// 正在拖动。拖动过程中窗口尺寸变化不重新贴边，免得和手指抢位置
    private var isDragging = false

    /// 闲置变淡的计时器
    private var idleTimer: Timer?

    /// 窗口尺寸停稳后再存位置，避免拖动窗口时每秒写几十次 `UserDefaults`
    private var persistTimer: Timer?

    /// 松手吸附时的轻触反馈
    private let snapFeedback = UIImpactFeedbackGenerator(style: .light)

    // MARK: 常量

    private static let dotSize: CGFloat = 50
    private static let edgeMargin: CGFloat = 10
    private static let gap: CGFloat = 8

    /// 多少秒没碰就淡下去
    private static let idleDimDelay: TimeInterval = 3
    /// 淡下去之后的不透明度
    private static let idleAlpha: CGFloat = 0.45

    /// 没存过位置时的默认值：右侧偏上，不挡正文第一屏。x 只用来判断贴哪一边
    private static let defaultRelativeX: CGFloat = 0.93
    private static let defaultRelativeY: CGFloat = 0.62

    private static let positionKeyX = "floatingEditButton.relativeX"
    private static let positionKeyY = "floatingEditButton.relativeY"

    // MARK: 生命周期

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize))
        setupAppearance()
        setupGestures()
        scheduleIdleDim()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 没实现：这个按钮只在代码里创建") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // 离开窗口就停表；回到窗口重新开始数闲置时间
        if window == nil {
            idleTimer?.invalidate()
            idleTimer = nil
        } else {
            scheduleIdleDim()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 容器尺寸变了（转屏 / 拉窗口）→ 贴回边上，并重新摆一次按钮条
        clampCenterIntoSuperview()
    }

    /// 把圆点放回容器里能待的位置；窗口尺寸变了就重新贴边。
    ///
    /// 恢复位置放在这里而不是 `didMoveToSuperview`：那一步发生在 `viewDidLoad` 里，
    /// 那时容器的 `bounds` 还是零，按算出来的位置会是 (0, 0)，圆点缩在左上角。
    ///
    /// 窗口一变宽，原来贴右边缘的圆点按绝对坐标会离边越来越远。这里记住它原来在哪一侧，
    /// 尺寸变了就贴回同一侧；纵向按比例跟过去，再夹回可见范围。拖动过程中不重新贴边。
    func clampCenterIntoSuperview() {
        guard let superview = superview,
              superview.bounds.width > 0, superview.bounds.height > 0 else { return }

        let size = superview.bounds.size
        let previousSize = lastSuperviewSize
        let sizeChanged = previousSize.width > 0 && previousSize.height > 0 && previousSize != size
        lastSuperviewSize = size
        let limits = Self.centerLimits(of: superview)

        if needsPositionRestore {
            needsPositionRestore = false
            // 存的是比例：x 只用来判断上次贴哪一边，y 直接按比例还原
            let stored = Self.storedRelativePosition()
            center = CGPoint(x: stored.x <= 0.5 ? limits.minX : limits.maxX,
                             y: min(max(size.height * stored.y, limits.minY), limits.maxY))
        } else if sizeChanged, !isDragging {
            let wasLeft = center.x <= previousSize.width / 2
            let relativeY = center.y / previousSize.height
            center = CGPoint(x: wasLeft ? limits.minX : limits.maxX,
                             y: min(max(size.height * relativeY, limits.minY), limits.maxY))
            schedulePositionPersist()
        }

        center = CGPoint(x: min(max(center.x, limits.minX), limits.maxX),
                         y: min(max(center.y, limits.minY), limits.maxY))

        if sizeChanged, !isDragging {
            // 菜单位置是按旧尺寸算的，窗口一变就直接收掉，免得挂在半空
            dismissMenu()
        }
        if isExpanded { layoutToolbar() }
        toolbarBackdrop?.frame = superview.bounds
    }

    // MARK: 外观

    private func setupAppearance() {
        backgroundColor = .clear
        layer.cornerRadius = Self.dotSize / 2
        // ⚠️ 圆点压在浅色正文上本来就几乎看不见，全靠这圈灰描边 + 投影把边界描出来
        //（iOS 辅助触控在白底上也是靠一圈灰环才认得出形状的）。描边再淡一点，圆点就找不到了
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 0.4, alpha: 0.35).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)
        accessibilityLabel = "悬浮编辑按钮"
        isAccessibilityElement = true

        // 玻璃自己裁圆角，父层要留着阴影，不能 clipsToBounds
        glassView.isUserInteractionEnabled = false
        glassView.layer.cornerRadius = Self.dotSize / 2
        glassView.clipsToBounds = true
        glassView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassView)
        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        iconView.image = UIImage(systemName: "pencil")
        // 跟着系统外观走：深色模式下玻璃是暗的，再用深灰图标就看不清了
        iconView.tintColor = .label
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
        wakeFromIdle()
        dismissMenu()
        pulseDot()
        isExpanded ? collapse() : expand()
    }

    /// 点下去的轻微回弹：先缩一点再弹回原尺寸，给手指一个「按到了」的反馈。
    private func pulseDot() {
        UIView.animate(withDuration: 0.1, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        } completion: { _ in
            UIView.animate(withDuration: 0.4, delay: 0,
                           usingSpringWithDamping: 0.55,
                           initialSpringVelocity: 0.7,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transform = .identity
            }
        }
    }

    @objc private func dotPanned(_ gesture: UIPanGestureRecognizer) {
        guard let superview = superview else { return }
        switch gesture.state {
        case .began:
            wakeFromIdle()
            isDragging = true
            idleTimer?.invalidate()
            idleTimer = nil
            // 拖动时先把按钮条收起来：条跟着圆点一起飞既晃眼又挡正文
            dismissMenu()
            collapse()
            dragStartCenter = center
            // 拎起来：稍微放大、阴影加深，松手再落回去
            setLifted(true)
            snapFeedback.prepare()
        case .changed:
            let move = gesture.translation(in: superview)
            center = CGPoint(x: dragStartCenter.x + move.x, y: dragStartCenter.y + move.y)
            clampCenterIntoSuperview()
        case .ended, .cancelled, .failed:
            isDragging = false
            setLifted(false)
            snapToNearestEdge(velocity: gesture.velocity(in: superview))
            scheduleIdleDim()
        default:
            break
        }
    }

    /// 松手后吸附到左右边缘（iOS 辅助触控就是这个行为）。
    ///
    /// 甩得够快就顺着甩的方向贴；慢慢松开才按离哪边近来算。
    /// 停在屏幕正中间的话，圆点会一直压着一行字；贴着边就只压到边距那一小块。
    private func snapToNearestEdge(velocity: CGPoint) {
        guard let superview = superview else { return }
        let limits = Self.centerLimits(of: superview)

        let targetX: CGFloat
        if abs(velocity.x) > 300 {
            targetX = velocity.x < 0 ? limits.minX : limits.maxX
        } else {
            targetX = (center.x - limits.minX) < (limits.maxX - center.x) ? limits.minX : limits.maxX
        }
        let target = CGPoint(x: targetX, y: min(max(center.y, limits.minY), limits.maxY))

        // 甩得越快，弹簧的初速度越大，回弹更利落
        let springVelocity = min(abs(velocity.x) / 600, 1.4)
        UIView.animate(withDuration: 0.34, delay: 0,
                       usingSpringWithDamping: 0.78,
                       initialSpringVelocity: springVelocity,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.center = target
            self.transform = .identity
        }
        Self.storeRelativePosition(x: superview.bounds.width > 0 ? target.x / superview.bounds.width : Self.defaultRelativeX,
                                   y: superview.bounds.height > 0 ? target.y / superview.bounds.height : Self.defaultRelativeY)
        snapFeedback.impactOccurred()
    }

    /// 拖动时拎起来的分量：放大一点、阴影加深；松手落回去。
    private func setLifted(_ lifted: Bool) {
        let duration: TimeInterval = lifted ? 0.15 : 0.28
        UIView.animate(withDuration: duration, delay: 0,
                       usingSpringWithDamping: 0.72,
                       initialSpringVelocity: 0.4,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.transform = lifted ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity
        }

        let opacity: Float = lifted ? 0.32 : 0.22
        let radius: CGFloat = lifted ? 16 : 10
        animateShadow(opacity: opacity, radius: radius, duration: duration)
    }

    /// 阴影不是 `UIView` 的可动画属性，只能走 `CABasicAnimation`。
    private func animateShadow(opacity: Float, radius: CGFloat, duration: TimeInterval) {
        let opacityAnimation = CABasicAnimation(keyPath: "shadowOpacity")
        opacityAnimation.fromValue = layer.shadowOpacity
        opacityAnimation.toValue = opacity
        opacityAnimation.duration = duration
        opacityAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(opacityAnimation, forKey: "liftShadowOpacity")
        layer.shadowOpacity = opacity

        let radiusAnimation = CABasicAnimation(keyPath: "shadowRadius")
        radiusAnimation.fromValue = layer.shadowRadius
        radiusAnimation.toValue = radius
        radiusAnimation.duration = duration
        radiusAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(radiusAnimation, forKey: "liftShadowRadius")
        layer.shadowRadius = radius
    }

    // MARK: 展开 / 收起

    private func expand() {
        guard let superview = superview, !isExpanded else { return }
        wakeFromIdle()
        isExpanded = true
        setIcon("xmark")

        let toolbar = toolbarView ?? makeToolbar()
        toolbarView = toolbar
        if toolbar.superview == nil { superview.addSubview(toolbar) }
        layoutToolbar()
        toolbar.isHidden = false
        updateToolbarBackdrop()
        // 从圆点朝外长出来：起点小一点，并朝圆点方向偏几像素，弹簧回弹到原位。
        // ⚠️ 只动 transform 不动 alpha：浮层容器打 < 1 的 alpha 会让里面的按钮一起变虚（项目里的老规矩）
        let towardDot: CGFloat = center.x <= superview.bounds.midX ? -10 : 10
        toolbar.transform = CGAffineTransform(translationX: towardDot, y: 4)
            .scaledBy(x: 0.86, y: 0.86)
        toolbar.alpha = 1
        UIView.animate(withDuration: 0.42, delay: 0,
                       usingSpringWithDamping: 0.72,
                       initialSpringVelocity: 0.6,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            toolbar.transform = .identity
        }
    }

    /// 切换圆点里的图标，用交叉淡入代替硬切。
    private func setIcon(_ name: String) {
        UIView.transition(with: iconView, duration: 0.2,
                          options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.iconView.image = UIImage(systemName: name)
        }
    }

    private func collapse() {
        guard isExpanded, let toolbar = toolbarView else { return }
        isExpanded = false
        setIcon("pencil")
        dismissMenu()
        updateToolbarBackdrop()
        scheduleIdleDim()
        let towardDot: CGFloat = center.x <= (superview?.bounds.midX ?? center.x) ? -8 : 8
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            toolbar.transform = CGAffineTransform(translationX: towardDot, y: 2)
                .scaledBy(x: 0.9, y: 0.9)
        } completion: { finished in
            // 收完才藏：动画还没跑完就 `isHidden = true` 的话，动画根本看不见。
            // 被新的展开打断时（finished == false）不能藏，否则条会闪一下不见
            guard finished else { return }
            toolbar.isHidden = true
            toolbar.transform = .identity
        }
    }

    private func makeToolbar() -> QuickActionPanelView {
        let toolbar = QuickActionPanelView(items: mainRowItems, axis: .horizontal)
        toolbar.onSelect = { [weak self] action, _ in self?.perform(action) }
        toolbar.onMenu = { [weak self] actions, button in self?.showMenu(actions, anchoredTo: button) }
        return toolbar
    }

    /// 主横条上那七项（顺序就是屏幕上从左到右的顺序）。
    ///
    /// H1 只摆一个，长按它才把 H1~H6 全列出来 —— 六级别全摆上去的话，横条在窄窗口里就塞不下了。
    /// 「图片」不是 markdown 动作（它要先弹系统选择器），所以用 `QuickActionPanelItem.custom`。
    private var mainRowItems: [QuickActionPanelItem] {
        [
            .action(.heading(1)),
            .action(.todo),
            .action(.bulletedList),
            .action(.bold),
            .action(.italic),
            .custom(title: "图片", symbol: "photo") { [weak self] in self?.requestInsertImage() },
            .menuEntry(title: "更多", symbol: "ellipsis", MarkdownQuickAction.moreActions)
        ]
    }

    /// 点「图片」：先把横条收起来（选择器一弹，条留在后面既碍眼又挡事），再把请求交给宿主。
    private func requestInsertImage() {
        dismissMenu()
        collapse()
        onRequestInsertImage?()
    }

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
        var appearsAbove = true
        var y = anchor.minY - size.height - 6
        if y < area.minY {
            y = min(anchor.maxY + 6, area.maxY - size.height)
            appearsAbove = false
        }

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

        // 从按钮那一侧弹出来：菜单在上方就向下偏一点起步，在下方就向上偏一点
        let towardButton: CGFloat = appearsAbove ? 8 : -8
        menu.transform = CGAffineTransform(translationX: 0, y: towardButton)
            .scaledBy(x: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.34, delay: 0,
                       usingSpringWithDamping: 0.76,
                       initialSpringVelocity: 0.5,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            menu.transform = .identity
        }
    }

    @objc private func dismissMenu() {
        menuView?.removeFromSuperview()
        menuBackdrop?.removeFromSuperview()
        menuView = nil
        menuBackdrop = nil
        // 菜单关掉、条也收着，就可以重新开始数闲置时间了
        if !isExpanded { scheduleIdleDim() }
    }

    @objc private func toolbarBackdropTapped() {
        collapse()
    }

    /// 按当前是否展开、以及 `dismissesOnOutsideTap` 的开关，装上 / 撤掉按钮条的透明遮罩。
    private func updateToolbarBackdrop() {
        guard isExpanded, dismissesOnOutsideTap, let superview else {
            toolbarBackdrop?.removeFromSuperview()
            toolbarBackdrop = nil
            return
        }

        if let backdrop = toolbarBackdrop {
            backdrop.frame = superview.bounds
            return
        }

        let backdrop = UIControl(frame: superview.bounds)
        backdrop.backgroundColor = .clear
        backdrop.isAccessibilityElement = false
        backdrop.addTarget(self, action: #selector(toolbarBackdropTapped), for: .touchUpInside)

        // 垫在圆点下面：遮罩铺满容器，但圆点自己仍然点得到（点了就是收起），
        // 也不会把圆点抬到目录面板这类浮层上面去
        superview.insertSubview(backdrop, belowSubview: self)
        toolbarBackdrop = backdrop
    }

    // MARK: 闲置变淡

    /// 重新开始数闲置时间。展开着、菜单开着、正在拖动时不排这一班。
    private func scheduleIdleDim() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard !isExpanded, menuView == nil, !isDragging else { return }

        let timer = Timer(timeInterval: Self.idleDimDelay, repeats: false) { [weak self] _ in
            self?.dimIfIdle()
        }
        idleTimer = timer
        // `.common`：滚动正文时计时器也照常走，不会一直等滚动停下
        RunLoop.main.add(timer, forMode: .common)
    }

    private func dimIfIdle() {
        idleTimer = nil
        guard !isExpanded, menuView == nil, !isDragging else { return }
        UIView.animate(withDuration: 0.45, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = Self.idleAlpha
        }
    }

    /// 一碰圆点就恢复不透明，并把闲置计时停掉；下次松手 / 收起后再重新数。
    private func wakeFromIdle() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard alpha < 1 else { return }
        UIView.animate(withDuration: 0.18, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = 1
        }
    }

    // MARK: 执行动作

    private func perform(_ action: MarkdownQuickAction) {
        guard let textView = textView else { return }
        // 编辑器可能已经不是第一响应者了（刚拖过圆点），但选区还在 —— 动作照样作用在选区上
        action.apply(to: textView)
        if collapsesAfterAction { collapse() }
    }

    // MARK: 位置的小工具

    /// 窗口尺寸停稳 0.4 秒后再把位置记下来：拖动窗口的过程中 `layoutSubviews` 会连着来很多次，
    /// 每次都写 `UserDefaults` 没必要。
    private func schedulePositionPersist() {
        persistTimer?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.persistCurrentPosition()
        }
        persistTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func persistCurrentPosition() {
        persistTimer = nil
        guard let superview,
              superview.bounds.width > 0, superview.bounds.height > 0 else { return }
        Self.storeRelativePosition(x: center.x / superview.bounds.width,
                                   y: center.y / superview.bounds.height)
    }

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

    /// 圆点**圆心**能待的范围：在可用区域里再让出半个圆点，圆点才不会有一半探到容器外面。
    private static func centerLimits(of view: UIView) -> (minX: CGFloat, maxX: CGFloat,
                                                          minY: CGFloat, maxY: CGFloat) {
        let area = usableArea(of: view)
        let half = dotSize / 2
        return (area.minX + half,
                max(area.minX + half, area.maxX - half),
                area.minY + half,
                max(area.minY + half, area.maxY - half))
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
