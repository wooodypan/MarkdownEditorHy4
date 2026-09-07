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

    /// 圆点右边留出的间距（相当于源码里 `- ` 那个空格的宽度）
    private static let trailingGap: CGFloat = 8

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
    }

    required init?(coder: NSCoder) {
        fatalError("BulletAttachment 不支持从 coder 解档")
    }

    override func viewProvider(for parentView: UIView?,
                               location: any NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        BulletAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
    }
}

/// 圆点的 view provider：一个透明容器 + 一个圆形小 dot。
private final class BulletAttachmentViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        guard let attachment = textAttachment as? BulletAttachment else { return }
        let diameter = attachment.diameter

        // 外面套一层透明容器，宽度里包含圆点右边的间距
        let container = UIView()
        container.backgroundColor = .clear

        let dot = UIView(frame: CGRect(x: 2, y: 0, width: diameter, height: diameter))
        dot.backgroundColor = attachment.color
        dot.layer.cornerRadius = diameter / 2
        container.addSubview(dot)

        self.view = container
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

        // 高度 1，垂直位置对齐文字的大写字母中线
        let y = (font.capHeight - 1) / 2
        bounds = CGRect(x: 0, y: y, width: max(20, width), height: 1)
    }

    required init?(coder: NSCoder) {
        fatalError("SeparatorAttachment 不支持从 coder 解档")
    }

    override func viewProvider(for parentView: UIView?,
                               location: any NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        SeparatorAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
    }
}

/// 分隔线的 view provider：一条横线
private final class SeparatorAttachmentViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        guard let attachment = textAttachment as? SeparatorAttachment else { return }
        let line = UIView()
        line.backgroundColor = attachment.lineColor
        self.view = line
    }
}
