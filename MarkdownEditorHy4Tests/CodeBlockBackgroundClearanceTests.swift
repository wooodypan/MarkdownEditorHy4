//
//  CodeBlockBackgroundClearanceTests.swift
//  MarkdownEditorHy4Tests
//
//  灰底矩形和「上下两行代码」的几何关系。
//
//  ### 不变式就两条
//  1. 灰底盖住代码正文，上下各留够一个 padding —— 不许切进正文；
//  2. 灰底最多只压进围栏行的 descender 空白区一个 padding，不许再往上（那片区域没有字形，``` 和语言名都画在基线以上，看不出来）。
//
//  第 2 条由「围栏行对内段距是 0」加「灰底按代码正文字形顶 ± padding 定位」共同保证：段距 0 之后围栏行底正好等于首行代码顶，所以灰底顶最多只在围栏行底上方一个 padding，对任何字号 / 行高 / 段距都成立。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

final class CodeBlockBackgroundClearanceTests: XCTestCase {

    private let markdown = """
    ```swift
    let document = Document(parsing: markdown)
    for child in document.children {
    print(type(of: child))
    }
    ```
    """

    /// 造一个「主题已经设好、并且重排过一轮」的编辑器。
    ///
    /// ⚠️ 每一种版式组合都要**新建**一个：同一个编辑器改完主题再 `setMarkdown`，装饰层有可能还停在上一轮的位置上（实测过一次，量出来的灰底比实际画的短一半）。
    private func makeEditor(fontSize: CGFloat = 17,
                            lineHeight: CGFloat = 1.0,
                            spacing: CGFloat = 12) -> MarkdownTextView {
        let textView = MarkdownTextView(markdown: markdown)
        textView.renderer.theme.bodyFont = UIFont.systemFont(ofSize: fontSize)
        textView.renderer.theme.codeFont = UIFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
        textView.renderer.theme.headingFonts = MarkdownTheme.makeHeadingFonts(baseSize: fontSize)
        textView.renderer.theme.lineHeightMultiple = lineHeight
        textView.renderer.theme.paragraphSpacing = spacing
        textView.setMarkdown(markdown)
        textView.frame = CGRect(x: 0, y: 0, width: 700, height: 900)

        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        textView.layoutIfNeeded()
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        return textView
    }

    /// 每段排版出来的**字形盒**（视图坐标），按文档顺序。
    ///
    /// 这里量的是字实际占的高度（基线 ± 字体的 ascender / descender），**不是**行盒。
    /// 行高倍数多出来的空白全在文字上方，行盒会比字形高出十几点；灰底现在按字形定位，
    /// 拿行盒来断言就会一直误判成「灰底切进了字里」。
    ///
    /// 本用例的文档只有一个代码块，所以 `[0]` 是开围栏行、`[count-1]` 是闭围栏行、中间那几个是代码正文（某一行太长被折行时，仍算作**一个**条目，取并集）。
    private func glyphBoxes(in tv: MarkdownTextView) -> [(top: CGFloat, bottom: CGFloat)] {
        guard let layoutManager = tv.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else { return [] }
        let documentStart = contentStorage.documentRange.location
        var boxes: [(top: CGFloat, bottom: CGFloat)] = []
        layoutManager.enumerateTextLayoutFragments(from: documentStart, options: [.ensuresLayout]) { fragment in
            let rect = fragment.layoutFragmentFrame
            let fragmentStart = contentStorage.offset(from: documentStart, to: fragment.rangeInElement.location)
            // 围栏行是 `bodyFont` 的弱化标记，代码正文才是 `codeFont`：按这一段自己的字体量
            let font = (tv.textStorage.attribute(.font, at: fragmentStart, effectiveRange: nil) as? UIFont)
                ?? tv.renderer.theme.codeFont
            var top = CGFloat.greatestFiniteMagnitude
            var bottom = -CGFloat.greatestFiniteMagnitude
            for lineFragment in fragment.textLineFragments {
                let lineBox = lineFragment.typographicBounds
                // glyphOrigin 相对**这一行**的盒顶，折行后的第二行还要加上 lineBox.minY
                let baseline = rect.minY + lineBox.minY + lineFragment.glyphOrigin.y
                top = min(top, baseline - font.ascender)
                bottom = max(bottom, baseline - font.descender)
            }
            if top <= bottom {
                boxes.append((top + tv.textContainerInset.top, bottom + tv.textContainerInset.top))
            }
            return true
        }
        return boxes
    }

    /// 核心用例：不管字号 / 行高 / **段落间距**怎么调，两条不变式都得成立。
    ///
    /// ### 段距这一维是必须扫的
    /// 早先灰底的上下留白是「借」了首尾围栏行自己的段间距：段距默认 12，灰底上下各有 18pt 的留白，看着很正常。
    /// 用户把段距调到 0 时，这点空隙跟着没了 —— 那时那版实现会去「跟围栏行的文字盒取大/小值」，结果算出来的灰底**切进了正文**：报障原话是「最后一个大括号 `}` 的底部超出了背景大概 10% 的高度」，实测段距 0、正文 60pt 高时 `}` 正好戳出去 6pt = 10.0%。
    /// 现在灰底按「代码正文字形顶底 ± padding」算，段距和行高都**不再掺和**；围栏行对内段距为 0，灰底顶会压进围栏行的 descender 空白区，最多一个 padding。
    func testBackgroundNeverCutsCodeTextNorBitesDeepIntoFenceLines() throws {
        let combinations: [(fontSize: CGFloat, lineHeight: CGFloat, spacing: CGFloat)] = [
            (17, 1.0, 0), (17, 1.0, 4), (17, 1.0, 8), (17, 1.0, 12), (17, 1.0, 40),
            (17, 1.6, 0), (17, 1.6, 12), (17, 2.0, 0), (17, 2.0, 12),
            (14, 1.0, 0), (14, 1.0, 12),
            (22, 1.0, 0), (22, 1.4, 0), (22, 1.4, 12),
            (28, 1.0, 0), (28, 2.0, 0), (28, 2.0, 12),
        ]

        for (fontSize, multiple, spacing) in combinations {
            let label = "字号 \(fontSize) / 行高 \(multiple) / 段距 \(spacing)"
            let tv = makeEditor(fontSize: fontSize, lineHeight: multiple, spacing: spacing)
            let boxes = glyphBoxes(in: tv)
            XCTAssertGreaterThanOrEqual(boxes.count, 3, "\(label)：至少要认出首尾围栏行和一段正文")
            let openFence = boxes[0], closeFence = boxes[boxes.count - 1]
            let firstCode = boxes[1], lastCode = boxes[boxes.count - 2]

            let (frames, _) = tv.computeCodeBlockFrames()
            let frame = try XCTUnwrap(frames.first?.frame, "\(label) 没算出背景")
            let padding = tv.renderer.theme.codeBlockVerticalPadding

            // ① 盖住代码正文：上下各留够一个 padding，一丁点都不许切进字里
            XCTAssertLessThanOrEqual(
                frame.minY, firstCode.top - padding + 0.5,
                "\(label)：灰底顶(\(frame.minY))没给首行代码留够 padding（字顶 \(firstCode.top)，该 ≤ \(firstCode.top - padding)）")
            XCTAssertGreaterThanOrEqual(
                frame.maxY, lastCode.bottom + padding - 0.5,
                "\(label)：灰底底(\(frame.maxY))切进了末行代码（字底 \(lastCode.bottom)，该 ≥ \(lastCode.bottom + padding)）"
                + " —— 段距调小以后灰底会往上缩，就是这里戳出去的")

            // ② 灰底最多压进围栏行的 descender 空白区（约一个 padding，围栏对内段距 0 之后就是这个形态），再往上就不对了
            // 多给 1pt 是留给字体测量的误差：围栏行用正文字体、代码行用等宽字体，两边的 ascender / descender 差零点几点
            XCTAssertGreaterThanOrEqual(
                frame.minY, openFence.bottom - padding - 1,
                "\(label)：灰底顶(\(frame.minY))压进 ` ```swift ` 太深了（围栏字底 \(openFence.bottom)，最多允许到 \(openFence.bottom - padding)）")
            XCTAssertLessThanOrEqual(
                frame.maxY, closeFence.top + padding + 1,
                "\(label)：灰底底(\(frame.maxY))压进收尾 ` ``` ` 太深了（围栏字顶 \(closeFence.top)，最多允许到 \(closeFence.top + padding)）")
        }
    }

    /// 灰底正好贴着代码正文外扩一个 padding：上下都是「文字盒 ± padding」，不再掺进段距。
    ///
    /// ### 为什么上下各只有一个 padding（以前是两个 padding + 段距）
    /// 代码正文的段距归零之后（行与行之间只剩自然行距，见 `MarkdownCodeBlockSpacingTests`），
    /// 灰底就只按首末行的**字形**顶底外扩一个 padding —— 行高倍数多出来的空白堆在文字上方，按字形量才不会把它算进灰底，文字因此上下留白相等。
    /// 多出来的那段留白由围栏行对内段距为 0 让出来：围栏行底正好等于首行代码顶，灰底上沿只会压进围栏行没有字形的 descender 区域。
    func testBackgroundSitsOnePaddingOutsideCodeText() throws {
        let tv = makeEditor()
        XCTAssertEqual(tv.renderer.theme.paragraphSpacing, 12, accuracy: 0.01, "默认段落间距应为 12")

        let boxes = glyphBoxes(in: tv)
        let frame = try XCTUnwrap(tv.computeCodeBlockFrames().frames.first?.frame)
        let padding = tv.renderer.theme.codeBlockVerticalPadding

        XCTAssertEqual(frame.minY, boxes[1].top - padding, accuracy: 0.5,
                       "默认设置下灰底顶 = 首行代码文字顶 - padding")
        XCTAssertEqual(frame.maxY, boxes[boxes.count - 2].bottom + padding, accuracy: 0.5,
                       "默认设置下灰底底 = 末行代码文字底 + padding")
    }

    /// 空代码块（开围栏紧接着闭围栏）依旧不铺背景 —— 顺带守住改动没在这儿画出个怪框
    func testEmptyCodeBlockStillHasNoBackground() {
        let tv = makeEditor()
        tv.setMarkdown("```\n```\n")
        tv.layoutIfNeeded()
        let (frames, _) = tv.computeCodeBlockFrames()
        XCTAssertTrue(frames.isEmpty, "空代码块不该有背景")
    }
}
