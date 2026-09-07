//
//  SourceLocationTable.swift
//  MarkdownEditorHy4
//
//  swift-markdown 的 SourceLocation → NSAttributedString 偏移的换算表
//

import Foundation
import Markdown

/// 把 swift-markdown 给出的 `(行号, 列号)` 换算成「整篇文本里的 UTF-16 字符偏移」。
///
/// ### 为什么需要这张表
/// - swift-markdown 的 `SourceLocation` 只有两个信息：`line`（从 1 开始）和 `column`（从 1 开始，
///   而且是**该行内的 UTF-8 字节数**，不是字符数）。
/// - 而 `NSAttributedString` / `NSRange` 用的是 **UTF-16 偏移**（一个 emoji 算 2，一个中文算 1）。
///
/// 中文、emoji 混排时两者完全对不上，所以必须建一张表，把「第几行第几列」翻译成「第几个字符」。
struct SourceLocationTable {
    /// 下标 = 行号 - 1，值 = 该行第一个字符的 UTF-8 字节偏移
    private let lineStartUTF8: [Int]
    /// 下标 = UTF-8 字节偏移，值 = 对应的 UTF-16 字符偏移
    private let utf8ToUTF16: [Int]
    /// 整篇文本的 UTF-16 长度
    let totalUTF16Length: Int

    init(source: String) {
        // 第 1 行总是从偏移 0 开始
        var lineStarts = [0]
        var map = [Int]()
        map.reserveCapacity(source.utf8.count + 1)

        var utf8Offset = 0
        var utf16Offset = 0

        // 逐个字符（Unicode 标量）扫一遍，同时累计两种偏移。
        //
        // 关键点：map 的下标是 **UTF-8 字节偏移**，所以一个占 N 个字节的字符
        // 必须连续写 N 条记录（都指向同一个 UTF-16 偏移）。
        // 只写 1 条的话，纯英文时看不出问题（1 字节 = 1 个 UTF-16 单元），
        // 一碰到中文（3 字节 = 1 个 UTF-16 单元）整张表就整体错位了。
        for scalar in source.unicodeScalars {
            let byteWidth = UTF8.width(scalar)
            for _ in 0..<byteWidth {
                map.append(utf16Offset)
            }
            utf8Offset += byteWidth
            utf16Offset += UTF16.width(scalar)
            if scalar == "\n" {
                // 换行符后面就是下一行的开头
                lineStarts.append(utf8Offset)
            }
        }
        // 末尾哨兵：字符串结尾也要能换算
        map.append(utf16Offset)

        self.lineStartUTF8 = lineStarts
        self.utf8ToUTF16 = map
        self.totalUTF16Length = utf16Offset
    }

    /// 把一个源码位置换算成 UTF-16 字符偏移
    /// - parameter line:   行号，从 1 开始
    /// - parameter column: 列号，从 1 开始（该行内的 UTF-8 字节数）
    func utf16Offset(line: Int, column: Int) -> Int {
        // 行号越界时兜底当作文末，避免整段渲染崩掉
        guard line >= 1, line <= lineStartUTF8.count else { return totalUTF16Length }

        let byteOffset = lineStartUTF8[line - 1] + max(0, column - 1)
        guard byteOffset >= 0, byteOffset < utf8ToUTF16.count else { return totalUTF16Length }
        return utf8ToUTF16[byteOffset]
    }

    /// 把 swift-markdown 的 `SourceRange` 换算成 `NSRange`（UTF-16 偏移）
    func utf16Range(of range: SourceRange) -> NSRange {
        let start = utf16Offset(line: range.lowerBound.line, column: range.lowerBound.column)
        let end = utf16Offset(line: range.upperBound.line, column: range.upperBound.column)
        return NSRange(location: start, length: max(0, end - start))
    }
}

// MARK: - String 的 UTF-16 下标小工具

extension String {
    /// 按 UTF-16 偏移取子串。`NSRange` 用的就是 UTF-16 偏移，所以这是和 NSAttributedString 对齐的唯一正确切法。
    /// - parameter offset: 起始偏移（以 UTF-16 计）
    /// - parameter length: 长度（以 UTF-16 计）
    func substring(utf16Offset offset: Int, length: Int) -> String {
        let utf16View = self.utf16
        guard offset >= 0, length > 0 else { return "" }
        guard let startUTF16 = utf16View.index(utf16View.startIndex, offsetBy: offset, limitedBy: utf16View.endIndex) else { return "" }
        guard let endUTF16 = utf16View.index(startUTF16, offsetBy: length, limitedBy: utf16View.endIndex) else { return "" }
        // 把 UTF-16 的下标转回 String 的下标（emoji 中间的下标转不回来，会返回 nil）
        guard let start = String.Index(startUTF16, within: self),
              let end = String.Index(endUTF16, within: self) else { return "" }
        return String(self[start..<end])
    }

    /// 从指定 UTF-16 偏移开始查找子串，返回 NSRange（找不到返回 nil）
    func nsRange(of needle: String, fromUTF16Offset offset: Int) -> NSRange? {
        let nsSelf = self as NSString
        let start = min(max(0, offset), nsSelf.length)
        let searchRange = NSRange(location: start, length: nsSelf.length - start)
        let found = nsSelf.range(of: needle, options: [], range: searchRange)
        return found.location == NSNotFound ? nil : found
    }

    /// UTF-16 长度（等价于 `(self as NSString).length`，但不用桥接）
    var utf16Length: Int { utf16.count }
}
