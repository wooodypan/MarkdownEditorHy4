//
//  MarkdownTextView+Export.swift
//  MarkdownEditorHy4
//
//  导出长图：把整篇内容（包括滚出屏幕外的部分）渲染成一张图片，给「导出成图片 / 分享」用。
//
//  ### 为什么单独一个文件
//  这是全项目唯一一处「临时撑大视口强制全文排版、再自己逐段画」的地方，副作用（改 `bounds` / `contentOffset` / 退出编辑态）全部集中在两个方法里，单独一个文件最好核对「现场恢复」是否完整。
//

import UIKit

extension MarkdownTextView {

    // MARK: - 导出长图

    /// 把**整篇内容**（包括滚出屏幕外的部分）渲染成一张图片，给「导出成图片 / 分享」用。
    ///
    /// ### 两步走：先撑大视口拿全文排版，再自己逐段画
    /// 1. TextKit 2 是「viewport 按需排版」：屏幕外的文字不排不画，fragment 坐标还是估算值。
    ///    所以先把 bounds（它就是视口）临时撑到整篇内容高度，强制布局，拿到准确的 contentSize 和全文 fragment。画完立刻恢复现场，中间不会真的闪一帧。
    /// 2. **不能**指望 `layer.render(in:)` 把文字画出来 —— UITextView 只把「画过的」
    ///    缓存进自己的 layer，屏幕外部分缓存里是空白（撑大视口强制重绘也只重绘它认定的可视区）。
    ///    文字必须自己枚举 `NSTextLayoutFragment` 逐个 draw（`.rendersUnseenText` 让没画过的 fragment 真正渲染出来）；装饰层是独立 subview，单独 render 各自的 layer 即可。
    func renderFullContentImage() -> UIImage? {
        layoutIfNeeded()
        guard bounds.width > 1, contentSize.height > 1 else { return nil }

        // 记住现场，画完恢复
        let savedBounds = bounds
        let savedOffset = contentOffset
        let hadFocus = isFirstResponder
        // 光标会被画进图里；键盘也占着屏幕。先退出编辑态，画完再还回去
        if hadFocus { resignFirstResponder() }

        // 视口撑到全文高度。注意 contentSize 首次拿到的是 TextKit 的**估算值**（viewport 外的排版是估的），撑大后全文排完高度可能变 → 循环到不再变化为止
        for _ in 0..<3 {
            bounds = CGRect(origin: .zero, size: contentSize)
            contentOffset = .zero // 同步触发装饰层 KVO，按新视口重摆装饰
            layoutIfNeeded()
            if bounds.size == contentSize { break }
        }

        // 装饰矩形的重算（computeCodeBlockFrames）此刻全文已排完，坐标是准的；
        // 同步刷一轮，保证代码块背景/竖条/勾选框和文字对齐
        refreshCodeBlockDecorations()

        // 像素密度跟屏幕一致，导出的图才不糊；
        // GPU 单张纹理有上限（一般 16384px），超长文档按比例降像素密度防止渲染失败
        let maxPixels: CGFloat = 16384
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(max(traitCollection.displayScale, 1), maxPixels / max(bounds.height, 1))
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)

        let image = renderer.image { context in
            let cg = context.cgContext
            // 先铺一层背景色，避免出现透明区域
            (backgroundColor ?? .systemBackground).setFill()
            context.fill(CGRect(origin: .zero, size: bounds.size))

            // 层次和真实视图一致：代码块背景、引用竖条在文字下面，勾选框在文字上面。
            // 复制按钮 / 折叠三角是操作入口，不画进分享图
            codeBlockBackgroundLayer.layer.render(in: cg)
            quoteBarLayer.layer.render(in: cg)
            drawAllLayoutFragments(in: cg)
            // 宽表格的浮层必须画：文本流里那个位置只有一张透明占位图，不画它就是一片空白
            tableScrollLayer.layer.render(in: cg)
            checkboxLayer.layer.render(in: cg)
        }

        // 恢复现场：bounds/offset 一改，装饰层 KVO 会把装饰摆回可见区
        bounds = savedBounds
        contentOffset = savedOffset
        layoutIfNeeded()
        if hadFocus { becomeFirstResponder() }
        return image
    }

    /// 把每个 `NSTextLayoutFragment`（文字 + 表格/图片/圆点等 attachment）画进图片上下文。
    /// 这是 TextKit 2 导出全文的姿势：直接 `layer.render` 只能拿到「画过的」缓存，屏幕外是空白；自己枚举 fragment 逐个 draw 才能把没画过的段落真正渲染出来
    private func drawAllLayoutFragments(in context: CGContext) {
        guard let layoutManager = textLayoutManager else { return }
        // ### 坐标系换算（同 computeCodeBlockFrames 的注释）
        // layoutFragmentFrame 原点是 textContainer 左上角（已扣掉 textContainerInset），图片画在 textView 坐标系里，x/y 要把 inset 补回来
        let inset = textContainerInset
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard !frame.isNull, frame.width > 0, frame.height > 0 else { return true }
            // 访问一次 textLineFragments 强制它把文字段渲染出来：
            // 屏幕外的 fragment 是「排了但没画」状态，直接 draw 可能画的是空的
            _ = fragment.textLineFragments
            fragment.draw(at: CGPoint(x: frame.minX + inset.left,
                                      y: frame.minY + inset.top),
                          in: context)
            return true
        }
    }
}
