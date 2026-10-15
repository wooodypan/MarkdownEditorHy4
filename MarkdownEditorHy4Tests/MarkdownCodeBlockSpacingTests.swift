//
//  MarkdownCodeBlockSpacingTests.swift
//  MarkdownEditorHy4Tests
//
//  代码块里的行距：代码行之间要只剩**自然行距**，不能再吃一份段距。
//
//  ### 守的是哪个现象
//  代码正文每行都以 `\n` 结尾，而 `\n` 在 TextKit 里就是**段落分隔符** —— 所以代码的每一行都是独立段落，段前段后各吃一份 `paragraphSpacing`（默认 12），实测行与行之间空出 **24pt**，比正文里软换行的行距大好几倍，代码块看着散成一截一截。
//  修法是把代码正文的段距归零。
//
//  围栏行（` ``` `）不能跟着一起归零：它夹在「外面的正文」和「里面的代码」中间，两个方向要的不一样 —— 对外留正常段距（代码块和上下文分开），对内只留灰底要的那点 padding（贴着灰底，紧凑）。
//  所以开 / 闭两条围栏行是**两套**样式，段前段后正好反着。这里把四个数逐个钉住。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

final class MarkdownCodeBlockSpacingTests: XCTestCase {

    private let markdown = """
    正文一段。

    ```swift
    let a = 1
    let b = 2
    ```

    正文二段。
    """

    /// 渲染一份出来（顺便把主题交回去，好对着它算期望值）
    private func render(_ markdown: String) -> (text: NSAttributedString, theme: MarkdownTheme) {
        let theme = MarkdownTheme.default
        let renderer = MarkupToAttributedRenderer(theme: theme, containerWidth: 420)
        let store = MarkdownDocumentStore(renderer: renderer)
        store.load(markdown: markdown, containerWidth: 420)
        return (store.attributedDocument, theme)
    }

    /// 落在代码块标记区间内的那几段**段落样式**（按渲染顺序：开围栏 → 代码正文 → 闭围栏）
    private func codeBlockStyles(in text: NSAttributedString) -> [(text: String, style: NSParagraphStyle)] {
        let full = NSRange(location: 0, length: text.length)
        var blockRanges: [NSRange] = []
        text.enumerateAttribute(.markdownCodeBlock, in: full, options: []) { value, range, _ in
            if value != nil { blockRanges.append(range) }
        }
        var out: [(String, NSParagraphStyle)] = []
        text.enumerateAttribute(.paragraphStyle, in: full, options: []) { value, range, _ in
            guard let style = value as? NSParagraphStyle,
                  blockRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { return }
            out.append(((text.string as NSString).substring(with: range), style))
        }
        return out
    }

    /// 代码正文：段前段后**都必须是 0** —— 行与行之间只剩字体的自然行距，和「一段长文本折行」一个观感
    func testCodeLinesHaveNoParagraphSpacing() {
        let (text, _) = render(markdown)
        let styles = codeBlockStyles(in: text)
        XCTAssertEqual(styles.count, 3, "代码块里该有三段样式：开围栏、代码正文、闭围栏（实到 \(styles.map(\.text))）")

        let code = styles.first { $0.text.contains("let a") }
        guard let code else { return XCTFail("没找到代码正文那一段（实到 \(styles.map(\.text))）") }
        XCTAssertEqual(code.style.paragraphSpacingBefore, 0, "代码正文不该有段前间距")
        XCTAssertEqual(code.style.paragraphSpacing, 0, "代码正文不该有段后间距")
    }

    /// 开围栏（```swift）：**对外**（上面那段正文）留正常段距，**对内**（第一行代码）只留灰底要的 padding
    func testOpeningFenceKeepsBlockSpacingOutsideAndPaddingInside() {
        let (text, theme) = render(markdown)
        let styles = codeBlockStyles(in: text)

        let opening = styles.first { $0.text.hasPrefix("```") && $0.text.contains("swift") }
        guard let opening else { return XCTFail("没找到开围栏那一行（实到 \(styles.map(\.text))）") }

        XCTAssertEqual(opening.style.paragraphSpacingBefore, max(theme.paragraphSpacing, theme.codeBlockVerticalPadding),
                       "开围栏上面是正文，要留正常段距")
        // 对内是两个 padding：只留一个的话 ``` 那几个字符就压进灰底了（灰底 = 代码正文那个 fragment 的框 ± padding）
        XCTAssertEqual(opening.style.paragraphSpacing, theme.codeBlockVerticalPadding * 2,
                       "开围栏下面是代码，对内留两个 padding")
    }

    /// 闭围栏（```）：和开围栏正好反过来 —— 对内（最后一行代码）留 padding，对外（下一段正文）留正常段距
    func testClosingFenceKeepsPaddingInsideAndBlockSpacingOutside() {
        let (text, theme) = render(markdown)
        let styles = codeBlockStyles(in: text)

        let closing = styles.last { $0.text.hasPrefix("```") }
        guard let closing else { return XCTFail("没找到闭围栏那一行（实到 \(styles.map(\.text))）") }
        XCTAssertFalse(closing.text.contains("swift"), "闭围栏那一行不该是 ```swift")

        XCTAssertEqual(closing.style.paragraphSpacingBefore, theme.codeBlockVerticalPadding * 2,
                       "闭围栏上面是代码，对内留两个 padding")
        XCTAssertEqual(closing.style.paragraphSpacing, max(theme.paragraphSpacing, theme.codeBlockVerticalPadding),
                       "闭围栏下面是正文，要留正常段距")
    }

    /// 未闭合的代码块（末尾没有 ```）：最后一行是**代码正文**，不能被误当成闭围栏套上围栏的样式
    func testUnclosedCodeBlockKeepsLastLineAsCode() {
        let (text, _) = render("""
        ```swift
        let a = 1
        """)
        let styles = codeBlockStyles(in: text)

        let last = styles.last
        guard let last else { return XCTFail("没渲染出代码块（实到 \(styles.map(\.text))）") }
        XCTAssertTrue(last.text.contains("let a"), "末尾那一行是代码正文，不是围栏行")
        XCTAssertEqual(last.style.paragraphSpacingBefore, 0, "代码正文不该有段前间距")
        XCTAssertEqual(last.style.paragraphSpacing, 0, "代码正文不该有段后间距")
    }
}
