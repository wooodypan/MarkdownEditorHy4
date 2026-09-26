//
//  MarkdownMathScanner.swift
//  MarkdownEditorHy4
//
//  在一串普通文字里找出 `$...$` / `$$...$$` 这些公式片段
//
//  ### 为什么非得自己扫一遍
//  swift-markdown 只认 CommonMark / GFM 标准语法，而 `$` 在两个标准里都是普通字符 ——
//  `$x^2$` 在它眼里就是四个普通字。所以要识别公式，只能在 **AST 之后、自己再看一遍**。
//
//  ### 宁漏不错
//  公式识别最怕的不是「漏识别」，而是「把不是公式的东西当成了公式」——
//  后者会让正文凭空少一段字。`$ 100 和 $200` 这种写法在账单、报价里很常见，
//  所以开口 `$` 的右边**必须紧跟非空白字符**、收口 `$` 的左边也**不能是空白**，
//  靠这两条把这类误判挡掉。
//

import Foundation

/// 把一段文字切成「普通文字」和「公式」两种片段。
enum MarkdownMathScanner {

    /// 一个片段。所有范围都是 **UTF-16 偏移**，可以直接喂给 `RenderedFragment`
    enum Segment {
        /// 普通文字：原样显示
        case plain(NSRange)
        /// 一个公式：`range` 是连两侧 `$` 在内的整段源码，`latex` 是 `$` 里面的正文
        case math(range: NSRange, latex: NSRange, mode: MarkdownMathMode)
    }

    /// `$` 的 UTF-16 码位
    private static let dollar: unichar = 0x24
    /// `\` 的 UTF-16 码位
    private static let backslash: unichar = 0x5C

    /// 扫描一段文字，返回按顺序排好的片段（拼起来正好是原文，一个字符不多一个字符不少）。
    ///
    /// - parameter text:  被扫描的整串文字（一般是块的源码）
    /// - parameter scope: 只看这一段（对应某个 AST 节点覆盖的源码范围）
    static func scan(_ text: NSString, in scope: NSRange) -> [Segment] {
        let upperBound = NSMaxRange(scope)
        var segments: [Segment] = []
        var index = scope.location
        // 正在攒的「普通文字」段的起点；nil 表示手里现在没有在攒的段
        var plainStart: Int?

        func takeAsPlain(_ location: Int) {
            if plainStart == nil { plainStart = location }
        }
        /// 把手里攒着的普通文字段收尾（到 `upper` 为止，不含）
        func flushPlain(upTo upper: Int) {
            guard let start = plainStart, upper > start else { return }
            segments.append(.plain(NSRange(location: start, length: upper - start)))
            plainStart = nil
        }

        while index < upperBound {
            let character = text.character(at: index)

            // 反斜杠：`\$` 是「一个普通的美元符号」，不该被当成公式的边界 ——
            // 连它转义的那个字符一起跳过（同时也作为普通文字收进当前段）
            if character == backslash {
                takeAsPlain(index)
                index += 2
                continue
            }

            guard character == dollar else {
                takeAsPlain(index)
                index += 1
                continue
            }

            // `$$` = 块级公式，单个 `$` = 行内公式
            let isDouble = index + 1 < upperBound && text.character(at: index + 1) == dollar
            let contentStart = index + (isDouble ? 2 : 1)
            let terminator = isDouble ? "$$" : "$"

            guard let closing = findClosing(text,
                                           terminator: terminator,
                                           from: contentStart,
                                           upperBound: upperBound),
                  isValidContent(text, start: contentStart, end: closing.contentEnd, isBlock: isDouble) else {
                // 没找到收口，或者里头不像公式：这个 `$` 就只是个普通的美元符号
                takeAsPlain(index)
                index += 1
                continue
            }

            flushPlain(upTo: index)
            segments.append(.math(range: NSRange(location: index, length: closing.end - index),
                                  latex: NSRange(location: contentStart,
                                                 length: closing.contentEnd - contentStart),
                                  mode: isDouble ? .block : .inline))
            index = closing.end
        }

        flushPlain(upTo: upperBound)
        return segments
    }

    // MARK: - 收口与合法性

    /// 找 `terminator` 下一次出现的位置
    private static func findClosing(_ text: NSString,
                                    terminator: String,
                                    from start: Int,
                                    upperBound: Int) -> (contentEnd: Int, end: Int)? {
        let closingLength = terminator.utf16.count
        var index = start
        while index < upperBound {
            let character = text.character(at: index)
            // `\$` 是转义出来的普通美元符号，不做收口
            if character == backslash {
                index += 2
                continue
            }
            guard character == dollar else {
                index += 1
                continue
            }
            // 行内公式（`$`）遇到 `$$` 时不做收口：那是块级公式的地盘，让它过去，
            // 免得把 `$$x$$` 拆得七零八落
            if terminator == "$", index + 1 < upperBound, text.character(at: index + 1) == dollar {
                index += 2
                continue
            }
            guard index + closingLength <= upperBound else { return nil }
            let candidate = text.substring(with: NSRange(location: index, length: closingLength))
            guard candidate == terminator else { return nil }
            return (contentEnd: index, end: index + closingLength)
        }
        return nil
    }

    /// `start..<end` 这段内容能不能当公式。
    ///
    /// ### 块级和行内的判据不一样（这里踩过坑）
    /// 块级公式的常见写法就是 `$$\nE=mc^2\n$$` —— **首尾本来就是换行**。
    /// 早先把它和行内公式同一套判据（「紧贴 `$` 的字符不能是空白」），
    /// 结果块级公式一条都识别不出来。所以块级只要求「去掉空白后还有内容」。
    ///
    /// 行内公式的三条硬规则都是为了少误伤正文：
    /// - **紧挨着两侧 `$` 的字符不能是空白**：排除 `$ 100 和 $200` 这种金额写法；
    /// - **不能跨换行**：`$` 后面隔了行还能配上，多半只是正文里随手写的半截 `$`；
    /// - **内容不能空**：`$$` / `$$$` 单独出现时有别的意思（代码块、分隔），不该当公式。
    private static func isValidContent(_ text: NSString, start: Int, end: Int, isBlock: Bool) -> Bool {
        guard end > start else { return false }

        let content = text.substring(with: NSRange(location: start, length: end - start))
        // 不管块级还是行内，去掉空白后得真有东西（`$$  $$` 不该算公式）
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if isBlock { return true }

        // 行内公式不能跨换行
        guard !content.contains("\n"), !content.contains("\r") else { return false }
        // 紧贴两侧 `$` 的字符不能是空白（`\n` 也算空白，这样 `$ \n…` 也不会被当成公式）
        guard !isWhitespace(text.character(at: start)),
              !isWhitespace(text.character(at: end - 1)) else { return false }
        return true
    }

    /// 空格 / 制表符 / 换行 / 回车
    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D
    }
}
