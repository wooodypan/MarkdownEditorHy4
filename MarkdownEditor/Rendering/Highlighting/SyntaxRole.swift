//
//  SyntaxRole.swift
//  MarkdownEditorHy4
//
//  代码高亮的「中间表示」：只描述字符属于什么语法角色，不掺任何颜色
//

import Foundation

/// 一段代码里某个字符区间的语法角色。
///
/// ### 为什么用固定枚举，而不是让每个高亮库自己返回分类字符串
/// 这样「角色 → 颜色」的映射只存在一份（在 `MarkdownTheme` 里），
/// **换任何高亮实现，颜色风格都不变** —— 变的只是「哪些字符算关键字」的准确度。
/// 如果让高亮库返回自己的分类名，换一个库整套配色就得改一遍，样式就不归主题管了。
enum SyntaxRole {
    /// 关键字：`func` / `def` / `const` …
    case keyword
    /// 字符串字面量：`"abc"` / `'abc'` / `` `abc` ``
    case string
    /// 注释：`// …` / `# …` / `/* … */`
    case comment
    /// 数字字面量，顺带包括 `true` / `false` / `nil` / `None` 这类「写死的常量」
    /// （它们和数字的语义是一类：字面量，不是标识符）
    case number
    /// 类型名。两部分合起来：① 语言规则表里明确列出的（`int` / `void` / `boolean` 这类）；② **启发式**判定的 —— 大写字母开头的标识符一律当类型（`NSString` / `List` 这类，各语言都这么写，命中率够高，省得逐门语言抄一遍内置类型表）
    case type
    /// 普通标识符。它不会被真正用起来：考虑到性能，扫描器不产这个角色的 token
    case identifier
    /// 空白、运算符等没归类的字符
    case plain
}

/// 高亮结果里的一个片段。
///
/// ### `range` 为什么是 NSRange（UTF-16 偏移）而不是 `Range<String.Index>`
/// 最终消费方是 `NSMutableAttributedString.addAttribute(_:value:range:)`，用 `String.Index` 的话每个 token 都要 `NSRange(token.range, in: code)` 换算一次 —— 而高亮是**每敲一个字都要重跑一遍**的热路径，能省就省。扫描器那边干脆一开始就按 UTF-16 记账（见 `Lexer.offsets`），一个 token 都不用换算。
///
/// 坐标原点是「传进去那段代码的首字符」，不是整篇文档。
struct HighlightToken {
    let range: NSRange
    let role: SyntaxRole
}
