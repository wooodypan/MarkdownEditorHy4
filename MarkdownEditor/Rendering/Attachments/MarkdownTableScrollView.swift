//
//  MarkdownTableScrollView.swift
//  MarkdownEditorHy4
//
//  列太多的表格：浮在正文上面的横向滚动容器
//

import UIKit

/// 一个能横向滚动的表格。
///
/// ### 为什么要有这一层（表格本来是一张静态图）
/// 表格是按整张画成图片塞进文本流的（原因见 `MarkdownTableView`），代价就是它不能滚。
/// 列数不多时无所谓：超宽了整体等比压缩一下还看得清；但 30 列的时候压缩会把每列压到二十几点宽 —— 一个字都显示不全。
/// 所以「每列都保持最小宽度还塞不下」时改成横向滚动：表格按内容画完整宽度，屏幕上只露容器那么宽（占位的是 `MarkdownTableAttachment` 那张透明图），剩下的靠手指 / 触控板横着滑。
///
/// ### 画布为什么不是一张大图
/// 30 列 × 每列最多 280pt 就是上万点宽，整张转成位图既吃内存又超 GPU 纹理上限。
/// 这里放的是一块 `MarkdownTableView`（UIView），它每次只按脏矩形画露出来那一块，不管表格多宽，一帧的成本都只有一屏。
final class MarkdownTableScrollView: UIScrollView {

    /// 它对应的那个 attachment（浮层靠它复用：同一个表格滚出视野再滚回来，滚动位置不该丢）
    let attachment: MarkdownTableAttachment
    /// 真正画表格的那块画布
    let canvas: MarkdownTableView

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释
    nonisolated deinit {}

    init(attachment: MarkdownTableAttachment) {
        self.attachment = attachment
        let layout = attachment.presentation.layout
        // ⚠️ 一定要走「按布局」那个 init：再传宽度进去就会被按容器宽度压缩一次，白滚了
        self.canvas = MarkdownTableView(data: attachment.data,
                                        style: attachment.style,
                                        bodyFont: attachment.bodyFont,
                                        textColor: attachment.textColor,
                                        layout: layout)
        super.init(frame: .zero)

        canvas.frame = CGRect(origin: .zero, size: CGSize(width: layout.totalWidth,
                                                          height: layout.totalHeight))
        addSubview(canvas)
        contentSize = canvas.bounds.size
        contentOffset = .zero

        // 只允许横向滚：内容高度和框一样高，竖着滑本来也不会动
        showsHorizontalScrollIndicator = true
        showsVerticalScrollIndicator = false
        alwaysBounceHorizontal = true
        // 滚出去的部分要裁掉（表格外框的圆角在画布里画，右边缘本来就该是齐的）
        clipsToBounds = true
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("MarkdownTableScrollView 不支持从 coder 解档")
    }

    /// 只接管**横向意图**的拖拽，纵向一律放行给外层的 textView。
    ///
    /// ### 为什么这一步不能省
/// 这一层是 textView 的**子视图**，触摸先落到它身上，而 UIScrollView 的拖拽手势一旦开始，外面那层 textView 就收不到这次触摸了 —— 手指在表格上竖着划，文档纹丝不动，看起来就是「滚到表格这儿卡住了」。
/// 所以按手势方向分流：横向归表格，纵向归文档。
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGestureRecognizer,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let translation = pan.translation(in: self)
        return abs(translation.x) > abs(translation.y)
    }
}
