//
//  CheckboxControl.swift
//  MarkdownEditorHy4
//
//  任务列表的复选框：浮在 `[x]` / `[ ]` 旁边的原生 UIButton
//

import UIKit

/// 复选框所在的控件层：加在 UITextView **最上层**，只让按钮自己吃点击。
///
/// 和 `FoldControlLayer`、`CodeBlockControlLayer` 是同一套机制 —— 除了按钮之外的
/// 区域一律穿透，否则会挡住正文的点击和光标定位。
final class CheckboxLayer: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for subview in subviews where subview.frame.contains(point) {
            if let hit = subview.hitTest(convert(point, to: subview), with: event) { return hit }
        }
        return nil
    }
}

/// 一个任务列表项的复选框。
///
/// ### 为什么不放在文本流里当 attachment
/// 和折叠三角是同一个理由：attachment 占字符位，会把行首往右推；
/// 而且 `NSTextAttachmentViewProvider` 有「整篇替换后 view 消失、loadView 不再回调」的坑
/// （见 `ImageAttachment` 的注释）。放在这一层之后文本流一个多余字符都没有，
/// `[x]` 源码照常显示，复选框只是浮在它旁边 / 上面。
///
/// ### 位置怎么来
/// 由 `MarkdownTextView` 每次布局 / 滚动时按 `.markdownCheckbox` 标记那三个字符的
/// 矩形摆一次，和折叠三角、代码块复制按钮完全一样。
final class MarkdownCheckboxButton: UIButton {

    /// 这个复选框对应源码里的哪个 `[x]` / `[ ]`（点击时靠它改源码）
    var checkbox: CheckboxInfo?

    /// 方框边长（对勾的笔画粗细、四周留白都按它等比算）
    private let side: CGFloat

    init(side: CGFloat) {
        self.side = side
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        layer.cornerRadius = side / 4
        backgroundColor = .clear
        // 点下去时整块高亮一下，给用户「点到了」的反馈
        adjustsImageWhenHighlighted = true
        accessibilityLabel = "切换任务完成状态"
    }

    required init?(coder: NSCoder) {
        fatalError("MarkdownCheckboxButton 不支持从 coder 解档")
    }

    /// 按勾选状态重画外观。
    ///
    /// - parameter isChecked: 是不是 `[x]`
    /// - parameter theme:     样式表（颜色都从它来）
    /// - parameter covers:    true 表示要**盖住**底下的 `[x]` 文字，
    ///                        这时未勾选的底色必须是不透明的，否则会透出 `[ ]`
    func apply(isChecked: Bool, theme: MarkdownTheme, covers: Bool) {
        let style = theme.taskList
        layer.borderWidth = style.borderWidth
        layer.cornerRadius = style.cornerRadius

        if isChecked {
            backgroundColor = style.checkedColor
            layer.borderColor = style.checkedColor.cgColor
            // 颜色仍走 tintColor（对勾是模板图）；形状和尺寸由我们自己画，不看系统脸色
            tintColor = style.checkmarkColor
            setImage(checkmarkImage, for: .normal)
        } else {
            // 盖住模式用不透明底色挡住底下的 `[ ]`；不盖住模式保持透明，
            // 免得在源码旁边挖出一个白方块
            backgroundColor = covers ? .systemBackground : style.uncheckedFillColor
            layer.borderColor = style.uncheckedBorderColor.cgColor
            setImage(nil, for: .normal)
        }
        accessibilityValue = isChecked ? "已完成" : "未完成"
    }

    // MARK: 对勾（自己画，不用 SF Symbol）

    /// 对勾图：尺寸只跟方框边长有关。
    ///
    /// ### 为什么不用 `UIImage(systemName: "checkmark")`
    /// SF Symbol 的大小由 `configuration.pointSize` 定死，**和方框边长没有关系** —— 而方框边长是主题里可配的（`taskList.checkboxSide`）。符号不会跟着方框变，只能写一个「凑出来正好」的 pointSize 去碰运气；系统换一套符号度量就偏了。这里按边长算出笔画粗细和四周留白、画进一张 `side × side` 的图，「对勾比方框小一圈、永远居中」由代码保证，不依赖任何外部度量。
    ///
    /// 画成黑色 + 模板模式：颜色照旧由 `tintColor`（主题的 `checkmarkColor`）决定。
    private lazy var checkmarkImage = MarkdownCheckboxButton.makeCheckmarkImage(side: side)

    private static func makeCheckmarkImage(side: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { _ in
            // 笔画粗细和留白都按边长等比给：方框变大，对勾跟着变大
            let lineWidth = max(1, side * 0.14)
            let inset = side * 0.26

            let path = UIBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            // 一个普通的对勾：左边起笔偏下 → 下方折点 → 右边收笔偏上
            path.move(to: CGPoint(x: inset, y: side * 0.53))
            path.addLine(to: CGPoint(x: side * 0.42, y: side - inset))
            path.addLine(to: CGPoint(x: side - inset, y: inset))
            UIColor.black.setStroke()
            path.stroke()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}
