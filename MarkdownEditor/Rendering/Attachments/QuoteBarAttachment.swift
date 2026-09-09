//
//  QuoteBarAttachment.swift
//  MarkdownEditorHy4
//
//  引用块的左侧绿条 attachment：每行一个，跟随该行 layout
//

import UIKit

/// 引用块的左侧绿条（3pt 宽，跟随行高）。
///
/// ### 为什么不靠 UIView 跨行画
/// `NSTextAttachment` 只占 1 个字符位，没法画跨多行的竖条；
/// UITextView 上面盖 UIView 测 fragment 位置又拿不到 viewport 外的真实 y
/// （TextKit 2 的 `layoutFragmentFrame` 对 viewport 外的 fragment 永远是估算值，
/// 用 `setContentOffset` / `invalidateLayout` / `ensureLayout` 都没用）。
/// 唯一稳的办法：让绿条作为 attachment 嵌进文本流，**每行一个**，由 NSTextAttachment 自己
/// 跟该行 layout 走，零测量成本。
///
/// ### 行间为什么有 6pt 间隙
/// attachment 的高度等于一行 line height（28pt 左右），而段前 / 段后距（`paragraphSpacing` = 6pt）
/// 不属于本行 line height，所以**两行之间会留出 6pt 缝隙**。
/// 视觉上像「虚线绿条」，但每个绿条都贴在 `>` 左边，不影响识别引用块。
final class QuoteBarAttachment: NSTextAttachment {

    /// 颜色（绿条的具体绿色，在 init 时从 theme 拿过来）
    let color: UIColor

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释
    nonisolated deinit {}

    init(width: CGFloat, height: CGFloat, color: UIColor) {
        self.color = color
        super.init(data: nil, ofType: nil)

        // bounds.y 相对文本 baseline，向上为正。要让绿条「贴在本行」，
        // 让它的顶部对齐 line height 顶部：y = lineHeight - 高度
        // 这样绿条底端和本行 baseline 对齐，视觉上紧贴 `>` 文字
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        image = Self.barImage(width: width, height: height, color: color)
    }

    required init?(coder: NSCoder) {
        fatalError("QuoteBarAttachment 不支持从 coder 解档")
    }

    private static func barImage(width: CGFloat, height: CGFloat, color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { _ in
            color.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}
