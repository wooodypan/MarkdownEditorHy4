//
//  MarkdownTextView+Fold.swift
//  MarkdownEditorHy4
//
//  折叠 / 展开：标题左侧装订线里的小三角、折叠后行尾的「⋯」，以及点它们时替换掉那一节渲染内容的那次编辑（toggleCollapse）。
//  本文件代码最开始存在于MarkdownTextView.swift，2026-10-12从MarkdownTextView.swift移动到这里

import UIKit
// Mac Catalyst 上要直接用 AppKit 的 `NSCursor` 换鼠标指针，只有这一个平台看得见它；
// iOS / iPadOS 那边既用不上也不需要，整段连同下面的方法一起用 `#if` 关掉
#if targetEnvironment(macCatalyst)
import AppKit
#endif

extension MarkdownTextView {

    // MARK: - 折叠 / 展开（顶层块左侧的小三角）

    /// 铺好三角所在的控件层（最上层，只有按钮吃点击）
    func setupFoldDecorations() {
        addSubview(foldControlLayer)
        // ⚠️ 只有 Mac 上才有「鼠标悬停」这回事 —— iOS / iPadOS 没有鼠标指针可换，那边不装这个手势
        #if targetEnvironment(macCatalyst)
        setupFoldHoverCursor()
        #endif
    }

#if targetEnvironment(macCatalyst)

    // MARK: macOS 上的鼠标指针

    /// 让 macOS 上鼠标移到折叠三角 / 「⋯」上面时，指针从插入符（I 形）变成**手指**。
    ///
    /// ### 为什么要自己换（Mac Catalyst 的坑）
    /// 编辑器本体是 `UITextView`，AppKit 给整片正文区域挂的光标是**插入符**（✅ 能打字的意思）。
    /// 三角虽然是个真的 `UIButton`、浮在上面也真能吃点击，但它压不住底下那一整片的插入符——
    /// 鼠标指上去还是一根 I 形竖线，看着像「这里能写字」，不像「这里能点」。
    ///
    /// ### 为什么不把手势挂到按钮自己身上
    /// 这两个按钮**每轮布局都整批销毁重建**（见 `positionFoldControls`），滚一下就换一批新对象。
    /// 挂在按钮上等于每次滚动都要重装一遍手势；更要命的是鼠标不动时旧按钮会先消失，
    /// `.ended` 事件收不到，指针就卡在手指形状再也回不来。
    /// 改成只往 textView 上挂**一个**悬停手势，每次现场问「这个点压没压在某颗按钮上」，最稳。
    private func setupFoldHoverCursor() {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleFoldHover(_:)))
        // 别让它吃掉任何触摸：textView 自己的「点一下放光标 / 拖动选中」要照旧工作
        hover.cancelsTouchesInView = false
        hover.delaysTouchesBegan = false
        addGestureRecognizer(hover)
    }

    /// 鼠标动了：压在折叠按钮上就是手指，离开就换回正文的插入符。
    ///
    /// ### 为什么要掺一层 foldControlLayer 的 hitTest
    /// 热区是允许撑到按钮 `frame` 外面的（`CollapsedSectionButton.point(inside:)` 四面各撑了几 pt，
    /// 手小一点才好点），直接比 `frame` 会把撑出来那圈漏掉 —— 手指只在框内才出现、框边缘又变回 I 形。
    /// 交给层的 `hitTest` 判定，两边永远一致。
    ///
    /// ### 为什么离开时要**主动**换回插入符
    /// `NSCursor.set()` 是「只此一改、此后不改」：设成手指之后，只要没人再设一次，指针就一直是手指。
    /// 所以移出按钮必须自己把它设回去（这一带周围全是正文，插回去就是插入符）。
    @objc private func handleFoldHover(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            let point = gesture.location(in: foldControlLayer)
            let overButton = foldControlLayer.hitTest(point, with: nil) is UIButton
            // `NSCursor.pointingHand` / `.iBeam` 都是现成的系统光标实例，直接取来用
            (overButton ? NSCursor.pointingHand : NSCursor.iBeam).set()
        case .ended, .cancelled, .failed:
            NSCursor.iBeam.set()
        default:
            break
        }
    }

#endif

    /// 滚动停下之后再补一次重画（每次滚动都取消上一个任务，只留最后一个）。
    ///
    /// 没有这个兜底的话，快速滚动停下时三角可能还停在「fragment 是估算值 → 跳过」那一步，
    /// 要等用户再动一下才冒出来。
    func scheduleFoldRedraw() {
        foldRedrawWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.positionFoldControls()
            self.positionCheckboxes()
            // 滚动停下后 fragment 才排实（滚动中屏幕外的还是估算值），
            // 视野附近的装饰矩形要重算一遍，不然一直拿着首帧的错坐标画。
            // ⚠️ 这里刻意**不做整篇重算**：屏幕外的块算出来也只是估算值，而整篇重算要逼 TextKit
            // 把全文都排一遍（每个代码块一次 ensuresLayout），长文档上滚一下停一下就会顿一下。
            // 屏幕外的等它滚进视野附近再算，那时才是准的。
            self.refreshDecorationsNearViewport(force: true)
        }
        foldRedrawWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// 把折叠三角摆到每个标题的左边，并给每个「⋯」占位符盖上点击热区。
    ///
    /// ### 位置的三个关键点
    /// 1. **只画已经「完整排版好」的 fragment**。没排到的 fragment 的
    ///    `layoutFragmentFrame` 是估算值（`state` 还停在 `estimatedUsageBounds`），
    ///    差几百像素，画上去一定错位。这里用 `state == .layoutAvailable` 过滤 ——
    ///    被跳过的都在屏幕外，等滚进来排好版自然就画出来了。
    /// 2. **对齐第一行，不是整段**。一个 fragment 常常包着整个段落（好几行），
    ///    直接按 `layoutFragmentFrame` 居中会让三角掉到段落中间。
    ///    用 `textLineFragments.first.typographicBounds` 取首行的矩形。
    /// 3. **层和子 view 的坐标系要统一**。控件层的 `frame = bounds`（跟着 viewport 走），
    ///    所以子 view 用 viewport 坐标 = 文档坐标 − contentOffset，和代码块复制按钮一致。
    func positionFoldControls() {
        // 关掉隐式动画：见 beginDecorationPositioning 的注释（键盘弹出那一下三角会从左上角飞过来）
        beginDecorationPositioning()
        defer { endDecorationPositioning() }
        guard let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              bounds.width > 1 else {
            foldControlLayer.subviews.forEach { $0.removeFromSuperview() }
            return
        }

        foldControlLayer.frame = bounds

        // 全重建：数量不多（每节最多一个三角 + 一个「⋯」），比维护复用池省心
        foldControlLayer.subviews.forEach { $0.removeFromSuperview() }

        let documentStart = contentStorage.documentRange.location
        // 可见范围（viewport 坐标），上下各留 200pt 余量，滚快一点也不闪空
        let visible = CGRect(x: 0, y: -200, width: bounds.width, height: bounds.height + 400)

        // ① 折叠三角：扫出所有锚点（渲染时打在标题第一个字符上的 `.markdownFoldAnchor`）
        var anchors: [(range: NSRange, info: FoldAnchorInfo)] = []
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.markdownFoldAnchor, in: full, options: []) { value, range, _ in
            guard let info = value as? FoldAnchorInfo else { return }
            anchors.append((range, info))
        }

        let theme = renderer.theme
        let side = theme.foldButtonSide
        // 三角贴着正文左边缘往左让出一个间距，正好落在装订线里
        let x = textContainerInset.left - side - theme.foldButtonGap

        for anchor in anchors {
            guard let location = contentStorage.location(documentStart,
                                                         offsetBy: anchor.range.location),
                  let fragment = layoutManager.textLayoutFragment(for: location) else { continue }

            // 只要「完整排版好」的 fragment。
            // `state` 是个 enum 不是 OptionSet：none(0) < estimatedUsageBounds(1)
            // < calculatedUsageBounds(2) < layoutAvailable(3)。
            // 没排到 layoutAvailable 的话 `textLineFragments` 是空的、
            // `layoutFragmentFrame` 也只是估算的，画出来会错位 —— 直接跳过，
            // 反正那都在屏幕外，滚进来变成 layoutAvailable 之后自然就画出来了。
            guard fragment.state == .layoutAvailable else { continue }

            // 首行矩形：typographicBounds 是相对 fragment 自己的坐标，要加上 fragment 的原点
            let lineRect = fragment.textLineFragments.first?.typographicBounds
                ?? CGRect(origin: .zero, size: fragment.layoutFragmentFrame.size)
            var line = CGRect(x: fragment.layoutFragmentFrame.minX + lineRect.minX,
                              y: fragment.layoutFragmentFrame.minY + lineRect.minY,
                              width: lineRect.width,
                              height: lineRect.height)
            // 文档坐标 → viewport 坐标
            line.origin.y -= contentOffset.y
            guard line.intersects(visible) else { continue }

            let button = FoldDisclosureButton()
            button.anchor = anchor.info
            button.apply(isCollapsed: anchor.info.isCollapsed)
            button.frame = CGRect(x: x,
                                  y: line.midY + 5,
                                  width: side,
                                  height: side)
            button.addTarget(self, action: #selector(foldButtonTapped(_:)), for: .touchUpInside)
            foldControlLayer.addSubview(button)
        }

        // ② 「⋯」那个圆角按钮：扫出所有打了 `.markdownCollapsedPlaceholder` 的字符（座位）， 按钮摆在座位上 —— 三个点和圆角框都是它画的，座位自己不画
        var placeholders: [(range: NSRange, info: CollapsedSectionInfo)] = []
        textStorage.enumerateAttribute(.markdownCollapsedPlaceholder, in: full, options: []) { value, range, _ in
            guard let info = value as? CollapsedSectionInfo else { return }
            placeholders.append((range, info))
        }
        guard !placeholders.isEmpty else { return }

        for entry in placeholders {
            guard let start = contentStorage.location(documentStart, offsetBy: entry.range.location),
                  let end = contentStorage.location(documentStart, offsetBy: NSMaxRange(entry.range)),
                  let textRange = NSTextRange(location: start, end: end) else { continue }

            // 字符级矩形：和复选框同一套取法（`enumerateTextSegments`）。
            // 座位是 attachment（只占位、一个像素都不画），这个 API 给的正是它在行里占的那块矩形
            var rect: CGRect?
            layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
                guard !segment.isNull else { return true }
                rect = rect.map { $0.union(segment) } ?? segment
                return true
            }
            guard let rect else { continue }

            // 坐标系换算（推导见 computeCodeBlockFrames 里的注释）：
            // TextKit 的矩形不含 textContainerInset，画在 textView 里要补回来；
            // 再减掉 contentOffset 换成 viewport 坐标。
            //
            // ⚠️ 这里**不再**把矩形四周撑开当热区（老写法是 `insetBy(dx: -8, dy: -8)`）：
            // 按钮自己就是画出来的那个圆角框，frame 一撑大框也跟着变大。
            // 热区改由 `CollapsedSectionButton.point(inside:)` 向外放宽。
            let height = theme.collapsedButtonHeight
            // 垂直对齐：按钮**底边**贴基线（= x 的底部），不是行盒底（那含 j 的降部）。
            // ⚠️ 座位 `.standard` 段矩形的 maxY 是**行盒底**（行高含降部深），不是基线 —— 别拿它当基线用。
            //    真基线要从行片段算：片段原点 + 行原点 + `glyphOrigin.y`（行顶 → 基线的距离）。
            //    实测 H1：行盒 38 = 31(基线) + 7(降部)，`glyphOrigin.y` 正是那个 31。
            //    座位在标题行末尾，标题若折行它在**最后一行**，所以取 last 不取 first。
            var baselineY = rect.maxY   // 行片段还没排版好时的退路：按行盒底摆，下个布局周期会被摆正
            if let seatFragment = layoutManager.textLayoutFragment(for: start),
               let seatLine = seatFragment.textLineFragments.last {
                baselineY = seatFragment.layoutFragmentFrame.minY
                          + seatLine.typographicBounds.minY
                          + seatLine.glyphOrigin.y
            }
            var frame = CGRect(x: rect.minX + textContainerInset.left,
                               y: baselineY - height + textContainerInset.top,
                               // 宽度**读主题**、不读 `rect.width`：座位就是按这个宽度留的空档，一个数管两处才盖得准（改主题宽度时座位和按钮一起变，不会出现按钮压住标题最后一个字）
                               width: theme.collapsedPlaceholderWidth,
                               height: height)
            frame.origin.x -= contentOffset.x
            frame.origin.y -= contentOffset.y
            guard frame.intersects(visible) else { continue }

            let button = CollapsedSectionButton(strokeColor: theme.collapsedPlaceholderColor)
            button.sectionID = entry.info.blockID
            button.frame = frame
            button.addTarget(self, action: #selector(collapsedSectionTapped(_:)), for: .touchUpInside)
            foldControlLayer.addSubview(button)
        }
    }

    /// 点三角 → 折叠 / 展开这个标题下面的一整节
    @objc private func foldButtonTapped(_ sender: FoldDisclosureButton) {
        guard let blockID = sender.anchor?.blockID else { return }
        toggleCollapse(blockID: blockID)
        // 换完内容立刻重摆一次，不用等下个布局周期
        positionFoldControls()
    }

    /// 点「⋯」→ 展开这一节（「⋯」只会出现在已折叠的标题后面，所以点它一定是展开）
    @objc private func collapsedSectionTapped(_ sender: CollapsedSectionButton) {
        guard let blockID = sender.sectionID else { return }
        toggleCollapse(blockID: blockID)
        positionFoldControls()
    }

    /// 折叠 / 展开某个标题下面的一整节：只替换这一节涉及的渲染内容，其它块一个字符都不动。
    ///
    /// - parameter blockID: 要切换的那个**标题块**（从被点到的三角 / 「⋯」上拿来的）
    func toggleCollapse(blockID: UUID) {
        guard let index = documentStore.blocks.firstIndex(where: { $0.id == blockID }),
              let outcome = documentStore.toggleCollapse(blockAt: index) else { return }

        // 先记下光标停在源码的哪个位置：替换会打乱渲染坐标，但源码位置不会变
        let caretSource = documentStore.sourceCaret(forRenderedOffset: selectedRange.location)

        // 旧范围要按当前 storage 长度收一下，防止越界
        let storageLength = (text as NSString).length
        let start = min(outcome.replacedRange.location, storageLength)
        let target = NSRange(location: start,
                             length: min(outcome.replacedRange.length, storageLength - start))

        isApplyingModelChange = true
        if let contentStorage = textLayoutManager?.textContentManager as? NSTextContentStorage {
            contentStorage.performEditingTransaction {
                backingStorage.replaceCharacters(in: target, with: outcome.newContent)
            }
        } else {
            backingStorage.replaceCharacters(in: target, with: outcome.newContent)
        }
        isApplyingModelChange = false

        // 折叠写的这一段会被系统当成一次「文本编辑」记进撤销栈，
        // 但栈里更早的那些记录是针对**折叠前**的渲染文本的，撤销它们会把文本改到
        // 和模型对不上的状态（reconcile 会把差异当成用户输入，直接污染源码）。
        // 所以折叠之后统一清掉撤销栈 —— 代价是丢掉之前的撤销记录，换来一致性。
        //
        // 这里不能用 `disableUndoRegistration` / `enableUndoRegistration` 包住上面的替换：
        // 在「不是系统发起的编辑」这个时机调用它，UIKit 的 _UITextUndoManager 会直接抛
        // `NSInternalInconsistencyException`（实测崩溃，别再改回去）。
        resetUndoHistory()

        lastSyncedString = documentStore.renderedString
        needsCodeBlockRefresh = true

        // 光标原本在被折叠的块里的话，那个位置已经被折叠掉了，挪到块首去
        let caret = min(documentStore.renderedCaret(forSourceOffset: caretSource), (text as NSString).length)
        selectedRange = NSRange(location: caret, length: 0)
    }

}
