//
//  DocumentListCell.swift
//  MarkdownEditorHy4
//
//  左栏列表的一行：文件名、浅灰的预览、修改日期，三行字摞在一起。
//

import UIKit

/// 「文档」那一页列表里的一行。
///
/// ### 为什么要自己写一个 cell
/// 系统那个 `UIListContentConfiguration` 只有两个文字位（`text` 和 `secondaryText`），而这一行要放三行字（文件名、预览、修改日期），它塞不下。
/// 自己搭一个虽然多写几行约束，但布局完全看得见、也好改。
final class DocumentListCell: UITableViewCell {

    /// 第一行：文件名（已经去掉扩展名）
    private let nameLabel = UILabel()

    /// 第二行：浅灰的预览 —— 文档的首行内容，一行放不下就从**尾巴**省略
    private let previewLabel = UILabel()

    /// 第三行：文件的修改日期
    private let dateLabel = UILabel()

    /// 最左边那个小图标
    private let iconView = UIImageView(image: UIImage(systemName: "doc.text"))

    /// 取不到预览内容（空文档、或者整份都是空行）时顶在这儿的话。
    ///
    /// 不这么做的话那一行会是一片空白，看着像布局坏了 —— 空白和「空文档」得能分得出来。
    static let emptyPreviewText = "空文档"

    /// 日期怎么显示。
    ///
    /// 抽成 `static` 是为了**整个列表共用一份** —— `DateFormatter` 造一次挺贵，每个 cell 造一个会拖慢滚动。
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // short / short 是「跟着系统的地区语言走」的格式，中文下大概是「2026/9/29 01:07」
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - 生命周期

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("DocumentListCell 不支持从 coder 解档")
    }

    // MARK: - 填内容

    /// 把一行的内容填进去。
    ///
    /// - Parameters:
    ///   - name: 文件名（已经去掉扩展名）
    ///   - preview: 预览文字。传空串会显示「空文档」
    ///   - date: 修改日期。取不到时传 nil，那一行日期会整行收掉
    func configure(name: String, preview: String, date: Date?) {
        nameLabel.text = name
        previewLabel.text = preview.isEmpty ? Self.emptyPreviewText : preview

        if let date {
            dateLabel.text = Self.dateFormatter.string(from: date)
            dateLabel.isHidden = false
        } else {
            // 日期取不到（文件刚被删、没权限）就把这一行收掉，别留一行空白。
            // 栈视图里把 arrangedSubview 设成 isHidden，它占的那块高度会自动让出来
            dateLabel.text = nil
            dateLabel.isHidden = true
        }
    }

    // MARK: - 界面

    private func setupSubviews() {
        // 三行字竖着摞起来。用栈视图是为了省掉「每行各写四条约束、还得互相接上」那堆代码
        let textStack = UIStackView(arrangedSubviews: [nameLabel, previewLabel, dateLabel])
        textStack.axis = .vertical
        // 行间只留 1 点：文字本身的行高已经把间隔撑出来了，再大会显得散
        textStack.spacing = 1
        textStack.alignment = .fill
        textStack.translatesAutoresizingMaskIntoConstraints = false

        applyFont(style: .body, color: .label, to: nameLabel)
        applyFont(style: .subheadline, color: .secondaryLabel, to: previewLabel)
        applyFont(style: .caption1, color: .tertiaryLabel, to: dateLabel)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        // 图标用浅灰：它只是个提示，不该比文件名更抢眼
        iconView.tintColor = .secondaryLabel

        contentView.addSubview(iconView)
        contentView.addSubview(textStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            // 上下各留 8 点：cell 的高度就是「三行字 + 16」，交给系统的自适应行高去算
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])
    }

    /// 三个标签长得差不多，只有字号和颜色不一样 —— 一起配一下，省得抄三遍。
    ///
    /// - Parameters:
    ///   - style: 系统的文字样式，它自带字号和行高，并会跟着「设置 → 显示与亮度 → 文字大小」变
    ///   - color: 文字颜色
    ///   - label: 要配的那个标签
    private func applyFont(style: UIFont.TextStyle, color: UIColor, to label: UILabel) {
        label.font = .preferredFont(forTextStyle: style)
        // 跟着系统的文字大小设置一起缩放，用户调大了不会挤成一团
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 1
        // 一行放不下就从尾巴省略 —— 前面的内容才有用，而且这样才会显示「…」
        label.lineBreakMode = .byTruncatingTail
    }
}
