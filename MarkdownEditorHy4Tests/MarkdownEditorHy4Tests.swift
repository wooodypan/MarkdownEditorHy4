//
//  MarkdownEditorHy4Tests.swift
//  MarkdownEditorHy4Tests
//
//  冒烟测试：只验一件事 —— 「显示是排版效果，复制出来还是源码」
//
//  这里的每一条断言都对应方案里的一个用户体验目标：
//  1. 全选复制出来的文本 === 源文件文本（逐字符）
//  2. 选中一张图片复制出来 === `![alt](src)` 这段源码
//  3. 列表项前面的圆点退格删掉 === 源码里的 `- ` 被删掉（自动降级成段落）
//  4. 打字之后，上面这些不变量依然成立
//

import XCTest
@testable import MarkdownEditorHy4

/// app target 开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
/// 里面所有类型都默认是 @MainActor 的，所以测试类也要标 @MainActor 才能直接调用。
@MainActor
final class MarkdownEditorHy4Tests: XCTestCase {

    // MARK: - 测试用的文档

    /// 覆盖标题 / 行内语法 / 图片 / 嵌套列表 / 有序列表 / 引用 / 代码块 / 分隔线 / emoji
    private var sample: String {
        """
        # 标题一

        这是 **粗体**、*斜体*、`行内代码`、~~删除线~~ 和 [链接](https://swift.org)。

        ![示例图片](sample.png)

        ## 列表

        - 一级列表项
        - 带嵌套的项
          - 二级列表项
            - 三级列表项
        - 回到一级

        1. 有序第一项
        2. 有序第二项

        > 引用第一行
        > 引用第二行

        ```swift
        let document = Document(parsing: markdown)
        ```

        ---

        普通段落，中文和 emoji 🎉 混排。
        """
    }

    // MARK: - 小工具

    private func makeStore(_ markdown: String) -> MarkdownDocumentStore {
        let store = MarkdownDocumentStore()
        store.load(markdown: markdown, containerWidth: 600)
        return store
    }

    /// 整篇渲染范围
    private func fullRenderedRange(_ store: MarkdownDocumentStore) -> NSRange {
        NSRange(location: 0, length: store.renderedLength)
    }

    /// 两段文本第一处不同的位置，断言失败时能一眼看出问题在哪
    private func firstDifference(_ expected: String, _ actual: String) -> String {
        let expectedChars = Array(expected)
        let actualChars = Array(actual)
        for index in 0..<min(expectedChars.count, actualChars.count)
        where expectedChars[index] != actualChars[index] {
            let from = max(0, index - 20)
            let expectedSnippet = String(expectedChars[from..<min(expectedChars.count, index + 20)])
            let actualSnippet = String(actualChars[from..<min(actualChars.count, index + 20)])
            return "第 \(index) 个字符不同\n  期望: …\(expectedSnippet)…\n  实际: …\(actualSnippet)…"
        }
        return "长度不同：期望 \(expectedChars.count) 字符，实际 \(actualChars.count) 字符"
    }

    // MARK: - 测试用例

    /// 核心验收一：全选复制出来的文本必须和源码逐字符一致
    func testRoundTripKeepsSourceIntact() {
        let source = sample
        let store = makeStore(source)
        let restored = store.sourceText(forRenderedRange: fullRenderedRange(store))

        XCTAssertEqual(restored, source, firstDifference(source, restored))
    }

    /// 核心验收二：分块之后，所有块的源码首尾相接 === 整篇源码（否则块与块之间会有缝）
    func testBlocksCoverWholeSource() {
        let source = sample
        let store = makeStore(source)
        let joined = store.blocks.reduce(into: "") { $0 += $1.sourceText }

        XCTAssertEqual(joined, source, firstDifference(source, joined))
        XCTAssertFalse(store.blocks.isEmpty, "至少要切出一个块")
    }

    /// 每个块的渲染长度必须和它的映射表长度一致（映射表是后面所有换算的地基）
    func testMappingCountMatchesRenderedLength() {
        let store = makeStore(sample)
        for block in store.blocks {
            XCTAssertEqual(block.charMappings.count,
                           block.renderedLength,
                           "块「\(block.kindDescription)」的映射表长度和渲染长度对不上")
        }
    }

    /// 核心验收三：选中图片复制，拿到的应该是 `![alt](src)` 这段源码，而不是图片本身
    func testCopyImageRangeReturnsMarkdownSource() {
        let source = sample
        let store = makeStore(source)

        // 找到源码里那行图片，换算到渲染坐标，选它、再还原
        let marker = "![示例图片](sample.png)"
        guard let sourceRange = (source as NSString).range(of: marker).asValid else {
            return XCTFail("测试文档里找不到图片语法")
        }
        let renderedStart = store.renderedCaret(forSourceOffset: sourceRange.location)
        let renderedEnd = store.renderedCaret(forSourceOffset: NSMaxRange(sourceRange))
        let restored = store.sourceText(forRenderedRange: NSRange(location: renderedStart,
                                                                 length: max(0, renderedEnd - renderedStart)))

        XCTAssertEqual(restored, marker, firstDifference(marker, restored))
    }

    /// 核心验收四：列表项前面的圆点映射到源码的 `- `，退格删掉它就等于删掉源码里的标记
    func testBackspaceOnBulletDeletesSourceMarker() {
        let source = sample
        let store = makeStore(source)

        guard let markerSourceRange = (source as NSString).range(of: "- 一级列表项").asValid else {
            return XCTFail("测试文档里找不到列表项")
        }

        // 圆点在渲染文本里只占 1 个字符位，但它的映射指向源码里的 `- ` 两个字符。
        // 所以「删掉这一个字符位」应该等价于「删掉源码里的列表标记」，列表项自动降级成段落。
        let bulletRendered = store.renderedCaret(forSourceOffset: markerSourceRange.location)
        store.applyEdit(inRenderedRange: NSRange(location: bulletRendered, length: 1),
                        replacementText: "",
                        containerWidth: 600)

        XCTAssertFalse(store.sourceDocument.contains("- 一级列表项"),
                       "退格应该删掉源码里的列表标记，实际源码：\n\(store.sourceDocument)")
        XCTAssertTrue(store.sourceDocument.contains("一级列表项"), "正文必须原样留着")

        // 删完之后，「复制 === 源码」这个不变量依然要成立
        let restored = store.sourceText(forRenderedRange: fullRenderedRange(store))
        XCTAssertEqual(restored, store.sourceDocument,
                       firstDifference(store.sourceDocument, restored))
    }

    /// 核心验收五：打字（增量编辑）之后，「复制 === 源码」这个不变量依然成立
    func testIncrementalTypingKeepsRoundTrip() {
        let source = sample
        let store = makeStore(source)

        // 在文末敲几个字：模拟用户在最后一个字符后面输入
        let insertAtRendered = store.renderedLength
        let outcome = store.applyEdit(inRenderedRange: NSRange(location: insertAtRendered, length: 0),
                                      replacementText: "新输入的一段话",
                                      containerWidth: 600)

        // 1) 先验证 store 内部的源码已经被更新
        XCTAssertTrue(store.sourceDocument.hasSuffix("新输入的一段话"),
                      "源码没有跟上这次输入，实际结尾是：\(store.sourceDocument.suffix(20))")

        // 2) 再验证新的渲染结果依然能还原成新源码
        let restored = store.sourceText(forRenderedRange: fullRenderedRange(store))
        XCTAssertEqual(restored, store.sourceDocument,
                       firstDifference(store.sourceDocument, restored))

        // 3) 顺带确认这次编辑只产生了很小的替换范围（增量生效，没有整篇重排）
        XCTAssertGreaterThan(outcome.newContent.length, 0, "增量编辑应该给出要替换进去的新内容")
        XCTAssertLessThanOrEqual(outcome.replacedRange.length, store.renderedLength,
                                 "替换范围不该超过整篇长度")
    }

    /// 中文 + emoji 混排时，UTF-8 列号换算成 UTF-16 偏移不能错位
    func testChineseAndEmojiOffsets() {
        let source = """
        前面一段中文，然后一个 emoji 🎉，再来一段中文。

        - 列表项里也有 emoji 🚀
        - 普通项

        > 引用里的 emoji ✨

        结尾。
        """
        let store = makeStore(source)
        let restored = store.sourceText(forRenderedRange: fullRenderedRange(store))

        XCTAssertEqual(restored, source, firstDifference(source, restored))
    }

    /// 核心验收六（回归）：光标停在图片源码 `![示例图片](sample.png)` 中间打字，
    /// 字符必须插在光标处，不能跳到右括号后面。
    ///
    /// ### 这个 bug 是怎么来的（别再改回去）
    /// 之前把「源码提示」那行文字标成了 decoration（不占源码位置）。
    /// 于是光标落在 `![alt](url)` 中间时 `sourceCaret` 找不到对应源码，
    /// 会一路往前找到图片那个 attachment，返回「整段源码的结束位置」——
    /// 新字符就全被插到右括号后面了。现在提示文字用的是真实映射，逐字符对得上。
    func testTypingInsideImageSourceStaysInPlace() {
        let store = makeStore(sample)
        let marker = "![示例图片](sample.png)"
        guard let sourceRange = (sample as NSString).range(of: marker).asValid else {
            return XCTFail("测试文档里找不到图片语法")
        }

        // 光标放到「示例图片」和「](sample.png)」之间
        let insertAtSource = sourceRange.location + "![示例图片".utf16.count
        let caret = store.renderedCaret(forSourceOffset: insertAtSource)
        let outcome = store.applyEdit(inRenderedRange: NSRange(location: caret, length: 0),
                                      replacementText: "X",
                                      containerWidth: 600)

        // 1) 字符必须插在光标处，而不是整段源码的末尾
        XCTAssertTrue(store.sourceDocument.contains("![示例图片X](sample.png)"),
                      "字符应该插在光标处，实际源码：\n\(store.sourceDocument)")

        // 2) 光标也要停在刚输入的字符后面（换算回源码应该是插入点的下一个位置）
        let caretSource = store.sourceCaret(forRenderedOffset: outcome.caretRenderedOffset)
        XCTAssertEqual(caretSource, insertAtSource + 1,
                       "光标应该停在刚输入的字符后面，实际落在源码 \(caretSource)")

        // 3) 「复制 === 源码」这个不变量依然要成立
        let restored = store.sourceText(forRenderedRange: fullRenderedRange(store))
        XCTAssertEqual(restored, store.sourceDocument,
                       firstDifference(store.sourceDocument, restored))
    }

    // MARK: - 折叠 / 展开

    /// 折叠三角**只挂在标题上**，而且只挂在「下面真的有内容」的标题上。
    ///
    /// ### 这条守的是本次重写的核心规则
    /// 折叠从「多行块各自折叠」改成了「按标题层级折叠」：
    /// - 正文块（哪怕是多行的列表、代码块）不再有三角；
    /// - 标题下面什么都没有（`# A` 紧跟着 `# B`）时也不给三角 —— 折了也看不出变化。
    func testOnlyHeadingsWithContentHaveFoldDisclosure() {
        let source = """
        # 一级标题

        一级的正文。

        ## 二级标题

        ### 三级标题

        三级下面的正文。

        ## 另一个二级
        """
        let store = makeStore(source)

        var headingsWithTriangle = 0
        for block in store.blocks {
            let anchor = foldAnchor(in: block)

            guard let title = block.headingTitle else {
                XCTAssertNil(anchor, "非标题块不该有折叠三角：\(block.kindDescription)")
                continue
            }

            // 「## 另一个二级」在文档末尾，下面一个块都没有 → 没有三角
            let expectTriangle = title != "另一个二级"
            XCTAssertEqual(anchor != nil, expectTriangle,
                           "标题「\(title)」的三角情况不对")
            if let anchor {
                XCTAssertFalse(anchor.isCollapsed, "初始状态应该是展开的")
                XCTAssertEqual(anchor.blockID, block.id,
                               "锚点必须记住自己属于哪个块，否则点了不知道折叠谁")
                headingsWithTriangle += 1
            }
        }
        XCTAssertEqual(headingsWithTriangle, 3, "三个有内容的标题应该有三角")
    }

    /// 取一个块里的折叠锚点（打在第一个非空白字符上的那个标记）
    private func foldAnchor(in block: MarkdownBlock) -> FoldAnchorInfo? {
        (0..<block.renderedLength)
            .compactMap { block.renderedContent.attribute(.markdownFoldAnchor,
                                                          at: $0,
                                                          effectiveRange: nil) }
            .compactMap { $0 as? FoldAnchorInfo }
            .first
    }

    /// 折叠三角**不能占字符位**（用户报的就是这个：块首插一个 attachment 画三角，
    /// 第一行被推歪，第二行起还按原缩进排，多行左边缘就对不齐了）。
    ///
    /// 现在三角画在正文左边的装订线里，文本流里一个多余字符都没有 ——
    /// 这条测试守的是「打锚点这个动作不改变文本结构」。
    /// 现在三角画在正文左边的装订线里，文本流里一个多余字符都没有 ——
    /// 这条测试守的是「打锚点这个动作不改变文本结构」。
    func testFoldDisclosureDoesNotOccupyCharacterPosition() {
        let store = makeStore(sample)
        let renderer = MarkupToAttributedRenderer(theme: .default, containerWidth: 600)

        var checked = 0
        for block in store.blocks {
            guard foldAnchor(in: block) != nil else { continue }

            // 不加锚点地渲染同一段源码，长度必须和加过锚点的完全一样
            let (plain, _) = renderer.render(blockSource: block.sourceText)

            XCTAssertEqual(block.renderedContent.length, plain.length,
                           "块「\(block.kindDescription)」打锚点之后多出了字符 —— 三角会占字符位，多行就对不齐了")
            XCTAssertEqual(block.renderedContent.string, plain.string,
                           "块「\(block.kindDescription)」打锚点之后正文被改动了")

            // 展开状态的块里不该出现折叠占位符
            for index in 0..<block.renderedLength {
                if let attachment = block.renderedContent.attribute(.attachment,
                                                                    at: index,
                                                                    effectiveRange: nil) {
                    XCTAssertFalse(attachment is CollapsedBlockAttachment,
                                   "展开状态的块里不该有折叠占位符")
                }
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "示例文档里应该有带三角的标题")
    }

    // MARK: - 折叠一整节（折叠 H2 = 收起它下面直到下一个同级/更高级标题的全部内容）

    /// 一份「H1 → H2 → H3 → H2」的样例文档，专门用来验证折叠范围
    private var sectionSample: String {
        """
        # 一级

        一级的正文。

        ## 二级 A

        二级 A 的正文。

        ### 三级 A1

        三级 A1 的正文。

        ## 二级 B

        二级 B 的正文。
        """
    }

    /// 找到标题文字等于 `title` 的那个块的下标
    private func headingIndex(_ title: String, in store: MarkdownDocumentStore) -> Int? {
        store.blocks.firstIndex { $0.headingTitle == title }
    }

    /// 折叠 H2 后，它下面的正文和 H3 **整节**都要消失；下一个同级标题不受影响
    func testCollapsingH2HidesEverythingUntilNextSameLevel() {
        let store = makeStore(sectionSample)
        guard let index = headingIndex("二级 A", in: store) else {
            return XCTFail("样例里找不到「二级 A」")
        }

        XCTAssertNotNil(store.toggleCollapse(blockAt: index), "有内容的标题应该能折叠")

        let rendered = store.renderedString
        XCTAssertTrue(rendered.contains("## 二级 A"), "标题自己要留着，用户才知道收起的是哪一节")
        XCTAssertFalse(rendered.contains("二级 A 的正文"), "这一节的正文应该被收起来")
        XCTAssertFalse(rendered.contains("### 三级 A1"), "折叠 H2 要连 H3 一起收起来")
        XCTAssertFalse(rendered.contains("三级 A1 的正文"), "H3 下面的正文也要一起收起来")

        XCTAssertTrue(rendered.contains("# 一级"), "更外层的标题不受影响")
        XCTAssertTrue(rendered.contains("一级的正文"), "更外层的正文不受影响")
        XCTAssertTrue(rendered.contains("## 二级 B"), "下一个同级标题要露出来")
        XCTAssertTrue(rendered.contains("二级 B 的正文"), "下一节的内容不受影响")
    }

    /// 折叠之后整节只剩**一个**「⋯」占位符（1 个字符位），并且它带着可点击的标记
    func testCollapsedSectionShowsExactlyOnePlaceholder() {
        let store = makeStore(sectionSample)
        guard let index = headingIndex("二级 A", in: store) else {
            return XCTFail("样例里找不到「二级 A」")
        }
        store.toggleCollapse(blockAt: index)

        let content = store.blocks[index].renderedContent
        XCTAssertTrue(content.string.hasPrefix("## 二级 A"),
                      "折叠后显示的是「标题 + ⋯」，实际是：\(content.string)")

        var placeholders = 0
        content.enumerateAttribute(.markdownCollapsedPlaceholder,
                                   in: NSRange(location: 0, length: content.length),
                                   options: []) { value, range, _ in
            guard value is CollapsedSectionInfo else { return }
            placeholders += 1
            XCTAssertEqual(range.length, 1, "「⋯」只占 1 个字符位")
        }
        XCTAssertEqual(placeholders, 1, "一节折叠后只该有一个「⋯」")
        XCTAssertEqual(content.string.filter { $0 == "\u{FFFC}" }.count, 1,
                       "整节内容应该被一个 attachment 字符位代替")

        // 被折叠起来的那些块：还在 blocks 里，但渲染内容被清空了
        let hidden = store.blocks.filter { $0.isHidden }
        XCTAssertFalse(hidden.isEmpty, "被折叠的块应该标成 hidden")
        XCTAssertTrue(hidden.allSatisfy { $0.renderedContent.length == 0 },
                      "隐藏的块不该再有渲染内容")
    }

    /// 折叠之后块尾要留着换行，否则下一节会直接贴在「⋯」后面（一行挤两块）
    func testCollapsedHeadingEndsWithLineBreak() {
        let store = makeStore(sectionSample)
        guard let index = headingIndex("二级 A", in: store) else {
            return XCTFail("样例里找不到「二级 A」")
        }
        store.toggleCollapse(blockAt: index)

        let rendered = store.blocks[index].renderedContent.string as NSString
        XCTAssertTrue(rendered.hasSuffix("\n"),
                      "折叠块的渲染内容必须以换行结尾，否则下一节会接在后面，实际是：\(rendered)")
    }

    /// 折叠之后「全选复制 === 源码」必须依然成立：折叠只是视图状态，源码一个字没少
    func testCollapsedSectionStillCopiesFullSource() {
        let source = sectionSample
        let store = makeStore(source)
        guard let index = headingIndex("二级 A", in: store) else {
            return XCTFail("样例里找不到「二级 A」")
        }

        let lengthBefore = store.renderedLength
        XCTAssertNotNil(store.toggleCollapse(blockAt: index), "折叠应该成功")
        XCTAssertTrue(store.blocks[index].isCollapsed, "折叠状态没写回块")
        XCTAssertLessThan(store.renderedLength, lengthBefore, "折叠后渲染长度应该变短")

        // 1) 源码一个字都不能变
        XCTAssertEqual(store.sourceDocument, source, "折叠不能改动源码")

        // 2) 折叠着全选复制，拿到的依然是完整源码（靠「⋯」那一个字符位吐出整节内容）
        let restored = store.sourceText(forRenderedRange: fullRenderedRange(store))
        XCTAssertEqual(restored, source, firstDifference(source, restored))

        // 3) 每个块的映射表长度还是要和渲染长度对得上
        for block in store.blocks {
            XCTAssertEqual(block.charMappings.count, block.renderedLength,
                           "块「\(block.kindDescription)」的映射表长度和渲染长度对不上")
        }
    }

    /// 折叠 → 展开，应该回到原样（渲染长度、源码、复制结果都不变）
    func testCollapseExpandRoundTrip() {
        let source = sectionSample
        let store = makeStore(source)
        let lengthBefore = store.renderedLength
        guard let index = headingIndex("二级 A", in: store) else {
            return XCTFail("样例里找不到「二级 A」")
        }

        store.toggleCollapse(blockAt: index)
        store.toggleCollapse(blockAt: index)

        XCTAssertFalse(store.blocks[index].isCollapsed, "折回来应该是展开状态")
        XCTAssertEqual(store.renderedLength, lengthBefore, "折叠再展开应该回到原来的长度")
        XCTAssertEqual(store.sourceDocument, source, "来回切一次不能改动源码")

        let restored = store.sourceText(forRenderedRange: fullRenderedRange(store))
        XCTAssertEqual(restored, source, firstDifference(source, restored))
    }

    /// **展开 H2 要恢复它下面原来的折叠状态**：之前折着的 H3，展开后仍然是折着的
    func testExpandingRestoresNestedCollapseState() {
        let store = makeStore(sectionSample)
        guard let h2 = headingIndex("二级 A", in: store),
              let h3 = headingIndex("三级 A1", in: store) else {
            return XCTFail("样例里找不到对应的标题")
        }

        // 先折 H3，再折 H2（H3 整块被 H2 收进去）
        store.toggleCollapse(blockAt: h3)
        XCTAssertTrue(store.blocks[h3].isCollapsed)
        store.toggleCollapse(blockAt: h2)
        XCTAssertFalse(store.renderedString.contains("### 三级 A1"), "H2 折起来后 H3 也该看不见")

        // 展开 H2：H3 要恢复成**它自己折着**的样子
        store.toggleCollapse(blockAt: h2)
        XCTAssertTrue(store.blocks[h3].isCollapsed, "H3 的折叠状态不该被 H2 的展开冲掉")

        let rendered = store.renderedString
        XCTAssertTrue(rendered.contains("### 三级 A1"), "展开 H2 后 H3 的标题要露出来")
        XCTAssertFalse(rendered.contains("三级 A1 的正文"), "H3 自己折着，它的正文仍该收着")
        XCTAssertTrue(store.blocks[h3].renderedIsCollapsed, "H3 应该渲染成「标题 + ⋯」")

        let restored = store.sourceText(forRenderedRange: fullRenderedRange(store))
        XCTAssertEqual(restored, store.sourceDocument,
                       firstDifference(store.sourceDocument, restored))
    }

    /// 下面什么都没有的标题：不给三角，也折不动（返回一个空操作而不是崩）
    func testHeadingWithoutContentCannotCollapse() {
        let store = makeStore("# A\n# B\n")
        XCTAssertNil(store.toggleCollapse(blockAt: 0), "空节不该能折叠")

        for block in store.blocks {
            XCTAssertNil(foldAnchor(in: block), "空节标题不该有折叠三角")
        }
    }

    /// 在折叠标题的**标题行**里编辑，折叠状态不能丢
    /// （否则「折叠一节 → 改个标题 → 它自己展开了」很烦人）
    func testCollapseStateSurvivesEditingInsideHeading() {
        let store = makeStore("# 标题\n\n正文。\n")
        XCTAssertNotNil(store.toggleCollapse(blockAt: 0), "标题应该能折叠")

        // 在标题文字末尾插一个字（「# 标题」4 个字符之后）
        let caret = 4
        store.applyEdit(inRenderedRange: NSRange(location: caret, length: 0),
                        replacementText: "X",
                        containerWidth: 600)

        XCTAssertTrue(store.blocks[0].isCollapsed,
                      "改标题不应该把折叠状态弄丢，实际状态：\(store.blocks.map(\.isCollapsed))")
        XCTAssertTrue(store.sourceDocument.hasPrefix("# 标题X"),
                      "字符应该插在标题里，实际源码：\(store.sourceDocument)")
        XCTAssertFalse(store.renderedString.contains("正文"), "折叠着的节不该露出正文")

        // 顺便确认这个不变量依然成立
        let restored = store.sourceText(forRenderedRange: fullRenderedRange(store))
        XCTAssertEqual(restored, store.sourceDocument,
                       firstDifference(store.sourceDocument, restored))
    }

    /// 每个「下面有内容」的标题左边都要真的画出一个三角（不占字符位、浮在装订线里）
    func testFoldTrianglesAppearOnScreen() {
        let source = """
        # 一级

        一级的正文。

        ## 二级 A

        二级 A 的正文。

        ## 空的二级
        """
        let textView = makeEditor(source)
        textView.layoutIfNeeded()

        let triangles = allSubviews(of: textView).compactMap { $0 as? FoldDisclosureButton }
        XCTAssertEqual(triangles.count, 2, "两个有内容的标题该各有一个三角，末尾那个空标题不该有")

        // 三角必须落在正文左边的装订线里（不能压到正文上）
        for triangle in triangles {
            XCTAssertLessThan(triangle.frame.maxX, textView.textContainerInset.left + 1,
                              "三角应该整个在装订线里，实际 frame=\(triangle.frame)")
        }

        // 折掉「二级 A」之后：它自己的三角变成 ▶（表示「点开」），另一个不受影响
        guard let index = textView.documentStore.blocks.firstIndex(where: { $0.headingTitle == "二级 A" }) else {
            return XCTFail("找不到「二级 A」")
        }
        textView.toggleCollapse(blockID: textView.documentStore.blocks[index].id)
        textView.layoutIfNeeded()

        let after = allSubviews(of: textView).compactMap { $0 as? FoldDisclosureButton }
        XCTAssertEqual(after.count, 2)
        let collapsed = after.filter { $0.accessibilityValue == "已折叠" }
        XCTAssertEqual(collapsed.count, 1, "折叠之后应该只有一个三角变成 ▶")
    }

    /// 折叠后文本流里那个座位**什么也不画**。
    ///
    /// 三个点改由浮层上的按钮画：两边各画一半的话是两份图形各自定位，字号或行高一变就有半个点的错位。
    /// 但座位**必须还在**（占 1 个字符位、宽度非零）—— 「全选复制 === 源文件」的映射全靠它。
    ///
    /// ⚠️ 「不画」在实现上是**给一张全透明的图**，不是不给图：附件在 TextKit 眼里没内容时， 它会自己补画一张「缺省白纸」图标到屏幕上（用户看到那张纸报过 bug）。
    func testCollapsedSeatDrawsNothingInTextFlow() {
        let store = makeStore(sectionSample)
        guard let index = headingIndex("二级 A", in: store) else {
            return XCTFail("样例里找不到「二级 A」")
        }
        store.toggleCollapse(blockAt: index)

        let content = store.blocks[index].renderedContent
        var seats: [NSTextAttachment] = []
        for offset in 0..<content.length {
            if let attachment = content.attribute(.attachment, at: offset, effectiveRange: nil) as? NSTextAttachment {
                seats.append(attachment)
            }
        }

        XCTAssertEqual(seats.count, 1, "折叠后整节只该剩一个座位")
        XCTAssertTrue(seats.first is CollapsedBlockAttachment, "那一个应该是折叠占位符")
        XCTAssertGreaterThan(seats.first?.bounds.width ?? 0, 0,
                             "座位仍要占一块宽度，按钮才正好盖在这块空档上")

        // ⚠️ 座位必须带一张图，而且那张图必须**全透明**，两头都不能偏：
        // 留 `image = nil` → TextKit 认为这个附件没内容，自己补画缺省图标（右上角卷起的白纸），屏幕上凭空多一张纸；
        // 给一张画了东西的图 → 那个字符位上真的会出现东西，盖住旁边的字
        guard let seat = seats.first as? CollapsedBlockAttachment, let seatImage = seat.image else {
            return XCTFail("座位该带一张图 —— 留 `image = nil` 的话 TextKit 会自己补画一张「缺省白纸」图标")
        }
        XCTAssertEqual(seatImage.size.width, seat.bounds.width, accuracy: 0.5,
                       "图要和占位一样宽，TextKit 是按图的尺寸决定这个字符位占多大的")
        XCTAssertEqual(maxAlpha(of: seatImage), 0,
                       "座位那张图必须全透明 —— 画面上那个「⋯」是浮层按钮画的")
    }

    /// 折叠后的「⋯」是一个**固定高度的圆角矩形按钮**（三个点由它自己画）
    func testCollapsedMarkerIsFixedSizeRoundedButton() {
        let textView = makeEditor("# 标题\n\n正文。\n")
        guard let index = textView.documentStore.blocks.firstIndex(where: { $0.headingLevel != nil }) else {
            return XCTFail("样例里找不到标题")
        }
        textView.toggleCollapse(blockID: textView.documentStore.blocks[index].id)
        textView.layoutIfNeeded()

        let theme = textView.renderer.theme
        guard let button = findSubview(in: textView, where: { $0 is CollapsedSectionButton }) as? CollapsedSectionButton else {
            return XCTFail("折叠后的「⋯」应该有一个按钮")
        }
        XCTAssertEqual(button.title(for: .normal), "⋯", "三个点该由按钮自己画")
        XCTAssertEqual(button.frame.height, theme.collapsedButtonHeight, accuracy: 0.5,
                       "高度是固定的，不该跟着行高走")
        XCTAssertEqual(button.frame.width, theme.collapsedPlaceholderWidth, accuracy: 0.5,
                       "宽度要正好盖住文本流给座位留的那块空档")
        XCTAssertGreaterThan(button.layer.cornerRadius, 0, "得是圆角的")
        XCTAssertLessThan(button.layer.cornerRadius, button.frame.height / 2,
                          "圆角半径必须小于高度的一半，否则两端会变成半圆（那是胶囊，不是圆角矩形）")
        XCTAssertGreaterThan(button.layer.borderWidth, 0, "得有描边，不然「⋯」看着还是三个孤零零的点")
    }

    /// ⚠️ 按钮的热区要比画出来的框大一圈，但**不能靠放大 frame** —— frame 就是画出来的那个框
    func testCollapsedButtonHitAreaIsBiggerThanItsBox() {
        let textView = makeEditor("# 标题\n\n正文。\n")
        guard let index = textView.documentStore.blocks.firstIndex(where: { $0.headingLevel != nil }) else {
            return XCTFail("样例里找不到标题")
        }
        textView.toggleCollapse(blockID: textView.documentStore.blocks[index].id)
        textView.layoutIfNeeded()

        guard let button = findSubview(in: textView, where: { $0 is CollapsedSectionButton }) as? CollapsedSectionButton else {
            return XCTFail("折叠后的「⋯」应该有一个按钮")
        }

        // 框正上方 6 点：已经出了框，但框只有 20 点高，按着框点太考验准头
        let above = CGPoint(x: button.bounds.midX, y: -6)
        XCTAssertFalse(button.bounds.contains(above), "这个点该确实在框外面（不然这条测试就没意义）")
        XCTAssertTrue(button.point(inside: above, with: nil), "框外面一圈也该点得中")

        // 左边只撑一点点：座位紧贴在标题文字最后面，撑多了会把「点最后一个字放光标」也抢走
        XCTAssertFalse(button.point(inside: CGPoint(x: -8, y: button.bounds.midY), with: nil),
                       "左边不该往外撑到 8 点")

        // 父层也要认这圈撑出来的热区：它以前先按 `frame.contains` 过滤，会把撑出来的部分又切掉
        guard let layer = button.superview else { return XCTFail("按钮该挂在折叠控件层上") }
        let pointInLayer = layer.convert(above, from: button)
        XCTAssertTrue(layer.hitTest(pointInLayer, with: nil) === button,
                      "父层 hitTest 必须把框外面那圈也判给按钮，否则看着点在按钮上却没反应")
    }

    /// 递归找符合条件的子视图（测试里用来挖 overlay 上的控件）
    private func findSubview(in root: UIView,
                             where matches: (UIView) -> Bool) -> UIView? {
        if matches(root) { return root }
        for subview in root.subviews {
            if let found = findSubview(in: subview, where: matches) { return found }
        }
        return nil
    }

    /// 把视图树拍平（数 overlay 上的控件时用）
    private func allSubviews(of root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { allSubviews(of: $0) }
    }

    /// 读一张图里所有像素的最大不透明度 —— 全透明的图返回 0。
    ///
    /// 用来验证「座位真的一点东西都没画」：`image == nil` 不算数（那样 TextKit 会补画一张缺省白纸图标）， 得看那张图本身是不是空的。CGImage 的字节序 / 每像素字节数各平台不一样， 所以先把它画进一张格式已知的位图再按 RGBA 读第 4 个分量
    private func maxAlpha(of image: UIImage) -> UInt8 {
        guard let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        guard let context = CGContext(data: &pixels,
                                      width: cgImage.width,
                                      height: cgImage.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: cgImage.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return 0
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        var maximum: UInt8 = 0
        for index in stride(from: 3, to: pixels.count, by: 4) {
            maximum = max(maximum, pixels[index])
        }
        return maximum
    }

    // MARK: - 按回车

    /// 按一次回车，编辑器里只能多一行。
    ///
    /// ### 这个 bug 长什么样
    /// 在段落中间（或引用块里）按回车，源码里产生的是**软换行**（SoftBreak）。
    /// cmark 不给软换行标 `range`，renderer 的兜底分支自己输出了一个 `\n`，
    /// 而补漏步骤（`reconciled`）不知道这个源码字符已经被消费，又把源码里那个
    /// `\n` 补了一遍 —— 于是**一次回车换来两个换行**：屏幕上换了 2 行，
    /// 复制到别处却只有 1 行（因为多出来的那个是装饰字符，复制时被跳过）。
    ///
    /// ### 断言为什么写成「差值不变」
    /// 渲染文本本来就比源码多几个**装饰换行**（图片单独占一行等），这个差值是恒定的。
    /// 按一次回车，源码 +1 行，渲染也应该只 +1 行 —— 也就是差值必须保持不变。
    func testEnterInsertsExactlyOneLineBreak() {
        // 覆盖：标题末尾 / 段落中间（软换行）/ 段落末尾 / 引用块里（软换行）/ 文档末尾
        let spots = ["# 标题一", "**粗体**", "https://swift.org)。", "> 引用第一行", "混排。"]
        var checked = 0

        for spot in spots {
            let textView = makeEditor(sample)
            guard let sourceRange = textView.documentStore.sourceDocument.range(of: spot) else {
                return XCTFail("示例文档里找不到定位用的「\(spot)」")
            }
            let target = textView.documentStore.sourceDocument.distance(from: textView.documentStore.sourceDocument.startIndex,
                                                                        to: sourceRange.upperBound)

            let before = lineBreakBalance(of: textView)
            textView.selectedRange = NSRange(location: textView.documentStore.renderedCaret(forSourceOffset: target),
                                             length: 0)
            textView.insertText("\n")
            let after = lineBreakBalance(of: textView)

            XCTAssertEqual(after.source, before.source + 1,
                           "在「\(spot)」后按回车，源码应该只多 1 个换行，实际 \(before.source) → \(after.source)")
            XCTAssertEqual(after.rendered, before.rendered + 1,
                           "在「\(spot)」后按回车，编辑器里应该只多 1 行，实际 \(before.rendered) → \(after.rendered)")
            XCTAssertEqual(after.gap, before.gap,
                           "在「\(spot)」后按回车，渲染与源码的换行差不应该变（说明有装饰换行被重复输出了）")

            // 光标必须停在新换行的后面，否则再敲一个字就插到错误位置了
            let caretSource = textView.documentStore.sourceCaret(forRenderedOffset: textView.selectedRange.location)
            XCTAssertEqual(caretSource, target + 1,
                           "在「\(spot)」后按回车，光标应该落在新换行的后面")
            checked += 1
        }
        XCTAssertEqual(checked, spots.count)
    }

    /// 渲染文本比源码多出来的换行数（装饰换行的数量，应当是恒定的）
    private func lineBreakBalance(of textView: MarkdownTextView) -> (source: Int, rendered: Int, gap: Int) {
        let source = textView.documentStore.sourceDocument.filter { $0 == "\n" }.count
        let rendered = (textView.text ?? "").filter { $0 == "\n" }.count
        return (source, rendered, rendered - source)
    }

    /// 造一个挂在窗口上的编辑器（需要真实布局才能跑完整条编辑管线）
    private func makeEditor(_ markdown: String) -> MarkdownTextView {
        let textView = MarkdownTextView(markdown: markdown)
        textView.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        textView.layoutIfNeeded()
        return textView
    }

    // MARK: - 文件关联（Finder 右键「打开方式」）

    /// Info.plist 里的声明被误删的话，Finder 右键 .md 文件的「打开方式」里就找不到本 App
    func testAppDeclaresMarkdownDocumentType() throws {
        let info = try XCTUnwrap(Bundle(for: MarkdownDocumentOpener.self).infoDictionary)

        let documentTypes = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let handled = documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        XCTAssertTrue(handled.contains("net.daringfireball.markdown"),
                      "CFBundleDocumentTypes 必须声明 net.daringfireball.markdown，否则右键菜单里没有本 App")

        let imported = try XCTUnwrap(info["UTImportedTypeDeclarations"] as? [[String: Any]])
        let extensions = imported.compactMap { entry -> [String]? in
            guard entry["UTTypeIdentifier"] as? String == "net.daringfireball.markdown" else { return nil }
            let tags = entry["UTTypeTagSpecification"] as? [String: Any]
            return tags?["public.filename-extension"] as? [String]
        }.flatMap { $0 }
        XCTAssertTrue(extensions.contains("md"), "必须把 md 扩展名绑到 markdown UTI 上，否则系统认不出 .md")
    }

    

    /// 空文档和只有空行的文档不能崩，也不能凭空多出字符
    func testEmptyAndBlankDocuments() {
        for source in ["", "\n", "\n\n\n", "   "] {
            let store = makeStore(source)
            let restored = store.sourceText(forRenderedRange: fullRenderedRange(store))
            XCTAssertEqual(restored, source, firstDifference(source, restored))
        }
    }

    // MARK: - 表格（上方自绘表格图 + 下方弱化源码）

    /// 一个带三种对齐方式的表格
    private var tableSample: String {
        """
        | 姓名 | 年龄 | 城市 |
        | :--- | :--: | ---: |
        | 张三 | 18 | 上海 |
        | 李四 | 20 | 武汉 |
        """
    }

    /// 表格图是「额外挂上去的视觉元素」，全选复制出来必须还是源码，一个字符都不能多
    func testTableRoundTripKeepsSource() {
        let sources = [
            tableSample,
            "# 标题\n\n" + tableSample + "\n\n正文段落\n",
            // 列数不齐（GFM 允许数据行比表头短）
            "| a | b |\n| --- | --- |\n| 1 |\n",
            // 单元格是空的
            "|  |  |\n| --- | --- |\n|  |  |\n",
        ]
        for source in sources {
            let store = makeStore(source)
            let restored = store.sourceText(forRenderedRange: fullRenderedRange(store))
            XCTAssertEqual(restored, source, firstDifference(source, restored))
        }
    }

    /// 表格下面的源码要弱化显示（浅灰等宽）—— 用户要的就是「源码压成浅灰」
    func testTableSourceIsDimmed() {
        let store = makeStore(tableSample)
        let block = store.blocks[0]
        let dimmedColor = MarkdownTheme.default.table.sourceTextColor

        var checked = 0
        for (offset, mapping) in block.charMappings.enumerated() where !mapping.isAttachmentView {
            guard let color = block.renderedContent.attribute(.foregroundColor,
                                                             at: offset,
                                                             effectiveRange: nil) as? UIColor else {
                XCTFail("第 \(offset) 个字符没有前景色")
                continue
            }
            XCTAssertEqual(color, dimmedColor, "第 \(offset) 个字符不是弱化的浅灰色")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 10, "应该检查到一批源码字符，实际只检查了 \(checked) 个")
    }

    /// 表格图必须排在源码前面，尺寸撑满容器、高度按内容算，并且真的画出了图片
    func testTableAttachmentSitsAboveSource() throws {
        let store = makeStore(tableSample)
        let content = store.blocks[0].renderedContent

        var attachmentRange: NSRange?
        content.enumerateAttribute(.attachment,
                                   in: NSRange(location: 0, length: content.length),
                                   options: []) { value, range, stop in
            if value is MarkdownTableAttachment {
                attachmentRange = range
                stop.pointee = true
            }
        }

        let range = try XCTUnwrap(attachmentRange, "表格块里应该有一个表格 attachment")
        XCTAssertEqual(range.location, 0, "表格图应该排在源码前面")
        XCTAssertEqual(range.length, 1, "attachment 在文本流里只占 1 个字符位")

        let attachment = try XCTUnwrap(content.attribute(.attachment, at: range.location,
                                                         effectiveRange: nil) as? MarkdownTableAttachment)
        // 数据解析：表头 / 数据行 / 三种对齐
        XCTAssertEqual(attachment.data.header, ["姓名", "年龄", "城市"])
        XCTAssertEqual(attachment.data.rows.count, 2)
        XCTAssertEqual(attachment.data.alignment(column: 0), .left)
        XCTAssertEqual(attachment.data.alignment(column: 1), .center)
        XCTAssertEqual(attachment.data.alignment(column: 2), .right)

        // 尺寸：宽度 = 三列按内容算出来的宽度之和（**不**撑满容器 600-16=584），高度自适应
        XCTAssertLessThan(attachment.bounds.width, 584, "表格不该被拉到跟容器一样宽")
        XCTAssertGreaterThan(attachment.bounds.height, 60, "三行表格的高度不该只有这么点")
        XCTAssertNotNil(attachment.image, "表格要画成图片交给 TextKit")
        XCTAssertEqual(attachment.image?.size.width ?? 0, attachment.bounds.width, accuracy: 1)
    }

    /// 列宽必须受 `min/maxColumnWidth` 限制：短内容不被拉宽、长内容不被撑爆。
    ///
    /// ### 防的是什么回归
    /// `makeLayout` 以前会把夹过 min/max 的列宽再整体缩放撑满容器，
    /// 结果「列宽限制」形同虚设 —— 三列小表格在宽屏上跟窗口一样宽。
    func testTableColumnWidthsAreClamped() throws {
        // 容器给得很宽（模拟 Mac 全屏），三列内容都很短
        let store = MarkdownDocumentStore()
        store.load(markdown: "| Name | Age | City |\n| --- | ---: | --- |\n| Alice | 20 | Tokyo |\n",
                   containerWidth: 1400)
        let content = store.blocks[0].renderedContent
        let attachment = try XCTUnwrap(firstTableAttachment(in: content))

        let style = MarkdownTheme.default.table
        let layout = MarkdownTableView.makeLayout(data: attachment.data,
                                                  style: style,
                                                  bodyFont: MarkdownTheme.default.bodyFont,
                                                  headerFont: MarkdownTheme.default.bodyFont.adding(.traitBold),
                                                  availableWidth: 1400)

        XCTAssertEqual(layout.columnWidths.count, 3)
        for width in layout.columnWidths {
            XCTAssertGreaterThanOrEqual(width, style.minColumnWidth - 0.5, "列宽不该窄过最小值")
            XCTAssertLessThanOrEqual(width, style.maxColumnWidth + 0.5, "列宽不该宽过最大值")
        }
        // 短内容：每列都该贴着最小值附近（内容比最小值还窄的按最小值算）
        XCTAssertLessThan(layout.totalWidth, 300, "三列短表格的总宽不该被拉到几百点以外")
        XCTAssertEqual(attachment.bounds.width, layout.totalWidth, accuracy: 1)
        XCTAssertLessThan(attachment.bounds.width, 400, "三列短表格在 1400 宽的容器里依然是窄的")
    }

    /// 某一列内容特别长时，列宽封顶在 `maxColumnWidth`，总宽仍然受控
    func testTableVeryLongCellIsCapped() throws {
        let longText = String(repeating: "很长的单元格内容", count: 30)
        let store = MarkdownDocumentStore()
        store.load(markdown: "| 短 | \(longText) |\n| --- | --- |\n| a | b |\n",
                   containerWidth: 1400)
        let content = store.blocks[0].renderedContent
        let attachment = try XCTUnwrap(firstTableAttachment(in: content))

        let style = MarkdownTheme.default.table
        let layout = MarkdownTableView.makeLayout(data: attachment.data,
                                                  style: style,
                                                  bodyFont: MarkdownTheme.default.bodyFont,
                                                  headerFont: MarkdownTheme.default.bodyFont.adding(.traitBold),
                                                  availableWidth: 1400)
        XCTAssertEqual(layout.columnWidths[1], style.maxColumnWidth, accuracy: 1,
                       "超长内容的列宽必须封顶在 maxColumnWidth")
        XCTAssertEqual(layout.columnWidths[0], style.minColumnWidth, accuracy: 1)
        XCTAssertEqual(layout.totalWidth, style.minColumnWidth + style.maxColumnWidth, accuracy: 1)
    }

    /// 列很多、总宽超过容器时，仍然要压回容器宽度内（不溢出）
    func testTableTooWideShrinksToContainer() throws {
        let header = (0..<20).map { "第\($0)列" }.joined(separator: " | ")
        let divider = Array(repeating: "---", count: 20).joined(separator: " | ")
        let row = (0..<20).map { "内容\($0)" }.joined(separator: " | ")
        let store = MarkdownDocumentStore()
        store.load(markdown: "| \(header) |\n| \(divider) |\n| \(row) |\n",
                   containerWidth: 400)
        let content = store.blocks[0].renderedContent
        let attachment = try XCTUnwrap(firstTableAttachment(in: content))

        XCTAssertLessThanOrEqual(attachment.bounds.width, 400 - 16 + 1,
                                 "表格总宽不该超出容器")
    }

    /// 从渲染内容里挖出第一个表格 attachment
    private func firstTableAttachment(in content: NSAttributedString) -> MarkdownTableAttachment? {
        var found: MarkdownTableAttachment?
        content.enumerateAttribute(.attachment,
                                   in: NSRange(location: 0, length: content.length),
                                   options: []) { value, _, stop in
            if let table = value as? MarkdownTableAttachment {
                found = table
                stop.pointee = true
            }
        }
        return found
    }

    /// 单元格里的行内语法（`**粗体**`）取出来应该是纯文本，不该带星号
    func testTableCellTextIsPlain() {
        let source = "| 名称 | 说明 |\n| --- | --- |\n| **粗体** | `代码` |\n"
        let store = makeStore(source)
        let content = store.blocks[0].renderedContent

        var attachment: MarkdownTableAttachment?
        content.enumerateAttribute(.attachment,
                                   in: NSRange(location: 0, length: content.length),
                                   options: []) { value, _, stop in
            if let found = value as? MarkdownTableAttachment {
                attachment = found
                stop.pointee = true
            }
        }
        XCTAssertEqual(attachment?.data.rows.first, ["粗体", "代码"])
    }

    /// 只有表头、没有数据行的表格不能崩，往返也要正确
    func testHeaderOnlyTable() {
        let source = "| a | b |\n| --- | --- |\n"
        let store = makeStore(source)
        let restored = store.sourceText(forRenderedRange: fullRenderedRange(store))
        XCTAssertEqual(restored, source, firstDifference(source, restored))
    }

    // MARK: - 引用块竖条（嵌套链）

    /// 渲染层必须给引用块打上 `.markdownQuoteChain` 嵌套链标记。
    ///
    /// ### 防的是什么回归
    /// 竖条改到 overlay 方案后，标记是 UI 层画条的唯一依据。踩过的坑：打标记时
    /// 读到了已恢复现场的父链，外层引用的竖条整个消失。这里验证：
    /// 嵌套引用里，内层字符的链是 `[外层ID, 内层ID]`、外层自己的字符是 `[外层ID]`，
    /// 且两者的第一层 ID 相同（同一条外层竖条）。
    func testQuoteChainAttributeMarksNesting() {
        let tv = makeEditor("""
        > 外层开始
        >
        > > 内层引用
        """)

        var chains: [(range: NSRange, ids: [Int])] = []
        tv.textStorage.enumerateAttribute(
            .markdownQuoteChain,
            in: NSRange(location: 0, length: tv.textStorage.length),
            options: []
        ) { value, range, _ in
            guard let chain = value as? QuoteChain else { return }
            chains.append((range, chain.ids))
        }

        // 内层（长链）一定存在
        let nested = chains.filter { $0.ids.count == 2 }
        XCTAssertEqual(nested.count, 1, "内层引用应该恰好有一个区间挂着两层链，实际：\(chains.map(\.ids))")
        // 外层自己的字符（短链）第一层 ID 要和内层一致 —— 同一条外层竖条
        let outer = chains.filter { $0.ids.count == 1 }
        XCTAssertFalse(outer.isEmpty, "外层引用自己的字符也应该挂一层链（踩过的坑：打成了空链，外层竖条消失）")
        for entry in outer {
            XCTAssertEqual(entry.ids[0], nested[0].ids[0],
                           "外层字符的链首 ID 和内层不一致，外层竖条会断开")
        }
    }

    /// 嵌套引用的竖条：外层贯穿整块，内层只罩自己的行，x 随深度错开一个缩进单位。
    func testNestedQuoteBarsOuterSpansInner() {
        let tv = makeEditor("""
        > 外层开始
        >
        > > 内层引用
        """)

        let (bars, _) = tv.computeQuoteBarFrames()
        XCTAssertEqual(bars.count, 2, "两层嵌套应该恰好两条竖条，实际：\(bars)")
        guard bars.count == 2 else { return }

        let outer = bars.first { $0.level == 0 }!
        let inner = bars.first { $0.level == 1 }!

        // 外层竖条顶要高于内层竖条顶（从"外层开始"那行就开始了）；
        // 底部允许齐平 —— 测试文档里内层引用恰好是最后一行，两条竖条共享底线是正确的
        XCTAssertLessThan(outer.frame.minY, inner.frame.minY, "外层竖条顶应该高于内层竖条顶")
        XCTAssertGreaterThanOrEqual(outer.frame.maxY, inner.frame.maxY, "外层竖条底不能高于内层竖条底")
        XCTAssertGreaterThan(outer.frame.height, inner.frame.height,
                             "外层竖条必须比内层高 —— 只比内层高不出一行的话，说明外层没有贯穿整块")
        // 内层竖条往右错开一个缩进单位，和内层文字的缩进对齐
        let theme = tv.renderer.theme
        XCTAssertEqual(inner.frame.minX - outer.frame.minX, theme.quoteIndent, accuracy: 0.5,
                       "内外竖条的水平间距应该等于 quoteIndent")
        XCTAssertEqual(outer.frame.width, theme.quoteBarWidth, accuracy: 0.5)
    }

    /// 竖条必须连续贯穿段距（空行）——这是 overlay 方案相对旧版「每行一个 attachment」
    /// 的核心改进：旧版在 6pt 段距处断成虚线。
    func testQuoteBarCoversBlankLinesContinuously() {
        let tv = makeEditor("""
        > 第一段
        >
        > 第二段
        """)

        let (bars, _) = tv.computeQuoteBarFrames()
        XCTAssertEqual(bars.count, 1, "带空行的引用应该只有一条连续竖条，实际：\(bars)")
        let lineHeight = tv.renderer.theme.bodyFont.lineHeight
        XCTAssertGreaterThan(bars.first?.frame.height ?? 0, lineHeight * 2,
                             "竖条高度没盖住两行 + 中间段距，还是断的")
    }

    /// 两条**独立**的引用必须各自一条竖条，不能被合并成一条贯穿两个块的。
    ///
    /// ### 防的是什么回归
    /// 竖条 ID 来自「块在文档里的起始偏移 + 引用节点在块内的位置」。早期版本忘了加盐，
    /// 不同块里的引用都从块内位置 0 开始算 ID → 两个块的 ID 撞车，UI 层把两条竖条
    /// 合并成一条、中间隔着普通段落还连在一起。
    func testSeparateQuotesGetSeparateBars() {
        let tv = makeEditor("""
        > 第一条引用

        普通段落

        > 第二条引用
        """)

        let (bars, _) = tv.computeQuoteBarFrames()
        XCTAssertEqual(bars.count, 2, "两条独立引用应该两条竖条，实际：\(bars)")
        guard bars.count == 2 else { return }
        let sorted = bars.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertLessThan(sorted[0].frame.maxY, sorted[1].frame.minY,
                          "两条竖条在竖直方向上不该有重叠 —— 重叠说明 ID 撞车被合并了")
    }

    // MARK: - 任务列表复选框

    /// 扫出 textStorage 里所有复选框标记的（区间, 信息）
    private func checkboxMarkedRanges(in textView: MarkdownTextView) -> [(NSRange, CheckboxInfo)] {
        var result: [(NSRange, CheckboxInfo)] = []
        textView.textStorage.enumerateAttribute(.markdownCheckbox,
                                                in: NSRange(location: 0, length: textView.textStorage.length),
                                                options: []) { value, range, _ in
            guard let info = value as? CheckboxInfo else { return }
            result.append((range, info))
        }
        return result
    }

    /// 把编辑器视图树里所有复选框按钮捞出来。
    ///
    /// 复选框所在的层（`CheckboxLayer`）和摆按钮的方法都是 private，所以只能从视图树里找 —— 但这也正是「用户看到的那一个」，拿它做断言比查数据更贴近症状。
    private func allCheckboxButtons(in view: UIView) -> [MarkdownCheckboxButton] {
        var result: [MarkdownCheckboxButton] = []
        for sub in view.subviews {
            if let button = sub as? MarkdownCheckboxButton { result.append(button) }
            result.append(contentsOf: allCheckboxButtons(in: sub))
        }
        return result
    }

    /// `[x]` / `[ ]` 三个字符必须带着正确的标记，且**字符本身原样保留在文本里**。
    ///
    /// ### 防的是什么回归
    /// 复选框是「叠在源码上」的按钮，不是替换掉源码 —— 这三个字符一旦被删掉或改成
    /// 装饰字符，「全选复制 === 源文件」就破了。
    func testTaskListCheckboxMarkedOnLiteralText() {
        let tv = makeEditor("""
        - [x] 已完成
        - [ ] 未完成
        """)
        let marked = checkboxMarkedRanges(in: tv)
        XCTAssertEqual(marked.count, 2, "两个任务项应该有两个复选框标记")

        // 文本流：`- ` + 座位(￼) + `[x] ` + 正文。**没有圆点** —— 任务项的标记位置换成了「浅灰 `-` + 复选框座位 + 浅灰 `[x]`」
        XCTAssertEqual(tv.textStorage.string, "- \u{FFFC}[x] 已完成\n- \u{FFFC}[ ] 未完成")

        // 勾选状态识别正确
        XCTAssertEqual(marked[0].1.isChecked, true, "`[x]` 应该识别为已勾选")
        XCTAssertEqual(marked[1].1.isChecked, false, "`[ ]` 应该识别为未勾选")

        // sourceStart 必须精确指向 `[`（点复选框时靠它定位要改的三个字符）
        let source = tv.markdownSource as NSString
        XCTAssertEqual(source.substring(with: NSRange(location: marked[0].1.sourceStart, length: 3)), "[x]")
        XCTAssertEqual(source.substring(with: NSRange(location: marked[1].1.sourceStart, length: 3)), "[ ]")
    }

    /// 点一下复选框 = 一次标准源码编辑：`[ ]` ↔ `[x]`，再点一次回到原样。
    func testCheckboxToggleRewritesSourceBothWays() {
        let original = "- [ ] 未完成\n"
        let tv = makeEditor(original)

        guard let info = checkboxMarkedRanges(in: tv).first?.1 else {
            return XCTFail("没有找到复选框标记")
        }
        tv.toggleCheckbox(info)
        XCTAssertEqual(tv.markdownSource, "- [x] 未完成\n", "点击后源码里的 `[ ]` 应该变成 `[x]`")

        // 切换之后块会重新渲染，标记是全新的实例 —— 用新实例再点一次切回去
        guard let reloaded = checkboxMarkedRanges(in: tv).first?.1 else {
            return XCTFail("切换之后复选框标记丢了")
        }
        XCTAssertEqual(reloaded.isChecked, true)
        tv.toggleCheckbox(reloaded)
        XCTAssertEqual(tv.markdownSource, original, "再点一次应该切回 `[ ]`，源码一字不差")
    }

    /// 大写 `[X]` 按 GFM 也算已勾选；点一下取消勾选（写成 `[ ]`）。
    func testUppercaseXIsCheckedAndTogglesOff() {
        let tv = makeEditor("- [X] 大写也算完成\n")
        guard let info = checkboxMarkedRanges(in: tv).first?.1 else {
            return XCTFail("没有找到复选框标记")
        }
        XCTAssertEqual(info.isChecked, true)
        tv.toggleCheckbox(info)
        XCTAssertEqual(tv.markdownSource, "- [ ] 大写也算完成\n")
    }

    /// 复选框矩形（也就是渲染层留出来的那块「座位」）必须紧贴在 `[x]` **左边**，且和它同一行 —— 垂直方向对不上就说明 inset 换算又丢了。
    ///
    /// ### 为什么基准从「和 `[` 左边界对齐」改成「待在 `[` 左边」
    /// 早先复选框是**盖在** `[x]` 上的，矩形左边界自然该和 `[` 对齐；现在默认不遮盖（`[x]` 要照常看得见），按钮改坐在 `- ` 和 `[x]` 之间留出的座位上，左边界落在 `[` 前面一截 —— 隔的那段正是座位宽度（边长 + 两侧间距）。
    func testCheckboxFrameSitsLeftOfLiteral() {
        let tv = makeEditor("- [x] 已完成\n- [ ] 未完成\n")
        let (boxes, _) = tv.computeCheckboxFrames()
        XCTAssertEqual(boxes.count, 2)

        for (info, frame) in boxes {
            guard let rendered = tv.documentStore.renderedRange(forSourceRange:
                        NSRange(location: info.sourceStart, length: 3)),
                  let pos = tv.position(from: tv.beginningOfDocument, offset: rendered.location) else {
                continue
            }
            let caret = tv.caretRect(for: pos)
            XCTAssertLessThanOrEqual(frame.maxX, caret.minX + 0.5,
                                     "座位必须整个待在 `[` 左边，否则按钮会压住源码")
            XCTAssertEqual(frame.midY, caret.midY, accuracy: 3,
                           "y 没对齐 —— 八成是忘了补 textContainerInset.top")
            XCTAssertGreaterThan(frame.width, 8, "矩形宽度不该是 0 —— segment 没算出来")
        }
    }

    /// 嵌套任务项也要有自己的复选框，且源码定位各自正确。
    func testNestedTaskListGetsOwnCheckbox() {
        let tv = makeEditor("""
        - [x] 父任务
          - [ ] 子任务
        """)
        let marked = checkboxMarkedRanges(in: tv)
        XCTAssertEqual(marked.count, 2, "嵌套项也要有自己的复选框")

        let source = tv.markdownSource as NSString
        XCTAssertEqual(source.substring(with: NSRange(location: marked[0].1.sourceStart, length: 3)), "[x]")
        XCTAssertEqual(source.substring(with: NSRange(location: marked[1].1.sourceStart, length: 3)), "[ ]")

        // 嵌套项的 `[` 在源码里必须指向子任务那一行（`- [x] 父任务\n  ` 之后第 3 个字符）
        XCTAssertEqual(marked[1].1.sourceStart, 14, "子任务的 `[` 应该在偏移 14（前 10 个字符 + 两个缩进空格 + 2）")
    }

    /// 任务列表文档「全选复制」必须还原源文件（复选框 UI 不许偷走任何字符）
    func testTaskListSelectAllCopiesSource() {
        let source = "- [x] 已完成\n- [ ] 未完成\n  - [X] 嵌套\n"
        let store = makeStore(source)
        XCTAssertEqual(store.sourceText(forRenderedRange: fullRenderedRange(store)), source,
                       firstDifference(source, store.sourceText(forRenderedRange: fullRenderedRange(store))))
    }

    /// 复选框**默认不遮盖** `[x]`：源码要照常看得见，按钮坐在渲染层留出的座位上。要改回遮盖（盖在 `[x]` 上），先更新这条测试和 `MarkdownTheme` 里的注释。
    func testCheckboxDoesNotCoverLiteralByDefault() {
        XCTAssertFalse(MarkdownTheme.default.taskList.coversCheckboxLiteral)
    }

    /// 勾选状态必须**读源码里那三个字符**，不能信语法树的 `item.checkbox`。
    ///
    /// ### 防的是什么回归（真出过，用户报的就是这个）
    /// cmark-gfm 判定勾没勾用的是 `strstr(整行, "[x]")` —— 只要这一行**别处**还有一个 `[x]` / `[X]`，整项就被报成已勾选，哪怕真正的标记是 `[ ]`。于是复选框顶着绿底盖在 `[ ]` 上，点它又按「已勾选」写回 `[ ]`（等于没动），表现为「点了没反应」。
    func testCheckboxStateComesFromLiteralNotWholeLine() {
        // 用户报的那一行：标记是 `[ ]`，正文里另有 `[x]`
        let decoy = "- [ ] 未完成的项，点一下变 [x]\n"
        let tv = makeEditor(decoy)
        guard let marked = checkboxMarkedRanges(in: tv).first else {
            return XCTFail("没有找到复选框标记")
        }
        let source = tv.markdownSource as NSString
        XCTAssertEqual(source.substring(with: NSRange(location: marked.1.sourceStart, length: 3)), "[ ]",
                       "定位必须指向 `[` 那三个字符")
        XCTAssertFalse(marked.1.isChecked,
                       "标记是 `[ ]` 就不该是已勾选 —— 语法树的 checkbox 在正文含 `[x]` 时会错报")

        // 反过来：标记是 `[x]`、正文里有 `[ ]`，仍然算勾上
        let reverse = makeEditor("- [x] 已完成的项，正文提到 [ ]\n")
        XCTAssertEqual(checkboxMarkedRanges(in: reverse).first?.1.isChecked, true,
                       "`[x]` 就是勾上，别被正文里的 `[ ]` 带偏")

        // 大小写 `X` 一样算勾上
        XCTAssertEqual(checkboxMarkedRanges(in: makeEditor("- [X] 大写\n")).first?.1.isChecked, true)
    }

    /// 用户看到的那个按钮：源码是 `[ ]` 时必须画成**未勾选**。
    ///
    /// ### 为什么单测要走到视图层
    /// 上一条盯的是数据，这条盯的是「用户眼里看到的样子」—— 复选框是叠在正文上的原生 UIButton，状态由 `computeCheckboxFrames()` 喂给它，所以直接从视图树里把按钮捞出来问一句，才是这条 bug 的真实验收标准。
    func testCheckboxButtonLooksUncheckedWhenLiteralIsUnchecked() {
        let tv = makeEditor("- [ ] 未完成的项，点一下变 [x]\n")
        let buttons = allCheckboxButtons(in: tv)
        XCTAssertEqual(buttons.count, 1, "应该只有一个复选框")
        guard let button = buttons.first else { return }

        XCTAssertEqual(button.checkbox?.isChecked, false, "按钮拿到的状态该是没勾")
        XCTAssertNil(button.image(for: .normal), "没勾就不该画对勾")
        XCTAssertEqual(button.accessibilityValue, "未完成")
    }

    /// 点一下必须**真的改到源码**：正文里那个 `[x]` 是干扰，不能让它导致「按已勾选写回 `[ ]`」这种空操作。
    func testClickingCheckboxWithDecoyXStillWritesX() {
        let tv = makeEditor("- [ ] 未完成的项，点一下变 [x]\n")
        guard let info = checkboxMarkedRanges(in: tv).first?.1 else {
            return XCTFail("没有找到复选框标记")
        }
        tv.toggleCheckbox(info)
        XCTAssertEqual(tv.markdownSource, "- [x] 未完成的项，点一下变 [x]\n",
                       "点一下应该把标记改成 `[x]`，正文里那个 `[x]` 一个字都不能动")

        // 再点一次切回去
        guard let reloaded = checkboxMarkedRanges(in: tv).first?.1 else {
            return XCTFail("切换之后复选框标记丢了")
        }
        tv.toggleCheckbox(reloaded)
        XCTAssertEqual(tv.markdownSource, "- [ ] 未完成的项，点一下变 [x]\n")
    }

    /// 复选框的**宽度不能随勾选状态变** —— 这就是「点一下复选框变宽了」那个 bug。
    ///
    /// ### 防的是什么回归
    /// 方框宽度早先写成 `max(checkboxSide, 当前字面量宽度)`。而 `[ ]` / `[x]` / `[X]` 在图里的宽度**各不相同**（正文 17pt 系统字体实测 15.95 / 20.09 / 22.71pt），于是点一下 `[ ]` → `[x]`，方框就从 16pt 长到 20pt。
    ///
    /// 宽度只该跟**字体**有关、和当前状态无关 —— 所以同一份文档里，勾上的和没勾的复选框必须是同一个宽度。
    func testCheckboxWidthDoesNotDependOnCheckedState() {
        let tv = makeEditor("- [ ] 未完成\n- [x] 已完成\n- [X] 大写\n")
        let buttons = allCheckboxButtons(in: tv)
        XCTAssertEqual(buttons.count, 3, "三个任务项应该三个复选框")

        let widths = buttons.map(\.frame.width)
        XCTAssertEqual(Set(widths.map { ($0 * 100).rounded() }).count, 1,
                       "勾没勾不能影响方框宽度，实际宽度：\(widths)")

        // 不遮盖模式下按钮就是方框边长本身（居中坐在座位里），而座位要留出两侧间距，所以必须比方框宽
        let side = MarkdownTheme.default.taskList.checkboxSide
        XCTAssertEqual(widths[0], side, accuracy: 0.5, "按钮宽度就该是主题里的方框边长")
        let seatWidth = tv.computeCheckboxFrames().boxes.map(\.frame.width).max() ?? 0
        XCTAssertGreaterThan(seatWidth, widths[0], "座位要留出两侧间距，得比方框宽")
    }

    /// 用户看到变化的**正是点击那一刻**，所以要单独钉一次「点完宽度不变」。
    func testCheckboxWidthStaysAfterToggling() {
        let tv = makeEditor("- [ ] 未完成\n")
        let before = allCheckboxButtons(in: tv).first?.frame.width

        guard let info = checkboxMarkedRanges(in: tv).first?.1 else {
            return XCTFail("没有找到复选框标记")
        }
        tv.toggleCheckbox(info)
        // 直接调 toggleCheckbox 不会自己触发重新排版，得手动催一次（按钮是在排版过程中重建的）
        tv.setNeedsLayout()
        tv.layoutIfNeeded()

        XCTAssertEqual(allCheckboxButtons(in: tv).first?.frame.width, before,
                       "点一下 `[ ]` 变 `[x]`，方框宽度不该跟着变")
    }

    // MARK: - 任务项的排版：`-` 不是圆点、`[x]` 要看得见

    /// 任务项**不画圆点**；普通列表项照旧画（别顺手把圆点一起改没了）。
    ///
    /// 圆点和座位在文本流里都是 `\u{FFFC}`，靠位置区分：任务项是「`- ` 打头、座位跟在后面」，普通列表项是「圆点打头、后面才跟着弱化的 `- `」。
    func testTaskListItemHasNoBulletButPlainItemKeepsIt() {
        let tv = makeEditor("- [ ] 任务项\n- 普通项\n")
        let text = tv.textStorage.string
        XCTAssertTrue(text.contains("- \u{FFFC}[ ] 任务项"),
                      "任务项应该是「浅灰 `-` + 座位 + `[ ]` + 正文」，实际：\(text)")
        XCTAssertTrue(text.contains("\u{FFFC}- 普通项"),
                      "普通列表项仍然以圆点打头，实际：\(text)")
    }

    /// 按钮必须坐在 `- ` 和 `[x]` 中间 —— 两边的源码都不许被压住。
    ///
    /// 这条钉的就是用户要的那个顺序：浅灰 `-` → 复选框 → `[ ]`/`[x]` → 正文。
    func testCheckboxButtonSitsBetweenDashAndLiteral() {
        let tv = makeEditor("- [ ] 未完成的项\n")
        let buttons = allCheckboxButtons(in: tv)
        XCTAssertEqual(buttons.count, 1)
        guard let button = buttons.first,
              let info = checkboxMarkedRanges(in: tv).first?.1,
              let rendered = tv.documentStore.renderedRange(forSourceRange:
                  NSRange(location: info.sourceStart, length: 3)),
              let literalPos = tv.position(from: tv.beginningOfDocument, offset: rendered.location),
              let seatPos = tv.position(from: tv.beginningOfDocument, offset: rendered.location - 1),
              let dashPos = tv.position(from: tv.beginningOfDocument, offset: rendered.location - 2)
        else { return XCTFail("定位失败") }

        let literalX = tv.caretRect(for: literalPos).minX   // `[` 的位置
        let seatX = tv.caretRect(for: seatPos).minX         // 座位的位置
        let dashX = tv.caretRect(for: dashPos).minX         // `- ` 的位置

        XCTAssertGreaterThan(seatX, dashX, "座位应该在 `- ` 右边")
        XCTAssertLessThanOrEqual(button.frame.maxX, literalX + 0.5,
                                 "按钮不能压住 `[ ]` —— 源码要照常看得见")
        XCTAssertGreaterThanOrEqual(button.frame.minX, seatX - 0.5,
                                    "按钮不能越出座位、压到左边的 `- `")
    }

    /// 任务项换行后，第二行要落在首行**正文**起点附近 —— 悬挂缩进得按标记实际宽度算，不能沿用普通列表项的 `listIndent`。
    ///
    /// ### 为什么允许一点点偏差（实测约 7pt）
    /// 悬挂缩进取的是「所有字面量里最宽的那个」（`[X] `）算出来的**定值**，这样**同一份文档里勾上和没勾的任务项，第二行起点一模一样**（整列看着才齐）。代价是当前字面量是较窄的 `[ ]` 时，首行正文比第二行靠左约 7pt（`[ ]` 与 `[X]` 的字宽差）。反过来「按当前字面量算」能让单项内部严丝合缝，但勾上/没勾的行会各缩各的，更乱。
    func testTaskListIndentFollowsMarkerWidth() {
        let tv = makeEditor("- [ ] 未完成的项\n")
        guard let style = tv.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle else {
            return XCTFail("第一个字符上应该有列表项的段落样式")
        }
        XCTAssertGreaterThan(style.headIndent, MarkdownTheme.default.listIndent,
                             "任务项的标记区比普通项宽（多了座位和 `[x]`），悬挂缩进要跟着变大")
        XCTAssertEqual(style.firstLineHeadIndent, 0, accuracy: 0.5, "首行仍然顶到最左边")

        // 第二行不能跑到首行正文左边 —— 那看着就像缩进错乱
        guard let info = checkboxMarkedRanges(in: tv).first?.1,
              let literal = tv.documentStore.renderedRange(
                  forSourceRange: NSRange(location: info.sourceStart, length: 3)),
              let bodyPos = tv.position(from: tv.beginningOfDocument, offset: literal.location + 4)
        else { return XCTFail("定位失败") }

        let bodyX = tv.caretRect(for: bodyPos).minX
        let wrappedX = tv.textContainerInset.left + style.headIndent
        XCTAssertGreaterThanOrEqual(wrappedX, bodyX - 0.5, "第二行不能缩到首行正文左边")
        XCTAssertLessThan(wrappedX - bodyX, 12, "两行起点别差太多 —— 差值是 `[ ]` 与 `[X]` 的字宽差")
    }

    /// 对勾是**自己画的**（不走 SF Symbol）：形状随方框边长等比，颜色交给 tintColor。
    ///
    /// ### 为什么不用 `UIImage(systemName: "checkmark")`
    /// 符号大小由 `pointSize` 定死、**和方框边长无关** —— 方框边长是主题里可配的，符号不会跟着变，只能拿一个「凑出来正好」的 pointSize 碰运气。自绘之后「对勾比方框小一圈、永远居中」由代码保证。
    func testCheckmarkIsSelfDrawnSquareWithinBox() {
        let tv = makeEditor("- [x] 已完成\n")
        guard let button = allCheckboxButtons(in: tv).first else {
            return XCTFail("没有找到复选框按钮")
        }
        guard let image = button.image(for: .normal) else {
            return XCTFail("已勾选就该画上对勾")
        }

        XCTAssertEqual(image.renderingMode, .alwaysTemplate,
                       "对勾走模板模式，颜色才能由 tintColor（主题的 checkmarkColor）决定")
        XCTAssertEqual(image.size.width, image.size.height, accuracy: 0.5,
                       "对勾图应该是正方形，边长按方框边长算")
        XCTAssertLessThanOrEqual(image.size.height, button.bounds.height + 0.5,
                                 "对勾不能比如框还高，否则会顶到边框")
    }

    // MARK: - 代码块背景（文档坐标修正）

    /// 代码块测试文档：两个代码块，中间垫了足量正文，第二个块从 1500pt 开外才开始
    /// （滚动用例要滚到 1500 还能看到它）。
    ///
    /// ### 为什么是内联字符串，不是 testcase/ 下的文件
    /// 之前放在 `testcase/CodeBlockBackgroundTestCase.md`，目录清理时文件被删了、
    /// 五条测试全挂。测试文档是测试自己的输入，内联进来谁也删不掉。
    private var codeBlockTestCase: String {
        """
        # 代码块背景测试

        第一段正文，用来把第一个代码块往下顶一点。

        ```swift
        let a = 1
        let b = 2
        print(a + b)
        ```

        \(Array(repeating: "这是一段垫在两个代码块之间的正文，让第二个代码块离第一屏足够远。", count: 23).joined(separator: "\\n\\n"))

        ```bash
        echo 长代码块第一行
        for i in 1 2 3; do
          echo "第 $i 轮"
        done
        until false; do
          echo 永远走不到的分支
          break
        done
        case "$1" in
          start) echo 启动 ;;
          stop) echo 停止 ;;
          *) echo 用法：$0 {start|stop} ;;
        esac
        echo 长代码块最后一行
        ```

        结尾还有一行正文，保证代码块不是文档最后一个块。
        """
    }

    private func makeCodeBlockTestCaseEditor() throws -> MarkdownTextView {
        makeEditor(codeBlockTestCase)
    }

    /// 扫出 textStorage 里所有代码块的字符区间
    private func codeBlockRanges(in textView: MarkdownTextView) -> [NSRange] {
        var ranges: [NSRange] = []
        textView.textStorage.enumerateAttribute(
            .markdownCodeBlock,
            in: NSRange(location: 0, length: textView.textStorage.length),
            options: []
        ) { value, range, _ in
            if value is CodeBlockInfo { ranges.append(range) }
        }
        return ranges
    }

    /// 背景矩形必须真的罩住代码**正文**。
    ///
    /// ### 防的是什么回归
    /// `layoutFragmentFrame` 的原点是 **textContainer 左上角（不含 textContainerInset）**，
    /// 直接当文档坐标用，背景会整体偏上一个 inset（16pt）。这里用官方 `caretRect(for:)`
    /// （它的坐标含 inset，是权威基准）对照：背景顶/底必须贴着正文的首行和末行。
    func testCodeBlockBackgroundAlignsWithCaret() throws {
        let tv = try makeCodeBlockTestCaseEditor()
        let (frames, _) = tv.computeCodeBlockFrames()
        let ranges = codeBlockRanges(in: tv)
        XCTAssertEqual(frames.count, 2, "测试用例里应该有 2 个代码块")
        XCTAssertEqual(ranges.count, frames.count)

        for (entry, range) in zip(frames, ranges) {
            let lines = codeBlockLines(of: range, in: tv)
            XCTAssertGreaterThanOrEqual(lines.count, 3, "测试用例里的代码块至少有开围栏、正文、闭围栏三行")

            // 正文首行 = 开围栏那行的下一行，正文末行 = 闭围栏那行的上一行
            guard let contentTopPos = tv.position(from: tv.beginningOfDocument, offset: lines[1].location),
                  let contentBottomPos = tv.position(from: tv.beginningOfDocument,
                                                    offset: lines[lines.count - 2].location) else { continue }
            let contentTop = tv.caretRect(for: contentTopPos)
            let contentBottom = tv.caretRect(for: contentBottomPos)

            // 背景顶：在正文首行上方，但只差一个 padding（主题里是 6pt），给 20pt 容差防脆断
            XCTAssertLessThanOrEqual(entry.frame.minY, contentTop.minY + 1,
                "背景顶(\(entry.frame.minY))跑到正文首行(\(contentTop.minY))下面了")
            XCTAssertGreaterThanOrEqual(entry.frame.minY, contentTop.minY - 20,
                "背景顶离正文首行太远，多半是 inset 换算又丢了")
            // 背景底：刚好压在正文末行下面
            XCTAssertGreaterThanOrEqual(entry.frame.maxY, contentBottom.maxY - 1,
                "背景底(\(entry.frame.maxY))没罩住正文末行(\(contentBottom.maxY))")
            XCTAssertLessThanOrEqual(entry.frame.maxY, contentBottom.maxY + 20,
                "背景底拖太长，多半把闭围栏那行也包进去了")
        }
    }

    /// **首尾的 \`\`\` 围栏行不能带灰底**（用户明确要求）。
    ///
    /// 背景只罩代码正文，围栏行留白，这样 ```bash 和收尾的 ``` 看起来是"框"，
    /// 而不是被糊进灰方块里。
    func testCodeBlockBackgroundExcludesFenceLines() throws {
        let tv = try makeCodeBlockTestCaseEditor()
        let (frames, _) = tv.computeCodeBlockFrames()
        let ranges = codeBlockRanges(in: tv)

        for (entry, range) in zip(frames, ranges) {
            let lines = codeBlockLines(of: range, in: tv)

            // 开围栏行（第一行）的文字不能被背景压住
            guard let fencePos = tv.position(from: tv.beginningOfDocument, offset: lines[0].location) else { continue }
            let fenceCaret = tv.caretRect(for: fencePos)
            XCTAssertGreaterThan(entry.frame.minY, fenceCaret.minY,
                "背景顶(\(entry.frame.minY))盖到了开围栏行(\(fenceCaret.minY))上")

            // 闭围栏行（最后一行）同理：背景底不能探进它的文字区域
            let closing = lines[lines.count - 1]
            guard let closingPos = tv.position(from: tv.beginningOfDocument, offset: closing.location) else { continue }
            let closingCaret = tv.caretRect(for: closingPos)
            XCTAssertLessThan(entry.frame.maxY, closingCaret.maxY,
                "背景底(\(entry.frame.maxY))盖到了闭围栏行(\(closingCaret.maxY))上")
        }
    }

    /// 开关打开（`showsCodeBlockFenceBackground = true`）时，围栏行要重新被背景罩住。
    /// 和上一个测试正好相反，两条一起才说明这个 bool 真的管用、而不是写死了一种效果。
    func testFenceBackgroundEnabledCoversFenceLines() throws {
        let tv = try makeCodeBlockTestCaseEditor()
        tv.renderer.theme.showsCodeBlockFenceBackground = true
        let (frames, _) = tv.computeCodeBlockFrames()
        let ranges = codeBlockRanges(in: tv)
        XCTAssertEqual(frames.count, 2)

        for (entry, range) in zip(frames, ranges) {
            let lines = codeBlockLines(of: range, in: tv)
            guard let openPos = tv.position(from: tv.beginningOfDocument, offset: lines[0].location),
                  let closePos = tv.position(from: tv.beginningOfDocument,
                                             offset: lines[lines.count - 1].location) else { continue }
            let openCaret = tv.caretRect(for: openPos)
            let closeCaret = tv.caretRect(for: closePos)

            XCTAssertLessThanOrEqual(entry.frame.minY, openCaret.minY + 1,
                "开关打开后背景顶(\(entry.frame.minY))应该压到开围栏行(\(openCaret.minY))上面")
            XCTAssertGreaterThanOrEqual(entry.frame.maxY, closeCaret.maxY - 1,
                "开关打开后背景底(\(entry.frame.maxY))应该盖住闭围栏行(\(closeCaret.maxY))")
        }
    }

    /// 主题里这个开关的默认值必须是 false（用户明确要求围栏行默认不带背景）
    func testFenceBackgroundDefaultsToOff() {
        XCTAssertFalse(MarkdownTheme.default.showsCodeBlockFenceBackground)
    }

    /// 空代码块（开围栏紧接着闭围栏，中间没有正文）不该铺出任何背景
    func testEmptyCodeBlockHasNoBackground() throws {
        let tv = makeEditor("""
        # 空代码块

        ```
        ```

        正文
        """)
        let (frames, pending) = tv.computeCodeBlockFrames()
        XCTAssertTrue(frames.isEmpty, "只有两个围栏行的空代码块不应该有背景，实际：\(frames)")
        XCTAssertFalse(pending, "空代码块不是「TextKit 还没排出来」，不该触发重试")
    }

    // MARK: - 滚动时的背景落位（长文档专项）

    /// 造一篇「代码块在首屏之外」的长文档：前面垫 40 段正文，最后放一个 swift 代码块。
    /// 不依赖磁盘文件（testcase 目录以前被清理过一次，测试跟着一起挂过）
    private func makeLongDocumentWithCodeBlock() -> String {
        let filler = Array(repeating: "这是一段垫在代码块前面的正文，用来把代码块顶到首屏之外。",
                           count: 40).joined(separator: "\n\n")
        return """
        \(filler)

        ```swift
        let document = Document(parsing: markdown)
        for child in document.children {
            print(type(of: child))
        }
        ```
        """
    }

    /// **滚动当帧背景就要落到位**，不能等滚动停下（0.15s 后那次全量重算）才跳过去。
    ///
    /// 现象：打开长文档往下滚，灰底先停在一个偏上的位置，停下手才「啪」地挪到代码背后。
    /// 根因是屏幕外的代码块只能用 TextKit 的估算坐标算矩形、缓存下来后滚动时一直沿用。
    func testCodeBlockBackgroundIsCorrectRightAfterScrolling() {
        let tv = makeEditor(makeLongDocumentWithCodeBlock())
        tv.frame = CGRect(x: 0, y: 0, width: 900, height: 800)
        tv.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        // 先拿一次文档坐标（此时代码块还在屏幕外，这个值可能是估算的，正好用来定滚动量）
        let (initial, _) = tv.computeCodeBlockFrames()
        XCTAssertEqual(initial.count, 1, "这篇文档里应该有 1 个代码块")

        // 滚到代码块露出来的位置。只给 0.1 秒（滚动中一帧的量级，远小于 0.15s 的兜底），
        // 就是要看「滚动过程中」而不是「滚动停下之后」的结果
        tv.contentOffset = CGPoint(x: 0, y: initial[0].frame.midY - 300)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        // 现在代码块在视野里了，这才是它的真坐标
        let (fresh, _) = tv.computeCodeBlockFrames()
        let expectedY = fresh[0].frame.origin.y - tv.contentOffset.y
        let placed = backgroundFrames(of: tv)

        XCTAssertEqual(placed.count, 1, "滚到代码块处，应该有一个背景 view")
        XCTAssertEqual(placed.first?.origin.y ?? -1, expectedY, accuracy: 2,
                       "滚动当帧的背景位置(\(placed.first?.origin.y ?? -1))应该等于文档坐标减滚动量(\(expectedY))，差太多说明还在用屏幕外的估算值")
    }

    /// 滚动到位后，灰底不能压到 ```swift 那一行上（用户报的「swift 跟背景重合」）。
    ///
    /// 这就是上面那条 bug 的视觉表现：估算值偏上 84pt，正好把开围栏那行罩进灰底里，
    /// 于是 ```swift 这几个字看起来是写在灰底上的。
    func testCodeBlockBackgroundDoesNotCoverFenceLineAfterScrolling() {
        let tv = makeEditor(makeLongDocumentWithCodeBlock())
        tv.frame = CGRect(x: 0, y: 0, width: 900, height: 800)
        tv.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        let (initial, _) = tv.computeCodeBlockFrames()
        tv.contentOffset = CGPoint(x: 0, y: initial[0].frame.midY - 300)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        guard let range = codeBlockRanges(in: tv).first,
              let background = backgroundFrames(of: tv).first else {
            return XCTFail("滚到代码块处应该有一个背景 view")
        }
        let lines = codeBlockLines(of: range, in: tv)
        let offsetY = tv.contentOffset.y

        // 开围栏那一行（```swift）的文字区域换算到屏幕坐标
        guard let openPos = tv.position(from: tv.beginningOfDocument, offset: lines[0].location) else {
            return XCTFail("拿不到开围栏行的位置")
        }
        let openCaret = tv.caretRect(for: openPos)
        XCTAssertGreaterThan(background.minY, openCaret.maxY - offsetY,
                             "背景顶(\(background.minY))压到了开围栏行(\(openCaret.maxY - offsetY))上")

        // 闭围栏那一行（收尾的 ```）同理
        let closing = lines[lines.count - 1]
        guard let closePos = tv.position(from: tv.beginningOfDocument, offset: closing.location) else {
            return XCTFail("拿不到闭围栏行的位置")
        }
        let closeCaret = tv.caretRect(for: closePos)
        XCTAssertLessThan(background.maxY, closeCaret.minY - offsetY,
                          "背景底(\(background.maxY))压到了闭围栏行(\(closeCaret.minY - offsetY))上")
    }

    /// 把一个代码块按行切开，返回每行在**整篇文本**里的 NSRange（含行尾换行）。
    /// 这里故意不复用 `MarkdownTextView` 里的切分逻辑，免得它算错了测试也跟着错。
    private func codeBlockLines(of range: NSRange, in textView: MarkdownTextView) -> [NSRange] {
        let text = textView.textStorage.string as NSString
        let end = NSMaxRange(range)
        var lines: [NSRange] = []
        var cursor = range.location
        while cursor < end {
            let line = text.lineRange(for: NSRange(location: cursor, length: 0))
            let lineEnd = min(NSMaxRange(line), end)
            guard lineEnd > cursor else { break }
            lines.append(NSRange(location: cursor, length: lineEnd - cursor))
            cursor = lineEnd
        }
        return lines
    }

    /// 同一个代码块，滚动到任何位置算出来的文档坐标矩形都必须一致。
    /// 之前背景「完全错乱」的一半原因就是坐标随滚动漂移。
    func testCodeBlockFramesStableAcrossScroll() throws {
        let tv = try makeCodeBlockTestCaseEditor()

        var baseline: [CGRect] = []
        for offset in [0, 300, 800, 1500, 2500, 3200] {
            tv.contentOffset = CGPoint(x: 0, y: CGFloat(offset))
            tv.layoutIfNeeded()
            let (frames, _) = tv.computeCodeBlockFrames()
            let rects = frames.map(\.frame)
            XCTAssertEqual(rects.count, 2, "offset=\(offset) 时应该还是 2 个代码块")
            if baseline.isEmpty {
                baseline = rects
            } else {
                for (index, rect) in rects.enumerated() {
                    XCTAssertEqual(rect, baseline[index],
                        "offset=\(offset) 时块\(index)的矩形和 offset=0 不一致：\(rect) vs \(baseline[index])")
                }
            }
        }
    }

    /// 滚动之后背景必须重新落位。
    ///
    /// 之前「完全错乱」的另一半原因：背景矩形算完就固化了，滚动只做平移，
    /// 首帧那个估算坐标一直用到天荒地老。现在滚动停下 0.15s 会重算一次。
    func testCodeBlockBackgroundFollowsScroll() throws {
        let tv = try makeCodeBlockTestCaseEditor()
        // 等首帧那条「结果不稳定就重试」的链路收敛
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        let offsetY: CGFloat = 1500
        tv.contentOffset = CGPoint(x: 0, y: offsetY)
        tv.layoutIfNeeded()

        // ⚠️ 必须用**实际**滚动量：文档总高只有 1700 出头，滚 1500 会被系统夹到底部
        // （实测夹到 813）。拿写死的 1500 去算期望值，测出来的是「UITextView 会夹滚动」
        // 而不是「背景没跟上」，白白红了很久
        let actualOffset = tv.contentOffset.y
        XCTAssertGreaterThan(actualOffset, 100, "这个用例要真的滚起来才有意义")

        let (frames, _) = tv.computeCodeBlockFrames()
        XCTAssertEqual(frames.count, 2)

        // 滚动停下之后的重算是异步的，轮询等它落位（最多等 3 秒）
        var placed: [CGRect] = []
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            placed = backgroundFrames(of: tv)
            if let first = placed.first,
               abs(first.origin.y - (frames.last!.frame.origin.y - actualOffset)) < 2 { break }
        }

        XCTAssertFalse(placed.isEmpty, "滚到底时第二个代码块应该还在可见范围内")
        XCTAssertEqual(placed.first?.origin.y ?? 0,
                       frames.last!.frame.origin.y - actualOffset,
                       accuracy: 2,
                       "背景没跟着滚动重新落位：\(placed.first?.origin.y ?? 0) 应该等于文档 y 减滚动量")
    }

    // MARK: - 斜体 / 粗斜体

    /// 渲染一段 markdown，取指定文字所在位置的字体字形特征（粗 / 斜）
    private func fontTraits(for needle: String, in markdown: String) -> UIFontDescriptor.SymbolicTraits? {
        let tv = makeEditor(markdown)
        let text = tv.textStorage.string as NSString
        let range = text.range(of: needle)
        guard range.location != NSNotFound,
              let font = tv.textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont else {
            return nil
        }
        return font.fontDescriptor.symbolicTraits
    }

    func testBoldItalicAndNestedItalic() {
        let source = "这是 ***粗斜体***，以及 **包含 *嵌套斜体* 的粗体**。"

        let boldItalic = fontTraits(for: "粗斜体", in: source)
        XCTAssertNotNil(boldItalic, "渲染结果里找不到「粗斜体」")
        XCTAssertTrue(boldItalic?.contains(.traitBold) == true, "***粗斜体*** 应该同时粗")
        XCTAssertTrue(boldItalic?.contains(.traitItalic) == true, "***粗斜体*** 应该同时斜")

        let nested = fontTraits(for: "嵌套斜体", in: source)
        XCTAssertTrue(nested?.contains(.traitBold) == true, "** 里的 *嵌套斜体* 应该继承外层的粗")
        XCTAssertTrue(nested?.contains(.traitItalic) == true, "** 里的 *嵌套斜体* 应该是斜的")

        let boldOnly = fontTraits(for: "的粗体", in: source)
        XCTAssertTrue(boldOnly?.contains(.traitBold) == true, "**包含 ... 的粗体** 整体应该是粗的")
        XCTAssertFalse(boldOnly?.contains(.traitItalic) == true, "嵌套斜体结束后，后面的粗体不该还是斜的")

        let plain = fontTraits(for: "这是", in: source)
        XCTAssertFalse(plain?.contains(.traitBold) == true, "普通正文不该是粗的")
        XCTAssertFalse(plain?.contains(.traitItalic) == true, "普通正文不该是斜的")
    }

    /// 斜体里的**中文**要换上带仿斜矩阵的字体（中文回退字体没有真斜体，
    /// 不掰一下汉字歪不了），**英文**保持真斜体、不叠矩阵（叠了会歪过头）。
    ///
    /// ### 防的是什么回归
    /// ① 只推了字体特征、没做中文仿斜 → 中文看起来「斜体没生效」；
    /// ② 图省事整段加仿斜 → 英文双重倾斜。两条一起锁。
    func testItalicSlantsCJKAndKeepsLatinUntouched() {
        let source = "*斜体 English*"
        let tv = makeEditor(source)
        let text = tv.textStorage.string as NSString

        let cjkRange = text.range(of: "斜体")
        let latinRange = text.range(of: "English")
        XCTAssertNotEqual(cjkRange.location, NSNotFound)
        XCTAssertNotEqual(latinRange.location, NSNotFound)

        let cjkFont = tv.textStorage.attribute(.font, at: cjkRange.location, effectiveRange: nil) as? UIFont
        let latinFont = tv.textStorage.attribute(.font, at: latinRange.location, effectiveRange: nil) as? UIFont

        // 英文：真斜体
        XCTAssertTrue(latinFont?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true,
                      "英文应该用真斜体字体")
        // 中文：字体和英文那个「真斜体」不一样 —— 说明被换成了带仿斜矩阵的版本。
        // 没做仿斜的话，中文区间拿到的字体和英文完全相同，这条就会挂
        XCTAssertNotEqual(cjkFont, latinFont,
                          "中文没有被掰歪（字体和英文的真斜体一模一样），斜体对中文等于没生效")

        // 两个字体应该同族（仿斜矩阵只改矩阵，不改字体名）
        XCTAssertEqual(cjkFont?.fontName, latinFont?.fontName,
                       "仿斜只该加矩阵，不该把中文换成别的字体")
    }

    /// 粗斜体（`***x***`）里的中文：既要保留粗，也要被掰歪。
    ///
    /// ### 防的是什么回归
    /// 做仿斜时如果把整段字体重建成了「只有矩阵没有粗」的版本，
    /// 粗斜体会退化成细斜 —— 这条锁住「粗 + 歪」两个特征同时在场。
    func testBoldItalicCJKKeepsBoldAndSlant() throws {
        let tv = makeEditor("***粗斜体***")
        let text = tv.textStorage.string as NSString
        let range = text.range(of: "粗斜体")
        XCTAssertNotEqual(range.location, NSNotFound)

        let font = try XCTUnwrap(tv.textStorage.attribute(.font, at: range.location,
                                                          effectiveRange: nil) as? UIFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold),
                      "粗斜体的中文必须还是粗的")
        // 普通的「粗 + 斜」字体（没矩阵）。中文现在拿到的字体应该和它不一样 —— 不一样才说明矩阵加上了
        let plainBoldItalic = themeBodyFont.adding(.traitBold).adding(.traitItalic)
        XCTAssertNotEqual(font, plainBoldItalic,
                          "中文粗斜体应该带仿斜矩阵（和普通粗斜字体不同），否则汉字歪不了")
    }

    /// 测试用的正文基准字体（和 MarkdownTheme.default 里的取法保持一致）
    private var themeBodyFont: UIFont { .preferredFont(forTextStyle: .body) }

    /// 背景层里实际铺上去的那些 view 的 frame（测试里用它看渲染结果对不对）
    private func backgroundFrames(of textView: MarkdownTextView) -> [CGRect] {
        for subview in textView.subviews {
            if let layer = subview as? CodeBlockBackgroundLayer { return layer.subviews.map(\.frame) }
        }
        return []
    }

    // MARK: - 颜色：有序列表序号 / 引用正文

    /// 有序列表的「数字 + 点」必须走 `orderedListMarkerColor`，改 `markerColor` 不能动它。
    ///
    /// ### 防的是什么回归
    /// 这两个色以前是同一个变量（`markerColor`），想单独调序号颜色就只能连 `#`、`- `
    /// 一起改。拆开后这里锁住「改 markerColor 不影响序号，改 orderedListMarkerColor 只动序号」。
    func testOrderedListMarkerUsesOwnColor() {
        let source = "1. 第一项\n2. 第二项\n"
        let tv = makeEditor(source)
        tv.renderer.theme.markerColor = .red          // 别的语法标记全变红
        tv.renderer.theme.orderedListMarkerColor = .blue
        tv.setMarkdown(source)                        // 换主题后要重新渲染一次才生效

        let text = tv.textStorage.string as NSString
        let marker = text.range(of: "1.")
        XCTAssertNotEqual(marker.location, NSNotFound, "渲染结果里应该能找到有序列表的序号")

        let color = tv.textStorage.attribute(.foregroundColor,
                                             at: marker.location,
                                             effectiveRange: nil) as? UIColor
        XCTAssertEqual(color, .blue,
                       "有序列表序号应该用 orderedListMarkerColor，不受 markerColor 影响（现在是 \(String(describing: color))）")
    }

    /// 引用里只有 `>` 是灰色，正文文字走 `quoteTextColor`（默认和正文同色）。
    func testQuoteTextUsesOwnColor() {
        let tv = makeEditor("> 引用正文\n")
        let theme = tv.renderer.theme
        XCTAssertEqual(theme.quoteTextColor, theme.textColor,
                       "默认引用正文应该和正文同色，想让它淡一点要显式改 quoteTextColor")

        let text = tv.textStorage.string as NSString

        // 1) 行首的 `>` 仍然是弱化灰（`markerColor`）
        let marker = text.range(of: ">")
        XCTAssertNotEqual(marker.location, NSNotFound)
        let markerColor = tv.textStorage.attribute(.foregroundColor,
                                                   at: marker.location,
                                                   effectiveRange: nil) as? UIColor
        XCTAssertEqual(markerColor, theme.markerColor,
                       "引用行首的 > 应该还是弱化灰，实际：\(String(describing: markerColor))")

        // 2) 引用正文用 quoteTextColor，不是灰色、也不是系统次要色
        let body = text.range(of: "引用正文")
        XCTAssertNotEqual(body.location, NSNotFound)
        let bodyColor = tv.textStorage.attribute(.foregroundColor,
                                                 at: body.location,
                                                 effectiveRange: nil) as? UIColor
        XCTAssertEqual(bodyColor, theme.quoteTextColor,
                       "引用正文应该用 quoteTextColor，实际：\(String(describing: bodyColor))")
    }

    /// 「导出成图片」的核心保证：截出来的图必须覆盖**整篇内容**，而不是只有屏幕上可见的那一屏
    func testFullContentImageCoversWholeDocument() {
        // 视口故意开得很小（300x400），文档内容远超一屏
        let editor = MarkdownTextView()
        editor.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        // 纯文本文档撑高度，不掺图片（图片是异步加载的，时序不好控）
        let long = (1...80).map { "第 \($0) 段：这是一段用来撑高度的普通文本。" }
            .joined(separator: "\n\n")
        editor.setMarkdown(long)
        editor.layoutIfNeeded()

        guard let image = editor.renderFullContentImage() else {
            return XCTFail("导出长图返回了 nil")
        }

        // 像素高度要明显超过 400pt 的视口，说明屏幕外的内容也被画进去了
        let pixelHeight = image.size.height * image.scale
        XCTAssertGreaterThan(pixelHeight, 400, "导出的图只有 \(Int(pixelHeight))px，没覆盖到全文")

        // 宽度应该和内容宽度一致（只截编辑器，不带左右留白差异）
        XCTAssertEqual(image.size.width, editor.contentSize.width, accuracy: 2,
                       "导出宽度 \(image.size.width) 和内容宽度 \(editor.contentSize.width) 对不上")

        // 关键回归：原视口以下不能是纯白（曾踩过坑 —— UITextView 的 layer 缓存只有
        // 画过的部分，直接 layer.render 导出时屏幕外全是白底）。取文档中段采样验墨
        let sampleY = max(500, image.size.height * 0.7)
        XCTAssertTrue(bandHasInk(image, yPoint: sampleY, heightPoint: 80),
                      "图片 \(Int(sampleY))pt 以下采样带全是白底，屏幕外内容没有真正渲染出来")
    }

    /// 从图片里裁一条横带，降采样后看有没有「墨」（明显暗于白底的像素）。
    /// 纯背景/纯白返回 false；只要有文字或装饰就算 true
    private func bandHasInk(_ image: UIImage, yPoint: CGFloat, heightPoint: CGFloat) -> Bool {
        guard let cg = image.cgImage else { return false }
        let scale = image.scale
        let pixelRect = CGRect(x: 0, y: yPoint * scale,
                               width: CGFloat(cg.width), height: heightPoint * scale).integral
        guard let cropped = cg.cropping(to: pixelRect) else { return false }

        // 降采样到 64x8 再读像素，够判断「有没有墨」且不怕行间空隙
        let sampleWidth = 64
        let sampleHeight = 8
        var pixels = [UInt8](repeating: 255, count: sampleWidth * sampleHeight * 4)
        guard let ctx = CGContext(data: &pixels,
                                  width: sampleWidth,
                                  height: sampleHeight,
                                  bitsPerComponent: 8,
                                  bytesPerRow: sampleWidth * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .low
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        // CGContext 原点在左下角，但这里只关心有没有暗像素，方向无所谓
        return stride(from: 0, to: pixels.count, by: 4).contains { i in
            pixels[i] < 240 && pixels[i + 1] < 240 && pixels[i + 2] < 240
        }
    }

    // MARK: - 撤销（粘贴 / 剪切）
    //
    // ### 这几条测试守的是什么
    // 编辑器存进 textStorage 的是**渲染文本**，它和源码长度不一定相等：
    // 无序列表每行行首会多一个圆点占位符（`U+FFFC`）。而系统的撤销是
    // 「按插入时的长度记账」的，插入之后我们又把这一段重渲染成另一个长度
    // （那次替换不注册撤销），这条账就失效了 —— 表现为 Cmd+Z 之后
    // 末尾残留几个字。所以粘贴/剪切改成走 `insertMarkdownSourceUndoably`：
    // 撤销记录按**整篇源码快照**登记，恢复时整篇换回去，逐字符一致。

    /// 造一个「能撤销」的编辑器。
    ///
    /// ### 为什么挂到 app 真实的窗口，而不是像别处那样自建一个
    /// `UndoManager` 是从响应者链上取的（view → superview → window → …），
    /// 游离的 view 根本拿不到它，自建的窗口也不一定有。用 app 自己的窗口最稳。
    ///
    /// ### 为什么不 `becomeFirstResponder()`
    /// 撤销记录不依赖第一响应者，只要 view 挂在窗口上就能拿到 `UndoManager`。
    /// 不去抢第一响应者是为了**别干扰别的用例**（整套跑的时候，抢了第一响应者
    /// 会影响那些依赖「光标回调」的用例，实测会让大纲那条端到端高亮测试偶发失败）。
    /// 用完请 `removeFromSuperview()`（测试里用 defer），别留在窗口上。
    private func makeUndoableEditor(_ markdown: String) -> MarkdownTextView? {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow })
                ?? UIApplication.shared.windows.first else { return nil }

        let textView = MarkdownTextView(markdown: markdown)
        textView.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        window.addSubview(textView)
        textView.layoutIfNeeded()
        return textView
    }

    /// 粘贴两行任务列表后撤销：一个字符都不许残留。
    ///
    /// ### 这个 bug 的由来（别改回去）
    /// 源码 19 个字符，渲染出来是 21 个（每行行首多一个圆点占位符）。
    /// 系统按「插入时的 19」记账，撤销时就从 21 个字符里删掉 19 个 ——
    /// 末尾正好剩下「完成」两个字。
    func testPasteTaskListCanBeUndoneCleanly() throws {
        let pasted = "- [x] 已完成\n- [ ] 未完成"

        // 先把「渲染比源码长」这件事钉住 —— 它就是系统记账会失效的根因
        let store = makeStore(pasted)
        XCTAssertEqual(store.renderedLength, (pasted as NSString).length + 2,
                       "无序列表每行行首会多一个圆点占位符，渲染结果应该比源码长 2 个字符")

        let textView = try XCTUnwrap(makeUndoableEditor(""), "拿不到可用窗口，没法验证撤销")
        defer { textView.removeFromSuperview() }

        textView.insertMarkdownSourceUndoably(pasted)
        XCTAssertEqual(textView.markdownSource, pasted, "插入之后源码应该就是粘贴的内容")

        let manager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(manager.canUndo, "插入之后必须能撤销")

        manager.undo()
        XCTAssertEqual(textView.markdownSource, "", "撤销后源码必须清空，不许残留尾巴")
        XCTAssertEqual(textView.text ?? "", "", "撤销后显示的内容也必须清空")

        manager.redo()
        XCTAssertEqual(textView.markdownSource, pasted, "重做要把粘贴的内容原样放回来")
    }

    /// 在已有文档末尾粘贴后撤销：源码要逐字符回到粘贴前的样子
    func testPasteIntoExistingDocumentCanBeUndone() throws {
        let original = "# 标题\n\n正文一段\n"
        let textView = try XCTUnwrap(makeUndoableEditor(original))
        defer { textView.removeFromSuperview() }

        // 光标移到文末再粘
        textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
        textView.insertMarkdownSourceUndoably("- [ ] 未完成")
        XCTAssertNotEqual(textView.markdownSource, original, "粘贴之后源码应该变了")

        textView.undoManager?.undo()
        XCTAssertEqual(textView.markdownSource, original, "撤销后源码必须逐字符回到原文")
    }

    /// 选中一段再粘贴（替换选区）后撤销：被替换掉的内容要回来
    func testPasteReplacingSelectionCanBeUndone() throws {
        let original = "第一行\n第二行"
        let textView = try XCTUnwrap(makeUndoableEditor(original))
        defer { textView.removeFromSuperview() }

        // 选中渲染文本开头三个字（对应源码的「第一行」）
        textView.selectedRange = NSRange(location: 0, length: 3)
        textView.insertMarkdownSourceUndoably("- [x] 已完成")
        XCTAssertTrue(textView.markdownSource.hasPrefix("- [x] 已完成"), "粘贴应该替换掉选区")

        textView.undoManager?.undo()
        XCTAssertEqual(textView.markdownSource, original, "撤销后源码必须回到原文")
    }

    /// 剪切（Cmd+X）也要能撤销 —— 剪切是我们自己做的，系统没替我们记账
    func testCutCanBeUndone() throws {
        let original = "第一段\n\n第二段\n"
        let textView = try XCTUnwrap(makeUndoableEditor(original))
        defer { textView.removeFromSuperview() }

        textView.selectedRange = NSRange(location: 0, length: 3)
        textView.cut(nil)
        XCTAssertNotEqual(textView.markdownSource, original, "剪切之后源码应该少了内容")

        textView.undoManager?.undo()
        XCTAssertEqual(textView.markdownSource, original, "撤销后源码必须回到剪切前的样子")
    }
}

// MARK: - 小工具

private extension NSRange {
    /// `range(of:)` 找不到时返回 `NSNotFound`（一个超大数），用它当范围会越界，这里统一转成 nil
    var asValid: NSRange? { location == NSNotFound ? nil : self }
}
