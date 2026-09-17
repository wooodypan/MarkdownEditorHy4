//
//  MarkdownImageSizeTests.swift
//  MarkdownEditorHy4Tests
//
//  图片显示尺寸的策略。
//
//  背景（2026-09-17）：需求是「默认保持原始比例，最大宽度 = 编辑器宽度的 50%（或固定 px），
//  小图不放大，最大高度有个上限」。
//
//  2026-09-18 改过一版：最大高度早先是「编辑器可视高度的 80%」，为此渲染层要多收一个
//  `containerHeight`、编辑器要多记一个 `renderedHeight`，窗口一拉高拉矮就整篇重排。
//  现在还原成主题里写死的**点数** `MarkdownTheme.ImageStyle.maxHeight`（默认 420），
//  跟窗口尺寸彻底无关 —— `testMaxHeightIgnoresWindowSize` 就是钉住这一点的。
//
//  ⚠️ 断言一律看 attachment 的 `bounds`：图片在文本流里只占 1 个字符位，
//  光看富文本的字符串什么也看不出来。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class MarkdownImageSizeTests: XCTestCase {

    // MARK: - 小工具

    /// 造一张**纯色** PNG 写到临时目录，用来当本地图片。
    ///
    /// ⚠️ 必须把 scale 固定成 1：`UIGraphicsImageRenderer` 默认按屏幕 scale 出图，
    /// Retina 上会画成 2 倍像素，读回来 `UIImage.size` 也翻倍，尺寸断言就对不上了。
    private func makeImageFile(width: CGFloat, height: CGFloat) throws -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("size-\(UUID().uuidString).png")
        try image.pngData()!.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// 渲染一行 `![](文件地址)`，把里面那个图片 attachment 挖出来
    private func renderAttachment(imageSize: CGSize,
                                  theme: MarkdownTheme = .default,
                                  containerWidth: CGFloat = 600) throws -> ImageAttachment {
        let url = try makeImageFile(width: imageSize.width, height: imageSize.height)
        let renderer = MarkupToAttributedRenderer(theme: theme, containerWidth: containerWidth)
        let (text, _) = renderer.render(blockSource: "![](\(url.absoluteString))\n")

        var found: ImageAttachment?
        text.enumerateAttribute(.attachment,
                                in: NSRange(location: 0, length: (text.string as NSString).length),
                                options: []) { value, _, _ in
            if let attachment = value as? ImageAttachment { found = attachment }
        }
        return try XCTUnwrap(found, "没有渲染出 ImageAttachment")
    }

    /// 宽高比，用来验证「缩放有没有把图拉变形」
    private func aspectRatio(of attachment: ImageAttachment) -> CGFloat {
        attachment.bounds.width / attachment.bounds.height
    }

    // MARK: - 默认策略：最大宽度 = 容器宽的一半

    /// 600 宽的编辑器、50% → 图片最多 292 宽（(600 − 16) × 0.5），而且比例不变
    func testDefaultMaxWidthIsHalfOfContainer() throws {
        let attachment = try renderAttachment(imageSize: CGSize(width: 400, height: 200))

        XCTAssertEqual(attachment.bounds.width, 292, accuracy: 1,
                       "默认最大宽度是可用宽度的一半，实际 \(attachment.bounds.width)")
        XCTAssertEqual(aspectRatio(of: attachment), 2.0, accuracy: 0.01,
                       "缩放必须保持原始比例，不能把图拉变形")
    }

    /// 窗口拉宽 → 图片跟着变宽（百分比模式的本来意义）
    func testWiderContainerGrowsTheImage() throws {
        let narrow = try renderAttachment(imageSize: CGSize(width: 400, height: 200),
                                          containerWidth: 600)
        let wide = try renderAttachment(imageSize: CGSize(width: 400, height: 200),
                                        containerWidth: 1000)

        XCTAssertGreaterThan(wide.bounds.width, narrow.bounds.width,
                             "按百分比算的话，窗口变宽图片也该变宽")
    }

    // MARK: - 小图不放大（需求里点名要的）

    /// 10×10 的小图不能被撑成 292 宽 —— 放大只会让它变糊
    func testSmallImageIsNotUpscaled() throws {
        let attachment = try renderAttachment(imageSize: CGSize(width: 10, height: 10))

        XCTAssertEqual(attachment.bounds.width, 10, accuracy: 0.5, "小图该按原尺寸显示")
        XCTAssertEqual(attachment.bounds.height, 10, accuracy: 0.5)
    }

    /// 10×10 的图放进 1000 宽的窗口也不放大（需求里点名的那个例子）
    func testSmallImageStaysSmallInWideWindow() throws {
        let attachment = try renderAttachment(imageSize: CGSize(width: 10, height: 10),
                                              containerWidth: 1000)

        XCTAssertEqual(attachment.bounds.width, 10, accuracy: 0.5,
                       "窗口再宽也不该把 10×10 撑大，实际 \(attachment.bounds.width)")
    }

    // MARK: - 固定宽度模式

    /// 切成「固定 200px」：不管窗口多宽，图片最多 200 宽
    func testFixedWidthModeIgnoresContainerWidth() throws {
        var theme = MarkdownTheme.default
        theme.image.maxWidthRatio = nil
        theme.image.maxWidthPoints = 200

        let attachment = try renderAttachment(imageSize: CGSize(width: 400, height: 200),
                                              theme: theme,
                                              containerWidth: 1000)

        XCTAssertEqual(attachment.bounds.width, 200, accuracy: 1,
                       "固定宽度模式下就该是 200，跟窗口宽度无关")
        XCTAssertEqual(aspectRatio(of: attachment), 2.0, accuracy: 0.01)
    }

    /// 固定宽度也不能超过「这一行实际放得下多宽」（不然会画出容器外面去）
    func testFixedWidthIsCappedByAvailableWidth() throws {
        var theme = MarkdownTheme.default
        theme.image.maxWidthRatio = nil
        theme.image.maxWidthPoints = 800

        let attachment = try renderAttachment(imageSize: CGSize(width: 1000, height: 500),
                                              theme: theme,
                                              containerWidth: 300)

        XCTAssertLessThanOrEqual(attachment.bounds.width, 300,
                                 "用户设的宽度不能让图超出编辑器，实际 \(attachment.bounds.width)")
    }

    // MARK: - 最大高度 = 主题里的固定点数

    /// 一张很长的图：宽度还有富余，但高度会被压到主题里写的那个点数
    func testMaxHeightComesFromTheme() throws {
        var theme = MarkdownTheme.default
        theme.image.maxHeight = 300

        let attachment = try renderAttachment(imageSize: CGSize(width: 100, height: 2000),
                                              theme: theme,
                                              containerWidth: 600)

        XCTAssertEqual(attachment.bounds.height, 300, accuracy: 1,
                       "最大高度就是主题里的 300 点，实际 \(attachment.bounds.height)")
        XCTAssertEqual(aspectRatio(of: attachment), 100.0 / 2000.0, accuracy: 0.01,
                       "压高度的同时比例不能变")
    }

    /// 窗口多高都跟图片无关 —— 这是「还固定点数」这一版的核心：
    /// 不用传容器高度，也就不用因为窗口拉高拉矮重排整篇文档
    func testMaxHeightIgnoresWindowSize() throws {
        let narrow = try renderAttachment(imageSize: CGSize(width: 100, height: 2000),
                                          containerWidth: 300)
        let wide = try renderAttachment(imageSize: CGSize(width: 100, height: 2000),
                                        containerWidth: 1200)

        XCTAssertEqual(narrow.bounds.height, wide.bounds.height, accuracy: 0.5,
                       "最大高度是固定点数，窗口宽窄不该影响它")
    }

    // MARK: - 加载失败的占位仍然受同一套上限管着

    // MARK: - 点击图片：能认出点到了哪张图

    /// 点在图片上要能找回来那张图；点在空白处不能误判。
    ///
    /// ### 干嘛要把它挂到真窗口上
    /// TextKit 2 不挂窗口就不排版，`layoutFragmentFrame` 全是 0 —— 那样无论怎么点都找不到。
    /// 所以这里照别的地方的做法建一个 `UIWindow` 把它装进去。
    func testTappingImageFindsTheAttachment() throws {
        let url = try makeImageFile(width: 200, height: 100)
        let textView = MarkdownTextView()
        textView.frame = CGRect(x: 0, y: 0, width: 600, height: 800)

        let window = UIWindow(frame: textView.frame)
        window.addSubview(textView)
        window.makeKeyAndVisible()
        textView.setMarkdown("![](\(url.absoluteString))\n")
        textView.layoutIfNeeded()

        let center = try XCTUnwrap(centerOfImageFragment(in: textView),
                                   "没排出图片所在的 fragment —— 布局还没做完")
        XCTAssertNotNil(textView.imageAttachment(at: center), "点在图片上却没认出来")

        // 图片下面那行是浅灰源码提示，那里不该被当成图片
        XCTAssertNil(textView.imageAttachment(at: CGPoint(x: 5, y: 780)),
                     "空白处被误判成图片了")
    }

    /// 找出「图片那一行」在屏幕上的中心点（用来模拟点击）
    private func centerOfImageFragment(in textView: MarkdownTextView) -> CGPoint? {
        guard let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else {
            return nil
        }
        let documentStart = contentStorage.documentRange.location
        var result: CGPoint?

        layoutManager.enumerateTextLayoutFragments(from: documentStart,
                                                   options: [.ensuresLayout]) { fragment in
            let start = contentStorage.offset(from: documentStart, to: fragment.rangeInElement.location)
            let length = contentStorage.offset(from: fragment.rangeInElement.location,
                                               to: fragment.rangeInElement.endLocation)
            let range = NSRange(location: start, length: max(0, length))
            guard NSMaxRange(range) <= textView.textStorage.length else { return true }

            var isImage = false
            textView.textStorage.enumerateAttribute(.attachment, in: range, options: []) { value, _, _ in
                if value is ImageAttachment { isImage = true }
            }
            guard isImage else { return true }

            // fragment 坐标 → 屏幕坐标（和 `imageAttachment(at:)` 里那套是同一个方向）
            let frame = fragment.layoutFragmentFrame
            result = CGPoint(x: frame.midX + textView.textContainerInset.left - textView.contentOffset.x,
                             y: frame.midY + textView.textContainerInset.top - textView.contentOffset.y)
            return false
        }
        return result
    }

    /// 图片不存在时的小占位也不能高过「行高 × 2」，更不能被最大高度反过来撑大
    func testMissingPlaceholderStillRespectsTwoLines() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("missing-\(UUID().uuidString).png")
        let renderer = MarkupToAttributedRenderer(theme: .default, containerWidth: 600)
        let (text, _) = renderer.render(blockSource: "![](\(url.absoluteString))\n")

        var found: ImageAttachment?
        text.enumerateAttribute(.attachment,
                                in: NSRange(location: 0, length: (text.string as NSString).length),
                                options: []) { value, _, _ in
            if let attachment = value as? ImageAttachment { found = attachment }
        }
        let attachment = try XCTUnwrap(found)

        XCTAssertTrue(attachment.isMissing)
        XCTAssertLessThanOrEqual(attachment.bounds.height,
                                 MarkdownTheme.default.bodyFont.lineHeight * 2 + 0.01,
                                 "缺失占位最多两行高，实际 \(attachment.bounds.height)")
    }
}
