import UIKit

/// 用户在「导出成 HTML」这个小面板里做的选择。
///
/// 故意**不**带上 `MarkdownTheme` 和目录：面板只管问「要什么」，具体去哪儿找图、用哪套颜色是调用方的事—— 这样这个面板能被单独测（塞两个分段控件进去、读回可选结构），也不用认识编辑器。
struct HTMLExportChoice {
    /// 用编辑器当前主题的配色，还是内置那套 GitHub 风格
    var usesThemeColors: Bool
    /// 能不能读到的本地图片要不要编成 base64 内联
    var inlinesLocalImages: Bool

    /// 上次导出选的什么（第一次给默认值：跟主题配色、图片保留原路径）
    static var stored: HTMLExportChoice {
        let defaults = UserDefaults.standard
        let usesTheme = defaults.object(forKey: Keys.usesThemeColors) as? NSNumber
        let inlines = defaults.object(forKey: Keys.inlinesLocalImages) as? NSNumber
        return HTMLExportChoice(usesThemeColors: usesTheme?.boolValue ?? true,
                                inlinesLocalImages: inlines?.boolValue ?? false)
    }

    func save() {
        // 存 NSNumber 而不是 Bool：`bool(forKey:)` 在「从没存过」的时候也会返回 false，分不清那是默认值还是用户真的选了「不内联」。用 object(forKey:) 读回 NSNumber 才判得出来。
        UserDefaults.standard.set(NSNumber(value: usesThemeColors), forKey: Keys.usesThemeColors)
        UserDefaults.standard.set(NSNumber(value: inlinesLocalImages), forKey: Keys.inlinesLocalImages)
    }

    private enum Keys {
        static let usesThemeColors = "htmlExport.usesThemeColors"
        static let inlinesLocalImages = "htmlExport.inlinesLocalImages"
    }
}

/// 「导出成 HTML」的选项面板。
///
/// ### 为什么非得插这一页
/// 导出结果有两种互有取舍的做法：配色是跟着编辑器主题走（导出页面和编辑器里看到的一样），还是用一套固定的（分享给别人时对方看到的永远是同一个样子）；
/// 图片是保留 `![](a.png)` 原路径（导出来还是一份小文件，但拷走就变死图），还是把本地读得到的图编成 base64 内联（单文件自包含，代价是 HTML 会变大）。
/// 这两件事只能用户自己拿主意，所以点菜单之后先问一句，再落到保存 / 分享那一步。
final class HTMLExportOptionsController: UIViewController {

    /// 点「导出」时回调，参数是面板当前的选择
    var onExport: ((HTMLExportChoice) -> Void)?

    /// 这一页只问两件事，两个分段控件
    private let styleSegmented = UISegmentedControl(items: ["跟随当前主题", "内置样式"])
    private let imageSegmented = UISegmentedControl(items: ["保留原路径", "内联为 base64"])

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "导出成 HTML"
        view.backgroundColor = .systemGroupedBackground

        let choice = HTMLExportChoice.stored
        styleSegmented.selectedSegmentIndex = choice.usesThemeColors ? 0 : 1
        imageSegmented.selectedSegmentIndex = choice.inlinesLocalImages ? 1 : 0

        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel,
                                                           target: self,
                                                           action: #selector(cancelTapped))

        let stack = UIStackView(arrangedSubviews: [
            card(title: "配色",
                 subtitle: "「跟随当前主题」导出的页面和编辑器里看到的一致；"
                     + "「内置样式」是一套固定的浅色版式，换主题、换深浅色外观都不变。",
                 control: styleSegmented),
            card(title: "图片",
                 subtitle: "本地图片可以编成 base64 塞进 HTML，文件拷到哪儿都能显示；"
                     + "代价是文件会变大（超过 2 MB 的图自动跳过）。网络图片两种模式下都保持原链接。",
                 control: imageSegmented),
            exportButton()
        ])
        stack.axis = .vertical
        stack.spacing = 18
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20)
        ])
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func exportTapped() {
        let choice = HTMLExportChoice(usesThemeColors: styleSegmented.selectedSegmentIndex == 0,
                                      inlinesLocalImages: imageSegmented.selectedSegmentIndex == 1)
        choice.save()
        dismiss(animated: true) { [onExport] in onExport?(choice) }
    }

    // MARK: 界面零件

    /// 一张「小卡片」：标题 + 说明 + 一个分段控件。
    ///
    /// ### 为什么用 `UIStackView` 自己排而不是 `UITableView`
    /// 就两行东西，为它起一张表格（注册 cell、写数据源、处理选中）不值当；
    /// 而卡片这一层是必要的 —— 分段控件直接铺在灰底上，看不出它管着哪个问题。
    private func card(title: String, subtitle: String, control: UISegmentedControl) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [titleLabel, control, subtitleLabel])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 10
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
        return card
    }

    private func exportButton() -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = "导出"
        configuration.cornerStyle = .medium
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: #selector(exportTapped), for: .touchUpInside)
        button.accessibilityLabel = "导出 HTML"
        return button
    }
}
