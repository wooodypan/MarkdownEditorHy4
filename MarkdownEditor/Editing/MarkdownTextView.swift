//
//  MarkdownTextView.swift
//  MarkdownEditorHy4
//
//  UI 层：TextKit 2 模式下的 UITextView 子类，整个编辑器的对外门面
//

import UIKit

/// 一个能「所见即所得显示 markdown、但复制出来还是源码」的 UITextView。
///
/// ### 数据流（一次编辑的完整闭环）
/// ```
/// 用户敲键盘
///   → 系统把字符插进 UITextView 的 NSTextStorage
///   → textViewDidChange
///   → 和上一版渲染文本做 diff，找出改动范围
///   → MarkdownDocumentStore.applyEdit（渲染范围 → 源码范围，局部 parse，局部渲染）
///   → 拿到 EditOutcome，局部替换 NSTextStorage
///   → 刷新光标位置
/// ```
///
/// ### 为什么不在 `shouldChangeTextIn` 里拦截？
/// 方案里原本打算在那里拦截并自己接管替换。但那样会绕过系统的输入法（marked text）机制，
/// 中文拼音输入会直接坏掉。所以改成「**先让系统改，改完再 diff 回写**」，
/// 中文输入、自动纠错、听写全都能正常工作。
final class MarkdownTextView: UITextView, MarkdownAttachmentHost {

    // MARK: 核心组件

    let renderer: MarkupToAttributedRenderer
    let documentStore: MarkdownDocumentStore
    private let editController: MarkdownEditController
    private let pasteboardController: MarkdownPasteboardController

    /// 相对路径图片的基准目录（demo 里指向 App 包资源目录）
    var imageBaseURL: URL? {
        get { renderer.imageBaseURL }
        set { renderer.imageBaseURL = newValue }
    }

    // MARK: 状态

    /// 上一次同步给模型的渲染文本。textView 的实际内容和它 diff，就能定位用户改了哪一段。
    private var lastSyncedString = ""
    /// 正在把模型改动写回 textView —— 这段时间内忽略 textViewDidChange，避免递归
    private(set) var isApplyingModelChange = false
    /// 上一次渲染时用的容器宽度，窗口尺寸变了要整篇重排
    private var renderedWidth: CGFloat = 0
    /// 有一整篇内容等着写进 textStorage（真正的写入要等到布局阶段）
    private var pendingFullReplace = false
    /// 输入法组合还没结束，等结束（markedTextRange == nil）再补一次排版
    private var needsReconcileAfterComposition = false

    // MARK: 代码块装饰（整块背景矩形 + 右上角复制按钮）

    /// 背景层：加在最底层，画在文字下面
    private let codeBlockBackgroundLayer = CodeBlockBackgroundLayer()
    /// 控件层：加在最上层，放复制按钮
    private let codeBlockControlLayer = CodeBlockControlLayer()
    /// 已经算好的代码块矩形（**文档坐标系**，滚动时只需要整体平移）
    private var codeBlockFrames: [(info: CodeBlockInfo, frame: CGRect)] = []
    /// 下一个布局周期要不要重算矩形（文本内容/宽度变了才需要）
    private var needsCodeBlockRefresh = false
    /// 上次重算时的「签名」，用来判断内容或宽度有没有变
    private var lastCodeBlockSignature = ""
    /// 首帧 TextKit 还没排出 fragment，允许重试几次
    private var codeBlockRetryCount = 0

    // MARK: 折叠三角（顶层块左侧，浮在正文左边的装订线里）

    /// 三角所在的控件层，加在最上层，只让按钮吃点击
    private let foldControlLayer = FoldControlLayer()
    /// 滚动停下之后补一次重画的定时任务（TextKit 排版比滚动事件慢半拍，见 positionFoldButtons）
    private var foldRedrawWork: DispatchWorkItem?
    /// 监听滚动：滚动只改位置，不重算布局
    private var contentOffsetObservation: NSKeyValueObservation?

    // MARK: - 引用块装饰（左侧绿条）——
    //
    // 绿条现在是**每行一个 NSTextAttachment**，由 renderer 在 visitBlockQuote 阶段插入，
    // 跟随该行 layout，不需要任何 fragment 测量。详见 QuoteBarAttachment 的注释。
    // 早期版本尝试在 UI 层盖 UIView 算 fragment 位置画整段竖条，但 TextKit 2 的
    // layoutFragmentFrame 对 viewport 外的 fragment 永远是估算值（state=3 LayoutAvailable
    // 但 usage bounds 是估算的），用 setContentOffset / invalidateLayout / 离屏 layout
    // 都拿不到真实坐标，差 360+ 像素。改用 attachment 方案后零测量、零成本。

    // MARK: 初始化

    init(markdown: String = "") {
        let renderer = MarkupToAttributedRenderer(theme: .default, containerWidth: 600)
        let store = MarkdownDocumentStore(renderer: renderer)
        self.renderer = renderer
        self.documentStore = store
        self.editController = MarkdownEditController()
        self.pasteboardController = MarkdownPasteboardController()

        // 用 TextKit 2 的标准配置：UITextView 自己会创建 NSTextLayoutManager + NSTextContentStorage
        super.init(frame: .zero, textContainer: nil)

        editController.textView = self
        pasteboardController.textView = self
        delegate = editController
        renderer.attachmentHost = self
        imageBaseURL = Bundle.main.resourceURL

        configureTextView()
        setupCodeBlockDecorations()
        setupFoldDecorations()
        setMarkdown(markdown)
    }

    required init?(coder: NSCoder) {
        // demo 全部用代码搭建界面，不走 storyboard
        fatalError("MarkdownTextView 不支持从 coder 解档")
    }

    private func configureTextView() {
        font = renderer.theme.bodyFont
        textColor = renderer.theme.textColor
        backgroundColor = .systemBackground
        alwaysBounceVertical = true
        // 左边多留一条「装订线」给折叠三角。三角浮在这条带子里，不占正文字符位，
        // 多行文字的左边缘才对得齐（它要是插在文本流里，第一行会被推歪）。
        let baseInset: CGFloat = 16
        textContainerInset = UIEdgeInsets(top: baseInset,
                                          left: baseInset + renderer.theme.foldGutterWidth,
                                          bottom: 32,
                                          right: baseInset)

        // 下面几项很关键：markdown 编辑器必须拿到「用户原始输入的字符」，
        // 否则系统会把引号变成弯引号、粘贴时自动补空格，源码就和用户输入对不上了
        smartDashesType = .no
        smartQuotesType = .no
        smartInsertDeleteType = .no
        autocapitalizationType = .none
    }

    // MARK: 对外接口

    /// 整篇替换内容
    func setMarkdown(_ markdown: String) {
        documentStore.load(markdown: markdown, containerWidth: currentContainerWidth)
        renderedWidth = currentContainerWidth
        lastSyncedString = documentStore.renderedString

        // 真正的 storage 写入推迟到布局阶段做（原因见 applyPendingFullReplace 的注释）。
        // 这里立刻跑一次 layoutIfNeeded，保证 setMarkdown 返回后内容就已经就位。
        pendingFullReplace = true
        setNeedsLayout()
        layoutIfNeeded()
        // 兜底：view 还没挂到 window 上（比如 init 刚结束）时 layoutSubviews 不会来，这里补一次
        if pendingFullReplace { applyPendingFullReplace() }
    }

    /// 把模型里的渲染结果整篇写进 textStorage。
    ///
    /// ### 为什么必须放在 `layoutSubviews` 里做（TextKit 2 的坑，别删）
    /// 在按钮事件里同步整篇替换，TextKit 2 会把所有 attachment 的 view 从视图树里摘掉，
    /// 却**不会**为新的 attachment 建 view —— 于是「图片和圆点全部消失，滚一下才回来」。
    /// 只有放在布局阶段做，TextKit 才会跟着重建 view。
    ///
    /// 试过但**都无效**的绕法（别再试一遍了）：
    /// `invalidateLayout(for:)`、`ensureLayout(for:)`、`textViewportLayoutController.layoutViewport()`、
    /// 抖动 `textContainer.size`、把 `attributedText` 清空再赋值、拆成「先清空再回填」两步、
    /// 让「源码没变的块」复用旧的 attachment 实例。
    private func applyPendingFullReplace() {
        pendingFullReplace = false
        isApplyingModelChange = true
        replaceWholeStorage(with: documentStore.attributedDocument)
        isApplyingModelChange = false
    }

    /// 整篇替换 backingStorage 的内容（包在编辑事务里，确保 TextKit 收到「内容变了」的通知）
    private func replaceWholeStorage(with attributed: NSAttributedString) {
        let whole = NSRange(location: 0, length: backingStorage.length)
        if let contentStorage = textLayoutManager?.textContentManager as? NSTextContentStorage {
            contentStorage.performEditingTransaction {
                backingStorage.replaceCharacters(in: whole, with: attributed)
            }
        } else {
            backingStorage.replaceCharacters(in: whole, with: attributed)
        }
    }

    /// 当前源码（和「全选复制」出来的内容完全一致）
    var markdownSource: String { documentStore.fullSource }

    /// 容器可用宽度（图片、分隔线按它算尺寸）
    var currentContainerWidth: CGFloat {
        let width = bounds.width - textContainerInset.left - textContainerInset.right
        return max(120, width - textContainer.lineFragmentPadding * 2)
    }

    // MARK: 布局

    override func layoutSubviews() {
        super.layoutSubviews()

        // 有整篇内容等着写入：现在就写（这一步必须在布局阶段做，见 applyPendingFullReplace 的注释）
        if pendingFullReplace { applyPendingFullReplace() }

        // 代码块背景矩形跟着布局走（内容或宽度变了会重算，纯滚动只平移）
        updateCodeBlockDecorationsIfNeeded()
        // 折叠三角同理，只是它每次都按 fragment 的当前位置重摆
        positionFoldButtons()

        // 容器宽度变了（转屏、Catalyst 拉窗口）→ 图片尺寸要跟着变，整篇重排一次
        let width = currentContainerWidth
        guard abs(width - renderedWidth) > 1, !isApplyingModelChange, markedTextRange == nil else { return }
        renderedWidth = width
        reRenderPreservingCaret()
    }

    /// 整篇重新渲染，但保持光标停在原来的源码位置
    private func reRenderPreservingCaret() {
        let sourceCaret = documentStore.sourceCaret(forRenderedOffset: selectedRange.location)
        documentStore.load(markdown: documentStore.fullSource, containerWidth: renderedWidth)

        isApplyingModelChange = true
        replaceWholeStorage(with: documentStore.attributedDocument)
        isApplyingModelChange = false

        lastSyncedString = documentStore.renderedString
        needsCodeBlockRefresh = true

        let caret = min(documentStore.renderedCaret(forSourceOffset: sourceCaret), (text as NSString).length)
        selectedRange = NSRange(location: caret, length: 0)
    }

    // MARK: - 代码块装饰（整块一个矩形背景 + 右上角复制按钮）

    /// 铺好两层容器：背景在**最底层**（被文字压着），复制按钮在**最上层**（能点）
    private func setupCodeBlockDecorations() {
        // 背景层要插到 index 0，否则会盖住文字
        insertSubview(codeBlockBackgroundLayer, at: 0)
        addSubview(codeBlockControlLayer)

        // 滚动时只做平移，不重算 —— 重算要走 TextKit 布局，滚动中做太贵
        contentOffsetObservation = observe(\.contentOffset, options: []) { [weak self] _, _ in
            self?.positionCodeBlockDecorations()
            self?.positionFoldButtons()
            // TextKit 排版比滚动事件慢半拍：滚动过程中刚进 viewport 的 fragment
            // 可能还是估算值（三角被跳过）。停一下再补一次，三角就不会「滚过去才冒出来」。
            self?.scheduleFoldRedraw()
        }
    }

    /// 每次布局时决定：是「重算矩形」还是「只平移」。
    /// 只有文本内容或宽度变了才需要重算，纯滚动走平移分支。
    private func updateCodeBlockDecorationsIfNeeded() {
        let signature = "\(textStorage.length)/\(Int(bounds.width))"
        guard needsCodeBlockRefresh || signature != lastCodeBlockSignature else {
            positionCodeBlockDecorations()
            return
        }
        lastCodeBlockSignature = signature
        needsCodeBlockRefresh = false
        refreshCodeBlockDecorations()
    }

    private func refreshCodeBlockDecorations() {
        let (frames, pending) = computeCodeBlockFrames()
        codeBlockFrames = frames

        // 文本里已经有代码块，但 TextKit 还没排出 fragment（首帧常见）→ 下一帧再算
        if pending, codeBlockRetryCount < 5 {
            codeBlockRetryCount += 1
            needsCodeBlockRefresh = true
            setNeedsLayout()
        } else {
            codeBlockRetryCount = 0
        }
        positionCodeBlockDecorations()
    }

    /// 算出每个代码块在**文档坐标系**下占的矩形。
    ///
    /// - returns: `(frames, pending)`。`pending == true` 表示「文本里有代码块，
    ///            但 TextKit 还没把它排出来」，需要等下一个布局周期重试。
    private func computeCodeBlockFrames() -> (frames: [(info: CodeBlockInfo, frame: CGRect)], pending: Bool) {
        guard let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              bounds.width > 1 else { return ([], false) }

        // 1) 扫出所有代码块区间（渲染时打的 `.markdownCodeBlock` 标记）
        var marked: [(NSRange, CodeBlockInfo)] = []
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.markdownCodeBlock, in: full, options: []) { value, range, _ in
            guard let info = value as? CodeBlockInfo else { return }
            marked.append((range, info))
        }
        guard !marked.isEmpty else { return ([], false) }

        // 2) 横向范围固定：去掉 textContainerInset 左右内间距后的整行宽度
        let width = max(0, bounds.width - textContainerInset.left - textContainerInset.right)
        let x = textContainerInset.left
        let padding = renderer.theme.codeBlockVerticalPadding
        let documentStart = contentStorage.documentRange.location

        var frames: [(info: CodeBlockInfo, frame: CGRect)] = []
        frames.reserveCapacity(marked.count)

        for (range, info) in marked {
            // NSTextContentStorage 用的是 UTF-16 偏移，和 NSRange.location 同一套坐标
            guard let startLocation = contentStorage.location(documentStart, offsetBy: range.location),
                  let endLocation = contentStorage.location(documentStart, offsetBy: NSMaxRange(range)) else { continue }

            // 3) 纵向范围：把这个区间覆盖到的所有 layout fragment 的外接矩形求出来
            var top: CGFloat?
            var bottom: CGFloat = 0

            layoutManager.enumerateTextLayoutFragments(from: startLocation, options: [.ensuresLayout]) { fragment in
                let rect = fragment.layoutFragmentFrame
                if !rect.isNull, rect.height > 0 {
                    top = min(top ?? rect.minY, rect.minY)
                    bottom = max(bottom, rect.maxY)
                }
                // 还没走到这个代码块的结尾就继续（offset > 0 表示 endLocation 在后面）
                return contentStorage.offset(from: fragment.rangeInElement.endLocation, to: endLocation) > 0
            }

            guard let top else { continue }
            frames.append((info, CGRect(x: x,
                                        y: top - padding,
                                        width: width,
                                        height: (bottom - top) + padding * 2)))
        }
        return (frames, frames.isEmpty)
    }

    /// 把文档坐标的矩形搬到屏幕上，铺背景 view 和复制按钮
    private func positionCodeBlockDecorations() {
        codeBlockBackgroundLayer.frame = bounds
        codeBlockControlLayer.frame = bounds

        // 代码块数量很少，每次重建比维护复用池省心
        codeBlockBackgroundLayer.subviews.forEach { $0.removeFromSuperview() }
        codeBlockControlLayer.subviews.forEach { $0.removeFromSuperview() }

        let theme = renderer.theme
        let buttonSize = CodeBlockCopyButton.size
        let margin: CGFloat = 6
        // 可见范围，上下各留 200pt 余量，滚快一点也不会闪出空白
        let visible = CGRect(x: 0, y: -200, width: bounds.width, height: bounds.height + 400)

        for (info, documentFrame) in codeBlockFrames {
            // 文档坐标 → 本层坐标：减掉滚动偏移
            var frame = documentFrame
            frame.origin.x -= contentOffset.x
            frame.origin.y -= contentOffset.y

            guard frame.intersects(visible) else { continue }

            let background = UIView(frame: frame)
            background.backgroundColor = theme.codeBlockBackground
            background.layer.cornerRadius = theme.codeBlockCornerRadius
            background.isUserInteractionEnabled = false
            codeBlockBackgroundLayer.addSubview(background)

            let button = CodeBlockCopyButton()
            button.codeBlock = info
            button.frame = CGRect(x: frame.maxX - margin - buttonSize,
                                  y: frame.minY + margin,
                                  width: buttonSize,
                                  height: buttonSize)
            button.addTarget(self, action: #selector(copyCodeBlock(_:)), for: .touchUpInside)
            codeBlockControlLayer.addSubview(button)
        }
    }

    /// 点右上角按钮：把该代码块的正文（不含 ``` 围栏）放进系统剪贴板
    @objc private func copyCodeBlock(_ sender: CodeBlockCopyButton) {
        guard let info = sender.codeBlock else { return }
        UIPasteboard.general.string = info.code
        sender.flashCopied()
    }

    // MARK: - 折叠 / 展开（顶层块左侧的小三角）

    /// 铺好三角所在的控件层（最上层，只有按钮吃点击）
    private func setupFoldDecorations() {
        addSubview(foldControlLayer)
    }

    /// 滚动停下之后再补一次重画（每次滚动都取消上一个任务，只留最后一个）。
    ///
    /// 没有这个兜底的话，快速滚动停下时三角可能还停在「fragment 是估算值 → 跳过」那一步，
    /// 要等用户再动一下才冒出来。
    private func scheduleFoldRedraw() {
        foldRedrawWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.positionFoldButtons()
        }
        foldRedrawWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// 把每个可折叠块的三角摆到它第一行的左边（装订线里）。
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
    private func positionFoldButtons() {
        guard let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              bounds.width > 1 else {
            foldControlLayer.subviews.forEach { $0.removeFromSuperview() }
            return
        }

        foldControlLayer.frame = bounds

        // 扫出所有折叠锚点（渲染时打在块第一个字符上的 `.markdownFoldAnchor`）
        var anchors: [(range: NSRange, info: FoldAnchorInfo)] = []
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.markdownFoldAnchor, in: full, options: []) { value, range, _ in
            guard let info = value as? FoldAnchorInfo else { return }
            anchors.append((range, info))
        }

        // 全重建：块数量不多，比维护复用池省心
        foldControlLayer.subviews.forEach { $0.removeFromSuperview() }
        guard !anchors.isEmpty else { return }

        let theme = renderer.theme
        let side = theme.foldButtonSide
        // 三角贴着正文左边缘往左让出一个间距，正好落在装订线里
        let x = textContainerInset.left - side - theme.foldButtonGap
        let documentStart = contentStorage.documentRange.location
        // 可见范围（viewport 坐标），上下各留 200pt 余量，滚快一点也不闪空
        let visible = CGRect(x: 0, y: -200, width: bounds.width, height: bounds.height + 400)

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
                                  y: line.midY - side / 2,
                                  width: side,
                                  height: side)
            button.addTarget(self, action: #selector(foldButtonTapped(_:)), for: .touchUpInside)
            foldControlLayer.addSubview(button)
        }
    }

    /// 点三角 → 折叠 / 展开它那一块
    @objc private func foldButtonTapped(_ sender: FoldDisclosureButton) {
        guard let blockID = sender.anchor?.blockID else { return }
        toggleCollapse(blockID: blockID)
        // 换完内容立刻重摆一次，不用等下个布局周期
        positionFoldButtons()
    }

    /// 折叠 / 展开某一块：只替换这一块的渲染内容，其它块一个字符都不动。
    ///
    /// - parameter blockID: 要切换的块（从被点到的 attachment 上拿来的）
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
        undoManager?.removeAllActions()

        lastSyncedString = documentStore.renderedString
        needsCodeBlockRefresh = true

        // 光标原本在被折叠的块里的话，那个位置已经被折叠掉了，挪到块首去
        let caret = min(documentStore.renderedCaret(forSourceOffset: caretSource), (text as NSString).length)
        selectedRange = NSRange(location: caret, length: 0)
    }

    // MARK: - 引用块装饰（左侧绿条）
    //
    // 绿条现在是**每行一个 NSTextAttachment**，由 renderer 在 visitBlockQuote 阶段插入，
    // 跟随该行 layout，不需要任何 fragment 测量。详见 QuoteBarAttachment.swift 的注释。
    //
    // 早期版本（commit 撤回过）尝试在 UI 层盖 UIView 算 fragment 位置画整段竖条：
    // TextKit 2 的 `NSTextLayoutFragment.layoutFragmentFrame` 对 viewport 外的 fragment
    // **永远是估算值**（state=3 LayoutAvailable 但 usage bounds 是估算的），用
    // `setContentOffset` / `invalidateLayout` / `ensureLayout` / 离屏 NSLayoutManager
    // 全部拿不到真实坐标，差 360+ 像素。改用 attachment 方案后零测量、零成本，
    // 绿条永远贴在正确的行首。

    // MARK: - 编辑管线

    /// 系统已经把文本改完了（用户敲键、自动纠错、粘贴…），我们 diff 出改动范围再回写给模型。
    func reconcileFromTextChange() {
        guard !isApplyingModelChange else { return }

        // 输入法还在组合：先不动，等 unmarkText 之后再补
        guard markedTextRange == nil else {
            needsReconcileAfterComposition = true
            return
        }

        let current = text as NSString
        let previous = lastSyncedString as NSString
        guard current.length != previous.length || !current.isEqual(to: lastSyncedString) else { return }

        // 公共前缀 + 公共后缀，中间那段就是真正变了的
        let prefix = MarkdownTextView.commonPrefixLength(previous, current)
        let maxSuffix = min(previous.length, current.length) - prefix
        var suffix = 0
        while suffix < maxSuffix,
              previous.character(at: previous.length - 1 - suffix) == current.character(at: current.length - 1 - suffix) {
            suffix += 1
        }

        var changedRange = NSRange(location: prefix, length: max(0, previous.length - prefix - suffix))
        let replacement = current.substring(with: NSRange(location: prefix,
                                                          length: max(0, current.length - prefix - suffix)))

        // 用光标位置校正插入点 —— 纯字符串 diff 遇到「插入重复字符」会算错位置。
        //
        // ### 踩过的坑（按回车多跳两行，别删）
        // 光标停在 `# 标题一⏎|⏎这是` 按回车，文本从 `# 标题一⏎⏎` 变成 `# 标题一⏎⏎⏎`。
        // 公共前缀算法一路匹配到 offset 7（三个换行长得一模一样），于是认为插入发生在
        // **最后一个换行之后** —— 源码确实只多了一个换行看起来没问题，
        // 但光标被算到了正文开头，用户看到的就是「按一下回车跳了三行」。
        //
        // 光标不会说谎：变化之后它一定停在刚插入的内容后面，
        // 所以「光标位置 − 插入长度」就是真正的插入点。
        // 只有光标处的内容确实等于 diff 出来的替换内容时才采信，防止异常场景改坏。
        let inserted = (replacement as NSString).length
        let inferred = selectedRange.location - inserted
        if inferred >= 0,
           inferred + inserted <= current.length,
           current.substring(with: NSRange(location: inferred, length: inserted)) == replacement {
            changedRange.location = inferred
        }

        applyEdit(renderedRange: changedRange, replacementText: replacement, alreadyAppliedToTextStorage: true)
    }

    /// 输入法确认输入后会走到这里
    override func unmarkText() {
        super.unmarkText()
        needsReconcileAfterComposition = true
    }

    /// 供 EditController 在光标变动时调用：输入法结束后补排版
    func reconcileIfNeededAfterComposition() {
        guard needsReconcileAfterComposition, markedTextRange == nil else { return }
        needsReconcileAfterComposition = false
        reconcileFromTextChange()
    }

    /// 走一遍「模型增量编辑 → 局部回写 textView」的管线。
    ///
    /// - parameter renderedRange:              改动发生在渲染文本的哪个范围（**旧**坐标系）
    /// - parameter replacementText:            改成了什么
    /// - parameter alreadyAppliedToTextStorage: textView 里是不是已经改好了。
    ///   用户敲键盘时为 true（系统已经插进去了），我们自己发起的删除（cut）时为 false。
    func applyEdit(renderedRange: NSRange,
                   replacementText: String,
                   alreadyAppliedToTextStorage: Bool) {
        let outcome = documentStore.applyEdit(inRenderedRange: renderedRange,
                                              replacementText: replacementText,
                                              containerWidth: currentContainerWidth)

        // 如果 textView 里已经改好了，旧范围要按增删量伸缩，才能对上当前文本的坐标
        let delta = alreadyAppliedToTextStorage ? (replacementText as NSString).length - renderedRange.length : 0
        let rawRange = NSRange(location: outcome.replacedRange.location,
                               length: max(0, outcome.replacedRange.length + delta))
        let storageLength = (text as NSString).length
        let targetRange = NSRange(location: min(rawRange.location, storageLength),
                                  length: min(rawRange.length, storageLength - min(rawRange.location, storageLength)))

        isApplyingModelChange = true
        // 不注册 undo：编辑动作已经由系统记录过一次了，再记一次会让撤销栈错乱
        undoManager?.disableUndoRegistration()

        if let contentStorage = textLayoutManager?.textContentManager as? NSTextContentStorage {
            // TextKit 2 的事务接口：一次提交，TextKit 自己算最小失效区域做增量重排
            contentStorage.performEditingTransaction {
                backingStorage.replaceCharacters(in: targetRange, with: outcome.newContent)
            }
        } else {
            backingStorage.replaceCharacters(in: targetRange, with: outcome.newContent)
        }

        undoManager?.enableUndoRegistration()
        isApplyingModelChange = false

        lastSyncedString = documentStore.renderedString
        needsCodeBlockRefresh = true

        let caret = min(outcome.caretRenderedOffset, (text as NSString).length)
        if selectedRange.location != caret || selectedRange.length != 0 {
            selectedRange = NSRange(location: caret, length: 0)
        }
    }

    /// 真正用来改内容的 NSTextStorage
    private var backingStorage: NSTextStorage {
        if let contentStorage = textLayoutManager?.textContentManager as? NSTextStorageObserving,
           let storage = contentStorage.textStorage {
            return storage
        }
        return textStorage
    }

    /// 求两个字符串的公共前缀长度（按 UTF-16 单元算）
    private static func commonPrefixLength(_ a: NSString, _ b: NSString) -> Int {
        let max = min(a.length, b.length)
        var index = 0
        while index < max, a.character(at: index) == b.character(at: index) { index += 1 }
        return index
    }

    // MARK: - 剪贴板

    /// 把选区对应的 **markdown 源码** 放进剪贴板
    @discardableResult
    func copyMarkdownSourceToPasteboard() -> Bool {
        pasteboardController.handleCopy()
    }

    override func copy(_ sender: Any?) {
        // 接管复制：放进去的是源码文本，不是渲染出来的富文本
        if pasteboardController.handleCopy() { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        guard pasteboardController.handleCopy(), selectedRange.length > 0 else {
            super.cut(sender)
            return
        }
        // 复制成功后删掉选区，走同一套增量管线（保证源码和渲染同时更新）
        applyEdit(renderedRange: selectedRange, replacementText: "", alreadyAppliedToTextStorage: false)
    }

    override func paste(_ sender: Any?) {
        // 剪贴板里是图片：存成临时文件，插入 ![](路径) 源码
        if pasteboardController.handlePasteImage() { return }
        super.paste(sender)
    }

    /// 供 PasteboardController 调用：把一段 markdown 源码插到光标处
    func insertMarkdownSource(_ source: String) {
        applyEdit(renderedRange: selectedRange, replacementText: source, alreadyAppliedToTextStorage: false)
    }

    // MARK: - MarkdownAttachmentHost

    /// 图片异步加载完尺寸变了，通知 TextKit 重新排版这一个小范围
    func invalidateLayout(for attachment: NSTextAttachment) {
        var found: NSRange?
        let full = NSRange(location: 0, length: backingStorage.length)
        backingStorage.enumerateAttribute(.attachment, in: full, options: []) { value, range, stop in
            guard let candidate = value as? NSTextAttachment else { return }
            if candidate === attachment {
                found = range
                stop.pointee = true
            }
        }
        guard let range = found else { return }
        invalidateLayout(forRenderedRange: range)
    }

    private func invalidateLayout(forRenderedRange range: NSRange) {
        guard let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else { return }

        // NSTextContentStorage 的 location 是「textStorage 里的 UTF-16 偏移」，
        // 和 NSRange.location 是同一套坐标，所以可以直接用 range.location 去偏移。
        // 注意 documentRange.location 不是可选值，别写 guard let。
        let documentStart = contentStorage.documentRange.location
        guard let start = contentStorage.location(documentStart, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: max(1, range.length)),
              let textRange = NSTextRange(location: start, end: end) else { return }

        layoutManager.invalidateLayout(for: textRange)
    }
}
