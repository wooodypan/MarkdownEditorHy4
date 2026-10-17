//
//  MarkdownColorEditorViewController.swift
//  MarkdownEditorHy4
//
//  逐色调整：配色表里每一个色摆一行，既能敲十六进制，也能用系统的取色器挑。
//
//  ### 改的是哪一张表
//  改的是**盖在当前内置主题之上**的那张自定义覆盖表（`MarkdownColorPalette`），不是内置主题本身 —— 内置主题（默认 / Vue / Vue Dark）是写死在渲染层里的，用户不该改它们。
//  所以这一页刚进来时一张表是空的：每行显示的是「内置主题算出来的色」，用户动了哪一色，哪一色才写进这张表（其余继续跟着主题走），导出的 JSON 里也就只有动过的那几色。
//
//  ### 这一页跟渲染层怎么相处
//  某一色叫什么、它在配色表里是哪个键、套进 `MarkdownTheme` 之后落在哪个字段，全由渲染层的 `MarkdownPaletteColorKey` 说了算，这一页只负责把它们摆成一行、把用户敲进去的字符串转成一个 `MarkdownHexColor` 存回去 —— 依赖方向仍然是「App 层 → 组件」。
//

import UIKit

/// 逐色调整页。从主题页那一行「逐色调整」推进来（`UINavigationController` 的 push）。
final class MarkdownColorEditorViewController: UIViewController {

    // MARK: 常量

    private static let cellID = "colorCell"

    // MARK: 依赖

    private let settings: MarkdownEditorSettings
    private let store: MarkdownCustomThemeStore

    // MARK: 数据

    /// 用户改过的那些色（一张覆盖表）。一个都没改过时它是空的，每一行显示的是「内置主题算出来的色」
    private var palette: MarkdownColorPalette

    /// 正在用取色器改的那一色。取色器是另一个页面，delegate 只给回一个颜色，得自己记着是谁在改
    private var editingKey: MarkdownPaletteColorKey?

    // MARK: 视图

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    // MARK: 初始化

    init(settings: MarkdownEditorSettings = .shared, store: MarkdownCustomThemeStore = .shared) {
        self.settings = settings
        self.store = store
        // 进来先把当前选中那份读出来；读不出来（还没选过、或者文件坏了）就当「一个色都没改」
        self.palette = store.loadPalette(named: settings.customThemeFileName) ?? MarkdownColorPalette()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable, message: "这个页面只从代码里建，不用 storyboard")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 没实现")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "逐色调整"
        view.backgroundColor = .systemGroupedBackground
        setupTable()
        setupResetButton()
    }

    // MARK: 装配

    private func setupTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyboardDismissMode = .onDrag
        // 有些行下面带一句注意事项，行高交给 Auto Layout 自己量
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.tableHeaderView = makeHeader()
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    /// 表格顶端那句说明：先把「改的是覆盖表」这件事讲清楚，用户才不会奇怪「我改了一个色，怎么只导出一条」
    private func makeHeader() -> UIView {
        let label = UILabel()
        label.text = "改过的色会盖在当前内置主题之上，没改的继续跟着主题走。"
            + "左右滑动某一行可以把那一色还原成主题自带的色。"
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0

        // ⚠️ `tableHeaderView` 不会自己跟着表格变宽，得给它一个宽度；高度按文字量出来
        let width = max(1, view.bounds.width)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 10))
        container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        return container
    }

    private func setupResetButton() {
        let item = UIBarButtonItem(title: "全部还原", style: .plain,
                                   target: self, action: #selector(resetAll))
        item.accessibilityLabel = "全部还原自定义配色"
        navigationItem.rightBarButtonItem = item
        updateResetButton()
    }

    /// 一个色都没改过时「全部还原」没意义，灰掉
    private func updateResetButton() {
        navigationItem.rightBarButtonItem?.isEnabled = !palette.isEmpty
    }

    // MARK: 当前实际会渲染出来的颜色

    /// 内置主题 + 用户改过的那些色，套进 `MarkdownTheme` 之后的样子 —— 每一行「现在是什么色」就是从这儿读的
    private var resolvedTheme: MarkdownTheme {
        var theme = MarkdownTheme.default
        theme.applyColorPalette(settings.resolvedColorPalette(customPalette: palette))
        return theme
    }

    /// 某一区（比如「编辑区」）里有哪些色
    private func keys(inSection section: Int) -> [MarkdownPaletteColorKey] {
        guard let group = MarkdownPaletteColorGroup.allCases[safe: section] else { return [] }
        return MarkdownPaletteColorKey.keys(in: group)
    }

    /// 反查某一色在第几区第几行（改完要刷新那一行时用）
    private func indexPath(of key: MarkdownPaletteColorKey) -> IndexPath? {
        guard let section = MarkdownPaletteColorGroup.allCases.firstIndex(of: key.group),
              let row = MarkdownPaletteColorKey.keys(in: key.group).firstIndex(of: key) else { return nil }
        return IndexPath(row: row, section: section)
    }

    // MARK: 落盘

    /// 把当前这张覆盖表存进 App 自己的目录，并让打开的文档当场重渲染
    private func persist() {
        let nameBefore = settings.customThemeFileName
        let hadCustom = nameBefore != nil
        do {
            if palette.isEmpty {
                // 最后一个自定义色也被还原掉了 = 回到「只用内置主题」，那一份留着就是个空壳，删掉（本来就只删当前这份，其余不受影响）
                if let nameBefore { store.remove(named: nameBefore) }
                settings.setCustomThemeFileName(nil)
            } else {
                // 改的是当前选中的那一份：从外面导入的就沿用它的名字，本机调出来的就用「自定义配色」这个名
                let name = nameBefore ?? MarkdownCustomThemeStore.inAppEditedName
                try store.save(palette: palette, named: name)
                settings.setCustomThemeFileName(name)
            }
        } catch {
            showAlert(message: "配色没能存下来（\(error.localizedDescription)），重开这个页面再试一次。")
        }

        // 文件名没变的话（最常见的情形：只是把链接从绿换成红），上面那个 setter 会直接 return、不会广播，得手动发一次 —— 不发的话正文不知道要重渲染，用户回到文档会看到「改了没生效」。
        // `hadCustom` 那半个条件挡的是「本来就没有自定义配色、也没真改出东西」这种空跑，那种情况下没什么可广播的
        if hadCustom, settings.customThemeFileName == nameBefore {
            settings.noteCustomPaletteChanged()
        }
        updateResetButton()
    }

    // MARK: 改一个色

    /// 把某一色写进覆盖表（`hex` 得先过一遍解析，写坏了的颜色不进表）
    private func set(_ key: MarkdownPaletteColorKey, fromHex text: String) -> Bool {
        guard let color = MarkdownHexColor.parse(text) else { return false }
        // 存之前先规范化成 `#ff8800` 这样的小写 6/8 位写法：用户敲的是 `#FF8800` 还是 `ff8800` 不重要，存下来的样子要一致
        palette[key] = MarkdownHexColor(MarkdownHexColor.string(from: color))
        return true
    }

    /// 用户在格子里敲完十六进制（点回车、或者点到别处）
    private func commitHex(_ text: String, for key: MarkdownPaletteColorKey) {
        guard set(key, fromHex: text) else {
            // 不合法就一个字都不写，顺手把格子还原成现在的色 —— 否则用户看到的还是自己敲进去的那串乱码，以为生效了
            if let path = indexPath(of: key) { tableView.reloadRows(at: [path], with: .none) }
            return
        }
        persist()
        if let path = indexPath(of: key) { tableView.reloadRows(at: [path], with: .none) }
    }

    /// 某一色还原成主题自带的色（从覆盖表里删掉这一项）
    private func restore(_ key: MarkdownPaletteColorKey) {
        palette[key] = nil
        persist()
        if let path = indexPath(of: key) { tableView.reloadRows(at: [path], with: .automatic) }
    }

    /// 全部还原：清空覆盖表，回到只用内置主题
    @objc private func resetAll() {
        let alert = UIAlertController(title: "把所有自定义颜色都还原？",
                                      message: "改过的 \(palette.definedColorCount) 个色会被清掉，回到内置主题自带的颜色。"
                                        + "导出的那份 JSON 不会受影响（它已经存出去了）。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "还原", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.palette = MarkdownColorPalette()
            self.persist()
            self.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    /// 存盘失败要说出来 —— 不然用户以为改好了，下次打开颜色又回去了
    private func showAlert(message: String) {
        let alert = UIAlertController(title: "没能存下这次改动", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - 表格数据

extension MarkdownColorEditorViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        MarkdownPaletteColorGroup.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        keys(inSection: section).count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        MarkdownPaletteColorGroup.allCases[safe: section]?.displayName
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let key = keys(inSection: indexPath.section)[safe: indexPath.row]
            ?? MarkdownPaletteColorKey.text

        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID) as? ColorRowCell
            ?? ColorRowCell(reuseIdentifier: Self.cellID)

        let theme = resolvedTheme
        // 显示的是「现在真正会渲染出来的色」，不是「用户上一次敲进去的字符串」—— 内置主题一换，这一列跟着变才是对的
        let hex = MarkdownHexColor.string(from: theme[keyPath: key.themeColorPath])
        cell.configure(key: key, hex: hex, overridden: palette[key] != nil)
        cell.onHexCommit = { [weak self] editedKey, text in
            self?.commitHex(text, for: editedKey)
        }
        return cell
    }
}

// MARK: - 表格交互

extension MarkdownColorEditorViewController: UITableViewDelegate {

    /// 点一行 = 用系统的取色器改这一色
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let key = keys(inSection: indexPath.section)[safe: indexPath.row] else { return }

        editingKey = key
        let picker = UIColorPickerViewController()
        picker.delegate = self
        picker.title = key.displayName
        // 底色那几色必须能带透明度（行内代码那个底色不透明会盖住系统的选中高亮），所以统一开着
        picker.supportsAlpha = true
        picker.selectedColor = resolvedTheme[keyPath: key.themeColorPath]
        present(picker, animated: true)
    }

    /// 左滑某一行可以「还原」那一色。没改过的色没有可还原的东西，直接不给这个动作
    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        guard let key = keys(inSection: indexPath.section)[safe: indexPath.row],
              palette[key] != nil else { return nil }

        let action = UIContextualAction(style: .normal, title: "还原") { [weak self] _, _, done in
            self?.restore(key)
            done(true)
        }
        action.backgroundColor = .systemGray
        return UISwipeActionsConfiguration(actions: [action])
    }
}

// MARK: - 系统取色器

extension MarkdownColorEditorViewController: UIColorPickerViewControllerDelegate {

    /// 取色器里**拖动**的时候会一直回调：这一步只改内存里那张表、只刷这一行，不写文件、也不通知正文重渲染 —— 每拖一个像素就整篇重渲染一次，手指底下会一顿一顿的
    func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
        guard let key = editingKey else { return }
        let picked = viewController.selectedColor

        // ⚠️ 取色器一打开就可能回调一次「当前这个色」。不比对就照单全收的话，用户只是点进来看一眼、划走，这一色也被记成「已改」—— 导出的 JSON 里凭空多出一行，主题还在的话看不出来，换个主题就露馅了
        let current = resolvedTheme[keyPath: key.themeColorPath]
        guard MarkdownHexColor.string(from: picked) != MarkdownHexColor.string(from: current) else { return }

        palette[key] = MarkdownHexColor(color: picked)
        if let path = indexPath(of: key) { tableView.reloadRows(at: [path], with: .none) }
    }

    /// 取色器关掉（不管是点了完成还是划走）：这时候才落盘 + 让正文重渲染
    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        editingKey = nil
        persist()
        tableView.reloadData()
    }
}

// MARK: - 小工具

private extension Array {

    /// 按下标取值，越界返回 `nil` 而不是崩。
    ///
    /// 表格的 `indexPath` 是外面传进来的，越界一次就把整个 App 掀了不值得 —— 拿不到就当这一行不存在。
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 一行一个色

/// 逐色调整里的一行：左边名字 + 一句注意事项，右边一枚色块 + 一个能敲十六进制的格子。
///
/// ### 为什么色块和格子都塞进 `accessoryView`
/// 这一行已经没有「对勾」这种系统附件了（选中状态是靠格子里那个字符串表达的），而 `accessoryView` 和 `accessoryType` 抢的是同一个位置，索性全用自定义 view。
private final class ColorRowCell: UITableViewCell {

    /// 右边那枚色块
    private let chip = UIView()
    /// 右边那个能敲十六进制的格子
    private let field = UITextField()
    /// 这一行管的是哪个色（复用的时候会被换掉，所以得跟着更新）
    private var key: MarkdownPaletteColorKey?

    /// 用户敲完一段十六进制之后（回车 / 点到别处）回调，参数是「哪个色」和「敲进去的字符串」
    var onHexCommit: ((MarkdownPaletteColorKey, String) -> Void)?

    private static let chipSize = CGSize(width: 26, height: 20)
    private static let fieldWidth: CGFloat = 104
    /// 色块 + 间距 + 格子，这一整块的宽度（`accessoryView` 的宽度就是 UIKit 拿 `frame` 算的，得给死）
    private static let accessorySize = CGSize(width: chipSize.width + 8 + fieldWidth, height: 30)

    init(reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        setupAccessory()
    }

    @available(*, unavailable, message: "这个 cell 只从代码里建")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 没实现")
    }

    private func setupAccessory() {
        chip.layer.cornerRadius = 4
        chip.layer.borderWidth = 0.5
        // 描一道边：白色那种「接近没有」的色块压在白 cell 上会看不见轮廓
        chip.layer.borderColor = UIColor.separator.cgColor

        field.borderStyle = .roundedRect
        field.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        field.textAlignment = .center
        field.placeholder = "#42b983"
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .done
        field.clearButtonMode = .whileEditing
        field.delegate = self
        field.addTarget(self, action: #selector(fieldDidEndEditing), for: .editingDidEnd)

        // ⚠️ 必须是「自报尺寸」的容器：`accessoryView` 的宽度是 UIKit 按 `intrinsicContentSize` 问出来的，普通 `UIView` 一律答「不知道」→ 被压成零宽 → 色块和输入框在屏幕上根本看不见（见 `FixedSizeAccessoryView`）
        let container = FixedSizeAccessoryView(size: Self.accessorySize)
        let line = UIStackView(arrangedSubviews: [chip, field])
        line.axis = .horizontal
        line.spacing = 8
        line.alignment = .center
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)

        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: container.topAnchor),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            chip.widthAnchor.constraint(equalToConstant: Self.chipSize.width),
            chip.heightAnchor.constraint(equalToConstant: Self.chipSize.height),
            field.widthAnchor.constraint(equalToConstant: Self.fieldWidth)
        ])
        accessoryView = container
    }

    /// 填这一行的内容
    func configure(key: MarkdownPaletteColorKey, hex: String, overridden: Bool) {
        self.key = key

        var content = UIListContentConfiguration.subtitleCell()
        content.text = key.displayName
        content.secondaryText = key.note
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        contentConfiguration = content

        field.text = hex
        // 单测和旁人都靠这两个读「这一行是什么色、有没有改过」：可见标题就是颜色的名字
        accessibilityLabel = key.displayName
        accessibilityValue = overridden ? "已改 \(hex)" : "沿用主题 \(hex)"
        field.accessibilityLabel = "\(key.displayName) 十六进制值"
        chip.backgroundColor = MarkdownHexColor.parse(hex)
    }

    @objc private func fieldDidEndEditing() {
        guard let key, let text = field.text else { return }
        onHexCommit?(key, text)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // 复用的时候旧回调必须断掉：不然刷完这一行，用户敲回车会把结果算到上一次那个色头上
        key = nil
        onHexCommit = nil
    }
}

extension ColorRowCell: UITextFieldDelegate {

    /// 点回车 = 敲完了，收起键盘（`editingDidEnd` 会跟着触发，接着走 `commitHex`）
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.endEditing(true)
        return false
    }

    /// 只放行十六进制里可能出现的字符（`#`、0~9、a~f），连长度一起卡住（`#` + 8 位）。
    ///
    /// 不卡的话用户能敲进去一整句话，点完回车才发现「没生效」—— 那是最难查的一类界面反馈。
    func textField(_ textField: UITextField,
                   shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool {
        // 删除键传进来的是空串，一律放行
        if string.isEmpty { return true }
        let allowed = CharacterSet(charactersIn: "#0123456789abcdefABCDEF")
        guard string.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }

        let current = (textField.text ?? "") as NSString
        let result = current.replacingCharacters(in: range, with: string)
        return result.count <= 9
    }
}
