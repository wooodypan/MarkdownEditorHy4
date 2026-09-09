//
//  FoldDisclosureAttachment.swift
//  MarkdownEditorHy4
//
//  顶层块左侧的「展开 / 折叠」小三角按钮
//

import UIKit

/// 每个顶层块第一行左侧的小三角。
///
/// ### 为什么用 attachment 而不是在上面盖 UIButton
/// 按钮必须**跟着它那一行的文字走**：用户改了上面的内容，整块往下移，按钮也要跟着移。
/// 在 UITextView 上盖 UIView 去追位置这条路已经证明走不通 —— TextKit 2 的
/// `NSTextLayoutFragment.layoutFragmentFrame` 对 viewport 之外的 fragment 永远是估算值，
/// 用 `setContentOffset` / `invalidateLayout` / `ensureLayout` / 离屏 NSLayoutManager
/// 都拿不到真实坐标（差 360+ 像素，引用块绿条那次踩过）。
/// 嵌进文本流当 attachment，位置由 TextKit 自己算，零测量成本。
///
/// ### 点击怎么接
/// attachment 只负责画，不接收事件（`isUserInteractionEnabled` 对它没意义）。
/// 真正的点击由 `MarkdownTextView` 上的 `UITapGestureRecognizer` 接：
/// 拿点击处的字符索引 → 看这一位是不是 `FoldDisclosureAttachment` → 是就切换折叠。
///
/// ### 三角的垂直位置（bounds.y = 0 的含义）
/// `NSTextAttachment.bounds` 的 y 相对**文本 baseline**，向上为正。
/// 设成 0 表示「图片的底边贴在 baseline 上」，所以图片内部：
/// - `y = 高度` 处是 baseline；
/// - `y = 高度 - capHeight / 2` 是文字（大写字母）的视觉中心。
/// 三角按这个中心对齐，看起来才是「和文字齐平」；直接按图片高度居中会明显偏高。
final class FoldDisclosureAttachment: NSTextAttachment {

    /// 这个按钮属于哪个顶层块。点击时靠它反查要折叠哪一块
    /// （块在编辑后会重新创建，所以这里存的是「创建时那一块」的 id，点一下就够用）。
    let blockID: UUID

    /// 当前是不是折叠状态：折叠画 ▶，展开画 ▼
    let isCollapsed: Bool

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释
    nonisolated deinit {}

    /// - parameter blockID:      所属块的 id
    /// - parameter isCollapsed:  当前折叠状态（决定三角朝向）
    /// - parameter side:         三角的边长（pt）
    /// - parameter trailingGap:  三角右边留出的空隙，省得和正文贴在一起
    /// - parameter color:        三角颜色
    /// - parameter font:         正文，用来算行高和「文字的视觉中心」
    init(blockID: UUID,
         isCollapsed: Bool,
         side: CGFloat,
         trailingGap: CGFloat,
         color: UIColor,
         font: UIFont) {
        self.blockID = blockID
        self.isCollapsed = isCollapsed
        super.init(data: nil, ofType: nil)

        let lineHeight = font.lineHeight
        // bounds 宽度 = 三角边长 + 右边空隙。三角因此会把它后面的正文整体往右推一点，
        // 视觉上就像「带折叠箭头的大纲」，这是刻意的效果。
        bounds = CGRect(x: 0, y: 0, width: side + trailingGap, height: lineHeight)
        image = Self.triangleImage(side: side,
                                   trailingGap: trailingGap,
                                   color: color,
                                   font: font,
                                   isCollapsed: isCollapsed)
    }

    required init?(coder: NSCoder) {
        fatalError("FoldDisclosureAttachment 不支持从 coder 解档")
    }

    private static func triangleImage(side: CGFloat,
                                      trailingGap: CGFloat,
                                      color: UIColor,
                                      font: UIFont,
                                      isCollapsed: Bool) -> UIImage {
        let size = CGSize(width: side + trailingGap, height: font.lineHeight)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            // 文字的视觉中心：baseline 在图片底部，大写字母高度的一半就是中心
            let centerY = font.lineHeight - font.capHeight / 2

            let path = UIBezierPath()
            if isCollapsed {
                // ▶ 向右：顶点在左，底边在右 —— 「点我展开」
                path.move(to: CGPoint(x: 1, y: centerY - side / 2))
                path.addLine(to: CGPoint(x: 1 + side, y: centerY))
                path.addLine(to: CGPoint(x: 1, y: centerY + side / 2))
            } else {
                // ▼ 向下：底边在上，顶点在下 —— 「点我折叠」
                path.move(to: CGPoint(x: 1, y: centerY - side / 2))
                path.addLine(to: CGPoint(x: 1 + side, y: centerY - side / 2))
                path.addLine(to: CGPoint(x: 1 + side / 2, y: centerY + side / 2))
            }
            path.close()
            color.setFill()
            path.fill()
        }
    }
}
