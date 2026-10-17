//
//  MermaidKitRendererTests.swift
//  MarkdownEditorHy4Tests
//
//  App 层适配器 `MermaidKitRenderer` 的集成测试（**真的**过一遍 MermaidKit）
//
//  ### 为什么单独放一个文件
//  `MarkdownMermaidTests` 那组测的是组件层行为，刻意不依赖任何图表引擎 —— 那组是「换引擎也成立」的。
//  这一个文件反过来，专门钉住「我们和 MermaidKit 的接法对不对」：
//  合法语法出得了图、半截语法老实返回 nil、深浅背景会画出两张不同的图、重复请求命中缓存。
//
//  ### 为什么直接调单例、不经编辑器
//  编辑器那一路的接线（`renderer.mermaidRenderer = …`）已经由 `MarkdownMermaidTests` 的假引擎覆盖了。
//  这里只管适配器本身，直接调它最直白。
//

import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class MermaidKitRendererTests: XCTestCase {

    /// 拼一份请求。颜色给默认值，只有要测「换了配色会怎样」的用例才需要自己传。
    private func makeRequest(source: String,
                             maxWidth: CGFloat = 584,
                             textColor: UIColor = .black,
                             backgroundColor: UIColor = .white,
                             accentColor: UIColor = .systemBlue,
                             separatorColor: UIColor = .systemGray3) -> MarkdownMermaidRequest {
        MarkdownMermaidRequest(source: source,
                               maxWidth: maxWidth,
                               textColor: textColor,
                               backgroundColor: backgroundColor,
                               accentColor: accentColor,
                               separatorColor: separatorColor,
                               fontSize: 17)
    }

    /// 画一张图
    private func makeImage(source: String, backgroundColor: UIColor = .white) -> UIImage? {
        MermaidKitRenderer.shared.image(for: makeRequest(source: source, backgroundColor: backgroundColor))
    }

    // MARK: - 画得出来 / 画不出来

    func testValidFlowchartRenders() {
        let image = makeImage(source: "flowchart TD\n  A[开始] --> B[结束]")

        XCTAssertNotNil(image, "合法的 flowchart 应该画得出来")
        XCTAssertGreaterThan(image?.size.width ?? 0, 0, "图要有宽度")
        XCTAssertGreaterThan(image?.size.height ?? 0, 0, "图要有高度")
    }

    func testOtherDiagramTypesRender() {
        XCTAssertNotNil(makeImage(source: "pie title 占比\n  \"A\" : 70\n  \"B\" : 30"),
                        "饼图应该画得出来")
        XCTAssertNotNil(makeImage(source: "sequenceDiagram\n  A->>B: 你好"),
                        "时序图应该画得出来")
    }

    func testHalfWrittenSourceReturnsNil() {
        // 用户正敲半截（`flowchart T`）—— 这是**常态不是异常**。
        // 必须老实返回 nil，让调用方退化成显示源码原文，而不是抛错或画一张空图
        XCTAssertNil(makeImage(source: "flowchart T"), "半截语法应该返回 nil")
    }

    // MARK: - 深浅色

    func testDarkAndLightBackgroundsProduceDifferentImages() {
        let source = "flowchart LR\n  A --> B"
        let light = makeImage(source: source, backgroundColor: .white)
        let dark = makeImage(source: source, backgroundColor: UIColor(white: 0.12, alpha: 1))

        XCTAssertNotNil(light, "浅底该画得出来")
        XCTAssertNotNil(dark, "深底该画得出来")
        // 缓存键带上了背景色 —— 深浅两套各画各的，不会互相串
        XCTAssertFalse(light === dark, "深浅背景该画出两张不同的图")
    }

    // MARK: - 缓存

    func testRepeatedRequestHitsCache() {
        let request = makeRequest(source: "pie title 占比\n  \"A\" : 70\n  \"B\" : 30")

        guard let first = MermaidKitRenderer.shared.image(for: request) else {
            return XCTFail("饼图应该画得出来")
        }
        guard let second = MermaidKitRenderer.shared.image(for: request) else {
            return XCTFail("第二次也该拿到图")
        }
        // 整篇重排会把同一段源码反复问好几遍（换主题、拖字号都算），命中缓存时拿到的必须是**同一个对象**，不是重画一张一模一样的
        XCTAssertTrue(first === second, "同样的请求应该命中缓存，而不是重画")
    }

    func testDifferentWidthsDoNotEvictEachOther() {
        let source = "flowchart LR\n  A --> B\n  B --> C"
        // 顺序：先问 584 那份，中间插一份 200 的（宽度进了缓存键，它会另占一条），回头再问 584
        guard let first = MermaidKitRenderer.shared.image(for: makeRequest(source: source)) else {
            return XCTFail("宽的那份该画得出来")
        }
        XCTAssertNotNil(MermaidKitRenderer.shared.image(for: makeRequest(source: source, maxWidth: 200)),
                        "窄的那份也该画得出来")

        guard let again = MermaidKitRenderer.shared.image(for: makeRequest(source: source)) else {
            return XCTFail("回头再问宽的那份也该拿到图")
        }
        // ⚠️ 别断言「两种宽度画出来不是同一个对象」—— 可用宽度压根不参与绘制（缩放是 `MermaidAttachment` 干的），
        // 引擎内部对「同源码同主题」自己就会去重，拿到同一个对象才是正常的。
        // 真正要守的是：插进来一条别的键，不会把原来那条顶掉。
        XCTAssertTrue(first === again, "插进来一个别的宽度，不该把原来那条缓存顶掉")
    }

    func testDifferentAccentColorsAreCachedSeparately() {
        let source = "flowchart LR\n  A --> B"
        let blue = MermaidKitRenderer.shared.image(
            for: makeRequest(source: source, accentColor: .systemBlue))
        let red = MermaidKitRenderer.shared.image(
            for: makeRequest(source: source, accentColor: .systemRed))

        XCTAssertNotNil(blue)
        XCTAssertNotNil(red)
        // 强调色进了缓存键：**这条是在守「缓存键别自己拿几个颜色拼」** ——
        // 拼的时候漏掉一个颜色（比如强调色），症状就是「换了主题，图还是上一套配色」，而且只在某两份主题之间才复现
        XCTAssertFalse(blue === red, "强调色不同的请求该各留一份缓存")
    }

    // MARK: - 配色映射的反差守卫

    /// 把图压在页面底色上，看有没有「明显偏离底色」的像素。
    ///
    /// ### 为什么值得单写一条像素级的
    /// 配色是**按主题映射进引擎调色板**的（见 `MermaidKitRenderer.diagramTheme`）。映射写错一个槽位，
    /// 症状不是「画不出来」—— `image(for:)` 照样返回图、尺寸也对、位图里也真有内容 ——
    /// 而是**画出一张和底色几乎同色的图，肉眼看不见**。别的断言一条都拦不住它，只能真去数像素。
    private func hasVisibleInk(_ image: UIImage, onPage page: UIColor) -> Bool {
        let traits = UITraitCollection(userInterfaceStyle: .light)
        let resolvedPage = page.resolvedColor(with: traits)
        let width = max(1, Int(image.size.width.rounded(.up)))
        let height = max(1, Int(image.size.height.rounded(.up)))
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImage = image.cgImage else { return false }

        // 先把页面底色铺满，再把透明底的图叠上去 —— 和它在编辑器里的落法完全一样
        ctx.setFillColor(resolvedPage.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolvedPage.getRed(&r, green: &g, blue: &b, alpha: &a)
        let pageLuma = 0.2126 * r + 0.7152 * g + 0.0722 * b

        // 只要有一个像素和底色拉开 0.35 的亮度差，就算「看得见」—— 门槛放宽是有意的：
        // 这里守的是「整张图糊成底色」，不是「对比度够不够漂亮」，卡太严会变成又一条亚像素红。
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let luma = (0.2126 * CGFloat(pixels[i])
                        + 0.7152 * CGFloat(pixels[i + 1])
                        + 0.0722 * CGFloat(pixels[i + 2])) / 255
            if abs(luma - pageLuma) > 0.35 { return true }
        }
        return false
    }

    func testDiagramHasVisibleInkOnBothLightAndDarkPages() {
        let source = "flowchart TD\n  A[开始] --> B{判断}\n  B -->|是| C[走这边]"
        let darkPage = UIColor(white: 0.11, alpha: 1)

        guard let onLight = MermaidKitRenderer.shared.image(for: makeRequest(source: source)),
              let onDark = MermaidKitRenderer.shared.image(
                for: makeRequest(source: source,
                                 textColor: UIColor(white: 0.95, alpha: 1),
                                 backgroundColor: darkPage)) else {
            return XCTFail("两张图都该画得出来")
        }
        XCTAssertTrue(hasVisibleInk(onLight, onPage: .white),
                      "浅色主题：图压在页面上必须看得见（整张糊成白色 = 配色映射把墨色填成了背景色）")
        XCTAssertTrue(hasVisibleInk(onDark, onPage: darkPage),
                      "深色主题：图压在页面上必须看得见（整张糊成深灰 = 深色那档的配色没映射对）")
    }
}
