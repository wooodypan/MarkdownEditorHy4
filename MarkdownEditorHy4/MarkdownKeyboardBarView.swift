//
//  MarkdownKeyboardBarView.swift
//  MarkdownEditorHy4
//
//  键盘上方那条工具条（挂在编辑器的 `inputAccessoryView` 上）：左边是撤销 / 重做，最右边是「收起键盘」。
//
//  ### 它认识谁
//  谁都不认识：只往上报「撤销被按了 / 重做被按了 / 收起键被按了」这三个回调，具体动作由装配它的那一层接（现在是 `MarkdownDocumentViewController.setupEditor` 接的，接给了编辑器）。
//  将来往条上加功能，照 `setupButtons` 里那几行的样子再造一个按钮、插进 `row` 里弹簧**前面**就行 —— 这个类不需要认识编辑器。
//
//  ### 尺寸必须自己报
//  `inputAccessoryView` 是按「你自己报出来的尺寸」摆的，不报就摆不出来（跟 `FixedSizeAccessoryView` 那条坑同一个道理）。
//  这里两头都给了：初始 frame 带高度（有的摆放路径只认 frame，不看约束），`intrinsicContentSize` 再报一遍高度。
//

import UIKit

/// 键盘上方的一条工具条。
final class MarkdownKeyboardBarView: UIView {

    // MARK: 外部连接

    /// 按下「撤销」
    var onUndo: (() -> Void)?

    /// 按下「重做」
    var onRedo: (() -> Void)?

    /// 按下最右边那颗「收起键盘」
    var onDismissKeyboard: (() -> Void)?

    // MARK: 子视图

    /// 横着排的那一行：左端是功能按钮，中间一根弹簧，右端是收起键
    private let row = UIStackView()

    /// 撤销 / 重做：能不能点由外面喂（`setUndoEnabled`），这里只管画
    private let undoButton = UIButton(type: .system)
    private let redoButton = UIButton(type: .system)

    /// 一根「弹簧」：自己什么都没有，只是把后面的按钮顶到最右边
    private let spacer = UIView()

    /// 最右边的「收起键盘」
    private let dismissButton = UIButton(type: .system)

    // MARK: 常量

    /// 条的高度。44 是系统工具栏的常规高度：点起来不费劲，也不会占掉太多正文
    private static let barHeight: CGFloat = 44
    /// 按钮的高度（宽度交给按钮按图标 / 文字自己算）
    private static let buttonHeight: CGFloat = 32
    /// 内容离条的左右边缘各留多少
    private static let edgeMargin: CGFloat = 12
    /// 按钮之间的间距
    private static let itemSpacing: CGFloat = 8

    // MARK: 生命周期

    override init(frame: CGRect) {
        // 初始 frame 就把高度带上：`inputAccessoryView` 有的摆放路径只认 frame
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: Self.barHeight))
        setupBackground()
        setupButtons()
        setupRow()
    }

    @available(*, unavailable, message: "这条工具条只从代码里建")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 没实现")
    }

    /// 只报高度，不报宽度：条的宽度由系统拉满（跟着键盘 / 窗口走），报死了反而摆歪
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.barHeight)
    }

    // MARK: 界面搭建

    /// 半透明的底 + 顶上一条 1 像素分隔线。
    ///
    /// 底色用「页面底色打 0.85 透明」，不铺毛玻璃：毛玻璃在 Catalyst 上会显出一条明显的灰带子（还跟键盘那块灰叠在一起），看着像正文和键盘之间凭空多了一根横杠。
    /// 想彻底透明就把下面那行换成 `.clear`，分隔线留着 —— 不然条和键盘糊成一片，看不出边界在哪。
    ///
    /// ⚠️ 半透明只给 `backgroundColor`，**不能**给视图 `alpha`：给视图打 alpha 会把里面的按钮一起弄成半透明（这套界面的老规矩）。
    private func setupBackground() {
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale)
        ])
    }

    /// 铺横着那一行，并把「中间空着的地方」交给弹簧吃掉。
    ///
    /// 弹簧怎么把按钮顶到两边：这一行的左右两头都钉死在条上，多出来的宽度按「谁更愿意被拉宽」来分，弹簧的抗拉优先级调到最低，多出来的宽度就全归它（按钮那边调成了 `required`，一丝都不让拉）。
    /// 以后加功能按钮，`row.insertArrangedSubview(新按钮, at: 0)` 插在弹簧前面，会自动从左边排开、收起键仍在最右。
    private func setupRow() {
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.spacing = Self.itemSpacing
        row.alignment = .center
        row.distribution = .fill
        addSubview(row)

        spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(undoButton)
        row.addArrangedSubview(redoButton)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(dismissButton)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.edgeMargin),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.edgeMargin),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func setupButtons() {
        configure(undoButton, symbol: "arrow.uturn.backward", fallbackTitle: "撤销", label: "撤销")
        configure(redoButton, symbol: "arrow.uturn.forward", fallbackTitle: "重做", label: "重做")
        configure(dismissButton, symbol: "keyboard.chevron.compact.down", fallbackTitle: "收起键盘", label: "收起键盘")

        undoButton.addTarget(self, action: #selector(undoTapped), for: .touchUpInside)
        redoButton.addTarget(self, action: #selector(redoTapped), for: .touchUpInside)
        dismissButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)

        // 刚开始没东西可撤、也没东西可重做，先按灰的显示（外面之后会用 setUndoEnabled 修正）
        setUndoEnabled(false, redoEnabled: false)
    }

    /// 把一个系统图标装到按钮上。
    ///
    /// `fallbackTitle` 是「系统里没这个符号」时的退路 —— 宁可显示两个字，也不要一个没内容的空白按钮。
    private func configure(_ button: UIButton, symbol: String, fallbackTitle: String, label: String) {
        var configuration = UIButton.Configuration.plain()
        if let image = UIImage(systemName: symbol) {
            configuration.image = image
            configuration.preferredSymbolConfigurationForImage =
                UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        } else {
            configuration.title = fallbackTitle
            configuration.titleTextAttributesTransformer =
                UIConfigurationTextAttributesTransformer { incoming in
                    var outgoing = incoming
                    outgoing.font = .systemFont(ofSize: 15)
                    return outgoing
                }
        }
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        configuration.background.cornerRadius = 8
        button.configuration = configuration
        button.accessibilityLabel = label
        // Mac 上鼠标移上去要有个高亮框，不然 Catalyst 里完全看不出这是个按钮
        button.isPointerInteractionEnabled = true
        // ⚠️ 在条里绝不能被拉宽 / 压窄：拉宽了它自己会变形，压窄了图标会被切掉（这套浮层按钮的老规矩）
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 按下垫一层半透明底、不能点时整体变淡 —— 两件事都在这个回调里做，按钮状态一变它就会被叫到
        button.configurationUpdateHandler = { button in
            var updated = button.configuration
            let active = button.isEnabled
            updated?.background.backgroundColor = (button.isHighlighted && active)
                ? UIColor.label.withAlphaComponent(0.12)
                : .clear
            // ⚠️ configuration 的按钮不会自己变淡：`baseForegroundColor` 给死了就一直那么亮，得自己按 `isEnabled` 换颜色
            updated?.baseForegroundColor = active ? .label : .tertiaryLabel
            button.configuration = updated
        }
        button.heightAnchor.constraint(equalToConstant: Self.buttonHeight).isActive = true
    }

    // MARK: 按钮状态

    /// 「撤销 / 重做」这两粒按钮能不能点。
    ///
    /// 由外面在三个时机喂进来：刚装配好、正文变了、键盘动的时候（那时条刚好要出现，状态可能是上一次留下的）。
    func setUndoEnabled(_ undoEnabled: Bool, redoEnabled: Bool) {
        undoButton.isEnabled = undoEnabled
        redoButton.isEnabled = redoEnabled
        // ⚠️ 改完 `isEnabled` 手动喊一声：不喊的话按钮不一定会重跑 `configurationUpdateHandler`，颜色就停在上一档（看着还是亮的、点下去却没反应）
        undoButton.setNeedsUpdateConfiguration()
        redoButton.setNeedsUpdateConfiguration()
    }

    // MARK: 动作

    /// 三个动作本身都不在这里做 —— 只把「哪个被按了」报出去，因为该让谁放弃第一响应者、该撤谁的销，只有装配的那一层知道
    @objc private func undoTapped() {
        onUndo?()
    }

    @objc private func redoTapped() {
        onRedo?()
    }

    @objc private func dismissTapped() {
        onDismissKeyboard?()
    }
}
