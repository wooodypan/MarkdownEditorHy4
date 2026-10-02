//
//  MarkdownThemeViewController.swift
//  MarkdownEditorHy4
//
//  主题页：挑一套配色，再决定要不要拿一份自己的 JSON 盖在上面。
//
//  ### 为什么单开一页，不塞进设置页
//  主题往后不止三套，而设置页那套「一个分组 + 一个分段控件」的写法，选项一多就挤成了「…」。
//  换成列表以后加多少套都是加一行；入口放在文档的「更多」菜单里、跟「设置」平级 —— 主题是「这篇东西现在披哪张皮」，跟「记不记住阅读位置」那种长期偏好不是一类东西。
//
//  ### 这一页跟渲染层怎么相处
//  颜色、内置预设、JSON 解码全在 `MarkdownEditor/Rendering/MarkdownColorPalette.swift`，这一页只管三件事：把 `MarkdownColorTheme.allCases` 列出来、把用户的选择写进 settings、用选中的颜色画预览。
//  某个色到底是多少，这一页一个字都不知道 —— 依赖方向始终是「App 层 → 组件」。
//

import UIKit
import UniformTypeIdentifiers

/// 主题页。从文档的「更多」菜单进来，改完当场生效（内容的监听见 `applyEditorStyle`）。
final class MarkdownThemeViewController: UIViewController {

    // MARK: 分区

    private enum Section: Int, CaseIterable {
        /// 内置主题：一套一行，以后加多少套都是加一行
        case builtIn
        /// 用户自己的那几份（导入进来的 + 本机调出来的），一份一行：点一下就换过去，左滑删掉
        case customThemes
        /// 逐个颜色自己调（推进 `MarkdownColorEditorViewController`）
        case colorEditor
        /// 导入 / 导出别人的主题 JSON
        case customFile

        /// 分区标题
        var header: String? {
            switch self {
            case .builtIn: return "内置主题"
            case .customThemes: return "我的主题"
            case .colorEditor: return "自己调色"
            case .customFile: return "主题 JSON 文件"
            }
        }

        /// 分区底部的说明。
        ///
        /// ⚠️ 「内置主题」那一句要跟着「现在是不是在用自定义配色」变（两套互斥，得说清点一下会发生什么），所以它带一个参数，而不是写死在枚举上。
        func footer(customThemeName: String?) -> String? {
            switch self {
            case .builtIn:
                guard let customThemeName else {
                    return "换配色只换颜色，你在设置页调过的字号、行高、间距一个都不会动。"
                        + "内置主题和「我的主题」只能选一个：选了下面那份，上面这套的对勾就摘掉。"
                }
                return "现在用的是「我的主题」里的「\(customThemeName)」，上面几套都不带对勾。"
                    + "点任意一套就切到它、并停用那份自定义配色（那几份还留着，要删去「我的主题」里左滑）。"
            case .customThemes:
                return "每份各存一行，导入只增不覆盖：点一下就换过去，左滑可以删掉。"
                    + "它们都盖在上面选的那套内置主题之上，只写想改的几色就行。"
            case .colorEditor:
                return "改过的色盖在上面选的那套主题之上，没改的继续跟着主题走。"
            case .customFile:
                return "导入就是挑一份别人的 JSON 存成新的一行；导出会把你改过的那几色存成一份 JSON。"
                    + "文件里只写想改的几色就行，其余照旧，比如 {\"link\": \"#ff0000\"}。"
            }
        }
    }

    /// 「主题 JSON 文件」那一区的两行
    private enum FileRow: Int, CaseIterable {
        /// 从「文件」里挑一份别人的主题 JSON 进来
        case importFile
        /// 把自己改过的那几色存成一份 JSON 送出去
        case exportFile
    }

    // MARK: 常量

    /// 内置主题那几行复用 cell 用的标识
    private static let themeCellID = "themeCell"
    /// 「我的主题」那几行复用 cell 用的标识
    private static let customThemeCellID = "customThemeCell"
    /// 「逐色调整」那一行的标识
    private static let editorCellID = "editorCell"
    /// 「主题 JSON 文件」那一行的标识
    private static let fileCellID = "fileCell"
    /// 导出来的那份 JSON 叫什么（用户存的时候还能改名字，这只是默认那个）
    private static let exportFileName = "markdown-theme.json"
    /// 预览区（表格顶端那一块）的高度
    private static let previewHeight: CGFloat = 190

    /// 预览区里那段 markdown：挑几样颜色最直观的语法摆在一起，够看清一套配色的脾气。
    ///
    /// 刻意不放代码块 —— 那片圆角灰底要在布局之后才画出来，放进来有可能先白后灰地闪一下。
    private static let previewMarkdown = """
    # 一级标题
    正文里夹一段 `inline code`，还有一个[链接](https://example.com)。

    > 引用这一句的样子

    - 列表第一项
    - 列表第二项
    """

    // MARK: 依赖

    private let settings: MarkdownEditorSettings
    private let store: MarkdownCustomThemeStore

    // MARK: 视图

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    /// 预览用的编辑器：和正文是同一个控件，只是不许输入
    private lazy var preview = MarkdownTextView(markdown: Self.previewMarkdown)
    /// 预览区的容器，挂在 `tableHeaderView` 上，跟着表格一起滚
    private let previewContainer = UIView()

    // MARK: 状态

    /// 当前弹出的文件选择器是不是「导出主题」用途（导入和导出用的是同一个 delegate，靠它区分）
    private var isExportingTheme = false
    /// Finder 那条路的监听器（`MarkdownThemeOpener` 发的通知）。页面要活着才收得到，所以存着好移除
    private var observer: NSObjectProtocol?

    // MARK: 初始化

    init(settings: MarkdownEditorSettings = .shared, store: MarkdownCustomThemeStore = .shared) {
        self.settings = settings
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable, message: "这个页面只从代码里建，不用 storyboard")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 没实现")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "主题"
        // 「完成」挂导航栏上：外面是以 `UINavigationController` 形式弹出来的，见 `showThemePicker`
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                            target: self,
                                                            action: #selector(done))
        view.backgroundColor = .systemGroupedBackground
        setupPreview()
        setupTableView()
        refreshPreview()
        // Finder 送进来的主题文件（双击 /「打开方式」/ 拖到 Dock 图标）由这里接住
        observeThemeFileArrivals()
        // 另一种更直接的用法：把 .json 从 Finder 拖到这一页上
        setupDropTarget()
    }

    /// 从 Finder 进来的那一份，等这一页真的露出来再导入 —— 在 `viewDidLoad` 里弹提示会被系统丢掉，那时这一页还没挂到窗口上（`present` 找不到锚点）。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        importPendingThemeFile()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// 表格变宽变窄（转屏、拉窗口）时预览区也要跟着改宽度：`tableHeaderView` 不会自己适应
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = tableView.bounds.width
        if abs(previewContainer.frame.width - width) > 0.5 {
            previewContainer.frame.size.width = width
            // 改完 frame 要重新赋一次，`UITableView` 才会按新宽度再排一遍
            tableView.tableHeaderView = previewContainer
        }
    }

    @objc private func done() {
        dismiss(animated: true)
    }

    // MARK: 装配

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        // 说明文字有多行，行高交给 Auto Layout 自己量
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupPreview() {
        // 预览只许看不许动：能选中的话用户一拖就会触发 textkit 那套选中逻辑，纯属添乱
        preview.isEditable = false
        preview.isSelectable = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(preview)

        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 8),
            preview.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 12),
            preview.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -12),
            preview.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -8)
        ])

        previewContainer.frame = CGRect(x: 0, y: 0,
                                        width: max(1, view.bounds.width),
                                        height: Self.previewHeight)
        tableView.tableHeaderView = previewContainer
    }

    // MARK: 当前用到的颜色

    /// 当前选中的那份自定义配色。没选 / 读不出来就是 `nil`（= 只用内置主题的颜色）
    private var currentCustomPalette: MarkdownColorPalette? {
        // 「文件名记着」就算指定了：文件万一读不出来，`loadPalette` 返回 nil，走的和「没指定」是同一条退化路 —— 一份坏 JSON 不该把界面搞成一片黑
        store.loadPalette(named: settings.customThemeFileName)
    }

    /// 「我的主题」那几行的名字（导入进来的 + 本机调出来的，各存一份）
    private var customThemeNames: [String] {
        store.allNames()
    }

    /// 当前是不是在用「我的主题」里的某一份（在用 → 内置主题那几行都不带对勾，两套互斥）
    private var isUsingCustomTheme: Bool {
        settings.customThemeFileName != nil
    }

    /// 某一套内置主题**自己**的颜色（**不**叠自定义配色），落到 theme 上之后的样子。
    ///
    /// ⚠️ 列表里这几行必须画出各自的样子：叠上当前那份自定义配色的话，一份写满了的 JSON 会把几行色卡盖得一模一样，用户点哪套看到的都不变 —— 表现出来就是「三个内置主题全都点不动」。
    private func builtInTheme(_ item: MarkdownColorTheme) -> MarkdownTheme {
        var theme = MarkdownTheme.default
        theme.applyColorPalette(settings.palette(base: item, merging: nil))
        return theme
    }

    /// 「我的主题」里某一行长什么样：当前内置主题 + **那份**配色叠出来的样子。
    ///
    /// 每行画的是它自己那份的颜色，所以这里要按这一行的名字去读，不能用「当前选中的那份」。
    private func customTheme(named name: String) -> MarkdownTheme {
        var theme = MarkdownTheme.default
        theme.applyColorPalette(settings.palette(base: settings.colorTheme,
                                                 merging: store.loadPalette(named: name)))
        return theme
    }
}

// MARK: - 表格数据

extension MarkdownThemeViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .builtIn: return MarkdownColorTheme.allCases.count
        case .customThemes: return customThemeNames.count
        case .colorEditor: return 1
        case .customFile: return FileRow.allCases.count
        case nil: return 0
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)?.header
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        Section(rawValue: section)?.footer(customThemeName: settings.customThemeFileName)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .builtIn: return makeThemeCell(item: MarkdownColorTheme.allCases[indexPath.row])
        case .customThemes: return makeCustomThemeCell(named: customThemeNames[indexPath.row])
        case .colorEditor: return makeEditorCell()
        case .customFile:
            switch FileRow(rawValue: indexPath.row) {
            case .importFile: return makeFileCell()
            case .exportFile: return makeExportCell()
            case nil: return UITableViewCell()
            }
        case nil: return UITableViewCell()
        }
    }

    /// 一套内置主题一行：名字 + 说明 + 右边一枚色卡。
    ///
    /// ### 为什么用 `allCases` 的下标而不是自己存一份数组
    /// 以后往 `MarkdownColorTheme` 里加一个 case，这里不用改一行：列表自动多一行、名字自动带上。
    private func makeThemeCell(item: MarkdownColorTheme) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.themeCellID)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: Self.themeCellID)

        var content = UIListContentConfiguration.subtitleCell()
        content.text = item.displayName
        content.secondaryText = description(of: item)
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content

        // 互斥：用着「我的主题」里那份的时候，内置主题一行都不勾 —— 对勾只说明「现在实际在用哪一套」
        let selected = !isUsingCustomTheme && item == settings.colorTheme
        let theme = builtInTheme(item)
        let swatch = ThemeSwatch(background: theme.editorBackground,
                                 text: theme.textColor,
                                 accent: theme.linkColor)
        cell.accessoryView = ThemeSwatchView(swatch: swatch, selected: selected)
        // 可见标题就是主题名，已经够唯一（这正是按名字找控件的那条规矩的好处），选中与否另放进 `accessibilityValue` —— 单测靠它断言，旁人也一眼看懂当前选的是哪套
        cell.accessibilityLabel = item.displayName
        cell.accessibilityValue = selected ? "已选中" : "未选中"
        return cell
    }

    /// 每套主题的一句话说明：写清「颜色打哪儿来的」，以后加主题照着补一句就行
    private func description(of item: MarkdownColorTheme) -> String {
        switch item {
        case .default:
            return "编辑器自带的颜色：跟着系统的浅色 / 深色外观走。"
        case .vue:
            return "Vue 绿配深蓝灰的浅色风格，取自仓库根目录的 vue.css。"
        case .vueDark:
            return "同一套风格的深色版，取自 vue-dark.css。"
        }
    }

    /// 「我的主题」里一份一行：名字 + 改了几个色 + 右边一枚色卡（选中时带对勾）。
    ///
    /// 和内置主题那一行是同一套画法，只是颜色要按**这一份**算 —— 用户攒了好几份，每行得画出自己的样子才挑得动。
    private func makeCustomThemeCell(named name: String) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.customThemeCellID)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: Self.customThemeCellID)

        let palette = store.loadPalette(named: name)
        let count = palette?.definedColorCount ?? 0

        var content = UIListContentConfiguration.subtitleCell()
        content.text = name
        content.secondaryText = count > 0
            ? "改了 \(count) 个色，盖在「\(settings.colorTheme.displayName)」之上"
            : "这份没读出颜色"
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content

        let selected = name == settings.customThemeFileName
        let theme = customTheme(named: name)
        let swatch = ThemeSwatch(background: theme.editorBackground,
                                 text: theme.textColor,
                                 accent: theme.linkColor)
        cell.accessoryView = ThemeSwatchView(swatch: swatch, selected: selected)
        cell.accessibilityLabel = name
        cell.accessibilityValue = selected ? "已选中" : "未选中"
        return cell
    }

    /// 「逐色调整」一行：点进去逐个颜色改，副标题写清已经改了几个色
    private func makeEditorCell() -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.editorCellID)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: Self.editorCellID)

        var content = UIListContentConfiguration.subtitleCell()
        content.text = "逐色调整"
        content.secondaryText = editorDescription
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityLabel = "逐色调整"
        return cell
    }

    /// 「导入」一行：左边写当前用的哪份，右边「导入 / 清除」两个按钮
    private func makeFileCell() -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.fileCellID)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: Self.fileCellID)

        var content = UIListContentConfiguration.subtitleCell()
        content.text = "导入主题文件"
        content.secondaryText = fileDescription
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        // ⚠️ 别设 `.none`：这一行现在整行都能点（见 `performFileRowAction`），设了 `.none` 点了也不高亮，用户会以为没反应 —— 「点了没反应」最难查，因为代码其实跑过了
        cell.selectionStyle = .default
        cell.accessoryView = makeFileButtons()
        cell.accessibilityLabel = "导入主题 JSON 文件"
        return cell
    }

    /// 「导出」一行：把改过的那几色存成一份 JSON 送出去
    private func makeExportCell() -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.fileCellID + "-export")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: Self.fileCellID + "-export")

        var content = UIListContentConfiguration.subtitleCell()
        content.text = "导出为 JSON 文件"
        content.secondaryText = exportDescription
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryView = makeExportButton()
        cell.accessibilityLabel = "导出主题 JSON 文件"
        return cell
    }

    /// 右边那两个按钮：「导入」新增一份，「取消使用」只是不用自定义配色了（那几份还留着，要删去「我的主题」里左滑）。
    /// 「取消使用」在没选任何一份的时候置灰 —— 点了也白点，不如干脆不让点
    private func makeFileButtons() -> UIView {
        let choose = UIButton(type: .system)
        choose.setTitle("导入", for: .normal)
        choose.addTarget(self, action: #selector(chooseFile), for: .touchUpInside)
        choose.accessibilityLabel = "选择主题 JSON 文件"

        let clear = UIButton(type: .system)
        clear.setTitle("取消使用", for: .normal)
        clear.addTarget(self, action: #selector(clearFile), for: .touchUpInside)
        clear.accessibilityLabel = "取消使用自定义主题"
        clear.isEnabled = settings.customThemeFileName != nil

        return FileActionView(buttons: [choose, clear])
    }

    /// 「导出」那一个按钮。一个色都没改过时没什么可导的，置灰
    private func makeExportButton() -> UIView {
        let export = UIButton(type: .system)
        export.setTitle("导出", for: .normal)
        export.addTarget(self, action: #selector(exportFile), for: .touchUpInside)
        export.accessibilityLabel = "导出主题 JSON 文件"
        export.isEnabled = exportablePalette != nil
        return export
    }

    /// 「逐色调整」那一行下面要说的话：说清改了几个、改了之后盖在哪
    private var editorDescription: String {
        let count = currentCustomPalette?.definedColorCount ?? 0
        guard count > 0 else {
            return "一个色都还没改。点进来可以敲十六进制，也能用系统的取色器挑。"
        }
        return "已经改了 \(count) 个色，盖在上面选的那套主题之上；没改的继续跟着主题走。"
    }

    /// 「没指定」和「指定了」这两种情况下要说的话
    private var fileDescription: String {
        guard let name = settings.customThemeFileName else {
            return "上面「我的主题」里还没有在用哪一份。想用别人的配色就挑一份 JSON 文件："
                + "导入只增不覆盖，每份各存一行。"
        }
        return "当前用的是「\(name)」。它盖在上面选的那套主题之上："
            + "文件里写了哪一色就用哪一色，没写的继续用主题的色。"
    }

    /// 「导出」那行下面要说的话
    private var exportDescription: String {
        guard let palette = exportablePalette else {
            return "一个色都还没改，导出来是一份空的 JSON。先去「逐色调整」改几个色，或者导入一份再来导。"
        }
        return "把改过的 \(palette.definedColorCount) 个色存成一份 JSON（\(Self.exportFileName)），可以发给别人用。"
    }

    /// 值得导出去的那张表：有内容才导，一个色都没有的话导出去是个空壳，不如干脆不让点
    private var exportablePalette: MarkdownColorPalette? {
        guard let palette = currentCustomPalette, !palette.isEmpty else { return nil }
        return palette
    }
}

// MARK: - 表格交互

extension MarkdownThemeViewController: UITableViewDelegate {

    /// 从「逐色调整」回来的时候要重画：那页可能改了好几个色，这一页的预览和副标题都得跟上
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadAll()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch Section(rawValue: indexPath.section) {
        case .builtIn:
            selectBuiltIn(MarkdownColorTheme.allCases[indexPath.row])
        case .customThemes:
            selectCustomTheme(customThemeNames[indexPath.row])
        case .colorEditor:
            showColorEditor()
        case .customFile:
            // 两行都让「点整行」等同于点右边那个按钮：按钮就两个字宽，鼠标 / 手指常常落在标题上
            if let row = FileRow(rawValue: indexPath.row) { performFileRowAction(row) }
        case nil:
            break
        }
    }

    /// 选一套内置主题：**同时**停用「我的主题」里那份自定义配色 —— 两套互斥，同一时刻只能选一个。
    ///
    /// ⚠️ 别写成「点的已经是当前这套就直接 return」：内置主题没变、但正用着自定义配色时，那种写法会直接返回，用户就永远切不回内置主题 —— 表现出来就是「三个内置主题全都点不动」。
    private func selectBuiltIn(_ item: MarkdownColorTheme) {
        // 同值 + 没在用自定义配色时，settings 自己会挡掉，不用在外面再判一次
        settings.selectBuiltInTheme(item)
        reloadAll()
    }

    /// 选「我的主题」里的一份：只是把覆盖层换成这一份，内置主题那套继续当底色
    private func selectCustomTheme(_ name: String) {
        // 点到已经是当前那份就不用再写一遍，省掉一次整篇重渲染
        guard name != settings.customThemeFileName else { return }
        settings.setCustomThemeFileName(name)
        reloadAll()
    }

    /// 「我的主题」里左滑就是删掉那一份（删的是存的那份配色，不影响内置主题）
    func tableView(_ tableView: UITableView,
                   commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        guard Section(rawValue: indexPath.section) == .customThemes,
              editingStyle == .delete else { return }

        let name = customThemeNames[indexPath.row]
        store.remove(named: name)
        // 删掉的正好是当前在用的那份 → 退回「只用内置主题」，否则界面上还挂着个已经不存在的名字
        if name == settings.customThemeFileName {
            settings.setCustomThemeFileName(nil)
        }
        reloadAll()
    }

    /// 列表和预览一起刷：行尾那个对勾要挪到新选的那套上，预览也要换成新的颜色
    private func reloadAll() {
        tableView.reloadData()
        refreshPreview()
    }

    /// 把当前配色 + 用户调过的排版套到预览上、整篇重排一遍。
    ///
    /// ⚠️ 换颜色**必须整篇重渲染**：颜色是在渲染那一刻烙进 `NSAttributedString` 的，只改主题画面纹丝不动。
    private func refreshPreview() {
        settings.applyColors(to: &preview.renderer.theme, customPalette: currentCustomPalette)
        settings.applyTypography(to: &preview.renderer.theme)
        // 预览区才多宽，别再按「行宽上限」给它留一圈白 —— 那一项是给正文排版的
        preview.maxContentWidth = nil
        preview.setMarkdown(Self.previewMarkdown)
        preview.refreshTheme()
    }
}

// MARK: - 逐色调整

extension MarkdownThemeViewController {

    /// 推进「逐色调整」那一页。它改的是同一份自定义 JSON，改完 pop 回来由 `viewWillAppear` 重画这一页
    private func showColorEditor() {
        let editor = MarkdownColorEditorViewController(settings: settings, store: store)
        navigationController?.pushViewController(editor, animated: true)
    }
}

// MARK: - 导入主题 JSON 文件

extension MarkdownThemeViewController: UIDocumentPickerDelegate {

    /// 点「主题 JSON 文件」那一区的某一行该做什么。
    ///
    /// 抽成一个方法（而不是在 `didSelectRowAt` 里写 `if row == .exportFile` 那种）是为了**两行一视同仁**：
    /// 漏掉一行的后果是「点了没反应」，而这一区每一行都挂着按钮，看着像能点，用户根本不会想到要去戳那个小字。
    private func performFileRowAction(_ row: FileRow) {
        switch row {
        case .importFile: chooseFile()
        case .exportFile: exportFile()
        }
    }

    /// 挑一份别人的主题 JSON。
    ///
    /// Mac 上这个面板呈现出来就是原生的「选取文件」对话框（选文件夹 + 改文件名），也就是用户说的「在 Finder 里挑」—— Catalyst 里 `NSOpenPanel` / `NSSavePanel` 被标成 unavailable，这一块是唯一能用的等效物（`MarkdownDocumentViewController.saveImageToFolder` 导出图片也是走它）。
    ///
    /// ⚠️ `asCopy: true`：我们要的是**拷进来一份副本**，不是原地打开 —— 主题文件只是配色，没必要（也不该）让 App 反过来去写用户那份原文件。
    @objc private func chooseFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    /// 不用自定义配色了，回到「只用内置主题」的状态。
    ///
    /// ⚠️ 只**取消选用**，不删文件：那几份是用户一份份攒下来的，取消使用不该把它们弄丢 —— 要删去「我的主题」里左滑那一行。
    @objc private func clearFile() {
        settings.setCustomThemeFileName(nil)
        reloadAll()
    }

    /// 把一份主题文件（不管是面板挑的、还是从 Finder 送进来的）存成新的一份、并切过去用它
    private func importThemeFile(at url: URL) {
        do {
            let palette = try MarkdownThemeFileImport.palette(from: url)
            let name = try adopt(palette, named: url.lastPathComponent)
            showImportedAlert(fileName: name, colorCount: palette.definedColorCount)
        } catch {
            showFileAlert(message: error.localizedDescription)
        }
    }

    /// 存进 App 自己的目录、切过去用它、刷新界面，返回**最终存下来的那个名字**（可能为了不撞车加了「 2」）。
    ///
    /// ### 为什么是「加一份」而不是「覆盖现有那份」
    /// 导入是「多一套配色」，不是「把现在这套改掉」。用户手里往往攒着好几份别人发的 JSON，覆盖掉的话上一份就凭空没了 —— 那正是「选了文件之后现有的颜色被冲掉」那种体验。
    ///
    /// ### 为什么是「拷进来」而不是记一个路径
    /// 挑到的文件在别人的沙盒里，App 只有这一次有权读它，下次启动按路径去读会被系统拒掉。
    /// 所以当场把内容存进 `MarkdownCustomThemeStore`，路径永远是自己的。
    @discardableResult
    private func adopt(_ palette: MarkdownColorPalette, named fileName: String) throws -> String {
        let name = store.uniquedName(fileName)
        try store.save(palette: palette, named: name)
        settings.setCustomThemeFileName(name)
        reloadAll()
        return name
    }

    /// 用户在面板里挑了一份 JSON（导入的**目的地**不在这儿，那是 `exportFile` 那条路）
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        if isExportingTheme {
            // 导出：系统已经把那份 JSON 的副本写到用户选的位置了，提示一句就完事
            isExportingTheme = false
            let folder = url.deletingLastPathComponent().path
            showNotice(title: "主题已导出", message: "存到了 \(folder)")
            return
        }
        importThemeFile(at: url)
    }

    /// 用户点了取消：什么都不改，顺手把导出标记清掉
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        isExportingTheme = false
    }
}

// MARK: - 导出主题 JSON 文件

extension MarkdownThemeViewController {

    /// 把自己改过的那几色存成一份 JSON 送出去。
    ///
    /// 写法照 `MarkdownDocumentViewController.saveImageToFolder`（导出长图那一条）：
    /// 系统这块面板只认「一个真实存在的文件」，所以先按当前内容写一份到临时目录，再由面板把**副本**复制到用户选的位置 —— Mac 上用户看到的就是原生存储对话框。
    ///
    /// ### 文件名带上当前主题名
    /// 同一个 App 里能导出好几份（Vue 上调的、默认上调的），用 `markdown-theme-vue.json`
    /// 这种名字，用户发出去的时候对方一眼就知道这是配哪套主题的。
    @objc private func exportFile() {
        guard let palette = exportablePalette else {
            showFileAlert(message: "一个色都还没改，没什么可导的。先去「逐色调整」改几个色，或者先导入一份。")
            return
        }

        let data: Data
        do {
            data = try palette.jsonData()
        } catch {
            showFileAlert(message: "生成 JSON 的时候失败了（\(error.localizedDescription)），重开这个页面再试一次。")
            return
        }

        let suggestedName = "markdown-theme-\(settings.colorTheme.rawValue).json"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName)
        do {
            try data.write(to: tempURL, options: .atomic)
        } catch {
            showFileAlert(message: "没能写出这份 JSON（\(error.localizedDescription)），换到「文件」里再存一次试试。")
            return
        }

        // 面板回调里要靠这个标记区分「导出」和「导入挑文件」（见 delegate）
        isExportingTheme = true
        // `asCopy: true` = 让系统拷走这份文件（而不是把临时目录那份搬走），下次导出还能再写一遍
        let picker = UIDocumentPickerViewController(forExporting: [tempURL], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }
}

// MARK: - 从 Finder 送进来的主题文件

extension MarkdownThemeViewController {

    /// 盯住 Finder 那条路：双击 /「打开方式」/ 拖到 Dock 图标进来的 .json 会先落到 `MarkdownThemeOpener`，由 `WorkspaceCoordinator` 把这一页弹出来，再由这里接住并导入
    private func observeThemeFileArrivals() {
        observer = NotificationCenter.default.addObserver(
            forName: .markdownThemeFileReceived,
            object: nil,
            queue: .main) { [weak self] _ in
                self?.importPendingThemeFile()
            }
    }

    /// 取走攒着的那一份（冷启动时界面还没起来，`MarkdownThemeOpener` 先替我们收着）并导入
    private func importPendingThemeFile() {
        guard let arrival = MarkdownThemeOpener.shared.takePending() else { return }
        applyImportResult(fileName: arrival.fileName, result: arrival.result)
    }

    /// 把「读出来的结果」落到界面上：成了就套上 + 说一句，败了就说清楚为什么
    private func applyImportResult(fileName: String, result: Result<MarkdownColorPalette, Error>) {
        switch result {
        case .success(let palette):
            do {
                try adopt(palette, named: fileName)
                showImportedAlert(fileName: fileName, colorCount: palette.definedColorCount)
            } catch {
                showFileAlert(message: "拷进 App 目录时失败了（\(error.localizedDescription)），换一份文件试试。")
            }
        case .failure(let error):
            showFileAlert(message: "「\(fileName)」没能导入。\(error.localizedDescription)")
        }
    }

    private func showImportedAlert(fileName: String, colorCount: Int) {
        showNotice(title: "已导入主题",
                   message: "「\(fileName)」里的 \(colorCount) 个色已经盖在当前主题之上，没写到的继续跟着主题走。")
    }

    /// 「选了文件却没反应」是最难查的一类问题，所以失败一定要说出来
    private func showFileAlert(message: String) {
        let alert = UIAlertController(title: "没能用上这份主题文件",
                                      message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    private func showNotice(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - 从 Finder 拖到这一页上

extension MarkdownThemeViewController: UIDropInteractionDelegate {

    /// 装一个「接住拖进来的东西」的手势：Mac 上从 Finder 拖一份 .json 到窗口里就能导入，iPad 上同理
    private func setupDropTarget() {
        view.addInteraction(UIDropInteraction(delegate: self))
    }

    /// 只认一份 .json：拖文字、拖图片、一次拖一堆都不接 —— 接了也说不清用户想干什么
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        session.items.count == 1 && session.hasItemsConforming(toTypeIdentifiers: [UTType.json.identifier])
    }

    /// 复制语义：主题文件是**拷一份**进来，不动用户磁盘上那份原文件
    func dropInteraction(_ interaction: UIDropInteraction,
                         sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        guard let provider = session.items.first?.itemProvider else { return }
        // ⚠️ 系统给的是临时目录里的一份副本，**只在这个回调里有效**（回调一返回就可能被清掉）。
        // 所以在这里当场读完，再把结果（不是 URL）带回主线程 —— 拿着 URL 跑主线程再去读，读到的可能是空气
        provider.loadFileRepresentation(forTypeIdentifier: UTType.json.identifier) { [weak self] url, _ in
            guard let url else { return }
            let fileName = url.lastPathComponent
            let result = Result { try MarkdownThemeFileImport.palette(from: url) }
            DispatchQueue.main.async { self?.applyImportResult(fileName: fileName, result: result) }
        }
    }
}

// MARK: - 一行右边的色卡

/// 一行预览要用的三个颜色：底色、正文色、强调色（链接那条主色）。
///
/// 挑三个就够：行里真正让人「一眼认出这套主题」的就是这三者。
private struct ThemeSwatch {
    var background: UIColor
    var text: UIColor
    var accent: UIColor
}

/// 主题行右边那枚色卡：三个小方块 + 选中时的对勾。
///
/// ### 为什么不用系统的 `.checkmark` 附件
/// `accessoryView` 和 `accessoryType` 抢的是同一个位置：挂了自定义 view 之后 `accessoryType` 就不生效了。
/// 所以「画出这套的颜色」和「标出当前选中」这两件事只能合成一个 view。
private final class ThemeSwatchView: FixedSizeAccessoryView {

    private let blocks = [UIView(), UIView(), UIView()]
    private let check = UIImageView(image: UIImage(systemName: "checkmark"))

    /// 一个方块的边长
    private static let side: CGFloat = 16
    /// 整枚色卡的尺寸：三个方块 + 两个间距 + 一个对勾。
    ///
    /// `accessoryView` 的宽度是 UIKit 按 `intrinsicContentSize` 问出来的（见 `FixedSizeAccessoryView`），不报尺寸的话这一列色卡会东一块西一块地对不齐右边的边。
    private static let size = CGSize(width: side * 3 + 4 * 3 + 18, height: side + 4)

    init(swatch: ThemeSwatch, selected: Bool) {
        super.init(size: Self.size)

        check.tintColor = .secondaryLabel
        check.contentMode = .center

        let line = UIStackView(arrangedSubviews: blocks + [check])
        line.axis = .horizontal
        line.spacing = 4
        line.alignment = .center
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)

        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        for block in blocks {
            block.layer.cornerRadius = 3
            // 描一道边：浅色主题的「白底」方块压在白 cell 上没有边界，看得见轮廓才像一枚色卡
            block.layer.borderWidth = 0.5
            block.layer.borderColor = UIColor.separator.cgColor
            NSLayoutConstraint.activate([
                block.widthAnchor.constraint(equalToConstant: Self.side),
                block.heightAnchor.constraint(equalToConstant: Self.side)
            ])
        }

        blocks[0].backgroundColor = swatch.background
        blocks[1].backgroundColor = swatch.text
        blocks[2].backgroundColor = swatch.accent
        check.isHidden = !selected
    }

    @available(*, unavailable, message: "这个 view 只从代码里建")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 没实现")
    }
}

/// 行右侧「两个文字按钮」的容器，用来当 `accessoryView`。
///
/// ### 为什么不能用 `UIStackView` 直接顶上
/// `accessoryView` 的宽度是 UIKit 按 `intrinsicContentSize` 问出来的，而 `UIStackView` 在这个位置一律答「不知道」（实测返回 `(-1, -1)`，也就是 `noIntrinsicMetric`）—— 于是两个按钮被压成**零宽**，屏幕上只剩行标题，用户点上去什么也不会发生，看着就是个死按钮（色卡 `ThemeSwatchView` 是同一个坑，它自己报了尺寸）。
///
/// 所以这里自己按按钮的 `intrinsicContentSize` 报一个尺寸，并手写两段 frame —— 一共就两个按钮，手动摆比跟 Auto Layout 讲道理快。
private final class FileActionView: FixedSizeAccessoryView {

    /// 两个按钮之间留的空
    private static let spacing: CGFloat = 12

    private let buttons: [UIButton]

    init(buttons: [UIButton]) {
        self.buttons = buttons
        super.init(size: Self.size(of: buttons))
        for button in buttons { addSubview(button) }
        layoutButtons()
    }

    @available(*, unavailable, message: "这个 view 只从代码里建")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 没实现")
    }

    /// 容器该占多大：两个按钮各自想要的宽度 + 中间的空，高度取高的那个
    private static func size(of buttons: [UIButton]) -> CGSize {
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (index, button) in buttons.enumerated() {
            let size = button.intrinsicContentSize
            if index > 0 { width += spacing }
            width += size.width
            height = max(height, size.height)
        }
        return CGSize(width: width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutButtons()
    }

    /// 从左到右摆开，高度撑满（按钮自己会把字竖着居中）
    private func layoutButtons() {
        var x: CGFloat = 0
        for button in buttons {
            let size = button.intrinsicContentSize
            button.frame = CGRect(x: x, y: 0, width: size.width, height: bounds.height)
            x += size.width + Self.spacing
        }
    }
}
