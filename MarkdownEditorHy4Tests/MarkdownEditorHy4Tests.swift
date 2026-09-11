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

    // MARK: - 代码块背景（文档坐标修正）

    /// 加载测试用例文档（两个代码块，第二个很长、超出好几屏）
    private func makeCodeBlockTestCaseEditor() throws -> MarkdownTextView {
        let path = "/Users/pan/Project/iOSDemo/MarkdownEditorHy4/testcase/CodeBlockBackgroundTestCase.md"
        return makeEditor(try String(contentsOfFile: path, encoding: .utf8))
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

    /// 背景层里实际铺上去的那些 view 的 frame（测试里用它看渲染结果对不对）
    private func backgroundFrames(of textView: MarkdownTextView) -> [CGRect] {
        for subview in textView.subviews {
            if let layer = subview as? CodeBlockBackgroundLayer { return layer.subviews.map(\.frame) }
        }
        return []
    }
}

// MARK: - 小工具

private extension NSRange {
    /// `range(of:)` 找不到时返回 `NSNotFound`（一个超大数），用它当范围会越界，这里统一转成 nil
    var asValid: NSRange? { location == NSNotFound ? nil : self }
}
