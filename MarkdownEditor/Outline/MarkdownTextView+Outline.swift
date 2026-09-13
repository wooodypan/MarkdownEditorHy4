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
    /// 留这点空是为了让标题**完整**落在屏幕上沿下方 —— 紧贴着边的话，标题上半截会被裁掉。
    /// （「记住阅读位置」恢复时用的上边距是 0，因为记住的就是「最上面那一行」）
    private static let jumpTopPadding: CGFloat = 16
    /// 「滚 → 量视口 → 再滚」最多跑几轮。实测 2~4 轮收敛，多留一些兜底
    private static let maxJumpRounds = 16
    /// 每一轮之间的间隔 —— 留给 TextKit 按新视口重排
    private static let jumpStepDelay: TimeInterval = 0.06
    /// 认为「已经到位」的像素误差（点）。小于它就当已经停好了
    private static let jumpSettleTolerance: CGFloat = 0.5
    /// 「目标已经在视口边上」的判定松紧度（字符）。
    ///
    /// 视口的渲染范围本身带一点余量，而且读数有可能比滚动慢半拍 ——
    /// 实测「目标差 9 个字符（约半行）没落进范围」就被判成「还没排版」，
    /// 于是退回按字符密度粗调，拿着过期读数一轮一轮空转到轮次耗尽。
    /// 允许差这么一点点，正是为了避免这种边界误判。
    private static let jumpNearViewportSlack = 16

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

        // 主动把光标报给目录。
        //
        // ### 为什么不能只等 UITextView 自己通知
        // 改 `selectedRange` 一般会触发 delegate 的 `textViewDidChangeSelection`，
        // 于是「光标动了 → 上报」这条链本来是被动生效的。但实测这个回调**不保证每次都来**
        // （受第一响应者状态影响，单元测试里尤其明显），一漏掉目录高亮就停在旧位置不动
        // —— 表现为「点了目录，光标过去了，但高亮那一行没跟着走」。
        // 主动报一次，这条路就不再依赖 UIKit 的心情了。
        publishOutlineCursor()

        // 一次点击内部要滚好几轮（原因见下面的注释），期间用户可能又点了别的标题，
        // 用序号把上一轮的残余步骤作废，免得两个目标互相拉扯
        outlineJumpToken &+= 1
        jumpStep(token: outlineJumpToken,
                 targetRendered: caret,
                 round: 1,
                 previousGap: 0,
                 referenceSpan: 0,
                 topPadding: Self.jumpTopPadding)
    }

    /// 按「源码偏移」把文档滚回那个位置（记住阅读位置用的）。
    ///
    /// 和 `scrollToOutlineItem` 是同一套迭代滚动，区别只有两点：
    /// - **不动光标**：只是想回到上次读到的位置，光标该在哪儿还在哪儿；
    /// - **上边距为 0**：目标直接顶到可视区最上面 —— 记住的就是「最上面那一行」。
    ///
    /// ### 为什么要等一帧再开始
    /// 调用时机是「刚 `setMarkdown` 换完整篇内容」，那一刻 TextKit 还没按新内容排版，
    /// `viewportRange` 是空的，量不到就滚不准。等一个 runloop 之后布局已经发生，
    /// 才能真正开始「滚 → 量 → 再滚」。
    func restoreScrollPosition(sourceOffset: Int) {
        guard sourceOffset > 0 else { return }

        let length = (text as NSString).length
        let target = min(max(0, documentStore.renderedCaret(forSourceOffset: sourceOffset)), length)

        outlineJumpToken &+= 1
        let token = outlineJumpToken
        DispatchQueue.main.async { [weak self] in
            // 期间用户又点了目录 / 又换了文档 → 这一轮作废，别和新的滚动目标互相拉扯
            guard let self, token == self.outlineJumpToken else { return }
            self.layoutIfNeeded()
            self.jumpStep(token: token,
                          targetRendered: target,
                          round: 1,
                          previousGap: 0,
                          referenceSpan: 0,
                          topPadding: 0)
        }
    }

    /// 当前屏幕最上面那一行对应的**源码偏移**，用来「记住读到哪儿了」。
    ///
    /// ### 为什么记源码偏移而不是 `contentOffset.y`
    /// `contentOffset.y` 跟窗口宽度强相关：同一份文档在 iPhone 竖屏和 Catalyst 宽窗口里，
    /// 第 3000 点可能是一个位置，也可能完全不是。源码偏移是文档自身的位置，
    /// 换窗口大小、换字号都还指在同一段文字上。
    ///
    /// 量不到视口（还没排版完）时返回 0，也就是「当作在读文档开头」——
    /// 这种情况下不记位置，比记一个错的强。
    var topVisibleSourceOffset: Int {
        guard let viewport = renderedRangeInViewport() else { return 0 }
        return documentStore.sourceCaret(forRenderedOffset: viewport.start)
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
    /// **精细对齐**：一旦目标字符落在视口渲染范围**附近**（详见 `jumpNearViewportSlack`），
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
    /// - parameter topPadding: 目标最后要停在「屏幕上沿往下多少点」。跳标题时留一点空，
    ///   免得标题上半截被裁掉（`jumpTopPadding`）；恢复阅读位置时是 0，因为记住的就是最上面那一行
    private func jumpStep(token: Int,
                          targetRendered: Int,
                          round: Int,
                          previousGap: Int,
                          referenceSpan: Int,
                          topPadding: CGFloat) {
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

        // 目标算不算「已经排过版」？落在渲染范围里算，差一丁点（约半行）也算 ——
        // 理由见 jumpNearViewportSlack 的注释
        let slack = max(Self.jumpNearViewportSlack, rowSpan / 16)
        let targetIsLaidOut = targetRendered >= viewport.start - slack
            && targetRendered < viewport.end + slack

        // ===== 阶段一：精细对齐（目标已经排过版，几何数据可信）=====
        if targetIsLaidOut, let caretFrame = caretFrame(atRenderedOffset: targetRendered) {
            // caretRect 和 contentOffset 是同一套坐标系（textView 内容坐标，含 inset），
            // 所以「光标所在行顶部 - 想要的内边距」直接就等于目标 contentOffset
            let desired = min(max(0, caretFrame.minY - topPadding),
                              maximumContentOffsetY)
            if abs(desired - contentOffset.y) <= Self.jumpSettleTolerance {
                return // 停好了，收工
            }
            setContentOffset(CGPoint(x: contentOffset.x, y: desired), animated: false)
            scheduleNextJumpRound(token: token, targetRendered: targetRendered,
                                  round: round, previousGap: gap, referenceSpan: span,
                                  topPadding: topPadding)
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
                                  round: round, previousGap: gap, referenceSpan: span,
                                  topPadding: topPadding)
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
                              round: round, previousGap: gap, referenceSpan: span,
                              topPadding: topPadding)
    }

    /// 某个渲染偏移处「光标那一行的矩形」（内容坐标，和 contentOffset 同一套）。
    ///
    /// ⚠️ 只有目标**已经排过版**时这个值才可信 —— 屏幕外没排过版的区域，
    /// TextKit 2 返回的是估算值（实测一个真实位置 2783 的标题，它一直报 1817）。
    /// 所以调用方必须先用 `renderedRangeInViewport()` 确认目标就在视口渲染范围附近
    /// （判定见 `jumpNearViewportSlack`）。
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
                                       referenceSpan: Int,
                                       topPadding: CGFloat) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.jumpStepDelay) { [weak self] in
            self?.jumpStep(token: token,
                           targetRendered: targetRendered,
                           round: round + 1,
                           previousGap: previousGap,
                           referenceSpan: referenceSpan,
                           topPadding: topPadding)
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

    /// 标题列表变了 → 重新提取整份列表，交给目录 UI 显示。
    ///
    /// 只在三个地方被调用（都在主文件里，一眼能找全）：
    /// 整篇加载 `setMarkdown`、整篇重排 `reRenderPreservingCaret`、
    /// 以及增量编辑里 `outcome.headingsChanged == true` 的情况。
    ///
    /// ⚠️ 「变了」不只是指标题被增删改，**标题位置被顶移**也算 ——
    /// 在某个标题上面的正文里打字，它后面所有标题的 `sourceOffset` 都会平移。
    /// 漏掉这一种，目录就会拿着一批过期偏移，一点就跳到正文中间
    /// （判据在 `MarkdownDocumentStore.applyEdit` 第 9 步）。
    func publishOutlineItems() {
        guard let sink = outlineEventSink else { return }
        sink.editorDidUpdateOutline(documentStore.outlineItems)
    }

    /// 光标动了 → 等 0.12 秒没有新动作之后，告诉目录「光标现在在源码的第几个字」。
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
