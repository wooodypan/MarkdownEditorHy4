//
//  MarkdownFindBarView.swift
//  MarkdownEditorHy4
//
//  查找框 UI：输入框、命中计数、上一个 / 下一个、区分大小写 / 全字匹配的菜单，以及可展开的「替换为」那一行
//
//  ### 它认识谁
//  只认识 `MarkdownFindBarDelegate`（实现方是 `SearchCoordinator`）。
//  编辑器 - 协调者 - 查找框三者互不引用，装配在上层容器里做，和目录那一组（MarkdownOutlineView + OutlineCoordinator）是同一个格局。
//

import UIKit

/// 顶部那条查找 / 替换横条。
///
/// ### 它是怎么「出现 / 消失」的（这里踩过坑，别再改回压高度那套）
/// 早先的做法是「收起时把高度压成 0，正文顺势顶上来」，踩了两个坑：
/// - 高度一旦有两条约束同时在管（外面一条、内容撑出来一条），系统只会满足其中一条，收起就静默失效；
/// - 改完约束的数值，还得自己提醒系统「这个视图得重新排一次版」，否则数字已经改了、屏幕上还是老样子。
/// **现在的做法简单得多**：横条浮在正文上面，出现 / 消失只切 `isHidden`，高度完全不用管 —— 上面两个坑也就不存在了。
final class MarkdownFindBarView: UIView {

    // MARK: 外部连接

    weak var delegate: MarkdownFindBarDelegate?

    /// 「我要把自己收起来」的出口（由持有本横条的容器填：做动画、切状态都是它的事）
    var onDismiss: (() -> Void)?

    // MARK: 子视图

    private let queryField = SearchTextField()
    private let replaceField = SearchTextField()
    private let countLabel = UILabel()
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let optionsButton = UIButton(type: .system)
    private let replaceToggleButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let replaceButton = UIButton(type: .system)
    private let replaceAllButton = UIButton(type: .system)

    /// 查找那一行（输入框 + 计数 + 上一/下一 + 选项 + 替换开关 + 关闭）
    private let queryRow = UIStackView()
    /// 「替换为」那一行（输入框 + 替换 + 全部替换），点 ⇄ 才展开
    private let replaceRow = UIStackView()
    /// 两行外面那层竖着排的栈（横条的高度就由它撑出来：上下贴住它，它多高横条就多高）
    private let column = UIStackView()

    // MARK: 状态

    /// 当前的查找选项（由选项菜单改动，任何一次查找都会带上它）
    private var options = SearchOptions()

    /// 整个横条是不是收起来了 —— 就是「是不是藏着」，状态只有 `isHidden` 这一份真相，不另存一份标记
    var isCollapsed: Bool { isHidden }
    /// 「替换为」那一行要不要展开
    private var wantsReplaceRow = false

    /// 「替换为」那一行现在是不是显示着
    var showsReplaceRow: Bool { !replaceRow.isHidden }

    /// 输入框里现在的内容
    var query: String { queryField.text ?? "" }
    /// 替换框里现在的内容
    var replacement: String { replaceField.text ?? "" }

    // MARK: 常量

    private static let fieldHeight: CGFloat = 30
    private static let buttonSize: CGFloat = 30
    private static let edgeMargin: CGFloat = 10
    private static let rowSpacing: CGFloat = 8

    // MARK: 生命周期

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        setupSeparator()
        setupFields()
        setupButtons()
        setupRows()
        refreshOptionsMenu()
        countLabel.text = ""
        // 默认藏着：要等用户按 ⌘F 才出现
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("MarkdownFindBarView 不支持从 coder 解档")
    }

    // MARK: 界面搭建

    /// 底部那条 1 像素的分隔线（它是一种能随 dark mode 变色的 hairline）
    private let separator = UIView()

    private func setupSeparator() {
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale)
        ])
    }

    private func setupFields() {
        configure(queryField, placeholder: "查找")
        configure(replaceField, placeholder: "替换为")
        queryField.delegate = self
        replaceField.delegate = self
        // 输入框里的内容一变就汇报（什么时候真的去搜由协调者决定，它负责防抖）
        queryField.addTarget(self, action: #selector(queryDidChange), for: .editingChanged)
    }

    private func configure(_ field: SearchTextField, placeholder: String) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: 13)
        field.placeholder = placeholder
        field.autocorrectionType = .no
        field.returnKeyType = .default
        field.clearButtonMode = .whileEditing
        field.accessibilityLabel = placeholder
        field.heightAnchor.constraint(equalToConstant: Self.fieldHeight).isActive = true
    }

    private func setupButtons() {
        configure(previousButton, symbol: "chevron.up", accessibility: "上一个匹配")
        configure(nextButton, symbol: "chevron.down", accessibility: "下一个匹配")
        configure(closeButton, symbol: "xmark", accessibility: "关闭查找")
        configure(optionsButton, symbol: "textformat", accessibility: "查找选项")
        configure(replaceToggleButton, symbol: "arrow.triangle.2.circlepath", accessibility: "显示替换")

        previousButton.addTarget(self, action: #selector(previousTapped), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        replaceToggleButton.addTarget(self, action: #selector(replaceToggleTapped), for: .touchUpInside)

        replaceButton.setTitle("替换", for: .normal)
        replaceAllButton.setTitle("全部替换", for: .normal)
        configureText(replaceButton, accessibility: "替换当前")
        configureText(replaceAllButton, accessibility: "全部替换")
        replaceButton.addTarget(self, action: #selector(replaceTapped), for: .touchUpInside)
        replaceAllButton.addTarget(self, action: #selector(replaceAllTapped), for: .touchUpInside)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countLabel.textColor = .secondaryLabel
        countLabel.textAlignment = .right
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.accessibilityIdentifier = "查找命中计数"
    }

    private func configure(_ button: UIButton, symbol: String, accessibility: String) {
        let configuration = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.setImage(UIImage(systemName: symbol, withConfiguration: configuration), for: .normal)
        button.accessibilityLabel = accessibility
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            button.heightAnchor.constraint(equalToConstant: Self.buttonSize)
        ])
    }

    private func configureText(_ button: UIButton, accessibility: String) {
        button.titleLabel?.font = .systemFont(ofSize: 13)
        button.accessibilityLabel = accessibility
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 钉成和输入框一样高，替换行的高度才是确定的
        button.heightAnchor.constraint(equalToConstant: Self.fieldHeight).isActive = true
    }

    private func setupRows() {
        for row in [queryRow, replaceRow] {
            row.axis = .horizontal
            row.alignment = .center
        }
        queryRow.spacing = 4
        replaceRow.spacing = 8

        queryRow.addArrangedSubview(queryField)
        queryRow.addArrangedSubview(countLabel)
        queryRow.addArrangedSubview(previousButton)
        queryRow.addArrangedSubview(nextButton)
        queryRow.addArrangedSubview(optionsButton)
        queryRow.addArrangedSubview(replaceToggleButton)
        queryRow.addArrangedSubview(closeButton)

        replaceRow.addArrangedSubview(replaceField)
        replaceRow.addArrangedSubview(replaceButton)
        replaceRow.addArrangedSubview(replaceAllButton)
        replaceRow.isHidden = true

        column.axis = .vertical
        column.spacing = Self.rowSpacing
        column.addArrangedSubview(queryRow)
        column.addArrangedSubview(replaceRow)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        let margin = Self.edgeMargin
        // 四边都贴住：横条的高度就由「内容的高度 + 上下留白」决定，加不加替换行它自己会变
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: margin),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -margin),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin)
        ])
    }

    // MARK: 对外动作

    /// 显示 / 隐藏整个横条（上层容器调它）。
    ///
    /// 只切 `isHidden`，**不碰高度**：横条是浮在正文上面的，藏起来就等于不存在，
    /// 正文的位置从头到尾不受它影响（正文的上边钉在菜单栏下面，跟本横条无关）。
    func setCollapsed(_ collapsed: Bool) {
        isHidden = collapsed
    }

    /// 开始查找：输入框获得焦点，并把已有的内容全选（再打字就是重新起一次查找）。
    ///
    /// 显示 / 隐藏和动画由上层容器负责，这里只管焦点和选中。
    func beginSearch() {
        queryField.becomeFirstResponder()
        queryField.selectAll(nil)
    }

    /// 隐藏前把焦点收回来，免得键盘一直挂在上面
    func endSearch() {
        queryField.resignFirstResponder()
        replaceField.resignFirstResponder()
    }

    /// 切换「替换为」那一行的显示与否，返回切换之后的状态
    ///
    /// 直接把那一行从竖着的栈里藏掉就行 —— 被藏起来的一行不占位置，横条的高度会自己缩回去，一行约束都不用改。
    @discardableResult
    func toggleReplaceRow() -> Bool {
        wantsReplaceRow = !wantsReplaceRow
        replaceRow.isHidden = !wantsReplaceRow
        replaceToggleButton.accessibilityLabel = wantsReplaceRow ? "隐藏替换" : "显示替换"
        return showsReplaceRow
    }

    /// 往查找框里填一段字，并按一次「内容变了」，让协调者照常跑一次查找。
    ///
    /// 打开查找面板时会用它**预填**正文里选中的文字 —— 用户选了字再按 ⌘F，多半就是想找它。
    /// 走的是「改输入框内容 + 发一次编辑事件」这条路，和真人敲字完全一样，所以命中计数、高亮、防抖那套都不用另外再触发一遍。
    func fillQuery(_ text: String) {
        queryField.text = text
        queryField.sendActions(for: .editingChanged)
    }

    /// 模拟「往查找框里敲了一段字」（测试用入口，和 `fillQuery` 是同一条链）
    func typeQuery(_ text: String) {
        fillQuery(text)
    }

    // MARK: 按钮动作

    @objc private func queryDidChange() {
        delegate?.findBar(self, didChangeQuery: query, options: options)
    }

    @objc private func previousTapped() {
        delegate?.findBar(self, didStepBy: -1)
    }

    @objc private func nextTapped() {
        delegate?.findBar(self, didStepBy: 1)
    }

    @objc private func replaceTapped() {
        delegate?.findBar(self, didTapReplaceWith: replacement)
    }

    @objc private func replaceAllTapped() {
        delegate?.findBar(self, didTapReplaceAllWith: replacement)
    }

    @objc private func closeTapped() {
        delegate?.findBarDidClose(self)
    }

    @objc private func replaceToggleTapped() {
        _ = toggleReplaceRow()
    }

    // MARK: 选项菜单

    /// 重建选项菜单。每次改完 options 都要重建一次 —— 菜单项里的「勾」是快照，不会自己更新
    private func refreshOptionsMenu() {
        let caseItem = UIAction(title: "区分大小写", state: options.caseSensitive ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.options.caseSensitive.toggle()
            self.refreshOptionsMenu()
            self.queryDidChange()
        }
        let wholeItem = UIAction(title: "全字匹配", state: options.wholeWord ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.options.wholeWord.toggle()
            self.refreshOptionsMenu()
            self.queryDidChange()
        }
        optionsButton.menu = UIMenu(title: "", options: [.displayInline], children: [caseItem, wholeItem])
        optionsButton.showsMenuAsPrimaryAction = true
    }

    // MARK: 键盘

    /// Esc：关掉查找框（这是 Mac / 外接键盘上的习惯用法）
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [],
                      action: #selector(closeTapped))]
    }
}

// MARK: - 输入框回车 = 下一个 / 全部替换

extension MarkdownFindBarView: UITextFieldDelegate {

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === replaceField {
            delegate?.findBar(self, didTapReplaceWith: replacement)
        } else {
            delegate?.findBar(self, didStepBy: 1)
        }
        return true
    }
}

// MARK: - MarkdownSearchBarDisplaying

extension MarkdownFindBarView: MarkdownSearchBarDisplaying {

    func updateSearchSummary(current: Int, total: Int) {
        guard !query.isEmpty else {
            countLabel.text = ""
            setNavigationEnabled(false)
            return
        }
        if total == 0 {
            countLabel.text = "无结果"
            setNavigationEnabled(false)
            return
        }
        countLabel.text = current >= 0 ? "\(current + 1)/\(total)" : "\(total) 个"
        setNavigationEnabled(true)
    }

    func dismissSearchBar() {
        onDismiss?()
    }

    /// 没有命中时把「上一个 / 下一个」置灰（比点了没反应强）
    private func setNavigationEnabled(_ enabled: Bool) {
        previousButton.isEnabled = enabled
        nextButton.isEnabled = enabled
        replaceButton.isEnabled = enabled
        replaceAllButton.isEnabled = enabled
    }
}

/// 查找框 / 替换框用的输入框：边框和圆角都自己画，不用系统自带的那套。
///
/// ### 为什么要自己画
/// 系统自带的 `.roundedRect` 会在**获得焦点时自己换一副样子**（圆角突然变成高度的一半，整个框鼓成胶囊形），
/// 一失焦又缩回去。查找框和替换框上下挨着，正在编辑的那个跟另一个长得完全不一样，看着像两个不同的控件。
/// 所以这里把系统那套边框关掉，自己画一套**固定圆角**：有没有焦点都长一个样。
private final class SearchTextField: UITextField {

    /// 圆角大小：统一用这一个，不随焦点变化
    private static let cornerRadius: CGFloat = 8
    /// 文字离左右边框的留白（自己画边框之后系统不会帮忙留，得自己加）
    private static let horizontalInset: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 关掉系统那套边框 —— 就是它会跟着焦点变圆角
        borderStyle = .none
        // 浅灰底：用系统给的灰，深浅色模式切换时它自己会变
        backgroundColor = .tertiarySystemFill
        clipsToBounds = true
        layer.cornerRadius = Self.cornerRadius
        layer.borderWidth = 1.0 / UIScreen.main.scale
        refreshBorderColor()
    }

    required init?(coder: NSCoder) {
        fatalError("SearchTextField 不支持从 coder 解档")
    }

    /// 深浅色模式切换之后，图层上的边框颜色不会自己跟着变，得在这儿补一次
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshBorderColor()
    }

    private func refreshBorderColor() {
        layer.borderColor = UIColor.separator.cgColor
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: Self.horizontalInset, dy: 0)
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: Self.horizontalInset, dy: 0)
    }

    override func placeholderRect(forBounds bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: Self.horizontalInset, dy: 0)
    }
}
