//
//  MarkdownTypographyTests.swift
//  MarkdownEditorHy4Tests
//
//  「正文排版」那五项设置（字号 / 行高 / 段落间距 / 段落首行缩进 / 行宽上限）的验收测试。
//
//  分三层验，缺一层都不算数：
//  1. 配置层：默认值、落盘、越界夹取、「几个字 → 多少点」的换算；
//  2. 渲染层：这些数值**真的落进了**字体和 `NSParagraphStyle`（不是存了不用）；
//  3. 排版层：行高真的把后面的内容推下去了、行宽真的把正文收窄了。
//
//  第 3 层必须做：TextKit 2 会**无视**一部分 `NSParagraphStyle` 属性
//  （项目里已知 `.obliqueness` 就被它忽略），所以「属性写进去了」和「画面上有效果」
//  是两件事，只验前者会放过一条坏掉的设置。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownTypographyTests: XCTestCase {

    // MARK: - 测试脚手架

    /// 造一个临时配置文件地址，并登记「跑完删掉整个临时目录」。
    /// 所有用例都用它 —— 绝不碰用户真实的 Caches 目录，测试跑完不能把设置改了
    private func makeTempFileURL(_ name: String = "settings.json") -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownTypographyTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent(name)
    }

    /// 把「正文 / 标题 / 列表 / 引用 / 代码块」全占齐的一份小文档 ——
    /// 首行缩进那条要靠它验「只缩正文，别的都不缩」
    private var typographySample: String {
        """
        # 一级标题

        这是一段普通的正文。

        - 列表项

        > 引用里的一段话

        ```swift
        let a = 1
        ```
        """
    }

    /// 两段正文把两个代码块隔得很开 —— 「行高真的把后面推下去了」那条要用
    private var lineHeightSample: String {
        let filler = Array(repeating: "这是一段用来把第二个代码块顶到远处去的正文。", count: 12)
            .joined(separator: "\n\n")
        return """
        第一段正文。

        ```swift
        let a = 1
        ```

        \(filler)

        ```bash
        echo 第二个代码块
        ```
        """
    }

    /// 造一个**挂进真实窗口、排好版**的编辑器，再按 `configure` 改主题并重新渲染 ——
    /// 走的就是 App 里「设置页改一下 → 内容页重排一遍」那条完全相同的路。
    ///
    /// 为什么非得挂窗口：不挂上去 `bounds` 是零，`currentContainerWidth` 会退化成下限，
    /// 所有跟宽度、位置有关的断言都会变成假数字
    private func makeEditor(_ markdown: String,
                            configure: (inout MarkdownTheme) -> Void = { _ in }) -> MarkdownTextView {
        let textView = MarkdownTextView(markdown: markdown)
        textView.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        textView.layoutIfNeeded()

        configure(&textView.renderer.theme)
        textView.refreshTheme()
        textView.layoutIfNeeded()
        return textView
    }

    /// 取渲染结果里某段文字所在位置的字体
    private func font(of needle: String, in textView: MarkdownTextView) -> UIFont? {
        guard let location = renderedLocation(of: needle, in: textView) else { return nil }
        return textView.textStorage.attribute(.font, at: location, effectiveRange: nil) as? UIFont
    }

    /// 取渲染结果里某段文字所在段落的段落样式
    private func paragraphStyle(of needle: String, in textView: MarkdownTextView) -> NSParagraphStyle? {
        guard let location = renderedLocation(of: needle, in: textView) else { return nil }
        return textView.textStorage.attribute(.paragraphStyle, at: location, effectiveRange: nil)
            as? NSParagraphStyle
    }

    private func renderedLocation(of needle: String, in textView: MarkdownTextView) -> Int? {
        let range = (textView.textStorage.string as NSString).range(of: needle)
        return range.location == NSNotFound ? nil : range.location
    }

    /// 等两个代码块都排出 fragment，返回它们顶边的文档坐标（从上到下）
    private func codeBlockTops(in textView: MarkdownTextView) -> [CGFloat] {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let (frames, pending) = textView.computeCodeBlockFrames()
            if !pending, frames.count >= 2 {
                return frames.map(\.frame.minY).sorted()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return []
    }

    // MARK: - 配置层：默认值

    /// 排版这几项的默认值都该**跟渲染层的主题一致** ——
    /// 两边各写一份的话，用户会遇到「我什么都没调，外观怎么变了」
    func testDefaultsComeFromTheme() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        let theme = MarkdownTheme.default

        XCTAssertEqual(settings.bodyFontSize, Double(theme.bodyFont.pointSize), accuracy: 0.001,
                       "正文字号的默认值该等于主题里的正文大小")
        XCTAssertEqual(settings.lineHeightMultiple, 1.0, accuracy: 0.001,
                       "行高默认 1 倍：用字体自带的自然行高")
        XCTAssertEqual(settings.paragraphSpacing, Double(theme.paragraphSpacing), accuracy: 0.001,
                       "段间距的默认值该等于主题里的值")
        XCTAssertEqual(settings.paragraphIndentCharacters, 0, accuracy: 0.001,
                       "首行缩进默认不缩 —— 中文习惯是缩两个字，但那是偏好，不该替用户决定")
        XCTAssertEqual(settings.bodyContentWidth,
                       MarkdownEditorSettings.Limits.bodyContentWidth.upperBound, accuracy: 0.001,
                       "行宽默认停在量程最右端")
        XCTAssertNil(settings.bodyContentWidthLimit, "最右端表示「不限」，正文该照旧铺满窗口")
    }

    // MARK: - 配置层：落盘与夹取

    func testTypographySettingsArePersisted() {
        let url = makeTempFileURL()
        let settings = MarkdownEditorSettings(fileURL: url)
        settings.setBodyFontSize(20)
        settings.setLineHeightMultiple(1.5)
        settings.setParagraphSpacing(24)
        settings.setParagraphIndentCharacters(2)
        settings.setBodyContentWidth(600)

        let reloaded = MarkdownEditorSettings(fileURL: url)
        XCTAssertEqual(reloaded.bodyFontSize, 20, accuracy: 0.001)
        XCTAssertEqual(reloaded.lineHeightMultiple, 1.5, accuracy: 0.001)
        XCTAssertEqual(reloaded.paragraphSpacing, 24, accuracy: 0.001)
        XCTAssertEqual(reloaded.paragraphIndentCharacters, 2, accuracy: 0.001)
        XCTAssertEqual(reloaded.bodyContentWidth, 600, accuracy: 0.001)
    }

    /// 越界的值要夹住：直接调 setter 和「配置文件被手改」两条路都得防
    func testTypographyValuesAreClamped() throws {
        // 路径一：直接调 setter
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setBodyFontSize(999)
        settings.setLineHeightMultiple(0.2)
        settings.setParagraphSpacing(-5)
        settings.setParagraphIndentCharacters(99)
        settings.setBodyContentWidth(10)

        XCTAssertEqual(settings.bodyFontSize, 28, accuracy: 0.001, "字号超上限要夹回来")
        XCTAssertEqual(settings.lineHeightMultiple, 1.0, accuracy: 0.001, "行高不能小于 1 倍")
        XCTAssertEqual(settings.paragraphSpacing, 0, accuracy: 0.001, "段间距不能是负的")
        XCTAssertEqual(settings.paragraphIndentCharacters, 4, accuracy: 0.001)
        XCTAssertEqual(settings.bodyContentWidth, 320, accuracy: 0.001)

        // 路径二：配置文件被手改
        let url = makeTempFileURL()
        try Data(#"{"bodyFontSize": 1, "lineHeightMultiple": 9, "paragraphSpacing": 999}"#.utf8)
            .write(to: url)
        let reloaded = MarkdownEditorSettings(fileURL: url)
        XCTAssertEqual(reloaded.bodyFontSize, 12, accuracy: 0.001)
        XCTAssertEqual(reloaded.lineHeightMultiple, 2.0, accuracy: 0.001)
        XCTAssertEqual(reloaded.paragraphSpacing, 40, accuracy: 0.001)
    }

    /// 老配置文件里没有这几个新字段 → 各自退回默认，但不能把整份配置一起作废
    func testOldSettingsFileKeepsOtherValues() throws {
        let url = makeTempFileURL()
        try Data(#"{"tableMinColumnWidth": 96}"#.utf8).write(to: url)

        let settings = MarkdownEditorSettings(fileURL: url)
        XCTAssertEqual(settings.tableMinColumnWidth, 96, accuracy: 0.001, "别的设置不该被带走")
        XCTAssertEqual(settings.lineHeightMultiple, 1.0, accuracy: 0.001)
        XCTAssertNil(settings.bodyContentWidthLimit)
    }

    /// 行宽只在「没拖到最右端」时才是个真实上限
    func testContentWidthLimitTreatsTopOfRangeAsUnlimited() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        let top = MarkdownEditorSettings.Limits.bodyContentWidth.upperBound

        settings.setBodyContentWidth(top)
        XCTAssertNil(settings.bodyContentWidthLimit, "拖到最右端就是「不限」")

        settings.setBodyContentWidth(top - 20)
        XCTAssertEqual(settings.bodyContentWidthLimit ?? -1, top - 20, accuracy: 0.001,
                       "拖离最右端之后就恢复成一个真实的上限")
    }

    // MARK: - 配置层：换算成主题

    /// 用户选的是「缩几个字」，写进主题时得按字号换成点 ——
    /// 这样字号一变，缩进跟着变宽，「两个汉字」在任何字号下都是两个字
    func testApplyTypographyConvertsIndentCharactersToPoints() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setParagraphIndentCharacters(2)
        settings.setBodyFontSize(20)

        var theme = MarkdownTheme.default
        settings.applyTypography(to: &theme)
        XCTAssertEqual(theme.paragraphIndent, 40, accuracy: 0.001, "20pt 字号下，两个字就是 40 点")

        // 字号调大 → 缩进跟着变宽
        settings.setBodyFontSize(24)
        settings.applyTypography(to: &theme)
        XCTAssertEqual(theme.paragraphIndent, 48, accuracy: 0.001,
                       "字号变大以后，同样的「两个字」要更宽")
    }

    /// 换正文字号必须把**派生出来的**字体一起换掉，
    /// 否则标题会留在原来的大小上 —— 字号调大以后正文比 H2 还大
    func testApplyTypographyRebuildsEveryDerivedFont() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setBodyFontSize(20)

        var theme = MarkdownTheme.default
        settings.applyTypography(to: &theme)

        XCTAssertEqual(theme.bodyFont.pointSize, 20, accuracy: 0.001)
        XCTAssertEqual(theme.codeFont.pointSize, 19, accuracy: 0.001, "等宽字体取正文 -1")
        XCTAssertEqual(theme.headingFonts[1]?.pointSize ?? 0, 35, accuracy: 0.001, "H1 = 正文 +15")
        XCTAssertEqual(theme.headingFonts[3]?.pointSize ?? 0, 25, accuracy: 0.001, "H3 = 正文 +5")
        XCTAssertEqual(theme.headingFonts[6]?.pointSize ?? 0, 19, accuracy: 0.001, "H6 = 正文 -1")
        // 增量表本身在 MarkdownTheme.makeHeadingFonts（15/8/5/2/0/-1），改表就得同步改上面三条
    }

    func testApplyTypographyWritesLineHeightAndSpacing() {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setLineHeightMultiple(1.6)
        settings.setParagraphSpacing(28)

        var theme = MarkdownTheme.default
        settings.applyTypography(to: &theme)

        XCTAssertEqual(theme.lineHeightMultiple, 1.6, accuracy: 0.001)
        XCTAssertEqual(theme.paragraphSpacing, 28, accuracy: 0.001)
    }

    // MARK: - 渲染层：字号

    /// 字号要真的落到渲染出来的字体上（存了不用是最容易犯的错）
    func testBodyFontSizeReachesRenderedText() throws {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setBodyFontSize(24)
        let editor = makeEditor(typographySample) { settings.applyTypography(to: &$0) }

        let body = try XCTUnwrap(font(of: "这是一段普通的正文", in: editor), "找不到正文")
        XCTAssertEqual(body.pointSize, 24, accuracy: 0.001, "正文没按新字号渲染")

        let heading = try XCTUnwrap(font(of: "一级标题", in: editor), "找不到标题")
        XCTAssertEqual(heading.pointSize, 39, accuracy: 0.001,
                       "标题是从正文字号推出来的（H1 = 正文 +15），改字号时要一起变")
    }

    // MARK: - 渲染层：行高

    /// 1 倍时**不碰** `lineHeightMultiple`。
    ///
    /// 这个属性默认是 0，而 0 和 1 都是「照自然行高来」—— 默认状态干脆不写，
    /// 免得「什么都没调」的时候行高却和加这一项之前差一丝
    func testLineHeightIsNotWrittenAtOneX() throws {
        let editor = makeEditor(typographySample)
        let style = try XCTUnwrap(paragraphStyle(of: "这是一段普通的正文", in: editor))

        XCTAssertEqual(style.lineHeightMultiple, 0, accuracy: 0.001,
                       "1 倍时不该往段落样式里写这个属性")
    }

    func testLineHeightReachesParagraphStyle() throws {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setLineHeightMultiple(1.5)
        let editor = makeEditor(typographySample) { settings.applyTypography(to: &$0) }

        let body = try XCTUnwrap(paragraphStyle(of: "这是一段普通的正文", in: editor))
        XCTAssertEqual(body.lineHeightMultiple, 1.5, accuracy: 0.001, "正文段落没吃到行高")

        // 列表项也是文字，要跟着一起松
        let list = try XCTUnwrap(paragraphStyle(of: "列表项", in: editor))
        XCTAssertEqual(list.lineHeightMultiple, 1.5, accuracy: 0.001, "列表项也该跟着变松")
    }

    // MARK: - 渲染层：段落间距

    /// 正文和列表项要**用同一个**段间距。
    ///
    /// 列表项那条以前是把 12 写死在渲染器里的，所以这里专门盯一下 ——
    /// 不盯的话很容易出现「正文松了、列表还是挤的」
    func testParagraphSpacingReachesBodyAndListItemParagraphs() throws {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setParagraphSpacing(30)
        let editor = makeEditor(typographySample) { settings.applyTypography(to: &$0) }

        let body = try XCTUnwrap(paragraphStyle(of: "这是一段普通的正文", in: editor))
        XCTAssertEqual(body.paragraphSpacing, 30, accuracy: 0.001)

        let list = try XCTUnwrap(paragraphStyle(of: "列表项", in: editor))
        XCTAssertEqual(list.paragraphSpacing, 30, accuracy: 0.001,
                       "列表项的段间距要跟着设置走，不能还写死 12")
    }

    // MARK: - 渲染层：段落首行缩进

    /// 「缩进」只给正文段落。
    ///
    /// 四种都不该缩，各有理由：标题整行自成一级；列表项第一行是圆点/序号；
    /// 引用块整体已经往右内缩、左边还有竖条；代码块的围栏和正文都对左。
    func testFirstLineIndentOnlyAppliesToBodyParagraphs() throws {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setBodyFontSize(20)
        settings.setParagraphIndentCharacters(2)
        let editor = makeEditor(typographySample) { settings.applyTypography(to: &$0) }

        let body = try XCTUnwrap(paragraphStyle(of: "这是一段普通的正文", in: editor))
        XCTAssertEqual(body.firstLineHeadIndent, 40, accuracy: 0.001, "正文首行该缩进两个字（20pt × 2）")
        XCTAssertEqual(body.headIndent, 0, accuracy: 0.001, "只缩首行，换行以后的行不缩")

        let heading = try XCTUnwrap(paragraphStyle(of: "一级标题", in: editor))
        XCTAssertEqual(heading.firstLineHeadIndent, 0, accuracy: 0.001, "标题不缩")

        let list = try XCTUnwrap(paragraphStyle(of: "列表项", in: editor))
        XCTAssertEqual(list.firstLineHeadIndent, 0, accuracy: 0.001,
                       "列表项第一行是圆点，缩了会顶歪")

        let quote = try XCTUnwrap(paragraphStyle(of: "引用里的一段话", in: editor))
        XCTAssertEqual(quote.firstLineHeadIndent, quote.headIndent, accuracy: 0.001,
                       "引用块整体已经内缩，首行不该再多缩一道")
    }

    // MARK: - 排版层：真的画得出来

    /// 行高必须**真的把后面的内容推下去**。
    ///
    /// 拿「第二个代码块落在哪一行」当尺子：它离文首隔了一整段正文，
    /// 行高从 1 倍调到 2 倍，它必须明显往下走。只验段落样式属性不够 ——
    /// TextKit 2 会无视一部分 `NSParagraphStyle` 属性（`.obliqueness` 就是前车之鉴）
    func testLineHeightActuallyPushesFollowingContentDown() throws {
        let normal = codeBlockTops(in: makeEditor(lineHeightSample))
        XCTAssertEqual(normal.count, 2, "样例里的两个代码块没都排出来")

        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setLineHeightMultiple(2.0)
        let tall = codeBlockTops(in: makeEditor(lineHeightSample) { settings.applyTypography(to: &$0) })
        XCTAssertEqual(tall.count, 2)

        let shifted = try XCTUnwrap(tall.last) - (try XCTUnwrap(normal.last))
        XCTAssertGreaterThan(shifted, 50,
                             "行高调成 2 倍，后面那块代码只被推下去 \(shifted) 点 —— 行高没真正生效")
    }

    /// 段落间距同理：把 12 段正文之间的空隙拉开，后面的代码块必须往下走
    func testParagraphSpacingActuallyMovesFollowingContentDown() throws {
        let normal = codeBlockTops(in: makeEditor(lineHeightSample))
        XCTAssertEqual(normal.count, 2)

        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setParagraphSpacing(40)
        let loose = codeBlockTops(in: makeEditor(lineHeightSample) { settings.applyTypography(to: &$0) })
        XCTAssertEqual(loose.count, 2)

        let shifted = try XCTUnwrap(loose.last) - (try XCTUnwrap(normal.last))
        XCTAssertGreaterThan(shifted, 200,
                             "段间距从默认调到 40，十几段的空隙只多出 \(shifted) 点 —— 没真正生效")
    }

    // MARK: - 排版层：行宽

    /// 默认「不限」：一根手指头都不该动
    func testNoWidthLimitKeepsInsetsUntouched() {
        let editor = makeEditor(typographySample)
        let before = editor.textContainerInset

        editor.maxContentWidth = 5000        // 比窗口宽得多 = 等于没设
        editor.layoutIfNeeded()

        XCTAssertEqual(editor.textContainerInset, before, "窗口本来就比上限窄，不该动内边距")
    }

    /// 设了上限：正文栏必须真的收到上限那么宽，而且**两边留白**（居中），
    /// 不是把文字往左一挤了事
    func testWidthLimitNarrowsAndCentersTheTextColumn() {
        let editor = makeEditor(typographySample)
        let full = editor.currentContainerWidth
        XCTAssertGreaterThan(full, 500, "700 宽的窗口，默认该铺满")

        editor.maxContentWidth = 400
        editor.layoutIfNeeded()

        XCTAssertEqual(editor.currentContainerWidth, 400, accuracy: 2,
                       "正文栏没收到用户设的 400 点，实际 \(editor.currentContainerWidth)")
        XCTAssertLessThan(editor.currentContainerWidth, full, "比不限宽时该窄")

        // 左右留白对称 = 标题栏和正文在窗口里居中。装订线（折叠三角那条）是左边本来就有的，
        // 所以左边比右边正好多出这么宽 —— 多的部分不能跑到一边去
        let insetDifference = editor.textContainerInset.left - editor.textContainerInset.right
        XCTAssertEqual(insetDifference, editor.renderer.theme.foldGutterWidth, accuracy: 0.5,
                       "多出来的留白该左右平分，全挤到一边就不是居中了")
    }

    /// 窗口变宽 / 变窄时，行宽上限要跟着重算（不然拉大窗口后正文还是旧的宽度）
    func testWidthLimitReactsToWindowResize() {
        let editor = makeEditor(typographySample)
        editor.maxContentWidth = 400
        editor.layoutIfNeeded()
        XCTAssertEqual(editor.currentContainerWidth, 400, accuracy: 2)

        // 窗口缩到比上限还窄 → 不再留白，正文铺满
        editor.frame = CGRect(x: 0, y: 0, width: 360, height: 900)
        editor.layoutIfNeeded()
        XCTAssertGreaterThan(editor.currentContainerWidth, 250,
                             "窗口比上限窄的时候该铺满，不能再往里缩")

        // 再拉宽 → 回到上限
        editor.frame = CGRect(x: 0, y: 0, width: 900, height: 900)
        editor.layoutIfNeeded()
        XCTAssertEqual(editor.currentContainerWidth, 400, accuracy: 2)
    }

    // MARK: - 重排之后光标不能跑

    /// 设置页拖滑块时每动一下就整篇重排一次，光标必须留在原地 ——
    /// 否则拖两下光标就跳回文首，用户根本没法一边看效果一边继续写
    func testRefreshThemeKeepsTheCaretAtTheSameSourcePosition() throws {
        let editor = makeEditor(typographySample)
        let source = editor.documentStore.sourceDocument as NSString
        let target = source.range(of: "普通的正文").location + 2
        XCTAssertGreaterThan(target, 0, "样例文档里找不到定位用的文字")

        editor.selectedRange = NSRange(
            location: editor.documentStore.renderedCaret(forSourceOffset: target), length: 0)

        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setBodyFontSize(22)
        settings.applyTypography(to: &editor.renderer.theme)
        editor.refreshTheme()

        let moved = editor.documentStore.sourceCaret(forRenderedOffset: editor.selectedRange.location)
        XCTAssertEqual(moved, target, "重排之后光标跑到别的源码位置去了")
    }

    // MARK: - 设置页

    /// 设置页里该有这五个滑块，拖一下要写回配置并吸到步进上。
    ///
    /// ⚠️ 帧高给得很大是**故意的**：`UITableView` 只创建可见范围内的 cell，
    /// 帧太矮的话靠下的行压根不存在，`XCTUnwrap` 会因为「找不到控件」而失败 ——
    /// 那是测试自己没把页面铺开，不是功能坏了
    func testSettingsPageHasTypographySlidersAndWritesBack() throws {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        let controller = SettingsViewController(settings: settings)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 2600)
        controller.view.layoutIfNeeded()

        // 按量程当身份证找（12~28 / 1~2 / 0~40 / 0~4 / 320~1200，和别的分组都不冲突）
        let fontSlider = try XCTUnwrap(slider(in: controller.view, range: 12...28),
                                       "找不到「正文字号」的滑块")
        let lineSlider = try XCTUnwrap(slider(in: controller.view, range: 1...2),
                                       "找不到「行高」的滑块")
        let spacingSlider = try XCTUnwrap(slider(in: controller.view, range: 0...40),
                                          "找不到「段落间距」的滑块")
        let indentSlider = try XCTUnwrap(slider(in: controller.view, range: 0...4),
                                         "找不到「段落首行缩进」的滑块")
        let widthSlider = try XCTUnwrap(slider(in: controller.view, range: 320...1200),
                                        "找不到「行宽上限」的滑块")

        // 故意给不在步进上的值，验证会被吸到最近的一档
        fontSlider.value = 21.4
        fontSlider.sendActions(for: .valueChanged)
        XCTAssertEqual(settings.bodyFontSize, 21, accuracy: 0.001, "字号该按 1 点一档吸")

        lineSlider.value = 1.43
        lineSlider.sendActions(for: .valueChanged)
        XCTAssertEqual(settings.lineHeightMultiple, 1.45, accuracy: 0.001, "行高该按 0.05 一档吸")

        spacingSlider.value = 13
        spacingSlider.sendActions(for: .valueChanged)
        XCTAssertEqual(settings.paragraphSpacing, 14, accuracy: 0.001, "段间距该按 2 点一档吸")

        indentSlider.value = 1.7
        indentSlider.sendActions(for: .valueChanged)
        XCTAssertEqual(settings.paragraphIndentCharacters, 1.5, accuracy: 0.001,
                       "缩进该按 0.5 字一档吸")

        widthSlider.value = 466
        widthSlider.sendActions(for: .valueChanged)
        XCTAssertEqual(settings.bodyContentWidth, 460, accuracy: 0.001, "行宽该按 20 点一档吸")

        // 这几项没有「当前模式下不生效」的情况，不该被灰掉
        XCTAssertTrue(fontSlider.isEnabled)
        XCTAssertTrue(widthSlider.isEnabled)
    }

    /// 行宽拖到最右端 → 显示「不限」，而且真的按「不限」算
    func testDraggingContentWidthToTheEndMeansUnlimited() throws {
        let settings = MarkdownEditorSettings(fileURL: makeTempFileURL())
        settings.setBodyContentWidth(600)

        let controller = SettingsViewController(settings: settings)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 420, height: 2600)
        controller.view.layoutIfNeeded()

        let widthSlider = try XCTUnwrap(slider(in: controller.view, range: 320...1200))
        widthSlider.value = 1200
        widthSlider.sendActions(for: .valueChanged)

        XCTAssertNil(settings.bodyContentWidthLimit, "拖到最右端该变成「不限」")
    }

    // MARK: - 找控件的小工具

    /// 按「滑块的量程」找一个滑块出来。
    ///
    /// 为什么不用顺序或者 tag：顺序取决于视图树怎么排，挪一行就挂；
    /// tag 是行枚举的 rawValue，往枚举里插一个 case 就全错位。
    /// 每行的量程是定死的，拿它当身份证最稳（⚠️ 上下界要**一起**看：设置页里「高度百分比」和「背景不透明度」的上界都是 1）
    private func slider(in view: UIView, range: ClosedRange<Double>) -> UISlider? {
        let lower = Float(range.lowerBound)
        let upper = Float(range.upperBound)
        for subview in view.subviews {
            if let slider = subview as? UISlider,
               slider.minimumValue == lower, slider.maximumValue == upper {
                return slider
            }
            if let found = slider(in: subview, range: range) { return found }
        }
        return nil
    }
}
