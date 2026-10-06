//
//  MarkdownFootnoteTests.swift
//  MarkdownEditorHy4
//
//  脚注（`[^1]` 引用 / `[^1]: 说明` 定义）的渲染测试。
//
//  ### 这里守的三条
//  1. **认得出**：正文里的 `[^1]` 要被打上引用标记、行首的 `[^1]:` 要被认成定义块；
//  2. **不动字符**：脚注是纯属性语法，渲染串长度必须和源码一致（长度一变，撤销就按错的长度记账）；
//  3. **悬空引用看得出来**：引用了没定义的 ID 时换个颜色，但不报错、字符一个不少。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownFootnoteTests: XCTestCase {

    // MARK: 小工具

    /// 渲染一段 markdown。
    /// - parameter definedIDs: 这篇里已经写了定义的脚注 ID（模拟「文档里有没有对应的定义」）
    private func render(_ source: String,
                        definedIDs: Set<String> = []) -> (text: NSAttributedString, theme: MarkdownTheme) {
        var theme = MarkdownTheme.default
        // 给一个和正文色明显不同的链接色，方便断言「引用用的是强调色」而不是碰巧和正文同色
        theme.linkColor = UIColor(red: 0.10, green: 0.20, blue: 0.90, alpha: 1.00)
        let renderer = MarkupToAttributedRenderer(theme: theme, containerWidth: 600)
        renderer.footnoteDefinitionIDs = definedIDs
        let (text, _) = renderer.render(blockSource: source)
        return (text, theme)
    }

    /// 取字符串里某段文字的属性
    private func attribute(_ key: NSAttributedString.Key,
                           of needle: String,
                           in text: NSAttributedString) -> Any? {
        let plain = text.string as NSString
        let range = plain.range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return text.attribute(key, at: range.location, effectiveRange: nil)
    }

    /// 把 UIColor 拆成 RGBA 字符串再比（同一个颜色可能落在不同色彩空间里，直接比对象会误判）
    private func rgba(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%.2f,%.2f,%.2f,%.2f", r, g, b, a)
    }

    /// 颜色的透明度：0 = 全透明（画不出来），1 = 完全不透明
    private func alpha(of color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return a
    }

    // MARK: 引用

    /// 正文里的 `[^1]` 要被打上引用标记，值是它的 ID —— 点击跳转靠这个 ID 去查定义
    func testReferenceIsMarkedWithItsID() throws {
        let (text, _) = render("正文里的[^1]引用\n", definedIDs: ["1"])

        let id = try XCTUnwrap(attribute(.markdownFootnoteReference, of: "[^1]", in: text) as? String,
                               "`[^1]` 这几个字符上该挂着脚注 ID")
        XCTAssertEqual(id, "1", "挂的 ID 要就是源码里写的那个")
    }

    /// 引用要画成上标：字号比正文小、基线往上抬
    func testReferenceIsDrawnAsSuperscript() throws {
        let (text, theme) = render("正文里的[^1]引用\n", definedIDs: ["1"])

        let font = try XCTUnwrap(attribute(.font, of: "[^1]", in: text) as? UIFont, "引用上该有字体")
        XCTAssertLessThan(font.pointSize, theme.bodyFont.pointSize, "引用标记该比正文小一号，才像上标")
        XCTAssertGreaterThan(font.pointSize, 1, "引用是看得见的正经字号")

        let offset = try XCTUnwrap(attribute(.baselineOffset, of: "[^1]", in: text) as? NSNumber,
                                   "引用该有 baselineOffset（没有就是没抬起来，看着还是正文里的普通字）")
        XCTAssertGreaterThan(offset.doubleValue, 0, "上标要往上抬，不是往下沉")
    }

    /// 方括号和编号一起画出来：`[^` 和 `]` 跟中间那个编号**同一副样子**（同字号、同色），源码四个字符一个不少。
    ///
    /// ### 为什么是「整段一起画」而不是「把方括号替换掉」
    /// 想让正文里只留下一个上标的编号，最简单的做法是渲染时把 `[^1]` 换成 `1` —— 但那样渲染串就比源码短了：「全选复制 === 源文件」当场不成立，撤销按「插入时的字符数」记账也会算错（保真度那两条在守这个）。
    /// 所以字符照旧，改的只有画笔：整段一起套上标样式，屏幕上看到的是缩小上抬的 `[^1]`。
    func testReferenceBracketsAreDrawnLikeTheNumber() throws {
        let (text, _) = render("正文里的[^1]引用\n", definedIDs: ["1"])

        let headColor = try XCTUnwrap(attribute(.foregroundColor, of: "[^", in: text) as? UIColor)
        let numberColor = try XCTUnwrap(attribute(.foregroundColor, of: "1]", in: text) as? UIColor)
        let tailColor = try XCTUnwrap(attribute(.foregroundColor, of: "]引用", in: text) as? UIColor)
        XCTAssertEqual(rgba(headColor), rgba(numberColor), "`[^` 该和编号一个颜色 —— 它俩是一体的，不是被藏起来的")
        XCTAssertEqual(rgba(tailColor), rgba(numberColor), "末尾那个 `]` 同样该和编号一个颜色")

        let headFont = try XCTUnwrap(attribute(.font, of: "[^", in: text) as? UIFont)
        let numberFont = try XCTUnwrap(attribute(.font, of: "1]", in: text) as? UIFont)
        XCTAssertEqual(headFont.pointSize, numberFont.pointSize, "`[^` 该和编号同字号，否则看着像两段拼起来的")
        XCTAssertGreaterThan(headFont.pointSize, 1, "方括号是画出来的正经字号，不是压到约等于零")

        XCTAssertTrue(text.string.contains("[^1]"), "画出来 ≠ 替换掉：源码里那四个字符必须一个不少")
    }

    /// 有定义 → 强调色（默认跟链接同色）
    func testDefinedReferenceUsesAccentColor() throws {
        let (text, theme) = render("正文里的[^1]引用\n", definedIDs: ["1"])

        let color = try XCTUnwrap(attribute(.foregroundColor, of: "[^1]", in: text) as? UIColor)
        XCTAssertEqual(rgba(color), rgba(theme.linkColor), "有定义的引用该用强调色（默认 = 链接色）")
    }

    /// 没定义（悬空引用）→ 断链色，但字符照常显示
    func testDanglingReferenceUsesWarningColor() throws {
        let (text, theme) = render("正文里的[^1]引用\n", definedIDs: [])

        let color = try XCTUnwrap(attribute(.foregroundColor, of: "[^1]", in: text) as? UIColor)
        XCTAssertEqual(rgba(color), rgba(theme.footnote.danglingColor), "引用了不存在的 ID 该画成断链色，提示用户")
        XCTAssertTrue(text.string.contains("[^1]"), "断链也只是换个颜色，字符一个都不能少")
    }

    // MARK: 定义

    /// 行首的 `[^1]: 说明` 要被认成定义块：整段挂上 ID，开头的标记弱化显示。
    ///
    /// ### 为什么两个写法都要测（这是踩到的坑，别只留一个）
    /// cmark 会把「冒号后面那串不含空格」的定义当成 **CommonMark 的链接引用定义**吃掉 —— 它压根不是段落节点，靠「访问段落」那条路就永远认不出来，所以两种写法都要能认：
    /// - `这是脚注内容`（中间没空格）→ 被 cmark 当链接引用定义，整行是补漏补出来的字符；
    /// - `这是 脚注 内容`（带空格）→ 正常的段落节点。
    func testDefinitionBlockIsMarkedWithItsID() throws {
        let sources = ["[^1]: 这是脚注内容\n", "[^1]: 这是 脚注 内容\n"]

        for source in sources {
            let (text, _) = render(source, definedIDs: ["1"])
            let id = try XCTUnwrap(attribute(.markdownFootnoteDefinition, of: "[^1]:", in: text) as? String,
                                   "「\(source)」整段该挂着它的 ID")
            XCTAssertEqual(id, "1", "挂的 ID 要就是源码里写的那个")
        }
    }

    /// 定义块自己的开头不该再被当成引用 —— 否则点它会「跳到自己身上」
    func testDefinitionMarkerIsNotMarkedAsReference() {
        let (text, _) = render("[^1]: 这是脚注内容\n", definedIDs: ["1"])

        XCTAssertNil(attribute(.markdownFootnoteReference, of: "[^1]:", in: text),
                     "定义块开头的 `[^1]:` 是定义的一部分，不该再挂引用标记")
    }

    /// 定义块要缩进一档（悬挂缩进：第一行顶到正文位置，换行后往里缩）
    func testDefinitionBlockIsIndented() throws {
        let (text, _) = render("[^1]: 这是 脚注 内容\n", definedIDs: ["1"])

        let style = try XCTUnwrap(attribute(.paragraphStyle, of: "[^1]:", in: text) as? NSParagraphStyle)
        XCTAssertGreaterThan(style.headIndent, style.firstLineHeadIndent,
                             "定义块该是悬挂缩进：续行比第一行往里缩，才看得出这几行属于同一条脚注")
    }

    /// 正文中间的 `[^1]` 是引用，不是定义（区分全靠「是不是在行首 + 后面有没有冒号」）
    func testReferenceInBodyIsNotTreatedAsDefinition() {
        let (text, _) = render("正文里的[^1]引用\n", definedIDs: ["1"])

        XCTAssertNil(attribute(.markdownFootnoteDefinition, of: "[^1]", in: text),
                     "正文中间的引用不该被当成定义块")
    }

    // MARK: 保真度（脚注不许改变渲染串长度）

    /// 脚注是**纯属性**语法：认出来只改样式，一个字符都不许加。
    ///
    /// ### 为什么这条最要紧
    /// 系统替键盘输入记的撤销账是「按插入时的字符数」记的：用户敲 1 个字符，撤销就删 1 个。
    /// 渲染串长度只要和用户敲进去的字符数对不上，撤销就会删错位置 ——表现为「撤销一次还能用，连按几次就再也回不到原来」。所以引用 / 定义一律不许插占位字符。
    func testFootnoteDoesNotChangeRenderedLength() {
        let sources = [
            "正文里的[^1]引用\n",
            "[^1]: 这是脚注内容\n",
            "正文[^1]和[^note]两个\n\n[^1]: 第一条\n[^note]: 第二条\n",
            "[^]空标记\n",                 // 刚敲了一半、`[]` 中间还没有内容
            "正[^foo\n",                   // 没闭合的标记：认不出来就该当普通文字，不能吃掉字符
        ]

        for source in sources {
            let store = MarkdownDocumentStore()
            store.load(markdown: source, containerWidth: 600)
            XCTAssertEqual((store.renderedString as NSString).length, (source as NSString).length,
                           "「\(source)」渲染长度变了 —— 脚注只能改属性，不许加字符")
        }
    }

    /// 全选复制出来的必须正好是源文件（脚注标记照样完整复制）
    func testFootnoteSourceStaysFullySelectable() {
        let source = "正文[^1]和[^note]两个\n\n[^1]: 第一条\n[^note]: 第二条\n"
        let store = MarkdownDocumentStore()
        store.load(markdown: source, containerWidth: 600)

        let everything = NSRange(location: 0, length: store.renderedLength)
        XCTAssertEqual(store.sourceText(forRenderedRange: everything), source,
                       "全选复制必须 === 源文件，脚注标记一个字符都不能少")
    }

    // MARK: 查表

    /// 整篇里找定义：正文里的引用不算，只认行首带冒号的那个，偏移要指向定义块的开头
    func testFootnoteIndexFindsDefinitionOffset() throws {
        let source = "正文[^1]引用\n\n[^1]: 第一条\n[^2]: 第二条\n"
        let definitions = FootnoteIndex.definitions(in: source)

        XCTAssertEqual(definitions.count, 2, "两个定义都要找到（正文里那个 `[^1]` 是引用，不算）")

        let offset = try XCTUnwrap(definitions["1"], "要能查到 ID 为 1 的定义")
        let expected = (source as NSString).range(of: "[^1]:").location
        XCTAssertEqual(offset, expected, "查到的偏移该指向定义块开头的那个 `[`")
    }

    /// 缩进着写的定义也要认（嵌套在别的内容里、或者手打了缩进）
    func testFootnoteIndexRecognizesIndentedDefinition() {
        let definitions = FootnoteIndex.definitions(in: "  [^a]: 缩进过的定义\n")
        XCTAssertEqual(definitions["a"], 2, "行首允许有缩进")
    }

    /// 只是正文里顺手提了一嘴 `[^1]，不该凭空冒出一个定义
    func testFootnoteIndexIgnoresReferenceWithoutColon() {
        let source = "这是[^1]引用，不是定义\n"
        XCTAssertTrue(FootnoteIndex.definitions(in: source).isEmpty, "后面没有冒号的一律不是定义")
    }

    // MARK: 回跳（点定义 → 回正文）

    /// 回跳要找的是**正文里**的引用，定义块开头那个 `[^1]:` 不算 —— 否则会「点定义跳到定义」
    func testReferenceRangesSkipTheDefinitionMarker() {
        let source = "正文里提到[^1]一下\n\n[^1]: 这是定义\n"
        let ranges = FootnoteIndex.referenceRanges(for: "1", in: source)

        XCTAssertEqual(ranges.count, 1, "定义自己那个标记不能算引用")
        XCTAssertEqual(ranges.first?.location, (source as NSString).range(of: "[^1]").location,
                       "找到的该是正文里那个引用")
    }

    /// 同一个脚注被引用多次时，全部都要能找到（点定义回跳按「原路返回」挑其中一个，所以这里得给全）
    func testReferenceRangesFindsEveryMention() {
        let source = "开头[^1]，中间[^1]，结尾[^1]\n\n[^1]: 定义\n"
        XCTAssertEqual(FootnoteIndex.referenceRanges(for: "1", in: source).count, 3, "三处引用都要找到")
    }

    /// 一条脚注整块的范围：从 `[^1]:` 起，到下一个定义之前结束，尾巴上的空行不算
    func testDefinitionBlockRangeCoversTheWholeFootnote() throws {
        let source = "正文\n\n[^1]: 第一条\n[^2]: 第二条\n"
        let range = try XCTUnwrap(FootnoteIndex.definitionBlockRange(for: "1", in: source))

        XCTAssertEqual(range.location, (source as NSString).range(of: "[^1]:").location, "起点是定义块开头那个 `[`")
        let expectedEnd = (source as NSString).range(of: "[^2]:").location - 1     // 减 1 是那条空行
        XCTAssertEqual(NSMaxRange(range), expectedEnd, "终点是下一个定义之前（末尾的空行不算在里头）")
    }

    /// 最后一条定义的终点是文档末尾（后面没有别的定义了）
    func testLastDefinitionBlockRangeRunsToTheEnd() throws {
        let source = "正文[^1]\n\n[^1]: 只有这一条\n"
        let range = try XCTUnwrap(FootnoteIndex.definitionBlockRange(for: "1", in: source))
        XCTAssertEqual(NSMaxRange(range), (source as NSString).length - 1, "最后一条定义一直算到文档末尾（不含末尾那个换行）")
    }

    /// 定义块开头的标记要**按正文标记的样子**画（不是上标、不是断链色）：它是锚点，用户要在这儿改 ID
    func testDefinitionMarkerStaysVisible() throws {
        let (text, _) = render("[^1]: 这是脚注内容\n", definedIDs: ["1"])

        let color = try XCTUnwrap(attribute(.foregroundColor, of: "[^1]:", in: text) as? UIColor)
        XCTAssertGreaterThan(alpha(of: color), 0, "定义块开头的标记是锚点，不能像正文里那样藏起来")
    }

    // MARK: 定义被并进前一个块（cmark 吃掉链接引用定义）

    /// cmark 会把 `[^1]: 说明` 当 CommonMark 的链接引用定义吃掉，被吃掉之后它不产生节点、常被并进**前一个块**的尾巴。这种定义也必须认出来 —— 否则既没缩进、也没弱化色，⌘+ 点它还跳不回正文。
    func testDefinitionMergedIntoPreviousBlockIsStillRecognized() throws {
        let (text, _) = render("这里有个脚注[^note]。\n\n[^1]: 普通脚注。\n\n", definedIDs: ["1", "note"])

        let id = try XCTUnwrap(attribute(.markdownFootnoteDefinition, of: "[^1]:", in: text) as? String,
                               "被并进前一块的定义也要挂上 ID，否则点它跳不回正文")
        XCTAssertEqual(id, "1")
    }

    /// 定义块的正文是**正经内容**，不能整块刷成语法标记的弱化灰
    ///
    /// 被 cmark 吃掉的那段源码是靠补漏步骤补回来的，补漏默认用「语法标记色」——于是 `[^note]: 特殊脚注…` 里只有头几个字是正文色，剩下全成了浅灰，看着像被禁用。
    func testDefinitionContentUsesBodyColorNotMarkerColor() throws {
        let (text, theme) = render("[^note]: 特殊脚注，包含多行内容。\n", definedIDs: ["note"])

        let content = try XCTUnwrap(attribute(.foregroundColor, of: "特殊脚注", in: text) as? UIColor)
        XCTAssertNotEqual(rgba(content), rgba(theme.markerColor), "定义内容不能是语法标记的弱化色")

        let marker = try XCTUnwrap(attribute(.foregroundColor, of: "[^note]:", in: text) as? UIColor)
        XCTAssertEqual(rgba(marker), rgba(theme.markerColor), "开头那个标记仍然是弱化色，跟正文区分开")
    }

    /// 一条定义的范围**不能越过后面的小节** —— 两条脚注之间常常隔着好几个章节。
    ///
    /// 老算法拿「下一个定义的起点」当终点，实测一份 351 行的文件里第二条脚注一口吃掉了后面 1481 个字符、二十来个章节，跳转落地时那层高亮会铺满半个屏幕。终点只能看「还有没有缩进续行」。
    func testDefinitionBlockRangeStopsBeforeTheNextSection() throws {
        let source = "## 19. Footnote\n\n这是[^note]引用。\n\n[^note]: 特殊脚注。\n\n---\n\n## 20. Link\n\n后面还有很多内容\n\n---\n\n[^release]: 最后一条\n"
        let range = try XCTUnwrap(FootnoteIndex.definitionBlockRange(for: "note", in: source))

        let noteStart = (source as NSString).range(of: "[^note]:").location
        let separator = (source as NSString).range(of: "---").location
        XCTAssertEqual(range.location, noteStart, "起点是定义块开头那个 `[`")
        XCTAssertLessThanOrEqual(NSMaxRange(range), separator,
                                 "终点不能越过后面的分隔线 —— 老算法会一路吃到下一条定义，高亮铺满半个屏幕")
    }
}
