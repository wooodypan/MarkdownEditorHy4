//
//  MarkdownQuoteSpacingTests.swift
//  MarkdownEditorHy4Tests
//
//  引用块里的行距：同一段话折出来的那几行要只剩**自然行距**，不能凭空多吃一份段距。
//
//  ### 守的是哪个现象
//  引用的每一行都以 `>` 开头，行与行之间那个 `\n` 在 TextKit 里就是**段落分隔符** —— 于是「一段话写到换行就换个 `>` 接着写」看着是一段，排版上却是好几个段落，行与行之间要多出一份 `paragraphSpacing`（默认 12），比正文里同一段折行的行距松一大截，整块引用散成一节一节。
//
//  ### 哪两种换行必须分开对待
//  1. **段落内部的折行**（源码里就是一个 `\n`，AST 里是 SoftBreak / LineBreak）—— 要收紧；
//  2. **段落与段落之间**（中间隔一行只有一个 `>`）—— 那份段距是排版要的，必须留着。
//  两种换行渲染出来都只是一个 `\n`，只能靠 AST 里 Paragraph 的源码范围分辨（详见 `tightenQuoteWrappedLines`）。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

final class MarkdownQuoteSpacingTests: XCTestCase {

    /// 文档里刻意混了三样东西：引用里的**段内折行**、引用里的**两个段落**（中间那行只有一个 `>`）、以及引用外的正文。
    private let markdown = """
    正文第一行 AAA
    正文第二行 BBB

    > 引用第一段第一行 CCC
    > 引用第一段第二行 DDD
    >
    > 引用第二段 EEE

    正文第三段 FFF
    """

    private func render(_ markdown: String) -> (text: NSAttributedString, theme: MarkdownTheme) {
        let theme = MarkdownTheme.default
        let renderer = MarkupToAttributedRenderer(theme: theme, containerWidth: 420)
        let store = MarkdownDocumentStore(renderer: renderer)
        store.load(markdown: markdown, containerWidth: 420)
        return (store.attributedDocument, theme)
    }

    /// 引用块覆盖到的那些段落样式 run（按出现顺序）
    private func quoteStyles(in text: NSAttributedString) -> [(text: String, style: NSParagraphStyle)] {
        let full = NSRange(location: 0, length: text.length)
        var quoteRanges: [NSRange] = []
        text.enumerateAttribute(.markdownQuoteChain, in: full, options: []) { value, range, _ in
            if value != nil { quoteRanges.append(range) }
        }
        return styleRuns(in: text) { range in
            quoteRanges.contains(where: { NSIntersectionRange($0, range).length > 0 })
        }
    }

    private func styleRuns(in text: NSAttributedString,
                           filter: (NSRange) -> Bool) -> [(text: String, style: NSParagraphStyle)] {        let full = NSRange(location: 0, length: text.length)
        var out: [(String, NSParagraphStyle)] = []
        text.enumerateAttribute(.paragraphStyle, in: full, options: []) { value, range, _ in
            guard let style = value as? NSParagraphStyle, filter(range) else { return }
            out.append(((text.string as NSString).substring(with: range), style))
        }
        return out
    }

    /// 在 `runs` 里找唯一包含 `needle` 的那一段（一行就是一段），找不到就 fail
    private func pick(_ needle: String,
                      from runs: [(text: String, style: NSParagraphStyle)],
                      file: StaticString = #filePath,
                      line: UInt = #line) -> NSParagraphStyle? {
        let hits = runs.filter { $0.text.contains(needle) }
        guard hits.count == 1 else {
            XCTFail("含「\(needle)」的本该只命中一段，实到 \(hits.count) 段：\(runs.map(\.text))", file: file, line: line)
            return nil
        }
        return hits[0].style
    }

    /// 同一段话里换的那个 `>` 下面：**不能再有段距**，否则行距看着比正文里的软换行还松
    func testWrappedLinesInsideQuoteHaveNoParagraphSpacing() {
        let (text, _) = render(markdown)
        let runs = quoteStyles(in: text)

        let first = pick("CCC", from: runs)
        XCTAssertEqual(first?.paragraphSpacing, 0, "引用里同一段话的第一行下面不该留段距")
        XCTAssertEqual(first?.paragraphSpacingBefore, 0, "也没加段前间距")
    }

    /// 引用里**真的有两个段落**时（中间那行只有一个 `>`），那份段距是排版要的 —— 不能被一起清零
    func testParagraphBreakInsideQuoteKeepsParagraphSpacing() {
        let (text, theme) = render(markdown)
        let runs = quoteStyles(in: text)

        let lastLineOfFirstParagraph = pick("DDD", from: runs)
        XCTAssertEqual(lastLineOfFirstParagraph?.paragraphSpacing, theme.paragraphSpacing,
                       "引用里两个段落之间的段距要留着，否则引用里的分段就没了")
    }

    /// 引用最后一行到外面的正文之间照旧隔着一份段距（收的是块**内部**的行距，不是引用和上下文之间的距离）
    func testLastQuoteLineKeepsParagraphSpacingOutside() {
        let (text, theme) = render(markdown)
        let runs = quoteStyles(in: text)

        let last = pick("EEE", from: runs)
        XCTAssertEqual(last?.paragraphSpacing, theme.paragraphSpacing, "引用整块和下一段正文之间要留正常段距")
    }

    /// 只动段距，不动别的：缩进、行高都得原样留着，否则引用里套个列表 / 标题就歪了
    func testTighteningKeepsTheRestOfParagraphStyle() {
        let (text, theme) = render(markdown)
        let runs = quoteStyles(in: text)

        guard let wrapped = pick("CCC", from: runs),
              let kept = pick("DDD", from: runs) else { return }

        XCTAssertEqual(wrapped.headIndent, theme.quoteIndent, accuracy: 0.001,
                       "引用第 1 层的缩进是 quoteIndent，收紧行距时不该动它")
        XCTAssertEqual(wrapped.headIndent, kept.headIndent, accuracy: 0.001,
                       "同一层引用里所有行的缩进应当一致")
        XCTAssertEqual(wrapped.lineHeightMultiple, kept.lineHeightMultiple, accuracy: 0.001,
                       "行高倍数也不跟着改")
    }

    /// 引用**外面**的软换行不受影响 —— 这次只改引用块，别把正文一整段的折行也顺手收紧了
    func testSoftBreakOutsideQuoteKeepsParagraphSpacing() {
        let (text, theme) = render(markdown)
        let full = NSRange(location: 0, length: text.length)
        var quoteRanges: [NSRange] = []
        text.enumerateAttribute(.markdownQuoteChain, in: full, options: []) { value, range, _ in
            if value != nil { quoteRanges.append(range) }
        }

        let outside = styleRuns(in: text) { range in
            !quoteRanges.contains(where: { NSIntersectionRange($0, range).length > 0 })
        }
        let wrapped = pick("AAA", from: outside)
        XCTAssertEqual(wrapped?.paragraphSpacing, theme.paragraphSpacing, "正文里的软换行保持原样，仍是全局那份段距")
    }

    /// 嵌套引用：内层里多半也蹲着一整段话，同样该收紧
    func testNestedQuoteWrappedLinesAreAlsoTightened() {
        let (text, _) = render("""
        > 外面一层 WWW
        >
        > > 里面一层 XXX
        > > 里面接着 YYY
        """)
        let runs = quoteStyles(in: text)

        let innerFirst = pick("XXX", from: runs)
        XCTAssertEqual(innerFirst?.paragraphSpacing, 0, "嵌套引用的内层也是同一段话，行距照样收紧")
    }
}
