//
//  MarkdownListContinuation.swift
//  MarkdownEditorHy4
//
//  回车键的「列表续写」：认出光标所在的这一行是不是列表项、是的话回车该干什么
//

import Foundation

/// 光标所在列表项的信息，以及「这次回车该做什么」。
///
/// ### 大白话
/// 用户在 `- 已完成` 末尾按回车，期望光标落到新一行、并且新行开头已经替他写好了 `- `；
/// 在只有一个 `- ` 的空行上再按一次回车，则期望这个 `- ` 被吃掉、退回普通段落。
/// 这件事**不是渲染能解决的**（屏幕上多画一个圆点没用，文本流里得真有那两个字符），只能在「系统把回车插进文本之前」拦下来，自己构造一个复合编辑。
///
/// ### 为什么单独抽成一个纯函数（不写在 `MarkdownTextView` 里）
/// 判定本身只是「给整篇源码 + 光标偏移，算出结果」，不碰 UI、不碰渲染、不碰撤销栈。
/// 抽出来之后单测可以直接喂字符串验证，UI 层只负责「接管回车」这一件事，两边都好改。
struct MarkdownListContinuation {

    /// 这次回车要做的动作
    enum Action {
        /// 续写一项：在光标处插入 `\n` + 前缀（`- `、`  2. `、`- [ ] ` 这些）
        case insertItem(prefix: String)
        /// 退出列表：把 `markerRange` 这段源码（缩进 + 列表标记）删掉，留一个空行
        case exitList(markerRange: NSRange)
    }

    /// 光标所在那一行的源码范围（不含换行符）
    let lineRange: NSRange
    /// 缩进 + 列表标记的源码范围（退出列表时删掉的就是它）
    let markerRange: NSRange
    /// 标记后面是不是什么都没有（空列表项 → 回车是退出，不是续写）
    let isEmptyItem: Bool
    /// 这次回车要做的动作
    let action: Action

    /// 认出光标所在的列表项，算出这次回车该干什么。
    ///
    /// - parameter source: 整篇 markdown 源码
    /// - parameter caret:  光标在源码里的位置（UTF-16 偏移）
    /// - returns: 需要接管这次回车时返回结果；`nil` = 这不是列表项，回车照旧只插一个换行
    static func parse(source: String, caret: Int) -> MarkdownListContinuation? {
        let text = source as NSString
        let length = text.length
        guard caret >= 0, caret <= length else { return nil }

        let line = lineRange(containing: caret, in: text, length: length)
        let lineStart = line.location
        let lineEnd = NSMaxRange(line)
        // 空行（光标正停在换行符上）没什么可续写的
        guard lineEnd > lineStart else { return nil }

        // 1) 跳过行首缩进：嵌套列表的缩进要跟着一起抄到下一行，否则新项会掉回最外层
        var cursor = lineStart
        while cursor < lineEnd, isBlank(text.character(at: cursor)) { cursor += 1 }
        let markerStart = cursor
        guard markerStart < lineEnd else { return nil }

        // 2) 认标记：认不出来（`-abc`、`1.5`、`> - x` 这些）就不接管，回车照旧
        guard let scanned = scanMarker(in: text, from: markerStart, end: lineEnd) else { return nil }
        let markerEnd = scanned.markerEnd

        // 3) 标记后面还有没有正经内容？只剩空格 / tab 就算「空项」
        var probe = markerEnd
        var isEmptyItem = true
        while probe < lineEnd {
            if !isBlank(text.character(at: probe)) {
                isEmptyItem = false
                break
            }
            probe += 1
        }

        // 4) 光标还在标记上（或标记之前）时不接管：那种时候用户只是想在标记中间换行，续写会插出莫名其妙的标记残片（比如在 `[ ]` 里按回车）
        guard caret >= markerEnd else { return nil }

        let indent = text.substring(with: NSRange(location: lineStart, length: markerStart - lineStart))
        let markerRange = NSRange(location: lineStart, length: markerEnd - lineStart)
        let action: Action = isEmptyItem
            ? .exitList(markerRange: markerRange)
            : .insertItem(prefix: indent + scanned.nextMarker)

        return MarkdownListContinuation(lineRange: line,
                                        markerRange: markerRange,
                                        isEmptyItem: isEmptyItem,
                                        action: action)
    }

    // MARK: - 扫描细节

    /// 认出一行开头的列表标记。
    ///
    /// - returns: `markerEnd` = 标记结束的位置（`1. abc` 里就是 `a` 那个位置），`nextMarker` = 下一行要抄的标记文本
    private static func scanMarker(in text: NSString,
                                   from start: Int,
                                   end: Int) -> (markerEnd: Int, nextMarker: String)? {
        let first = text.character(at: start)

        // 有序列表：一串数字 + `.` 或 `)`，例如 `1. ` / `12) `
        if isDigit(first) {
            var cursor = start
            var digits = ""
            while cursor < end, isDigit(text.character(at: cursor)) {
                digits += character(text.character(at: cursor))
                cursor += 1
            }
            // 数字吃完了就到行尾（`123` 只是个数字，不是列表）
            guard cursor < end else { return nil }
            let delimiter = text.character(at: cursor)
            guard delimiter == 0x2E /* . */ || delimiter == 0x29 /* ) */ else { return nil }
            cursor += 1
            // 定界符后面必须跟空格 / tab / 行尾，否则 `1.5` 这种只是普通文字
            guard cursor == end || isBlank(text.character(at: cursor)) else { return nil }
            while cursor < end, isBlank(text.character(at: cursor)) { cursor += 1 }
            return (cursor, nextOrderedNumberText(after: digits) + character(delimiter) + " ")
        }

        // 无序列表：`-` / `*` / `+`
        guard isBulletCharacter(first) else { return nil }
        var cursor = start + 1

        // 任务列表：`- [ ] ` / `- [x] `（空格、小写 x、大写 X 都是合法的状态字符）。
        // ⚠️ 标记和 `[` 之间那个空格必须跳过去 —— `- [ ]` 里 `-` 后面第一个字符是空格，不是 `[`；
        //    不跳的话任务项会被误判成普通无序项，续写出来的新项会丢掉复选框。
        var bracket = cursor
        while bracket < end, isBlank(text.character(at: bracket)) { bracket += 1 }
        if bracket + 2 < end,
           text.character(at: bracket) == 0x5B /* [ */,
           text.character(at: bracket + 2) == 0x5D /* ] */ {
            let state = text.character(at: bracket + 1)
            if isBlank(state) || state == 0x78 /* x */ || state == 0x58 /* X */ {
                cursor = bracket + 3
                while cursor < end, isBlank(text.character(at: cursor)) { cursor += 1 }
                // 新的一项永远是「未完成」—— 刚敲的回车不该顺手把上一项的勾也勾上
                return (cursor, character(first) + " [ ] ")
            }
        }

        // 普通无序项：标记后面必须跟空格 / tab / 行尾，否则 `-abc` 只是普通文字
        guard cursor == end || isBlank(text.character(at: cursor)) else { return nil }
        while cursor < end, isBlank(text.character(at: cursor)) { cursor += 1 }
        return (cursor, character(first) + " ")
    }

    /// 有序列表下一项的序号文本（`1.` → `2.`）。
    ///
    /// 用户写 `01. ` 这种补零写法时，下一项也补到同样宽度（`02. `），不然序号会从两位数突然缩回一位、缩进跟着跳一下。
    private static func nextOrderedNumberText(after digits: String) -> String {
        guard let value = Int(digits) else { return digits }
        let next = String(value + 1)
        guard digits.count > next.count, digits.hasPrefix("0") else { return next }
        return String(repeating: "0", count: digits.count - next.count) + next
    }

    /// 光标落在哪一行（不含换行符本身）
    private static func lineRange(containing caret: Int, in text: NSString, length: Int) -> NSRange {
        var start = caret
        while start > 0, !isLineBreak(text.character(at: start - 1)) { start -= 1 }
        var end = caret
        while end < length, !isLineBreak(text.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    // MARK: - 字符判定（按 UTF-16 单元，和 NSRange 的坐标一致）

    private static func isLineBreak(_ character: unichar) -> Bool { character == 0x0A || character == 0x0D }
    private static func isBlank(_ character: unichar) -> Bool { character == 0x20 || character == 0x09 }
    private static func isDigit(_ character: unichar) -> Bool { character >= 0x30 && character <= 0x39 }
    private static func isBulletCharacter(_ character: unichar) -> Bool {
        character == 0x2D /* - */ || character == 0x2A /* * */ || character == 0x2B /* + */
    }

    /// `unichar` → 单字符字符串（`String(utf16CodeUnits:count:)` 是按 UTF-16 单元取的，和上面所有判定同一套坐标）
    private static func character(_ unit: unichar) -> String {
        String(utf16CodeUnits: [unit], count: 1)
    }
}
