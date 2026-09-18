//
//  FoldDisclosureControl.swift
//  MarkdownEditorHy4
//
//  顶层块左侧的「展开 / 折叠」小三角：浮在正文左边装订线里的按钮
//

import UIKit

/// 折叠三角所在的控件层：加在 UITextView **最上层**，只让三角按钮吃点击。
///
/// 和 `CodeBlockControlLayer` 是同一套机制 —— 除了按钮之外的区域一律穿透，
/// 否则会挡住正文的点击和光标定位。
final class FoldControlLayer: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for subview in subviews where subview.frame.contains(point) {
            if let hit = subview.hitTest(convert(point, to: subview), with: event) { return hit }
        }
        return nil
    }
}

/// 一个标题左侧的展开 / 折叠三角。
///
/// ### 为什么不放在文本流里当 attachment
/// attachment 占一个字符位，会把块的第一行朝右推，而第二行、第三行还按原来的缩进排 ——
/// 多行的左边缘就对不齐了。放在这一层之后文本流一个多余字符都没有，
/// 多行**天然左对齐**，三角只是浮在正文左边的装订线（gutter）里。
///
/// ### 位置怎么来
/// 由 `MarkdownTextView` 每次布局 / 滚动时按锚点字符的 fragment 位置摆一次，
/// 和代码块复制按钮完全一样。
final class FoldDisclosureButton: UIButton {

    /// 这个三角属于哪个块、当前什么状态（点击时从这里取）
    var anchor: FoldAnchorInfo?

    /// 图标边长（和按钮同宽，视觉上三角占满整个热区）
    private static let symbolPointSize: CGFloat = 11

    init() {
        super.init(frame: .zero)

        // 用系统的 chevron 形状：折叠（▶ 朝右）表示「点开」，展开（▼ 朝下）表示「收起」，
        // 和大纲类 App 的习惯一致，比自己画实心三角更轻、更不容易和正文抢注意力。
        let configuration = UIImage.SymbolConfiguration(pointSize: Self.symbolPointSize,
                                                        weight: .bold)
        setImage(UIImage(systemName: "chevron.right", withConfiguration: configuration),
                 for: .normal)
        tintColor = .tertiaryLabel

        backgroundColor = .clear
        accessibilityLabel = "折叠或展开这一段"
    }

    required init?(coder: NSCoder) {
        fatalError("FoldDisclosureButton 不支持从 coder 解档")
    }

    /// 按折叠状态换图标
    func apply(isCollapsed: Bool) {
        let configuration = UIImage.SymbolConfiguration(pointSize: Self.symbolPointSize,
                                                        weight: .bold)
        let name = isCollapsed ? "chevron.right" : "chevron.down"
        setImage(UIImage(systemName: name, withConfiguration: configuration), for: .normal)
        accessibilityValue = isCollapsed ? "已折叠" : "已展开"
    }
}

/// 折叠标题后面那个「⋯」占位符的**点击热区**。
///
/// ### 为什么按钮是「透明」的
/// 「⋯」这三个点是由文本流里的 `CollapsedBlockAttachment` 画出来的（它占 1 个字符位，
/// 这样「全选复制 === 源文件」才成立）。按钮只是**盖在它上面**接点击，
/// 自己什么都不画 —— 画面上看到的仍然是文本流里那个「⋯」。
///
/// 和复选框用的是同一套机制：位置由 `MarkdownTextView` 按字符矩形摆，
/// 加在 `FoldControlLayer` 上（只有按钮吃点击，其余区域穿透给正文）。
final class CollapsedSectionButton: UIButton {

    /// 这个「⋯」属于哪个标题块（点它时靠它反查要展开哪一节）
    var sectionID: UUID?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        accessibilityLabel = "展开被折叠的内容"
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("CollapsedSectionButton 不支持从 coder 解档")
    }
}
