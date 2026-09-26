//
//  MarkdownMathRenderer.swift
//  MarkdownEditorHy4
//
//  数学公式的渲染接口（`$...$` / `$$...$$`）
//
//  ### 为什么这里只有协议、没有实现
//  `MarkdownEditor` 是要单独开源给别人用的库，而 LaTeX 排版是个高度专业化的活，
//  唯一的靠谱选项就是引入第三方库（本项目用的是 SwiftMath）。如果这里直接 `import SwiftMath`，
//  那么**所有**用这个库的人都被迫拖上这个依赖 —— 哪怕他一篇公式都不写。
//
//  所以这里沿用代码高亮那套已经被验证过的做法（`CodeHighlighting` + `codeHighlighter`）：
//  **库只定义接口，具体实现由宿主 App 注入**。差别只有一处默认值 ——
//  代码高亮自带了 `SimpleCodeHighlighter` 兜底，公式没有兜底（`nil` 就退化成显示源码原文），
//  因为「随便画点什么」比「不画」更糟。
//
//  ### 接抽象的时候注意别泄露返回值
//  返回值是 `UIImage`：公式排版的结果本来就是一张图（走 `NSTextAttachment.image` 那条路，
//  理由见 `MathAttachment` 的注释）。刻意不说「某个第三方库的类型」，将来想换成别的排版引擎，
//  只要它也能吐一张 `UIImage` 就行。
//

import UIKit

/// 公式是「夹在文字里」还是「独占一块」。
///
/// 对应 LaTeX 里的 text style / display style：同一个 `x^2` 在两种模式下的字号、
/// 上下标的排版位置都不一样（display 模式更舒展，像课本里单独列出的公式）。
enum MarkdownMathMode {
    /// 行内：跟着正文的文字一起走
    case inline
    /// 块级：单独一块，通常居中
    case block
}

/// 一次公式渲染请求：排版一张公式需要的所有信息。
///
/// 刻意不带 `bounds` / `containerWidth` 这类布局参数 —— 缩放、居中这些事
/// 是文本排版层（`MathAttachment`）的活，不是排版引擎的活。
struct MarkdownMathRequest {
    /// LaTeX 源码（`\frac{a}{b}`，不含两侧的 `$`）
    var latex: String
    /// 排版用的字号（点）。已经由主题算好（正文字号 × 倍率）
    var fontSize: CGFloat
    /// 公式的颜色（一般是正文色）
    var textColor: UIColor
    /// 行内还是块级
    var mode: MarkdownMathMode
}

/// 把 LaTeX 渲染成一张图的渲染器。
///
/// 由宿主 App 实现后注入给 `MarkupToAttributedRenderer.mathRenderer`。
/// 不注入的话公式就按源码原文显示（`x^2` 连同 `$` 一起），功能降级但**不会坏**。
///
/// ### 实现者要注意两件事
/// 1. **这个方法会在渲染的紧循环里被调用**（一篇文档的每段都调），
///    一定要缓存结果 —— 同一个公式在中英文切换到深色、滚动重排时会被反复问到。
///    缓存键至少要把 `latex` / `fontSize` / `textColor` / `mode` 都算进去。
/// 2. **返回 nil 表示「这个公式渲染不出来」**（语法错、字库没加载出来…）。
///    调用方会退化成显示源码原文，所以**不要**为了兜底返回一张「错误提示图」——
///    用户正在输入 `\frac{` 的半截公式，满屏报错图表征才是最差的体验。
protocol MarkdownMathRenderer: AnyObject {

    /// 排版一条公式。
    /// - returns: 排版好的图（尺寸就是它在屏幕上的实际大小），渲染不出来返回 `nil`
    func image(for request: MarkdownMathRequest) -> UIImage?
}
