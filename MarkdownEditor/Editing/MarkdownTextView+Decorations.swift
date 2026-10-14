//
//  MarkdownTextView+Decorations.swift
//  MarkdownEditorHy4
//
//  装饰层：代码块背景矩形（+ 右上角复制按钮）、引用竖条、任务列表复选框。
//  本文件代码最开始存在于MarkdownTextView.swift，2026-10-12从MarkdownTextView.swift移动到这里
//  ### 为什么这三类放在同一个文件里
//  它们画的东西各不相同（一个罩整块、一条贯穿引用、一个压在 `[x]` 上），但**刷新时机和刷新循环是同一套**。
//  内容 / 宽度变了才重算矩形，纯滚动只做平移；重算还共用「等 TextKit 排版收敛」那一套重试逻辑（见 refreshCodeBlockDecorations）。
//  摆位的总控和这三类装饰分开的话，改刷新时机要在两个文件之间来回跳，容易漏。
//
//  ⚠️ 存储属性（各层的 view、算好的矩形、重试任务）仍在 `MarkdownTextView.swift` 里 —— Swift 的 extension 不能声明存储属性。
//  跨文件要读写它们，所以那几处没标 `private`。
//

import UIKit

extension MarkdownTextView {

    // MARK: - 代码块装饰（整块一个矩形背景 + 右上角复制按钮）

    /// 铺好两层容器：背景在**最底层**（被文字压着），复制按钮在**最上层**（能点）
    func setupCodeBlockDecorations() {
        // 引用底色在最底下（引用里嵌代码块时，代码块的灰底要盖在它上面），其次才是代码块背景
        insertSubview(quoteBackgroundLayer, at: 0)
        quoteBackgroundLayer.isUserInteractionEnabled = false
        insertSubview(codeBlockBackgroundLayer, aboveSubview: quoteBackgroundLayer)
        // 竖条层放在代码块背景上面（引用里可以嵌代码块，竖条要压在灰背景上），
        // 但仍在文字之下 —— 它跟背景层一样只是陪衬，不许抢点击
        insertSubview(quoteBarLayer, aboveSubview: codeBlockBackgroundLayer)
        quoteBarLayer.isUserInteractionEnabled = false
        addSubview(codeBlockControlLayer)
        addSubview(checkboxLayer)
        // 宽表格的横向滚动容器：必须压在文字**上面**（它是要接管触摸的，不是陪衬）
        addSubview(tableScrollLayer)

        contentOffsetObservation = observe(\.contentOffset, options: []) { [weak self] _, _ in
            // 1) 先按缓存的文档坐标平移一次 —— 这一步很便宜，每帧都要做，
            //    否则背景会跟着滚动掉队（哪怕只掉一帧也看得出来）
            self?.positionCodeBlockDecorations()
            self?.positionQuoteDecorations()
            self?.positionCheckboxes()
            self?.positionTableScrollViews()
            self?.positionFoldControls()
            self?.positionSearchHighlights()
            self?.positionFootnoteFlash()
            self?.positionLineNumbers()
            // 2) 再要一轮布局：重算必须发生在 `layoutSubviews` 里（**在 super.layoutSubviews()
            //    之后**）—— TextKit 是在那一轮里更新 viewport 的，在滚动回调里直接算拿到的是
            //    上一次 viewport 的估算值，等于白算。重算逻辑见 refreshDecorationsNearViewport。
            //    ⚠️ 系统滚动时不一定会调 `layoutSubviews`（滚动只改 bounds 原点，不一定触发布局），
            //    所以这里自己要一次；用 async 排到下一个 runloop，避免和布局过程互相递归
            self?.setNeedsLayout()
            self?.scheduleScrollLayout()
            // TextKit 排版比滚动事件慢半拍：滚动过程中刚进 viewport 的 fragment
            // 可能还是估算值（三角被跳过）。停一下再补一次，三角就不会「滚过去才冒出来」。
            self?.scheduleFoldRedraw()
        }
    }

    /// 排一轮布局到下一个 runloop（一帧最多一次），滚动时用。
    private func scheduleScrollLayout() {
        guard !scrollLayoutScheduled else { return }
        scrollLayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollLayoutScheduled = false
            self.layoutIfNeeded()
        }
    }

    /// 视野附近（上下各扩一屏）在**文档坐标系**里的矩形。
    ///
    /// 为什么要扩一屏而不是只取 viewport：屏幕外的块算出来的坐标有几十上百 pt 的误差，
    /// 只按 viewport 判断会漏掉「缓存里看着还在外面、其实已经露出来了」的块。
    private var nearViewportBand: CGRect {
        let height = max(bounds.height, 1)
        return CGRect(x: 0, y: contentOffset.y - height,
                      width: max(bounds.width, 1), height: height * 3)
    }

    /// 滚动过程中把「视野附近」的装饰矩形重算一遍。
    ///
    /// ### 不这么做会怎样（这就是「停下滑才跳到位」的根因）
    /// 打开长文档时，屏幕外的代码块只能用 TextKit 的**估算坐标**算矩形（实测差 84pt 甚至更多），
    /// 这个值被缓存下来；滚动时只做平移，用的还是错的缓存 —— 于是灰底停在错误的位置，
    /// 比如压在 ```swift 那一行上（文字和背景重合）。等滚过 40pt（或滚动停下）触发一次
    /// 视野附近的重算，才把真值算出来 —— 用户看到的就是这个跳。
    ///
    /// ### 为什么不能滚动时整篇重算
    /// 重算要 `enumerateTextLayoutFragments(options: [.ensuresLayout])`，等于强制 TextKit 排版
    /// 那些区域；整篇重算会把整个文档排一遍，长文档上滚动会掉帧。所以只重算视野附近的
    /// （它们本来就要排版，成本几乎为零），视野外的继续用缓存，滚近了自然会补算。
    ///
    /// ### 节流：按**滚动距离**而不是按时间
    /// 每帧重算要扫一遍 textStorage 的属性，没必要。这里每滚过 40pt 才重算一次：
    /// 块进视野前 1 屏（800pt）就已经落在 band 里被算过了，40pt 的粒度足够早，
    /// 用户根本看不到「还没纠正」的中间状态。慢速滚动时几乎不触发，掉帧风险最小。
    /// 剩下的误差由滚动结束后的 `scheduleFoldRedraw`（再强制算一次视野附近）兜底。
    ///
    /// - parameter force: true = 不管滚了多少都要算（滚动停下后的兜底用）
    func refreshDecorationsNearViewport(force: Bool = false) {
        guard force || abs(contentOffset.y - lastNearViewportRefreshOffset) > 40 else { return }
        lastNearViewportRefreshOffset = contentOffset.y
        // 滚动不改变内容 → 表格那趟全篇扫描可以省掉
        _ = recomputeDecorations(within: nearViewportBand, rescanTableMarks: false)
    }

    /// 重算四类装饰（代码块背景 / 引用竖条 / 复选框 / 表格横滚）并摆到屏幕上。
    ///
    /// - parameter band: 传「视野附近」的文档坐标矩形 = **只重算落在里面的**，外面的沿用上一轮结果；
    ///            传 nil = 整篇重算。
    /// - parameter rescanTableMarks: 要不要重扫「哪些表格要横滚」。只有内容变了才需要（那是一次 O(n) 的全篇属性扫描），纯滚动一律 false。
    /// - returns: `pending` = 还有区间连一个 fragment 都没排出来（首帧常见），调用方据此决定要不要再等一个布局周期；
    ///            `stable` = 这一轮算出来的和上一轮正画着的是不是一致（整篇重算用它判断排版收敛了没）
    @discardableResult
    private func recomputeDecorations(within band: CGRect?, rescanTableMarks: Bool) -> (pending: Bool, stable: Bool) {
        let (frames, codePending) = computeCodeBlockFrames(reusingOutside: band)
        let (bars, barPending) = computeQuoteBarFrames(reusingOutside: band)
        let (boxes, _) = computeCheckboxFrames(reusingOutside: band)
        if rescanTableMarks {
            // 内容变了 → 「哪些表格要横滚」也可能变了，这里重扫一遍（滚动那趟不扫，见 refreshTableScrollMarks）
            refreshTableScrollMarks()
        }

        // 比对必须在写回**之前**做：比的是「这一轮算出来的」和「上一轮正画着的」
        let barsStable = bars.count == quoteBarFrames.count
            && zip(bars, quoteBarFrames).allSatisfy { $0.id == $1.id && $0.level == $1.level && nearlyEqual($0.frame, $1.frame) }
        let stable = sameFrames(frames, codeBlockFrames) && barsStable && sameFrames(boxes, checkboxFrames)

        codeBlockFrames = frames
        quoteBarFrames = bars
        checkboxFrames = boxes
        tableScrollFrames = computeTableScrollFrames(reusingOutside: band)
        positionCodeBlockDecorations()
        positionQuoteDecorations()
        positionCheckboxes()
        positionTableScrollViews()
        return (codePending || barPending, stable)
    }

    /// 两轮算出来的矩形是不是「一回事」。`info` 按**对象身份**比（块被重建时身份就变了，必须算不一样）。
    private func sameFrames<Info: AnyObject>(_ lhs: [(info: Info, frame: CGRect)],
                                             _ rhs: [(info: Info, frame: CGRect)]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.info === $1.info && nearlyEqual($0.frame, $1.frame) }
    }

    /// 差在 0.5pt 以内就算相等：TextKit 的坐标是浮点，差 0.001 不该把整轮判成「还没稳定」（那会白白多跑一轮整篇重算）
    private func nearlyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 0.5 && abs(lhs.minY - rhs.minY) <= 0.5
            && abs(lhs.width - rhs.width) <= 0.5 && abs(lhs.height - rhs.height) <= 0.5
    }

    /// 每次布局时决定：是「重算矩形」还是「只平移」。
    /// 只有文本内容或宽度变了才需要重算，纯滚动走平移分支。
    /// （代码块背景和引用竖条共用同一套判断，两者都靠 fragment 矩形吃饭）
    func updateCodeBlockDecorationsIfNeeded(nearViewportOnly: Bool = false) {
        let signature = "\(textStorage.length)/\(Int(bounds.width))"
        guard needsCodeBlockRefresh || signature != lastCodeBlockSignature else {
            positionCodeBlockDecorations()
            positionQuoteDecorations()
            positionCheckboxes()
            // 纯滚动：缓存里那些「块还在屏幕外时算出来的」坐标要趁现在纠正掉。
            // 必须放在布局里做（滚动回调那会儿 TextKit 的 viewport 还没更新，算出来还是错的）
            refreshDecorationsNearViewport()
            return
        }
        lastCodeBlockSignature = signature
        needsCodeBlockRefresh = false
        refreshCodeBlockDecorations(recomputingAll: !nearViewportOnly)
    }

    /// 重算装饰矩形。
    ///
    /// - parameter recomputingAll: false = 只算视野附近那一条带（`nearViewportBand`），屏幕外的沿用上一轮缓存。
    ///
    ///   ### 这才是这次优化的关键（打字那条路径每敲一个字都要付的代价，以前付的是整篇）
    ///   整篇重算会对**每一个**代码块调 `enumerateTextLayoutFragments(options: [.ensuresLayout])`，
    ///   等于逼 TextKit 把屏幕外那些本来不用排的区域也排一遍 —— 成本随整篇长度线性上涨，而且是白干的：
    ///   屏幕外的 fragment 算出来只是估算值，等它滚进视野再算才是准的（见 `refreshDecorationsNearViewport` 的注释）。
    ///   一次编辑只改了改动点那一小段，屏幕外的块位置没变，沿用缓存就够了。
    ///
    ///   true = 整篇重算，留给「内容整体换掉」那几条路：首屏加载、换主题、改窗口宽度、导出长图。
    ///
    /// 不开 `private`：导出长图把视口撑到全文后要同步刷一轮（见 `MarkdownTextView+Export.swift`）。
    func refreshCodeBlockDecorations(recomputingAll: Bool = true) {
        // 新一轮开始先把上一轮挂着没跑的重试撤掉：快速打字时每一字都会触发一次重算，
        // 不撤的话会叠出好几条重试链并行跑（每条都是整篇重算，而且共享同一个重试计数，乱成一团）
        if let pending = decorationRetryWork {
            pending.cancel()
            decorationRetryWork = nil
            // 链作废了，重试额度从头算 —— 不然连打几十个字就把 30 次一次耗光
            codeBlockRetryCount = 0
        }

        let (pending, stable) = recomputeDecorations(within: recomputingAll ? nil : nearViewportBand,
                                                    rescanTableMarks: true)

        guard recomputingAll else {
            // 只算视野附近时，band 内的坐标是 `.ensuresLayout` 当场逼出来的真值，不会自己漂移，
            // 所以不需要「轮询到收敛」那一套。唯一要等的是「这段还没排出 fragment」（pending）。
            if pending { scheduleDecorationRetry(recomputingAll: false) }
            return
        }

        // ### 整篇重算才需要「每 60ms 重算到收敛」（TextKit 2 的坑，别删）
        // 屏幕外 fragment 的 frame 还是**估算值**（实测差几十上百 pt，越靠下越歪），
        // 直接拿去画必然错位。所以重算一次并和上一轮比对：结果还在变就说明排版没稳定，继续重试；
        // 连续两轮一致才收手。屏幕外的误差由滚动停下后的 scheduleFoldRedraw 兜底。
        if !stable || pending {
            scheduleDecorationRetry(recomputingAll: true)
        } else {
            codeBlockRetryCount = 0
        }
    }

    /// 排一次重试（这一轮判定「还不算数」时用）。
    ///
    /// ### 为什么要存成 DispatchWorkItem 而不是直接 asyncAfter
    /// 存下来才能在下一轮重算开始时 `cancel()` 掉。以前那种「只管 dispatch 出去」的写法，
    /// 快速打字时会同时挂着好几条链，每条都在整篇重算 —— 打字越久越卡。
    private func scheduleDecorationRetry(recomputingAll: Bool) {
        guard codeBlockRetryCount < Self.maxDecorationRetries else {
            // 到顶就收手：再等下去也不会更准，屏幕外的留给滚动停下那次重算
            codeBlockRetryCount = 0
            return
        }
        codeBlockRetryCount += 1
        let work = DispatchWorkItem { [weak self] in
            // view 已经从窗口摘掉（比如切换文档）就别再刷了
            guard let self, self.window != nil else { return }
            self.decorationRetryWork = nil
            self.refreshCodeBlockDecorations(recomputingAll: recomputingAll)
        }
        decorationRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    /// 打字停下来之后补一次**整篇**重算。
    ///
    /// ### 为什么打字那一下只算视野附近，之后还要整篇补一次
    /// 视野附近的坐标是当场排出来的，屏幕上看到的必然是对的；但屏幕外那些块只是沿用了上一轮的缓存 ——
    /// 一次大改动（删掉一整段）会把它们整体平移一大截，缓存的 y 就不再可信。
    /// 所以等打字停下来补一次整篇重算把它们全部校正掉。快速连续打字时每一次都会把上一个任务取消，
    /// 真正停下来之后才跑一次（和 scheduleFoldRedraw 一个套路）。
    func scheduleDecorationSettle() {
        decorationSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window != nil else { return }
            self.decorationSettleWork = nil
            self.refreshCodeBlockDecorations(recomputingAll: true)
        }
        decorationSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// 算出每个代码块在**文档坐标系**下占的矩形。
    ///
    /// - parameter reusingOutside: 传一个文档坐标的矩形（一般是「视野上下各扩一屏」），
    ///            落在这个矩形**外面**的块直接沿用上一轮算好的结果，不再问 TextKit。
    ///            滚动时每帧都整篇重算太贵（会强制排版全文），而视野外的块算出来也是估算值，
    ///            等它滚进视野附近再算才是准的 —— 详见 `refreshDecorationsNearViewport`。
    ///            传 nil（内容/宽度变化时）表示全部重算。
    /// - returns: `(frames, pending)`。`pending == true` 表示「文本里有代码块，
    ///            但 TextKit 还没把它排出来」，需要等下一个布局周期重试。
    /// 注意：不开 `private` 是为了让单元测试能直接调它，验证滚动前后算出的矩形是否稳定
    func computeCodeBlockFrames(reusingOutside band: CGRect? = nil) -> (frames: [(info: CodeBlockInfo, frame: CGRect)], pending: Bool) {
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
            // 视野外的块沿用上一轮结果（理由见方法注释里的 reusingOutside）
            if let band,
               let cached = codeBlockFrames.first(where: { $0.info === info })?.frame,
               !cached.intersects(band) {
                frames.append((info, cached))
                continue
            }

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

            // ### 为什么这里不用再算「躲围栏行」
            // 灰底上沿 = 正文首行 fragment 顶往上一个 padding，下沿 = 末行 fragment 底往下一个 padding。
            // 光看这个式子像是在占正文的便宜，其实不是：fragment 里除了字还有正文自己的段间距，而围栏行那边由 `codeFenceParagraphStyle` 兜了至少一个 padding 的空档 —— 两边加起来必然够，所以不用再跟围栏行的文字盒取大/小值（早先那种夹取还有个反向的坑：段距调小以后夹出来的上/下沿会切进正文，实测最后一个 `}` 的底部戳出灰底 6pt，正好是灰底高度的 10%）。
            let backgroundTop = top - padding
            let backgroundBottom = bottom + padding
            // 理论上必然成立（top / bottom 都来自真实存在的 fragment）→ 真有异常就宁可不画，也不画一个翻过来的框
            guard backgroundBottom > backgroundTop else { continue }

            // ### 坐标系换算（不看注释直接用必错）
            // layoutFragmentFrame 的原点是 **textContainer 的左上角**，也就是已经扣掉了
            // textContainerInset —— fragment y=0 对应的是 inset.top 下面的第一行，不是
            // textView 顶部。而背景 view 画在 textView 坐标系里，所以 y 必须补回 top inset
            // （验证方法：caretRect(for:) 的 x/y 减 fragment 的 x/y 应该正好等于 inset）。
            // 横向不用换算：x 和宽度本来就是按 inset 现算的整行宽度。
            frames.append((info, CGRect(x: x,
                                        y: backgroundTop + textContainerInset.top,
                                        width: width,
                                        height: backgroundBottom - backgroundTop)))
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

    /// 摆位前先调它，再配一句 `defer { endDecorationPositioning() }`：这一轮摆位就整个落进一个**不自动补间**的事务里。
    ///
    /// ### 为什么摆位必须关掉隐式动画（iPhone 上「键盘弹出 / 收起时按钮从左上角飞过来」就是这个）
    /// 复制按钮 / 折叠三角 / 复选框这些装饰**每一轮布局都整批重建**，新 view 的 `frame` 先是左上角的 `(0,0)`，紧接着才被赋成真正的位置。
    /// 平时这一下没有动画 —— UIKit 只在**动画事务里**才给属性变化配补间。
    /// 但键盘弹出 / 收起时 UIKit 是在一个动画事务里改 textView 高度的（`keyboardWillChangeFrame` 那个通知就发在事务里，App 层的 `layoutIfNeeded()` 于是也跑在事务里），那一下赋值就成了一次真的属性动画。
    /// 实测这几个按钮会被挂上 `position` / `bounds.size` 动画，从 `(0,0)`「嗖」地飞到目标位置。
    /// 摆位是跟着滚动 / 布局走的定位，本来就该瞬时对齐，不该有补间。
    ///
    /// 关的是 **CATransaction 的隐式动作**（`UIView.performWithoutAnimation` 内部就是这么实现的）。
    /// 这样既挡住 UIKit 的属性动画，也挡住直接改 layer 属性带出来的隐式动画。
    func beginDecorationPositioning() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
    }

    /// 配 `beginDecorationPositioning()` 用，理由见那里的注释
    func endDecorationPositioning() {
        CATransaction.commit()
    }

    /// 把文档坐标的矩形搬到屏幕上，铺背景 view 和复制按钮
    private func positionCodeBlockDecorations() {
        beginDecorationPositioning()
        defer { endDecorationPositioning() }
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
    /// - parameter reusingOutside: 同 `computeCodeBlockFrames(reusingOutside:)`：
    ///            传视野附近的文档坐标矩形时，落在它外面的引用层沿用上一轮结果。
    /// - returns: `(bars, pending)`。`pending` 表示还有区间没排出 fragment，需要重试。
    /// 注意：不开 `private` 是为了让单元测试能直接调它
    func computeQuoteBarFrames(reusingOutside band: CGRect? = nil) -> (bars: [(id: Int, level: Int, frame: CGRect)], pending: Bool) {
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
            // 这一段文字参与的所有引用层都在视野外 → 整段沿用上一轮结果
            if let band, !chain.ids.isEmpty, chain.ids.allSatisfy({ id in
                guard let cached = quoteBarFrames.first(where: { $0.id == id }) else { return false }
                return !cached.frame.intersects(band)
            }) {
                continue
            }

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
        //    前后两轮的稳定性比对、以及测试断言都依赖顺序稳定。
        //    ⚠️ 只重算视野附近时（`band != nil`）要先拿上一轮结果打底：
        //    视野外的层这一轮压根没算，不从缓存补回来的话它们会从界面上直接消失
        var merged = barsByID
        if band != nil {
            for bar in quoteBarFrames where merged[bar.id] == nil {
                merged[bar.id] = (level: bar.level,
                                  rect: CGRect(x: bar.frame.minX,
                                               y: bar.frame.minY,
                                               width: 0,
                                               height: bar.frame.height))
            }
        }
        let bars = merged
            .map { (id: $0.key,
                    level: $0.value.level,
                    frame: CGRect(x: textContainerInset.left + CGFloat($0.value.level) * renderer.theme.quoteIndent,
                                  y: $0.value.rect.minY,
                                  width: renderer.theme.quoteBarWidth,
                                  height: $0.value.rect.height)) }
            .sorted { ($0.level, $0.id) < ($1.level, $1.id) }
        return (bars, missingLayout)
    }

    /// 把文档坐标的竖条搬到屏幕上，顺带把引用的内容底色一起铺了（和 positionCodeBlockDecorations 同一套平移逻辑）
    ///
    /// ### 内容底色为什么跟竖条一起画
    /// 它俩吃的是**同一批矩形**（`quoteBarFrames`：每层引用的纵向范围），只是横向不一样 —— 竖条是一条窄带，底色从竖条一直铺到行尾。
    /// 分开画就得在两个地方各维护一份「视野内可见」的判断，滚动时少画一处就是缺口。
    private func positionQuoteDecorations() {
        // 关掉隐式动画：见 beginDecorationPositioning 的注释（键盘弹出那一下竖条会淡入）
        beginDecorationPositioning()
        defer { endDecorationPositioning() }
        quoteBarLayer.frame = bounds
        quoteBackgroundLayer.frame = bounds
        // 竖条数量很少，每次重建比维护复用池省心
        quoteBarLayer.subviews.forEach { $0.removeFromSuperview() }
        quoteBackgroundLayer.subviews.forEach { $0.removeFromSuperview() }

        let theme = renderer.theme
        // 可见范围，上下各留 200pt 余量，滚快一点也不会闪出空白
        let visible = CGRect(x: 0, y: -200, width: bounds.width, height: bounds.height + 400)
        // 行尾 = 正文右边界（扣掉右边内间距），底色一律铺到这儿
        let rightEdge = bounds.width - textContainerInset.right

        for bar in quoteBarFrames {
            // 文档坐标 → 本层坐标：减掉滚动偏移
            var frame = bar.frame
            frame.origin.x -= contentOffset.x
            frame.origin.y -= contentOffset.y

            guard frame.intersects(visible) else { continue }

            // 内容底色：从竖条那条线开始，一直铺到行尾（默认关，见 `theme.showsQuoteBackground`）
            if theme.showsQuoteBackground, rightEdge > frame.minX {
                let band = UIView(frame: CGRect(x: frame.minX,
                                                y: frame.minY,
                                                width: rightEdge - frame.minX,
                                                height: frame.height))
                band.backgroundColor = theme.quoteBackground
                band.layer.cornerRadius = theme.codeBlockCornerRadius
                band.isUserInteractionEnabled = false
                quoteBackgroundLayer.addSubview(band)
            }

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
    /// - parameter reusingOutside: 同 `computeCodeBlockFrames(reusingOutside:)`：
    ///            传视野附近的文档坐标矩形时，落在它外面的复选框沿用上一轮结果。
    /// - returns: `(boxes, pending)`。坐标和 `computeCodeBlockFrames` 同一套：
    ///           TextKit 给的矩形原点在 textContainer 左上角，画到 textView 里要补回 inset。
    ///           注意：不开 `private` 是为了让单元测试能直接调它
    func computeCheckboxFrames(reusingOutside band: CGRect? = nil) -> (boxes: [(info: CheckboxInfo, frame: CGRect)], pending: Bool) {
        guard let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              bounds.width > 1 else { return ([], false) }

        // 1) 扫描复选框标记。优先认**座位** —— 渲染层专门给按钮留的那块透明空间，摆它正中就不会挡到任何字；没有座位时（遮盖模式，或别的入口渲染出来的任务项）回退到 `[x]` 三个字符的矩形。
        let full = NSRange(location: 0, length: textStorage.length)
        var marked: [(NSRange, CheckboxInfo)] = []
        textStorage.enumerateAttribute(.markdownCheckboxSeat, in: full, options: []) { value, range, _ in
            guard let info = value as? CheckboxInfo else { return }
            marked.append((range, info))
        }
        if marked.isEmpty {
            textStorage.enumerateAttribute(.markdownCheckbox, in: full, options: []) { value, range, _ in
                guard let info = value as? CheckboxInfo else { return }
                marked.append((range, info))
            }
        }
        guard !marked.isEmpty else { return ([], false) }

        let documentStart = contentStorage.documentRange.location
        var boxes: [(info: CheckboxInfo, frame: CGRect)] = []
        boxes.reserveCapacity(marked.count)

        for (range, info) in marked {
            // 视野外的复选框沿用上一轮结果（理由见方法注释里的 reusingOutside）
            if let band,
               let cached = checkboxFrames.first(where: { $0.info === info })?.frame,
               !cached.intersects(band) {
                boxes.append((info, cached))
                continue
            }

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

    /// 把复选框摆到屏幕上（和 `positionQuoteDecorations` 同一套平移逻辑）
    func positionCheckboxes() {
        // 关掉隐式动画：见 beginDecorationPositioning 的注释（键盘弹出那一下复选框会从左上角飞过来）
        beginDecorationPositioning()
        defer { endDecorationPositioning() }
        checkboxLayer.frame = bounds
        // 复选框数量不多，每次重建比维护复用池省心
        checkboxLayer.subviews.forEach { $0.removeFromSuperview() }

        let theme = renderer.theme
        let style = theme.taskList
        let side = style.checkboxSide
        // ⚠️ 方框宽度**只跟字体有关**，和「当前那一项勾没勾」无关 —— 理由见 checkboxCoverWidth
        let coverWidth = checkboxCoverWidth(side: side)
        // 可见范围，上下各留 200pt 余量，滚快一点也不会闪出空白
        let visible = CGRect(x: 0, y: -200, width: bounds.width, height: bounds.height + 400)

        for entry in checkboxFrames {
            let anchor = entry.frame
            let buttonFrame: CGRect
            if style.coversCheckboxLiteral {
                // 遮盖模式：方框压在 `[x]` 正中，把它整个挡住（底色不透明）。宽度用「所有状态里最宽的那个字面量」算出来的**定值** —— 点前点后方框一样大
                buttonFrame = CGRect(x: anchor.midX - coverWidth / 2,
                                     y: anchor.midY - side / 2,
                                     width: coverWidth,
                                     height: side)
            } else {
                // 默认：anchor 是渲染层留出来的「座位」，方框摆在它正中 —— 左边是浅灰的 `-`、右边是浅灰的 `[x]`，两边都不挡
                buttonFrame = CGRect(x: anchor.midX - side / 2,
                                     y: anchor.midY - side / 2,
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
            // 只读模式：复选框照样画出来（它反映的是源码状态），但**不许点**。
            //
            // ⚠️ 这里用 `isUserInteractionEnabled = false` 而不是 `isEnabled = false`：前者会让
            // 这一层的 `hitTest` 直接跳过这个按钮，点击**穿透**给下面的 textView —— 用户依然能在
            // `[x]` 那三个字上放光标、选中它；后者只是让按钮自己不响应，点击照样被它吃掉，
            // 那一小块地方就永远点不到正文了（看着像界面坏了）。
            // target 也不用摘：按钮都不可交互了，`touchUpInside` 根本发不出来。
            button.isUserInteractionEnabled = !isReadOnly
            button.addTarget(self, action: #selector(checkboxTapped(_:)), for: .touchUpInside)
            checkboxLayer.addSubview(button)
        }
    }

    /// 遮盖模式下复选框要盖住 `[x]`，所以宽度得 ≥ 字面量在图里的宽度。
    ///
    /// ### 为什么宽度不能按「当前那一项的字面量」取（踩过的坑）
    /// `[ ]` / `[x]` / `[X]` 三个字面量在图里的宽度**各不相同**（正文 17pt 系统字体实测 15.95 / 20.09 / 22.71pt）。早先写成 `max(checkboxSide, literal.width)`，于是**点一下 `[ ]` 变 `[x]`，方框就从 16pt 长到 20pt** —— 用户看到的就是「点一下复选框变宽了」。
    ///
    /// 宽度只该跟**字体**有关：这里把三种字面量都量一遍取最宽的，再和方框边长取大。这样同一份文档里所有复选框、勾前勾后，宽度全都是同一个值。
    private func checkboxCoverWidth(side: CGFloat) -> CGFloat {
        guard let font = checkboxLiteralFont() else { return side }
        let widest = ["[ ]", "[x]", "[X]"]
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return max(side, widest)
    }

    /// `[x]` 那三个字符在图里用的字体（整篇正文同一套字体，量第一个就够了）
    private func checkboxLiteralFont() -> UIFont? {
        guard let first = checkboxFrames.first,
              let rendered = documentStore.renderedRange(
                  forSourceRange: NSRange(location: first.info.sourceStart, length: 3)),
              rendered.location < textStorage.length
        else { return nil }
        return textStorage.attribute(.font, at: rendered.location, effectiveRange: nil) as? UIFont
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
    /// ### ⚠️ 撤销这笔账得我们自己补（别再只设 `isProgrammaticEdit`）
    /// 点复选框是**程序自己发起**的编辑，系统不会替它记撤销。以前这里只设了
    /// `isProgrammaticEdit`，结果用户勾掉一个任务后按 ⌘Z，撤销的是**更早的另一件事**、
    /// 勾选纹丝不动 —— 既违反直觉，又可能一路误撤到别处去。
    /// 套一层 `performUndoableModelEdit` 就补上了这笔账（它顺带也替我们开 `isProgrammaticEdit`）。
    ///
    /// - parameter info: 被点到的复选框（它带着 `[` 在整篇源码里的偏移）
    func toggleCheckbox(_ info: CheckboxInfo) {
        let sourceRange = NSRange(location: info.sourceStart, length: 3)
        guard let rendered = documentStore.renderedRange(forSourceRange: sourceRange) else { return }
        performUndoableModelEdit(actionName: "切换任务状态") {
            applyEdit(renderedRange: rendered,
                      replacementText: info.isChecked ? "[ ]" : "[x]",
                      alreadyAppliedToTextStorage: false)
        }
    }

}
