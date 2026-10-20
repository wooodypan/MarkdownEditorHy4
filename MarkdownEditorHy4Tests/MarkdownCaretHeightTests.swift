//
//  MarkdownCaretHeightTests.swift
//  MarkdownEditorHy4Tests
//
//  光标不能被行高倍数拉长。
//
//  ### 守的是哪个现象
//  行高倍数（lineHeightMultiple）多出来的行距在 TextKit 里全堆在文字上方，
//  系统默认按整个行盒画光标：1.7 倍时光标跟着变长，上端戳进上一行、像根竖杠压住上面的字。
//  MarkdownTextView.caretRect(for:) 现在把这段多出来的行距从光标顶部减掉、底边不动。
//
//  ### 不变式
//  同一个字，行高调大之后：
//  1. 光标高度不变（不跟着行高一起长）；
//  2. 光标相对字形的位置不变（顶边、底边到字形的距离都和默认行高时一致）。
//  合起来就是「高行高下的光标 = 默认行高下的光标」，只是整体跟着字形往下平移了。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownCaretHeightTests: XCTestCase {

    private let markdown = "这是一段普通正文，用来放光标。\n第二行正文继续。"
    private let caretOffset = 2

    /// 造一个挂到窗口上、已经排好版的编辑器
    private func makeEditor(lineHeight: CGFloat) -> MarkdownTextView {
        let tv = MarkdownTextView(markdown: markdown)
        tv.renderer.theme.lineHeightMultiple = lineHeight
        tv.setMarkdown(markdown)
        tv.frame = CGRect(x: 0, y: 0, width: 420, height: 700)
        let window = UIWindow(frame: tv.frame)
        window.addSubview(tv)
        window.makeKeyAndVisible()
        tv.layoutIfNeeded()
        tv.setNeedsLayout()
        tv.layoutIfNeeded()
        return tv
    }

    /// 光标所在行的字形盒（视图坐标，含 textContainerInset）。
    /// 和 MarkdownContentBackgroundCenteringTests.glyphBoxes 同一套算法。
    private func glyphBox(containing offset: Int, in tv: MarkdownTextView) -> (top: CGFloat, bottom: CGFloat)? {
        guard let layoutManager = tv.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else { return nil }
        let documentStart = contentStorage.documentRange.location
        var result: (top: CGFloat, bottom: CGFloat)?

        layoutManager.enumerateTextLayoutFragments(from: documentStart, options: [.ensuresLayout]) { fragment in
            guard result == nil else { return false }
            let fragmentStart = contentStorage.offset(from: documentStart, to: fragment.rangeInElement.location)
            let fragmentEnd = contentStorage.offset(from: documentStart, to: fragment.rangeInElement.endLocation)
            guard offset >= fragmentStart, offset < fragmentEnd else { return true }

            let frame = fragment.layoutFragmentFrame
            let font = (tv.textStorage.attribute(.font, at: fragmentStart, effectiveRange: nil) as? UIFont)
                ?? tv.renderer.theme.bodyFont
            var top = CGFloat.greatestFiniteMagnitude
            var bottom = -CGFloat.greatestFiniteMagnitude
            for line in fragment.textLineFragments {
                let lineBox = line.typographicBounds
                let baseline = frame.minY + lineBox.minY + line.glyphOrigin.y
                top = min(top, baseline - font.ascender)
                bottom = max(bottom, baseline - font.descender)
            }
            guard top <= bottom else { return true }
            result = (top + tv.textContainerInset.top, bottom + tv.textContainerInset.top)
            return false
        }
        return result
    }

    /// 某个行高下，光标的「高度」和「相对字形的上下位置」
    private struct CaretMetrics {
        let height: CGFloat
        let topGapToGlyph: CGFloat    // 字形顶 - 光标顶（光标盖住字形顶部多少 / 是否留白）
        let bottomGapToGlyph: CGFloat // 光标底 - 字形底
    }

    private func caretMetrics(lineHeight: CGFloat) throws -> CaretMetrics {
        let tv = makeEditor(lineHeight: lineHeight)
        let position = try XCTUnwrap(tv.position(from: tv.beginningOfDocument, offset: caretOffset))
        let caret = tv.caretRect(for: position)
        let box = try XCTUnwrap(glyphBox(containing: caretOffset, in: tv), "行高 \(lineHeight)：没量到字形盒")
        return CaretMetrics(height: caret.height,
                            topGapToGlyph: box.top - caret.minY,
                            bottomGapToGlyph: caret.maxY - box.bottom)
    }

    /// 核心：行高从 1.0 调到 1.7，光标的高度、以及它相对字形的位置都不该变。
    func testCaretStaysSameSizeRelativeToGlyphAcrossLineHeights() throws {
        let baseline = try caretMetrics(lineHeight: 1.0)
        let tall = try caretMetrics(lineHeight: 1.7)

        // ① 高度不变（没跟着行高一起被拉长）
        XCTAssertEqual(tall.height, baseline.height, accuracy: 0.6,
                       "行高 1.7 的光标高度(\(tall.height))应和默认(\(baseline.height))一致，不该被拉长")
        // 明确排除「按整个行盒画」的旧行为：那会比默认高出一大截
        XCTAssertLessThan(tall.height, baseline.height * 1.4,
                          "光标明显跟着行高变长了（\(tall.height) vs 默认 \(baseline.height)）")

        // ② 相对字形的位置不变：顶边、底边到字形的距离都和默认一致
        XCTAssertEqual(tall.topGapToGlyph, baseline.topGapToGlyph, accuracy: 0.6,
                       "光标顶边相对字形的位置变了（\(tall.topGapToGlyph) vs 默认 \(baseline.topGapToGlyph)）")
        XCTAssertEqual(tall.bottomGapToGlyph, baseline.bottomGapToGlyph, accuracy: 0.6,
                       "光标底边相对字形的位置变了（\(tall.bottomGapToGlyph) vs 默认 \(baseline.bottomGapToGlyph)）")
    }

    /// 再扫几个行高，确认不是只在 1.7 这一个点上碰巧对上。
    func testCaretHeightStableAcrossSeveralLineHeights() throws {
        let baseline = try caretMetrics(lineHeight: 1.0)
        for lineHeight in [1.2, 1.45, 1.7, 2.0] {
            let m = try caretMetrics(lineHeight: lineHeight)
            XCTAssertEqual(m.height, baseline.height, accuracy: 0.6,
                           "行高 \(lineHeight)：光标高度(\(m.height))应和默认(\(baseline.height))一致")
            XCTAssertEqual(m.bottomGapToGlyph, baseline.bottomGapToGlyph, accuracy: 0.6,
                           "行高 \(lineHeight)：光标底边相对字形的位置变了")
        }
    }
}
