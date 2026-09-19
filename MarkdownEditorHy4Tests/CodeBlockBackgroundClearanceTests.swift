//
//  CodeBlockBackgroundClearanceTests.swift
//  MarkdownEditorHy4Tests
//
//  灰底矩形和「上下两行代码」的几何关系。
//
//  ### 不变式就两条
//  1. 灰底盖住代码正文，上下各留够一个 padding —— 不许切进正文；
//  2. 灰底不碰首尾围栏行（` ```swift ` / ` ``` `）的文字。
//
//  这两条都靠「围栏行的段落样式自带一个 padding 的段间距」保证（见 MarkdownTheme.codeFenceParagraphStyle），所以对任何字号 / 行高 / 段距都成立，不需要在算矩形的时候再做夹取。
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

    /// 每段排版出来的文字盒（视图坐标），按文档顺序。
    /// 本用例的文档只有一个代码块，所以 `[0]` 是开围栏行、`[count-1]` 是闭围栏行、中间那几个是代码正文（某一行太长被折行时，仍算作**一个**条目，取并集）。
    private func lineBoxes(in tv: MarkdownTextView) -> [(top: CGFloat, bottom: CGFloat)] {
        guard let layoutManager = tv.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else { return [] }
        let documentStart = contentStorage.documentRange.location
        var boxes: [(top: CGFloat, bottom: CGFloat)] = []
        layoutManager.enumerateTextLayoutFragments(from: documentStart, options: [.ensuresLayout]) { fragment in
            let rect = fragment.layoutFragmentFrame
            var top = CGFloat.greatestFiniteMagnitude
            var bottom = -CGFloat.greatestFiniteMagnitude
            for lineFragment in fragment.textLineFragments {
                top = min(top, rect.minY + lineFragment.typographicBounds.minY)
                bottom = max(bottom, rect.minY + lineFragment.typographicBounds.maxY)
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
    /// 灰底的上下留白是「借」了首尾围栏行自己的段间距：段距默认 12 恰好是两个 padding，所以灰底上下各有 18pt 的留白，看着很正常。
    /// 用户把段距调到 0 时，这点空隙跟着没了 —— 早先那版实现会去「跟围栏行的文字盒取大/小值」，结果夹出来的灰底**切进了正文**：报障原话是「最后一个大括号 `}` 的底部超出了背景大概 10% 的高度」，实测段距 0、正文 60pt 高时 `}` 正好戳出去 6pt = 10.0%。
    func testBackgroundNeverCutsCodeTextNorTouchesFenceLines() throws {
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
            let boxes = lineBoxes(in: tv)
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

            // ② 不碰围栏行：撑住这条的是围栏行段落样式自带的段间距下限
            XCTAssertGreaterThanOrEqual(
                frame.minY, openFence.bottom - 0.5,
                "\(label)：灰底顶(\(frame.minY))压到了 ` ```swift ` 这行文字(\(openFence.bottom))")
            XCTAssertLessThanOrEqual(
                frame.maxY, closeFence.top + 0.5,
                "\(label)：灰底底(\(frame.maxY))压到了收尾 ` ``` ` 那行文字(\(closeFence.top))")
        }
    }

    /// 段距是**默认值**（12）时，灰底的位置必须和这次修复之前完全一致 —— 这次只该动「段距小于一个 padding」的场景，默认观感一格都不许动。
    /// 这条同时把「默认主题下正文自己的段间距也算进灰底留白」这个原有行为钉住
    func testDefaultSettingsClearanceUnchanged() throws {
        let tv = makeEditor()
        let spacing = tv.renderer.theme.paragraphSpacing
        XCTAssertEqual(spacing, 12, accuracy: 0.01, "默认段落间距应为 12，下面的容差是按它算的")

        let boxes = lineBoxes(in: tv)
        let frame = try XCTUnwrap(tv.computeCodeBlockFrames().frames.first?.frame)
        let padding = tv.renderer.theme.codeBlockVerticalPadding

        XCTAssertEqual(frame.minY, boxes[1].top - spacing - padding, accuracy: 0.5,
                       "默认设置下灰底顶 = 首行代码文字顶 - 段距 - padding（原有行为）")
        XCTAssertEqual(frame.maxY, boxes[boxes.count - 2].bottom + spacing + padding, accuracy: 0.5,
                       "默认设置下灰底底 = 末行代码文字底 + 段距 + padding（原有行为）")
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
