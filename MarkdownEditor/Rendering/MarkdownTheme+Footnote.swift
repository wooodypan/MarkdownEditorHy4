//
//  MarkdownTheme+Footnote.swift
//  MarkdownEditorHy4
//
//  脚注的样式：引用标记画成上标、定义块往里缩一档。
//
//  放在扩展文件里是为了让「脚注长什么样」这件事只占这一处 —— `MarkdownTheme.swift` 里只有一行 `var footnote = FootnoteStyle()`。
//

import UIKit

extension MarkdownTheme {

    /// 脚注的样式参数。
    struct FootnoteStyle {
        /// 引用标记（`[^1]`）的字号 = 正文字号 × 这个倍率。
        ///
        /// 比正文小一号才像「上标注释」，和正文一样大的话那几个字符会挤进正文里、看着就是普通文字。
        var referenceFontScale: CGFloat = 0.78

        /// 引用标记往上抬多少（**相对正文字号的比例**，不是固定点数）。
        ///
        /// 用比例是因为字号是用户在设置页拖的：写死 4 点的话，字号调到 28 时那几个字符几乎没抬起来。
        var referenceBaselineScale: CGFloat = 0.28

        /// 有对应定义时引用标记的颜色。`nil` = 跟链接同色（`linkColor`，换配色时一起变）。
        var referenceColor: UIColor? = nil

        /// 引用了一个**根本没定义**的 ID 时的颜色 —— 提示「这是个断链」。
        ///
        /// 不报错、不隐藏、字符照常参与复制，只是换个颜色：用户常常是先写 `[^1]` 再回头补定义，打字打到一半就飘红比什么都不提示好用，也比弹窗温和。
        var danglingColor: UIColor = .systemRed

        /// 定义块（`[^1]: 说明`）相对正文往里缩多少点
        var definitionIndent: CGFloat = 18

        /// 定义块开头那个 `[^1]:` 的颜色。`nil` = 跟语法标记同色（`markerColor`）。
        var definitionMarkerColor: UIColor? = nil

        /// 跳转落地时给目标刷的那层背景色（半透明，压在文字**下面**）。
        var flashColor: UIColor = UIColor.systemYellow.withAlphaComponent(0.35)

        /// 落地高亮亮多久（秒）之后自己消失
        var flashDuration: TimeInterval = 1
    }

    // MARK: 派生值

    /// 引用标记的字体：比正文小一号。
    ///
    /// 写成计算属性而不是存一个 `UIFont`：字号是从 `bodyFont` 派生的，用户在设置页拖正文字号时它要跟着变，存一份就得记得在 `applyBodyFontSize` 里同步 —— 漏一处就是「字号变了，脚注没变」。
    var footnoteReferenceFont: UIFont {
        bodyFont.withSize(max(9, bodyFont.pointSize * footnote.referenceFontScale))
    }

    /// 引用标记往上抬多少点（上标效果）
    var footnoteReferenceBaselineOffset: CGFloat {
        bodyFont.pointSize * footnote.referenceBaselineScale
    }

    /// 引用标记的颜色：有定义用强调色（默认链接色），没定义用断链色。
    func footnoteReferenceColor(hasDefinition: Bool) -> UIColor {
        guard hasDefinition else { return footnote.danglingColor }
        return footnote.referenceColor ?? linkColor
    }

    /// 引用标记的完整样式。
    ///
    /// ### 为什么是「小字号 + baselineOffset」而不是附件
    /// 引用标记只有几个字符，用 `NSTextAttachment` 那种「在文本流里插一个占位字符」的重机制反而是过度设计：
    /// 会多出一个不对应源码的字符位，还得为它补映射。纯属性手段不动字符、不动映射，「全选复制 === 源文件」自动成立。
    func footnoteReferenceAttributes(hasDefinition: Bool) -> [NSAttributedString.Key: Any] {
        [.font: footnoteReferenceFont,
         .baselineOffset: footnoteReferenceBaselineOffset,
         .foregroundColor: footnoteReferenceColor(hasDefinition: hasDefinition)]
    }

    /// 定义块开头那个 `[^1]:` 的样式
    var footnoteDefinitionMarkerAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: footnote.definitionMarkerColor ?? markerColor]
    }

    /// 定义块的段落样式：悬挂缩进 —— 第一行（带 `[^1]:`）顶到正文位置，换行之后往里缩一档。
    ///
    /// 和列表项是同一套道理：标记比正文短，续行跟正文左边缘对齐才看得出「这几行属于同一条脚注」。
    func footnoteDefinitionParagraphStyle(indent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent + footnote.definitionIndent
        style.paragraphSpacingBefore = 4
        style.paragraphSpacing = paragraphSpacing
        applyLineHeight(to: style)
        return style
    }
}
