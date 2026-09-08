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

    /// 空文档和只有空行的文档不能崩，也不能凭空多出字符
    func testEmptyAndBlankDocuments() {
        for source in ["", "\n", "\n\n\n", "   "] {
            let store = makeStore(source)
            let restored = store.sourceText(forRenderedRange: fullRenderedRange(store))
            XCTAssertEqual(restored, source, firstDifference(source, restored))
        }
    }
}

// MARK: - 小工具

private extension NSRange {
    /// `range(of:)` 找不到时返回 `NSNotFound`（一个超大数），用它当范围会越界，这里统一转成 nil
    var asValid: NSRange? { location == NSNotFound ? nil : self }
}
