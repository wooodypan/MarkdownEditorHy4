//
//  SettingsListViewController.swift
//  MarkdownEditorHy4
//
//  设置页的「目录」：把七个分组列成一张表，点一行 push 进那一组的面板。
//
//  这一条路是 iPhone / iPad 走的。Mac 上对应的东西是 `SettingsSplitViewController` 左边的侧边栏 —— 两边读的是同一份 `SettingsSection.allCases`，只是长得不一样：这边是「列表 → 推下一页」，那边是「分栏，换右边的内容」。
//  之所以不共用一套：手机上左右分栏放不下（375 点宽的屏幕切两半，两边都不够用），而 Mac 上既然窗口够宽，就该照系统偏好设置那样「左边一直看得见」，省掉一次返回。
//

import UIKit

/// 设置页的目录（列表）。
///
/// ### 为什么用 `UITableView` 而不是 `UICollectionView` 的 sidebar 样式
/// 手机上要的是 iOS 设置那种「一行一个分组、点进去」的列表：`UITableView` 的 `.insetGrouped` 就是为它准备的，分隔线、圆角卡片、动态字号全都不用自己管。sidebar 那种样式是给 Mac 侧边栏用的（见 `SettingsSplitViewController`）。
final class SettingsListViewController: UIViewController {

    // MARK: 依赖

    /// 读 / 写这份配置。这一页自己不写配置，只是转交给下一层面板 —— 留着是为了建面板时传下去
    private let settings: MarkdownEditorSettings

    /// 目录里的分组，顺序就是 `SettingsSection` 里声明的顺序（改顺序去那个枚举里改）
    private let sections = SettingsSection.allCases

    // MARK: 控件

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    private static let cellID = "settingsSectionCell"

    init(settings: MarkdownEditorSettings = .shared) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
        title = "设置"
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsListViewController 不支持从 coder 解档")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        // 大标题：一屏目录用大标题最像系统设置页
        navigationItem.largeTitleDisplayMode = .always
        // 右上角「完成」：这一页现在只有「模态弹出」这一条路（都从 `SettingsOpener` 进来，见那边 `presentAsModal` 的注释），所以按钮常驻。
        // 哪天它被 push 进某个导航栈了，这里得改成按 `presentingViewController` 判断
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                            target: self,
                                                            action: #selector(closeSelf))

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func closeSelf() {
        dismiss(animated: true)
    }
}

// MARK: - 表格

extension SettingsListViewController: UITableViewDataSource, UITableViewDelegate {

    /// 只有一组：七个分组平铺在一张卡里，和 iOS 设置首页一个样
    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: Self.cellID)

        guard sections.indices.contains(indexPath.row) else { return cell }
        let section = sections[indexPath.row]

        // 内容配置走系统的 `contentConfiguration`：自带多行副标题排版，跟着动态字号和深色模式走
        var content = UIListContentConfiguration.subtitleCell()
        content.text = section.title
        content.secondaryText = section.summary
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        // 图标画不出来时 `image` 是 nil，系统会自己把左边空出来，不会挤压文字
        content.image = UIImage(systemName: section.iconName)
        cell.contentConfiguration = content

        cell.accessoryType = .disclosureIndicator
        // 可见标题就是分组名，已经够唯一；单测按标识找控件时也认它
        cell.accessibilityLabel = section.title
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard sections.indices.contains(indexPath.row) else { return }
        let pane = SettingsPaneViewController(section: sections[indexPath.row], settings: settings)
        navigationController?.pushViewController(pane, animated: true)
    }
}
