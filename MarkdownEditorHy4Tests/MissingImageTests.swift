//
//  MissingImageTests.swift
//  MarkdownEditorHy4Tests
//
//  图片加载不出来时的占位行为。
//
//  背景（2026-09-17）：网络图 404、本地图不存在时，attachment 会一直停在加载中的
//  16:9 尺寸上（宽 = 容器宽，能有 300 多 pt 高），而且 `image` 是 nil —— 屏幕上就是
//  一大块说不清多高的空白。需求：这种时候占位要小，高度不超过行高的 2 倍。
//
//  注意：这里只测 attachment 自己。**别指望查富文本能发现问题** —— 富文本里挂的是
//  attachment 对象，尺寸对不对要看它的 `bounds`，不是看字符串。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class MissingImageTests: XCTestCase {

    // MARK: - 小工具

    /// 测试用的行高。真实值由主题的正文字体决定，这里取一个好算的整数。
    private let lineHeight: CGFloat = 24

    /// 造一个图片 attachment。参数除了 URL 全都固定，方便几个用例互相对照。
    private func makeAttachment(_ url: URL) -> ImageAttachment {
        ImageAttachment(markdownSource: "![图](\(url.absoluteString))",
                        imageURL: url,
                        maxWidth: 600,
                        maxHeight: 420,
                        lineHeight: lineHeight,
                        placeholderColor: .gray)
    }

    /// 造一张纯色 PNG 写到临时目录，用来当「能正常加载的本地图片」。
    ///
    /// ⚠️ 必须把 scale 固定成 1：`UIGraphicsImageRenderer` 默认按屏幕的 scale 出图，
    /// 在 Retina 上会画成 2 倍像素，读回来 `UIImage.size` 也跟着翻倍，断言就对不上了。
    private func writeTempImage(width: CGFloat = 200, height: CGFloat = 100) throws -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("probe-\(UUID().uuidString).png")
        try image.pngData()!.write(to: url)
        return url
    }

    // MARK: - 失败要收小

    /// 本地文件不存在：渲染那一刻就能确定读不出来，应该**立刻**收成小占位，
    /// 不该先撑一大块、等异步回调再缩回去（那样会看到一次跳动）。
    func testMissingLocalFileShrinksImmediately() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("missing-\(UUID().uuidString).png")

        let attachment = makeAttachment(url)

        XCTAssertTrue(attachment.isMissing, "本地文件读不出来，init 里就该判定成缺失")
        XCTAssertLessThanOrEqual(attachment.bounds.height, lineHeight * 2,
                                 "缺失占位的高度不能超过行高的 2 倍，实际 \(attachment.bounds.height)")
        XCTAssertLessThanOrEqual(attachment.bounds.width, 200,
                                 "缺失占位也应该收窄，别占满整行")
        XCTAssertNotNil(attachment.image,
                        "缺失占位必须画出标记，不能是一块看不出所以然的空白")
    }

    /// 网络图 404：init 时还是加载中的大占位，异步回来失败后收成小占位。
    ///
    /// `.invalid` 是保留域名（RFC 2606），必然解析失败，不依赖外网服务是否在线。
    func testMissingNetworkImageShrinksAfterFailure() {
        let url = URL(string: "https://example.invalid/missing-\(UUID().uuidString).png")!
        let attachment = makeAttachment(url)

        XCTAssertFalse(attachment.isMissing, "还没加载完不能先判成缺失")

        attachment.loadIfNeeded(host: nil)
        // 加载结果在主线程回调，用轮询等它回来（网络失败可能要几秒才返回）
        let becameMissing = XCTNSPredicateExpectation(
            predicate: NSPredicate(block: { _, _ in attachment.isMissing }), object: nil)
        wait(for: [becameMissing], timeout: 15)

        XCTAssertLessThanOrEqual(attachment.bounds.height, lineHeight * 2,
                                 "加载失败后要收小，实际 \(attachment.bounds.height)")
        XCTAssertNotNil(attachment.image, "失败后也要画出占位标记")
    }

    // MARK: - 回归：能加载的图不受影响

    /// 真图该多大就多大，不能被占位逻辑压成小方块。
    func testLoadedImageKeepsItsOwnSize() throws {
        let url = try writeTempImage()
        defer { try? FileManager.default.removeItem(at: url) }

        let attachment = makeAttachment(url)

        XCTAssertFalse(attachment.isMissing, "能读出来的图不能被判成缺失")
        XCTAssertEqual(attachment.bounds.height, 100, accuracy: 1,
                       "真图按自己的尺寸排版")
        XCTAssertGreaterThan(attachment.bounds.height, lineHeight * 2,
                             "真图比 2 行还高是正常的，别拿占位规则去压它")
    }

    // MARK: - 渲染器接线

    /// 渲染一条指向不存在文件的图片语法，出来的 attachment 必须是收小的。
    ///
    /// 这个用例保护的是「渲染器有没有把行高传给 attachment」：
    /// 万一哪天漏传，attachment 拿不到 2 倍行高这个上限，又会退回大空白。
    func testRendererShrinksMissingImage() {
        let theme = MarkdownTheme.default
        let renderer = MarkupToAttributedRenderer(theme: theme, containerWidth: 600)
        let source = "![](file:///nonexistent-\(UUID().uuidString).png)\n"
        let (text, _) = renderer.render(blockSource: source)

        var found: ImageAttachment?
        text.enumerateAttribute(.attachment,
                                in: NSRange(location: 0, length: (text.string as NSString).length),
                                options: []) { value, _, _ in
            if let attachment = value as? ImageAttachment { found = attachment }
        }

        guard let attachment = found else {
            return XCTFail("没有渲染出 ImageAttachment")
        }

        XCTAssertTrue(attachment.isMissing, "指向不存在文件的图片应该判成缺失")
        let expectedLineHeight = theme.bodyFont.lineHeight * max(1, theme.lineHeightMultiple)
        XCTAssertLessThanOrEqual(attachment.bounds.height, expectedLineHeight * 2 + 0.01,
                                 "渲染出来的缺失占位不能超过 2 行正文高")
    }
}
