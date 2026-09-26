//
//  SwiftMathRenderer.swift
//  MarkdownEditorHy4
//
//  用 SwiftMath 把 LaTeX 排成一张图（App 层的实现，注入给编辑器组件）
//
//  ### 这个文件为什么要放在 **App 层**
//  `MarkdownEditor` 是要单独开源给别人用的库。SwiftMath 是本项目 App 选的公式引擎，
//  不该变成开源库的强制依赖 —— 所以库里只有 `MarkdownMathRenderer` 协议，
//  真正的 SwiftMath 代码放在这里，由 App 注入进去。
//  结果：`MarkdownEditor/` 下一个 `import SwiftMath` 都没有，开源出去是干净的依赖图。
//
//  ### 为什么用 `MTMathImage` 而不是 `MTMathUILabel`
//  编辑器那边要求公式最终是一张图（理由见 `MathAttachment` 的注释：
//  TextKit 2 的 view provider 在整篇替换后会失效）。SwiftMath 恰好自带了
//  `MTMathImage.asImage()` 直接吐 UIImage，省掉「先建 UIView 再 layer.render」这道弯。
//

import UIKit
import SwiftMath

/// SwiftMath 版的公式渲染器。
///
/// 用法：在编辑器建好之后塞给它，一行就装上了：
/// `editor.renderer.mathRenderer = SwiftMathRenderer.shared`
final class SwiftMathRenderer: MarkdownMathRenderer {

    /// 全局共用一个：排版结果的缓存是跨文档复用的，
    /// 而且 SwiftMath 的字库只会在第一次排版时被加载一次。
    static let shared = SwiftMathRenderer()

    /// 排版结果缓存。
    ///
    /// ### 为什么必须缓存
    /// 每排一次公式都要跑一遍「解析 + 字形排版 + 离屏渲染」。单条公式不慢，
    /// 但**整篇重排是高频事件** —— 用户在设置页拖一下字号滑块就是一次整篇重排，
    /// 一篇十几个公式的文档会被反复问同样的十几次。没缓存的话拖动会明显掉帧。
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // 200 条足够：一篇文档里的公式通常个位数，多留些是为了来回切换文档时不重排
        cache.countLimit = 200
    }

    /// 排版一条公式。
    /// - returns: 排版好的图；**LaTeX 语法有误时返回 nil**（调用方会退化成显示源码原文）
    func image(for request: MarkdownMathRequest) -> UIImage? {
        let key = cacheKey(for: request)
        if let cached = cache.object(forKey: key) { return cached }

        let mathImage = MTMathImage(latex: request.latex,
                                    fontSize: request.fontSize,
                                    textColor: request.textColor,
                                    // display 对应课本里「单独列出的式子」：下标 proportion 更舒展；
                                    // text 对应夹在句子里的写法，刻意压矮一点免得把行距撑开
                                    labelMode: request.mode == .block ? .display : .text,
                                    textAlignment: .center)
        let (error, image) = mathImage.asImage()

        // 用户一边打一边看，`\frac{` 这种半截公式必然解析失败 —— 这是常态不是异常，返回 nil 就好
        guard error == nil, let image else { return nil }

        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: 缓存键

    /// 一段公式的唯一标识：内容变小 / 字号变小 / 颜色变了一点，图都得重新排。
    private func cacheKey(for request: MarkdownMathRequest) -> NSString {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        // 动态色（比如 .label）在不同外观下解出来的分量不同，正好让深浅两套外观各自缓存一份。
        // 注意中间两个参数有标签（green: / blue:），只有第一个和 alpha 那个是这么写的，写错了编译器只会说「缺逗号」
        request.textColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let color = String(format: "%.3f,%.3f,%.3f,%.3f", red, green, blue, alpha)
        let mode = request.mode == .block ? "block" : "inline"
        return "\(request.latex)|\(request.fontSize)|\(color)|\(mode)" as NSString
    }
}
