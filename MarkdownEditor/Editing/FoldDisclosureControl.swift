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
        for subview in subviews {
            // ⚠️ 这里**不能**先按 `subview.frame.contains(point)` 过滤一道：按钮允许把热区撑到 frame 外面 （见 `CollapsedSectionButton.point(inside:)`），先按 frame 过滤就把撑出来那圈又切掉了 —— 表现出来是「看着明明点在按钮上，却没反应」。改成直接问子视图自己。
            let local = convert(point, to: subview)
            guard subview.point(inside: local, with: event) else { continue }
            if let hit = subview.hitTest(local, with: event) { return hit }
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

/// 折叠标题后面那个「⋯」**本身**：一个固定高度的圆角矩形按钮。
///
/// ### 它和以前那个「透明热区」的区别
/// 以前那三个点由文本流里的 `CollapsedBlockAttachment` 画，按钮只是个盖在上面的透明热区。
/// 现在文本流里只留一个**什么也不画的座位**，三个点连同这个圆角框都归按钮画 —— 好处是「⋯」和框永远对得齐（两边各画一半就会有半个点的错位），框的粗细 / 圆角 / 颜色也只此一处。
/// 那个字符位还在、源码映射一个字没动，所以「全选复制 === 源文件」照样成立。
///
/// 位置由 `MarkdownTextView.positionFoldControls` 按座位的矩形摆（和复选框同一套机制）， 加在 `FoldControlLayer` 上（只有按钮吃点击，其余区域穿透给正文）。
final class CollapsedSectionButton: UIButton {

    /// 这个「⋯」属于哪个标题块（点它时靠它反查要展开哪一节）
    var sectionID: UUID?

    /// 圆角半径。
    ///
    /// ⚠️ 必须**小于高度的一半**（高度见 `MarkdownTheme.collapsedButtonHeight`，默认 20 → 上限 10）。
    /// 正好取一半的话两端就是两个半圆，形状成了胶囊，不是「圆角矩形」了。
    private static let cornerRadius: CGFloat = 6
    /// 描边粗细
    private static let borderWidth: CGFloat = 1.5
    /// 热区在框的四周各向外撑出多少（**负数 = 向外**）。
    ///
    /// 框只有 20 点高，正好按着框点太考验准头，所以下右各撑 10 点。
    /// ⚠️ 左边只撑 4 点：座位紧贴在标题文字最后面，左边撑多了会把「点最后一个字放光标」也抢走。
    /// ⚠️ 上方撑 6 点就够：按钮现在是**底边贴基线**摆的，框顶已经贴近标题字迹，
    ///    上边再撑多就是把「点这行文字放光标」从正文手里抢走。
    ///
    /// ⚠️ 也不许靠放大 `frame` 来撑热区 —— 这个按钮自己就是画出来的那个框，`frame` 一放大框也跟着变大。
    private static let hitOutset = UIEdgeInsets(top: -6, left: -4, bottom: -10, right: -10)
    /// 「⋯」的字号。比正文小一点，三个点才不会在 20 点高的框里顶到上下边
    private static let titlePointSize: CGFloat = 13

    /// 描边色 / 文字色。用主题里那个「折叠占位色」，浅色深色两套自动跟着走
    private let strokeColor: UIColor

    /// - parameter strokeColor: 框和「⋯」的颜色，从主题来
    init(strokeColor: UIColor) {
        self.strokeColor = strokeColor
        super.init(frame: .zero)

        setTitle("⋯", for: .normal)
        setTitleColor(strokeColor, for: .normal)
        titleLabel?.font = .systemFont(ofSize: Self.titlePointSize, weight: .semibold)
        backgroundColor = .clear
        layer.cornerRadius = Self.cornerRadius
        layer.borderWidth = Self.borderWidth
        accessibilityLabel = "展开被折叠的内容"
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("CollapsedSectionButton 不支持从 coder 解档")
    }

    /// 描边色在这里赋，而不是在 `init` 里赋一次就完。
    ///
    /// ⚠️ 动态色（`.tertiaryLabel` 这类）的 `cgColor` 会把**赋值那一刻的外观定住**：
    /// 浅色下画好，用户切到深色不会自己变，那条框会一直挂着浅色模式的灰。
    /// `CALayer` 不认识动态色、只能吃解析好的 `cgColor`，所以换外观时得再解析一次。
    /// 放 `layoutSubviews` 里最省事 —— 系统换外观一定会走一遍布局。
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.borderColor = strokeColor.resolvedColor(with: traitCollection).cgColor
    }

    /// 热区比画出来的框大一圈（见 `hitOutset`）。
    ///
    /// ⚠️ 这里必须把 `isUserInteractionEnabled / isHidden / alpha` 一并判掉：
    /// 父层 `FoldControlLayer.hitTest` 现在直接问这个方法、不再自己按 frame 过滤， 少了这几个判断的话，一个隐藏掉的按钮也会把点击吃走。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return false }
        return bounds.inset(by: Self.hitOutset).contains(point)
    }
}
