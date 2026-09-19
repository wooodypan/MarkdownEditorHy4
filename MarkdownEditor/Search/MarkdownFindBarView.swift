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
/// ### 收起时怎么做到「一点高度都不占」（绕了四版才找对，别再改回去）
/// - **第一版**：外面钉一条 `height = 0`，和里面那套「内容四周」的约束**同时**生效。
///   两组都是 required，Auto Layout 只能丢掉一条 —— 实测丢的是 height，收起后仍留着 50pt。
/// - **第二版**：把横条自己做成 `UIStackView`，收起时把两行都 hidden 掉。问题是 `UIStackView` **没有 intrinsicContentSize**，于是没有任何约束在决定它的高度 —— 一旦被排到 50pt，收起时也还是 50pt。
/// - **第三版**：两组约束互斥切换（展开用内容那一组，收起换 height=0）。约束这回是对的，可 frame 还是 50 —— 于是误判成「约束没生效」，其实真凶是下面那条标脏问题，跟怎么切约束没关系。
/// - **现在的做法**：高度**自始至终只有一条约束说了算**，内容是抢不过它的 —— `column` 只钉上 / 左 / 右（**故意不钉下边**，钉了就等于让内容参与决定高度），横条自己挂一条 `heightAnchor` 约束，收起时把 constant 调成 0。
///   高度用 `expandedHeight` 算，和 constant 同源，不存在两边算得不一样的情况。
/// - ⚠️ **最关键的一条**：改完 constant 得自己把脏标上（见 `refreshHeightConstant()`）。
///   少了这一步，高度约束明明已经是 0 了，frame 还是老样子 —— 而且第一次排版之后才按 ⌘F 就一定会踩到，查找条直接弹不出来。
final class MarkdownFindBarView: UIView {

    // MARK: 外部连接

    weak var delegate: MarkdownFindBarDelegate?

    /// 「我要把自己收起来」的出口（由持有本横条的容器填：做动画、切状态都是它的事）
    var onDismiss: (() -> Void)?

    // MARK: 子视图

    private let queryField = UITextField()
    private let replaceField = UITextField()
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
    /// 两行外面那层竖着排的栈（它只负责排内容，横条的高度跟它无关）
    private let column = UIStackView()
    /// 横条自己的高度约束 —— 展开还是收起，从头到尾都是这一条在说了算
    private var heightConstraint: NSLayoutConstraint?

    // MARK: 状态

    /// 当前的查找选项（由选项菜单改动，任何一次查找都会带上它）
    private var options = SearchOptions()

    /// 整个横条是不是收起来了（收起来 = 0 高）
    private(set) var isCollapsed = true
    /// 「替换为」那一行要不要展开（收起时它自然也不显示）
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
        // 收起后高度是 0，里面的内容必须裁掉，否则会从 0 高的横条里漏出来
        clipsToBounds = true
        setupSeparator()
        setupFields()
        setupButtons()
        setupRows()
        refreshOptionsMenu()
        countLabel.text = ""
        setCollapsed(true)
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

    private func configure(_ field: UITextField, placeholder: String) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.borderStyle = .roundedRect
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
        // 钉成和输入框一样高，替换行的高度才是确定的（`expandedHeight` 就是按这个算的）
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

        column.axis = .vertical
        column.spacing = Self.rowSpacing
        column.addArrangedSubview(queryRow)
        column.addArrangedSubview(replaceRow)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        let margin = Self.edgeMargin
        // ⚠️ 只钉上 / 左 / 右三条，**故意不钉下边**：钉了下边，内容的高度就会反过来参与决定横条的高度，跟下面那条 height 约束抢话事权（抢的那版就是收起失效那版）
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: margin),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin)
        ])

        // 全程唯一一条决定高度的约束，收起时把 constant 调成 0 即可
        let height = heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
        heightConstraint = height
    }

    /// 展开时需要多高：上下留白 + 查找行（+ 替换行和行间距）。
    ///
    /// 用算的而不是让约束自己撑 —— 因为高度现在由上面那条约束独裁，算出来的值就是它的 constant，两边永远一致。
    private var expandedHeight: CGFloat {
        var height = Self.edgeMargin * 2 + Self.fieldHeight
        if wantsReplaceRow { height += Self.rowSpacing + Self.fieldHeight }
        return height
    }

    /// 把高度约束的 constant 刷成当前状态该有的值
    ///
    /// ### 为什么改完 constant 还要手动标脏（少了这一步，展开会静默失效）
    /// 改 `constant` **不会**自动把祖先标成「需要重新排版」。上层容器收起 / 展开时做的是 `view.layoutIfNeeded()` —— 它只在「确实有待处理的排版」时才真的算一次，没标脏就直接空转。结果就是：约束的 constant 已经改成 50 了，横条的 frame 还是 0，查找条永远弹不出来（第一次排版之后才按 ⌘F 就一定会踩到）。
    /// 所以这里自己把脏标上：自己 + 外面一层，谁先跑 layoutIfNeeded 都能算到。
    private func refreshHeightConstant() {
        heightConstraint?.constant = isCollapsed ? 0 : expandedHeight
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    /// 按两个开关（收没收起 / 要不要替换行）决定显示什么。
    ///
    /// 只管显示，**不管高度** —— 高度是 `refreshHeightConstant()` 按同一批开关算出来的，两边用的是同一组状态，不会一个说显示、另一个按不显示的高度算。
    private func applyRowVisibility() {
        replaceRow.isHidden = !wantsReplaceRow
        separator.isHidden = isCollapsed
        // 收起时顺手把内容藏掉：高度已经是 0 了，藏着还能省掉一次白跑的排版
        column.isHidden = isCollapsed
    }

    // MARK: 对外动作

    /// 收起 / 展开整个横条（上层容器在做动画之前调它）。
    ///
    /// ### 为什么是「改 constant」而不是「切一组约束」
    /// 切换意味着同一时刻有两组约束存在，得靠 `isActive` 保证只生效一组 —— 一旦哪条漏关，就会有一条 required 的高度约束和内容抢话事权（前面三版都是这么挂的）。
    /// 只留一条、只改 constant，就不存在「谁被丢掉」这个问题。
    func setCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
        refreshHeightConstant()
        applyRowVisibility()
    }

    /// 开始查找：输入框获得焦点，并把已有的内容全选（再打字就是重新起一次查找）。
    ///
    /// 收起 / 展开和动画由上层容器负责，这里只管焦点和选中。
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
    @discardableResult
    func toggleReplaceRow() -> Bool {
        wantsReplaceRow = !wantsReplaceRow
        refreshHeightConstant()
        applyRowVisibility()
        replaceToggleButton.accessibilityLabel = wantsReplaceRow ? "隐藏替换" : "显示替换"
        return showsReplaceRow
    }

    /// 模拟「往查找框里敲了一段字」：内容写进输入框，并按一次「内容变了」。
    ///
    /// 存在的意义是让外面（尤其是测试）能走和真实用户完全一致的那条链：
    /// 输入框 → delegate → 协调者 → 防抖 → 编辑器。
    func typeQuery(_ text: String) {
        queryField.text = text
        queryField.sendActions(for: .editingChanged)
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
