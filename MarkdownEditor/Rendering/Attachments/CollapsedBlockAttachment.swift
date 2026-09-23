//
//  CollapsedBlockAttachment.swift
//  MarkdownEditorHy4
//
//  块被折叠后的占位符：在文本流里**只占座、不画画**，画面上那个「⋯」由浮层按钮画
//

import UIKit

/// 折叠状态下代替整节内容的**座位**（只占一个字符位，一个像素都不画）。
///
/// ### 它为什么必须存在
/// 本编辑器的核心约定是「全选复制出来的文本 === 源文件」。折叠只是**视图状态**，
/// 源码一个字都没少，所以复制也必须一个字不少。
///
/// 做法和图片、复选框座位一模一样：把「从标题结束处到整节结束」的源码全挂在**这一个字符位**上。
/// `sourceText(forRenderedRange:)` 遍历映射表时，它一个字符就吐出整节源码， 于是「折叠着全选复制」和「展开着全选复制」结果完全一致（有测试守着）。
///
/// ### ⚠️ 为什么它自己不画那三个点
/// 画面上那个「⋯」现在是浮层上的 `CollapsedSectionButton`（一个固定高度的圆角矩形）画的。
/// 要是文本流也画一份，就是**两份图形各自定位**：附件按字号算位置、按钮按行矩形摆， 字号或行高一变就有半个点的错位，看着像「点没居中」。一份图形只留一个出处，颜色 / 粗细 / 圆角也只需改一处。
///
/// 这和核心不变量「UI 画装饰一律走 overlay，别往文本流插 attachment」是同向的：
/// **文本流负责占位与源码映射，overlay 负责画**（复选框的座位 + 对勾按钮也是这个分工）。
///
/// ⚠️ 占座的宽度**必须**和浮层按钮同宽（都读 `MarkdownTheme.collapsedPlaceholderWidth`）， 否则按钮会盖到标题文字上、或者右边多留一道空档。
final class CollapsedBlockAttachment: NSTextAttachment {

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释
    nonisolated deinit {}

    /// - parameter width: 这个座位在文本流里占多宽（**和浮层按钮同宽**）
    /// - parameter font:  正文字体。**只用来定高度** —— 高度取 `font.lineHeight`，
    ///                    折叠那一行的行高才和展开时完全一样，开关折叠时正文不会跳
    init(width: CGFloat, font: UIFont) {
        super.init(data: nil, ofType: nil)
        bounds = CGRect(x: 0, y: 0, width: width, height: font.lineHeight)
        // ⚠️ 必须给一张**全透明**的图，不能图省事留 `image = nil`（做法同 `CheckboxSeatAttachment`）。
        // 附件在 TextKit 眼里「没有任何内容」时，它会自己补画一个缺省图标 —— 就是那张右上角卷起的白纸，于是屏幕上凭空多出一张纸。给它一张透明的图等于说「内容在这儿，只是看不见」：占位照旧，纸也不画
        image = Self.transparentImage(size: bounds.size)
    }

    /// 一张全透明的图 —— 座位自己什么都不画，画面上那个「⋯」由浮层按钮负责
    private static func transparentImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in }
    }

    required init?(coder: NSCoder) {
        fatalError("CollapsedBlockAttachment 不支持从 coder 解档")
    }
}
