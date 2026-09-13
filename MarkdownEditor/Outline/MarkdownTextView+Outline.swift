//
//  MarkdownTextView+Outline.swift
//  MarkdownEditorHy4
//
//  编辑器侧的大纲接入：产出标题列表、上报光标、接受跳转指令
//
//  单独放一个文件是为了让「编辑器 ←→ 大纲」的全部接触面一眼可见：
//  主文件 MarkdownTextView.swift 里只有三处一行调用（publishOutlineItems /
//  publishOutlineCursor），其余逻辑都在这里。
//

import UIKit

// MARK: - 数据源：协调者通过这些方法取数据 / 下指令

extension MarkdownTextView: MarkdownOutlineDataSource {

    // MARK: 跳转时的视口对齐参数

    /// 标题距离屏幕上沿留出的空白（点）。
    /// 留这点空是为了让标题**完整**落在屏幕上沿下方 —— 紧贴着边的话，标题上半截会被裁掉
    private static let jumpTopPadding: CGFloat = 16
    /// 「滚 → 量视口 → 再滚」最多跑几轮。实测 2~4 轮收敛，多留一些兜底
    private static let maxJumpRounds = 16
    /// 每一轮之间的间隔 —— 留给 TextKit 按新视口重排
    private static let jumpStepDelay: TimeInterval = 0.06
    /// 认为「已经到位」的像素误差（点）。小于它就当已经停好了
    private static let jumpSettleTolerance: CGFloat = 0.5

    /// 当前文档的完整标题列表（H1-H6）。
    ///
    /// 数据本身是文档模型算出来的（`MarkdownDocumentStore.outlineItems`），
    /// 这里只是个转发 —— 编辑器不参与「标题有哪些」的判断。
    func currentOutlineItems() -> [OutlineItem] {
        documentStore.outlineItems
    }

    /// 跳到某个标题：光标落位 + 视口滚动。
    func scrollToOutlineItem(_ item: OutlineItem) {
        let length = (text as NSString).length
        // 源码偏移 → 渲染坐标。这一步复用的是「复制/粘贴」那套已有的双向映射表
        // （`renderedCaret(forSourceOffset:)`），不需要为目录跳转另造一套
        let caret = min(max(0, documentStore.renderedCaret(forSourceOffset: item.sourceOffset)), length)

        selectedRange = NSRange(location: caret, length: 0)
        // 让光标真正落位，用户跳过去就能直接开始改
        becomeFirstResponder()

        // 一次点击内部要滚好几轮（原因见下面的注释），期间用户可能又点了别的标题，
        // 用序号把上一轮的残余步骤作废，免得两个目标互相拉扯
        outlineJumpToken &+= 1
        jumpStep(token: outlineJumpToken,
                 targetRendered: caret,
                 round: 1,
                 previousGap: 0,
                 referenceSpan: 0)
    }

    /// 迭代滚动：每一轮看「视口顶部现在停在哪」，算出还差多少，再滚过去。
    ///
    /// ### 为什么不能「算一次目标位置、滚一次」
    /// TextKit 2 是**按视口惰性排版**的：屏幕外的内容还没真正排过版，
    /// 这时 `caretRect` / `layoutFragmentFrame` 拿到的都是**估算的坐标**，
    /// 而且遇到图片、表格这种「字符少但很高」的块，估算和实际能差出上千点。
    /// 于是「一次滚到位」根本不可能，只能滚一段、重新看、再滚 ——
    /// 这也正是这个 bug 的由来：以前一次点击只滚一次，用户得连点好几下才到位。
    ///
    /// ### 两个阶段（关键设计）
    /// **粗调**：目标还在视口之外时，用「这一屏渲染了哪段文字」当尺子估算距离。
    ///   为什么用它：`textViewportLayoutController.viewportRange` 是渲染层自己的说法 ——
    ///   「这一屏渲染的是哪一段文本」，滚到哪儿就报哪儿，不依赖任何估算。
    ///   一屏横跨了 n 个字符、高度是 h，那么每个字符大约占 h/n 点，按这个换算步长。
    ///
    /// **精细对齐**：一旦目标字符落进了视口渲染范围（`[viewport.start, viewport.end)`），
    ///   说明它**已经真的排过版了**，此刻 `caretRect` 才是可信的，于是直接用像素算：
    ///   想让光标停在「屏幕上沿往下 `jumpTopPadding`」处，就把滚动位置设成
    ///   `caretRect.minY - jumpTopPadding`。
    ///
    /// ### 为什么必须分两段（gap == 0 死区）
    /// 只用粗调时会有个死区：当「视口顶部正好落在标题上」时 `targetRendered - viewport.start == 0`，
    /// 按字符密度换算出来的步长也就是 0 —— 既没到位（标题贴着屏幕上沿），又再也挪不动，
    /// 循环空转到底。精细对齐用像素算，不存在这个死区。
    ///
    /// - parameter previousGap: 上一轮的 `gap`，用来识别「滚过头了」并减小步长
    /// - parameter referenceSpan: 第一轮量到的「一屏字符数」，用来识别异常读数
    private func jumpStep(token: Int,
                          targetRendered: Int,
                          round: Int,
                          previousGap: Int,
                          referenceSpan: Int) {
        guard token == outlineJumpToken, round <= Self.maxJumpRounds else { return }
        guard markedTextRange == nil else { return }
        guard let viewport = renderedRangeInViewport() else {
            // 量不到视口（还没排版完）—— 退回系统的最小滚动，至少保证光标可见
            scrollRangeToVisible(selectedRange)
            return
        }

        let rowSpan = max(1, viewport.end - viewport.start)
        let span = referenceSpan == 0 ? rowSpan : referenceSpan
        let gap = viewport.start - targetRendered

        NSLog("[STEP] token=%d round=%d 视口=%d..%d 目标=%d gap=%d offset=%.1f",
              token, round, viewport.start, viewport.end, targetRendered, gap, contentOffset.y)

        // ===== 阶段一：精细对齐（目标已经排过版，几何数据可信）=====
        if viewport.start <= targetRendered && targetRendered < viewport.end,
           let caretFrame = caretFrame(atRenderedOffset: targetRendered) {
            // caretRect 和 contentOffset 是同一套坐标系（textView 内容坐标，含 inset），
            // 所以「光标所在行顶部 - 想要的内边距」直接就等于目标 contentOffset
            let desired = min(max(0, caretFrame.minY - Self.jumpTopPadding),
                              maximumContentOffsetY)
            if abs(desired - contentOffset.y) <= Self.jumpSettleTolerance {
                return // 停好了，收工
            }
            setContentOffset(CGPoint(x: contentOffset.x, y: desired), animated: false)
            scheduleNextJumpRound(token: token, targetRendered: targetRendered,
                                  round: round, previousGap: gap, referenceSpan: span)
            return
        }

        // ===== 阶段二：粗调（目标还在视口外）=====

        // 目标在下方、而且它之后剩下的内容已经不足一屏 —— 说明它是文末那几个标题，
        // 再怎么滚也不可能顶到最上面，直接滚到底（硬要贴顶会把页面滚出内容之外）
        if gap < 0 && totalRenderedLength() - targetRendered <= span {
            let bottom = maximumContentOffsetY
            if abs(bottom - contentOffset.y) <= Self.jumpSettleTolerance { return } // 已经到底了
            setContentOffset(CGPoint(x: contentOffset.x, y: bottom), animated: false)
            scheduleNextJumpRound(token: token, targetRendered: targetRendered,
                                  round: round, previousGap: gap, referenceSpan: span)
            return
        }

        var delta: CGFloat
        if rowSpan < span / 4 {
            // 这一屏的跨度异常小：要么滚到内容之外了，要么大半屏都是图片这种「字符少、位置高」的块。
            // 此时按字符密度换算出来的距离会大得离谱（实测能一步跳 800 点），改用固定小步走
            let step = bounds.height / 2
            delta = gap < 0 ? step : -step
        } else {
            delta = CGFloat(targetRendered - viewport.start) * (bounds.height / CGFloat(rowSpan))
            // 上一轮滚过头、这一轮要往回走 → 步长打四折，避免在两个位置之间来回弹
            if previousGap != 0 && (previousGap > 0) != (gap > 0) {
                delta *= 0.4
            }
        }

        // 只夹在「能滚到的范围」里，不额外限制单步大小：
        // 跨半个文档跳的时候就是要一步跨过去，限制成一屏反而要来回滚十几轮
        let next = min(max(0, contentOffset.y + delta), maximumContentOffsetY)
        // 一步都挪不动说明已经顶到边界了，再算下去也是原地打转，直接收工
        if abs(next - contentOffset.y) <= Self.jumpSettleTolerance { return }

        setContentOffset(CGPoint(x: contentOffset.x, y: next), animated: false)
        scheduleNextJumpRound(token: token, targetRendered: targetRendered,
                              round: round, previousGap: gap, referenceSpan: span)
    }

    /// 某个渲染偏移处「光标那一行的矩形」（内容坐标，和 contentOffset 同一套）。
    ///
    /// ⚠️ 只有目标**已经排过版**时这个值才可信 —— 屏幕外没排过版的区域，
    /// TextKit 2 返回的是估算值（实测一个真实位置 2783 的标题，它一直报 1817）。
    /// 所以调用方必须先用 `renderedRangeInViewport()` 确认目标落在视口渲染范围里。
    private func caretFrame(atRenderedOffset offset: Int) -> CGRect? {
        guard let position = self.position(from: beginningOfDocument, offset: offset) else {
            return nil
        }
        return caretRect(for: position)
    }

    /// 排下一轮。带上这一轮的 `gap`，好让下一轮识别出「是不是滚过头了」
    private func scheduleNextJumpRound(token: Int,
                                       targetRendered: Int,
                                       round: Int,
                                       previousGap: Int,
                                       referenceSpan: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.jumpStepDelay) { [weak self] in
            self?.jumpStep(token: token,
                           targetRendered: targetRendered,
                           round: round + 1,
                           previousGap: previousGap,
                           referenceSpan: referenceSpan)
        }
    }

    /// 视口里当前渲染的文本范围（渲染坐标）。量不到返回 nil
    private func renderedRangeInViewport() -> (start: Int, end: Int)? {
        guard let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              let viewport = layoutManager.textViewportLayoutController.viewportRange else { return nil }

        let start = contentStorage.offset(from: contentStorage.documentRange.location,
                                          to: viewport.location)
        let end = contentStorage.offset(from: contentStorage.documentRange.location,
                                        to: viewport.endLocation)
        return (start, end)
    }

    /// 整篇渲染文本的长度
    private func totalRenderedLength() -> Int {
        guard let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else {
            return (text as NSString).length
        }
        return contentStorage.offset(from: contentStorage.documentRange.location,
                                     to: contentStorage.documentRange.endLocation)
    }

    /// 能滚到的最靠下的位置。
    ///
    /// `contentSize` 在 TextKit 2 下可能是估算值，所以这里取「它和真实内容高度里更大的那个」，
    /// 免得算出来的上限比实际能滚到的位置还小、把最后几个标题卡在半路。
    private var maximumContentOffsetY: CGFloat {
        let byContentSize = contentSize.height + adjustedContentInset.bottom - bounds.height
        let contentBottom = textLayoutManager?.usageBoundsForTextContainer.maxY ?? 0
        let byUsage = contentBottom + textContainerInset.bottom + adjustedContentInset.bottom - bounds.height
        return max(0, max(byContentSize, byUsage))
    }
}

// MARK: - 往外发事件

extension MarkdownTextView {

    /// 标题结构可能变了 → 重新提取整份列表推出去。
    ///
    /// 只在三个地方被调用（都在主文件里，一眼能找全）：
    /// 整篇加载 `setMarkdown`、整篇重排 `reRenderPreservingCaret`、
    /// 以及增量编辑里 `outcome.headingsChanged == true` 的情况。
    func publishOutlineItems() {
        guard let sink = outlineEventSink else { return }
        sink.editorDidUpdateOutline(documentStore.outlineItems)
    }

    /// 光标动了 → 防抖之后把「光标所在的源码偏移」推出去。
    ///
    /// 上报的是**源码偏移**而不是光标所在的块 id：这样协调者只要在
    /// 「按源码偏移排好序的标题数组」里二分查找就能判断归属，不需要反过来问编辑器
    /// 「这个块在文档里排第几」，双方的接口更少。
    func publishOutlineCursor() {
        guard outlineEventSink != nil else { return }

        // 尾部防抖：连续触发时只保留最后一次
        outlineCursorWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let sink = self.outlineEventSink else { return }
            sink.editorDidMoveCursor(sourceOffset: self.cursorSourceOffset)
        }
        outlineCursorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// 光标当前所在的源码偏移（UTF-16）。
    /// 渲染坐标 → 源码坐标同样复用已有的映射表
    var cursorSourceOffset: Int {
        documentStore.sourceCaret(forRenderedOffset: selectedRange.location)
    }
}
