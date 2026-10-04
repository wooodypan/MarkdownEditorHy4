//
//  MarkdownTextView+Footnote.swift
//  MarkdownEditorHy4
//
//  脚注的交互：正文里的 `[^1]` 和文末的 `[^1]: 说明` 互相跳。
//
//  `MarkdownTextView.swift` 里只有三行（状态坑位 + 铺层 + 滚动时跟着平移），其余全在这儿。
//

import UIKit

/// 脚注跳转的运行时状态。
///
/// ### 为什么要打包成一个类
/// Swift 的 extension 里不能声明存储属性，而脚注要记的东西有四个（高亮层、正在亮的渲染范围、1 秒后收掉它的任务、回跳要去的位置）。
/// 和 `SearchState` 一个套路：主文件里只声明一个坑位，字段都在这儿 —— 主文件少四行，也不必为了它们去放宽访问级别。
final class FootnoteJumpState {

    /// 落地高亮层：直接复用查找命中那一层（`SearchHighlightLayer`），它干的就是「按矩形刷一层半透明底色」。
    let layer = SearchHighlightLayer()

    /// 正在亮的渲染范围；`nil` = 没在亮。
    ///
    /// 存**渲染范围**而不是矩形：跳转刚落地时目标那一带还没排完版，此刻算出来的矩形是上一轮 viewport 的估算值。
    /// 存范围、每次定位时现算，滚一下就自动修正了。
    var flashRange: NSRange?

    /// 1 秒后收掉高亮的那个任务。连着跳时要先取消上一个，否则上一次的定时器会把这一次的高亮提前抹掉。
    var hideWork: DispatchWorkItem?

    /// 上一次「从正文跳到定义」时，那个引用在源码里的偏移。
    var originOffset: Int?

    /// 上一次跳的脚注 ID（配合上面那个偏移判断「这一跳和上一跳是不是同一条脚注」）。
    var originID: String?

    nonisolated deinit {}
}

extension MarkdownTextView {

    // MARK: 装配

    /// 铺高亮层。绘制逻辑在 `SearchHighlightLayer` 里，这里只管插队秩序。
    ///
    /// 夹在查找高亮层**上面**：两者都是「压在文字下面」的陪衬层（见 `setupSearchDecorations` 的说明），同一时刻一般只有一个在亮，谁在上面都不影响；排在后面只是为了不打扰查找那套的层级假设。
    func setupFootnoteDecorations() {
        footnoteJumpState.layer.isUserInteractionEnabled = false
        insertSubview(footnoteJumpState.layer, aboveSubview: searchHighlightLayer)
    }

    /// 装一个「透明」的点击手势：认出点击位置，但不拦下这次触摸。
    ///
    /// `cancelsTouchesInView = false` 是关键（和图片那条同一个道理）：编辑器还得靠这次触摸去放光标、选中文字，设成 false 之后两边各做各的 —— 光标照常落下去，我们也在同一时刻收到回调。
    func setupFootnoteTapGesture() {
        let tap = FootnoteTapGestureRecognizer(target: self, action: #selector(handleFootnoteTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    // MARK: 跳转

    @objc private func handleFootnoteTap(_ gesture: FootnoteTapGestureRecognizer) {
        guard gesture.state == .ended else { return }

        // ⚠️ 能编辑的时候必须按住 ⌘ 才跳：「点一下」在编辑器里的意思是**把光标放过去改这几个字**，直接跳走等于把人扔到文档另一头，改一个 `[^1]` 都改不成。⌘+ 点 = 「跳到定义」，和 Xcode 一个规矩。
        //    只读时（比如主题页那块预览）没有放光标这回事，点一下就跳。
        if isEditable, !gesture.pressedModifierFlags.contains(.command) { return }

        let point = gesture.location(in: self)

        // 先试引用、再试定义：定义块里也可能提到别的脚注（`[^1]: 参见 [^2]`），那种情况点 `[^2]` 该跳去 `[^2]` 的定义，而不是「跳回 [^1] 的引用处」。
        if let hit = footnoteHit(.markdownFootnoteReference, at: point) {
            let offset = documentStore.sourceCaret(forRenderedOffset: hit.renderedRange.location)
            jumpToFootnoteDefinition(hit.id, fromReferenceOffset: offset)
            return
        }
        if let hit = footnoteHit(.markdownFootnoteDefinition, at: point) {
            jumpBackToFootnoteReference(hit.id)
        }
    }

    /// ⌘+ 点正文里的 `[^1]` → 跳到它的定义处，并把整条定义刷一下底色。
    ///
    /// ### 为什么能直接复用「目录跳转」那一套
    /// 目录跳标题是「拿到一个源码偏移 → 换算成渲染坐标 → 迭代滚动过去」，脚注跳定义是**同一件事**，只是坐标的来源从「标题块的起点」换成了「定义块的起点」（见 `FootnoteIndex.definitionBlockRange`）。
    /// 这是那套 source↔display 映射第四次被复用（代码块复制、目录跳转、脚注、这次的回跳）。
    func jumpToFootnoteDefinition(_ id: String, fromReferenceOffset: Int? = nil) {
        let source = documentStore.fullSource
        guard let block = FootnoteIndex.definitionBlockRange(for: id, in: source) else { return }

        // 记住「从哪儿跳过来的」：等下点定义回跳时优先回到这一个引用 —— 同一个脚注常被引用好几次，回到「刚看的那一处」比回到「第一处」更符合预期。
        footnoteJumpState.originID = id
        footnoteJumpState.originOffset = fromReferenceOffset

        moveCaret(toSourceOffset: block.location, flashingSourceRange: block)
    }

    /// ⌘+ 点文末的定义 → 跳回正文里提到它的地方，并把那个 `[^1]` 刷一下底色。
    ///
    /// ### 回到哪一个引用
    /// 上一次正是从正文某个引用跳过来的（同一条脚注），就回那一个；否则回**第一个**引用。
    /// 一篇里同一个脚注被引用多次时，「原路返回」比「一律回第一处」好用得多。
    func jumpBackToFootnoteReference(_ id: String) {
        let source = documentStore.fullSource
        let ranges = FootnoteIndex.referenceRanges(for: id, in: source)
        let cameFromHere = footnoteJumpState.originID == id ? footnoteJumpState.originOffset : nil
        let target = ranges.first { $0.location == cameFromHere } ?? ranges.first

        guard let range = target else { return }        // 这条脚注在正文里根本没被引用过，跳不动
        moveCaret(toSourceOffset: range.location, flashingSourceRange: range)
    }

    /// 光标落到某个源码位置 + 滚进视野 + 把那一段刷亮。
    private func moveCaret(toSourceOffset offset: Int, flashingSourceRange sourceRange: NSRange) {
        let length = (text as NSString).length
        let caret = min(max(0, documentStore.renderedCaret(forSourceOffset: offset)), length)
        selectedRange = NSRange(location: caret, length: 0)
        scrollToRenderedOffset(caret)
        startFootnoteFlash(forSourceRange: sourceRange)
    }

    // MARK: 落地高亮

    /// 给一段源码刷上高亮，`theme.footnote.flashDuration` 秒后自己消失。
    ///
    /// ### 为什么不直接改 textStorage 的 `.backgroundColor`
    /// 改属性会走一遍「内容变了」的同步链路（撤销记账、模型回写全都挂在上面），为了亮 1 秒去动它是拿锤子敲钉子。
    /// 所以和查找高亮一样走 overlay：文字一个字节都不动，屏幕上多一层半透明色块就完事。
    private func startFootnoteFlash(forSourceRange sourceRange: NSRange) {
        let state = footnoteJumpState
        state.hideWork?.cancel()
        state.flashRange = documentStore.renderedRange(forSourceRange: sourceRange)
        positionFootnoteFlash()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.footnoteJumpState.flashRange = nil
            self.footnoteJumpState.hideWork = nil
            self.positionFootnoteFlash()
        }
        state.hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + renderer.theme.footnote.flashDuration, execute: work)
    }

    /// 把高亮的矩形搬到屏幕上（滚动回调里每帧都会走到，见 `MarkdownTextView` 的 `contentOffsetObservation`）。
    func positionFootnoteFlash() {
        let state = footnoteJumpState
        state.layer.frame = bounds

        guard let rendered = state.flashRange,
              let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              rendered.length > 0,
              rendered.location >= 0,
              NSMaxRange(rendered) <= textStorage.length else {
            state.layer.isHidden = true
            state.layer.setEntries([], normal: .clear, current: .clear)
            return
        }

        // 矩形现算而不缓存（见 `FootnoteJumpState.flashRange` 的注释）：只在亮着的那 1 秒内会走到这里。
        let visible = CGRect(x: 0, y: -200, width: bounds.width, height: bounds.height + 400)
        var entries: [(rect: CGRect, isCurrent: Bool)] = []

        for frame in segmentFrames(forRenderedRange: rendered,
                                   contentStorage: contentStorage,
                                   layoutManager: layoutManager) {
            var rect = frame
            rect.origin.x -= contentOffset.x
            rect.origin.y -= contentOffset.y
            guard rect.intersects(visible) else { continue }
            entries.append((rect: rect.insetBy(dx: -2, dy: -1), isCurrent: true))
        }

        state.layer.isHidden = entries.isEmpty
        let color = renderer.theme.footnote.flashColor
        state.layer.setEntries(entries, normal: color, current: color)
    }

    // MARK: 命中测试

    /// 屏幕坐标 `point` 上盖着的是哪个脚注引用（返回它的 ID）。
    func footnoteReferenceID(at point: CGPoint) -> String? {
        footnoteHit(.markdownFootnoteReference, at: point)?.id
    }

    /// 屏幕坐标 `point` 上盖着的是哪条脚注定义（返回它的 ID）。整块定义都算命中 —— 它是「文末那一坨」，点哪儿都是它。
    func footnoteDefinitionID(at point: CGPoint) -> String? {
        footnoteHit(.markdownFootnoteDefinition, at: point)?.id
    }

    /// 在 `point` 处找打了某个脚注属性的那几个字符，返回 ID 和它们占的**渲染范围**。
    ///
    /// ### 怎么定位的
    /// 和 `imageAttachment(at:)` 同一套：先把点换算到 TextKit 的 fragment 坐标系，找到包含这个点的那一行，再在这一行覆盖的字符范围里找打了那个属性的那几段，最后按**字符级矩形**判断点是不是真的落在标记上（一行里可以有好几个引用，不能只看行）。
    private func footnoteHit(_ key: NSAttributedString.Key,
                             at point: CGPoint) -> (id: String, renderedRange: NSRange)? {
        guard let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              bounds.width > 1 else { return nil }

        let target = CGPoint(x: point.x + contentOffset.x - textContainerInset.left,
                             y: point.y + contentOffset.y - textContainerInset.top)

        let documentStart = contentStorage.documentRange.location
        var found: (id: String, renderedRange: NSRange)?

        layoutManager.enumerateTextLayoutFragments(from: documentStart,
                                                   options: [.ensuresLayout]) { fragment in
            guard fragment.layoutFragmentFrame.contains(target) else { return true }

            let start = contentStorage.offset(from: documentStart, to: fragment.rangeInElement.location)
            let length = contentStorage.offset(from: fragment.rangeInElement.location,
                                               to: fragment.rangeInElement.endLocation)
            let range = NSRange(location: start, length: max(0, length))
            guard range.location >= 0, NSMaxRange(range) <= textStorage.length else { return true }

            textStorage.enumerateAttribute(key, in: range, options: []) { value, marked, _ in
                guard let id = value as? String, let rect = documentRect(of: marked) else { return }
                // 标记是上标小字，占的那块矩形很小，命中区往外放一圈才点得中。
                // ⚠️ 只放宽**判定**，不放大任何被画出来的东西（这点和折叠三角那条规矩一致）
                if rect.insetBy(dx: -3, dy: -4).contains(target) { found = (id, marked) }
            }
            return false
        }
        return found
    }

    /// 某几个字符在**文档坐标系**下占的矩形（不含 `textContainerInset`）。
    ///
    /// 字符级矩形只能靠 `enumerateTextSegments` —— 行级的 `layoutFragmentFrame` 给的是一整行。
    private func documentRect(of range: NSRange) -> CGRect? {
        guard let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else { return nil }

        let documentStart = contentStorage.documentRange.location
        guard let startLocation = contentStorage.location(documentStart, offsetBy: range.location),
              let endLocation = contentStorage.location(documentStart, offsetBy: NSMaxRange(range)),
              let textRange = NSTextRange(location: startLocation, end: endLocation) else { return nil }

        var rect: CGRect?
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
            guard !segment.isNull else { return true }
            rect = rect.map { $0.union(segment) } ?? segment
            return true
        }
        return rect
    }
}

/// 一个「记得按下时修饰键」的点击手势。
///
/// ### 为什么非得自己写一个
/// `UITapGestureRecognizer` 不告诉外面「这次点击按住修饰键没有」，而我们要的就是「⌘ + 点才跳」。
/// 手势自己的 `touchesBegan` 里能拿到 `UIEvent`，顺手把 `modifierFlags` 存下来就行 ——在子类里重写（不是扩展里），因为重写只能发生在子类声明上。
private final class FootnoteTapGestureRecognizer: UITapGestureRecognizer {

    /// 最近一次触摸按下时的修饰键（⌘ / ⇧ / ⌥ …）。
    ///
    /// ⚠️ 不能叫 `modifierFlags`：基类 `UIGestureRecognizer` 自己已经有一个同名属性（只读），拿存储属性去覆盖会直接编不过。
    private(set) var pressedModifierFlags: UIKeyModifierFlags = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        pressedModifierFlags = event.modifierFlags
        super.touchesBegan(touches, with: event)
    }
}
