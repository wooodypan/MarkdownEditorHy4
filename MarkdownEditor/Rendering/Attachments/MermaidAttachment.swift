//
//  MermaidAttachment.swift
//  MarkdownEditorHy4
//
//  Mermaid 图附件：把渲染好的一张图放进文本流
//
//  ### 为什么是「一张图」而不是一个 view
//  理由和 `MathAttachment` 完全一样（那边的注释写得最细）：TextKit 2 只在 App 生命周期里调一次 `loadView()`，整篇替换内容之后新附件的 view 根本不会被加载 ——表现是「重载之后图全没了，滚一下才回来」。
//
//  所以统一走 `NSTextAttachment.image` 这条位图路，绘制交给 TextKit 自己的图片路径。
//  哪怕 MermaidKit 另外提供了 SwiftUI 的 `MermaidView`，本项目也不用它。
//

import UIKit

/// 一张 Mermaid 图。在文本流里占 **1 个字符位**（吞掉了源码里整个 ```mermaid 围栏块），显示的则是渲染好的图。
final class MermaidAttachment: NSTextAttachment {

    /// 渲染引擎交出来的原图尺寸（缩放**之前**的）。
    /// 留着是为了调试，以及将来要「按原始分辨率导出」时不用再问一次引擎。
    let originalSize: CGSize

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释：
    /// 隔离 deinit 一旦嵌套就会踩 Swift 6.2 运行时的野指针 free。
    nonisolated deinit {}

    /// - parameter image:    渲染好的图（尺寸就是它在屏幕上的实际大小）
    /// - parameter maxWidth: 最多能占多宽（超出就等比缩小，和不拉大小图的规矩一致）
    init(image: UIImage, maxWidth: CGFloat) {
        self.originalSize = image.size
        super.init(data: nil, ofType: nil)

        let original = image.size
        guard original.width > 0, original.height > 0, maxWidth > 0 else { return }

        // 只缩不放：Mermaid 图常常比容器宽，塞不下就等比缩到刚好塞下；
        // 本来就比容器窄的（一张小 flowchart）按原尺寸显示，放大只会变糊 ——和 `ImageAttachment` / `MathAttachment` 是同一条规矩
        let scale = min(maxWidth / original.width, 1)
        let size = CGSize(width: original.width * scale, height: original.height * scale)

        // 垂直方向：块级图独占一行（段落样式是 `blockAttachmentParagraphStyle`），所以**不**跟 `capHeight` 对齐 —— 那是行内公式的做法。
        // 图底坐在基线上，上面由行高自然撑开，和表格附件（`MarkdownTableAttachment`）一致。
        bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        self.image = image
    }

    required init?(coder: NSCoder) {
        fatalError("MermaidAttachment 不支持从 coder 解档")
    }
}
