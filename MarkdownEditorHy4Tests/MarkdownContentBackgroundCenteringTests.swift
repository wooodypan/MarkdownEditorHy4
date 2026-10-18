//
//  MarkdownContentBackgroundCenteringTests.swift
//  MarkdownEditorHy4Tests
//
//  代码块灰底 / 引用竖条里的文字是不是**垂直居中**。
//
//  ### 守的是哪个现象
//  行高调到 1.7、段间距调到 0 时，灰底和引用条的上沿离第一行字很远、
//  下沿却贴着最后一行字 —— 文字整体偏向背景的底部。
//
//  根因是 TextKit 把 lineHeightMultiple 多出来的行距**全堆在文字上方**：
//  一行 34 点高的行盒里，17 号字只占最下面 20 点。背景原先按整个行盒铺，
//  于是上方多出十几点、下方只剩贴边的零点几。
//
//  现在背景按「字形顶底 ± padding」定位（见 MarkdownTextView.textGlyphVerticalBounds），
//  这条用例就钉住「上下两段留白相等」，并且把行高 / 段距几个组合都扫一遍。
//  引用那边额外钉住留白的具体数值 = `theme.quoteBarVerticalPadding`（默认 8pt），
//  防止以后有人只改了主题常量、算矩形时忘了用。
//

import XCTest
import UIKit
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownContentBackgroundCenteringTests: XCTestCase {

    private let markdown = """
    > 引用第一行
    > 引用第二行

    ```swift
    let first = 1
    let second = 2
    ```
    """

    private struct GlyphBox {
        let range: NSRange
        let top: CGFloat
        let bottom: CGFloat
    }

    /// 造一个挂到窗口上、已经排好版的编辑器
    private func makeEditor(lineHeight: CGFloat, spacing: CGFloat) -> MarkdownTextView {
        let tv = MarkdownTextView(markdown: markdown)
        tv.renderer.theme.lineHeightMultiple = lineHeight
        tv.renderer.theme.paragraphSpacing = spacing
        tv.renderer.theme.showsQuoteBackground = true
        tv.setMarkdown(markdown)
        tv.frame = CGRect(x: 0, y: 0, width: 420, height: 900)

        let window = UIWindow(frame: tv.frame)
        window.addSubview(tv)
        window.makeKeyAndVisible()
        tv.layoutIfNeeded()
        tv.setNeedsLayout()
        tv.layoutIfNeeded()
        return tv
    }

    /// 每个 fragment 的**字形盒**（视图坐标）。
    ///
    /// 和 `CodeBlockBackgroundClearanceTests.glyphBoxes` 一样：基线 = fragment 顶 + 行盒顶 + glyphOrigin，
    /// 上下再按字体 ascender / descender 展开。不用行盒，因为行盒把「文字上方那段行距」也算进来了，
    /// 正好会把这次要验的不对称掩盖掉。
    private func glyphBoxes(in tv: MarkdownTextView) -> [GlyphBox] {
        guard let layoutManager = tv.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else { return [] }
        let documentStart = contentStorage.documentRange.location
        var boxes: [GlyphBox] = []

        layoutManager.enumerateTextLayoutFragments(from: documentStart, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let fragmentStart = contentStorage.offset(from: documentStart, to: fragment.rangeInElement.location)
            let fragmentEnd = contentStorage.offset(from: documentStart, to: fragment.rangeInElement.endLocation)
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

            if top <= bottom {
                boxes.append(GlyphBox(range: NSRange(location: fragmentStart, length: max(0, fragmentEnd - fragmentStart)),
                                      top: top + tv.textContainerInset.top,
                                      bottom: bottom + tv.textContainerInset.top))
            }
            return true
        }
        return boxes
    }

    /// 整篇里带某个属性的第一段区间（代码块 / 引用）
    private func firstRange(in tv: MarkdownTextView, attribute: NSAttributedString.Key) -> NSRange? {
        var found: NSRange?
        let full = NSRange(location: 0, length: tv.textStorage.length)
        tv.textStorage.enumerateAttribute(attribute, in: full, options: []) { value, range, stop in
            guard value != nil else { return }
            found = range
            stop.pointee = true
        }
        return found
    }

    /// 一个区间按行切开（含行尾换行），和 `MarkdownTextView.fenceLineRanges` 的切法一致
    private func lineRanges(in text: NSString, range: NSRange) -> [NSRange] {
        var lines: [NSRange] = []
        var cursor = range.location
        let end = NSMaxRange(range)
        while cursor < end {
            let line = text.lineRange(for: NSRange(location: cursor, length: 0))
            let lineEnd = min(NSMaxRange(line), end)
            guard lineEnd > cursor else { break }
            lines.append(NSRange(location: cursor, length: lineEnd - cursor))
            cursor = lineEnd
        }
        return lines
    }

    private func intersects(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSIntersectionRange(lhs, rhs).length > 0
    }

    /// 核心用例：行高 1.7 / 段距 0 时，代码灰底和引用条的上下留白必须相等；别的组合也顺带扫一遍。
    func testCodeAndQuoteBackgroundsCenterTextVertically() throws {
        for lineHeight in [1.0, 1.7, 2.0] {
            for spacing in [0.0, 12.0] {
                let label = "行高 \(lineHeight) / 段距 \(spacing)"
                let tv = makeEditor(lineHeight: lineHeight, spacing: spacing)
                let boxes = glyphBoxes(in: tv)
                let text = tv.textStorage.string as NSString
                let padding = tv.renderer.theme.codeBlockVerticalPadding

                // ---- 代码块：灰底 = 首行代码字形顶 - padding … 末行代码字形底 + padding ----
                let codeRange = try XCTUnwrap(firstRange(in: tv, attribute: .markdownCodeBlock),
                                              "\(label)：没找到代码块标记")
                let codeLines = lineRanges(in: text, range: codeRange)
                XCTAssertGreaterThanOrEqual(codeLines.count, 3, "\(label)：代码块至少要有两条围栏 + 一行正文")
                let firstBody = codeLines[1]
                let lastBody = codeLines[codeLines.count - 2]
                let codeBodyBoxes = boxes.filter {
                    intersects($0.range, firstBody) || intersects($0.range, lastBody)
                }
                let firstCode = try XCTUnwrap(codeBodyBoxes.first, "\(label)：没量到代码正文")
                let lastCode = try XCTUnwrap(codeBodyBoxes.last, "\(label)：没量到代码正文")
                let codeFrame = try XCTUnwrap(tv.computeCodeBlockFrames().frames.first?.frame,
                                              "\(label)：没算出代码灰底")

                XCTAssertEqual(codeFrame.minY, firstCode.top - padding, accuracy: 0.6,
                               "\(label)：灰底顶应当 = 首行代码字形顶 - padding")
                XCTAssertEqual(codeFrame.maxY, lastCode.bottom + padding, accuracy: 0.6,
                               "\(label)：灰底底应当 = 末行代码字形底 + padding")

                // ---- 引用：竖条 / 内容底色吃同一批矩形，上下留白也必须相等 ----
                let quoteRange = try XCTUnwrap(firstRange(in: tv, attribute: .markdownQuoteChain),
                                               "\(label)：没找到引用标记")
                let quoteBoxes = boxes.filter { intersects($0.range, quoteRange) }
                let firstQuote = try XCTUnwrap(quoteBoxes.first, "\(label)：没量到引用文字")
                let lastQuote = try XCTUnwrap(quoteBoxes.last, "\(label)：没量到引用文字")
                let bar = try XCTUnwrap(tv.quoteBarFrames.first, "\(label)：没算出引用竖条")

                let quoteTopGap = firstQuote.top - bar.frame.minY
                let quoteBottomGap = bar.frame.maxY - lastQuote.bottom
                let quotePadding = tv.renderer.theme.quoteBarVerticalPadding
                XCTAssertEqual(quoteTopGap, quoteBottomGap, accuracy: 0.6,
                               "\(label)：引用条上留白(\(quoteTopGap))和下留白(\(quoteBottomGap))应当相等")
                XCTAssertEqual(quoteTopGap, quotePadding, accuracy: 0.6,
                               "\(label)：引用条上留白应当等于主题里的 quoteBarVerticalPadding")
                XCTAssertEqual(quoteBottomGap, quotePadding, accuracy: 0.6,
                               "\(label)：引用条下留白应当等于主题里的 quoteBarVerticalPadding")
            }
        }
    }
}
