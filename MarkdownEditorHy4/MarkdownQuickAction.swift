//
//  MarkdownQuickAction.swift
//  MarkdownEditorHy4
//
//  悬浮编辑按钮上那十来个动作：它们「是什么」「点下去改什么」都写在这里。
//
//  ### 为什么单独一个文件、且不认识任何视图
//  悬浮按钮那套 UI（圆点、横条、长按菜单）只负责「用户点了哪一个」，动作本身该往源码里写什么字符，跟按钮长什么样、摆在哪个位置一点关系都没有。
//  拆开之后，动作这一层可以单独跑测试（给它一个编辑器，看源码变成什么样）， UI 那一层按项目惯例靠编译 + 手动冒烟。
//
//  ### 为什么动作的施加方式有两种
//  - **整行的事**（标题 / 待办 / 列表）走 `setLineMarker`：改的是光标所在那一行的行首；
//  - **选中文字的事**（加粗 / 斜体 / 行内代码 / 删除线 / 下划线）走 `toggleInlineMarkup`：
//    选中了就给选中的那段套上标记，没选就插入一对空标记（光标停在中间）。
//  这两条路都在编辑器组件里，本文件只是挑一个用，自己不碰源码。
//

import UIKit

/// 悬浮编辑按钮上的一个动作。
///
/// 每个 case 同时带着「按钮长什么样」（`title` / `symbolName`）和「点了做什么」（`apply(to:)`）。
enum MarkdownQuickAction: Equatable {

    /// 把当前行变成 `level` 级标题（`1`~`6`）
    case heading(Int)
    /// 待办事项：行首加 `- [ ] `
    case todo
    /// 无序列表：行首加 `- `
    case bulletedList
    /// 有序列表：行首加 `1. `（多行时依次编号）
    case orderedList
    /// 加粗：`**文字**`
    case bold
    /// 斜体：`*文字*`
    case italic
    /// 行内代码：`` `文字` ``
    case inlineCode
    /// 围栏代码块
    case codeBlock
    /// 删除线：`~~文字~~`
    case strikethrough
    /// 下划线：`<u>文字</u>`（markdown 没有下划线语法，通行做法是内联 HTML）
    case underline

    // MARK: 按钮上显示什么

    /// 按钮上的字。
    ///
    /// 标题级别直接显示 `H1` 这样的记号（比「一级标题」省地方，也更直观）；
    /// 加粗 / 斜体沿用排版软件的老规矩，用 `B` / `I` 两个字。
    var title: String {
        switch self {
        case .heading(let level): return "H\(level)"
        case .todo: return "待办"
        case .bulletedList: return "列表"
        case .orderedList: return "有序"
        case .bold: return "B"
        case .italic: return "I"
        case .inlineCode: return "行内代码"
        case .codeBlock: return "代码块"
        case .strikethrough: return "删除线"
        case .underline: return "下划线"
        }
    }

    /// 按钮上的 SF Symbol 图标名；nil 表示只用文字。
    var symbolName: String? {
        switch self {
        case .heading: return nil                 // 文字 H1 比图标更好认
        case .todo: return "checkmark.square"
        case .bulletedList: return "list.bullet"
        case .orderedList: return "list.number"
        case .bold: return nil                    // 用加粗的 B 这个字本身当图标
        case .italic: return nil                  // 用倾斜的 I 这个字本身当图标
        case .inlineCode: return "chevron.left.forwardslash.chevron.right"
        case .codeBlock: return "curlybraces.square"
        case .strikethrough: return "strikethrough"
        case .underline: return "underline"
        }
    }

    /// 纯文字按钮要用的字体；nil 表示用常规字体。
    ///
    /// 加粗 / 斜体这两个按钮干脆把字本身做成加粗 / 倾斜的 —— 一眼就知道点下去是什么效果，比画个图标快。
    var titleFont: UIFont? {
        switch self {
        case .bold: return .boldSystemFont(ofSize: 15)
        case .italic: return .italicSystemFont(ofSize: 15)
        default: return nil
        }
    }

    /// 长按这个按钮时要不要弹菜单、弹出来是哪几项。
    ///
    /// 空数组表示「没有备选，点一下就直接生效」。
    ///
    /// ### 为什么标题那六项挂在 `heading` 自己身上
    /// 主横条上只摆了一个 H1 按钮，长按它才把 H1~H6 全列出来 ——这样「H2 在哪」不用占横条的位置，横条才塞得下六个按钮。
    var alternatives: [MarkdownQuickAction] {
        switch self {
        case .heading: return (1...6).map { .heading($0) }
        case .bulletedList: return [.bulletedList, .orderedList]
        default: return []
        }
    }

    /// 「更多」里面那四项。
    ///
    /// 它们不是任何一个按钮的备选，而是单独一个「更多」按钮弹出来的，所以写成一个静态常量而不是 `alternatives`。
    static let moreActions: [MarkdownQuickAction] = [.inlineCode, .codeBlock, .strikethrough, .underline]

    // MARK: 点下去做什么

    /// 把这个动作施加到 `textView` 上。
    ///
    /// 选中了文字就改选中的那段，没选就在光标处插一对空标记 —— 这两件事都是编辑器里那套命令干的，这里只负责挑一个调。
    func apply(to textView: MarkdownTextView) {
        switch self {
        case .heading(let level):
            textView.setHeadingMarkdown(level: level)
        case .todo:
            textView.setLineMarker("- [ ] ", actionName: "待办事项")
        case .bulletedList:
            textView.setLineMarker("- ", actionName: "无序列表")
        case .orderedList:
            textView.setLineMarker("1. ", actionName: "有序列表", numbered: true)
        case .bold:
            textView.toggleBoldMarkdown()
        case .italic:
            textView.toggleItalicMarkdown()
        case .inlineCode:
            textView.toggleInlineMarkup(open: "`", close: "`", actionName: "行内代码")
        case .codeBlock:
            textView.toggleCodeBlockMarkdown()
        case .strikethrough:
            textView.toggleInlineMarkup(open: "~~", close: "~~", actionName: "删除线")
        case .underline:
            textView.toggleUnderlineMarkdown()
        }
    }
}
