//
//  DocumentVersionPreviewController.swift
//  MarkdownEditorHy4
//
//  某一版历史的预览页：上面切换「这一版内容 / 和现在对比」，下面显示原文或者对比结果。
//
//  大白话：像看校对稿——想知道当时原文长什么样就切左边，想知道"点恢复会改掉什么"就切右边。
//
//  ### 颜色的含义（用户在历史页点某一版时最关心的两件事）
//  - 绿色：这一版有、编辑器里现在没有，恢复之后会加进来；
//  - 红色：编辑器里现在有、这一版没有，恢复之后会消失。
//
//  ### 为什么对比结果放在表格里，不塞进一个 UITextView
//  整行铺底色要铺到行尾、折叠条要能点开，这两件事用文字视图都得自己做命中测试；
//  表格天生一行一个格子，行高还会自己算，反而更省事。
//

import UIKit

/// 预览一份「准备替换掉编辑器里现有内容」的文字。
///
/// 两个地方用它：翻历史版本（点「恢复」）、格式化文档（点「应用」）。
/// 除了标题和按钮上的字，两边要做的事一模一样——所以做成同一个页面，文案当参数传进来。
final class DocumentVersionPreviewController: UIViewController {

    /// 用户点了右上角那个按钮（恢复 / 应用）。真正的确认框在上一页弹，这里只负责把话传出去
    var onConfirm: (() -> Void)?

    /// 页面标题
    private let titleText: String
    /// 准备用的这份正文
    private let versionContent: String
    /// 编辑器里此刻的正文，也就是确认之后会被覆盖掉的那一份
    private let currentContent: String
    /// 顶部左半边那个切换按钮上写什么
    private let contentLabel: String
    /// 右上角按钮和提示文案里用哪个动词（"恢复" / "应用"）
    private let actionName: String

    /// 对比放在后台算：几千行的文档在主线程算会卡住界面
    private let diffQueue = DispatchQueue(label: "MarkdownEditorHy4.text-diff", qos: .userInitiated)

    private lazy var modeControl = UISegmentedControl(items: [contentLabel, "和现在对比"])
    private let summaryLabel = UILabel()
    private let container = UIView()
    private let textView = UITextView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let spinner = UIActivityIndicatorView(style: .medium)

    /// 完整的对比结果（含被折叠起来的行）
    private var diffLines: [DiffLine] = []
    /// 表格真正要显示的行：改动附近的行 + 折叠条
    private var displayRows: [DiffDisplayRow] = []
    /// 用户点开过的折叠段，记的是那一段第一行的下标
    private var expandedGaps: Set<Int> = []
    /// 后台算完了没有。没算完时先显示"正在对比…"
    private var isDiffReady = false

    init(titleText: String,
         content: String,
         currentContent: String,
         contentLabel: String = "这一版内容",
         actionName: String = "恢复") {
        self.titleText = titleText
        self.versionContent = content
        self.currentContent = currentContent
        self.contentLabel = contentLabel
        self.actionName = actionName
        super.init(nibName: nil, bundle: nil)
    }

    /// 从历史列表点进来的那条路。
    ///
    /// 标题用「什么时候存的」：列表页已经把原因（自动存档 / 手动保存）显示过了，进来看时间更有用。
    convenience init(version: DocumentVersion, content: String, currentContent: String) {
        self.init(titleText: DocumentHistoryViewController.dateFormatter.string(from: version.createdAt),
                  content: content,
                  currentContent: currentContent)
    }

    required init?(coder: NSCoder) {
        fatalError("DocumentVersionPreviewController 不支持从 coder 解档")
    }

    /// 原因见 `MarkdownBlock` / `OutlineCoordinator` 里 `nonisolated deinit` 那段长注释。
    nonisolated deinit {}

    override func viewDidLoad() {
        super.viewDidLoad()
        // 标题由调用方定：历史那条路是"什么时候存的"，格式化那条路是"格式化预览"
        title = titleText
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: actionName,
                                                            style: .plain,
                                                            target: self,
                                                            action: #selector(confirmTapped))

        configureSubviews()
        updateSummary()
        startDiff()
    }

    private func configureSubviews() {
        // 默认停在对比上：用户点进历史版本，八成是想知道"这一版和现在差在哪"
        modeControl.selectedSegmentIndex = 1
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabel
        summaryLabel.numberOfLines = 0

        let header = UIStackView(arrangedSubviews: [modeControl, summaryLabel])
        header.axis = .vertical
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        container.translatesAutoresizingMaskIntoConstraints = false

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.text = versionContent
        // 只读：这一页是"看看以前长什么样"，顺手改两笔再恢复，容易搞混改的到底是哪一版
        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.isHidden = true

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 22
        tableView.separatorStyle = .none
        tableView.backgroundColor = .systemBackground
        tableView.register(DiffLineCell.self, forCellReuseIdentifier: DiffLineCell.reuseIdentifier)
        tableView.register(DiffGapCell.self, forCellReuseIdentifier: DiffGapCell.reuseIdentifier)

        container.addSubview(textView)
        container.addSubview(tableView)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true

        view.addSubview(header)
        view.addSubview(container)
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            container.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            textView.topAnchor.constraint(equalTo: container.topAnchor),
            textView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            tableView.topAnchor.constraint(equalTo: container.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    // MARK: 对比

    /// 让后台开始算，算完回主线程刷新。
    private func startDiff() {
        let current = currentContent
        let versionText = versionContent

        // 转圈晚 0.15 秒再出现：大多数文档几毫秒就算完了，立刻转一下再停掉反而闪眼睛
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.isDiffReady else { return }
            self.spinner.startAnimating()
        }

        diffQueue.async { [weak self] in
            let lines = TextDiff.diff(current: current, version: versionText)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isDiffReady = true
                self.spinner.stopAnimating()
                self.diffLines = lines
                self.rebuildDisplayRows()
                self.updateSummary()
                self.tableView.reloadData()
            }
        }
    }

    /// 按"哪些折叠段被点开过"重新拼一遍要显示的行
    private func rebuildDisplayRows() {
        let addedCount = diffLines.filter { $0.kind == .added }.count
        let removedCount = diffLines.filter { $0.kind == .removed }.count

        guard addedCount > 0 || removedCount > 0 else {
            // 一模一样：一行都没改，折叠起来也只是一条"中间 N 行没动"，不如直接说清楚
            displayRows = []
            tableView.backgroundView = makeEmptyStateLabel("这一版和编辑器里现在的内容完全一样，没有可对比的差异。")
            return
        }

        displayRows = TextDiff.displayRows(diffLines, expandedGaps: expandedGaps)
        tableView.backgroundView = nil
    }

    private func updateSummary() {
        guard isDiffReady else {
            summaryLabel.text = "正在对比…"
            return
        }
        let addedCount = diffLines.filter { $0.kind == .added }.count
        let removedCount = diffLines.filter { $0.kind == .removed }.count
        guard addedCount > 0 || removedCount > 0 else {
            summaryLabel.text = "和现在的内容没有差别。"
            return
        }
        summaryLabel.text = "\(actionName)后：绿色 \(addedCount) 行会加进来，红色 \(removedCount) 行会消失。"
    }

    private func makeEmptyStateLabel(_ text: String) -> UIView {
        let holder = UIView()
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -32),
            label.centerYAnchor.constraint(equalTo: holder.centerYAnchor)
        ])
        return holder
    }

    @objc private func modeChanged() {
        // 第 0 段是原文、第 1 段是对比
        let showingDiff = modeControl.selectedSegmentIndex == 1
        textView.isHidden = showingDiff
        tableView.isHidden = !showingDiff
        summaryLabel.isHidden = !showingDiff
    }

    @objc private func confirmTapped() {
        onConfirm?()
    }
}

// MARK: - 对比列表

extension DocumentVersionPreviewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        displayRows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch displayRows[indexPath.row] {
        case .line(let line):
            let cell = tableView.dequeueReusableCell(withIdentifier: DiffLineCell.reuseIdentifier,
                                                     for: indexPath) as! DiffLineCell
            cell.configure(with: line)
            return cell
        case .gap(let count, _):
            let cell = tableView.dequeueReusableCell(withIdentifier: DiffGapCell.reuseIdentifier,
                                                     for: indexPath) as! DiffGapCell
            cell.configure(hiddenLineCount: count)
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case .gap(_, let start) = displayRows[indexPath.row] else { return }
        expandedGaps.insert(start)
        rebuildDisplayRows()
        tableView.reloadData()
    }
}

// MARK: - 一行字

/// 对比里的一行文字：左边一个 + 或 −，右边是内容，整行铺一层浅色。
private final class DiffLineCell: UITableViewCell {

    static let reuseIdentifier = "DiffLineCell"

    /// 整行底色。透明度压得比较低，是为了让上面的黑字照样看得清
    private static let addedBackground = UIColor.systemGreen.withAlphaComponent(0.16)
    private static let removedBackground = UIColor.systemRed.withAlphaComponent(0.16)
    /// 行内那几个字再压深一层，长段落里一眼能找到改动点
    private static let addedHighlight = UIColor.systemGreen.withAlphaComponent(0.42)
    private static let removedHighlight = UIColor.systemRed.withAlphaComponent(0.42)

    private let signLabel = UILabel()
    private let contentLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        // 对比行不是按钮，点上去不该闪一下
        selectionStyle = .none

        signLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        signLabel.textAlignment = .center
        signLabel.setContentHuggingPriority(.required, for: .horizontal)
        signLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        contentLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        contentLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [signLabel, contentLabel])
        stack.axis = .horizontal
        stack.alignment = .top
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            signLabel.widthAnchor.constraint(equalToConstant: 12),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("DiffLineCell 不支持从 coder 解档")
    }

    func configure(with line: DiffLine) {
        // 空行也得占一行的高度，给个空格撑住
        let visibleText = line.text.isEmpty ? " " : line.text

        switch line.kind {
        case .same:
            contentView.backgroundColor = .clear
            signLabel.text = " "
            signLabel.textColor = .tertiaryLabel
            contentLabel.attributedText = nil
            contentLabel.textColor = .label
            contentLabel.text = visibleText

        case .added:
            contentView.backgroundColor = Self.addedBackground
            signLabel.text = "+"
            signLabel.textColor = .systemGreen
            contentLabel.text = nil
            contentLabel.attributedText = Self.attributedText(for: line,
                                                              font: contentLabel.font,
                                                              highlight: Self.addedHighlight)

        case .removed:
            contentView.backgroundColor = Self.removedBackground
            signLabel.text = "−"
            signLabel.textColor = .systemRed
            contentLabel.text = nil
            contentLabel.attributedText = Self.attributedText(for: line,
                                                              font: contentLabel.font,
                                                              highlight: Self.removedHighlight)
        }
    }

    /// 把"哪几个字变了"翻译成文字上的深色底。
    private static func attributedText(for line: DiffLine,
                                       font: UIFont,
                                       highlight: UIColor) -> NSAttributedString {
        let text = line.text.isEmpty ? " " : line.text
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: UIColor.label
            ])

        for range in line.highlight {
            guard let nsRange = NSRange(range, in: text) else { continue }
            attributed.addAttribute(.backgroundColor, value: highlight, range: nsRange)
        }
        return attributed
    }
}

// MARK: - 折叠条

/// "中间有 N 行没改"那一条，点一下展开。
private final class DiffGapCell: UITableViewCell {

    static let reuseIdentifier = "DiffGapCell"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .secondarySystemBackground
        textLabel?.font = .systemFont(ofSize: 12)
        textLabel?.textColor = .secondaryLabel
        textLabel?.textAlignment = .center
        textLabel?.numberOfLines = 0
    }

    required init?(coder: NSCoder) {
        fatalError("DiffGapCell 不支持从 coder 解档")
    }

    func configure(hiddenLineCount: Int) {
        textLabel?.text = "⋯ 中间 \(hiddenLineCount) 行没有改动，点一下展开"
    }
}

// MARK: - 字符下标换文字范围

private extension NSRange {

    /// 把"第几个字到第几个字"换成文字视图认识的范围。
    ///
    /// `TextDiff` 数的是"第几个字"（一个汉字算一个），而文字系统数的是 UTF-16 单元，碰到表情符号这类占两个单元的字符，两边就对不上了，所以必须走这个换算。
    init?(_ characterRange: Range<Int>, in text: String) {
        guard characterRange.lowerBound >= 0,
              characterRange.upperBound <= text.count else { return nil }
        let start = text.index(text.startIndex, offsetBy: characterRange.lowerBound)
        let end = text.index(start, offsetBy: characterRange.count)
        self.init(start..<end, in: text)
    }
}
