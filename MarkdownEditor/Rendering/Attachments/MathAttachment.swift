//
//  MathAttachment.swift
//  MarkdownEditorHy4
//
//  公式附件：把渲染出来的一张公式图放进文本流
//
//  ### 为什么是「一张图」而不是一个 view
//  外面查资料给的方案是 `NSTextAttachmentViewProvider` + SwiftMath 的 `MTMathUILabel`。
//  这条路在本项目已经被否决过一次了（见 `ImageAttachment` 的注释和 skill
//  `ios-textkit2-attachment-pitfalls`）：TextKit 2 只在 App 生命周期里调一次 `loadView()`，
//  整篇替换内容之后新附件的 view 根本不会被加载 —— 表现为「重载后图片全没了，滚一下才回来」。
//
//  所以这里照抄图片那条已经验证过的路：把 `UIImage` 直接赋给 `NSTextAttachment.image`，
//  绘制交给 TextKit 自己的图片路径。好处是它可能做的事 TextKit 都已经排好了：
//  文本重排它就跟着重画，不存在「view 生命周期对不上」的问题。
//

import UIKit

/// 一个公式。在文本流里占 **1 个字符位**（吞掉了源码里 `$...$` 那一段），
/// 显示的则是排版好的公式图。
final class MathAttachment: NSTextAttachment {

    /// 行内还是块级。UI 层不读它 —— 留着是为了调试和将来要单独处理块级时不用再猜
    let mode: MarkdownMathMode

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释：
    /// 隔离 deinit 一旦嵌套就会踩 Swift 6.2 运行时的野指针 free。
    nonisolated deinit {}

    /// - parameter image:     排版好的公式图（尺寸就是它在屏幕上的实际大小）
    /// - parameter font:      当前正文的字体，用来把图在垂直方向上摆到字的中间
    /// - parameter maxWidth:  最多能占多宽（超出就等比缩小，和不拉大小图的规矩一致）
    init(image: UIImage, font: UIFont, mode: MarkdownMathMode, maxWidth: CGFloat) {
        self.mode = mode
        super.init(data: nil, ofType: nil)

        let original = image.size
        guard original.width > 0, original.height > 0, maxWidth > 0 else { return }

        // 只缩不放：小公式按原尺寸显示，放大只会变糊（和 ImageAttachment 同一条规矩）
        let scale = min(maxWidth / original.width, 1)
        let size = CGSize(width: original.width * scale, height: original.height * scale)

        // 垂直方向：图的中心对齐到字体的 `capHeight` 中心 ——
        // 和圆点（`BulletAttachment`）用的是同一套基线定位，摆在文字里高度才对
        bounds = CGRect(x: 0,
                        y: (font.capHeight - size.height) / 2,
                        width: size.width,
                        height: size.height)
        self.image = image
    }

    required init?(coder: NSCoder) {
        fatalError("MathAttachment 不支持从 coder 解档")
    }
}
