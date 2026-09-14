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

    /// 只有**多行的块**才挂折叠锚点；单行块（标题、单行段落）不该有
    func testOnlyMultiLineBlocksHaveFoldDisclosure() {
        let store = makeStore(sample)

        var multiLine = 0
        for block in store.blocks {
            // 块的源码自带结尾换行，先 trim 掉再数行数（否则 `# 标题一\n\n` 会被算成 3 行）
            let trimmed = block.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            let isMultiLine = trimmed.contains("\n")

            // 找块里的折叠锚点（打在第一个非空白字符上的那个标记）
            let anchor = (0..<block.renderedLength)
                .compactMap { block.renderedContent.attribute(.markdownFoldAnchor,
                                                              at: $0,
                                                              effectiveRange: nil) }
                .compactMap { $0 as? FoldAnchorInfo }
                .first

            XCTAssertEqual(anchor != nil, isMultiLine,
                           "块「\(block.kindDescription)」\(isMultiLine ? "有多行" : "只有一行")，折叠锚点的存在情况不对")

            if let anchor {
                XCTAssertFalse(anchor.isCollapsed, "初始状态应该是展开的")
                XCTAssertEqual(anchor.blockID, block.id,
                               "锚点必须记住自己属于哪个块，否则点了不知道折叠谁")
                multiLine += 1
            }
        }
        XCTAssertGreaterThan(multiLine, 2, "示例文档里应该有多行块（列表 / 引用 / 代码块）")
    }

    /// 折叠三角**不能占字符位**（用户报的就是这个：块首插一个 attachment 画三角，
    /// 第一行被推歪，第二行起还按原缩进排，多行左边缘就对不齐了）。
    ///
    /// 现在三角画在正文左边的装订线里，文本流里一个多余字符都没有 ——
    /// 这条测试守的是「打锚点这个动作不改变文本结构」。
    func testFoldDisclosureDoesNotOccupyCharacterPosition() {
        let store = makeStore(sample)
        let renderer = MarkupToAttributedRenderer(theme: .default, containerWidth: 600)

        var checked = 0
        for block in store.blocks {
            let trimmed = block.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("\n") else { continue }

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
        XCTAssertGreaterThan(checked, 2, "示例文档里应该有多行块")
    }

    /// 折叠之后块尾要留着换行，否则下一个块会直接贴在「⋯」后面（一行挤两块）
    func testCollapsedBlockEndsWithLineBreak() {
        let store = makeStore(sample)

        guard let index = store.blocks.firstIndex(where: { $0.kindDescription.contains("List") }) else {
            return XCTFail("示例文档里找不到列表块")
        }
        store.toggleCollapse(blockAt: index)

        let rendered = store.blocks[index].renderedContent.string as NSString
        XCTAssertTrue(rendered.hasSuffix("\n"),
                      "折叠块的渲染内容必须以换行结尾，否则下一块会接在后面，实际是：\(rendered)")
    }

    /// 折叠之后「全选复制 === 源码」必须依然成立：折叠只是视图状态，源码一个字没少
    func testCollapsedBlockStillCopiesFullSource() {
        let source = sample
        let store = makeStore(source)

        guard let index = store.blocks.firstIndex(where: { $0.kindDescription.contains("List") }) else {
            return XCTFail("示例文档里找不到列表块")
        }

        let lengthBefore = store.renderedLength
        XCTAssertNotNil(store.toggleCollapse(blockAt: index), "折叠应该成功")
        XCTAssertTrue(store.blocks[index].isCollapsed, "折叠状态没写回块")
        XCTAssertLessThan(store.renderedLength, lengthBefore, "折叠后渲染长度应该变短")

        // 1) 源码一个字都不能变
        XCTAssertEqual(store.sourceDocument, source, "折叠不能改动源码")

        // 2) 折叠着全选复制，拿到的依然是完整源码（靠占位符那一个字符位吐出整块内容）
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
        let source = sample
        let store = makeStore(source)
        let lengthBefore = store.renderedLength

        // 只有多行的块能折叠，挑列表块
        guard let index = store.blocks.firstIndex(where: { $0.kindDescription.contains("List") }) else {
            return XCTFail("示例文档里找不到列表块")
        }

        store.toggleCollapse(blockAt: index)
        store.toggleCollapse(blockAt: index)

        XCTAssertFalse(store.blocks[index].isCollapsed, "折回来应该是展开状态")
        XCTAssertEqual(store.renderedLength, lengthBefore, "折叠再展开应该回到原来的长度")
        XCTAssertEqual(store.sourceDocument, source, "来回切一次不能改动源码")

        let restored = store.sourceText(forRenderedRange: fullRenderedRange(store))
        XCTAssertEqual(restored, source, firstDifference(source, restored))
    }

    /// 在折叠的块里编辑一个字，折叠状态不能丢（否则「折叠一段 → 敲个字 → 它自己展开了」很烦人）
    func testCollapseStateSurvivesEditingInsideBlock() {
        let store = makeStore("- 列表项一\n- 列表项二\n\n尾部段落。\n")

        // 第一块是两行的列表，能折叠
        XCTAssertTrue(store.blocks[0].sourceText.contains("\n"), "列表块应该是多行的")
        store.toggleCollapse(blockAt: 0)
        XCTAssertTrue(store.blocks[0].isCollapsed, "列表块应该被折叠了")

        // 在块尾敲一个字：块的源码起点和内容都没变，折叠状态应该继承下来。
        // （注意别在块首插字符 —— `X- 列表项一` 会被 markdown 解析成段落 + 新列表，
        //   原来的块被拆开，这个测试就测不到继承逻辑了）
        let caret = NSMaxRange(store.blocks[0].renderedRange)
        store.applyEdit(inRenderedRange: NSRange(location: caret, length: 0),
                        replacementText: "X",
                        containerWidth: 600)

        XCTAssertTrue(store.blocks[0].isCollapsed,
                      "在块内部编辑不应该把折叠状态弄丢，实际状态：\(store.blocks.map(\.isCollapsed))")

        // 顺便确认这个不变量依然成立
        let restored = store.sourceText(forRenderedRange: fullRenderedRange(store))
        XCTAssertEqual(restored, store.sourceDocument,
                       firstDifference(store.sourceDocument, restored))
    }

    /// 块被编辑成单行之后，必须自动展开 —— 没有按钮的话用户就再也点不回来了
    func testSingleLineBlockIsNeverCollapsed() {
        let store = makeStore("- 列表项一\n- 列表项二\n")

        store.toggleCollapse(blockAt: 0)
        XCTAssertTrue(store.blocks[0].isCollapsed, "多行列表应该能折叠")

        // 把整块替换成一行（相当于全选这个折叠块，重新输入一行字）
        store.applyEdit(inRenderedRange: store.blocks[0].renderedRange,
                        replacementText: "只有一行。\n",
                        containerWidth: 600)

        XCTAssertFalse(store.blocks[0].isCollapsed,
                       "变成单行之后必须自动展开，否则没有按钮就点不回来了")
        XCTAssertFalse(store.blocks[0].renderedContent.string.contains("\u{FFFC}"),
                       "单行块不该再有折叠按钮")
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

    /// 冷启动时界面还没建好，URL 要先攒着，等 ViewController 起来再取走
    func testDocumentOpenerKeepsPendingURL() {
        let url = URL(fileURLWithPath: "/tmp/MarkdownEditorHy4文件关联测试.md")
        MarkdownDocumentOpener.shared.handle(url: url)
        XCTAssertEqual(MarkdownDocumentOpener.shared.pendingURL, url)
        XCTAssertEqual(MarkdownDocumentOpener.shared.takePendingURL(), url)
        XCTAssertNil(MarkdownDocumentOpener.shared.takePendingURL(), "取走之后必须清空，否则下次启动会重复打开")
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

        // 字符还在原位
        XCTAssertEqual(tv.textStorage.string, "￼- [x] 已完成⏎￼- [ ] 未完成"
            .replacingOccurrences(of: "⏎", with: "\n")
            .replacingOccurrences(of: "￼", with: "\u{FFFC}"))

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

    /// 复选框矩形必须精确罩住 `[x]` 三个字符 —— 用官方 `caretRect` 做基准对照。
    ///
    /// ### 防的是什么回归
    /// `enumerateTextSegments` 给的矩形和 fragment 一样，原点在 textContainer 左上角
    /// （不含 textContainerInset）。忘了补 inset 的话按钮会整体偏移一个 inset。
    func testCheckboxFrameAlignsWithCaret() {
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
            XCTAssertEqual(frame.minX, caret.minX, accuracy: 2,
                           "`[` 字符的 x 应该和光标矩形对齐（差值大了说明 inset 换算又丢了）")
            XCTAssertEqual(frame.minY, caret.minY, accuracy: 2,
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

    /// 遮盖模式必须是默认值 —— 上次截图对比过，并列模式会把列表标记 `- ` 压在身下。
    /// 如果要改默认值，先更新这条测试和 MarkdownTheme 里的注释。
    func testCheckboxCoversLiteralByDefault() {
        XCTAssertTrue(MarkdownTheme.default.taskList.coversCheckboxLiteral)
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

        let (frames, _) = tv.computeCodeBlockFrames()
        XCTAssertEqual(frames.count, 2)

        // 滚动停下之后的重算是异步的，轮询等它落位（最多等 3 秒）
        var placed: [CGRect] = []
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            placed = backgroundFrames(of: tv)
            if let first = placed.first,
               abs(first.origin.y - (frames.last!.frame.origin.y - offsetY)) < 2 { break }
        }

        XCTAssertFalse(placed.isEmpty, "滚到 1500 时第二个代码块应该还在可见范围内")
        XCTAssertEqual(placed.first?.origin.y ?? 0,
                       frames.last!.frame.origin.y - offsetY,
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
