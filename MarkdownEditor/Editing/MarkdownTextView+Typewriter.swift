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
    ///
    /// ### 程序化滚动刚发生时也不动
    /// 目录跳转 / 查找下一个 / 脚注跳转 / 恢复阅读位置都在改同一个 `contentOffset`，
    /// 它们通过 `jumpStep` 一轮一轮滚（每轮刷新 `lastProgrammaticScrollTime`）。
    /// 这时打字机再插一脚就会和跳转抢位置、画面来回跳，所以避让一个冷却窗口（见 `typewriterProgrammaticScrollCooldown`）。
    private func centerCaretIfNeeded() {
        guard isTypewriterMode, !isApplyingModelChange, markedTextRange == nil else { return }
        guard bounds.height > 0, window != nil else { return }
        guard selectedRange.length == 0 else { return }
        // 刚被程序化滚动动过（跳转还在飞、或刚停下没多久）→ 让它先收敛，别抢
        guard CACurrentMediaTime() - lastProgrammaticScrollTime > Self.typewriterProgrammaticScrollCooldown else { return }

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

    /// 程序化滚动（目录 / 查找 / 脚注跳转、恢复阅读位置）停下之后，打字机还要再避让这么久才恢复居中。
    ///
    /// ### 为什么是这个值
    /// 跳转靠 `jumpStep` 一轮一轮滚，每轮间隔 `jumpStepDelay`（0.06s），每轮都会刷新 `lastProgrammaticScrollTime`。
    /// 只要还在滚，这个时间差就一直接近 0，打字机全程被压住；跳转收敛后不再刷新，时间差才开始累积。
    /// 取一个略大于轮间隔的值：跳转一停就尽快把居中还给打字机，又不会因为两轮之间的空隙误判成「已经停了」。
    private static let typewriterProgrammaticScrollCooldown: CFTimeInterval = 0.12

    /// 屏幕上「真正看得见的那一块」的纵向中点。
    ///
    /// ### 为什么不能直接写 bounds.height / 2
    /// 现在的键盘避让是把编辑器顶短（`keyboardFrameChanged` 改 `bottomConstraint`），这时 bounds.height 就是可见高度，直接写没问题。
    /// 但只要哪天换成「编辑器不动、键盘盖在上面」，bounds.height 就包含了被盖住的那段，光标会被送到键盘背后。
    /// 所以这里两种布局都算得对，不依赖外面怎么避让。
    ///
    /// ### 为什么只读 minY
    /// layoutFrame 在滚动视图里是内容坐标（实测 896.33 = 滚动偏移 274.33 + 视口高度 622），minY 才是键盘上沿，maxY 是屏幕底边，读它拿不到任何东西。
    ///
    /// ### 为什么要减 bounds.origin.y
    /// 内容坐标的原点在文档开头，减掉滚动偏移才是「离可视区顶部多远」。
    ///
    /// ### 谁还在读它
    /// 目录跳转（`MarkdownTextView+Outline.swift` 的 `jumpStep`）在打字机模式下要按这个中线算目标位置，跨文件够不到私有方法，所以这里不能标 `private`。
    func visibleAreaCenterY() -> CGFloat {
        let guide = keyboardLayoutGuide.layoutFrame

        // 键盘收起时 guide 缩成贴底边的一条，高度正好等于底部安全区，这时读它会把中心点抬高十几点，不如直接用整个视口。
        guard guide.height > safeAreaInsets.bottom + 0.5 else { return bounds.height / 2 }

        let keyboardTop = guide.minY - bounds.origin.y
        // 只有落在视口里面才有参考价值：等于视口高度说明键盘正好在编辑器下方（编辑器已经被顶短的正常情况），
        // 算成负数或超出视口说明坐标系和预期不一样，这两种都退回整个视口，宁可偏一点也不要把光标送到看不见的地方。
        let visibleHeight = (keyboardTop > 1 && keyboardTop < bounds.height) ? keyboardTop : bounds.height
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
