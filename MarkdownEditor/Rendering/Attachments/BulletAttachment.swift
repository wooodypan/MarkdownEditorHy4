//
//  BulletAttachment.swift
//  MarkdownEditorHy4
//
//  无序列表的小圆点
//

import UIKit

/// 无序列表的小圆点。
///
/// ### 它对应源码里的哪一段？
/// 圆点本身是纯视觉效果，但它在源码里确实有对应的字符 —— 也就是 `- `（或 `* `、`+ `）这个列表标记。
/// 所以渲染时把圆点做成 attachment 占 1 个字符位，同时让这个字符位映射到源码里 `- ` 那一段。
///
/// 好处有两个：
/// 1. **复制还原**：选中列表项复制，出来的是 `- 内容`，粘回任何 markdown 编辑器都能用；
/// 2. **退格自然**：光标停在圆点后面按退格，删掉的就是 `- ` 这两个源码字符，列表项自动降级成普通段落，
///    不需要为退格键写任何特殊逻辑。
final class BulletAttachment: NSTextAttachment {
    let diameter: CGFloat
    let color: UIColor

    /// 圆点右边留出的间距（紧贴 `-[空格]` 的那个位置，让圆点和 `-` 之间有点呼吸感）
    private static let trailingGap: CGFloat = 2

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释：
    /// 隔离 deinit 一旦嵌套就会踩 Swift 6.2 运行时的野指针 free。
    nonisolated deinit {}

    init(diameter: CGFloat, color: UIColor, font: UIFont) {
        self.diameter = diameter
        self.color = color
        super.init(data: nil, ofType: nil)

        // bounds 的 y 是相对文本基线、向上为正的偏移。
        // 想让圆点垂直居中对齐文字的大写字母高度，就让它的中心落在 capHeight 的一半处：
        //   中心 = y + 高度/2 = capHeight/2   ==>   y = (capHeight - 高度) / 2
        let y = (font.capHeight - diameter) / 2
        bounds = CGRect(x: 0, y: y, width: diameter + Self.trailingGap, height: diameter)

        // 直接给一张画好的圆点图，让 TextKit 当普通文本元素画出来。
        // 不用 view provider 的原因见 ImageAttachment 的注释（那种方式在整篇替换后会「圆点消失」）。
        self.image = Self.circleImage(diameter: diameter, color: color, gap: Self.trailingGap)
    }

    required init?(coder: NSCoder) {
        fatalError("BulletAttachment 不支持从 coder 解档")
    }

    /// 画一个实心圆点，右边留 `gap` 的空白
    private static func circleImage(diameter: CGFloat, color: UIColor, gap: CGFloat) -> UIImage {
        let size = CGSize(width: diameter + gap, height: diameter)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale     // 按屏幕倍率出图，圆点边缘才不会糊
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            // 圆点靠左，右边那段是间距
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        }
    }
}

// MARK: - 任务列表复选框的「座位」

/// 任务列表项里给复选框**留出来的那块位置**。
///
/// ### 它是什么
/// 它不是视觉元素（整张图是透明的），而是一块**占位空间**：在文本流里占 1 个字符位，宽度 = 方框边长 + 左右各一点间距。真正的复选框按钮由 `MarkdownTextView` 叠在这块空间正中。
///
/// ### 为什么需要它（修「复选框挤在 `- ` 上」的由来）
/// 用户要的排布是：浅灰 `-` → 复选框 → `[x]`（照常显示）→ 正文。标记区凭空多出「一个复选框」的宽度，就必须在**文本流里**真的留出位置，否则按钮只能压在 `- ` 上（老的「并列模式」）或者压在 `[x]` 上（老的「遮盖模式」）。有了座位，按钮既不挡源码、也不跟列表标记挤。
///
/// ### 它不消耗源码位置，但**是退格的边界**
/// 它是纯装饰：构造时走 `RenderedFragment.decorationAttachment(isSyntaxMarker: false)`（**必须传 `false`**，理由见那里的注释），映射被标成「跳过」，所以全选复制出来的文本里没有它。退格时它只是一道**边界**：光标停在座位上、或者停在 `]` 右边，删掉的都是右边 `[ ] ` 那一段，不会越过它把左边的 `- ` 一起吃掉 —— 这条踩过坑，见 `MarkdownDocumentStore.expandedSyntaxMarkerRange`。
final class CheckboxSeatAttachment: NSTextAttachment {
    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释：
    /// 隔离 deinit 一旦嵌套就会踩 Swift 6.2 运行时的野指针 free。
    nonisolated deinit {}

    /// - parameter side: 复选框边长（按钮就铺在这块空间的中间）
    /// - parameter gap:  方框左右各留多少间距（和主题里的 `checkboxGap` 同一个值）
    /// - parameter font: 正文字体（决定垂直位置，让方框和文字的大写字母高度居中对齐）
    init(side: CGFloat, gap: CGFloat, font: UIFont) {
        super.init(data: nil, ofType: nil)

        let width = side + gap * 2
        // 和圆点同一套垂直定位：bounds.y 是相对基线向上为正的偏移，让方框的垂直中心落在大写字母高度的一半处 ==> y = (capHeight - side) / 2
        let y = (font.capHeight - side) / 2
        bounds = CGRect(x: 0, y: y, width: width, height: side)

        // 必须给一张图：TextKit 靠 image 的尺寸决定这个字符位占多大（不给图的话可能被算成 0 宽，座位就白留了）
        self.image = Self.transparentImage(size: bounds.size)
    }

    required init?(coder: NSCoder) {
        fatalError("CheckboxSeatAttachment 不支持从 coder 解档")
    }

    /// 一张全透明的图 —— 座位本身什么都不画，视觉上的东西全由叠上去的按钮负责
    private static func transparentImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in }
    }
}

// MARK: - 分隔线

/// `---` 分隔线的 attachment。
///
/// 和圆点同理：视觉上是一条横线，但字符位映射到源码里的 `---` 三个字符，保证复制还原。
final class SeparatorAttachment: NSTextAttachment {
    let lineColor: UIColor

    /// 原因见 `MarkdownBlock` 里 `nonisolated deinit` 的注释：
    /// 隔离 deinit 一旦嵌套就会踩 Swift 6.2 运行时的野指针 free。
    nonisolated deinit {}

    init(width: CGFloat, lineColor: UIColor, font: UIFont) {
        self.lineColor = lineColor
        super.init(data: nil, ofType: nil)

        let lineWidth = max(20, width)
        // 高度 1，垂直位置对齐文字的大写字母中线
        let y = (font.capHeight - 1) / 2
        bounds = CGRect(x: 0, y: y, width: lineWidth, height: 1)

        // 和圆点一样走「给 image 让 TextKit 画」这条路，不用 view provider
        self.image = Self.lineImage(width: lineWidth, color: lineColor)
    }

    required init?(coder: NSCoder) {
        fatalError("SeparatorAttachment 不支持从 coder 解档")
    }

    /// 画一条 1 点高的横线
    private static func lineImage(width: CGFloat, color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: 1), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: 1))
        }
    }
}
