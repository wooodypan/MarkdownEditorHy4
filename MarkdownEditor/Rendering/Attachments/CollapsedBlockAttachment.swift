//
//  CollapsedBlockAttachment.swift
//  MarkdownEditorHy4
//
//  块被折叠后的占位符：显示一个弱化的「⋯」，但复制时吐出整块源码
//

import UIKit

/// 折叠状态下代替整块内容的占位符（画三个小圆点）。
///
/// ### 为什么它必须映射到「整块源码」
/// 本编辑器的核心约定是「全选复制出来的文本 === 源文件」。折叠只是**视图状态**，
/// 源码一个字都没少，所以复制也必须一个字不少。
///
/// 做法和图片一模一样：用 `.attachmentView(start: 0, length: 整块源码长度)`。
/// `sourceText(forRenderedRange:)` 遍历映射表时，占位符这一个字符位会吐出整块源码，
/// 于是「折叠着全选复制」和「展开着全选复制」结果完全一致。
///
/// 前面的折叠按钮（小三角）是纯装饰，映射是 `.decoration`，复制时跳过 —— 两者分工明确。
final class CollapsedBlockAttachment: NSTextAttachment {

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释
    nonisolated deinit {}

    /// - parameter width:  「⋯」的整体宽度
    /// - parameter color:  圆点颜色（一般用弱化色）
    /// - parameter font:   正文字体，用来把圆点对齐到文字的视觉中心
    init(width: CGFloat, color: UIColor, font: UIFont) {
        super.init(data: nil, ofType: nil)
        bounds = CGRect(x: 0, y: 0, width: width, height: font.lineHeight)
        image = Self.ellipsisImage(width: width, color: color, font: font)
    }

    required init?(coder: NSCoder) {
        fatalError("CollapsedBlockAttachment 不支持从 coder 解档")
    }

    private static func ellipsisImage(width: CGFloat, color: UIColor, font: UIFont) -> UIImage {
        let size = CGSize(width: width, height: font.lineHeight)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            // 对齐到文字的视觉中心（和折叠三角同一套算法，两个符号才会在一条线上）
            let centerY = font.lineHeight - font.capHeight / 2

            let dotDiameter: CGFloat = 3
            let gap: CGFloat = 4
            // 三个圆点横向居中摆放
            let total = dotDiameter * 3 + gap * 2
            var x = (width - total) / 2
            color.setFill()
            for _ in 0..<3 {
                let rect = CGRect(x: x,
                                  y: centerY - dotDiameter / 2,
                                  width: dotDiameter,
                                  height: dotDiameter)
                UIBezierPath(ovalIn: rect).fill()
                x += dotDiameter + gap
            }
        }
    }
}
