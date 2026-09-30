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
        /// 用户自己那份 JSON（盖在内置主题之上）
        case customFile

        /// 分区标题
        var header: String? {
            switch self {
            case .builtIn: return "内置主题"
            case .customFile: return "自定义配色"
            }
        }

        /// 分区底部的说明
        var footer: String? {
            switch self {
            case .builtIn:
                return "换配色只换颜色，你在设置页调过的字号、行高、间距一个都不会动。"
            case .customFile:
                return "写一份 JSON，只写想改的几色就行，其余照旧，比如 {\"link\": \"#ff0000\"}。"
            }
        }
    }

    // MARK: 常量

    /// 内置主题那几行复用 cell 用的标识
    private static let themeCellID = "themeCell"
    /// 「主题 JSON 文件」那一行的标识
    private static let fileCellID = "fileCell"
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

    /// 用户那份 JSON 解析出来的配色。没指定 / 读不出来就是 `nil`（= 只用内置主题的颜色）
    private var currentCustomPalette: MarkdownColorPalette? {
        // 「文件名记着」就算指定了：文件万一读不出来，`loadPalette()` 返回 nil，走的和「没指定」是同一条退化路 —— 一份坏 JSON 不该把界面搞成一片黑
        guard settings.customThemeFileName != nil else { return nil }
        return store.loadPalette()
    }

    /// 某一套主题（连带用户那份 JSON）落到 theme 上之后的样子。
    ///
    /// 每一行都要画自己那套的颜色，所以这里不能读「当前选中的那套」，得按传进来的这套算。
    private func resolvedTheme(_ item: MarkdownColorTheme) -> MarkdownTheme {
        var theme = MarkdownTheme.default
        theme.applyColorPalette(settings.resolvedColorPalette(theme: item,
                                                              customPalette: currentCustomPalette))
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
        case .customFile: return 1
        case nil: return 0
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)?.header
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        Section(rawValue: section)?.footer
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .builtIn: return makeThemeCell(item: MarkdownColorTheme.allCases[indexPath.row])
        case .customFile: return makeFileCell()
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

        let selected = item == settings.colorTheme
        let theme = resolvedTheme(item)
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

    /// 「主题 JSON 文件」一行：左边写当前用的哪份，右边「选择 / 清除」两个按钮
    private func makeFileCell() -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.fileCellID)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: Self.fileCellID)

        var content = UIListContentConfiguration.subtitleCell()
        content.text = "主题 JSON 文件"
        content.secondaryText = fileDescription
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        cell.accessoryView = makeFileButtons()
        cell.accessibilityLabel = "主题 JSON 文件"
        return cell
    }

    /// 右边那两个按钮。「清除」在还没指定文件的时候置灰 —— 点了也白点，不如干脆不让点
    private func makeFileButtons() -> UIView {
        let choose = UIButton(type: .system)
        choose.setTitle("选择文件", for: .normal)
        choose.addTarget(self, action: #selector(chooseFile), for: .touchUpInside)
        choose.accessibilityLabel = "选择主题 JSON 文件"

        let clear = UIButton(type: .system)
        clear.setTitle("清除", for: .normal)
        clear.addTarget(self, action: #selector(clearFile), for: .touchUpInside)
        clear.accessibilityLabel = "清除主题 JSON 文件"
        clear.isEnabled = settings.customThemeFileName != nil

        // 文件名那一段自己吃掉多余宽度（它在 cell 里），两个按钮拔到最高优先级，别被压缩
        choose.setContentHuggingPriority(.required, for: .horizontal)
        clear.setContentHuggingPriority(.required, for: .horizontal)

        let line = UIStackView(arrangedSubviews: [choose, clear])
        line.axis = .horizontal
        line.spacing = 12
        line.alignment = .center
        return line
    }

    /// 「没指定」和「指定了」这两种情况下要说的话
    private var fileDescription: String {
        guard let name = settings.customThemeFileName else {
            return "没指定，只用上面那套主题自带的颜色。想自己配色就挑一份 JSON 文件："
                + "里面只写想改的几色，其余照旧。"
        }
        return "当前用的是「\(name)」。它盖在上面选的那套主题之上："
            + "文件里写了哪一色就用哪一色，没写的继续用主题的色。"
    }
}

// MARK: - 表格交互

extension MarkdownThemeViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .builtIn else { return }

        let item = MarkdownColorTheme.allCases[indexPath.row]
        // 点到已经是当前那套就不用再写一遍：`setColorTheme` 自己会挡掉同值重复写，但下面那次重渲染还是省下来比较好
        guard item != settings.colorTheme else { return }
        settings.setColorTheme(item)
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

// MARK: - 挑主题 JSON 文件

extension MarkdownThemeViewController: UIDocumentPickerDelegate {

    /// 挑一份自己的主题 JSON
    @objc private func chooseFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    /// 不用自定义 JSON 了，回到「只用内置主题」的状态
    @objc private func clearFile() {
        store.clear()
        settings.setCustomThemeFileName(nil)
        reloadAll()
    }

    /// 用户在「文件」里挑了一份 JSON。
    ///
    /// ### 为什么是「拷进来」而不是记一个路径
    /// 挑到的文件在别人的沙盒里，App 只有这一次有权读它，下次启动按路径去读会被系统拒掉。
    /// 所以当场把内容读出来、交给 `MarkdownCustomThemeStore` 拷进 App 自己的目录。
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        // 外部文件要先声明「我要访问它」才能读，读完还回去
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url),
              let palette = try? JSONDecoder().decode(MarkdownColorPalette.self, from: data),
              !palette.isEmpty else {
            showFileAlert(message: "这份文件里没读出任何颜色。"
                + "主题 JSON 应该长这样：{\"link\": \"#ff0000\"}，键名见内置配色那套字段。")
            return
        }

        do {
            try store.save(data: data)
            settings.setCustomThemeFileName(url.lastPathComponent)
            reloadAll()
        } catch {
            showFileAlert(message: "拷进 App 目录时失败了（\(error.localizedDescription)），换一份文件试试。")
        }
    }

    /// 「选了文件却没反应」是最难查的一类问题，所以失败一定要说出来
    private func showFileAlert(message: String) {
        let alert = UIAlertController(title: "没能用上这份主题文件",
                                      message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
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
private final class ThemeSwatchView: UIView {

    private let blocks = [UIView(), UIView(), UIView()]
    private let check = UIImageView(image: UIImage(systemName: "checkmark"))

    /// 一个方块的边长
    private static let side: CGFloat = 16
    /// 整枚色卡的尺寸：三个方块 + 两个间距 + 一个对勾。
    ///
    /// 既当 `frame` 又当 `intrinsicContentSize`：`accessoryView` 的宽度是 UIKit 拿它算出来的，
    /// 不给定尺寸的话这一列色卡会东一块西一块地对不齐右边的边。
    private static let size = CGSize(width: side * 3 + 4 * 3 + 18, height: side + 4)

    init(swatch: ThemeSwatch, selected: Bool) {
        super.init(frame: CGRect(origin: .zero, size: Self.size))

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

    /// 告诉 `UITableView` 这一枚该占多大（和 init 里那个 frame 是同一个值）
    override var intrinsicContentSize: CGSize {
        Self.size
    }
}
