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
        let range = NSRange(location: caret, length: 0)

        selectedRange = range
        // 先确保这一段排过版：TextKit 2 是按视口惰性排版的，
        // 屏幕外的 fragment 坐标还是估算值，不先滚一次下面读到的 caretRect 会不准
        scrollRangeToVisible(range)
        // 让光标真正落位，用户跳过去就能直接开始改
        becomeFirstResponder()

        positionHeadingNearTop()
    }

    /// 把刚跳过去的标题顶到视口靠上的位置。
    ///
    /// ### 为什么不能只用 `scrollRangeToVisible`
    /// 它做的是「**最小**滚动」：目标已经在视口里就完全不动，在屏幕下沿附近也只滚一点点。
    /// 结果就是点了一个靠下的标题，跳过去之后标题还贴着屏幕底部，
    /// 看不见它下面有什么内容 —— 而跳转的意义正是「看这一章」。
    ///
    /// 这里只用**相对位移**，不碰 `contentSize`、不碰 `adjustedContentInset`
    /// 那套很容易算错的绝对值换算：先量出标题现在离视口顶部有多远，
    /// 再把这段距离滚掉，并保证不会滚到负偏移。
    private func positionHeadingNearTop() {
        // 等这一轮布局跑完，caretRect 才有真实值
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let position = self.selectedTextRange?.start,
                  self.markedTextRange == nil else { return }

            let caretRect = self.caretRect(for: position)
            guard !caretRect.isNull, !caretRect.isInfinite, caretRect.height > 0 else { return }

            // caretRect 是**视口坐标**：它离视口顶部的距离，就是要滚掉的距离
            let distanceFromTop = caretRect.minY - self.adjustedContentInset.top
            let desired: CGFloat = 12
            guard distanceFromTop > desired else { return }

            // 不能滚过界：最多只能滚掉当前已有的滚动量
            let delta = min(distanceFromTop - desired, self.contentOffset.y)
            guard delta > 0.5 else { return }
            self.setContentOffset(CGPoint(x: self.contentOffset.x, y: self.contentOffset.y + delta),
                                  animated: true)
        }
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
