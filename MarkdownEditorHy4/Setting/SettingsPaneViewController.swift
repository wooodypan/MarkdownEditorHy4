//
//  SettingsPaneViewController.swift
//  MarkdownEditorHy4
//
//  设置页的「一块面板」：只管一个分组（比如「大纲面板」）。
//
//  ### 它在整棵树里的位置
//  - Mac：`SettingsSplitViewController` 的右半边（左边是侧边栏），换分组就是换一块面板。
//  - iPhone / iPad：`SettingsListViewController` 里点一行 push 上来的页面（导航栈顶）。
//  两端用同一个类 —— 面板本身跟平台无关，它不认识自己是被 push 上来的还是被塞进分栏的。
//
//  ### 从前不是这样的
//  原先是「所有分组摊在一张表里」，一路往下滚。分组多了以后（现在七个），想改「表格列宽」得先滚过一整屏「正文排版」，而且滚到底就看不见上面改过什么。
//  现在拆成「目录 + 面板」：列表（侧边栏）一屏放得下所有分组，面板一屏放得下一个分组。
//
//  面板里改的那几项要「当场生效」，靠的是内容页监听 `MarkdownEditorSettings.didChangeNotification`
//  之后重新渲染；这一页自己只负责把值写回配置 —— 它不认识编辑器，也不需要认识。
//

import UIKit
import UniformTypeIdentifiers

/// 一个分组的面板。
///
/// ### 为什么用 `UITableView` 而不是手摆几个 `UILabel` + `UISwitch`
/// 需求里写了「先增加一行」，说明后面还会继续加。`UITableView` 只要往
/// `SettingsRow` 里加一个 case、在 `cellForRowAt` 里补一段配置，
/// 新行自动就有了（分组、分隔线、深色模式、动态字号全都不用自己管）。
/// 手摆控件的话，每加一行都要重算约束。
///
/// 分组样式用 `.insetGrouped`：这是系统设置、各种 App 设置页的通用样子，
/// 一行一个「标题 + 说明 + 右侧控件」，用户在 iOS 和 Mac Catalyst 上都认得。
///
/// ### 顶部为什么没有分组标题
/// 这一页只有一个分组，它的名字已经由外面那层显示出来了 —— iPhone 上是导航栏标题，Mac 上是侧边栏里高亮的那一行。表里再画一条一模一样的灰字标题，属于重复。
final class SettingsPaneViewController: UIViewController {

    // MARK: 依赖

    /// 这一页负责哪个分组（决定表格里有哪几行）
    let section: SettingsSection

    /// 读 / 写这份配置。默认用全局实例，测试可以换成指向临时目录的
    private let settings: MarkdownEditorSettings

    // MARK: 控件

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    /// 滑块旁边那个显示当前值的标签，靠 tag 从 cell 里找回来
    private static let valueLabelTag = 9001

    /// 「表格源码文字颜色」那个按钮，拖动取色器时要靠 tag 找到它改色块
    private static let tableSourceColorButtonTag = 9002

    // MARK: 取色器的临时状态

    /// 取色器**打开那一刻**的颜色。用来认出「只是点开看一眼、没真改」——
    /// ⚠️ 取色器一露面就会回调一次当前色，照单全收的话「跟随主题」会被悄悄改成固定色。
    private var tableSourceColorAtOpen: String?

    /// 这一轮取色里用户**真的动过**颜色（拖出一个和打开时不一样的色）才置 `true`。
    /// 置了之后就连「拖回原色」也要照实写进去，否则配置会停在中间某一色上。
    private var hasPickedTableSourceColor = false

    /// 拖动过程中攒着的那一色：等手停下来才写进配置（每动一格都写会让正文整篇重渲染，拖起来一顿一顿的）
    private var pendingTableSourceColor: UIColor?

    /// 上面那个「等手停下来」的定时器
    private var tableSourceColorCommitTimer: Timer?

    init(section: SettingsSection, settings: MarkdownEditorSettings = .shared) {
        self.section = section
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
        // 标题给外面那层用：iPhone 上是导航栏标题，Mac 上是侧边栏选中项的名字
        title = section.title
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsPaneViewController 不支持从 coder 解档")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        // iPhone / iPad 上这一页是 push 上来的：标题走「小标题 + 返回箭头」那种常规样子，大标题留给上一层的目录页（`SettingsListViewController`）—— 这正是 iOS 设置页的规矩。
        // Mac 上没有导航栏，这一行不起作用，留着不用管
        navigationItem.largeTitleDisplayMode = .never

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
    }

    // MARK: 控件回调

    /// 离开这一页（换分组、关面板）：把还在定时器里等着的那一色先落地。
    ///
    /// ⚠️ 弹取色器时这个回调也会走一趟，那时 `pending` 是空的，`commit` 直接返回，没有副作用。
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        commitPendingTableSourceColor()
    }

    /// 开关被拨动
    @objc private func switchChanged(_ sender: UISwitch) {
        guard let row = SettingsRow(rawValue: sender.tag) else { return }
        switch row {
        case .showsLineNumbers:
            settings.setShowsLineNumbers(sender.isOn)
        case .showsQuoteBackground:
            settings.setShowsQuoteBackground(sender.isOn)
        case .inlineCodeBacktickBackground:
            settings.setShowsInlineCodeBacktickBackground(sender.isOn)
        case .outlineReservesSpace:
            settings.setReservesSpaceForOutline(sender.isOn)
        case .remembersScrollPosition:
            settings.setRemembersScrollPosition(sender.isOn)
        case .pastesHTMLAsMarkdown:
            settings.setPastesHTMLAsMarkdown(sender.isOn)
        case .savesWebImagesLocally:
            settings.setSavesWebImagesLocally(sender.isOn)
        default:
            break
        }
    }

    /// 「大纲宽度怎么算」换了模式
    @objc private func outlineWidthModeChanged(_ sender: UISegmentedControl) {
        let modes = OutlineWidthMode.allCases
        guard modes.indices.contains(sender.selectedSegmentIndex) else { return }
        settings.setOutlineWidthMode(modes[sender.selectedSegmentIndex])
        // 两个滑块的「能不能用」跟着模式变，整表重刷最省事（总共没几行）
        tableView.reloadData()
    }

    /// 「高度怎么算」换了模式
    @objc private func heightModeChanged(_ sender: UISegmentedControl) {
        let modes = OutlineHeightMode.allCases
        guard modes.indices.contains(sender.selectedSegmentIndex) else { return }
        settings.setOutlineHeightMode(modes[sender.selectedSegmentIndex])
        // 两个滑块的「能不能用」跟着模式变，整表重刷最省事（总共没几行）
        tableView.reloadData()
    }

    /// 「图片宽度怎么算」换了模式
    @objc private func imageWidthModeChanged(_ sender: UISegmentedControl) {
        let modes = ImageWidthMode.allCases
        guard modes.indices.contains(sender.selectedSegmentIndex) else { return }
        settings.setImageWidthMode(modes[sender.selectedSegmentIndex])
        tableView.reloadData()
    }

    /// 拖动了某个数值滑块
    @objc private func sliderChanged(_ sender: UISlider) {
        guard let row = SettingsRow(rawValue: sender.tag) else { return }
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
        case .bulletDiameter:
            settings.setBulletDiameter(stepped)
        case .outlineWidthRatio:
            settings.setOutlineWidthRatio(stepped)
        case .outlineWidthPoints:
            settings.setOutlineWidthPoints(stepped)
        case .outlineHeightRatio:
            settings.setOutlineHeightRatio(stepped)
        case .outlineMaximumHeight:
            settings.setOutlineMaximumHeight(stepped)
        case .outlineBackgroundOpacity:
            settings.setOutlineBackgroundOpacity(stepped)
        case .tableMinColumnWidth:
            settings.setTableMinColumnWidth(stepped)
        case .tableMaxColumnWidth:
            settings.setTableMaxColumnWidth(stepped)
        case .tableCellPaddingHorizontal:
            settings.setTableCellPaddingHorizontal(stepped)
        case .tableCellPaddingVertical:
            settings.setTableCellPaddingVertical(stepped)
        case .tableSourceFontSize:
            settings.setTableSourceFontSize(stepped)
        case .imageWidthRatio:
            settings.setImageWidthRatio(stepped)
        case .imageWidthPoints:
            settings.setImageWidthPoints(stepped)
        case .imageMaxHeight:
            settings.setImageMaxHeight(stepped)
        case .appearanceMode,
             .showsLineNumbers, .remembersScrollPosition, .pastesHTMLAsMarkdown,
             .savesWebImagesLocally,
             .showsQuoteBackground, .outlineReservesSpace,
             .inlineCodeBacktickBackground,
             .outlineWidthMode, .outlineHeightMode, .imageWidthMode,
             .imageInsertionMode, .imageCustomFolderPath, .imageNameMode,
             .tableSourceTextColor:
            // 这几行挂的是开关 / 分段控件 / 菜单按钮，不是滑块，回调不会从这儿进来。
            // ⚠️ 这里故意不写 `default:`：穷举之后，以后往 `SettingsRow` 里加一行滑块，
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
    private func updateValueLabel(of row: SettingsRow, in slider: UISlider, value: Double) {
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
    private func makeCell(row: SettingsRow, control: UIView) -> UITableViewCell {
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
        control.accessibilityLabel = SettingsRow.outlineHeightMode.accessibilityLabel
        return makeCell(row: .outlineHeightMode, control: control)
    }

    /// 「大纲宽度怎么算」：两个选项平铺，一眼能看出是「二选一」
    private func makeOutlineWidthModeCell() -> UITableViewCell {
        let modes = OutlineWidthMode.allCases
        let control = UISegmentedControl(items: modes.map(\.displayName))
        control.selectedSegmentIndex = modes.firstIndex(of: settings.outlineWidthMode) ?? 0
        control.addTarget(self, action: #selector(outlineWidthModeChanged(_:)), for: .valueChanged)
        control.accessibilityLabel = SettingsRow.outlineWidthMode.accessibilityLabel
        return makeCell(row: .outlineWidthMode, control: control)
    }

    /// 「图片宽度怎么算」：两个选项平铺，一眼能看出是「二选一」
    private func makeImageWidthModeCell() -> UITableViewCell {
        let modes = ImageWidthMode.allCases
        let control = UISegmentedControl(items: modes.map(\.displayName))
        control.selectedSegmentIndex = modes.firstIndex(of: settings.imageWidthMode) ?? 0
        control.addTarget(self, action: #selector(imageWidthModeChanged(_:)), for: .valueChanged)
        control.accessibilityLabel = SettingsRow.imageWidthMode.accessibilityLabel
        return makeCell(row: .imageWidthMode, control: control)
    }

    /// 「外观模式」：点一下弹三档菜单（跟随系统 / 深色 / 浅色）。
    ///
    /// ### 为什么用菜单而不是分段控件
    /// 「跟随系统」四个字最宽，和另外两档平铺进一行会被截成「跟随…」，用户分不出哪个是哪个。
    /// 菜单一列摆开、当前项打勾，和系统设置里「App 外观」那类选择是一个手感。
    private func makeAppearanceModeCell() -> UITableViewCell {
        makeMenuCell(for: .appearanceMode,
                     title: settings.appearanceMode.displayName,
                     menu: makeAppearanceModeMenu())
    }

    /// 三档外观组成的菜单，当前选中的那一项打勾
    private func makeAppearanceModeMenu() -> UIMenu {
        let current = settings.appearanceMode
        let actions = MarkdownAppearanceMode.allCases.map { mode in
            UIAction(title: mode.displayName,
                     state: mode == current ? .on : .off) { [weak self] _ in
                guard let self else { return }
                // 走 `MarkdownAppearance` 而不是直接写配置：它先把窗口套成新外观，
                // 再存值并广播 —— 打开的文档收到通知立刻重渲染时，读到的已经是新明暗
                MarkdownAppearance.setMode(mode, settings: self.settings)
                // 按钮上的文字跟着换，整表刷新最省事（总共没几行）
                self.tableView.reloadData()
            }
        }
        return UIMenu(children: actions)
    }

    /// 「插入的图片存到哪儿」：一个按钮，点一下弹带对勾的菜单。
    private func makeImageInsertionModeCell() -> UITableViewCell {
        makeMenuCell(for: .imageInsertionMode,
                     title: settings.imageInsertionMode.displayName,
                     menu: makeImageInsertionMenu())
    }

    /// 「插入的图片文件叫什么名字」：同一套按钮 + 菜单，只有三项
    private func makeImageNameModeCell() -> UITableViewCell {
        makeMenuCell(for: .imageNameMode,
                     title: settings.imageNameMode.displayName,
                     menu: makeImageNameMenu())
    }

    /// 「按钮上写着当前选中项，点一下弹菜单」这种行的通用造法。
    ///
    /// ### 为什么这儿不用分段控件（上面几个「二选一」用的那种）
    /// 这些选项至少三项，名字还都不短（「复制到与笔记同名的文件夹」「使用文件 MD5 哈希」）——
    /// 平铺在一行里必被截成「复制…」，用户根本分不出哪个是哪个。
    /// 菜单是系统设置里处理「多项选一」的通用做法：点开一列、选中的打勾、一眼看全。
    private func makeMenuCell(for row: SettingsRow, title: String, menu: UIMenu) -> UITableViewCell {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.gray()
        config.title = title
        // 右边那个上下小箭头是个暗示：这玩意儿点得开
        config.image = UIImage(systemName: "chevron.up.chevron.down")
        config.imagePlacement = .trailing
        config.imagePadding = 8
        config.cornerStyle = .medium
        button.configuration = config
        button.contentHorizontalAlignment = .leading
        // 点按钮直接弹菜单（不用先长按）
        button.showsMenuAsPrimaryAction = true
        button.menu = menu
        button.accessibilityLabel = row.accessibilityLabel
        return makeCell(row: row, control: button)
    }

    /// 「存哪儿」那几项组成的菜单，当前选中的那一项打勾
    private func makeImageInsertionMenu() -> UIMenu {
        let current = settings.imageInsertionMode
        var modes = ImageInsertionMode.selectableCases
        // 当前这一项必须出现在菜单里 —— 否则按钮上写着 A、菜单里翻不到 A，用户会以为设置坏了。
        // 正常情况下它本来就在，只有「配置是在另一种设备上设的」（比如 Mac 上选了「指定路径」，
        // 配置文件同步到 iPhone）才会缺，补在最后
        if !modes.contains(current) { modes.append(current) }

        let actions = modes.map { mode in
            UIAction(title: mode.displayName,
                     state: mode == current ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.settings.setImageInsertionMode(mode)
                // 按钮上的文字和菜单里的对勾都要跟着换，整表刷新最省事（总共没几行）
                self.tableView.reloadData()
            }
        }
        return UIMenu(children: actions)
    }

    /// 「文件名怎么起」那三项组成的菜单，当前选中的那一项打勾
    private func makeImageNameMenu() -> UIMenu {
        let current = settings.imageNameMode
        let actions = ImageNameMode.allCases.map { mode in
            UIAction(title: mode.displayName,
                     state: mode == current ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.settings.setImageNameMode(mode)
                self.tableView.reloadData()
            }
        }
        return UIMenu(children: actions)
    }

    /// 「指定路径」那个文件夹：一个按钮，按钮上显示当前路径，点一下弹系统的文件夹选择框。
    ///
    /// ⚠️ 只有 Mac 上有这一行 —— 理由见 `ImageInsertionMode.selectableCases`
    private func makeImageFolderCell() -> UITableViewCell {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.gray()
        let path = settings.imageCustomFolderPath
        config.title = (path?.isEmpty == false) ? path : "选择文件夹…"
        config.image = UIImage(systemName: "folder")
        config.imagePlacement = .leading
        config.imagePadding = 8
        config.cornerStyle = .medium
        // 路径可能很长，从中间截断：开头留着磁盘 / 用户名，结尾留着文件夹名，中间那截最不重要
        config.titleLineBreakMode = .byTruncatingMiddle
        button.configuration = config
        button.contentHorizontalAlignment = .leading
        button.addTarget(self, action: #selector(chooseImageFolder), for: .touchUpInside)
        button.accessibilityLabel = SettingsRow.imageCustomFolderPath.accessibilityLabel
        return makeCell(row: .imageCustomFolderPath, control: button)
    }

    /// 弹系统的文件夹选择框。
    ///
    /// ### 用的是和导出同一块面板
    /// `UIDocumentPickerViewController(forOpeningContentTypes:asCopy:)` ——
    /// 导出落盘（`DocumentExporter.presentExportPicker`）用的就是这一块，
    /// 在 Mac 上呈现为原生的文件夹选择对话框：左边一列「位置」，右边列文件夹，选完点「打开」。
    /// 这里只是把「导出到某个文件」换成「打开某个文件夹」：`asCopy` 传 `false`，
    /// 因为我们要的是那个文件夹本身的地址，不是它的副本。
    @objc private func chooseImageFolder() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        present(picker, animated: true)
    }

    /// 「表格源码文字颜色」：一个色块 + 当前色号，点开菜单选色、或者交还给主题。
    ///
    /// ### 为什么不做成「点一下直接弹取色器」
    /// 这一项有个「没设过（跟随主题）」的状态，用户得能回到那个状态。
    /// 菜单里两项正好摆平：「选择颜色…」和「跟随主题」（当前是哪一种就打勾），
    /// 和上面「图片存放位置」那几行是同一套交互，用户不用再学一遍。
    private func makeTableSourceColorCell() -> UITableViewCell {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.gray()
        // 没覆盖过就写「跟随主题」—— 让用户一眼看出现在的色是从哪儿来的
        config.title = settings.tableSourceTextColorHex ?? "跟随主题"
        // 色块当图标：光看色号（#8e8e93）没有人能想象出颜色
        config.image = makeColorSwatch(settings.effectiveTableSourceTextColor)
        config.imagePlacement = .leading
        config.imagePadding = 8
        config.cornerStyle = .medium
        button.configuration = config
        button.contentHorizontalAlignment = .leading
        button.showsMenuAsPrimaryAction = true
        button.menu = makeTableSourceColorMenu()
        // 拖动取色器时要就地改这个按钮的色块（不重建单元格），靠 tag 找回来
        button.tag = Self.tableSourceColorButtonTag
        button.accessibilityLabel = SettingsRow.tableSourceTextColor.accessibilityLabel
        return makeCell(row: .tableSourceTextColor, control: button)
    }

    /// 「源码文字颜色」那两件事：选色 / 跟随主题
    private func makeTableSourceColorMenu() -> UIMenu {
        let hasOverride = settings.tableSourceTextColorHex != nil

        let pick = UIAction(title: "选择颜色…",
                            image: UIImage(systemName: "eyedropper")) { [weak self] _ in
            self?.presentTableSourceColorPicker()
        }
        let follow = UIAction(title: "跟随主题",
                              state: hasOverride ? .off : .on) { [weak self] _ in
            guard let self else { return }
            // 传 nil = 把覆盖清掉，下次套主题时又回到配色表给的那一色
            self.settings.setTableSourceTextColor(nil)
            self.tableView.reloadData()
        }
        return UIMenu(children: [pick, follow])
    }

    /// 弹系统的取色器。
    ///
    /// 和主题页「自己调色」用的是同一个控件（`UIColorPickerViewController`），
    /// 在 Mac 上是一块浮窗、在 iPhone 上是半屏弹层，两端都不用手写。
    private func presentTableSourceColorPicker() {
        let picker = UIColorPickerViewController()
        picker.delegate = self
        picker.title = SettingsRow.tableSourceTextColor.title
        // 允许带透明度：源码本来就是要「压淡」的，用户可能想让它更淡一点
        picker.supportsAlpha = true
        // 取色器一露面会先回调一次「现在这个色」，把它记下来当「没改过」的基准
        let current = settings.effectiveTableSourceTextColor
        picker.selectedColor = current
        tableSourceColorAtOpen = MarkdownHexColor.string(from: current)
        hasPickedTableSourceColor = false
        present(picker, animated: true)
    }

    /// 画一枚小圆色块，给颜色那一行当图标。
    ///
    /// ⚠️ 先把动态色按当前外观解析成实色再画：`.tertiaryLabel` 这类系统色直接 `cgColor`
    /// 拿到的是浅色模式下的值，深色模式下画出来会是一块偏黑的圆。
    ///
    /// ⚠️ 画完要 `.withRenderingMode(.alwaysOriginal)`：按钮会把默认渲染模式的图片
    /// 当成模板图整体染成系统蓝，那样色块就永远是蓝的、看不出自己挑了哪个色。
    private func makeColorSwatch(_ color: UIColor) -> UIImage {
        let side: CGFloat = 14
        let resolved = color.resolvedColor(with: traitCollection)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { context in
            context.cgContext.setFillColor(resolved.cgColor)
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// 把「表格源码文字颜色」那一行的色块和色号**就地**改掉。
    ///
    /// ⚠️ 只改这一个按钮，不走 `reloadData`：取色器正开着，重建整表会连带再算一次
    /// 「跟随主题时该显示哪一色」（那里面要读一次自定义配色文件），拖动时每回调一次就白读一遍。
    private func refreshTableSourceColorControl(color: UIColor, title: String) {
        guard let index = section.rows.firstIndex(of: .tableSourceTextColor) else { return }
        let path = IndexPath(row: index, section: 0)
        guard let cell = tableView.cellForRow(at: path),
              let button = cell.contentView.viewWithTag(Self.tableSourceColorButtonTag) as? UIButton
        else { return }

        // 明确取出来改完再写回：`configuration` 是结构体，直接改它的字段虽然也能生效，
        // 但写回来这一步更直白，以后换别人接手也不容易看漏
        var config = button.configuration ?? .gray()
        config.image = makeColorSwatch(color)
        config.title = title
        button.configuration = config
    }

    /// 攒下拖动中的颜色，手停 0.25 秒再写配置
    private func scheduleTableSourceColorCommit() {
        tableSourceColorCommitTimer?.invalidate()
        tableSourceColorCommitTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            self?.commitPendingTableSourceColor()
        }
    }

    /// 把攒着的那一色真正写进配置。
    ///
    /// ### 为什么要攒一下再写
    /// 每写一次配置都会广播「设置变了」，正文跟着整篇重渲染一遍。取色器拖动时一秒回调几十次，
    /// 次次重排的话手指底下会一顿一顿的。0.25 秒的停顿足够把一串回调并成一次。
    ///
    /// ### 为什么关闭取色器时还要再调一次
    /// 用户拖完常常直接点别处把浮窗关掉，最后一次回调可能才刚发生、定时器还没到点。
    /// 这里先落盘，颜色才不会「拖了但没生效」。
    private func commitPendingTableSourceColor() {
        tableSourceColorCommitTimer?.invalidate()
        tableSourceColorCommitTimer = nil
        guard let color = pendingTableSourceColor else { return }
        pendingTableSourceColor = nil
        settings.setTableSourceTextColor(color)
    }

    /// 数值行：左边滑块，右边当前值。
    ///
    /// 当前这一项在当前模式下不生效时，滑块置灰 —— 光看文字说明还不够直观，
    /// 灰掉的控件能把「现在调它没用」直接摆出来
    private func makeSliderCell(for row: SettingsRow) -> UITableViewCell {
        let slider = UISlider()
        slider.minimumValue = Float(row.sliderRange.lowerBound)
        slider.maximumValue = Float(row.sliderRange.upperBound)
        let value = row.currentValue(in: settings)
        slider.value = Float(value)
        // tag 记着「这是哪一行」，回调里靠它区分
        slider.tag = row.rawValue
        slider.isContinuous = true
        slider.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
        slider.accessibilityLabel = row.accessibilityLabel

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
    private func isEffective(_ row: SettingsRow) -> Bool {
        switch row {
        case .outlineWidthRatio: return settings.outlineWidthMode == .percentage
        case .outlineWidthPoints: return settings.outlineWidthMode == .fixedPoints
        case .outlineHeightRatio: return settings.outlineHeightMode == .percentage
        case .outlineMaximumHeight: return settings.outlineHeightMode == .maximumHeight
        case .imageWidthRatio: return settings.imageWidthMode == .percentage
        case .imageWidthPoints: return settings.imageWidthMode == .fixedPoints
        default: return true
        }
    }
}

// MARK: - 表格数据源 / 代理

extension SettingsPaneViewController: UITableViewDataSource, UITableViewDelegate {

    /// 永远只有一组：这一页就是一个分组，分组名由外面那层显示
    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection index: Int) -> Int {
        section.rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let row = row(at: indexPath) else { return UITableViewCell() }

        switch row {
        case .appearanceMode:
            return makeAppearanceModeCell()
        case .showsLineNumbers, .remembersScrollPosition, .pastesHTMLAsMarkdown,
             .savesWebImagesLocally,
             .showsQuoteBackground, .inlineCodeBacktickBackground, .outlineReservesSpace:
            return makeToggleCell(for: row)
        case .outlineWidthMode:
            return makeOutlineWidthModeCell()
        case .outlineHeightMode:
            return makeHeightModeCell()
        case .imageWidthMode:
            return makeImageWidthModeCell()
        case .imageInsertionMode:
            return makeImageInsertionModeCell()
        case .imageCustomFolderPath:
            return makeImageFolderCell()
        case .imageNameMode:
            return makeImageNameModeCell()
        case .tableSourceTextColor:
            return makeTableSourceColorCell()
        case .bodyFontSize, .lineHeightMultiple, .paragraphSpacing, .paragraphIndentCharacters,
             .bodyContentWidth, .bulletDiameter,
             .outlineWidthRatio, .outlineWidthPoints,
             .outlineHeightRatio, .outlineMaximumHeight, .outlineBackgroundOpacity,
             .tableMinColumnWidth, .tableMaxColumnWidth,
             .tableCellPaddingHorizontal, .tableCellPaddingVertical,
             .tableSourceFontSize,
             .imageWidthRatio, .imageWidthPoints, .imageMaxHeight:
            return makeSliderCell(for: row)
        }
    }

    /// 开关行照旧用系统的副标题单元格 + 右侧开关：
    /// 这是 iOS 设置页最标准的「标题 + 说明 + 开关在右边」的样子
    private func makeToggleCell(for row: SettingsRow) -> UITableViewCell {
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
        toggle.isOn = row.isOn(in: settings)
        toggle.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
        toggle.accessibilityLabel = row.accessibilityLabel
        cell.accessoryView = toggle

        return cell
    }

    /// 按位置找出是哪一行
    private func row(at indexPath: IndexPath) -> SettingsRow? {
        section.rows.indices.contains(indexPath.row) ? section.rows[indexPath.row] : nil
    }
}

// MARK: - 文件夹选择框的回调

extension SettingsPaneViewController: UIDocumentPickerDelegate {

    /// 用户挑好了一个文件夹：把路径记进配置，顺手把按钮上的文字换成新路径。
    ///
    /// ⚠️ 用户点了「取消」时这个方法不会被调用 —— 什么都不做就是「保持原来的路径」，
    /// 正是我们要的行为，不用额外处理。
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        settings.setImageCustomFolderPath(url.path)
        tableView.reloadData()
    }
}

// MARK: - 取色器的回调

extension SettingsPaneViewController: UIColorPickerViewControllerDelegate {

    /// 取色器里**拖色**的时候会一直回调：色块立刻跟着变，配置则等手停下来再写。
    ///
    /// ### 为什么不每回调一次就写配置
    /// 写一次配置就会广播「设置变了」，正文整篇重渲染一遍。拖动时一秒几十次回调，
    /// 次次重排的话手指底下会一顿一顿的 —— 所以这里只更新界面，真正的落盘交给 0.25 秒后的定时器。
    ///
    /// ### 为什么不干脆在这里什么都不做（以前就是这么写的）
    /// Mac 上的取色器是块浮窗，拖完直接点别处关掉很常见，那时候 `didFinish` 不一定来 ——
    /// 结果就是「颜色选了，但小色块和正文都没变」。现在拖动就更新色块、0.25 秒后落盘，
    /// 关不关浮窗都不影响。
    func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
        let picked = viewController.selectedColor
        let hex = MarkdownHexColor.string(from: picked)

        // 拖动时先把这一行的色块 / 色号改掉，让用户看到自己挑的是哪一色
        refreshTableSourceColorControl(color: picked, title: hex)

        // ⚠️ 取色器一露面就会回调一次「当前这个色」。不比对就照单全收的话，
        // 用户只是点进来看一眼，这一色也被记成「已改」——「跟随主题」就这么被悄悄换成了固定色
        if hex != tableSourceColorAtOpen {
            hasPickedTableSourceColor = true
        }
        guard hasPickedTableSourceColor else { return }

        pendingTableSourceColor = picked
        scheduleTableSourceColorCommit()
    }

    /// 取色器关掉（点完成、点外面、或者划走）：把最后一次颜色落地，再把整行刷成配置里的真值。
    ///
    /// `didFinish` 在 Mac Catalyst 上不保证每次都会来，所以真正的落盘逻辑在
    /// `commitPendingTableSourceColor` 里 —— 它也会被定时器和「离开这一页」调，
    /// 这里只是顺手再催一次（`pending` 为空时它什么都不做）。
    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        if hasPickedTableSourceColor {
            pendingTableSourceColor = viewController.selectedColor
        }
        commitPendingTableSourceColor()

        tableSourceColorAtOpen = nil
        hasPickedTableSourceColor = false
        // 走一遍数据源，按钮上的文字 / 色块和配置对齐（也把「跟随主题」状态显示对）
        tableView.reloadData()
    }
}
