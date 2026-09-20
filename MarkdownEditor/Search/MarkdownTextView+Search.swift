//
//  MarkdownTextView+Search.swift
//  MarkdownEditorHy4
//
//  编辑器侧的查找 / 替换：搜 source → 换算成渲染区间 → 画高亮 → 上一个/下一个 → 执行替换
//
//  单独放一个文件是为了让「编辑器 ←→ 查找」的全部接触面一眼可见，和 `MarkdownTextView+Outline.swift` 是同一个分文件的原因。
//

import UIKit

// MARK: - 查找状态

/// 查找 / 替换的运行时状态。
///
/// ### 为什么包成一个结构体
/// Swift 的 extension 里不能声明存储属性，而查找这一整套想放在独立文件里，所以主文件里只留了一个 `searchState` 坑位，字段都在这儿。
struct SearchState {

    /// 当前查找的文字。**空串 = 没有查找在进行**（它就是「是否活跃」的唯一判据）
    var query = ""

    var options = SearchOptions()

    /// 用哪个查找算法。换成别的只要改这里 —— 编辑器不认识任何具体算法类型，和 `MarkupToAttributedRenderer.codeHighlighter` 是同一种接法。
    var searcher: MarkdownSearching = PlainTextSearcher()

    /// 命中项，坐标系是**源码**的 UTF-16 偏移（按位置递增）。
    ///
    /// ### 为什么存源码坐标而不是渲染坐标
    /// 文档是活的：每一次编辑都可能让后面的渲染坐标整体平移，而源码坐标只有被编辑的那一段会变。（复制 / 大纲那一整套也是建立在「源码才是真源」之上的。）
    var matches: [NSRange] = []

    /// 与 `matches` 一一对应：每个命中在渲染文本里对应的区间。
    /// 一个命中跨了块时会得到**多段**（见 `MarkdownDocumentStore.renderedRanges`）。
    var renderedRanges: [[NSRange]] = []

    /// 当前是第几个命中（-1 = 没有当前项）
    var currentIndex: Int = -1

    /// 每个命中在**文档坐标系**里的矩形（key 是命中下标）。
    ///
    /// 只有滚进视野附近的命中才会被量出来 —— 屏幕外问 TextKit 要到的是估算值，差几十上百点（代码块背景那次踩过），量了也不能用。
    var matchFrames: [Int: [CGRect]] = [:]

    /// 内容或者宽度变了 → 之前量过的矩形全部作废。
    /// 注意**纯滚动不需要置位**：文档坐标系不受滚动影响。
    var needsFrameRefresh = true

    /// 替换动作正在进行：这段时间别把「内容变了」报给外面。
    ///
    /// ### 为什么需要这么一个开关
    /// 替换本身会触发 `applyEdit`，而 `applyEdit` 末尾会通知查找协调者「文档变了、去重查」。
    /// 但替换自己紧接着就重查了一遍（还要把当前项停在合适的位置），再由协调者出于防抖重查一次，会把当前项顶回第一个 —— 用户看到的就是「一替换就跳回文首」。
    /// 所以自己能收尾的场合就别再麻烦外面了。
    var suppressesChangeNotice = false

    /// 有没有一次查找正在进行
    var isActive: Bool { !query.isEmpty }
}

// MARK: - 高亮层

/// 查找命中的高亮层：一批圆角矩形，自己画。
///
/// ### 为什么是「一个 view 自己画」而不是给每个命中加一个 subview
/// 一屏可能有几十个命中，滚动时每帧重建几十个 UIView 太贵。这里只维护一个 view，在 `draw(_:)` 里循环填色 —— 和 `CodeBlockBackgroundLayer` 的思路一致，只是它选择用 subview。
///
/// ### 这里的颜色为什么不必刻意追求半透明
/// 挂在**文字上**的 `.backgroundColor`（行内代码那次）必须是半透明的：它跟着文字一起画，会盖住画在文字下面的系统选中高亮 —— 表现为「框选看着像没选中」。
/// 而这一层是独立的 view，画在所有文字**下面**（见 `setupSearchDecorations` 的插入位置），和选中高亮碰不着。仍然只给到 0.5~0.9 的透明度，纯粹是为了让命中下面正文的行距、底色这些还能透出来一点，别把整行糊成一团色块。
final class SearchHighlightLayer: UIView {

    /// 要画的矩形，**viewport 坐标系**（=`bounds` 坐标系，因为本层的 frame 跟着 bounds 走）
    private(set) var entries: [(rect: CGRect, isCurrent: Bool)] = []

    private var normalFill = UIColor.clear
    private var currentFill = UIColor.clear

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        // 本层只是陪衬：整体都要贴合、铺满 bounds
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("SearchHighlightLayer 不支持从 coder 解档")
    }

    /// 更新要画的矩形。颜色和上一次完全一样、且列表都是空的时候直接跳过，省掉一次重绘。
    func setEntries(_ list: [(rect: CGRect, isCurrent: Bool)],
                    normal: UIColor,
                    current: UIColor) {
        let unchanged = list.isEmpty && entries.isEmpty
        entries = list
        normalFill = normal
        currentFill = current
        guard !unchanged else { return }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard !entries.isEmpty else { return }
        for entry in entries {
            let color = entry.isCurrent ? currentFill : normalFill
            color.setFill()
            // 命中块跟着字面走高度，用一点圆角看着更像「系统查找」的色块
            UIBezierPath(roundedRect: entry.rect, cornerRadius: 2).fill()
        }
    }
}

// MARK: - 数据源：协调者通过这几个方法取数据 / 下指令

extension MarkdownTextView: MarkdownSearchDataSource {

    var searchMatchSummary: (current: Int, total: Int) {
        (searchState.currentIndex, searchState.matches.count)
    }

    /// 跑一次查找：重算命中列表，然后把当前项定到第一个并滚过去。
    @discardableResult
    func performSearch(query: String, options: SearchOptions) -> Int {
        let count = recomputeMatches(query: query, options: options)
        searchState.currentIndex = count > 0 ? 0 : -1
        // 先量一次视野附近的矩形，再滚 —— 跳过去之后第一帧就有黄块，不用等下一轮布局
        updateSearchHighlightsIfNeeded()
        scrollToCurrentMatch()
        return count
    }

    func stepSearchMatch(by delta: Int) {
        let count = searchState.matches.count
        guard count > 0, searchState.currentIndex >= 0 else { return }
        // 先 +count 再加余数：Swift 的取模对负数给负结果，不加这步「上一个」到第 0 个时会变成 -1
        searchState.currentIndex = (searchState.currentIndex + delta + count) % count
        positionSearchHighlights()
        scrollToCurrentMatch()
    }

    @discardableResult
    func replaceCurrentSearchMatch(with replacement: String) -> Int {
        guard searchState.currentIndex >= 0,
              searchState.currentIndex < searchState.matches.count else { return searchState.matches.count }

        let target = searchState.matches[searchState.currentIndex]
        let query = searchState.query
        let options = searchState.options
        // 新生成的文字结尾（源码坐标）：重查之后要落在这个位置的**后面**
        let landing = target.location + (replacement as NSString).length

        replace(sourceRange: target, with: replacement, actionName: "替换")

        // 为什么要落到 `landing` 之后而不是接着用原来的序号：
        // 万一替换文字里还含着查找串（把 "ab" 换成 "abcab"），停在原序号就会一直盯着新出现的那一处，用户按「下一个」永远原地打转。往后面找第一个，等于替用户自动前进一格。
        rerunSearch(query: query, options: options, landing: { $0.location >= landing })
        return searchState.matches.count
    }

    @discardableResult
    func replaceAllSearchMatches(with replacement: String) -> Int {
        let matches = searchState.matches
        guard !matches.isEmpty else { return 0 }

        let query = searchState.query
        let options = searchState.options
        let wholeSource = documentStore.fullSource as NSString

        // ⚠️ 必须从**后往前**改（新手最容易踩的坑，务必记住）：
        // 正序替换的话，前面改完长度一变，后面那些还没处理的命中坐标就整体平移了，第二次替换会打在错的地方 —— 表现是「替换完的文档乱成一团」。
        // 倒着改永远不会动到尚未处理的区间。
        let builder = NSMutableString(string: wholeSource)
        for range in matches.reversed() { builder.replaceCharacters(in: range, with: replacement) }

        replace(sourceRange: NSRange(location: 0, length: wholeSource.length),
                with: builder as String,
                actionName: "替换全部")

        // 替换文字本身可能又含着查找串（比如把 a 换成 aaa），重查一遍把结果显示出来
        rerunSearch(query: query, options: options)
        return matches.count
    }

    func clearSearchHighlight() {
        searchState.query = ""
        searchState.matches = []
        searchState.renderedRanges = []
        searchState.matchFrames.removeAll()
        searchState.currentIndex = -1
        searchState.needsFrameRefresh = true
        positionSearchHighlights()
    }

    // MARK: 命中列表

    /// 重算「命中列表 + 每个命中的渲染区间」。不动当前项、也不滚 —— 收尾（定位到哪一个、要不要滚）交给调用方，因为替换之后想去的地方和首次查找不一样。
    @discardableResult
    private func recomputeMatches(query: String, options: SearchOptions) -> Int {
        searchState.query = query
        searchState.options = options
        // 旧的矩形是按旧的坐标量出来的，一次都用不了了
        searchState.matchFrames.removeAll()
        searchState.needsFrameRefresh = true

        guard !query.isEmpty else {
            searchState.matches = []
            searchState.renderedRanges = []
            return 0
        }

        // ### 永远在源码上搜，不在显示文本上搜
        // 显示文本里混着图片 / 表格 / 圆点这类「多出来的字符」，在它上面搜既多余，也容易把占位符当正文匹配到。
        searchState.matches = searchState.searcher.find(query: query,
                                                        in: documentStore.fullSource,
                                                        options: options)
        refreshMatchRenderedRanges()
        return searchState.matches.count
    }

    /// 把每个命中的源码区间翻译成渲染区间。
    ///
    /// 折叠起来（被收进标题里）的那些块没有渲染字符，`renderedRanges` 会返回空数组 —— 于是这个命中既不画黄块也不参与替换，和「折叠的内容先不动它」是一致的。
    private func refreshMatchRenderedRanges() {
        var mapped: [[NSRange]] = []
        mapped.reserveCapacity(searchState.matches.count)
        for range in searchState.matches {
            mapped.append(documentStore.renderedRanges(forSourceRange: range))
        }
        searchState.renderedRanges = mapped
    }

    /// 用当前的 query 重查一遍，并把「当前项」落在指定的位置。
    /// - parameter landing: 返回 true 的第一个命中成为当前项；都没有就停在第一个。
    private func rerunSearch(query: String, options: SearchOptions, landing: ((NSRange) -> Bool)? = nil) {
        guard !query.isEmpty else { return }
        let count = recomputeMatches(query: query, options: options)
        searchState.currentIndex = landing.flatMap { pick in searchState.matches.firstIndex { pick($0) } } ?? (count > 0 ? 0 : -1)
        updateSearchHighlightsIfNeeded()
        scrollToCurrentMatch()
    }

    // MARK: 执行替换

    /// 把源码里某一段换成别的文字，**并且这一步可以撤销**。
    ///
    /// ### 为什么不能直接改 textStorage
    /// 走了 `applyEdit` 这条标准编辑管线，等于白拿三样东西：
    /// 源码和渲染同时更新、只重渲染受影响的块、 invalidation 与装饰层刷新自动发生。
    /// 这和点复选框那一轮的结论是同一条：不要为「替换」发明新的改文档方式。
    private func replace(sourceRange: NSRange, with replacement: String, actionName: String) {
        searchState.suppressesChangeNotice = true
        defer { searchState.suppressesChangeNotice = false }

        performUndoableModelEdit(actionName: actionName) {
            if let rendered = singleRenderedRange(forSourceRange: sourceRange) {
                applyEdit(renderedRange: rendered,
                          replacementText: replacement,
                          alreadyAppliedToTextStorage: false)
            } else {
                // 跨块的（或压根找不到渲染区间的）：增量管线的坐标换算在这没有意义，直接按「整篇源码换一份」来做 —— 代价是一次全篇重渲染，而「替换全部」本来就要动大半篇，这一刀在这儿砍下去正好。
                let newSource = (documentStore.fullSource as NSString)
                    .replacingCharacters(in: sourceRange, with: replacement)
                restoreDocument(source: newSource, caret: selectedRange.location)
            }
        }
    }

    /// 源码区间对应的**单段**渲染区间；跨块（或完全没有渲染字符）时返回 nil。
    private func singleRenderedRange(forSourceRange sourceRange: NSRange) -> NSRange? {
        let pieces = documentStore.renderedRanges(forSourceRange: sourceRange)
        return pieces.count == 1 ? pieces[0] : nil
    }

    // MARK: 滚动到当前命中

    /// 把当前命中滚进视野。「滚动必须分好几轮才收敛」这件事和跳标题是完全同一个问题（TextKit 2 只对排过版的位置给真值），所以直接复用 `scrollToRenderedOffset`，不另写一套。
    private func scrollToCurrentMatch() {
        guard searchState.currentIndex >= 0,
              searchState.currentIndex < searchState.renderedRanges.count,
              let rendered = searchState.renderedRanges[searchState.currentIndex].first else { return }
        scrollToRenderedOffset(rendered.location)
    }

    // MARK: 高亮

    /// 每次布局（以及每一次查找之后）看一眼：有没有该算矩形还没算的命中。
    ///
    /// ### 为什么不一上来就把几百个命中的矩形全算出来
    /// 量一个区间的矩形要问 TextKit 排版，而屏幕外的位置上 TextKit 给的是**估算值**（差几十上百点，见 `computeCodeBlockFrames` 的注释），量了也不能用。
    /// 所以只给视野附近的命中量，量过的一直缓存在 `matchFrames` 里。
    /// 「视野优先 + 缓存」这套判断和 `refreshDecorationsNearViewport` 是同一个思路。
    func updateSearchHighlightsIfNeeded() {
        guard searchState.isActive, !searchState.renderedRanges.isEmpty else {
            positionSearchHighlights()
            return
        }
        computeMatchFramesNearViewportIfNeeded()
        positionSearchHighlights()
    }

    private func computeMatchFramesNearViewportIfNeeded() {
        guard let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              bounds.width > 1 else { return }
        // 量不到视口（首帧还没排版）就等下一轮 —— layoutSubviews 会反复走到这里
        guard let viewport = renderedRangeInViewport() else { return }

        let span = max(1, viewport.end - viewport.start)
        // 上下各扩一屏：等它真的露出来时，矩形早就算好了
        let lower = viewport.start - span
        let upper = viewport.end + span

        for entry in searchState.renderedRanges.enumerated() {
            let nearViewport = entry.element.contains { $0.location <= upper && NSMaxRange($0) >= lower }
            guard nearViewport else { continue }
            // 已经量过就不再问 TextKit（除非内容或宽度变了 —— 那时 needsFrameRefresh 为真）
            guard searchState.needsFrameRefresh || searchState.matchFrames[entry.offset] == nil else { continue }

            var frames: [CGRect] = []
            for range in entry.element {
                frames.append(contentsOf: segmentFrames(forRenderedRange: range,
                                                        contentStorage: contentStorage,
                                                        layoutManager: layoutManager))
            }
            searchState.matchFrames[entry.offset] = frames
        }
        searchState.needsFrameRefresh = false
    }

    /// 一个渲染区间在**文档坐标系**里的矩形。
    ///
    /// 命中被排到好几行时会占多行，`enumerateTextSegments` 一次给一段、这里全都要：
    /// 只取第一段的话黄块就停在第一行的末尾；把它们 union 成一块的话，中间那些和命中无关的行（行首到行尾的空白区域）也会被整块涂满。
    private func segmentFrames(forRenderedRange range: NSRange,
                               contentStorage: NSTextContentStorage,
                               layoutManager: NSTextLayoutManager) -> [CGRect] {
        let documentStart = contentStorage.documentRange.location
        guard let start = contentStorage.location(documentStart, offsetBy: range.location),
              let end = contentStorage.location(documentStart, offsetBy: NSMaxRange(range)),
              let textRange = NSTextRange(location: start, end: end) else { return [] }

        var results: [CGRect] = []
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
            guard !segment.isNull else { return true }
            // 坐标系换算（推导见 computeCodeBlockFrames 里的注释）：
            // TextKit 给的矩形不含 textContainerInset，画到 textView 里要补回来
            results.append(CGRect(x: segment.minX + textContainerInset.left,
                                  y: segment.minY + textContainerInset.top,
                                  width: segment.width,
                                  height: segment.height))
            return true
        }
        return results
    }

    /// 把缓存的文档坐标搬到屏幕上，交给高亮层去画。
    ///
    /// 滚动中每帧都会走到这里（由 contentOffset 的 KVO 调用），所以它只做「平移 + 过滤不可见的」，一丁点 TextKit 都不碰 —— 那一步在 `updateSearchHighlightsIfNeeded` 里。
    func positionSearchHighlights() {
        searchHighlightLayer.frame = bounds

        var entries: [(rect: CGRect, isCurrent: Bool)] = []
        // 可见范围上下各留 200pt 余量，滚快一点也不会闪出空白（和代码块背景同一个常数）
        let visible = CGRect(x: 0, y: -200, width: bounds.width, height: bounds.height + 400)

        for (index, frames) in searchState.matchFrames {
            for frame in frames {
                var rect = frame
                rect.origin.x -= contentOffset.x
                rect.origin.y -= contentOffset.y
                guard rect.intersects(visible) else { continue }
                // 左右各撑开 1pt：紧贴着字面的一条细线看着太寒酸
                entries.append((rect: rect.insetBy(dx: -1, dy: 0), isCurrent: index == searchState.currentIndex))
            }
        }
        // 当前项排在最后画：和别的黄块贴到一起时它压在最上面
        entries.sort { !$0.isCurrent && $1.isCurrent }

        let theme = renderer.theme
        searchHighlightLayer.setEntries(entries,
                                        normal: theme.searchMatchBackground,
                                        current: theme.searchCurrentMatchBackground)
    }
}

// MARK: - 打开查找框时的预填词

extension MarkdownTextView {

    /// 正文里当前选中的那段文字，还原成 **markdown 源码**（按 ⌘F 时拿它预填查找框）。
    ///
    /// ### 为什么要查映射表，而不是直接读屏幕上的富文本
    /// 富文本里混着「屏幕上显示、源码里并不是这样」的字符（图片占位符、列表圆点、纯装饰），
    /// 直接读会拿到错的东西。所以一律走 `documentStore` 的映射表 —— 和复制功能（`handleCopy`）是同一条路。
    ///
    /// 选中跨了好几行时只取**第一行**：查找框是一行输入框，塞一段带换行的文字进去没有意义。
    /// 没选中、或者选中的全是装饰字符时返回 `nil`。
    var selectedSourceText: String? {
        let range = selectedRange
        guard range.length > 0 else { return nil }
        let source = documentStore.sourceText(forRenderedRange: range)
        let firstLine = source.components(separatedBy: .newlines).first ?? ""
        // 选区两头常带着空格（双击选词、拖选拖过头），填进查找框之前顺手去掉
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
