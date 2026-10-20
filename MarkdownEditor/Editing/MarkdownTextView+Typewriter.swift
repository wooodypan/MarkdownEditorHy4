//
//  MarkdownTextView+Typewriter.swift
//  MarkdownEditorHy4
//
//  打字机模式：光标钉在屏幕中间，正文跟着光标走。
//
//  ### 为什么单独一个文件
//  和 `+ListContinuation` / `+Fold` 一样，是一块独立行为：不碰渲染、不碰模型，只读光标位置、改滚动位置。
//  开关本身（`isTypewriterMode`）的存储属性在 `MarkdownTextView.swift` —— Swift 的 extension 里不能声明存储属性。
//

import UIKit

extension MarkdownTextView {

    /// 打字机模式给底部留出的最小空白（点）。
    /// 视口太矮时也至少留这么点，免得文末那几行挤在屏幕最下面。
    static let typewriterBottomInsetMinimum: CGFloat = 32

    /// 按当前开关和视口高度，把底部留白设成「半屏」或者去掉。
    ///
    /// ### 为什么非要留这半屏
    /// 打字机模式要把光标停在中间，可文档最后一行下面没有内容了 —— `UIScrollView` 不允许滚过 `contentSize`，光标就永远停不到中线。底部补一块和半屏一样高的空白，末行才有地方「滚上来」。
    ///
    /// ### 谁在调
    /// - `isTypewriterMode` 的 `didSet`：开关一拨立刻生效；
    /// - `layoutSubviews`：转屏、拉窗口之后视口高度变了，半屏这个数得重算。
    ///
    /// 值没变就直接返回：`layoutSubviews` 每次布局都会走到这里，反复赋值会让滚动视图多算一轮。
    func applyTypewriterInset() {
        let bottom = isTypewriterMode
            ? max(Self.typewriterBottomInsetMinimum, bounds.height * 0.5)
            : 0
        guard abs(contentInset.bottom - bottom) > 0.5 else { return }
        contentInset.bottom = bottom
    }

    /// 把光标重新摆到屏幕中间。打字、点选、按方向键、开关刚打开，四处都会走到这里。
    ///
    /// ### 为什么推迟一拍
    /// 系统自己的「把光标滚进可见区域」发生在我们这一轮之后。当场设 `contentOffset`，下一毫秒就会被系统那次滚动覆盖掉，看着像「偶尔生效、偶尔不生效」。
    /// 推到 `DispatchQueue.main.async` 里执行，量到的是这一帧最终的位置。
    ///
    /// ### 为什么合并
    /// 快速打字 / 按住方向键时每一下都会来一次；真正有意义的只有最后一拍那次（它读的是当时最新的光标位置）。
    /// 用一个布尔标记把中间那些合并掉，省掉一串重复的排版查询。
    func keepCaretNearScreenCenterIfNeeded() {
        guard isTypewriterMode, !isApplyingModelChange, markedTextRange == nil else { return }
        guard !typewriterScrollScheduled else { return }
        typewriterScrollScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.typewriterScrollScheduled = false
            self.centerCaretIfNeeded()
        }
    }

    /// 真正干活的那一步：量光标在屏幕上的位置，不在中线附近就把滚动位置改成「光标落在中线」。
    ///
    /// ### 上下都管
    /// 第一版只处理「光标越过中线往下跑」，理由是「在屏幕上半部分改个字别把整页往下拽」。
    /// 可那样按住 ↑ 时屏幕纹丝不动，光标一路往上直到贴住顶栏，就不是打字机模式了。
    /// 现在**双向**都拉回中线：光标走到哪儿正文就跟着滚到哪儿，看着像光标钉在中间那一行。
    ///
    /// ### 差十几点以内不滚
    /// 点击同一行的不同位置时 `caretRect` 的纵坐标会抖几 pt，逐像素对齐会让画面一颤一颤的（见 `typewriterCenterDeadZone`）。
    ///
    /// ### 有选区时不动
    /// 拖选时系统自己会把选区末端滚进视野，我们再插一脚只会两边打架；用户正在选东西，画面也别乱跳。
    private func centerCaretIfNeeded() {
        guard isTypewriterMode, !isApplyingModelChange, markedTextRange == nil else { return }
        guard bounds.height > 0, window != nil else { return }
        guard selectedRange.length == 0 else { return }

        let middle = visibleAreaCenterY()
        // ### 为什么要滚一轮、再量一轮（这步最关键）
        // TextKit 2 按视口惰性排版：**还没排到的那一段，`caretRect` 给的是估算值**。
        // 实测在文末按回车，滚动前量到 `caret.minY = 1589.5`，滚过去真正排完之后变成了 `1721.5` —— 差 132pt。
        // 照第一次那个数滚一次，光标会停在离中线 130 多点的位置，看着就是「模式没生效」。
        // 所以这里循环两三轮：滚一次 → 逼它重排视口 → 再量 → 误差还大就再滚（和目录跳转 `jumpStep` 同一个坑）。
        for round in 0..<Self.typewriterCenterMaxRounds {
            // 每一步之前都催一次：TextKit 2 改完文本只是记了笔「待会儿要重排」，不催就量到上一帧的坐标
            flushPendingTextKitLayout()
            guard let caret = caretRectAtCaret() else { return }

            let error = caret.midY - contentOffset.y - middle
            // 第一轮只处理「肉眼看得出来偏了」的情况；后面几轮是收误差，标准严得多
            let tolerance = round == 0 ? Self.typewriterCenterDeadZone : 1
            guard abs(error) > tolerance else { return }

            let target = caret.midY - middle
            // 和滚动视图自己的上下限对齐：文档开头 / 结尾那两处没法真居中，夹住就好
            let minOffset = -adjustedContentInset.top
            let maxOffset = max(minOffset, contentSize.height + adjustedContentInset.bottom - bounds.height)
            let clamped = min(max(target, minOffset), maxOffset)
            // 已经顶到头 / 到底：再滚也不会变，直接收工
            guard abs(clamped - contentOffset.y) > 0.5 else { return }
            setContentOffset(CGPoint(x: contentOffset.x, y: clamped), animated: false)
        }
    }

    /// 光标离中线多近就算「已经在中间了」（点）。
    ///
    /// 点击同一行里不同的位置时，`caretRect` 的纵坐标会抖几 pt；逐像素对齐会让画面一颤一颤的。
    /// 取 12 差不多是半行：同一行内的抖动被吃掉，跨一行（行高 20 多点）照样会居中。
    private static let typewriterCenterDeadZone: CGFloat = 12

    /// 迭代几次就收手：一般两轮就收敛，第三轮是给「图片 / 表格这种一屏放不下几行」的极端情况兜底
    private static let typewriterCenterMaxRounds = 3

    /// 屏幕上「真正看得见的那一块」的纵向中点。
    ///
    /// ### 为什么不能直接用 `bounds.height / 2`
    /// iPhone / iPad 上键盘弹出来会盖住下半屏。这时候照整屏算中点，光标会被「居中」到键盘后面 —— 用户打字时眼前什么都没有。
    /// 有键盘就按键盘上沿算，没键盘（Catalyst、外接键盘）时 `keyboardLayoutGuide` 贴在底边，结果和整屏一致。
    private func visibleAreaCenterY() -> CGFloat {
        let keyboardTop = keyboardLayoutGuide.layoutFrame.minY
        let visibleHeight = keyboardTop > 1 ? min(bounds.height, keyboardTop) : bounds.height
        return visibleHeight / 2
    }

    /// 当前光标那个位置的矩形（拿不到位置就返回 nil）
    private func caretRectAtCaret() -> CGRect? {
        guard let position = self.position(from: beginningOfDocument, offset: selectedRange.location) else {
            return nil
        }
        let rect = caretRect(for: position)
        guard !rect.isNull, !rect.isInfinite, rect.height > 0 else { return nil }
        return rect
    }
}
