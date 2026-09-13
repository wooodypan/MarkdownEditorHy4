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

    // MARK: 大纲（目录）

    /// 大纲事件的出口。
    ///
    /// ### 为什么是协议而不是 `OutlineCoordinator`
    /// 编辑器只需要「把标题列表和光标位置喊出去」，不需要知道外面是谁在听、
    /// 更不需要知道目录长什么样。留这一层协议之后，把目录换成侧边栏、
    /// 底部抽屉、甚至换成往日志里打一份，编辑器都一行不用改。
    ///
    /// 用 `weak`：协调者的生命周期由上层容器（`ViewController`）持有，
    /// 编辑器只是「借用」它来发通知，不参与它的生死。
    weak var outlineEventSink: MarkdownOutlineEventSink?

    /// 光标上报的防抖任务。
    ///
    /// `textViewDidChangeSelection` 在拖光标 / 快速打字时会**高频**触发，
    /// 每次都去通知目录会让高亮跟着手指疯狂跳。这里合并成 120ms 一次的尾部触发：
    /// 目录高亮是「辅助感知」功能，不需要逐字符级别的实时性。
    ///
    /// 状态存在这里、读写发生在 `MarkdownTextView+Outline.swift`，
    /// 所以不能标 `private`（跨文件扩展够不到）—— 它只在本模块内可见，不外泄。
    var outlineCursorWork: DispatchWorkItem?

    // MARK: 状态

    /// 上一次同步给模型的渲染文本。textView 的实际内容和它 diff，就能定位用户改了哪一段。
    private var lastSyncedString = ""
    /// 正在把模型改动写回 textView —— 这段时间内忽略 textViewDidChange，避免递归
    private(set) var isApplyingModelChange = false
    /// 上一次渲染时用的容器宽度，窗口尺寸变了要整篇重排
    private var renderedWidth: CGFloat = 0
    /// 程序自己发起的编辑正在进行（比如点复选框）。
    ///
    /// 这种编辑**不是系统记的**，`applyEdit` 里 disable/enable undo 的配对在这种时机
    /// 会踩 `_UITextUndoManager invalid state` 崩溃（和折叠功能是同一个坑，
    /// 详见 toggleCollapse 里的长注释），所以要跳过那对调用。
    private var isProgrammaticEdit = false
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

    // MARK: 引用块竖条（每层嵌套一条，画在文字下面）

    /// 竖条所在的层：加在代码块背景之上、文字之下（引用里可以嵌代码块）
    private let quoteBarLayer = UIView()
    /// 已经算好的竖条矩形（**文档坐标系**，滚动时只需整体平移）
    /// `id` 是引用层的唯一标识，`level` 是嵌套深度（0 = 最外层）
    private var quoteBarFrames: [(id: Int, level: Int, frame: CGRect)] = []

    // MARK: 任务列表复选框（浮在 `[x]` / `[ ]` 旁边）

    /// 复选框所在的控件层，加在最上层，只让按钮吃点击
    private let checkboxLayer = CheckboxLayer()
    /// 已经算好的 `[x]` / `[ ]` 三个字符的矩形（**文档坐标系**，滚动时只需整体平移）
    private var checkboxFrames: [(info: CheckboxInfo, frame: CGRect)] = []

    // MARK: 大纲跳转（见 MarkdownTextView+Outline.swift）

    /// 当前正在进行的那次「跳到某个标题」的序号。
    ///
    /// 跳转要分好几轮滚动才能收敛（原因见 `MarkdownTextView+Outline.swift` 里的说明），
    /// 而这期间用户可能又点了别的标题 —— 用序号把上一轮的残余步骤作废，
    /// 免得两个目标互相拉扯。
    var outlineJumpToken = 0

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

        // 整篇换掉了，标题列表一定变了；光标也被重置，两样一起推给大纲
        publishOutlineItems()
        publishOutlineCursor()
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

        // 整篇重排会重建所有块（UUID 也跟着全换新），目录那边必须整份换掉，
        // 否则它会拿着一批已经不存在的旧 id 去做高亮
        publishOutlineItems()
    }

    // MARK: - 代码块装饰（整块一个矩形背景 + 右上角复制按钮）

    /// 铺好两层容器：背景在**最底层**（被文字压着），复制按钮在**最上层**（能点）
    private func setupCodeBlockDecorations() {
        // 背景层要插到 index 0，否则会盖住文字
        insertSubview(codeBlockBackgroundLayer, at: 0)
        // 竖条层放在代码块背景上面（引用里可以嵌代码块，竖条要压在灰背景上），
        // 但仍在文字之下 —— 它跟背景层一样只是陪衬，不许抢点击
        insertSubview(quoteBarLayer, aboveSubview: codeBlockBackgroundLayer)
        quoteBarLayer.isUserInteractionEnabled = false
        addSubview(codeBlockControlLayer)
        addSubview(checkboxLayer)

        // 滚动时只做平移，不重算 —— 重算要走 TextKit 布局，滚动中做太贵
        contentOffsetObservation = observe(\.contentOffset, options: []) { [weak self] _, _ in
            self?.positionCodeBlockDecorations()
            self?.positionQuoteBars()
            self?.positionCheckboxes()
            self?.positionFoldButtons()
            // TextKit 排版比滚动事件慢半拍：滚动过程中刚进 viewport 的 fragment
            // 可能还是估算值（三角被跳过）。停一下再补一次，三角就不会「滚过去才冒出来」。
            self?.scheduleFoldRedraw()
        }
    }

    /// 每次布局时决定：是「重算矩形」还是「只平移」。
    /// 只有文本内容或宽度变了才需要重算，纯滚动走平移分支。
    /// （代码块背景和引用竖条共用同一套判断，两者都靠 fragment 矩形吃饭）
    private func updateCodeBlockDecorationsIfNeeded() {
        let signature = "\(textStorage.length)/\(Int(bounds.width))"
        guard needsCodeBlockRefresh || signature != lastCodeBlockSignature else {
            positionCodeBlockDecorations()
            positionQuoteBars()
            positionCheckboxes()
            return
        }
        lastCodeBlockSignature = signature
        needsCodeBlockRefresh = false
        refreshCodeBlockDecorations()
    }

    private func refreshCodeBlockDecorations() {
        let (frames, _) = computeCodeBlockFrames()
        let (bars, _) = computeQuoteBarFrames()
        let (boxes, _) = computeCheckboxFrames()

        // ### 为什么要对比上一轮结果（TextKit 2 的坑，别删）
        // TextKit 2 是「viewport 按需排版」：刚加载、刚滚完的时候，屏幕外 fragment 的
        // frame 还是**估算值**（实测差几十上百 pt，越靠下越歪）。直接拿去画背景必然错位。
        // 这里每 60ms 重算一次并和上一轮比对：结果还在变就说明排版没稳定，继续重试；
        // 连续两轮一致才收手。滚动停下后 scheduleFoldRedraw 也会再触发一轮校正。
        let stable = frames.count == codeBlockFrames.count &&
            zip(frames, codeBlockFrames).allSatisfy { $0.info === $1.info && $0.frame == $1.frame } &&
            bars.count == quoteBarFrames.count &&
            zip(bars, quoteBarFrames).allSatisfy { $0.id == $1.id && $0.level == $1.level && $0.frame == $1.frame } &&
            boxes.count == checkboxFrames.count &&
            zip(boxes, checkboxFrames).allSatisfy { $0.info === $1.info && $0.frame == $1.frame }
        codeBlockFrames = frames
        quoteBarFrames = bars
        checkboxFrames = boxes
        positionCodeBlockDecorations()
        positionQuoteBars()
        positionCheckboxes()

        if !stable, codeBlockRetryCount < 30 {
            codeBlockRetryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                // view 已经从窗口摘掉（比如切换文档）就别再刷了
                guard let self, self.window != nil else { return }
                self.refreshCodeBlockDecorations()
            }
        } else {
            codeBlockRetryCount = 0
        }
    }

    /// 算出每个代码块在**文档坐标系**下占的矩形。
    ///
    /// - returns: `(frames, pending)`。`pending == true` 表示「文本里有代码块，
    ///            但 TextKit 还没把它排出来」，需要等下一个布局周期重试。
    /// 注意：不开 `private` 是为了让单元测试能直接调它，验证滚动前后算出的矩形是否稳定
    func computeCodeBlockFrames() -> (frames: [(info: CodeBlockInfo, frame: CGRect)], pending: Bool) {
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
        // 有没有代码块连一个 fragment 都还没排出来（首帧常见）→ 交给调用方重试
        var missingLayout = false

        for (range, info) in marked {
            // NSTextContentStorage 用的是 UTF-16 偏移，和 NSRange.location 同一套坐标
            guard let startLocation = contentStorage.location(documentStart, offsetBy: range.location),
                  let endLocation = contentStorage.location(documentStart, offsetBy: NSMaxRange(range)) else { continue }

            // 3) 纵向范围：把这个区间覆盖到的所有 layout fragment 的外接矩形求出来。
            //    围栏行（首行 ```lang、末行 ```）要不要一起铺背景由主题开关决定：
            //    默认 false，只罩代码正文；改成 true 就是整块一个灰方块。
            let fenceRanges = renderer.theme.showsCodeBlockFenceBackground ? [] : fenceLineRanges(in: range)

            var top: CGFloat?
            var bottom: CGFloat = 0
            var sawFragment = false

            layoutManager.enumerateTextLayoutFragments(from: startLocation, options: [.ensuresLayout]) { fragment in
                let rect = fragment.layoutFragmentFrame
                // 这个 fragment 覆盖的字符区间（全局 UTF-16 偏移），用来判断它是不是围栏行
                let fragmentStart = contentStorage.offset(from: documentStart, to: fragment.rangeInElement.location)
                let fragmentEnd = contentStorage.offset(from: documentStart, to: fragment.rangeInElement.endLocation)
                let fragmentRange = NSRange(location: fragmentStart, length: max(0, fragmentEnd - fragmentStart))

                sawFragment = true
                let isFenceLine = fenceRanges.contains { NSIntersectionRange($0, fragmentRange).length > 0 }

                if !rect.isNull, rect.height > 0, !isFenceLine {
                    top = min(top ?? rect.minY, rect.minY)
                    bottom = max(bottom, rect.maxY)
                }
                // 还没走到这个代码块的结尾就继续（offset > 0 表示 endLocation 在后面）
                return contentStorage.offset(from: fragment.rangeInElement.endLocation, to: endLocation) > 0
            }

            if !sawFragment {
                // TextKit 还没把这段排出来，下一个布局周期再来
                missingLayout = true
                continue
            }
            // top == nil 说明这个块只有围栏两行（``` 紧接着 ```），没有正文 → 不铺背景
            guard let top else { continue }
            // ### 坐标系换算（不看注释直接用必错）
            // layoutFragmentFrame 的原点是 **textContainer 的左上角**，也就是已经扣掉了
            // textContainerInset —— fragment y=0 对应的是 inset.top 下面的第一行，不是
            // textView 顶部。而背景 view 画在 textView 坐标系里，所以 y 必须补回 top inset
            // （验证方法：caretRect(for:) 的 x/y 减 fragment 的 x/y 应该正好等于 inset）。
            // 横向不用换算：x 和宽度本来就是按 inset 现算的整行宽度。
            frames.append((info, CGRect(x: x,
                                        y: top + textContainerInset.top - padding,
                                        width: width,
                                        height: (bottom - top) + padding * 2)))
        }
        return (frames, missingLayout)
    }

    /// 一个代码块里**可能不该铺背景**的行：第一行的 ```lang 和最后一行的 ```。
    ///
    /// 主题里 `showsCodeBlockFenceBackground == false` 时（默认），这两行会从背景矩形里
    /// 抠掉——背景只罩代码正文，围栏行留白，视觉上更像"一段被高亮的代码"。
    ///
    /// - returns: 这些行在**整篇文本**里的 NSRange（含行尾换行，和 fragment 的覆盖范围对齐）。
    ///           行数不足 3 行（空代码块，开围栏紧接着闭围栏）时全部返回，此时没有正文可画。
    private func fenceLineRanges(in blockRange: NSRange) -> [NSRange] {
        let text = textStorage.string as NSString
        let end = NSMaxRange(blockRange)

        var lines: [NSRange] = []
        var cursor = blockRange.location
        while cursor < end {
            // lineRange(for:) 会把行尾的 \n 也算进来，正好和 fragment 的覆盖范围对齐，
            // 交集判断才不会漏掉半行
            let line = text.lineRange(for: NSRange(location: cursor, length: 0))
            let lineEnd = min(NSMaxRange(line), end)
            let clipped = NSRange(location: cursor, length: lineEnd - cursor)
            guard clipped.length > 0 else { break }   // 防御：长度算成 0 就别死循环了
            lines.append(clipped)
            cursor = lineEnd
        }

        // 只有「开围栏 + 闭围栏」两行（或更少）时没有正文行，整块都不铺背景
        guard lines.count >= 3 else { return lines }
        return [lines[0], lines[lines.count - 1]]
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

    // MARK: - 引用块竖条

    /// 算出每条引用竖条在**文档坐标系**下占的矩形（思路来自 doc/引用渲染方案.md）。
    ///
    /// ### 核心规则：竖条数量 = 嵌套深度，每层独立合并矩形
    /// 渲染层给引用块内的字符挂了 `.markdownQuoteChain`（值是从外到内的层 ID 数组，
    /// 见 `QuoteChain`）。这里把每个区间覆盖的 fragment 矩形求出来后，**链上的每一层
    /// 都各自累计一份**：外层 ID 的矩形覆盖「所有包含它的行」（含内层引用的行），
    /// 内层 ID 只覆盖内层自己的行 —— 所以外层竖条贯穿整块、内层竖条中途出现中途消失。
    ///
    /// x 坐标按嵌套深度往右错开：第 n 层画在 `inset.left + n * quoteIndent`，
    /// 和第 n 层引用文字的段落缩进（`n * quoteIndent`）正好对齐。
    ///
    /// - returns: `(bars, pending)`。`pending` 表示还有区间没排出 fragment，需要重试。
    /// 注意：不开 `private` 是为了让单元测试能直接调它
    func computeQuoteBarFrames() -> (bars: [(id: Int, level: Int, frame: CGRect)], pending: Bool) {
        guard let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              bounds.width > 1 else { return ([], false) }

        // 1) 扫出所有带嵌套链标记的区间
        var marked: [(NSRange, QuoteChain)] = []
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.markdownQuoteChain, in: full, options: []) { value, range, _ in
            guard let chain = value as? QuoteChain else { return }
            marked.append((range, chain))
        }
        guard !marked.isEmpty else { return ([], false) }

        let documentStart = contentStorage.documentRange.location
        // 有没有区间连一个 fragment 都没排出来（首帧常见）→ 交给调用方重试
        var missingLayout = false
        // key: 引用层 ID → (嵌套深度, 已合并的文档坐标矩形)
        var barsByID: [Int: (level: Int, rect: CGRect)] = [:]

        for (range, chain) in marked {
            // NSTextContentStorage 用的是 UTF-16 偏移，和 NSRange.location 同一套坐标
            guard let startLocation = contentStorage.location(documentStart, offsetBy: range.location),
                  let endLocation = contentStorage.location(documentStart, offsetBy: NSMaxRange(range)) else { continue }

            // 2) 这段字符覆盖到的所有 fragment 求外接矩形。
            //    竖条要连续贯穿段距（不象旧版每行一根断成虚线），所以直接并 fragment 矩形，
            //    不做行过滤 —— 引用没有代码块"围栏行"那种要抠掉的例外
            var top: CGFloat?
            var bottom: CGFloat = 0
            var sawFragment = false

            layoutManager.enumerateTextLayoutFragments(from: startLocation, options: [.ensuresLayout]) { fragment in
                let rect = fragment.layoutFragmentFrame
                sawFragment = true
                if !rect.isNull, rect.height > 0 {
                    top = min(top ?? rect.minY, rect.minY)
                    bottom = max(bottom, rect.maxY)
                }
                // 还没走到这段的结尾就继续（offset > 0 表示 endLocation 在后面）
                return contentStorage.offset(from: fragment.rangeInElement.endLocation, to: endLocation) > 0
            }

            if !sawFragment {
                missingLayout = true
                continue
            }
            guard let top else { continue }

            // ### 坐标系换算（详细推导见 computeCodeBlockFrames 里的注释）
            // layoutFragmentFrame 原点是 textContainer 左上角（不含 textContainerInset），
            // 画在 textView 坐标系里 y 要补回 top inset。横向 x 不从 fragment 拿：
            // 竖条固定画在「该层缩进边界」上，见下面第 4 步
            let rect = CGRect(x: 0,
                              y: top + textContainerInset.top,
                              width: 0,
                              height: bottom - top)

            // 3) 链上每一层都各自累计自己的矩形
            for (level, id) in chain.ids.enumerated() {
                let union = barsByID[id]?.rect.union(rect) ?? rect
                barsByID[id] = (level, union)
            }
        }

        // 4) x 按嵌套深度错开，输出按 (level, id) 排序：
        //    前后两轮的稳定性比对、以及测试断言都依赖顺序稳定
        let bars = barsByID
            .map { (id: $0.key,
                    level: $0.value.level,
                    frame: CGRect(x: textContainerInset.left + CGFloat($0.value.level) * renderer.theme.quoteIndent,
                                  y: $0.value.rect.minY,
                                  width: renderer.theme.quoteBarWidth,
                                  height: $0.value.rect.height)) }
            .sorted { ($0.level, $0.id) < ($1.level, $1.id) }
        return (bars, missingLayout)
    }

    /// 把文档坐标的竖条搬到屏幕上（和 positionCodeBlockDecorations 同一套平移逻辑）
    private func positionQuoteBars() {
        quoteBarLayer.frame = bounds
        // 竖条数量很少，每次重建比维护复用池省心
        quoteBarLayer.subviews.forEach { $0.removeFromSuperview() }

        let theme = renderer.theme
        // 可见范围，上下各留 200pt 余量，滚快一点也不会闪出空白
        let visible = CGRect(x: 0, y: -200, width: bounds.width, height: bounds.height + 400)

        for bar in quoteBarFrames {
            // 文档坐标 → 本层坐标：减掉滚动偏移
            var frame = bar.frame
            frame.origin.x -= contentOffset.x
            frame.origin.y -= contentOffset.y

            guard frame.intersects(visible) else { continue }

            let strip = UIView(frame: frame)
            strip.backgroundColor = theme.quoteBarColor
            // 两端微微收圆，比直角条柔和一点；宽度只有 3pt，圆角最多 1.5pt
            strip.layer.cornerRadius = theme.quoteBarWidth / 2
            strip.isUserInteractionEnabled = false
            quoteBarLayer.addSubview(strip)
        }
    }

    // MARK: - 任务列表复选框

    /// 算出每个 `[x]` / `[ ]` 在**文档坐标系**下占的矩形（就是那三个字符的字面范围）。
    ///
    /// ### 和代码块背景、引用竖条的差别
    /// 那两个要的是「整段的纵向范围」，合并 layout fragment 的矩形就够了；
    /// 复选框要的是**某三个字符的横向范围**，行级的 fragment 给不了（一个 fragment 就是一整行），
    /// 所以这里走 TextKit 官方的 `enumerateTextSegments`——它能精确到字符级。
    ///
    /// - returns: `(boxes, pending)`。坐标和 `computeCodeBlockFrames` 同一套：
    ///           TextKit 给的矩形原点在 textContainer 左上角，画到 textView 里要补回 inset。
    ///           注意：不开 `private` 是为了让单元测试能直接调它
    func computeCheckboxFrames() -> (boxes: [(info: CheckboxInfo, frame: CGRect)], pending: Bool) {
        guard let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              bounds.width > 1 else { return ([], false) }

        // 1) 扫出所有打了 `.markdownCheckbox` 标记的区间
        var marked: [(NSRange, CheckboxInfo)] = []
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.markdownCheckbox, in: full, options: []) { value, range, _ in
            guard let info = value as? CheckboxInfo else { return }
            marked.append((range, info))
        }
        guard !marked.isEmpty else { return ([], false) }

        let documentStart = contentStorage.documentRange.location
        var boxes: [(info: CheckboxInfo, frame: CGRect)] = []
        boxes.reserveCapacity(marked.count)

        for (range, info) in marked {
            guard let startLocation = contentStorage.location(documentStart, offsetBy: range.location),
                  let endLocation = contentStorage.location(documentStart, offsetBy: NSMaxRange(range)),
                  let textRange = NSTextRange(location: startLocation, end: endLocation) else { continue }

            // 2) 字符级矩形：把这三个字符覆盖到的所有 segment 求并集。
            //    正常情况下就是一行里的一个小矩形；万一 `[x]` 被折到两行（极窄窗口），
            //    并集会变成一个跨行的大矩形，此时按钮仍然能点，只是位置偏一点，不崩
            var rect: CGRect?
            layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
                guard !segment.isNull else { return true }
                rect = rect.map { $0.union(segment) } ?? segment
                return true
            }
            guard let rect else { continue }

            // 3) 坐标系换算（推导见 computeCodeBlockFrames 里的注释）：
            //    TextKit 的矩形不含 textContainerInset，画在 textView 里要补回来
            boxes.append((info, CGRect(x: rect.minX + textContainerInset.left,
                                       y: rect.minY + textContainerInset.top,
                                       width: rect.width,
                                       height: rect.height)))
        }
        return (boxes, false)
    }

    /// 把复选框摆到屏幕上（和 `positionQuoteBars` 同一套平移逻辑）
    private func positionCheckboxes() {
        checkboxLayer.frame = bounds
        // 复选框数量不多，每次重建比维护复用池省心
        checkboxLayer.subviews.forEach { $0.removeFromSuperview() }

        let theme = renderer.theme
        let style = theme.taskList
        let side = style.checkboxSide
        // 可见范围，上下各留 200pt 余量，滚快一点也不会闪出空白
        let visible = CGRect(x: 0, y: -200, width: bounds.width, height: bounds.height + 400)

        for entry in checkboxFrames {
            let literal = entry.frame
            let buttonFrame: CGRect
            if style.coversCheckboxLiteral {
                // 遮盖模式（默认）：方框压在 `[x]` 正中，把它整个挡住（底色不透明）。
                // 宽度取 max(方框边长, 字面宽度) —— `[X]` 比方框宽（实测 22.7pt vs 16pt），
                // 不拉宽的话字的边角会从方框旁边露出来
                let width = max(side, literal.width)
                buttonFrame = CGRect(x: literal.midX - width / 2,
                                     y: literal.midY - side / 2,
                                     width: width,
                                     height: side)
            } else {
                // 并列模式：方框画在 `[x]` 左边，源码照常露出来。
                // 实测它会把列表标记 `- ` 压在身下（复选框和标记挤在同一个位置），
                // 视觉比较挤 —— 这就是主题里 `coversCheckboxLiteral` 开关存在的原因
                buttonFrame = CGRect(x: literal.minX - side - style.checkboxGap,
                                     y: literal.midY - side / 2,
                                     width: side,
                                     height: side)
            }

            // 文档坐标 → 本层坐标：减掉滚动偏移
            var frame = buttonFrame
            frame.origin.x -= contentOffset.x
            frame.origin.y -= contentOffset.y
            guard frame.intersects(visible) else { continue }

            let button = MarkdownCheckboxButton(side: side)
            button.frame = frame
            button.checkbox = entry.info
            button.apply(isChecked: entry.info.isChecked,
                         theme: theme,
                         covers: style.coversCheckboxLiteral)
            button.addTarget(self, action: #selector(checkboxTapped(_:)), for: .touchUpInside)
            checkboxLayer.addSubview(button)
        }
    }

    @objc private func checkboxTapped(_ sender: MarkdownCheckboxButton) {
        guard let info = sender.checkbox else { return }
        toggleCheckbox(info)
        // 立刻触发一轮布局：applyEdit 换掉的那一块有了全新的 CheckboxInfo，
        // 重算矩形 + 重摆按钮后，勾选状态马上从旧图标换成新的（不等下一个 runloop）
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// 切换一个任务列表项的勾选状态：把源码里的 `[x]` 换成 `[ ]`（或反过来）。
    ///
    /// ### 为什么走 `applyEdit` 而不是自己改源码
    /// 走标准编辑管线有三个白拿的好处：**撤销 / 重做自动生效**、只重解析重渲染
    /// 受影响的那一块（成本很小）、渲染结果和模型永远一致（不会出现「按钮显示已勾选、
    /// 源码还是 `[ ]`」这种两套状态）。
    ///
    /// - parameter info: 被点到的复选框（它带着 `[` 在整篇源码里的偏移）
    func toggleCheckbox(_ info: CheckboxInfo) {
        let sourceRange = NSRange(location: info.sourceStart, length: 3)
        guard let rendered = documentStore.renderedRange(forSourceRange: sourceRange) else { return }
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }
        applyEdit(renderedRange: rendered,
                  replacementText: info.isChecked ? "[ ]" : "[x]",
                  alreadyAppliedToTextStorage: false)
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
            guard let self else { return }
            self.positionFoldButtons()
            self.positionCheckboxes()
            // 滚动停下后 fragment 才排实（滚动中屏幕外的还是估算值），
            // 代码块背景矩形要重算一遍，不然一直拿着首帧的错坐标画
            self.refreshCodeBlockDecorations()
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

    // MARK: - 引用块装饰（左侧竖条）
    //
    // ### 竖条为什么最终走「overlay + fragment 矩形合并」
    // 这套机制曾经被放弃过：早期版本在 UI 层盖 UIView 画整段竖条，结果错位 360+ 像素 ——
    // TextKit 2 的 `NSTextLayoutFragment.layoutFragmentFrame` 对 viewport 外的 fragment
    // **永远是估算值**（state=3 LayoutAvailable 但 usage bounds 是估算的），当时
    // `setContentOffset` / `invalidateLayout` / `ensureLayout` / 离屏 NSLayoutManager
    // 全部拿不到真实坐标，于是改成了每行插一个 attachment（绿条断成虚线是已知代价）。
    //
    // 后来代码块背景把「估算值」问题解决在了机制层面：**每 60ms 重算并和上一轮比对，
    // 结果还在变就继续等；滚动停下后再补一轮**（见 refreshCodeBlockDecorations 的注释）。
    // 竖条因此得以迁回 overlay 方案（doc/引用渲染方案.md 的思路），换来三个 attachment
    // 方案做不到的效果：段距处连续、嵌套时每层一条且外层贯穿整块、x 随深度对齐缩进。
    // 引用竖条和代码块背景共用同一套刷新循环。

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
        // 不注册 undo：编辑动作已经由系统记录过一次了，再记一次会让撤销栈错乱。
        // （程序自己发起的编辑没有「系统刚记过」这个时机，连 disable/enable 都不能碰，
        //  否则 _UITextUndoManager 抛 invalid state —— 见 isProgrammaticEdit 的注释）
        if !isProgrammaticEdit {
            undoManager?.disableUndoRegistration()
        }

        if let contentStorage = textLayoutManager?.textContentManager as? NSTextContentStorage {
            // TextKit 2 的事务接口：一次提交，TextKit 自己算最小失效区域做增量重排
            contentStorage.performEditingTransaction {
                backingStorage.replaceCharacters(in: targetRange, with: outcome.newContent)
            }
        } else {
            backingStorage.replaceCharacters(in: targetRange, with: outcome.newContent)
        }

        if !isProgrammaticEdit {
            undoManager?.enableUndoRegistration()
        }
        isApplyingModelChange = false

        lastSyncedString = documentStore.renderedString
        needsCodeBlockRefresh = true

        let caret = min(outcome.caretRenderedOffset, (text as NSString).length)
        if selectedRange.location != caret || selectedRange.length != 0 {
            selectedRange = NSRange(location: caret, length: 0)
        }

        // 只有这次编辑动到了标题块才重推整份标题列表。
        // 在正文段落里打字时这里永远是 false —— 长文档也完全不会被目录拖慢
        if outcome.headingsChanged { publishOutlineItems() }
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

    // MARK: - 导出长图

    /// 把**整篇内容**（包括滚出屏幕外的部分）渲染成一张图片，给「导出成图片 / 分享」用。
    ///
    /// ### 两步走：先撑大视口拿全文排版，再自己逐段画
    /// 1. TextKit 2 是「viewport 按需排版」：屏幕外的文字不排不画，fragment 坐标还是估算值。
    ///    所以先把 bounds（它就是视口）临时撑到整篇内容高度，强制布局，
    ///    拿到准确的 contentSize 和全文 fragment。画完立刻恢复现场，中间不会真的闪一帧。
    /// 2. **不能**指望 `layer.render(in:)` 把文字画出来 —— UITextView 只把「画过的」
    ///    缓存进自己的 layer，屏幕外部分缓存里是空白（撑大视口强制重绘也只重绘它认定的可视区）。
    ///    文字必须自己枚举 `NSTextLayoutFragment` 逐个 draw（`.rendersUnseenText` 让没画过的
    ///    fragment 真正渲染出来）；装饰层是独立 subview，单独 render 各自的 layer 即可。
    func renderFullContentImage() -> UIImage? {
        layoutIfNeeded()
        guard bounds.width > 1, contentSize.height > 1 else { return nil }

        // 记住现场，画完恢复
        let savedBounds = bounds
        let savedOffset = contentOffset
        let hadFocus = isFirstResponder
        // 光标会被画进图里；键盘也占着屏幕。先退出编辑态，画完再还回去
        if hadFocus { resignFirstResponder() }

        // 视口撑到全文高度。注意 contentSize 首次拿到的是 TextKit 的**估算值**
        // （viewport 外的排版是估的），撑大后全文排完高度可能变 → 循环到不再变化为止
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
    /// 这是 TextKit 2 导出全文的姿势：直接 `layer.render` 只能拿到「画过的」缓存，
    /// 屏幕外是空白；自己枚举 fragment 逐个 draw 才能把没画过的段落真正渲染出来
    private func drawAllLayoutFragments(in context: CGContext) {
        guard let layoutManager = textLayoutManager else { return }
        // ### 坐标系换算（同 computeCodeBlockFrames 的注释）
        // layoutFragmentFrame 原点是 textContainer 左上角（已扣掉 textContainerInset），
        // 图片画在 textView 坐标系里，x/y 要把 inset 补回来
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
