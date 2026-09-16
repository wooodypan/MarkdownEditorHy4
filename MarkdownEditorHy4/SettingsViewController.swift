//
//  SettingsViewController.swift
//  MarkdownEditorHy4
//
//  简易设置页：正文排版 + 阅读相关 + 大纲面板高度 + 表格列宽，后面还会往里加
//
//  这一页改了之后要「当场生效」的那几项（字号、行高、段间距、首行缩进、表格列宽），
//  是由内容页监听 `MarkdownEditorSettings.didChangeNotification` 后重新渲染实现的，
//  设置页自己只负责把值写回配置 —— 它不认识编辑器，也不需要认识。
//

import UIKit

/// 设置页。
///
/// ### 为什么用 `UITableView` 而不是手摆几个 `UILabel` + `UISwitch`
/// 需求里写了「**先**增加一行」，说明后面还会继续加。`UITableView` 只要往
/// `Row` 这个枚举里加一个 case、在 `cellForRowAt` 里补一段配置，
/// 新行自动就有了（分组、分隔线、深色模式、动态字号全都不用自己管）。
/// 手摆控件的话，每加一行都要重算约束。
///
/// 分组样式用 `.insetGrouped`：这是系统设置、各种 App 设置页的通用样子，
/// 一行一个「标题 + 说明 + 右侧控件」，用户在 iOS 和 Mac Catalyst 上都认得。
///
/// ### 打开方式
/// 由 `ViewController` 包在 `UINavigationController` 里弹出来（和「源码」那一页一致），
/// 所以这里只需要一个「完成」按钮把页面关掉。
final class SettingsViewController: UIViewController {

    // MARK: 分组

    private enum Section: Int, CaseIterable {
        /// 正文字体与段落排版。放最上面：这是用户最常进来改的一组
        case typography
        /// 阅读与大纲（开关类）
        case reading
        /// 大纲面板长多高
        case outlineSize
        /// 表格画出来时的列宽限制
        case tableLayout

        var title: String {
            switch self {
            case .typography: return "正文排版"
            case .reading: return "阅读与大纲"
            case .outlineSize: return "大纲面板高度"
            case .tableLayout: return "表格列宽"
            }
        }

        var rows: [Row] {
            switch self {
            case .typography:
                // 顺序就是界面上从上到下的顺序：
                // 先定字号，再定行与行、段与段、段首，最后是整行的宽度
                return [.bodyFontSize, .lineHeightMultiple, .paragraphSpacing,
                        .paragraphIndentCharacters, .bodyContentWidth]
            case .reading:
                return [.remembersScrollPosition]
            case .outlineSize:
                // 顺序就是界面上从上到下的顺序：先选「怎么算」，再调两个数值
                return [.outlineHeightMode, .outlineHeightRatio, .outlineMaximumHeight]
            case .tableLayout:
                return [.tableMinColumnWidth, .tableMaxColumnWidth]
            }
        }
    }

    // MARK: 行

    /// 设置页上的行。加新设置就先在这里加一个 case
    private enum Row: Int, CaseIterable {
        // 正文排版
        /// 正文字号（点）
        case bodyFontSize
        /// 行高倍数
        case lineHeightMultiple
        /// 段落之间的间距（点）
        case paragraphSpacing
        /// 段落首行缩进（字符数）
        case paragraphIndentCharacters
        /// 正文栏宽上限（点），拖到最右端 = 不限
        case bodyContentWidth
        // 阅读与大纲
        case remembersScrollPosition
        /// 高度按什么算（百分比 / 固定最大高度）
        case outlineHeightMode
        /// 高度占父视图高度的比例
        case outlineHeightRatio
        /// 固定高度上限（点）
        case outlineMaximumHeight
        /// 表格最窄的一列（点）
        case tableMinColumnWidth
        /// 表格最宽的一列（点）
        case tableMaxColumnWidth

        /// 主标题
        var title: String {
            switch self {
            case .bodyFontSize:
                return "正文字号"
            case .lineHeightMultiple:
                return "行高"
            case .paragraphSpacing:
                return "段落间距"
            case .paragraphIndentCharacters:
                return "段落首行缩进"
            case .bodyContentWidth:
                return "行宽上限"
            case .remembersScrollPosition:
                return "记住目录大纲滚动位置"
            case .outlineHeightMode:
                return "高度怎么算"
            case .outlineHeightRatio:
                return "高度百分比"
            case .outlineMaximumHeight:
                return "最大高度"
            case .tableMinColumnWidth:
                return "最小列宽"
            case .tableMaxColumnWidth:
                return "最大列宽"
            }
        }

        /// 副标题：把「这一项是干嘛的、什么时候不起作用」说清楚，
        /// 免得用户点完/拖完不知道发生了什么。
        /// 两句高度相关的说明要跟着模式变 —— 不生效的那一项得明说
        func detail(in settings: MarkdownEditorSettings) -> String {
            let usesRatio = settings.outlineHeightMode == .percentage
            switch self {
            case .bodyFontSize:
                return "正文的字号。标题、行内代码、代码块都是从这个数推出来的"
                    + "（标题更大、代码略小），会跟着一起变。"
            case .lineHeightMultiple:
                return "行与行之间的距离。「1.00 倍」就是字体自带的松紧度，"
                    + "中文正文调到 1.40～1.60 读起来最省力。"
                    + "只影响文字，图片、表格、分隔线不跟着变松。"
            case .paragraphSpacing:
                return "上下两段之间空多少。正文、标题、列表项用的是同一个值，"
                    + "调大一点段落之间就分得清楚。"
            case .paragraphIndentCharacters:
                return "每个自然段**第一行**往右缩进几个字（后面的行不缩），"
                    + "中文排版习惯是缩 2 个字。标题、列表项、引用块、代码块都不缩。"
            case .bodyContentWidth:
                return "一行最多排多宽。窗口比它宽时正文居中、两边留白"
                    + "（一行拉太长，读到行尾容易串行）；拖到最右边显示「不限」，"
                    + "正文就铺满整个窗口。"
            case .remembersScrollPosition:
                return "打开：大纲跟着光标所在章节自动滚动，关闭文件时记住读到哪里，"
                    + "下次打开同一个文件回到原处。关闭：大纲只在你手动滚动时才动，"
                    + "列表刷新后回到顶部。"
            case .outlineHeightMode:
                return "「按百分比」按窗口高度算上限（下面的「最大高度」不生效）；"
                    + "「按最大高度」改用固定值。两种都只是上限：标题少的时候，"
                    + "面板会贴着内容变矮，不会空一大片。"
            case .outlineHeightRatio:
                return usesRatio
                    ? "面板高度最多占窗口高度的百分之几。"
                    : "当前用的是「按最大高度」，这一项暂不生效。"
            case .outlineMaximumHeight:
                return usesRatio
                    ? "当前用的是「按百分比」，这一项暂不生效。"
                    : "面板高度最多是多少点。窗口太小的话还会被压一道，不会盖满整屏。"
            case .tableMinColumnWidth:
                return "表格里再短的列也不窄于这个值，「姓名」这类两字列才不会挤成一团。"
                    + "如果调得比「最大列宽」还大，会按最大列宽算。"
            case .tableMaxColumnWidth:
                return "某一列内容特别长（比如贴了长链接）时，列宽到这里就封顶，"
                    + "多出来的文字自动换行，不把别的列挤没。"
            }
        }

        /// 这一项的滑块值范围
        var sliderRange: ClosedRange<Double> {
            switch self {
            case .bodyFontSize: return MarkdownEditorSettings.Limits.bodyFontSize
            case .lineHeightMultiple: return MarkdownEditorSettings.Limits.lineHeightMultiple
            case .paragraphSpacing: return MarkdownEditorSettings.Limits.paragraphSpacing
            case .paragraphIndentCharacters:
                return MarkdownEditorSettings.Limits.paragraphIndentCharacters
            case .bodyContentWidth: return MarkdownEditorSettings.Limits.bodyContentWidth
            case .outlineHeightRatio: return MarkdownEditorSettings.Limits.outlineHeightRatio
            case .outlineMaximumHeight: return MarkdownEditorSettings.Limits.outlineMaximumHeight
            case .tableMinColumnWidth: return MarkdownEditorSettings.Limits.tableMinColumnWidth
            case .tableMaxColumnWidth: return MarkdownEditorSettings.Limits.tableMaxColumnWidth
            default: return 0...1
            }
        }

        /// 拖动时的步进：一档一档地吸，免得停在 63.7% 这种数上
        var sliderStep: Double {
            switch self {
            case .bodyFontSize: return 1
            case .lineHeightMultiple: return 0.05
            case .paragraphSpacing: return 2
            case .paragraphIndentCharacters: return 0.5
            case .bodyContentWidth: return 20
            case .outlineHeightRatio: return 0.05
            case .outlineMaximumHeight: return 20
            case .tableMinColumnWidth, .tableMaxColumnWidth: return 8
            default: return 1
            }
        }


        /// 配置里这一项现在的值
        func currentValue(in settings: MarkdownEditorSettings) -> Double {
            switch self {
            case .bodyFontSize: return settings.bodyFontSize
            case .lineHeightMultiple: return settings.lineHeightMultiple
            case .paragraphSpacing: return settings.paragraphSpacing
            case .paragraphIndentCharacters: return settings.paragraphIndentCharacters
            case .bodyContentWidth: return settings.bodyContentWidth
            case .outlineHeightRatio: return settings.outlineHeightRatio
            case .outlineMaximumHeight: return settings.outlineMaximumHeight
            case .tableMinColumnWidth: return settings.tableMinColumnWidth
            case .tableMaxColumnWidth: return settings.tableMaxColumnWidth
            default: return 0
            }
        }

        /// 把滑块的连续值吸到步进上（不然会停在 63.700003 这种数上）
        func steppedValue(_ raw: Double) -> Double {
            (raw / sliderStep).rounded() * sliderStep
        }

        /// 数值怎么显示给用户看
        func formatted(_ value: Double) -> String {
            switch self {
            case .bodyFontSize:
                return "\(Int(value.rounded())) pt"
            case .lineHeightMultiple:
                // 1 倍就是「什么都没加」，写个数字反而不如直接说清楚
                return value <= 1.001 ? "默认" : String(format: "%.2f 倍", value)
            case .paragraphSpacing:
                return "\(Int(value.rounded())) pt"
            case .paragraphIndentCharacters:
                return Self.formatCharacters(value)
            case .bodyContentWidth:
                // 量程最右端是「不限」—— 和 `MarkdownEditorSettings.bodyContentWidthLimit` 保持一致
                return value >= sliderRange.upperBound
                    ? "不限"
                    : "\(Int(value.rounded())) pt"
            case .outlineHeightRatio:
                return "\(Int((value * 100).rounded()))%"
            case .outlineMaximumHeight, .tableMinColumnWidth, .tableMaxColumnWidth:
                return "\(Int(value.rounded())) pt"
            default:
                return "\(value)"
            }
        }

        /// 「缩进几个字」的显示：0 说「不缩进」，半个字也照实写出来
        private static func formatCharacters(_ value: Double) -> String {
            if value < 0.01 { return "不缩进" }
            let rounded = (value * 2).rounded() / 2
            let number = rounded == rounded.rounded()
                ? "\(Int(rounded))"
                : String(format: "%.1f", rounded)
            return "\(number) 字符"
        }
    }

    // MARK: 控件

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    /// 读 / 写这份配置。默认用全局实例，测试可以换成指向临时目录的
    private let settings: MarkdownEditorSettings

    /// 滑块旁边那个显示当前值的标签，靠 tag 从 cell 里找回来
    private static let valueLabelTag = 9001

    init(settings: MarkdownEditorSettings = .shared) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsViewController 不支持从 coder 解档")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设置"
        view.backgroundColor = .systemGroupedBackground

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        // 这些行没有二级页面，不需要「点了变灰再弹回来」的选中效果
        tableView.allowsSelection = false
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        setupDoneButton()
    }

    /// 右上角「完成」，点了关掉本页
    private func setupDoneButton() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                            target: self,
                                                            action: #selector(dismissSelf))
    }

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }

    // MARK: 控件回调

    /// 开关被拨动
    @objc private func switchChanged(_ sender: UISwitch) {
        guard let row = Row(rawValue: sender.tag) else { return }
        switch row {
        case .remembersScrollPosition:
            settings.setRemembersScrollPosition(sender.isOn)
        default:
            break
        }
    }

    /// 「高度怎么算」换了模式
    @objc private func heightModeChanged(_ sender: UISegmentedControl) {
        let modes = OutlineHeightMode.allCases
        guard modes.indices.contains(sender.selectedSegmentIndex) else { return }
        settings.setOutlineHeightMode(modes[sender.selectedSegmentIndex])
        // 两个滑块的「能不能用」跟着模式变，整表重刷最省事（总共没几行）
        tableView.reloadData()
    }

    /// 拖动了某个数值滑块
    @objc private func sliderChanged(_ sender: UISlider) {
        guard let row = Row(rawValue: sender.tag) else { return }
        // 先吸到步进上（滑块的连续值会停在 63.700003 这种数上）
        let stepped = row.steppedValue(Double(sender.value))

        switch row {
        case .bodyFontSize:
            settings.setBodyFontSize(stepped)
        case .lineHeightMultiple:
            settings.setLineHeightMultiple(stepped)
        case .paragraphSpacing:
            settings.setParagraphSpacing(stepped)
        case .paragraphIndentCharacters:
            settings.setParagraphIndentCharacters(stepped)
        case .bodyContentWidth:
            settings.setBodyContentWidth(stepped)
        case .outlineHeightRatio:
            settings.setOutlineHeightRatio(stepped)
        case .outlineMaximumHeight:
            settings.setOutlineMaximumHeight(stepped)
        case .tableMinColumnWidth:
            settings.setTableMinColumnWidth(stepped)
        case .tableMaxColumnWidth:
            settings.setTableMaxColumnWidth(stepped)
        case .remembersScrollPosition, .outlineHeightMode:
            // 这两行挂的是开关 / 分段控件，不是滑块，回调不会从这儿进来。
            // ⚠️ 这里**故意不写 `default:`**：穷举之后，以后往 `Row` 里加一行滑块，
            // 编译器会直接报「switch must be exhaustive」逼你回来接上 ——
            // 少了这层保护就会出现「滑块能拖、但拖了什么都没发生」这种静默失效。
            return
        }

        // 从配置里读回来 —— 超范围的值会被它夹到边界，界面上得显示夹过之后的结果
        let applied = row.currentValue(in: settings)
        sender.value = Float(applied)
        updateValueLabel(of: row, in: sender, value: applied)
    }

    /// 刷新某个滑块旁边显示的数字
    private func updateValueLabel(of row: Row, in slider: UISlider, value: Double) {
        guard let label = slider.superview?.viewWithTag(Self.valueLabelTag) as? UILabel else { return }
        label.text = row.formatted(value)
    }

    // MARK: 造控件

    /// 造一个「标题 + 说明 + 控件」的竖排单元格。
    ///
    /// ### 为什么这几行干脆不复用 cell
    /// 行数是个位数，而且每行挂的控件类型都不一样（开关 / 分段控件 / 滑块）。
    /// 走 `dequeueReusableCell` 反而要处理「复用出来的 cell 上还挂着上一行的控件和
    /// target」这类问题，滑块尤其容易串值。直接新建最省心。
    private func makeCell(row: Row, control: UIView) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        // 这些行点了没有二级页面，别给选中效果
        cell.selectionStyle = .none

        let titleLabel = UILabel()
        titleLabel.text = row.title
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0

        let detailLabel = UILabel()
        detailLabel.text = row.detail(in: settings)
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel, control])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor)
        ])
        return cell
    }

    /// 模式选择：两个选项平铺，一眼能看出是「二选一」
    private func makeHeightModeCell() -> UITableViewCell {
        let modes = OutlineHeightMode.allCases
        let control = UISegmentedControl(items: modes.map(\.displayName))
        control.selectedSegmentIndex = modes.firstIndex(of: settings.outlineHeightMode) ?? 0
        control.addTarget(self, action: #selector(heightModeChanged(_:)), for: .valueChanged)
        control.accessibilityLabel = Row.outlineHeightMode.title
        return makeCell(row: .outlineHeightMode, control: control)
    }

    /// 数值行：左边滑块，右边当前值。
    ///
    /// 当前这一项在当前模式下不生效时，滑块置灰 —— 光看文字说明还不够直观，
    /// 灰掉的控件能把「现在调它没用」直接摆出来
    private func makeSliderCell(for row: Row) -> UITableViewCell {
        let slider = UISlider()
        slider.minimumValue = Float(row.sliderRange.lowerBound)
        slider.maximumValue = Float(row.sliderRange.upperBound)
        let value = row.currentValue(in: settings)
        slider.value = Float(value)
        // tag 记着「这是哪一行」，回调里靠它区分
        slider.tag = row.rawValue
        slider.isContinuous = true
        slider.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
        slider.accessibilityLabel = row.title

        let valueLabel = UILabel()
        valueLabel.text = row.formatted(value)
        valueLabel.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: .regular))
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textColor = .secondaryLabel
        valueLabel.textAlignment = .right
        valueLabel.tag = Self.valueLabelTag
        // 固定宽度 + 等宽数字：拖动时数字变化不会把滑块挤来挤去。
        // ⚠️ 宽度要放得下最长的那几个值：「1200 pt」7 个等宽字符 ≈ 55pt、
        // 「1.5 字符」还带两个汉字 ≈ 57pt —— 56 就正好卡在边界上会截字，所以给 68
        valueLabel.widthAnchor.constraint(equalToConstant: 68).isActive = true

        let affectsHeight = isEffective(row)
        slider.isEnabled = affectsHeight
        valueLabel.alpha = affectsHeight ? 1 : 0.4

        let line = UIStackView(arrangedSubviews: [slider, valueLabel])
        line.axis = .horizontal
        line.spacing = 8
        line.alignment = .center

        let cell = makeCell(row: row, control: line)
        slider.alpha = affectsHeight ? 1 : 0.4
        return cell
    }

    /// 这一项在当前模式下生效吗（不生效的滑块要灰掉）
    private func isEffective(_ row: Row) -> Bool {
        switch row {
        case .outlineHeightRatio: return settings.outlineHeightMode == .percentage
        case .outlineMaximumHeight: return settings.outlineHeightMode == .maximumHeight
        default: return true
        }
    }
}

// MARK: - 表格数据源 / 代理

extension SettingsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    // ⚠️ 这两处参数特意不叫 `section`：叫了就会把下面那个
    // 「按下标找分组」的方法名 `section(at:)` 遮蔽掉，编译直接报
    // 「cannot call value of non-function type 'Int'」
    func tableView(_ tableView: UITableView, numberOfRowsInSection sectionIndex: Int) -> Int {
        section(at: sectionIndex)?.rows.count ?? 0
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection sectionIndex: Int) -> String? {
        section(at: sectionIndex)?.title
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let row = row(at: indexPath) else { return UITableViewCell() }

        switch row {
        case .remembersScrollPosition:
            return makeToggleCell(for: row)
        case .outlineHeightMode:
            return makeHeightModeCell()
        case .bodyFontSize, .lineHeightMultiple, .paragraphSpacing, .paragraphIndentCharacters,
             .bodyContentWidth,
             .outlineHeightRatio, .outlineMaximumHeight,
             .tableMinColumnWidth, .tableMaxColumnWidth:
            return makeSliderCell(for: row)
        }
    }

    /// 开关行照旧用系统的副标题单元格 + 右侧开关：
    /// 这是 iOS 设置页最标准的「标题 + 说明 + 开关在右边」的样子
    private func makeToggleCell(for row: Row) -> UITableViewCell {
        let identifier = "settingsCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)

        // 内容配置走系统的 `contentConfiguration`（`textLabel` / `detailTextLabel`
        // 那套在 iOS 14 之后已经标记过时了）：它自带多行副标题的排版，
        // 也会自动跟着动态字号和深色模式走
        var content = UIListContentConfiguration.subtitleCell()
        content.text = row.title
        content.secondaryText = row.detail(in: settings)
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content

        let toggle = UISwitch()
        toggle.tag = row.rawValue
        toggle.isOn = settings.remembersScrollPosition
        toggle.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
        toggle.accessibilityLabel = row.title
        cell.accessoryView = toggle

        return cell
    }

    /// 按位置找出是哪一行
    private func row(at indexPath: IndexPath) -> Row? {
        guard let section = section(at: indexPath.section) else { return nil }
        guard section.rows.indices.contains(indexPath.row) else { return nil }
        return section.rows[indexPath.row]
    }

    private func section(at index: Int) -> Section? {
        Section.allCases.indices.contains(index) ? Section.allCases[index] : nil
    }
}